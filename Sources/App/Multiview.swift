// Multi-view: up to four live streams at once, laid out like the multi-stream sites (MultiTwitch,
// Twitch Theater): every picture as big as the space allows, one stream heard at a time (tap a
// picture to listen to it and see its chat), a focus layout with one big picture, and each
// picture fetched no sharper than it's shown, to spare data.

import AVKit
import SwiftUI

@MainActor
final class MultiviewModel: ObservableObject {
  struct Tile: Identifiable {
    let channel: Channel
    let player: PlayerModel
    var id: String { channel.id }
  }

  static let maxTiles = 4

  @Published private(set) var tiles: [Tile] = []
  /// The stream being heard (and whose chat shows).
  @Published private(set) var heardID: String?
  @Published private(set) var chat: ChatController?

  nonisolated init() {}

  var isFull: Bool { tiles.count >= Self.maxTiles }

  func contains(_ channel: Channel) -> Bool {
    tiles.contains { $0.channel.id == channel.id || $0.channel.login.lowercased() == channel.login.lowercased() }
  }

  func add(_ channel: Channel) {
    guard !channel.login.isEmpty, !isFull, !contains(channel) else { return }
    let player = PlayerModel(target: .live(channel))
    player.isTile = true
    player.setMuted(heardID != nil)
    tiles.append(Tile(channel: channel, player: player))
    if heardID == nil { listen(to: channel.id) }
    Task { await player.start() }
  }

  func remove(_ id: String) {
    guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
    tiles[index].player.stop()
    tiles.remove(at: index)
    guard heardID == id else { return }
    heardID = nil
    if let first = tiles.first {
      listen(to: first.id)
    } else {
      chat?.stop()
      chat = nil
    }
  }

  /// Hear this stream (the others go quiet) and show its chat.
  func listen(to id: String) {
    guard let tile = tiles.first(where: { $0.id == id }) else { return }
    heardID = id
    for other in tiles { other.player.setMuted(other.id != id) }
    guard chat?.channel.id != tile.channel.id else { return }
    chat?.stop()
    let next = ChatController(channel: tile.channel)
    chat = next
    next.start()
  }

  /// Each stream no sharper than its picture is shown (see `MultiviewLayout.heightCap`).
  func fit(heights: [String: CGFloat], scale: CGFloat) {
    for tile in tiles {
      guard let points = heights[tile.id] else { continue }
      tile.player.setMaxHeight(MultiviewLayout.heightCap(points: points, scale: scale, heard: tile.id == heardID))
    }
  }

  func stopAll() {
    for tile in tiles { tile.player.stop() }
    chat?.stop()
  }
}

struct MultiviewScreen: View {
  let request: MultiviewRequest
  @StateObject private var model = MultiviewModel()
  @StateObject private var keyboard = KeyboardObserver()
  @EnvironmentObject private var app: AppModel
  @Environment(\.displayScale) private var displayScale
  @AppStorage("multiview.chat") private var chatShown = true
  @AppStorage("multiview.focus") private var focus = false
  @State private var picking = false
  @State private var started = false

  private static let spring = Animation.spring(response: 0.4, dampingFraction: 0.86)

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let safeBottom = geometry.safeAreaInsets.bottom
      let landscape = size.width > size.height
      let bar: CGFloat = landscape ? 38 : 44
      let showChat = chatShown && model.chat != nil
      let keyboardSpace = keyboard.overlap > 0 ? max(0, keyboard.overlap + 14 - safeBottom) : 0
      let areas = Self.areas(
        size: size, safeBottom: safeBottom, bar: bar, landscape: landscape, chat: showChat, keyboardSpace: keyboardSpace,
        count: model.tiles.count, focus: focus)
      let rects = layout(in: areas.grid.size)

