// Multi-view: up to four live streams at once, laid out like the multi-stream sites (MultiTwitch,
// Twitch Theater): every picture as big as the space allows, one stream heard at a time (tap a
// picture to listen to it and see its chat), a focus layout with one big picture, and each
// picture fetched no sharper than it's shown, to spare data.
//
// It can be tucked away while you browse: then it's a row of the streamers' pictures where the
// mini player sits (the ones you're hearing lit up), and a tap brings it back. Holding a stream
// anywhere in the app offers "Add to multi-view", which collects streams there before any of them
// starts; a tap on the row then starts watching them together.

import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class MultiviewModel: ObservableObject, Identifiable {
  struct Tile: Identifiable {
    let channel: Channel
    let player: PlayerModel
    var id: String { channel.id }
  }

  /// Six at most: with nine, the phone ran out of memory (the app quit, or the phone restarted its
  /// home screen).
  static let maxTiles = 6
  /// Between one stream starting and the next (see `start`).
  private static let startSpacing: UInt64 = 450_000_000
  private var startTask: Task<Void, Never>?
  static let volumeSteps: [Float] = [1, 0.75, 0.5, 0.25]
  /// Tucked away (or waiting to start): nothing's on screen, so nothing sharper than this is fetched.
  static let hiddenHeight = 160

  nonisolated let id = UUID()
  @Published private(set) var tiles: [Tile] = []
  /// The stream picked last: its chat shows, and it's the big one in the focus layout.
  @Published private(set) var selectedID: String?
  /// The streams heard (any number of them, each at its own volume).
  @Published private(set) var heardIDs: Set<String> = []
  @Published private(set) var volumes: [String: Float] = [:]
  @Published private(set) var chat: ChatController?
  /// Playing. Streams added while collecting them from around the app wait until it's opened.
  @Published private(set) var running = false
  /// Open the stream picker as soon as the screen shows.
  @Published var wantsPicker = false
  /// Every stream is in one Picture in Picture window (see MultiviewPictureInPicture).
  @Published private(set) var pictureInPictureActive = false
  /// Paused from the lock screen, Control Center or headphones (see `setPaused`).
  @Published private(set) var paused = false
  private var hidden = false
  /// The pictures' last sizes (to fit the streams to them again after PiP).
  private var lastFit: (heights: [String: CGFloat], scale: CGFloat)?
  /// The view under the pictures on screen (the all-streams PiP window grows from it).
  private weak var pictureSource: UIView?
  #if canImport(AmazonIVSPlayer)
    private lazy var sharedPiP = MultiviewPictureInPicture(model: self)
  #endif
  /// All the streams in one window with play and pause (Kestrel's player, Playback controls on).
  private lazy var controlsPiP = MultiviewControlsPiP(model: self)

  /// Every stream is on Kestrel's player and Picture in Picture has controls: the window with
  /// controls (see MultiviewControlsPiP) rather than the one that moves the pictures in.
  var usesControlsPiP: Bool {
    AppSettings.shared.pipControls && AppSettings.shared.kestrelPlayer && !tiles.isEmpty
  }

  nonisolated init() {}

  var isFull: Bool { tiles.count >= Self.maxTiles }

  func contains(_ channel: Channel) -> Bool {
    tiles.contains { $0.channel.id == channel.id || $0.channel.login.lowercased() == channel.login.lowercased() }
  }

  func volume(_ id: String) -> Float { volumes[id] ?? 1 }

  /// Heard and actually playing (what the dock lights up).
  func isSounding(_ id: String) -> Bool {
    guard running, heardIDs.contains(id), let tile = tiles.first(where: { $0.id == id }) else { return false }
    return tile.player.phase == .playing && !tile.player.isPaused && !tile.player.isBuffering
  }

  private func makePlayer(_ channel: Channel, heard: Bool) -> PlayerModel {
    let player = PlayerModel(target: .live(channel))
    player.isTile = true
    player.pictureInPictureAllowed = channel.id == selectedID
    player.setMuted(!heard)
    if let volume = volumes[channel.id] { player.setVolume(volume) }
    // Small until its place on screen is known (they all started at 1080p, six at once, before
    // being fitted: a rush that crowded out chat's emotes); fitted to its size right after.
    player.setMaxHeight(hidden ? Self.hiddenHeight : 480)
    return player
  }

  func add(_ channel: Channel) {
    guard !channel.login.isEmpty, !isFull, !contains(channel) else { return }
    // The first one is heard; the others start quiet.
    let heard = tiles.isEmpty
    let player = makePlayer(channel, heard: heard)
    tiles.append(Tile(channel: channel, player: player))
    if heard { heardIDs.insert(channel.id) }
    if selectedID == nil { select(channel.id) }
    if running { Task { await player.start() } }
    updatePictureInPicture()
    NowPlaying.shared.update(multiview: self)
    AppModel.shared.objectWillChange.send()
  }

  func remove(_ id: String) {
    guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
    tiles[index].player.stop()
    tiles.remove(at: index)
    chats.removeValue(forKey: id)?.stop()
    let wasHeard = heardIDs.remove(id) != nil
    volumes[id] = nil
    if selectedID == id {
      selectedID = nil
      if let first = tiles.first {
        select(first.id)
      } else {
        stopChats()
      }
    }
    // Don't leave it silent because the one heard went.
    if wasHeard, heardIDs.isEmpty, let next = selectedID { heardIDs.insert(next) }
    applySound()
    updatePictureInPicture()
    AppModel.shared.objectWillChange.send()
  }

  /// Two streams change places (dragged onto each other, or from a picture's hold menu).
  func swap(_ a: String, _ b: String) {
    guard a != b, let i = tiles.firstIndex(where: { $0.id == a }), let j = tiles.firstIndex(where: { $0.id == b }) else { return }
    tiles.swapAt(i, j)
    updatePictureInPicture()
  }

  /// Starts every stream (and the picked one's chat).
  func start() {
    guard !running else { return }
    running = true
    paused = false
    NowPlaying.shared.attach(multiview: self)
    // One after another, the one picked first: all at once (six connections, six decoders and
    // six sound engines starting together), every stream stuttered for a while before they
    // settled.
    let featured = tiles.filter { $0.id == selectedID || heardIDs.contains($0.id) }
    let order = (featured + tiles.filter { tile in !featured.contains { $0.id == tile.id } }).map(\.player)
    startTask?.cancel()
    startTask = Task { [weak self] in
      for (index, player) in order.enumerated() {
        if index > 0 { try? await Task.sleep(nanoseconds: Self.startSpacing) }
        guard !Task.isCancelled, let self, self.running else { return }
        guard self.tiles.contains(where: { $0.player === player }) else { continue }
        Task { await player.start() }
      }
    }
    applySound()
    if let selectedID { startChat(for: selectedID) }
    updatePictureInPicture()
  }

  /// Stops everything but keeps the streams (another stream is being watched on its own); a tap
  /// on the dock starts them again.
  func park() {
    guard running else { return }
    startTask?.cancel()
    stopPictureInPicture()
    NowPlaying.shared.detach(multiview: self)
    running = false
    paused = false
    for tile in tiles { tile.player.stop() }
    tiles = tiles.map { Tile(channel: $0.channel, player: makePlayer($0.channel, heard: heardIDs.contains($0.id))) }
    stopChats()
  }

  /// Tucked away or back on screen: while hidden, every picture is fetched small (the sound
  /// carries on as it was).
  func setHidden(_ isHidden: Bool) {
    hidden = isHidden
    if isHidden, !pictureInPictureActive { for tile in tiles { tile.player.setMaxHeight(Self.hiddenHeight) } }
    updatePictureInPicture()
  }

  /// Picks a stream: its chat shows (and it's the big one in focus). If only one is heard, the sound
  /// moves to it too, like a regular multi-stream page; with several heard, they stay as they are.
  func select(_ id: String) {
    guard tiles.contains(where: { $0.id == id }) else { return }
    selectedID = id
    // Picture in Picture follows the picked stream (unless all of them go in it together).
    updatePictureInPicture()
    if heardIDs.count <= 1 {
      heardIDs = [id]
      applySound()
    }
    if running { startChat(for: id) }
  }

  /// Every stream's chat, kept connected while multi-view plays: switching to one shows it at
  /// once, messages and emotes already in (each switch used to connect and load it from nothing).
  private var chats: [String: ChatController] = [:]

  private func startChat(for id: String) {
    guard let tile = tiles.first(where: { $0.id == id }), chat?.channel.id != tile.channel.id else { return }
    chat = chatController(for: tile)
    // The others' chats come up in the background, a moment apart, ready for a switch.
    let others = tiles.filter { $0.id != id && chats[$0.id] == nil }
    guard !others.isEmpty else { return }
    Task { [weak self] in
      for tile in others {
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let self, self.running, self.tiles.contains(where: { $0.id == tile.id }) else { return }
        _ = self.chatController(for: tile)
      }
    }
  }

  private func chatController(for tile: Tile) -> ChatController {
    if let existing = chats[tile.id] { return existing }
    let controller = ChatController(channel: tile.channel)
    chats[tile.id] = controller
    controller.start()
    return controller
  }

  private func stopChats() {
    for controller in chats.values { controller.stop() }
    chats = [:]
    chat = nil
  }

  /// Sound on or off for one stream, leaving the others as they are (several can be heard at once).
  func toggleSound(_ id: String) {
    if heardIDs.contains(id) { heardIDs.remove(id) } else { heardIDs.insert(id) }
    applySound()
  }

  /// Picture in Picture: every stream together (Settings › Playback, experimental), or the picked
  /// one (the others carry on: heard ones keep their sound).
  func togglePictureInPicture() {
    if picturesTogether, usesControlsPiP || controlsPiP.isActive {
      updatePictureInPicture()
      controlsPiP.toggle()
      return
    }
    #if canImport(AmazonIVSPlayer)
      if picturesTogether || sharedPiP.isActive {
        updatePictureInPicture()
        sharedPiP.toggle()
        return
      }
    #endif
    guard running, let selectedID, let tile = tiles.first(where: { $0.id == selectedID }) else { return }
    tile.player.pictureInPictureAllowed = true
    tile.player.togglePictureInPicture()
  }

  /// Just this one heard.
  func listenOnly(_ id: String) {
    heardIDs = [id]
    applySound()
    select(id)
  }

  func setVolume(_ value: Float, for id: String) {
    volumes[id] = value
    tiles.first { $0.id == id }?.player.setVolume(value)
  }

  private func applySound() {
    for tile in tiles { tile.player.setMuted(!heardIDs.contains(tile.id)) }
    NowPlaying.shared.update(multiview: self)
  }

  // MARK: Picture in Picture

  /// Leaving the app puts every stream in one PiP window (Settings › Playback, experimental; it
  /// needs the low-latency player), rather than just the picked one.
  var picturesTogether: Bool {
    #if canImport(AmazonIVSPlayer)
      return AppSettings.shared.multiviewPiPAll && tiles.count > 1
    #else
      return AppSettings.shared.multiviewPiPAll && tiles.count > 1 && usesControlsPiP
    #endif
  }

  /// Where each picture is on the multi-view screen, and the size of the area they're in.
  private var pictureLayout: (rects: [String: CGRect], size: CGSize)?

  func setPictureLayout(_ rects: [String: CGRect], in size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    pictureLayout = (rects, size)
    controlsPiP.setLayout(rects, in: size)
    #if canImport(AmazonIVSPlayer)
      sharedPiP.setLayout(rects, in: size)
      sharedPiP.fit(count: tiles.count)
    #endif
  }

  /// Sets up whichever Picture in Picture applies now.
  func updatePictureInPicture() {
    let together = picturesTogether
    let withControls = usesControlsPiP
    for tile in tiles { tile.player.pictureInPictureAllowed = !together && tile.id == selectedID }
    if let pictureLayout { controlsPiP.setLayout(pictureLayout.rects, in: pictureLayout.size) }
    controlsPiP.setEnabled(together && withControls && running && !hidden, source: pictureSource)
    controlsPiP.sync()
    #if canImport(AmazonIVSPlayer)
      if let pictureLayout { sharedPiP.setLayout(pictureLayout.rects, in: pictureLayout.size) }
      sharedPiP.fit(count: tiles.count)
      sharedPiP.setEnabled(together && !withControls && running && !hidden, source: pictureSource)
      sharedPiP.sync()
    #endif
  }

  /// The multi-view screen's pictures came on screen (or went).
  func setPictureSource(_ view: UIView?) {
    guard view !== pictureSource else { return }
    pictureSource = view
    updatePictureInPicture()
  }

  /// The all-streams window opened or closed: small pictures while it's up (it's small), then
  /// each as sharp as its place on screen again.
  func pictureInPictureChanged(_ active: Bool) {
    pictureInPictureActive = active
    if active {
      // Smaller pictures for the small window, a few seconds in: switching quality the moment
      // the window opened made the pictures stutter as they went into it.
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard let self, self.pictureInPictureActive else { return }
        // The window with controls plays at 60 frames a second: Twitch's 60 fps starts at 720p
        // (lower ones are 30), so up to four streams keep it there.
        let cap = self.controlsPiP.isActive ? (self.tiles.count <= 4 ? 720 : 480) : (self.tiles.count <= 2 ? 480 : 360)
        for tile in self.tiles { tile.player.setMaxHeight(cap) }
      }
    } else if !hidden {
      // Each picture sharp again for its place on screen, a moment after the hand-over (switching
      // quality right as the pictures move back added to the moment they went black).
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard let self, !self.pictureInPictureActive, !self.hidden, let lastFit = self.lastFit else { return }
        self.fit(heights: lastFit.heights, scale: lastFit.scale)
      }
    } else {
      for tile in tiles { tile.player.setMaxHeight(Self.hiddenHeight) }
    }
  }

  /// Paused or played from the lock screen, Control Center or headphones. Pausing stops every
  /// stream and closes the Picture in Picture window (it has no buttons of its own); playing picks
  /// them up at live again: in the background just the ones heard, the others with the app.
  func setPaused(_ pause: Bool, keepWindow: Bool = false) {
    guard running else { return }
    paused = pause
    controlsPiP.playbackChanged()
    if pause {
      // (The window with controls stays up, paused; the other kind has no play button.)
      if !keepWindow, !controlsPiP.isActive { stopPictureInPicture() }
      for tile in tiles { tile.player.setPaused(true) }
    } else {
      let background = UIApplication.shared.applicationState == .background
      for tile in tiles where !background || heardIDs.contains(tile.id) || controlsPiP.isActive { tile.player.setPaused(false) }
    }
    NowPlaying.shared.update(multiview: self)
  }

  /// Back on screen after a pause from outside the app: everything plays again.
  func resumeIfPaused() {
    guard running, paused else { return }
    paused = false
    for tile in tiles where tile.player.isPaused { tile.player.setPaused(false) }
    NowPlaying.shared.update(multiview: self)
  }

  private func stopPictureInPicture() {
    controlsPiP.stop()
    #if canImport(AmazonIVSPlayer)
      sharedPiP.stop()
    #endif
  }

  /// Each stream no sharper than its picture is shown (see `MultiviewLayout.heightCap`).
  func fit(heights: [String: CGFloat], scale: CGFloat) {
    lastFit = (heights, scale)
    guard !hidden, !pictureInPictureActive else { return }
    for tile in tiles {
      guard let points = heights[tile.id] else { continue }
      let featured = tile.id == selectedID || heardIDs.contains(tile.id)
      tile.player.setMaxHeight(MultiviewLayout.heightCap(points: points, scale: scale, heard: featured))
    }
  }

  func stopAll() {
    startTask?.cancel()
    stopPictureInPicture()
    NowPlaying.shared.detach(multiview: self)
    for tile in tiles { tile.player.stop() }
    stopChats()
    running = false
  }
}

