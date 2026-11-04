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
  /// Where the picture sits in the area (iPhone Duo's outer screen: clear of the camera).
  var pictureInsets = EdgeInsets()
  /// Extra room for the top bar or the bottom row, from a camera in their corner.
  var topBarExtra = EdgeInsets()
  var bottomRowExtra = EdgeInsets()
  /// False while the player shrinks into (or is) the mini player.
  var chromeVisible: Bool = true
  /// In the mini player (its own overlay takes the touches).
  var minimized: Bool = false
  /// Landscape chat is on the left (swipes to show and hide it are mirrored).
  var chatOnLeft: Bool = false
  /// Chat in a column beside the video (a large window held sideways): sideways swipes put it
  /// away and bring it back, as in phone landscape, instead of a swipe up for full screen.
  var sideChat: Bool = false
  /// A large window (iPhone Duo's inner display): full screen there is the same screen, so a
  /// swipe down pulls the player into the mini player, as in portrait (not back to chat).
  var largeWindow: Bool = false
  /// The details panel beside the video already shows the viewer count.
  var viewersShownElsewhere = false
  /// Theater mode: the streamer's picture and name go on the video (nothing else shows them).
  var showsStreamer = false
  /// For the chat overlay in full screen.
  var chat: ChatController? = nil
  /// A layout choice offered on the video, where one applies (theater mode, chat over video).
  var layoutToggle: LayoutToggle? = nil
  var setLayoutToggle: (Bool) -> Void = { _ in }
  var toggleChat: () -> Void
  var minimize: () -> Void
  /// Full screen: on a phone the player turns; in a large window the video takes the whole window.
  var enterFullScreen: () -> Void
  var exitFullScreen: () -> Void
  /// The keyboard is up: a swipe down on the video just puts it away (no pull).
  var keyboardUp = false
  /// Pulling the video down (portrait): how far, then where it was let go (and where it was headed).
  var onPull: (CGFloat) -> Void = { _ in }
  var onPullEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
  @EnvironmentObject private var settings: AppSettings
  @AppStorage("chatOverlay") private var chatOverlay = false
  @State private var controlsVisible = true
  @State private var hideTask: Task<Void, Never>? = nil
  /// A pinch also moves the fingers; don't read it as a swipe.
  @State private var lastPinch = Date.distantPast
  @State private var pulling = false
  /// This swipe put the keyboard away; the rest of it does nothing.
  @State private var swipeTookKeyboard = false

  /// Full screen with chat put away: a small see-through chat can lie over the video instead.
  private var overlayAvailable: Bool { landscape && !chatOpen && chat != nil }

  /// Where chat is in full screen (one menu for all of it: beside, over the video, a small
  /// see-through one, or none).
  private var chatMode: ChatMode {
    if chatOpen { return layoutToggle?.chatOverVideo == true && layoutToggle?.isOn == true ? .over : .beside }
    return chatOverlay && chat != nil ? .floating : .off
  }

  private var chatModes: [ChatMode] {
    // (A large window's chat only goes beside the video.)
    [.beside] + (largeWindow ? [] : [.over]) + (chat != nil ? [.floating] : []) + [.off]
  }

  private func setChatMode(_ mode: ChatMode) {
    guard mode != chatMode else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      switch mode {
      case .beside, .over:
        if !largeWindow { setLayoutToggle(mode == .over) }
        if !chatOpen { toggleChat() }
      case .floating, .off:
        chatOverlay = mode == .floating
        if chatOpen { toggleChat() }
      }
    }
  }

  var body: some View {
    ZStack {
      Color.black
      Group {
        poster
        surface
      }
      .padding(model.fillsScreen ? EdgeInsets() : pictureInsets)
      .animation(.easeInOut(duration: 0.25), value: model.fillsScreen)
      // Gestures live on this layer, under everything that can be tapped.
      Color.black.opacity(0.001)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { doubleTap() }
        .onTapGesture { toggleControls() }
        .gesture(swipe)
        .simultaneousGesture(zoom)
        // Keyed to the minimized state, not the animation, so a pull in progress keeps its touch.
        .allowsHitTesting(!minimized)
      if let audioOnly = model.audioOnly, model.phase == .playing, !model.coveringAd {
        AudioOnlyCard(state: audioOnly, compact: !landscape && !chatOpen)
          .padding(pictureInsets)
          .transition(.opacity)
      }
      statusOverlay
        .padding(pictureInsets)
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.coveringAd)
      if overlayAvailable, chatOverlay, chromeVisible, let chat {
        ChatOverlay(
          chat: chat, clearance: controlInsets, pictureInsets: pictureInsets, fill: model.fillsScreen,
          controlsShown: controlsShown, tap: toggleControls)
          .transition(.opacity)
      }
      if settings.showVideoStats && !model.stats.isEmpty && chromeVisible {
        // An overlay, so its size never changes the video area's (it used to grow it and push
        // the controls off the top and bottom of a small video).
        // Kept inside the picture and clear of the camera and the controls on every side, so it
        // never runs under iPhone Duo's status strip or off the screen; the layout that fits is
        // picked for the room there is.
        Color.clear
          .allowsHitTesting(false)
          .overlay(alignment: .topLeading) {
            StatsOverlay(lines: model.stats, close: { settings.showVideoStats = false })
              .padding(.top, max(controlInsets.top + (controlsShown ? 44 : 0), pictureInsets.top))
              .padding(.leading, max(controlInsets.leading + topBarExtra.leading, pictureInsets.leading))
              .padding(.trailing, max(controlInsets.trailing, pictureInsets.trailing))
              .padding(.bottom, max(controlInsets.bottom + (controlsShown ? 56 : 0), pictureInsets.bottom))
          }
          .clipped()
          .transition(.opacity)
      }
      PlayerControls(
        model: model, landscape: landscape, chatOpen: chatOpen, visible: controlsShown && chromeVisible && !pulling,
        insets: controlInsets, pictureInsets: pictureInsets, topBarExtra: topBarExtra, bottomRowExtra: bottomRowExtra,
        viewersShownElsewhere: viewersShownElsewhere, showsStreamer: showsStreamer,
        layoutToggle: layoutToggle?.chatOverVideo == true ? nil : layoutToggle, setLayoutToggle: setLayoutToggle,
        chatMode: landscape ? chatMode : nil, chatModes: chatModes, setChatMode: setChatMode,
        minimize: minimize, enterFullScreen: enterFullScreen, exitFullScreen: exitFullScreen,
        interacted: { scheduleHide(after: $0) })
      if let resumed = model.resumedAt, chromeVisible {
        resumeNotice(resumed)
          .padding(.leading, controlInsets.leading + 8)
          .padding(.bottom, controlInsets.bottom + (controlsShown ? 78 : 10))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
          .animation(.easeInOut(duration: 0.2), value: controlsShown)
      }
      if let part = model.currentMutedPart, chromeVisible, model.phase == .playing {
        skipMutedNotice(part)
          .padding(.trailing, controlInsets.trailing + bottomRowExtra.trailing + 8)
          .padding(.bottom, controlInsets.bottom + (controlsShown ? 78 : 10))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
          .animation(.easeInOut(duration: 0.2), value: controlsShown)
      }
    }
    .clipped()
    .animation(.easeInOut(duration: 0.25), value: model.currentMutedPart)
    .onAppear { scheduleHide(after: 3.5) }
  }

  private var controlsShown: Bool { controlsVisible || model.isPaused || model.phase != .playing }

  /// "Muted · 1:12 left · Skip": a part Twitch muted for copyright, offered to skip.
  private func skipMutedNotice(_ part: ClosedRange<Double>) -> some View {
    Button {
      model.skipMutedPart()
      scheduleHide(after: 2)
    } label: {
      HStack(spacing: 7) {
        Image(systemName: "speaker.slash.fill").foregroundColor(.orange)
        Text("Muted · \(Format.duration(Int(max(0, part.upperBound - model.currentPosition).rounded(.up)))) left")
          .foregroundColor(.white.opacity(0.85))
          .monospacedDigit()
        Text("Skip").foregroundColor(.white).fontWeight(.bold)
        Image(systemName: "forward.end.fill").font(.caption2)
      }
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(.black.opacity(0.75), in: Capsule())
      .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
      .contentShape(Capsule())
    }
    .buttonStyle(PressableStyle())
    .accessibilityLabel("Skip the muted part")
  }

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

  /// Zoomed to fill only while the player is open: the mini player always shows the whole picture
  /// (it kept the zoom, cropped).
  private var fill: Bool { model.fillsScreen && !minimized }

  @ViewBuilder
  private var surface: some View {
    ZStack {
      if let engine = model.kestrelEngine {
        KestrelVideoView(engine: engine, fill: fill)
      } else {
        #if canImport(AmazonIVSPlayer)
          if let controller = model.lowLatency {
            LowLatencyVideoView(controller: controller, fill: fill)
          } else {
            ApplePlayerSurface(model: model, fill: fill)
          }
        #else
          ApplePlayerSurface(model: model, fill: fill)
        #endif
      }
      // Rewinding: the broadcast's VOD plays on top once it has a picture; the live player stays
      // underneath, paused on its last frame, so the switch never flashes black.
      if model.rewind != nil {
        ApplePlayerSurface(model: model, role: .rewind, fill: fill)
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
        VStack(spacing: 10) {
          ProgressView().tint(.white).scaleEffect(1.2)
          if model.waitingForStream {
            // The broadcaster's upload dropped out: nothing this end can do but wait (and say so,
            // rather than restart and lose what's in hand).
            Text("Waiting for the stream…")
              .font(.caption.weight(.semibold))
              .foregroundColor(.white.opacity(0.85))
              .padding(.horizontal, 10).padding(.vertical, 5)
              .background(.black.opacity(0.55), in: Capsule())
              .transition(.opacity)
          }
        }
        .animation(.easeInOut(duration: 0.25), value: model.waitingForStream)
        .allowsHitTesting(false)
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
  /// in landscape: leave full screen. Swipe up (portrait): full screen. Sideways with chat beside
  /// the video (landscape): chat away (the video takes the space) and back.
  private var swipe: some Gesture {
    // Screen coordinates: the video shrinks under the finger while it's pulled.
    DragGesture(minimumDistance: 14, coordinateSpace: .global)
      .onChanged { value in
        guard !landscape || largeWindow, !swipeTookKeyboard, Date().timeIntervalSince(lastPinch) > 0.5 else { return }
        let dx = value.translation.width, dy = value.translation.height
        if pulling || (dy > 8 && dy > abs(dx) * 1.2) {
          // Typing: a swipe down puts the keyboard away (letting it slide off), rather than
          // starting to shrink the player under it.
          if !pulling, keyboardUp {
            swipeTookKeyboard = true
            Keyboard.dismiss()
            return
          }
          pulling = true
          onPull(max(0, dy))
        }
      }
      .onEnded { value in
        if swipeTookKeyboard {
          swipeTookKeyboard = false
          return
        }
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
          } else if dy < -70, !landscape, !sideChat {
            enterFullScreen()
          }
        } else if landscape || sideChat {
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
    Keyboard.dismiss()
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

/// In place of the frozen picture while only the sound is playing.
struct AudioOnlyCard: View {
  var state: PlayerModel.AudioOnly
  var compact: Bool

  var body: some View {
    ZStack {
      Color.black
      VStack(spacing: 8) {
        Image(systemName: "waveform")
          .font(.system(size: compact ? 28 : 36, weight: .semibold))
          .foregroundColor(.accentTeal)
          .symbolRenderingMode(.hierarchical)
        Text("Audio only").font(.headline)
        HStack(spacing: 6) {
          if state == .returning { ProgressView().tint(.white).scaleEffect(0.7) }
          Text(
            state == .chosen
              ? "Pick a video quality in the gear menu to bring the picture back"
              : "Bringing the picture back…"
          )
        }
        .font(.footnote)
        .foregroundColor(.white.opacity(0.7))
        .multilineTextAlignment(.center)
      }
      .foregroundColor(.white)
      .padding(.horizontal, 24)
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Controls

struct PlayerControls: View {
  @ObservedObject var model: PlayerModel
  var landscape: Bool
  var chatOpen: Bool
  var visible: Bool
  var insets: EdgeInsets
  var pictureInsets = EdgeInsets()
  var topBarExtra = EdgeInsets()
  var bottomRowExtra = EdgeInsets()
  var viewersShownElsewhere = false
  var showsStreamer = false
  var layoutToggle: LayoutToggle? = nil
  var setLayoutToggle: (Bool) -> Void = { _ in }
  /// Where chat is (nil: no chat menu here), and where it can go.
  var chatMode: ChatMode? = nil
  var chatModes: [ChatMode] = []
  var setChatMode: (ChatMode) -> Void = { _ in }
  var minimize: () -> Void
  var enterFullScreen: () -> Void
  var exitFullScreen: () -> Void
  /// Keeps the controls up for this many more seconds.
  var interacted: (Double) -> Void
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var app: AppModel
  @ObservedObject private var recordings = RecordingStore.shared
  @ObservedObject private var autoRecorder = AutoRecorder.shared
  /// While dragging the seek bar everything else steps aside for the preview.
  @State private var scrubbing = false
  /// A word on what a button just did (icons alone didn't say).
  @State private var hint: String?
  @State private var hintTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom
      )
      .allowsHitTesting(false)
      VStack(spacing: 0) {
        topBar
          .padding(topBarExtra)
          .opacity(scrubbing ? 0 : 1)
        Spacer(minLength: 0)
        bottomBar
      }
      .padding(insets)
      .animation(.easeInOut(duration: 0.15), value: scrubbing)
      if model.phase == .playing && !model.coveringAd && !scrubbing {
        let skips = model.canSkipBack || model.canSkipForward
        HStack(spacing: landscape ? 44 : 28) {
          if skips {
            skipButton(-10).opacity(model.canSkipBack ? 1 : 0).disabled(!model.canSkipBack)
          }
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
          if skips {
            // Kept in place (invisible) when there's nowhere to go, so pause stays centred.
            skipButton(10).opacity(model.canSkipForward ? 1 : 0).disabled(!model.canSkipForward)
          }
        }
        // Centred on the picture, not the area around it.
        .padding(pictureInsets)
      }
      if let hint {
        Text(hint)
          .font(.footnote.weight(.semibold))
          .padding(.horizontal, 14).padding(.vertical, 8)
          .background(.ultraThinMaterial, in: Capsule())
          .environment(\.colorScheme, .dark)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .padding(.top, insets.top + 52)
          .transition(.opacity)
          .allowsHitTesting(false)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: hint)
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
      if landscape || showsStreamer {
        // Full screen and theater mode: who's streaming (nothing else on screen says). A tap opens
        // their channel page (the player shrinks).
        Button {
          if let channel = model.channel, !channel.login.isEmpty { app.openChannel(channel) }
        } label: {
          HStack(spacing: 8) {
            Avatar(url: model.channel?.profileImageURL, size: 30)
              .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
              Text(model.channel?.name ?? "").font(.subheadline.weight(.bold))
              if !title.isEmpty {
                Text(title).font(.caption).foregroundColor(.white.opacity(0.75))
              }
            }
          }
          .lineLimit(1)
          .padding(.leading, 2)
          .padding(.vertical, 4)
          .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityHint("Opens the channel")
      }
      Spacer(minLength: 8)
      if model.isLive, !model.isRewinding, let channel = model.channel, !channel.login.isEmpty {
        // This stream and others at once.
        button("rectangle.split.2x2", label: "Multi-view: watch with other streams") { app.openMultiview([channel]) }
      }
      // UIKit's AirPlay button takes touches whatever SwiftUI says: only there while the controls
      // show (hidden in the mini player, it caught taps meant for the app beside it).
      if visible {
        AirPlayButton().frame(width: 40, height: 40)
      } else {
        Color.clear.frame(width: 40, height: 40)
      }
      if AVPictureInPictureController.isPictureInPictureSupported() {
        button(model.pictureInPictureActive ? "pip.exit" : "pip.enter", label: "Picture in Picture") {
          model.togglePictureInPicture()
        }
      }
      settingsMenu
    }
  }

  private var title: String {
    switch model.target {
    case .live: return model.stream?.title ?? ""
    case .video(let video): return video.title
    }
  }

  /// The gear menu, built from plain values so it only redraws when those change. (Built from
  /// the player directly, it was rebuilt with every twice-a-second stats update while open, which
  /// made its text flicker.)
  private var settingsMenu: some View {
    let qualities = model.menuQualities
    let login = model.channel?.login ?? ""
    let canRecord = model.isLive && !model.isRewinding && !login.isEmpty
    return PlayerSettingsMenu(
      qualities: qualities,
      selected: model.menuSelectedQuality,
      showLowLatency: model.isLive && model.canToggleLowLatency && !model.isRewinding,
      lowLatency: settings.lowLatency,
      showStats: settings.showVideoStats,
      recordOptions: canRecord ? RecordQuality.options(from: model.qualities.map(\.label)) : [],
      recording: canRecord ? recordings.isRecording(login) : nil,
      autoRecord: autoRecorder.rule(for: login) != nil,
      skipMuted: model.currentMutedParts.isEmpty ? nil : settings.skipMutedParts,
      select: { [model] in model.selectQuality($0) },
      setLowLatency: { [model] in model.setLowLatency($0) },
      setStats: { [settings] in settings.showVideoStats = $0 },
      startRecording: { [model, recordings] (label: String) in
        guard let channel = model.channel else { return }
        recordings.start(channel: channel, stream: model.stream, maxHeight: RecordQuality.height(label))
      },
      stopRecording: { [recordings] in
        if let current = recordings.recording(of: login) { recordings.stop(current.id) }
      },
      scheduleRecording: { [model, autoRecorder] (height: Int) in
        if let channel = model.channel { autoRecorder.schedule(channel, maxHeight: height) }
      },
      unscheduleRecording: { [autoRecorder] in autoRecorder.unschedule(login) },
      setSkipMuted: { [settings] in settings.skipMutedParts = $0 },
      opened: { [interacted] in interacted(12) }
    )
    .equatable()
  }

  private var bottomBar: some View {
    VStack(spacing: 2) {
      seekBar
      HStack(spacing: 10) {
        // As much about the stream as fits beside the buttons (which always fit): when room runs
        // short the ad badge shrinks to its icon, then the time live goes, then the viewer count,
        // then the latency. Nothing is ever squeezed onto a second line.
        ViewThatFits(in: .horizontal) {
          stats(0)
          stats(1)
          stats(2)
          stats(3)
          stats(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Layout switches live on the video, where they apply (not in the gear menu).
        if let layoutToggle {
          button(
            layoutToggle.isOn ? layoutToggle.onImage : layoutToggle.systemImage,
            label: layoutToggle.isOn ? "\(layoutToggle.title) off" : layoutToggle.title, highlighted: layoutToggle.isOn
          ) { setLayoutToggle(!layoutToggle.isOn) }
        }
        if model.kestrelEngine != nil {
          // The audio compressor (Kestrel's player): loud moments down, quiet ones up.
          button(
            "waveform", label: settings.audioCompressor ? "Audio compressor on" : "Audio compressor off",
            highlighted: settings.audioCompressor
          ) {
            settings.audioCompressor.toggle()
            show(settings.audioCompressor ? "Audio compressor on" : "Audio compressor off")
          }
        }
        if let chatMode {
          chatMenu(chatMode)
        }
        button(
          landscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
          label: landscape ? "Exit full screen" : "Full screen"
        ) {
          landscape ? exitFullScreen() : enterFullScreen()
        }
      }
      .padding(bottomRowExtra)
      .font(.caption.monospacedDigit())
      .labelStyle(StatLabelStyle())
      .foregroundColor(.white)
    }
  }

  /// The stream's numbers, from all of them (0) down to just the essentials (4).
  private func stats(_ level: Int) -> some View {
    HStack(spacing: 10) {
      if model.isLive {
        liveButton(latency: level < 4)
        if let login = model.channel?.login, recordings.isRecording(login) {
          Label("REC", systemImage: "record.circle.fill")
            .font(.caption2.weight(.heavy)).foregroundColor(.liveRed).labelStyle(.titleAndIcon)
            .accessibilityLabel("Recording")
        }
        if !viewersShownElsewhere {
          if level < 3, let viewers = model.stream?.viewers {
            Label(Format.viewers(viewers), systemImage: "person.fill")
              .accessibilityLabel("\(Format.viewers(viewers)) watching")
          }
          if level < 2, let started = model.stream?.startedAt {
            Label { UptimeText(since: started, ticking: visible) } icon: { Image(systemName: "clock") }
              .accessibilityLabel("Live for \(Format.uptime(since: started) ?? "")")
          }
        }
        adBadge(iconOnly: level > 0)
      } else if model.duration > 0 {
        Text(
          level < 3
            ? "\(Format.duration(Int(model.position))) / \(Format.duration(Int(model.duration)))"
            : Format.duration(Int(model.position))
        )
        .font(.caption.monospacedDigit())
        if model.vodIsRecording {
          Text(level < 2 ? "RECORDING" : "REC").font(.caption2.weight(.heavy))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.liveRed.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
        }
      }
    }
    .lineLimit(1)
    .fixedSize()
  }

  /// VODs: the whole video. Live: from the start of the broadcast to now, when the channel is
  /// recording a VOD of it that plays for you.
  @ViewBuilder
  private var seekBar: some View {
    if model.isLive, model.rewind != nil, model.broadcastElapsed > 60 {
      SeekBar(
        position: model.isRewinding ? model.rewindPosition : model.broadcastElapsed,
        duration: model.broadcastElapsed, storyboard: model.storyboard, marks: model.rewindMutedParts,
        label: { [model] time in
          model.broadcastElapsed - time < 20
            ? "Live" : Format.duration(Int(time)) + (model.rewindMutedParts.contains { $0.contains(time) } ? " · muted" : "")
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
        position: model.position, duration: model.duration, storyboard: model.storyboard, marks: model.mutedParts,
        label: { [model] time in Format.duration(Int(time)) + (model.mutedParts.contains { $0.contains(time) } ? " · muted" : "") },
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

  private func liveButton(latency showsLatency: Bool) -> some View {
    Button {
      model.goLive()
      interacted(3.5)
    } label: {
      HStack(spacing: 6) {
        Text("LIVE").font(.caption.weight(.heavy))
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(atLiveEdge ? Color.liveRed : Color.gray, in: RoundedRectangle(cornerRadius: 4))
        if !showsLatency {
          EmptyView()
        } else if model.isRewinding {
          // Where you are in the broadcast (counts up while it plays, holds while paused).
          Text("\(Format.duration(Int(model.rewindPosition))) / \(Format.duration(Int(model.broadcastElapsed)))")
            .font(.caption.monospacedDigit()).foregroundColor(.white.opacity(0.85))
        } else if let latency = model.latency {
          // How far behind the broadcast the picture is.
          Label(String(format: "%.1fs", latency), systemImage: "stopwatch")
            .font(.caption.monospacedDigit()).foregroundColor(.white.opacity(0.85))
        }
      }
      .animation(.easeInOut(duration: 0.2), value: atLiveEdge)
    }
    .accessibilityLabel(model.isRewinding ? "Back to live" : "Jump to live")
    .accessibilityValue(model.latency.map { String(format: "%.1f seconds behind", $0) } ?? "")
  }

  private var atLiveEdge: Bool { !model.isRewinding && (model.latency ?? 0) < (settings.lowLatency ? 6 : 15) }

  @ViewBuilder
  private func adBadge(iconOnly: Bool) -> some View {
    switch model.adState {
    case .skipped, .replaced:
      badge("Ad blocked", systemImage: "checkmark.shield.fill", color: .accentTeal, iconOnly: iconOnly)
    case .searching, .covering:
      badge("Ad", systemImage: "shield.lefthalf.filled", color: .orange, iconOnly: iconOnly)
    case .none:
      EmptyView()
    }
  }

  @ViewBuilder
  private func badge(_ title: String, systemImage: String, color: Color, iconOnly: Bool) -> some View {
    if iconOnly {
      Image(systemName: systemImage).font(.caption.weight(.semibold)).foregroundColor(color)
        .accessibilityLabel(title)
    } else {
      Label(title, systemImage: systemImage).font(.caption2.weight(.semibold)).foregroundColor(color)
        .labelStyle(.titleAndIcon)
    }
  }

  /// Ten seconds back or forward (VODs, and the broadcast while rewinding).
  private func skipButton(_ seconds: Double) -> some View {
    Button {
      model.skip(by: seconds)
      interacted(3.5)
    } label: {
      Image(systemName: seconds < 0 ? "gobackward.10" : "goforward.10")
        .font(.system(size: landscape ? 25 : 21, weight: .semibold))
        .frame(width: 50, height: 50)
        .background(.black.opacity(0.3), in: Circle())
    }
    .buttonStyle(PressableStyle(scale: 0.88))
    .accessibilityLabel(seconds < 0 ? "Back 10 seconds" : "Forward 10 seconds")
  }

  /// Where chat goes, in one place (it used to be two look-alike buttons).
  /// Where chat goes, in one place (it used to be two look-alike buttons). Built from plain
  /// values so it only redraws when they change: rebuilt with every stats update while open, its
  /// text flickered.
  private func chatMenu(_ current: ChatMode) -> some View {
    ChatModeMenu(
      current: current, modes: chatModes,
      pick: { [setChatMode, interacted] mode in
        setChatMode(mode)
        interacted(3.5)
      },
      picked: { show($0.hint) },
      opened: { [interacted] in interacted(12) }
    )
    .equatable()
  }

  private func show(_ text: String) {
    hint = text
    hintTask?.cancel()
    hintTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_300_000_000)
      if !Task.isCancelled { hint = nil }
    }
  }

  private func button(_ icon: String, label: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
    Button {
      action()
      interacted(3.5)
    } label: {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(highlighted ? .accentTeal : .white)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle(scale: 0.85))
    .accessibilityLabel(label)
  }
}

/// Small icon-and-number pairs on the video (latency, viewers, time live): the icon a touch
/// dimmer than the number, tightly spaced.
struct StatLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 3) {
      configuration.icon.font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.7))
      configuration.title.foregroundColor(.white.opacity(0.9))
    }
  }
}

/// How long a stream has been live, to the second ("2:03:15"), ticking by itself (only this text
/// redraws each second, not the controls around it).
struct UptimeText: View {
  let since: Date
  /// Off while it's not on screen (the controls faded out): no redrawing every second for nothing.
  var ticking = true

  var body: some View {
    if ticking {
      TimelineView(.periodic(from: since, by: 1)) { context in
        Text(Format.clock(Int(max(0, context.date.timeIntervalSince(since))))).monospacedDigit()
      }
    } else {
      Text(Format.clock(Int(max(0, Date().timeIntervalSince(since))))).monospacedDigit()
    }
  }
}

// MARK: - Seek bar

/// A Twitch-style seek bar: thin until touched, with a thumbnail of where you'd land, and the
/// parts Twitch muted for copyright marked on it.
struct SeekBar: View {
  var position: Double
  var duration: Double
  var storyboard: Storyboard?
  /// Stretches to mark (muted parts), in seconds.
  var marks: [ClosedRange<Double>] = []
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
        if duration > 0, !marks.isEmpty {
          MarkStrip(marks: marks, duration: duration)
            .frame(width: width, height: active ? 6 : 3)
            .allowsHitTesting(false)
        }
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

/// The marked stretches of a seek bar, drawn in one pass (a VOD can have dozens).
struct MarkStrip: View {
  var marks: [ClosedRange<Double>]
  var duration: Double

  var body: some View {
    Canvas { context, size in
      for mark in marks {
        let start = size.width * min(1, max(0, mark.lowerBound / duration))
        let end = size.width * min(1, max(0, mark.upperBound / duration))
        let rect = CGRect(x: start, y: 0, width: max(2, end - start), height: size.height)
        context.fill(Path(roundedRect: rect, cornerRadius: size.height / 2), with: .color(Color.orange.opacity(0.9)))
      }
    }
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
  /// False when the details panel shows the title, category and uptime: then this is just who's
  /// streaming (nothing said twice).
  var showsTitle = true
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
    .onTapGesture { Keyboard.dismiss() }
  }

  @ViewBuilder
  private var details: some View {
    // (Offline: just who it is; there's no title or uptime to show.)
    if !showsTitle || (model.isLive && model.stream == nil && model.phase == .offline) {
      Text(model.channel?.name ?? "").font(.headline).foregroundColor(.white).lineLimit(1)
    } else {
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
            if let started = model.stream?.startedAt {
              HStack(spacing: 0) {
                Text("· ")
                UptimeText(since: started)
              }
              .font(.footnote.monospacedDigit()).foregroundColor(.secondary)
            }
          }
        }
        .lineLimit(1)
      }
      .foregroundColor(.white)
    }
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
      if let started = model.stream?.startedAt {
        Label {
          HStack(spacing: 0) {
            Text("Live for ")
            UptimeText(since: started)
          }
        } icon: {
          Image(systemName: "clock")
        }
        .foregroundColor(.white.opacity(0.85))
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

/// The qualities a recording can be made at (from the quality menu's labels).
enum RecordQuality {
  /// One per height, best first: "1080p60", "720p60", "480p"…
  static func options(from labels: [String]) -> [String] {
    var seen = Set<Int>()
    var out: [String] = []
    for label in labels where !label.contains("·") {
      guard let lines = height(label), !seen.contains(lines) else { continue }
      seen.insert(lines)
      out.append(label)
    }
    return out
  }

  /// 720 for "720p60".
  static func height(_ label: String) -> Int? {
    Int(label.prefix { $0.isNumber })
  }

  /// Roughly how much a recording at that quality takes per hour.
  static func sizePerHour(_ label: String) -> String {
    switch height(label) ?? 0 {
    case 1080...: return "≈3 GB/h"
    case 720...: return "≈1.5 GB/h"
    case 480...: return "≈0.6 GB/h"
    case 360...: return "≈0.3 GB/h"
    default: return "≈0.1 GB/h"
    }
  }
}

/// A layout choice offered on the video where it applies (theater mode, chat over the video).
struct LayoutToggle: Equatable {
  var title: String
  var systemImage: String
  var onImage: String
  var isOn: Bool
  /// It's chat over the video (offered in the chat menu instead of as its own button).
  var chatOverVideo = false
}

struct ChatModeMenu: View, Equatable {
  var current: ChatMode
  var modes: [ChatMode]
  var pick: (ChatMode) -> Void
  var picked: (ChatMode) -> Void
  var opened: () -> Void

  static func == (a: Self, b: Self) -> Bool { a.current == b.current && a.modes == b.modes }

  var body: some View {
    Menu {
      Picker("Chat", selection: Binding(get: { current }, set: { mode in
        pick(mode)
        picked(mode)
      })) {
        ForEach(modes, id: \.self) { mode in
          Label(mode.title, systemImage: mode.systemImage).tag(mode)
        }
      }
    } label: {
      Image(systemName: current == .off ? "bubble.left" : "bubble.left.fill")
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(current == .off ? .white : .accentTeal)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .accessibilityLabel("Chat")
    .accessibilityValue(current.title)
    .simultaneousGesture(TapGesture().onEnded { opened() })
  }
}

/// Where chat goes in full screen.
enum ChatMode: Hashable {
  case beside, over, floating, off

  var title: String {
    switch self {
    case .beside: return "Beside the video"
    case .over: return "Over the video"
    case .floating: return "Small, see-through"
    case .off: return "Hidden"
    }
  }

  var hint: String {
    switch self {
    case .beside: return "Chat beside the video"
    case .over: return "Chat over the video"
    case .floating: return "See-through chat"
    case .off: return "Chat hidden"
    }
  }

  var systemImage: String {
    switch self {
    case .beside: return "rectangle.split.2x1"
    case .over: return "rectangle.righthalf.inset.filled"
    case .floating: return "text.bubble"
    case .off: return "eye.slash"
    }
  }
}

/// The gear menu: what's changed often at the top level (quality, low latency, recording, muted
/// parts); the rest one level down under More.
struct PlayerSettingsMenu: View, Equatable {
  var qualities: [PlayerModel.Quality]
  var selected: Int?
  var showLowLatency: Bool
  var lowLatency: Bool
  var showStats: Bool
  /// Qualities a recording can be made at (empty: none offered).
  var recordOptions: [String]
  /// Recording this stream (nil: recording isn't offered here).
  var recording: Bool?
  /// This channel is recorded whenever it goes live (see AutoRecorder).
  var autoRecord: Bool
  /// Skip muted parts by themselves (nil: the video has none).
  var skipMuted: Bool?
  var select: (PlayerModel.Quality) -> Void
  var setLowLatency: (Bool) -> Void
  var setStats: (Bool) -> Void
  var startRecording: (String) -> Void
  var stopRecording: () -> Void
  var scheduleRecording: (Int) -> Void
  var unscheduleRecording: () -> Void
  var setSkipMuted: (Bool) -> Void
  var opened: () -> Void

  static func == (a: Self, b: Self) -> Bool {
    a.qualities == b.qualities && a.selected == b.selected && a.showLowLatency == b.showLowLatency
      && a.lowLatency == b.lowLatency && a.showStats == b.showStats
      && a.recordOptions == b.recordOptions && a.recording == b.recording && a.autoRecord == b.autoRecord
      && a.skipMuted == b.skipMuted
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
      if let skipMuted {
        Toggle(isOn: Binding(get: { skipMuted }, set: setSkipMuted)) {
          Label("Skip muted parts", systemImage: "speaker.slash")
        }
      }
      if let recording {
        Menu {
          if recording {
            Button(role: .destructive, action: stopRecording) {
              Label("Stop recording", systemImage: "stop.circle")
            }
          } else if !recordOptions.isEmpty {
            Section("Now, saved on this iPhone to watch from the start") {
              ForEach(recordOptions, id: \.self) { label in
                Button("\(label) · \(RecordQuality.sizePerHour(label))") { startRecording(label) }
              }
            }
          }
          if autoRecord {
            Button(action: unscheduleRecording) {
              Label("Stop recording when they go live", systemImage: "calendar.badge.minus")
            }
          } else {
            Section("Whenever they go live, even with Kestrel closed") {
              ForEach(AutoRecordButton.heights, id: \.self) { height in
                Button("\(height)p · \(RecordQuality.sizePerHour("\(height)p"))") { scheduleRecording(height) }
              }
            }
          }
        } label: {
          Label(recording ? "Recording" : "Record", systemImage: recording ? "record.circle.fill" : "record.circle")
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
