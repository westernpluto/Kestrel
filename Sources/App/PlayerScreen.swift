// The watch screen, laid out like Twitch's app: video on top with controls that fade in on a
// tap (settings behind a gear: quality, low latency, video stats), chat below in portrait and
// beside the video in landscape.

import AVKit
import SwiftUI

// MARK: - Apple player surface

final class PlayerLayerView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// AVPlayer on a plain layer (Kestrel draws its own controls), with Picture in Picture and
/// audio that keeps playing in the background.
struct ApplePlayerSurface: UIViewRepresentable {
  let model: PlayerModel
  var fill: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.backgroundColor = .black
    view.playerLayer.player = model.player
    view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    context.coordinator.view = view
    context.coordinator.player = model.player
    if AVPictureInPictureController.isPictureInPictureSupported(),
      let pip = AVPictureInPictureController(playerLayer: view.playerLayer)
    {
      pip.canStartPictureInPictureAutomaticallyFromInline = true
      pip.delegate = context.coordinator
      context.coordinator.pip = pip
      model.applePictureInPicture = pip
    }
    return view
  }

  func updateUIView(_ view: PlayerLayerView, context: Context) {
    let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
    if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
  }

  final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
    weak var view: PlayerLayerView?
    weak var player: AVPlayer?
    var pip: AVPictureInPictureController?
    private var pictureInPicture = false
    private var detached = false
    private var tokens: [NSObjectProtocol] = []

    override init() {
      super.init()
      let center = NotificationCenter.default
      tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        self?.enteredBackground()
      })
      tokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
        self?.enteringForeground()
      })
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    /// Taking the player off the layer keeps the sound going in the background.
    private func enteredBackground() {
      guard !pictureInPicture else { return }
      if AppSettings.shared.backgroundAudio {
        detached = true
        view?.playerLayer.player = nil
      } else {
        player?.pause()
      }
    }

    private func enteringForeground() {
      guard detached else { return }
      detached = false
      view?.playerLayer.player = player
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) { pictureInPicture = true }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) { pictureInPicture = false }
    func pictureInPictureController(
      _ controller: AVPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) { completionHandler(true) }
  }
}

struct AirPlayButton: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.tintColor = .white
    view.activeTintColor = UIColor(red: 0.16, green: 0.78, blue: 0.72, alpha: 1)
    view.prioritizesVideoDevices = true
    return view
  }
  func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Browsing stays portrait; the player turns with the phone. The full-screen button and swipes
/// force an orientation, which then holds until the phone is physically turned that way (so
/// tapping full screen while holding the phone upright doesn't flip straight back).
enum OrientationLock {
  /// Read by `AppDelegate`.
  static private(set) var mask: UIInterfaceOrientationMask = .portrait
  private static var playerActive = false
  private static var forced: UIInterfaceOrientationMask?
  private static var observer: NSObjectProtocol?

  static func playerVisible(_ visible: Bool) {
    playerActive = visible
    forced = nil
    if visible {
      startObserving()
      apply(.allButUpsideDown, rotateTo: nil)
    } else {
      apply(.portrait, rotateTo: .portrait)
    }
  }

  /// `.portrait` or `.landscape`.
  static func force(_ orientation: UIInterfaceOrientationMask) {
    forced = orientation
    if orientation == .portrait {
      apply(.portrait, rotateTo: .portrait)
    } else {
      // Turn toward the side the phone is already tipped to, if any.
      let side: UIInterfaceOrientationMask = UIDevice.current.orientation == .landscapeRight ? .landscapeLeft : .landscapeRight
      apply(.landscape, rotateTo: side)
    }
  }

  private static func startObserving() {
    guard observer == nil else { return }
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    observer = NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
    ) { _ in releaseIfTurned() }
  }

  private static func releaseIfTurned() {
    guard playerActive, let forced else { return }
    let matches: Bool
    switch UIDevice.current.orientation {
    case .portrait: matches = forced == .portrait
    case .landscapeLeft, .landscapeRight: matches = forced == .landscape
    default: return
    }
    guard matches else { return }
    self.forced = nil
    apply(.allButUpsideDown, rotateTo: nil)
  }

  private static func apply(_ newMask: UIInterfaceOrientationMask, rotateTo target: UIInterfaceOrientationMask?) {
    mask = newMask
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
    for window in scene.windows {
      var controller = window.rootViewController
      while let current = controller {
        current.setNeedsUpdateOfSupportedInterfaceOrientations()
        controller = current.presentedViewController
      }
    }
    if let target { scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in } }
  }
}