/// How far multi-view is pulled up from its dock (nil: it isn't), watched only by what shows it
/// (published from AppModel, every frame of the pull would redraw the whole app).
@MainActor
final class MultiviewPull: ObservableObject {
  static let shared = MultiviewPull()
  @Published var progress: CGFloat?
}

/// Multi-view on screen: open, or growing out of its dock under the finger (the same view either
/// way, so letting go just carries on growing it).
struct MultiviewPresenter: View {
  let model: MultiviewModel
  let minimized: Bool
  @ObservedObject private var pull = MultiviewPull.shared

  var body: some View {
    if !minimized || pull.progress != nil {
      let progress = minimized ? (pull.progress ?? 0) : 1
      MultiviewScreen(model: model)
        // Only a scale and a fade while it moves (nothing re-laid out), from the dock's corner.
        .scaleEffect(0.25 + 0.75 * progress, anchor: .bottomTrailing)
        .opacity(Double(min(1, progress * 1.8)))
        .allowsHitTesting(!minimized)
        .transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .bottomTrailing)))
    }
  }
}

struct MultiviewScreen: View {
  @ObservedObject var model: MultiviewModel
  @StateObject private var keyboard = KeyboardObserver()
  @EnvironmentObject private var app: AppModel
  @Environment(\.displayScale) private var displayScale
  @AppStorage("multiview.chat") private var chatShown = true
  @AppStorage("multiview.focus") private var focus = false
  /// Chat's share of the width when it's beside the pictures (dragged at the divider).
  @AppStorage("multiview.chatShare") private var chatShare = 0.3
  @State private var resizedChat: CGFloat?
  @State private var resizingFrom: CGFloat?
  @State private var picking = false
  /// The bar, names, sound buttons and the outline around the picked stream: they fade after a
  /// few seconds so it's just the streams (a tap brings them back).
  @State private var chromeVisible = true
  @State private var hideTask: Task<Void, Never>?
  /// Pulled down this far (it shrinks toward its corner under the finger, like the player).
  @State private var pull: CGFloat = 0

