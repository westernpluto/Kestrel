// The video with its controls and gestures, the seek bar (with preview thumbnails) and what sits
// under the video in portrait.

import AVKit
import SwiftUI

// MARK: - Video with controls and gestures

struct PlayerVideoArea: View {
  @ObservedObject var model: PlayerModel
  /// The controls' full-screen form (phone landscape, or full screen in a large window).
  var landscape: Bool
  var chatOpen: Bool
  var controlInsets: EdgeInsets
  /// False while the player shrinks into (or is) the mini player.
  var chromeVisible: Bool = true
  /// In the mini player (its own overlay takes the touches).
  var minimized: Bool = false
  /// Landscape chat is on the left (swipes to show and hide it are mirrored).
  var chatOnLeft: Bool = false
  var toggleChat: () -> Void
  var minimize: () -> Void
  /// Full screen: on a phone the player turns; in a large window the video takes the whole window.
  var enterFullScreen: () -> Void
  var exitFullScreen: () -> Void
  /// Pulling the video down (portrait): how far, then where it was let go (and where it was headed).
  var onPull: (CGFloat) -> Void = { _ in }
  var onPullEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
  @EnvironmentObject private var settings: AppSettings
  @State private var controlsVisible = true
  @State private var hideTask: Task<Void, Never>? = nil
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
        insets: controlInsets, toggleChat: toggleChat, minimize: minimize,
        enterFullScreen: enterFullScreen, exitFullScreen: exitFullScreen, interacted: { scheduleHide(after: $0) })
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
      // Rewinding: the broadcast's VOD plays on top once it has a picture; the live player stays
      // underneath, paused on its last frame, so the switch never flashes black.
      if model.rewind != nil {
        ApplePlayerSurface(model: model, role: .rewind, fill: model.fillsScreen)
          .opacity((model.isRewinding || model.rewindLinger) && model.rewindShowing ? 1 : 0)
          .animation(.easeInOut(duration: 0.25), value: model.rewindShowing)
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
    // Screen coordinates: the video shrinks under the finger while it's pulled.
    DragGesture(minimumDistance: 14, coordinateSpace: .global)
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
            exitFullScreen()
          } else if dy < -70, !landscape {
            enterFullScreen()
          }
        } else if landscape {
          // Swipe toward the middle to bring chat in, toward its edge to put it away.
          let towardChatEdge = chatOnLeft ? dx < -60 : dx > 60
          let awayFromChatEdge = chatOnLeft ? dx > 60 : dx < -60
          if awayFromChatEdge, !chatOpen { toggleChat() }
          if towardChatEdge, chatOpen { toggleChat() }
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
      enterFullScreen()
    }
  }

  private func toggleControls() {
    // A tap on the video also puts the keyboard away.
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
  var enterFullScreen: () -> Void
  var exitFullScreen: () -> Void
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
        landscape ? exitFullScreen() : minimize()
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

  /// The gear menu, built from plain values so it only redraws when those change. (Built from
  /// the player directly, it was rebuilt with every twice-a-second stats update while open, which
  /// made its text flicker.)
  private var settingsMenu: some View {
    let qualities = model.menuQualities
    return PlayerSettingsMenu(
      qualities: qualities,
      selected: model.menuSelectedQuality,
      showLowLatency: model.isLive && model.canToggleLowLatency && !model.isRewinding,
      lowLatency: settings.lowLatency,
      showStats: settings.showVideoStats,
      select: { [model] in model.selectQuality($0) },
      setLowLatency: { [model] in model.setLowLatency($0) },
      setStats: { [settings] in settings.showVideoStats = $0 },
      opened: { [interacted] in interacted(12) }
    )
    .equatable()
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
          landscape ? exitFullScreen() : enterFullScreen()
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
          model.broadcastElapsed - time < 20 ? "Live" : Format.duration(Int(time))
        },
        onStart: {
          scrubbing = true
          model.refreshStoryboardIfStale()
          model.prepareRewind()
        },
        onScrub: { time in
          interacted(4)
          model.scrubRewind(to: time)
        },
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
          // Where you are in the broadcast (counts up while it plays, holds while paused).
          Text("\(Format.duration(Int(model.rewindPosition))) / \(Format.duration(Int(model.broadcastElapsed)))")
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
  @State private var dragTime: Double? = nil
  /// Where the thumb was let go, held until playback gets there (so it doesn't jump back).
  @State private var landedTime: Double? = nil

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
  @EnvironmentObject private var app: AppModel

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      // The streamer's picture and name open their channel page (the player shrinks).
      Button {
        if let channel = model.channel, !channel.login.isEmpty { app.openChannel(channel) }
      } label: {
        HStack(alignment: .center, spacing: 10) {
          Avatar(url: model.channel?.profileImageURL, size: 40)
          details
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(PressableStyle(scale: 0.97))
      .accessibilityHint("Opens the channel")
      Spacer(minLength: 4)
      if let channel = model.channel, !channel.id.isEmpty {
        FollowButton(channel: channel)
      }
    }
    .padding(.horizontal, 12)
    .frame(maxHeight: .infinity)
    .contentShape(Rectangle())
    // Tapping the bar's empty space puts the keyboard away, like anywhere outside the message box.
    .onTapGesture {
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
  }

  private var details: some View {
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
      .foregroundColor(.white)
  }

  private var title: String {
    switch target {
    case .live: return model.stream?.title ?? model.channel?.name ?? ""
    case .video(let video): return video.title
    }
  }
}

/// A large window in landscape (iPhone Duo's inner display): the room under the video's info bar
/// shows the stream's details: the whole title, who's watching and for how long, and its tags.
struct StreamDetailsPanel: View {
  @ObservedObject var model: PlayerModel
  let target: PlaybackTarget
  @EnvironmentObject private var app: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text(title)
          .font(.title3.weight(.semibold))
          .foregroundColor(.white)
          .fixedSize(horizontal: false, vertical: true)
        WrapLayout(spacing: 18, lineSpacing: 8) { facts }
          .font(.subheadline)
        if !tags.isEmpty {
          WrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.self) { TagChip(text: $0) }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 6)
      .padding(.bottom, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.hidden)
    .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.08)) }
  }

  @ViewBuilder
  private var facts: some View {
    switch target {
    case .live:
      if let viewers = model.stream?.viewers {
        Label("\(Format.viewers(viewers)) watching", systemImage: "person.fill").foregroundColor(.white.opacity(0.85))
      }
      if let uptime = Format.uptime(since: model.stream?.startedAt) {
        Label("Live for \(uptime)", systemImage: "clock").foregroundColor(.white.opacity(0.85))
      }
      if let category = model.stream?.category {
        Button {
          app.openCategory(category)
        } label: {
          Label(category.name, systemImage: "square.grid.2x2").foregroundColor(.accentTeal)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
      }
    case .video(let video):
      Label("\(Format.viewers(video.viewCount)) views", systemImage: "eye").foregroundColor(.white.opacity(0.85))
      if video.createdAt != nil {
        Label(Format.relative(video.createdAt), systemImage: "calendar").foregroundColor(.white.opacity(0.85))
      }
      if video.lengthSeconds > 0 {
        Label(Format.duration(video.lengthSeconds), systemImage: "film").foregroundColor(.white.opacity(0.85))
      }
      if let category = video.categoryName {
        Label(category, systemImage: "square.grid.2x2").foregroundColor(.accentTeal)
      }
    }
  }

  private var title: String {
    switch target {
    case .live: return model.stream?.title ?? model.channel?.name ?? ""
    case .video(let video): return video.title
    }
  }

  private var tags: [String] {
    if case .live = target { return model.stream?.tags ?? [] }
    return []
  }
}