// MARK: - Screen

struct PlayerScreen: View {
  let target: PlaybackTarget
  @StateObject private var model: PlayerModel
  @StateObject private var chat: ChatController
  @Environment(\.dismiss) private var dismiss
  @AppStorage("landscapeChat") private var landscapeChat = true

  init(target: PlaybackTarget) {
    self.target = target
    _model = StateObject(wrappedValue: PlayerModel(target: target))
    let channel: Channel
    switch target {
    case .live(let c): channel = c
    case .video(let video): channel = video.owner ?? Channel(id: "", login: "", displayName: "", profileImageURL: nil)
    }
    _chat = StateObject(wrappedValue: ChatController(channel: channel))
  }

  var body: some View {
    // The reader sits inside the safe area, so in landscape the video never reaches under the
    // Dynamic Island; only the black background runs edge to edge.
    GeometryReader { geometry in
      let landscape = geometry.size.width > geometry.size.height
      Group {
        if landscape {
          landscapeLayout(width: geometry.size.width)
        } else {
          portraitLayout
        }
      }
      .statusBarHidden(landscape)
      .persistentSystemOverlays(landscape ? .hidden : .automatic)
    }
    .background(Color.black.ignoresSafeArea())
    .preferredColorScheme(.dark)
    .task {
      OrientationLock.playerVisible(true)
      if model.isLive { chat.start() }
      await model.start()
    }
    .onDisappear {
      model.stop()
      chat.stop()
      OrientationLock.playerVisible(false)
    }
  }

  private var chatOpen: Bool { model.isLive && landscapeChat }

  private func landscapeLayout(width: CGFloat) -> some View {
    HStack(spacing: 0) {
      PlayerVideoArea(
        model: model, landscape: true, chatOpen: chatOpen,
        toggleChat: { withAnimation(.easeInOut(duration: 0.22)) { landscapeChat.toggle() } }, close: close)
        // Full height (into the home-indicator strip); the width stays inside the safe area.
        .ignoresSafeArea(.container, edges: .vertical)
        .ignoresSafeArea(.keyboard)
      if chatOpen {
        ChatPanel(chat: chat)
          .frame(width: min(340, width * 0.36))
          .background(Color(white: 0.07).ignoresSafeArea())
          .transition(.move(edge: .trailing))
      }
    }
  }

  private var portraitLayout: some View {
    VStack(spacing: 0) {
      PlayerVideoArea(model: model, landscape: false, chatOpen: false, toggleChat: {}, close: close)
        .aspectRatio(16 / 9, contentMode: .fit)
      StreamInfoBar(model: model, target: target)
      Divider().overlay(Color.white.opacity(0.08))
      if model.isLive {
        ChatPanel(chat: chat)
      } else {
        VideoDetails(target: target)
      }
    }
  }

  private func close() { dismiss() }
}

// MARK: - Video with controls and gestures

struct PlayerVideoArea: View {
  @ObservedObject var model: PlayerModel
  var landscape: Bool
  var chatOpen: Bool
  var toggleChat: () -> Void
  var close: () -> Void
  @EnvironmentObject private var settings: AppSettings
  @State private var controlsVisible = true
  @State private var hideTask: Task<Void, Never>?
  /// A pinch also moves the fingers; don't read it as a swipe.
  @State private var lastPinch = Date.distantPast