  private static let spring = Animation.spring(response: 0.4, dampingFraction: 0.86)

  /// On screen only while open: tucked away it's the dock (MultiviewDockSpot) and this view is
  /// gone, the streams carrying on in the model.
  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      expanded(size: size, safeBottom: geometry.safeAreaInsets.bottom, crease: Self.crease(geometry))
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
    .ignoresSafeArea(.keyboard)
    .background(Color.black.ignoresSafeArea())
    .scaleEffect(1 - min(0.3, pull / 1400), anchor: .bottomTrailing)
    .offset(y: pull * 0.35)
    .preferredColorScheme(.dark)
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .sheet(isPresented: $picking, onDismiss: { showChrome() }) { MultiviewPicker(model: model) }
    // (Being pulled up from the dock it's on screen but not open yet: opened once let go.)
    .onAppear { if !app.multiviewMinimized { opened() } }
    .onChange(of: app.multiviewMinimized) { minimized in if !minimized { opened() } }
    .onDisappear {
      hideTask?.cancel()
      model.setHidden(true)
      if app.playing == nil || app.playerMinimized { OrientationLock.playerVisible(false) }
    }
    // Back in the app on multi-view after pausing it from the lock screen: it plays again.
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
      model.resumeIfPaused()
    }
    .onChange(of: model.wantsPicker) { wants in
      if wants {
        model.wantsPicker = false
        picking = true
      }
    }
  }

  private func minimize() {
    Keyboard.dismiss()
    withAnimation(Self.spring) {
      app.multiviewMinimized = true
      pull = 0
    }
  }

  /// Pull down on the pictures to tuck multi-view away (it follows the finger), like the player.
  private var pullDown: some Gesture {
    DragGesture(minimumDistance: 16, coordinateSpace: .global)
      .onChanged { value in
        let dy = value.translation.height
        guard pull > 0 || (dy > 10 && dy > abs(value.translation.width) * 1.3) else { return }
        pull = max(0, dy)
      }
      .onEnded { value in
        guard pull > 0 else {
          // Landscape, sideways: chat in from the side (toward the middle) or away (toward its edge).
          let dx = value.translation.width, dy = value.translation.height
          let bounds = AppWindow.current?.bounds ?? .zero
          guard bounds.width > bounds.height, model.chat != nil, abs(dx) > 80, abs(dx) > abs(dy) * 1.5 else { return }
          let show = dx < 0
          guard show != chatShown else { return }
          Haptics.tap()
          withAnimation(Self.spring) { chatShown = show }
          return
        }
        if pull > 110 || value.predictedEndTranslation.height > 260 {
          minimize()
        } else {
          withAnimation(Self.spring) { pull = 0 }
        }
      }
  }

  /// On screen: playing, turnable, the picker up if there's hardly anything to watch yet.
  private func opened() {
    pull = 0
    model.updatePictureInPicture()
    model.resumeIfPaused()
    if app.playing != nil { app.playing = nil }
    OrientationLock.playerVisible(true)
    model.setHidden(false)
    model.start()
    showChrome()
    if model.wantsPicker || model.tiles.count < 2 {
      model.wantsPicker = false
      picking = true
    }
  }

  // MARK: On screen

  @ViewBuilder
  private func expanded(size: CGSize, safeBottom: CGFloat, crease: CGRect?) -> some View {
    let landscape = size.width > size.height
    let bar: CGFloat = landscape ? 40 : 44
    let showChat = chatShown && model.chat != nil
    let keyboardSpace = keyboard.overlap > 0 ? max(0, keyboard.overlap + 14 - safeBottom) : 0
    let areas = Self.areas(
      size: size, safeBottom: safeBottom, landscape: landscape, chat: showChat, keyboardSpace: keyboardSpace,
      count: model.tiles.count, focus: focus, chatWidth: resizedChat ?? size.width * chatShare, fold: crease != nil)
    let rects = layout(
      in: areas.grid.size,
      crease: crease.flatMap { $0.intersects(areas.grid) ? $0.offsetBy(dx: -areas.grid.minX, dy: -areas.grid.minY) : nil })
    let chrome = chromeVisible || keyboard.overlap > 0 || model.tiles.isEmpty

    ZStack(alignment: .topLeading) {
      ZStack(alignment: .topLeading) {
        Color.black
          .frame(width: size.width, height: size.height + safeBottom)
          .contentShape(Rectangle())
          .onTapGesture {
            Keyboard.dismiss()
            showChrome()
          }

        // Where the all-streams Picture in Picture window grows from and goes back to.
        // Just over the pictures (the box around them, the window's shape): over the whole area,
        // the window flew back into a different shape and jumped at the end.
        let anchor = StreamPictures.box(rects).flatMap { $0.isNull ? nil : $0 } ?? CGRect(origin: .zero, size: areas.grid.size)
        PictureInPictureAnchor(model: model)
          .frame(width: anchor.width, height: anchor.height)
          .offset(x: areas.grid.minX + anchor.minX, y: areas.grid.minY + anchor.minY)
          .allowsHitTesting(false)

        if model.tiles.isEmpty {
          emptyState
            .frame(width: areas.grid.width, height: areas.grid.height)
            .offset(x: areas.grid.minX, y: areas.grid.minY)
        }
        ForEach(Array(model.tiles.enumerated()), id: \.element.id) { index, tile in
          let rect = index < rects.count ? rects[index] : .zero
          MultiviewTileView(
            player: tile.player, channel: tile.channel, heard: model.heardIDs.contains(tile.id),
            selected: tile.id == model.selectedID, volume: model.volume(tile.id),
            several: model.heardIDs.count > 1 || (model.heardIDs.count == 1 && !model.heardIDs.contains(tile.id)),
            tap: {
              // The first tap just brings the controls back; with them showing, it picks the stream.
              if chromeVisible { withAnimation(Self.spring) { model.select(tile.id) } }
              showChrome()
            },
            toggleSound: {
              model.toggleSound(tile.id)
              showChrome()
            },
            listenOnly: { withAnimation(Self.spring) { model.listenOnly(tile.id) } },
            setVolume: { model.setVolume($0, for: tile.id) },
            makeMain: {
              withAnimation(Self.spring) {
                // Double-tapping the big one goes back to equal sizes; any other becomes the big one.
                if focus, tile.id == model.selectedID {
                  focus = false
                } else {
                  model.select(tile.id)
                  focus = true
                }
              }
              showChrome()
            },
            openInPlayer: { app.playing = .live(tile.channel) },
            remove: { withAnimation(Self.spring) { model.remove(tile.id) } },
            others: model.tiles.filter { $0.id != tile.id }.map(\.channel),
            swap: { other in
              Haptics.tap()
              withAnimation(Self.spring) { swapTiles(tile.id, other) }
            }
          )
          // Redrawn only when what it shows changes; the controls fading reach its picture through
          // the environment, past it (each redraw rebuilt its hold menu: the text flashed).
          .equatable()
          .environment(\.multiviewChrome, chrome)
          .frame(width: rect.width, height: rect.height)
          // Hold a picture and drag it onto another: they change places.
          .onDrag {
            NSItemProvider(object: tile.id as NSString)
          } preview: {
            Label(tile.channel.name, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 14).padding(.vertical, 10)
              .background(Color.accentTeal, in: Capsule())
              .foregroundColor(.white)
          }
          .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { item, _ in
              guard let dragged = item as? String else { return }
              Task { @MainActor in
                Haptics.tap()
                withAnimation(Self.spring) { swapTiles(dragged, tile.id) }
              }
            }
            return true
          }
          .offset(x: areas.grid.minX + rect.minX, y: areas.grid.minY + rect.minY)
          .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
      }
      .simultaneousGesture(pullDown)

      if model.pictureInPictureActive {
        // The pictures are in the PiP window meanwhile.
        VStack(spacing: 8) {
          Image(systemName: "pip").font(.system(size: 30, weight: .semibold))
          Text("Playing in Picture in Picture").font(.subheadline.weight(.semibold))
        }
        .foregroundColor(.white.opacity(0.75))
        .frame(width: areas.grid.width, height: areas.grid.height)
        .background(Color.black)
        .offset(x: areas.grid.minX, y: areas.grid.minY)
        .allowsHitTesting(false)
        .transition(.opacity)
      }

      if let chat = model.chat, showChat {
        // Down to the window's bottom edge, like the player's chat: the message box keeps clear
        // of the home indicator and the keyboard by padding.
        chatColumn(chat, bottomInset: keyboard.overlap > 0 ? keyboard.overlap + 14 : safeBottom, safeBottom: safeBottom)
          .frame(width: areas.chat.width, height: areas.chat.height)
          // Beside the pictures: swiped toward its edge, chat goes and the pictures take the room.
          .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .global).onEnded { value in
              guard landscape, keyboard.overlap == 0 else { return }
              let dx = value.translation.width, dy = value.translation.height
              guard dx > 80, dx > abs(dy) * 1.5 else { return }
              Haptics.tap()
              withAnimation(Self.spring) { chatShown = false }
            }
          )
          .offset(x: areas.chat.minX, y: areas.chat.minY)
          .transition(.move(edge: landscape ? .trailing : .bottom).combined(with: .opacity))
        if landscape {
          chatDivider(areas, width: size.width)
        }
      }

      // Over the pictures, fading with the rest of the controls.
      topBar
        .frame(width: areas.grid.width, height: bar)
        .background(
          LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
            .padding(.bottom, -16)
            .allowsHitTesting(false)
        )
        .offset(x: areas.grid.minX, y: areas.grid.minY)
        .opacity(chrome ? 1 : 0)
        .allowsHitTesting(chrome)
        .animation(.easeInOut(duration: 0.3), value: chrome)
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .animation(Self.spring, value: showChat)
    .animation(Self.spring, value: focus)
    .animation(Self.spring, value: model.tiles.map(\.id))
    .task(id: capsKey(rects)) {
      var heights: [String: CGFloat] = [:]
      for (index, tile) in model.tiles.enumerated() where index < rects.count { heights[tile.id] = rects[index].height }
      model.fit(heights: heights, scale: displayScale)
    }
    // The all-streams PiP window lays the pictures out just as they are here, so going into it and
    // back is one picture growing or shrinking, not a 2×2 grid turning into another layout.
    .task(id: layoutKey(rects, in: areas.grid.size)) {
      var placed: [String: CGRect] = [:]
      for (index, tile) in model.tiles.enumerated() where index < rects.count { placed[tile.id] = rects[index] }
      model.setPictureLayout(placed, in: areas.grid.size)
    }
  }

  /// Shows the controls, and hides them again after a few seconds without a touch.
  private func showChrome() {
    hideTask?.cancel()
    if !chromeVisible { withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = true } }
    hideTask = Task {
      try? await Task.sleep(nanoseconds: 3_500_000_000)
      guard !Task.isCancelled, !picking else { return }
      withAnimation(.easeInOut(duration: 0.4)) { chromeVisible = false }
    }
  }

  // MARK: Layout

  private struct Areas {
    var grid: CGRect
    var chat: CGRect
  }

  /// Landscape: the pictures at full height, chat in a column on the right. Portrait: the pictures
  /// at the top (no taller than they need), chat under them (room kept above the keyboard). The
  /// bar lies over the top of the pictures.
  /// Chat beside the pictures: between these.
  static let minChat: CGFloat = 240
  static func maxChat(_ width: CGFloat) -> CGFloat { max(minChat, width * 0.5) }

  private func chatDivider(_ areas: Areas, width: CGFloat) -> some View {
    Capsule()
      .fill(Color.white.opacity(resizingFrom == nil ? 0.22 : 0.6))
      .frame(width: 4, height: 44)
      .frame(width: 24, height: areas.chat.height)
      .contentShape(Rectangle())
      .offset(x: areas.chat.minX - 12, y: areas.chat.minY)
      .gesture(
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
          .onChanged { value in
            if resizingFrom == nil { resizingFrom = areas.chat.width }
            resizedChat = min(max((resizingFrom ?? areas.chat.width) - value.translation.width, Self.minChat), Self.maxChat(width))
          }
          .onEnded { _ in
            if let resized = resizedChat { chatShare = Double(resized / max(width, 1)) }
            resizingFrom = nil
            resizedChat = nil
          }
      )
      .accessibilityLabel("Resize chat")
  }

  private static func areas(
    size: CGSize, safeBottom: CGFloat, landscape: Bool, chat: Bool, keyboardSpace: CGFloat, count: Int, focus: Bool,
    chatWidth preferred: CGFloat, fold: Bool
  ) -> Areas {
    if landscape {
      var chatWidth = chat ? min(max(preferred, minChat), maxChat(size.width)).rounded() : 0
      var gridWidth = size.width - chatWidth - (chat ? 1 : 0)
      // Down to the window's bottom edge, the pictures centred in all of it (stopping at the home
      // indicator's band left them high, with black under them).
      let gridHeight = size.height + safeBottom
      if chat, !fold, count > 0 {
        // Width the pictures can't use (they're as tall as the window allows already) goes to
        // chat instead of black bars beside them.
        let probe = CGSize(width: gridWidth, height: gridHeight)
        let rects = focus && count > 1 ? MultiviewLayout.focus(count: count, main: 0, in: probe) : MultiviewLayout.grid(count: count, in: probe)
        let used = (rects.map(\.maxX).max() ?? gridWidth) - (rects.map(\.minX).min() ?? 0)
        let spare = (gridWidth - used).rounded(.down)
        if spare > 8 {
          gridWidth -= spare
          chatWidth += spare
        }
      }
      return Areas(
        grid: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight),
        chat: CGRect(x: size.width - chatWidth, y: 0, width: chatWidth, height: size.height + safeBottom))
    }
    guard chat else {
      return Areas(grid: CGRect(x: 0, y: 0, width: size.width, height: size.height), chat: .zero)
    }
    // As tall as the pictures need, leaving chat at least a little room (more without the keyboard).
    let roomForChat: CGFloat = keyboardSpace > 0 ? 150 : 230
    let limit = max(100, min(size.height * 0.66, size.height - keyboardSpace - roomForChat))
    let probe = CGSize(width: size.width, height: limit)
    let rects =
      focus && count > 1 ? MultiviewLayout.focus(count: count, main: 0, in: probe) : MultiviewLayout.grid(count: count, in: probe)
    let used = rects.isEmpty ? min(limit, (size.width * 9 / 16).rounded()) : (rects.map(\.maxY).max() ?? 0) - (rects.map(\.minY).min() ?? 0)
    let gridHeight = max(100, min(limit, used))
    return Areas(
      grid: CGRect(x: 0, y: 0, width: size.width, height: gridHeight),
      chat: CGRect(x: 0, y: gridHeight + 1, width: size.width, height: max(0, size.height - gridHeight - 1 + safeBottom)))
  }

  /// iPhone Duo partly folded: where the fold runs through the screen.
  private static func crease(_ geometry: GeometryProxy) -> CGRect? {
    if #available(iOS 27.1, *) {
      return geometry.reservedRegions(kind: .division).first?.frame
    }
    return nil
  }

  /// The pictures' places, kept off iPhone Duo's fold when it's partly folded (`crease`, in the
  /// pictures' area's coordinates): the streams split between the two sides (focus: the big one
  /// on one side, the rest on the other), so none runs across the fold.
  private func layout(in size: CGSize, crease: CGRect?) -> [CGRect] {
    let count = model.tiles.count
    guard count > 1, let crease, crease.width > 0, crease.height > 0 else { return layout(in: size) }
    let vertical = crease.height > crease.width
    let first: CGRect
    let second: CGRect
    if vertical {
      guard crease.minX > 120, crease.maxX < size.width - 120 else { return layout(in: size) }
      first = CGRect(x: 0, y: 0, width: crease.minX, height: size.height)
      second = CGRect(x: crease.maxX, y: 0, width: size.width - crease.maxX, height: size.height)
    } else {
      guard crease.minY > 90, crease.maxY < size.height - 90 else { return layout(in: size) }
      first = CGRect(x: 0, y: 0, width: size.width, height: crease.minY)
      second = CGRect(x: 0, y: crease.maxY, width: size.width, height: size.height - crease.maxY)
    }
    // Which streams go on the first side.
    let firstSide = focus ? [model.tiles.firstIndex { $0.id == model.selectedID } ?? 0] : Array(0..<((count + 1) / 2))
    let secondSide = (0..<count).filter { !firstSide.contains($0) }
    var rects = Array(repeating: CGRect.zero, count: count)
    for (side, indices) in [(first, firstSide), (second, secondSide)] {
      let placed = MultiviewLayout.grid(count: indices.count, in: side.size)
      for (index, rect) in zip(indices, placed) { rects[index] = rect.offsetBy(dx: side.minX, dy: side.minY) }
    }
    return rects
  }

  private func layout(in size: CGSize) -> [CGRect] {
    let count = model.tiles.count
    if focus, count > 1 {
      let main = model.tiles.firstIndex { $0.id == model.selectedID } ?? 0
      return MultiviewLayout.focus(count: count, main: main, in: size)
    }
    return MultiviewLayout.grid(count: count, in: size)
  }

  /// Two pictures change places. With one big picture, whichever lands in the big one's place
  /// becomes the big one (the big one is the picked stream, wherever it sits in the order).
  private func swapTiles(_ a: String, _ b: String) {
    guard a != b else { return }
    if focus, model.tiles.count > 1, let big = model.selectedID, big == a || big == b {
      model.select(big == a ? b : a)
    }
    model.swap(a, b)
  }

  private func layoutKey(_ rects: [CGRect], in size: CGSize) -> String {
    "\(Int(size.width))x\(Int(size.height))|"
      + zip(model.tiles, rects).map { "\($0.id):\(Int($1.minX)),\(Int($1.minY)),\(Int($1.width)),\(Int($1.height))" }
      .joined(separator: ";")
  }

  private func capsKey(_ rects: [CGRect]) -> String {
    zip(model.tiles, rects).map { "\($0.id):\(Int($1.height))" }.joined(separator: ",")
      + "|\(model.selectedID ?? "")|\(model.heardIDs.sorted().joined(separator: ","))|\(model.running)"
  }

  // MARK: Pieces

  private var topBar: some View {
    HStack(spacing: 2) {
      barButton("chevron.down", label: "Tuck multi-view away") { minimize() }
      Text("Multi-view").font(.headline)
      Text("\(model.tiles.count)/\(MultiviewModel.maxTiles)").font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
        .padding(.leading, 4)
      Spacer(minLength: 4)
      if model.tiles.count > 1 {
        barButton(
          focus ? "rectangle.grid.2x2" : "rectangle.inset.topleft.filled",
          label: focus ? "Equal sizes" : "One big picture"
        ) {
          focus.toggle()
          showChrome()
        }
      }
      if model.chat != nil {
        barButton(chatShown ? "bubble.left.fill" : "bubble.left", label: chatShown ? "Hide chat" : "Show chat", highlighted: chatShown) {
          chatShown.toggle()
          showChrome()
        }
      }
      if AVPictureInPictureController.isPictureInPictureSupported(), model.selectedID != nil {
        barButton(
          model.pictureInPictureActive ? "pip.exit" : "pip.enter",
          label: model.picturesTogether ? "Picture in Picture (all the streams)" : "Picture in Picture (the picked stream)"
        ) {
          model.togglePictureInPicture()
          showChrome()
        }
      }
      barButton("plus", label: "Add a stream") { picking = true }
        .disabled(model.isFull)
        .opacity(model.isFull ? 0.4 : 1)
      barButton("xmark", label: "Close multi-view") { app.closeMultiview() }
    }
    .padding(.horizontal, 6)
    .foregroundColor(.white)
  }

  private func barButton(_ icon: String, label: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 17, weight: .semibold))
        .foregroundColor(highlighted ? .accentTeal : .white)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(0.5), radius: 3)
    }
    .buttonStyle(PressableStyle(scale: 0.85))
    .accessibilityLabel(label)
  }

  private func chatColumn(_ chat: ChatController, bottomInset: CGFloat, safeBottom: CGFloat) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Avatar(url: chat.channel.profileImageURL, size: 18)
        Text("\(chat.channel.name)'s chat").font(.caption.weight(.semibold)).lineLimit(1)
        Spacer()
      }
      .foregroundColor(.white.opacity(0.85))
      .padding(.horizontal, 12)
      .frame(height: 28)
      Divider().overlay(Color.white.opacity(0.08))
      ChatPanel(
        chat: chat, bottomInset: bottomInset, keyboardUp: keyboard.overlap > 0, safeBottom: safeBottom, compact: true, active: true
      )
      .id(chat.channel.id)
    }
    .background(Color(white: 0.07))
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.split.2x2").font(.system(size: 40, weight: .semibold)).foregroundColor(.accentTeal)
      Text("Watch up to \(MultiviewModel.maxTiles) streams at once").font(.headline)
      Text("Or hold any stream in the app and pick Add to multi-view: they gather in the corner until you open them.")
        .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
      Button {
        picking = true
      } label: {
        Label("Add streams", systemImage: "plus").font(.subheadline.weight(.semibold))
          .padding(.horizontal, 16).padding(.vertical, 10)
          .background(Color.accentTeal, in: Capsule())
          .foregroundColor(.black)
      }
    }
    .padding(24)
  }
}