/// Lays its items out in lines, starting a new line when one is full.
struct WrapLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        y += lineHeight + lineSpacing
        x = 0
        lineHeight = 0
      }
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: proposal.width ?? widest, height: subviews.isEmpty ? 0 : y + lineHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        y += lineHeight + lineSpacing
        x = bounds.minX
        lineHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
  }
}

struct PlayerSettingsMenu: View, Equatable {
  var qualities: [PlayerModel.Quality]
  var selected: Int?
  var showLowLatency: Bool
  var lowLatency: Bool
  var showStats: Bool
  var select: (PlayerModel.Quality) -> Void
  var setLowLatency: (Bool) -> Void
  var setStats: (Bool) -> Void
  var opened: () -> Void

  static func == (a: Self, b: Self) -> Bool {
    a.qualities == b.qualities && a.selected == b.selected && a.showLowLatency == b.showLowLatency
      && a.lowLatency == b.lowLatency && a.showStats == b.showStats
  }

  var body: some View {
    Menu {
      if qualities.count > 1 {
        Menu {
          Picker("Quality", selection: Binding(get: { selected }, set: { id in
            if let quality = qualities.first(where: { $0.id == id }) { select(quality) }
          })) {
            ForEach(qualities) { Text($0.label).tag($0.id) }
          }
        } label: {
          Label("Quality · \(qualities.first { $0.id == selected }?.label ?? "Auto")", systemImage: "slider.horizontal.3")
        }
      }
      if showLowLatency {
        Toggle(isOn: Binding(get: { lowLatency }, set: setLowLatency)) {
          Label("Low latency", systemImage: "bolt")
        }
      }
      Toggle(isOn: Binding(get: { showStats }, set: setStats)) {
        Label("Video stats", systemImage: "chart.bar.xaxis")
      }
    } label: {
      Image(systemName: "gearshape.fill")
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .accessibilityLabel("Settings")
    .simultaneousGesture(TapGesture().onEnded { opened() })
  }
}