  var body: some View {
    ZStack {
      Color.black
      surface
      // Gestures live on this layer, under everything that can be tapped.
      Color.black.opacity(0.001)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { doubleTap() }
        .onTapGesture { toggleControls() }
        .gesture(swipe)
        .simultaneousGesture(zoom)
      statusOverlay
      if settings.showVideoStats && !model.stats.isEmpty {
        StatsOverlay(lines: model.stats).padding(.top, controlsShown ? 44 : 0)
      }
      PlayerControls(
        model: model, landscape: landscape, chatOpen: chatOpen, visible: controlsShown,
        toggleChat: toggleChat, close: close, interacted: { scheduleHide(after: $0) })
    }
    .clipped()
    .onAppear { scheduleHide(after: 3.5) }
  }

  private var controlsShown: Bool { controlsVisible || model.isPaused || model.phase != .playing }

  @ViewBuilder
  private var surface: some View {
    #if canImport(AmazonIVSPlayer)
      if let controller = model.lowLatency {
        LowLatencyVideoView(controller: controller, fill: model.fillsScreen)
      } else {
        ApplePlayerSurface(model: model, fill: model.fillsScreen)
      }
    #else
      ApplePlayerSurface(model: model, fill: model.fillsScreen)
    #endif
  }

  @ViewBuilder
  private var statusOverlay: some View {
    switch model.phase {
    case .loading:
      ProgressView().tint(.white).scaleEffect(1.2).allowsHitTesting(false)
    case .offline:
      card(icon: "moon.zzz.fill", title: "Offline", message: "\(model.channel?.name ?? "This channel") isn't live right now.")
        .allowsHitTesting(false)
    case .failed(let message):
      VStack(spacing: 12) {
        card(icon: "exclamationmark.triangle.fill", title: "Couldn't play", message: message).allowsHitTesting(false)
        Button("Try again") { model.retry() }.buttonStyle(.borderedProminent).tint(.accentTeal)
      }
    case .playing:
      if model.coveringAd {
        ZStack {
          Color.black.opacity(0.92)
          VStack(spacing: 6) {
            ProgressView().tint(.white)
            Text("Skipping an ad…").font(.subheadline.weight(.semibold))
            Text("The stream continues as soon as it's over.").font(.caption).foregroundColor(.secondary)
          }
          .foregroundColor(.white)
        }
        .allowsHitTesting(false)
      } else if model.isBuffering && !model.isPaused {
        ProgressView().tint(.white).scaleEffect(1.2).allowsHitTesting(false)
      }
    }
  }

  private func card(icon: String, title: String, message: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: icon).font(.title)
      Text(title).font(.headline)
      Text(message).font(.footnote).multilineTextAlignment(.center).foregroundColor(.secondary)
    }
    .foregroundColor(.white)
    .padding(24)
  }

  // MARK: Gestures

  /// Swipe down: close (portrait) or leave full screen. Swipe up: full screen. Sideways in
  /// landscape: show or hide chat.
  private var swipe: some Gesture {
    DragGesture(minimumDistance: 24).onEnded { value in
      guard Date().timeIntervalSince(lastPinch) > 0.5 else { return }
      let dx = value.translation.width, dy = value.translation.height
      if abs(dy) > abs(dx) {
        if dy > 70 {
          landscape ? OrientationLock.force(.portrait) : close()
        } else if dy < -70, !landscape {
          OrientationLock.force(.landscape)
        }
      } else if landscape, model.isLive {
        if dx < -60, !chatOpen { toggleChat() }
        if dx > 60, chatOpen { toggleChat() }
      }
    }
  }

  /// Pinch out to fill the screen (crops the sides), in to fit.
  private var zoom: some Gesture {
    MagnificationGesture()
      .onChanged { _ in lastPinch = Date() }
      .onEnded { scale in
        lastPinch = Date()
        if scale > 1.08 { withAnimation { model.setFill(true) } }
        if scale < 0.92 { withAnimation { model.setFill(false) } }
      }
  }

  private func doubleTap() {
    if landscape {
      withAnimation { model.setFill(!model.fillsScreen) }
    } else {
      OrientationLock.force(.landscape)
    }
  }

  private func toggleControls() {
    if controlsVisible {
      hideTask?.cancel()
      withAnimation(.easeInOut(duration: 0.18)) { controlsVisible = false }
    } else {
      withAnimation(.easeInOut(duration: 0.18)) { controlsVisible = true }
      scheduleHide(after: 3.5)
    }
  }

  /// Controls fade out after a few seconds without a touch (longer after opening the menu).
  private func scheduleHide(after seconds: Double) {
    hideTask?.cancel()
    controlsVisible = true
    hideTask = Task {
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
    }
  }
}