/// Where the dock sits while multi-view is tucked away: the mini player's corner (above the mini
/// player when a stream's in it too). It's laid over the app's tabs on its own, so everything else
/// on screen stays usable. Tap or swipe it up to open multi-view; throw it aside to close it.
struct MultiviewDockSpot: View {
  @ObservedObject var model: MultiviewModel
  @EnvironmentObject private var app: AppModel

  private static let spring = Animation.spring(response: 0.4, dampingFraction: 0.86)

  var body: some View {
    let window = AppWindow.current
    let insets = window?.safeAreaInsets ?? .zero
    let bounds = window?.bounds.size ?? AppWindow.bounds.size
    // The mini player's corner (above the mini player when there is one), as padding from the
    // safe area's corner.
    let corner = MiniCorner.frame(window: bounds, insets: insets, tabBar: app.tabBarHeight, rail: app.tabRail)
    let bottom = bounds.height - insets.bottom - corner.maxY + (app.playing != nil ? corner.height + 10 : 0)
    // Tap to open, hold for more. (Swipes on it opened or threw it away by accident.)
    MultiviewDock(model: model, open: open, close: close, closeNow: closeNow)
      .padding(.trailing, max(10, bounds.width - insets.right - corner.maxX))
      .padding(.bottom, max(10, bottom))
  }

