// The video with its controls and gestures, the seek bar (with preview thumbnails) and what sits
// under the video in portrait.

import AVKit
import SwiftUI

// MARK: - Video with controls and gestures

struct PlayerVideoArea: View {
  @ObservedObject var model: PlayerModel
  var landscape: Bool
  var chatOpen: Bool
  var controlInsets: EdgeInsets
  /// False while the player shrinks into (or is) the mini player.
  var chromeVisible: Bool = true
  /// In the mini player (its own overlay takes the touches).
  var minimized: Bool = false
  var toggleChat: () -> Void
  var minimize: () -> Void
  /// Pulling the video down (portrait): how far, then where it was let go (and where it was headed).
  var onPull: (CGFloat) -> Void = { _ in }
  var onPullEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
  @EnvironmentObject private var settings: AppSettings
  @State private var controlsVisible = true
  @State private var hideTask: Task<Void, Never>?
  /// A pinch also moves the fingers; don't read it as a swipe.
  @State private var lastPinch = Date.distantPast
  @State private var pulling = false

  var body: some View {
    ZStack {
      Color.black
      poster
      surface
      // Gestures live on this layer, under everything that can be tapped.
      Color.black.opacity(0.001)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { doubleTap() }
        .onTapGesture { toggleControls() }
        .gesture(swipe)
        .simultaneousGesture(zoom)
        // Keyed to the minimized state, not the animation, so a pull in progress keeps its touch.
        .allowsHitTesting(!minimized)
      statusOverlay
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.coveringAd)
      if settings.showVideoStats && !model.stats.isEmpty && chromeVisible {
        StatsOverlay(lines: model.stats)
          .padding(.top, controlsShown ? 44 : 0)
          .padding(.leading, controlInsets.leading)
          .padding(.top, controlInsets.top)
          .transition(.opacity)
      }
      PlayerControls(
        model: model, landscape: landscape, chatOpen: chatOpen, visible: controlsShown && chromeVisible && !pulling,
        insets: controlInsets, toggleChat: toggleChat, minimize: minimize, interacted: { scheduleHide(after: $0) })
      if let resumed = model.resumedAt, chromeVisible {
        resumeNotice(resumed)
          .padding(.leading, controlInsets.leading + 8)
          .padding(.bottom, controlInsets.bottom + (controlsShown ? 78 : 10))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
          .animation(.easeInOut(duration: 0.2), value: controlsShown)
      }
    }
    .clipped()
    .onAppear { scheduleHide(after: 3.5) }
  }

  private var controlsShown: Bool { controlsVisible || model.isPaused || model.phase != .playing }

  /// "Resumed at 1:23:45 · Start over"
  private func resumeNotice(_ position: Double) -> some View {
    HStack(spacing: 8) {
      Text("Resumed at \(Format.duration(Int(position)))").foregroundColor(.white.opacity(0.9))
      Button("Start over") { model.startOver() }
        .foregroundColor(.accentTeal)
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 10).padding(.vertical, 6)
    .background(.black.opacity(0.7), in: Capsule())
  }

  /// The stream's thumbnail while it loads, so opening a stream doesn't start on black.
  private var poster: some View {
    CachedImage(url: posterURL, maxPixels: 960, contentMode: .scaleAspectFit, placeholder: nil)
      .opacity(model.phase == .loading ? 0.5 : 0)
      .animation(.easeOut(duration: 0.35), value: model.phase)
      .allowsHitTesting(false)
  }

  private var posterURL: URL? {
    switch model.target {
    case .live(let channel):
      return URL(string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_\(channel.login.lowercased())-640x360.jpg")
    case .video(let video):
      return TwitchAPI.image(video.previewURL, width: 640, height: 360)
    }
  }

  @ViewBuilder
  private var surface: some View {
    ZStack {
      #if canImport(AmazonIVSPlayer)
        if let controller = model.lowLatency {
          LowLatencyVideoView(controller: controller, fill: model.fillsScreen)
        } else {
          ApplePlayerSurface(model: model, fill: model.fillsScreen)
        }
      #else
        ApplePlayerSurface(model: model, fill: model.fillsScreen)
      #endif
      // Rewinding: the broadcast's VOD plays on top; the live player stays underneath, paused.
      if model.rewind != nil {
        ApplePlayerSurface(model: model, role: .rewind, fill: model.fillsScreen)
          .opacity(model.isRewinding ? 1 : 0)
          .animation(.easeInOut(duration: 0.2), value: model.isRewinding)
      }
    }
    .opacity(model.phase == .playing ? 1 : 0)
    .animation(.easeIn(duration: 0.3), value: model.phase)
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private var statusOverlay: some View {
    switch model.phase {
    case .loading:
      ProgressView().tint(.white).scaleEffect(1.2).allowsHitTesting(false)
    case .offline:
      card(icon: "moon.zzz.fill", title: "Offline", message: "\(model.channel?.name ?? "This channel") isn't live right now.")
        .allowsHitTesting(false)
        .transition(.opacity)
    case .failed(let message):
      VStack(spacing: 12) {
        card(icon: "exclamationmark.triangle.fill", title: "Couldn't play", message: message).allowsHitTesting(false)
        Button("Try again") { model.retry() }.buttonStyle(.borderedProminent).tint(.accentTeal)
      }
      .transition(.opacity)
    case .playing:
      if model.coveringAd {
        ZStack {
          Color.black.opacity(0.92)
          VStack(spacing: 6) {
            ProgressView().tint(.white)
            Text("Skipping an ad…").font(.subheadline.weight(.semibold))
          }
          .foregroundColor(.white)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
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

  /// Pull down (portrait): the player shrinks with your finger into the mini player. Swipe down
  /// in landscape: leave full screen. Swipe up: full screen. Sideways in landscape: chat.
  private var swipe: some Gesture {
    DragGesture(minimumDistance: 14)
      .onChanged { value in
        guard !landscape, Date().timeIntervalSince(lastPinch) > 0.5 else { return }
        let dx = value.translation.width, dy = value.translation.height
        if pulling || (dy > 8 && dy > abs(dx) * 1.2) {
          pulling = true
          onPull(max(0, dy))
        }
      }
      .onEnded { value in
        let dx = value.translation.width, dy = value.translation.height
        if pulling {
          pulling = false
          onPullEnd(dy, value.predictedEndTranslation.height)
          return
        }
        guard Date().timeIntervalSince(lastPinch) > 0.5 else { return }
        if abs(dy) > abs(dx) {
          if dy > 70, landscape {
            OrientationLock.force(.portrait)
          } else if dy < -70, !landscape {
            OrientationLock.force(.landscape)
          }
        } else if landscape {
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
        if scale > 1.08 { withAnimation(.easeInOut(duration: 0.25)) { model.setFill(true) } }
        if scale < 0.92 { withAnimation(.easeInOut(duration: 0.25)) { model.setFill(false) } }
      }
  }

  private func doubleTap() {
    if landscape {
      withAnimation(.easeInOut(duration: 0.25)) { model.setFill(!model.fillsScreen) }
    } else {
      OrientationLock.force(.landscape)
    }
  }

  private func toggleControls() {
    if controlsVisible {
      hideTask?.cancel()
      controlsVisible = false
    } else {
      controlsVisible = true
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
      controlsVisible = false
    }
  }
}

// MARK: - Controls

struct PlayerControls: View {
  @ObservedObject var model: PlayerModel
  var landscape: Bool
  var chatOpen: Bool
  var visible: Bool
  var insets: EdgeInsets
  var toggleChat: () -> Void
  var minimize: () -> Void
  /// Keeps the controls up for this many more seconds.
  var interacted: (Double) -> Void
  @EnvironmentObject private var settings: AppSettings
  /// While dragging the seek bar everything else steps aside for the preview.
  @State private var scrubbing = false

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom
      )
      .allowsHitTesting(false)
      VStack(spacing: 0) {
        topBar
          .opacity(scrubbing ? 0 : 1)
        Spacer(minLength: 0)
        bottomBar
      }
      .padding(insets)
      .animation(.easeInOut(duration: 0.15), value: scrubbing)
      if model.phase == .playing && !model.coveringAd && !scrubbing {
        Button {
          model.togglePause()
          interacted(3.5)
        } label: {
          Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            .font(.system(size: landscape ? 34 : 28, weight: .semibold))
            .frame(width: 64, height: 64)
            .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.88))
        .accessibilityLabel(model.isPaused ? "Play" : "Pause")
      }
    }
    .foregroundColor(.white)
    .opacity(visible ? 1 : 0)
    .animation(.easeInOut(duration: 0.22), value: visible)
    .allowsHitTesting(visible)
  }

  private var topBar: some View {
    HStack(spacing: 2) {
      button("chevron.down", label: landscape ? "Exit full screen" : "Minimize") {
        landscape ? OrientationLock.force(.portrait) : minimize()
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
      let qualities = model.menuQualities
      if qualities.count > 1 {
        Menu {
          Picker("Quality", selection: Binding(get: { model.menuSelectedQuality }, set: { id in
            if let quality = qualities.first(where: { $0.id == id }) { model.selectQuality(quality) }
          })) {
            ForEach(qualities) { Text($0.label).tag($0.id) }
          }
        } label: {
          Label("Quality · \(qualities.first { $0.id == model.menuSelectedQuality }?.label ?? "Auto")", systemImage: "slider.horizontal.3")
        }
      }
      if model.isLive && model.canToggleLowLatency && !model.isRewinding {
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

  private var bottomBar: some View {
    VStack(spacing: 2) {
      seekBar
      HStack(spacing: 10) {
        if model.isLive {
          liveButton
          if let viewers = model.stream?.viewers {
            Label(Format.viewers(viewers), systemImage: "person.fill").font(.caption.monospacedDigit())
              .labelStyle(.titleAndIcon).foregroundColor(.white.opacity(0.85))
          }
          adBadge
        } else if model.duration > 0 {
          Text("\(Format.duration(Int(model.position))) / \(Format.duration(Int(model.duration)))")
            .font(.caption.monospacedDigit())
          if model.vodIsRecording {
            Text("RECORDING").font(.caption2.weight(.heavy))
              .padding(.horizontal, 5).padding(.vertical, 2)
              .background(Color.liveRed.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
          }
        }
        Spacer()
        if landscape {
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

  /// VODs: the whole video. Live: from the start of the broadcast to now, when the channel is
  /// recording a VOD of it that plays for you.
  @ViewBuilder
  private var seekBar: some View {
    if model.isLive, model.rewind != nil, model.broadcastElapsed > 60 {
      SeekBar(
        position: model.isRewinding ? model.rewindPosition : model.broadcastElapsed,
        duration: model.broadcastElapsed, storyboard: model.storyboard,
        label: { time in
          let behind = model.broadcastElapsed - time
          return behind < 20 ? "Live" : "-" + Format.duration(Int(behind))
        },
        onStart: {
          scrubbing = true
          model.refreshStoryboardIfStale()
        },
        onScrub: { _ in interacted(4) },
        onCommit: {
          scrubbing = false
          model.seekBroadcast(to: $0)
        }
      )
      .padding(.horizontal, 4)
      .transition(.opacity)
    } else if !model.isLive, model.duration > 0 {
      SeekBar(
        position: model.position, duration: model.duration, storyboard: model.storyboard,
        label: { Format.duration(Int($0)) },
        onStart: {
          scrubbing = true
          model.refreshStoryboardIfStale()
        },
        onScrub: { _ in interacted(4) },
        onCommit: {
          scrubbing = false
          model.seek(to: $0)
        }
      )
      .padding(.horizontal, 4)
    }
  }

  private var liveButton: some View {
    Button {
      model.goLive()
      interacted(3.5)
    } label: {
      HStack(spacing: 6) {
        Text("LIVE").font(.caption.weight(.heavy))
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(atLiveEdge ? Color.liveRed : Color.gray, in: RoundedRectangle(cornerRadius: 4))
        if model.isRewinding {
          Text("-" + Format.duration(Int(max(0, model.broadcastElapsed - model.rewindPosition))))
            .font(.caption.monospacedDigit()).foregroundColor(.white.opacity(0.85))
        } else if let latency = model.latency {
          Text(String(format: "%.1fs", latency)).font(.caption.monospacedDigit()).foregroundColor(.white.opacity(0.85))
        }
      }
      .animation(.easeInOut(duration: 0.2), value: atLiveEdge)
    }
    .accessibilityLabel(model.isRewinding ? "Back to live" : "Jump to live")
  }

  private var atLiveEdge: Bool { !model.isRewinding && (model.latency ?? 0) < (settings.lowLatency ? 6 : 15) }

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
    .buttonStyle(PressableStyle(scale: 0.85))
    .accessibilityLabel(label)
  }
}

// MARK: - Seek bar

/// A Twitch-style seek bar: thin until touched, with a thumbnail of where you'd land.
struct SeekBar: View {
  var position: Double
  var duration: Double
  var storyboard: Storyboard?
  var label: (Double) -> String
  var onStart: () -> Void = {}
  var onScrub: (Double) -> Void = { _ in }
  var onCommit: (Double) -> Void
  @State private var dragTime: Double?
  /// Where the thumb was let go, held until playback gets there (so it doesn't jump back).
  @State private var landedTime: Double?

  private static let bubbleWidth: CGFloat = 168

  var body: some View {
    GeometryReader { geometry in
      let width = max(1, geometry.size.width)
      let shown = dragTime ?? landedTime ?? position
      let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
      let active = dragTime != nil
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.28)).frame(height: active ? 6 : 3)
        Capsule().fill(Color.accentTeal).frame(width: max(0, width * fraction), height: active ? 6 : 3)
        Circle().fill(Color.white)
          .frame(width: active ? 16 : 11, height: active ? 16 : 11)
          .shadow(color: .black.opacity(0.4), radius: 2)
          .offset(x: width * fraction - (active ? 8 : 5.5))
      }
      .frame(width: width, height: geometry.size.height)
      .animation(active ? nil : .linear(duration: 0.5), value: position)
      .animation(.easeOut(duration: 0.15), value: active)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            if dragTime == nil { onStart() }
            let time = min(1, max(0, value.location.x / width)) * duration
            dragTime = time
            onScrub(time)
          }
          .onEnded { _ in
            if let dragTime {
              landedTime = dragTime
              onCommit(dragTime)
              DispatchQueue.main.asyncAfter(deadline: .now() + 2) { landedTime = nil }
            }
            dragTime = nil
          }
      )
      .onChange(of: position) { newValue in
        if let landed = landedTime, abs(newValue - landed) < 3 { landedTime = nil }
      }
      .overlay(alignment: .topLeading) {
        if let dragTime {
          SeekPreviewBubble(storyboard: storyboard, time: dragTime, label: label(dragTime))
            .frame(width: Self.bubbleWidth)
            .offset(
              x: min(max(0, width * fraction - Self.bubbleWidth / 2), width - Self.bubbleWidth),
              y: -(storyboard == nil ? 28 : 116))
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
            .allowsHitTesting(false)
        }
      }
    }
    .frame(height: 40)
  }
}

struct SeekPreviewBubble: View {
  var storyboard: Storyboard?
  var time: Double
  var label: String

  var body: some View {
    VStack(spacing: 4) {
      if let storyboard, let frame = storyboard.frame(at: time) {
        StoryboardThumbnail(board: storyboard, frame: frame)
          .frame(width: 160, height: 90)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.85), lineWidth: 1.5))
      }
      Text(label)
        .font(.caption.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.7), in: Capsule())
    }
    .shadow(color: .black.opacity(0.5), radius: 6)
  }
}

/// One thumbnail out of a storyboard sprite sheet. Keeps the last one while the next sheet loads.
struct StoryboardThumbnail: UIViewRepresentable {
  let board: Storyboard
  let frame: Storyboard.Frame

  func makeUIView(context: Context) -> SpriteView {
    let view = SpriteView()
    view.contentMode = .scaleAspectFill
    view.clipsToBounds = true
    view.backgroundColor = UIColor(white: 0.1, alpha: 1)
    for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
      view.setContentHuggingPriority(.defaultLow, for: axis)
      view.setContentCompressionResistancePriority(.defaultLow, for: axis)
    }
    return view
  }

  func updateUIView(_ view: SpriteView, context: Context) {
    view.show(frame, of: board)
  }

  final class SpriteView: UIImageView {
    private var current: Storyboard.Frame?

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }

    func show(_ frame: Storyboard.Frame, of board: Storyboard) {
      guard frame != current else { return }
      current = frame
      let apply: (UIImage?) -> Void = { [weak self] sheet in
        guard let self, self.current == frame, let image = sheet?.cgImage else { return }
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        if board.width > 0, board.height > 0 {
          // The last sheet can be shorter (fewer rows), so scale by width.
          let scale = CGFloat(image.width) / CGFloat(board.columns * board.width)
          cellWidth = CGFloat(board.width) * scale
          cellHeight = CGFloat(board.height) * scale
        } else {
          cellWidth = CGFloat(image.width) / CGFloat(board.columns)
          cellHeight = CGFloat(image.height) / CGFloat(board.rows)
        }
        let rect = CGRect(
          x: CGFloat(frame.column) * cellWidth, y: CGFloat(frame.row) * cellHeight, width: cellWidth, height: cellHeight
        ).integral
        if let cropped = image.cropping(to: rect) { self.image = UIImage(cgImage: cropped) }
      }
      if let cached = ImagePipeline.shared.cached(frame.image, maxPixels: 4096) {
        apply(cached)
      } else {
        ImagePipeline.shared.load(frame.image, maxPixels: 4096, completion: apply)
      }
    }
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
          if case .video(let video) = target {
            if let category = video.categoryName {
              Text("· \(category)").font(.footnote).foregroundColor(.accentTeal)
            }
            if video.createdAt != nil {
              Text("· \(Format.relative(video.createdAt))").font(.footnote).foregroundColor(.secondary)
            }
          } else {
            if let category = model.stream?.category?.name {
              Text("· \(category)").font(.footnote).foregroundColor(.accentTeal)
            }
            if let uptime = Format.uptime(since: model.stream?.startedAt) {
              Text("· \(uptime)").font(.footnote.monospacedDigit()).foregroundColor(.secondary)
            }
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { favorites.toggle(channel) }
          } label: {
            Image(systemName: favorites.contains(channel) ? "heart.fill" : "heart")
              .font(.title3)
              .foregroundColor(favorites.contains(channel) ? .liveRed : .white)
              .scaleEffect(favorites.contains(channel) ? 1.1 : 1)
          }
          .buttonStyle(PressableStyle(scale: 0.8))
          .accessibilityLabel(favorites.contains(channel) ? "Remove from Following" : "Add to Following")
        }
      }
    }
    .padding(.horizontal, 12)
    .frame(maxHeight: .infinity)
  }

  private var title: String {
    switch target {
    case .live: return model.stream?.title ?? model.channel?.name ?? ""
    case .video(let video): return video.title
    }
  }
}