// MARK: - Controls

struct PlayerControls: View {
  @ObservedObject var model: PlayerModel
  var landscape: Bool
  var chatOpen: Bool
  var visible: Bool
  var toggleChat: () -> Void
  var close: () -> Void
  /// Keeps the controls up for this many more seconds.
  var interacted: (Double) -> Void
  @EnvironmentObject private var settings: AppSettings
  @State private var scrubbing: Double?

  var body: some View {
    ZStack {
      LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
      VStack(spacing: 0) {
        topBar
        Spacer()
        bottomBar
      }
      .padding(.horizontal, landscape ? 12 : 6)
      .padding(.top, landscape ? 8 : 2)
      .padding(.bottom, landscape ? 16 : 2)
      if model.phase == .playing && !model.coveringAd {
        Button {
          model.togglePause()
          interacted(3.5)
        } label: {
          Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            .font(.system(size: landscape ? 34 : 28, weight: .semibold))
            .frame(width: 64, height: 64)
            .background(.black.opacity(0.35), in: Circle())
        }
        .accessibilityLabel(model.isPaused ? "Play" : "Pause")
      }
    }
    .foregroundColor(.white)
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
  }

  private var topBar: some View {
    HStack(spacing: 2) {
      button("chevron.down", label: landscape ? "Exit full screen" : "Close") {
        landscape ? OrientationLock.force(.portrait) : close()
      }
      if landscape {
        VStack(alignment: .leading, spacing: 1) {
          Text(model.channel?.name ?? "").font(.subheadline.weight(.bold))
          if let title = model.stream?.title, !title.isEmpty {
            Text(title).font(.caption).foregroundColor(.white.opacity(0.75))
          }
        }
        .lineLimit(1)
        .padding(.leading, 4)
      }
      Spacer(minLength: 8)
      AirPlayButton().frame(width: 40, height: 40)
      if AVPictureInPictureController.isPictureInPictureSupported() {
        button(model.pictureInPictureActive ? "pip.exit" : "pip.enter", label: "Picture in Picture") {
          model.togglePictureInPicture()
        }
      }
      settingsMenu
    }
  }