  private func open() {
    withAnimation(Self.spring) {
      if app.playing != nil { app.playing = nil }
      app.multiviewMinimized = false
      MultiviewPull.shared.progress = nil
    }
  }

  /// From the dock's own button: at once, fading as it goes (a press, then nothing for a moment,
  /// felt like the tap hadn't taken).
  private func closeNow() {
    withAnimation(.easeOut(duration: 0.25)) { app.closeMultiview() }
  }

  private func close() {
    // After the hold menu has gone (closed from inside it, the dock just vanished): it fades and
    // shrinks away.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      withAnimation(.easeInOut(duration: 0.3)) { app.closeMultiview() }
    }
  }
}

/// Multi-view tucked away: the streamers' pictures in a row (lit up while heard). Tap to open it;
/// hold for more.
struct MultiviewDock: View {
  @ObservedObject var model: MultiviewModel
  var open: () -> Void
  var close: () -> Void
  var closeNow: () -> Void = {}
  /// Pulled up: multi-view grows out of the dock under the finger (see MultiviewPresenter).
  @ObservedObject private var pull = MultiviewPull.shared

  var body: some View {
    HStack(spacing: 6) {
      if model.tiles.isEmpty {
        // Nobody in it yet: say what it is (just an arrow was easy to miss).
        Image(systemName: "rectangle.split.2x2.fill")
          .font(.system(size: 17, weight: .semibold))
          .foregroundColor(.accentTeal)
          .frame(width: 36, height: 40)
        VStack(alignment: .leading, spacing: 0) {
          Text("Multi-view").font(.subheadline.weight(.bold))
          Text("Tap + on streams to add").font(.caption2).foregroundColor(.white.opacity(0.65))
        }
        .lineLimit(1)
        .foregroundColor(.white)
        .padding(.trailing, 2)
      } else if model.tiles.count == 1 {
        DockAvatar(tile: model.tiles[0], model: model)
        VStack(alignment: .leading, spacing: 0) {
          Text("Multi-view").font(.caption.weight(.bold))
          Text("Add more with +").font(.caption2).foregroundColor(.white.opacity(0.65))
        }
        .lineLimit(1)
        .foregroundColor(.white)
      }
      // (Five pictures at most, then how many more: nine didn't fit across a phone.)
      if model.tiles.count > 1 {
        ForEach(model.tiles.prefix(5)) { tile in
          DockAvatar(tile: tile, model: model)
        }
      }
      if model.tiles.count > 5 {
        Text("+\(model.tiles.count - 5)").font(.footnote.weight(.bold)).foregroundColor(.white.opacity(0.85))
          .padding(.horizontal, 2)
      }
      Image(systemName: model.running ? "chevron.up" : "play.fill")
        .font(.system(size: model.running ? 13 : 14, weight: .bold))
        .foregroundColor(model.running ? .white.opacity(0.8) : .accentTeal)
        .frame(width: 26, height: 40)
      // Closes it in one tap (holding the dock or opening multi-view to close it was a chore).
      Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 26)
      Button(action: closeNow) {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(.white.opacity(0.85))
          .frame(width: 40, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(PressableStyle(scale: 0.85))
      .accessibilityLabel("Close multi-view")
    }
    .padding(.leading, 6)
    .padding(.trailing, 2)
    .padding(.vertical, 5)
    .background(.ultraThinMaterial, in: Capsule())
    // The shadow cast by the capsule alone (on the whole dock it was worked out from its contents
    // every frame they changed).
    .background(Capsule().fill(Color.black.opacity(0.45)).shadow(color: .black.opacity(0.45), radius: 10, y: 4))
    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
    .contentShape(Capsule())
    // Fades as multi-view grows out of it.
    .opacity(Double(1 - min(1, (pull.progress ?? 0) * 3)))
    .onTapGesture(perform: open)
    // Pulled up: multi-view grows out of the dock under the finger, and carries on opening (or
    // sinks back) when let go, as the mini player does.
    .simultaneousGesture(
      DragGesture(minimumDistance: 10, coordinateSpace: .global)
        .onChanged { value in
          let up = -value.translation.height
          guard pull.progress != nil || (up > 8 && up > abs(value.translation.width)) else { return }
          let distance = max(300, (AppWindow.current?.bounds.height ?? 800) * 0.6)
          pull.progress = min(1, max(0, up / distance))
        }
        .onEnded { value in
          guard let progress = pull.progress else { return }
          let distance = max(300, (AppWindow.current?.bounds.height ?? 800) * 0.6)
          let flung = -value.predictedEndTranslation.height / distance
          if progress > 0.3 || flung > 0.6 {
            Haptics.tap()
            open()
          } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { pull.progress = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
              if pull.progress == 0 { pull.progress = nil }
            }
          }
        }
    )
    .contextMenu {
      Button(action: open) { Label(model.running ? "Open multi-view" : "Watch them together", systemImage: "rectangle.split.2x2") }
      ForEach(model.tiles) { tile in
        Button(role: .destructive) {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.remove(tile.id) }
          if model.tiles.isEmpty { close() }
        } label: {
          Label("Remove \(tile.channel.name)", systemImage: "minus.circle")
        }
      }
      Button(role: .destructive, action: close) { Label("Close multi-view", systemImage: "xmark") }
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.tiles.map(\.id))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Multi-view: \(model.tiles.map(\.channel.name).joined(separator: ", "))")
    .accessibilityHint(model.running ? "Opens multi-view" : "Starts watching them together")
    .accessibilityAddTraits(.isButton)
  }
}