      ZStack(alignment: .topLeading) {
        Color.black
          .frame(width: size.width, height: size.height + geometry.safeAreaInsets.bottom)
          .onTapGesture { Keyboard.dismiss() }

        if model.tiles.isEmpty {
          emptyState
            .frame(width: areas.grid.width, height: areas.grid.height)
            .offset(x: areas.grid.minX, y: areas.grid.minY)
        }
        ForEach(Array(model.tiles.enumerated()), id: \.element.id) { index, tile in
          let rect = index < rects.count ? rects[index] : .zero
          MultiviewTileView(
            player: tile.player, channel: tile.channel, heard: tile.id == model.heardID,
            listen: { withAnimation(Self.spring) { model.listen(to: tile.id) } },
            makeMain: {
              withAnimation(Self.spring) {
                model.listen(to: tile.id)
                focus = true
              }
            },
            openInPlayer: { app.playing = .live(tile.channel) },
            remove: { withAnimation(Self.spring) { model.remove(tile.id) } }
          )
          .frame(width: rect.width, height: rect.height)
          .offset(x: areas.grid.minX + rect.minX, y: areas.grid.minY + rect.minY)
          .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }

        if let chat = model.chat, showChat {
          // Down to the window's bottom edge, like the player's chat: the message box keeps clear
          // of the home indicator and the keyboard by padding.
          chatColumn(chat, bottomInset: keyboard.overlap > 0 ? keyboard.overlap + 14 : safeBottom, safeBottom: safeBottom)
            .frame(width: areas.chat.width, height: areas.chat.height)
            .offset(x: areas.chat.minX, y: areas.chat.minY)
            .transition(.move(edge: landscape ? .trailing : .bottom).combined(with: .opacity))
        }

        topBar
          .frame(width: areas.bar.width, height: areas.bar.height)
          .offset(x: areas.bar.minX, y: areas.bar.minY)
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
    }
    .ignoresSafeArea(.keyboard)
    .background(Color.black.ignoresSafeArea())
    .preferredColorScheme(.dark)
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .sheet(isPresented: $picking) { MultiviewPicker(model: model) }
    .task {
      guard !started else { return }
      started = true
      OrientationLock.playerVisible(true)
      for channel in request.channels { model.add(channel) }
      // Opened with one stream (or none): straight to picking the others.
      if request.channels.count < 2 { picking = true }
    }
    .onDisappear {
      model.stopAll()
      if app.playing == nil { OrientationLock.playerVisible(false) }
    }
  }

  // MARK: Layout

  private struct Areas {
    var bar: CGRect
    var grid: CGRect
    var chat: CGRect
  }

  /// Landscape: the pictures with the bar over them, chat in a column on the right. Portrait: the
  /// bar, the pictures (no taller than they need), chat under them (room kept above the keyboard).
  private static func areas(
    size: CGSize, safeBottom: CGFloat, bar: CGFloat, landscape: Bool, chat: Bool, keyboardSpace: CGFloat, count: Int,
    focus: Bool
  ) -> Areas {
    if landscape {
      let chatWidth = chat ? min(max(size.width * 0.3, 250), 380).rounded() : 0
      let gridWidth = size.width - chatWidth - (chat ? 1 : 0)
      return Areas(
        bar: CGRect(x: 0, y: 0, width: gridWidth, height: bar),
        grid: CGRect(x: 0, y: bar, width: gridWidth, height: size.height - bar),
        chat: CGRect(x: size.width - chatWidth, y: 0, width: chatWidth, height: size.height + safeBottom))
    }
    let below = size.height - bar
    guard chat else {
      return Areas(
        bar: CGRect(x: 0, y: 0, width: size.width, height: bar), grid: CGRect(x: 0, y: bar, width: size.width, height: below),
        chat: .zero)
    }
    // As tall as the pictures need, leaving chat at least a little room (more without the keyboard).
    let roomForChat: CGFloat = keyboardSpace > 0 ? 150 : 230
    let limit = max(100, min(below * 0.66, below - keyboardSpace - roomForChat))
    let probe = CGSize(width: size.width, height: limit)
    let rects =
      focus && count > 1 ? MultiviewLayout.focus(count: count, main: 0, in: probe) : MultiviewLayout.grid(count: count, in: probe)
    let used = rects.isEmpty ? min(limit, (size.width * 9 / 16).rounded()) : (rects.map(\.maxY).max() ?? 0) - (rects.map(\.minY).min() ?? 0)
    let gridHeight = max(100, min(limit, used))
    return Areas(
      bar: CGRect(x: 0, y: 0, width: size.width, height: bar),
      grid: CGRect(x: 0, y: bar, width: size.width, height: gridHeight),
      chat: CGRect(x: 0, y: bar + gridHeight + 1, width: size.width, height: max(0, below - gridHeight - 1 + safeBottom)))
  }

  private func layout(in size: CGSize) -> [CGRect] {
    let count = model.tiles.count
    if focus, count > 1 {
      let main = model.tiles.firstIndex { $0.id == model.heardID } ?? 0
      return MultiviewLayout.focus(count: count, main: main, in: size)
    }
    return MultiviewLayout.grid(count: count, in: size)
  }

  private func capsKey(_ rects: [CGRect]) -> String {
    zip(model.tiles, rects).map { "\($0.id):\(Int($1.height))" }.joined(separator: ",") + "|\(model.heardID ?? "")"
  }

  // MARK: Pieces

  private var topBar: some View {
    HStack(spacing: 2) {
      barButton("chevron.down", label: "Close multi-view") { app.multiview = nil }
      Text("Multi-view").font(.headline)
      Text("\(model.tiles.count)/\(MultiviewModel.maxTiles)").font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
        .padding(.leading, 4)
      Spacer(minLength: 4)
      if model.tiles.count > 1 {
        barButton(
          focus ? "rectangle.grid.2x2" : "rectangle.inset.topleft.filled",
          label: focus ? "Equal sizes" : "One big picture"
        ) { focus.toggle() }
      }
      if model.chat != nil {
        barButton(chatShown ? "bubble.left.fill" : "bubble.left", label: chatShown ? "Hide chat" : "Show chat", highlighted: chatShown) {
          chatShown.toggle()
        }
      }
      barButton("plus", label: "Add a stream") { picking = true }
        .disabled(model.isFull)
        .opacity(model.isFull ? 0.4 : 1)
    }
    .padding(.horizontal, 6)
    .foregroundColor(.white)
    .background(Color.black.opacity(0.85))
  }

  private func barButton(_ icon: String, label: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 17, weight: .semibold))
        .foregroundColor(highlighted ? .accentTeal : .white)
        .frame(width: 40, height: 36)
        .contentShape(Rectangle())
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
      Text("Tap a picture to hear it and see its chat; double-tap to make it the big one.")
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