  private var settingsMenu: some View {
    Menu {
      if model.qualities.count > 1 {
        Menu {
          Picker("Quality", selection: Binding(get: { model.selectedQuality }, set: { id in
            if let quality = model.qualities.first(where: { $0.id == id }) { model.selectQuality(quality) }
          })) {
            ForEach(model.qualities) { Text($0.label).tag($0.id) }
          }
        } label: {
          Label("Quality · \(model.qualities.first { $0.id == model.selectedQuality }?.label ?? "Auto")", systemImage: "slider.horizontal.3")
        }
      }
      if model.isLive && model.canToggleLowLatency {
        Toggle(isOn: Binding(get: { settings.lowLatency }, set: { model.setLowLatency($0) })) {
          Label("Low latency", systemImage: "bolt")
        }
      }
      Toggle(isOn: $settings.showVideoStats) {
        Label("Video stats", systemImage: "chart.bar.xaxis")
      }
    } label: {
      Image(systemName: "gearshape.fill")
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .accessibilityLabel("Settings")
    .simultaneousGesture(TapGesture().onEnded { interacted(12) })
  }

  @ViewBuilder
  private var bottomBar: some View {
    VStack(spacing: 4) {
      if !model.isLive, model.duration > 0 {
        Slider(
          value: Binding(get: { scrubbing ?? model.position }, set: { scrubbing = $0; interacted(3.5) }),
          in: 0...model.duration
        ) { editing in
          if !editing, let target = scrubbing {
            model.seek(to: target)
            scrubbing = nil
          }
        }
        .tint(.accentTeal)
      }
      HStack(spacing: 10) {
        if model.isLive {
          Button {
            model.goLive()
            interacted(3.5)
          } label: {
            HStack(spacing: 6) {
              Text("LIVE").font(.caption.weight(.heavy))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(atLiveEdge ? Color.liveRed : Color.gray, in: RoundedRectangle(cornerRadius: 4))
              if let latency = model.latency {
                Text(String(format: "%.1fs", latency)).font(.caption.monospacedDigit()).foregroundColor(.white.opacity(0.85))
              }
            }
          }
          .accessibilityLabel("Jump to live")
          if let viewers = model.stream?.viewers {
            Label(Format.viewers(viewers), systemImage: "person.fill").font(.caption.monospacedDigit())
              .labelStyle(.titleAndIcon).foregroundColor(.white.opacity(0.85))
          }
          adBadge
        } else {
          Text("\(Format.duration(Int(scrubbing ?? model.position))) / \(Format.duration(Int(model.duration)))")
            .font(.caption.monospacedDigit())
        }
        Spacer()
        if landscape && model.isLive {
          button(chatOpen ? "bubble.left.fill" : "bubble.left", label: chatOpen ? "Hide chat" : "Show chat", action: toggleChat)
        }
        button(
          landscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
          label: landscape ? "Exit full screen" : "Full screen"
        ) {
          OrientationLock.force(landscape ? .portrait : .landscape)
        }
      }
    }
  }

  private var atLiveEdge: Bool { (model.latency ?? 0) < (settings.lowLatency ? 6 : 15) }

  @ViewBuilder
  private var adBadge: some View {
    switch model.adState {
    case .skipped, .replaced:
      Label("Ad blocked", systemImage: "checkmark.shield.fill").font(.caption2.weight(.semibold)).foregroundColor(.accentTeal)
    case .searching, .covering:
      Label("Ad", systemImage: "shield.lefthalf.filled").font(.caption2.weight(.semibold)).foregroundColor(.orange)
    case .none:
      EmptyView()
    }
  }

  private func button(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
    Button {
      action()
      interacted(3.5)
    } label: {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .accessibilityLabel(label)
  }
}

// MARK: - Below the video (portrait)

struct StreamInfoBar: View {
  @ObservedObject var model: PlayerModel
  let target: PlaybackTarget
  @EnvironmentObject private var favorites: FavoritesStore
  @ObservedObject private var following = FollowingStore.shared

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Avatar(url: model.channel?.profileImageURL, size: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
        HStack(spacing: 4) {
          Text(model.channel?.name ?? "").font(.footnote.weight(.semibold)).foregroundColor(.white.opacity(0.85))
          if let category = model.stream?.category?.name {
            Text("· \(category)").font(.footnote).foregroundColor(.accentTeal)
          }
          if model.isLive, let uptime = Format.uptime(since: model.stream?.startedAt) {
            Text("· \(uptime)").font(.footnote.monospacedDigit()).foregroundColor(.secondary)
          }
        }
        .lineLimit(1)
      }
      Spacer(minLength: 4)
      if let channel = model.channel, !channel.id.isEmpty {
        if following.twitchFollowIDs.contains(channel.id) {
          Image(systemName: "heart.fill").font(.title3).foregroundColor(.accentTeal)
            .accessibilityLabel("Following on Twitch")
        } else {
          Button {
            favorites.toggle(channel)
          } label: {
            Image(systemName: favorites.contains(channel) ? "heart.fill" : "heart")
              .font(.title3)
              .foregroundColor(favorites.contains(channel) ? .liveRed : .white)
          }
          .accessibilityLabel(favorites.contains(channel) ? "Remove from Following" : "Add to Following")
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var title: String {
    switch target {
    case .live: return model.stream?.title ?? model.channel?.name ?? ""
    case .video(let video): return video.title
    }
  }
}

struct VideoDetails: View {
  let target: PlaybackTarget

  var body: some View {
    ScrollView {
      if case .video(let video) = target {
        VStack(alignment: .leading, spacing: 6) {
          Text(video.title).font(.headline)
          Text([video.categoryName, Format.relative(video.createdAt), "\(Format.viewers(video.viewCount)) views"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
    }
  }
}