/// One streamer in the dock: their picture, ringed and with a moving sound badge while it's heard.
private struct DockAvatar: View {
  let tile: MultiviewModel.Tile
  @ObservedObject var model: MultiviewModel

  init(tile: MultiviewModel.Tile, model: MultiviewModel) {
    self.tile = tile
    self.model = model
  }

  // Whether it's heard and playing, looked at once a second. (Watching the stream's player
  // redrew the dock with every one of its updates, several a second per stream: the dock, and
  // what's around it, felt laggy.)
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      face(sounding: model.isSounding(tile.id))
    }
  }

  private func face(sounding: Bool) -> some View {
    Avatar(url: tile.player.channel?.profileImageURL ?? tile.channel.profileImageURL, size: 38)
      .opacity(model.running ? 1 : 0.85)
      .overlay(Circle().stroke(sounding ? Color.accentTeal : Color.white.opacity(0.18), lineWidth: sounding ? 2.5 : 1))
      .overlay(alignment: .bottomTrailing) {
        if sounding {
          SoundBadge().offset(x: 3, y: 3).transition(.scale.combined(with: .opacity))
        }
      }
      .scaleEffect(sounding ? 1.04 : 1)
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: sounding)
  }
}

/// A small moving waveform: this one's being heard.
private struct SoundBadge: View {
  var body: some View {
    Group {
      if #available(iOS 17.0, *) {
        Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
      } else {
        Image(systemName: "waveform")
      }
    }
    .font(.system(size: 8, weight: .heavy))
    .foregroundColor(.black)
    .frame(width: 16, height: 16)
    .background(Color.accentTeal, in: Circle())
    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
  }
}