/// One stream in multi-view: the picture, who it is, and whether it's the one being heard.
struct MultiviewTileView: View {
  @ObservedObject var player: PlayerModel
  let channel: Channel
  let heard: Bool
  var listen: () -> Void
  var makeMain: () -> Void
  var openInPlayer: () -> Void
  var remove: () -> Void

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
    .overlay(alignment: .topLeading) { nameTag.padding(6) }
    .overlay(alignment: .bottomLeading) {
      if heard, let latency = player.latency {
        Label(String(format: "%.1fs", latency), systemImage: "stopwatch")
          .font(.caption2.monospacedDigit())
          .labelStyle(StatLabelStyle())
          .padding(.horizontal, 6).padding(.vertical, 3)
          .background(.black.opacity(0.55), in: Capsule())
          .padding(6)
      }
    }
    .overlay {
      Rectangle()
        .strokeBorder(heard ? Color.accentTeal : Color.white.opacity(0.06), lineWidth: heard ? 2 : 1)
        .allowsHitTesting(false)
    }
    .clipped()
    .contentShape(Rectangle())
    .onTapGesture(count: 2, perform: makeMain)
    .onTapGesture(perform: listen)
    .contextMenu {
      if !heard {
        Button(action: listen) { Label("Listen", systemImage: "speaker.wave.2") }
      }
      Button(action: makeMain) { Label("Make it the big one", systemImage: "rectangle.inset.topleft.filled") }
      Button(action: openInPlayer) { Label("Watch on its own", systemImage: "play.rectangle") }
      Button(role: .destructive, action: remove) { Label("Remove", systemImage: "xmark") }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(player.channel?.name ?? channel.name)\(heard ? ", playing sound" : "")")
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private var surface: some View {
    #if canImport(AmazonIVSPlayer)
      if let controller = player.lowLatency {
        LowLatencyVideoView(controller: controller, fill: false)
      } else {
        ApplePlayerSurface(model: player, fill: false, pictureInPicture: false)
      }
    #else
      ApplePlayerSurface(model: player, fill: false, pictureInPicture: false)
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

  private var nameTag: some View {
    HStack(spacing: 5) {
      Avatar(url: player.channel?.profileImageURL ?? channel.profileImageURL, size: 18)
      Text(player.channel?.name ?? channel.name).font(.caption.weight(.bold)).lineLimit(1)
      Image(systemName: heard ? "speaker.wave.2.fill" : "speaker.slash.fill")
        .font(.system(size: 9, weight: .bold))
        .foregroundColor(heard ? .accentTeal : .white.opacity(0.6))
    }
    .foregroundColor(.white)
    .padding(.leading, 3).padding(.trailing, 7).padding(.vertical, 3)
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
            "Up to \(MultiviewModel.maxTiles) streams. Tap a picture to hear it and see its chat, double-tap it to make it the big one, hold it for more. Each picture is fetched only as sharp as it's shown, to spare data."
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