/// A stream in multi-view, with its hold menu. The menu is put on here, where the player isn't
/// watched: on the picture's own view (redrawn with every stats update) its text flickered.
struct MultiviewTileView: View, Equatable {
  let player: PlayerModel
  let channel: Channel
  let heard: Bool
  /// Its chat is showing (and it's the big one in focus).
  let selected: Bool
  let volume: Float
  /// Another stream is heard too (the menu then offers "only this one").
  let several: Bool
  var tap: () -> Void
  var toggleSound: () -> Void
  var listenOnly: () -> Void
  var setVolume: (Float) -> Void
  var makeMain: () -> Void
  var openInPlayer: () -> Void
  var remove: () -> Void
  /// The other streams, to change places with.
  var others: [Channel] = []
  var swap: (String) -> Void = { _ in }

  static func == (a: Self, b: Self) -> Bool {
    a.player === b.player && a.channel.id == b.channel.id && a.heard == b.heard && a.selected == b.selected
      && a.volume == b.volume && a.several == b.several && a.others.map(\.id) == b.others.map(\.id)
  }

  var body: some View {
    MultiviewTileFace(
      player: player, channel: channel, heard: heard, selected: selected, volume: volume, several: several,
      tap: tap, toggleSound: toggleSound, listenOnly: listenOnly, setVolume: setVolume, makeMain: makeMain,
      openInPlayer: openInPlayer, remove: remove, others: others, swap: swap
    )
    .contextMenu {
      // Built from plain values and redrawn only when they change: the multi-view screen fading its
      // controls a moment after the menu opened rebuilt it once, and its text flashed.
      TileMenu(
        heard: heard, several: several, volume: volume, others: others.map { TileMenu.Other(id: $0.id, name: $0.name) },
        toggleSound: toggleSound, listenOnly: listenOnly, setVolume: setVolume, makeMain: makeMain, swap: swap,
        openInPlayer: openInPlayer, remove: remove
      )
      .equatable()
    }
  }
}

/// A multi-view picture's hold menu.
struct TileMenu: View, Equatable {
  struct Other: Equatable {
    let id: String
    let name: String
  }

  var heard: Bool
  var several: Bool
  var volume: Float
  var others: [Other]
  var toggleSound: () -> Void
  var listenOnly: () -> Void
  var setVolume: (Float) -> Void
  var makeMain: () -> Void
  var swap: (String) -> Void
  var openInPlayer: () -> Void
  var remove: () -> Void

  static func == (a: Self, b: Self) -> Bool {
    a.heard == b.heard && a.several == b.several && a.volume == b.volume && a.others == b.others
  }

  var body: some View {
    Button(action: toggleSound) {
      Label(heard ? "Mute" : "Hear it too", systemImage: heard ? "speaker.slash" : "speaker.plus")
    }
    if several || !heard {
      Button(action: listenOnly) { Label("Hear only this one", systemImage: "speaker.wave.2") }
    }
    Picker(selection: Binding(get: { volume }, set: setVolume)) {
      ForEach(MultiviewModel.volumeSteps, id: \.self) { step in
        Text("\(Int(step * 100))%").tag(step)
      }
    } label: {
      Label("Volume", systemImage: "speaker.wave.1")
    }
    .pickerStyle(.menu)
    Button(action: makeMain) { Label("Make it the big one", systemImage: "rectangle.inset.topleft.filled") }
    if !others.isEmpty {
      Menu {
        ForEach(others, id: \.id) { other in
          Button(other.name) { swap(other.id) }
        }
      } label: {
        Label("Swap places with…", systemImage: "arrow.left.arrow.right")
      }
    }
    Button(action: openInPlayer) { Label("Watch on its own", systemImage: "play.rectangle") }
    Button(role: .destructive, action: remove) { Label("Remove", systemImage: "xmark") }
  }
}

/// One stream in multi-view: the picture, who it is, and whether it's heard.
struct MultiviewTileFace: View {
  @ObservedObject var player: PlayerModel
  let channel: Channel
  let heard: Bool
  /// Its chat is showing (and it's the big one in focus).
  let selected: Bool
  let volume: Float
  /// Another stream is heard too (the menu then offers "only this one").
  let several: Bool
  /// The name, sound button and outline show (they fade with the rest of the controls).
  @Environment(\.multiviewChrome) private var chrome
  var tap: () -> Void
  var toggleSound: () -> Void
  var listenOnly: () -> Void
  var setVolume: (Float) -> Void
  var makeMain: () -> Void
  var openInPlayer: () -> Void
  var remove: () -> Void
  /// The other streams, to change places with.
  var others: [Channel] = []
  var swap: (String) -> Void = { _ in }

  var body: some View {
    ZStack {
      Color.black
      CachedImage(
        url: URL(string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_\(channel.login.lowercased())-640x360.jpg"),
        maxPixels: 640, contentMode: .scaleAspectFit, placeholder: nil
      )
      .opacity(player.phase == .loading ? 0.45 : 0)
      surface
        .opacity(player.phase == .playing ? 1 : 0)
        .allowsHitTesting(false)
      status
      if player.coveringAd {
        ZStack {
          Color.black.opacity(0.92)
          Label("Skipping an ad…", systemImage: "shield.lefthalf.filled").font(.caption.weight(.semibold))
        }
        .foregroundColor(.white)
      }
    }
    .overlay(alignment: .topLeading) {
      nameTag.padding(6)
        .opacity(chrome ? 1 : 0)
        .allowsHitTesting(chrome)
    }
    .overlay(alignment: .bottomLeading) {
      if heard, chrome, let latency = player.latency {
        Label(String(format: "%.1fs", latency), systemImage: "stopwatch")
          .font(.caption2.monospacedDigit())
          .labelStyle(StatLabelStyle())
          .padding(.horizontal, 6).padding(.vertical, 3)
          .background(.black.opacity(0.55), in: Capsule())
          .padding(6)
          .transition(.opacity)
      }
    }
    .overlay {
      Rectangle()
        .strokeBorder(
          chrome && selected ? Color.accentTeal : Color.white.opacity(chrome ? 0.06 : 0), lineWidth: chrome && selected ? 2 : 1
        )
        .allowsHitTesting(false)
    }
    .animation(.easeInOut(duration: 0.3), value: chrome)
    .clipped()
    .contentShape(Rectangle())
    .onTapGesture(count: 2, perform: makeMain)
    .onTapGesture(perform: tap)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(player.channel?.name ?? channel.name)\(heard ? ", sound on" : "")")
  }

  @ViewBuilder
  private var surface: some View {
    #if canImport(AmazonIVSPlayer)
      if let engine = player.kestrelEngine {
        KestrelVideoView(engine: engine, fill: false)
      } else if let controller = player.lowLatency {
        LowLatencyVideoView(controller: controller, fill: false)
      } else {
        ApplePlayerSurface(model: player, fill: false, pictureInPicture: false)
      }
    #else
      if let engine = player.kestrelEngine {
        KestrelVideoView(engine: engine, fill: false)
      } else {
        ApplePlayerSurface(model: player, fill: false, pictureInPicture: false)
      }
    #endif
  }

  @ViewBuilder
  private var status: some View {
    switch player.phase {
    case .loading:
      ProgressView().tint(.white)
    case .offline:
      VStack(spacing: 4) {
        Image(systemName: "moon.zzz.fill")
        Text("Offline").font(.caption.weight(.semibold))
      }
      .foregroundColor(.white.opacity(0.8))
    case .failed:
      Button {
        player.retry()
      } label: {
        Label("Try again", systemImage: "arrow.clockwise").font(.caption.weight(.semibold))
          .padding(.horizontal, 10).padding(.vertical, 6)
          .background(Color.white.opacity(0.15), in: Capsule())
      }
      .foregroundColor(.white)
    case .playing:
      if player.isBuffering && !player.isPaused { ProgressView().tint(.white) }
    }
  }

  /// Who it is, and its sound: tap the speaker to hear it (alongside the others) or mute it.
  private var nameTag: some View {
    HStack(spacing: 4) {
      Avatar(url: player.channel?.profileImageURL ?? channel.profileImageURL, size: 18)
      Text(player.channel?.name ?? channel.name).font(.caption.weight(.bold)).lineLimit(1)
      Button(action: toggleSound) {
        Image(systemName: heard ? (volume < 0.6 ? "speaker.wave.1.fill" : "speaker.wave.2.fill") : "speaker.slash.fill")
          .font(.system(size: 12, weight: .bold))
          .foregroundColor(heard ? .accentTeal : .white.opacity(0.65))
          .frame(width: 32, height: 26)
          .contentShape(Rectangle().inset(by: -8))
      }
      .buttonStyle(PressableStyle(scale: 0.8))
      .accessibilityLabel(heard ? "Mute \(channel.name)" : "Hear \(channel.name) too")
    }
    .foregroundColor(.white)
    .padding(.leading, 3)
    .background(.black.opacity(0.6), in: Capsule())
  }
}

/// Adding streams to multi-view: who you follow that's live, or any channel by name.
struct MultiviewPicker: View {
  @ObservedObject var model: MultiviewModel
  @ObservedObject private var following = FollowingStore.shared
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var looking = false
  @State private var problem: String?

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack(spacing: 8) {
            TextField("Channel name", text: $name)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .submitLabel(.go)
              .onSubmit(addByName)
            if looking {
              ProgressView()
            } else {
              Button("Add", action: addByName)
                .disabled(trimmedName.isEmpty || model.isFull)
            }
          }
          if let problem {
            Text(problem).font(.footnote).foregroundColor(.orange)
          }
        } header: {
          Text("Any channel")
        }

        Section {
          if following.live.isEmpty {
            Text(following.loaded ? "No one you follow is live right now." : "Loading…").foregroundColor(.secondary)
          }
          ForEach(following.live) { stream in
            let added = model.contains(stream.channel)
            Button {
              if added {
                model.remove(stream.channel.id)
              } else {
                model.add(stream.channel)
              }
            } label: {
              HStack(spacing: 12) {
                RemoteImage(url: TwitchAPI.image(stream.previewImageURL, width: 320, height: 180))
                  .aspectRatio(16 / 9, contentMode: .fit)
                  .frame(width: 92)
                  .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                  Text(stream.channel.name).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                  Text(stream.title).font(.caption).foregroundColor(.secondary).lineLimit(1)
                  Text([Format.viewers(stream.viewers) + " watching", stream.category?.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                  .font(.title3)
                  .foregroundColor(added ? .accentTeal : .secondary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!added && model.isFull)
            .opacity(!added && model.isFull ? 0.45 : 1)
          }
        } header: {
          Text("Live now")
        } footer: {
          Text(
            "Up to \(MultiviewModel.maxTiles) streams. Tap a picture for its sound and chat; hold one and drag it onto another to swap them; tap the speaker on a picture to hear it alongside the others (hold a picture for its volume); double-tap to make it the big one. Each picture is fetched only as sharp as it's shown, to spare data."
          )
        }
      }
      .navigationTitle("Add streams")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .task { await following.refreshIfStale() }
    }
    .presentationDetents([.medium, .large])
    .preferredColorScheme(.dark)
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func addByName() {
    // A pasted link works too ("twitch.tv/name").
    let login = trimmedName.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
    guard !login.isEmpty, !model.isFull, !looking else { return }
    looking = true
    problem = nil
    Task {
      defer { looking = false }
      let found = try? await TwitchAPI.shared.users(logins: [login])
      guard let channel = found?.first?.0 else {
        problem = "There's no channel called \(login)."
        return
      }
      guard found?.first?.1 != nil else {
        problem = "\(channel.name) isn't live right now."
        return
      }
      model.add(channel)
      name = ""
    }
  }
}

/// Hands multi-view the view under its pictures: the all-streams Picture in Picture window grows
/// from it and goes back to it.
struct PictureInPictureAnchor: UIViewRepresentable {
  let model: MultiviewModel

  func makeUIView(context: Context) -> AnchorView {
    let view = AnchorView()
    view.isUserInteractionEnabled = false
    view.onWindow = { [weak model] view in model?.setPictureSource(view) }
    return view
  }

  func updateUIView(_ view: AnchorView, context: Context) {}

  static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
    view.onWindow?(nil)
    view.onWindow = nil
  }

  final class AnchorView: UIView {
    var onWindow: (@MainActor (UIView?) -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      onWindow?(window == nil ? nil : self)
    }
  }
}

/// Where the streams' pictures are within their places: 16:9, fitted and centred.
enum StreamPictures {
  static func picture(in place: CGRect) -> CGRect {
    let aspect: CGFloat = 16 / 9
    if place.width / max(place.height, 1) > aspect {
      let width = place.height * aspect
      return CGRect(x: place.midX - width / 2, y: place.minY, width: width, height: place.height)
    }
    let height = place.width / aspect
    return CGRect(x: place.minX, y: place.midY - height / 2, width: place.width, height: height)
  }

  /// The box around all the pictures (nil for none).
  static func box(_ places: [CGRect]) -> CGRect? {
    guard !places.isEmpty else { return nil }
    return places.map(picture(in:)).reduce(CGRect.null) { $0.union($1) }
  }
}

/// Multi-view's controls are showing (each picture's name, sound button and outline with them).
private struct MultiviewChromeKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var multiviewChrome: Bool {
    get { self[MultiviewChromeKey.self] }
    set { self[MultiviewChromeKey.self] = newValue }
  }
}
