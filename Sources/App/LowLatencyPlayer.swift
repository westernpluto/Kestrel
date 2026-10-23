// The low-latency live player, built on the Amazon IVS Player SDK (the engine Twitch's own apps
// use). Compiled only when the SDK is present: the GitHub Actions build downloads it.

#if canImport(AmazonIVSPlayer)
  import AmazonIVSPlayer
  import AVFoundation
  import AVKit
  import SwiftUI
  import UIKit

  @MainActor
  final class LowLatencyController: NSObject, ObservableObject {
    let player = IVSPlayer()
    let login: String
    @Published private(set) var isPaused = false
    @Published private(set) var pictureInPictureActive = false

    private let codecs: String
    private weak var model: PlayerModel?
    private let proxy = LowLatencyDelegateProxy()
    private let masterID = "ll-" + UUID().uuidString
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    /// Landscape renditions from Twitch's master (to find the playlist the player is on).
    private var variants: [HLSVariant] = []
    /// What the quality menu lists: landscape qualities best first, then audio only.
    private var menuQualities: [IVSQuality] = []
    private var chosen: Int? = 0  // index into menuQualities, nil = Auto
    private var everReady = false
    private var useDirectURL = false
    private var failures: [Date] = []
    private var adTimeline = AdTimeline()
    private var mutedForAd = false
    private var loggedBreak = false
    private var stopped = false
    private weak var view: IVSPlayerView?
    private var pip: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var detachedForBackground = false
    private var audioOnlyForBackground = false
    private var pausedForBackground = false
    private var notificationTokens: [NSObjectProtocol] = []

    init(login: String, codecs: String, model: PlayerModel) {
      self.login = login.lowercased()
      self.codecs = codecs
      self.model = model
      super.init()
    }

    // MARK: Lifecycle

    func start() {
      proxy.controller = self
      player.delegate = proxy
      player.setUserAgent(Browser.userAgent)
      player.setOrigin(URL(string: "https://player.twitch.tv"))
      player.setLiveLowLatencyEnabled(AppSettings.shared.lowLatency)
      player.setRebufferToLive(true)
      player.setNetworkRecoveryMode(.resume)
      player.autoQualityMode = false
      let center = NotificationCenter.default
      notificationTokens.append(
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
          guard let controller = self else { return }
          Task { @MainActor in controller.enteredBackground() }
        })
      notificationTokens.append(
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
          guard let controller = self else { return }
          Task { @MainActor in controller.enteringForeground() }
        })
      load()
    }

    func stop() {
      stopped = true
      loadTask?.cancel()
      watchTask?.cancel()
      player.pause()
      player.delegate = nil
      proxy.controller = nil
      view?.player = nil
      pipObservation = nil
      pip = nil
      notificationTokens.forEach(NotificationCenter.default.removeObserver)
      notificationTokens = []
      StreamProxy.shared.remove(masterID)
    }

    /// Fresh token and master, then (re)load the player.
    private func load() {
      guard !stopped else { return }
      loadTask?.cancel()
      watchTask?.cancel()
      loadTask = Task { [weak self] in
        guard let controller = self else { return }
        await controller.loadStream()
      }
    }

    private func loadStream() async {
      do {
        let token = try await TwitchAPI.shared.streamToken(login: login, playerType: "popout", platform: "web")
        let usher = Usher.live(login: login, token: token, codecs: codecs, lowLatency: true)
        if useDirectURL {
          // Fallback if the player won't take a master from the local server: Twitch's URL
          // as-is (stitched-ad detection is off then, since it needs the same playlists).
          guard !stopped else { return }
          variants = []
          player.load(usher)
          return
        }
        let (data, response) = try await URLSessionHTTPClient(timeout: 8).data(for: Usher.playlistRequest(usher))
        guard !stopped, !Task.isCancelled else { return }
        if response.statusCode == 404 {
          model?.lowLatencyOffline()
          return
        }
        guard response.statusCode == 200, HLS.looksLikePlaylist(data), let text = String(data: data, encoding: .utf8) else {
          throw StreamSession.StartError.usher(response.statusCode)
        }
        let base = response.url ?? usher
        variants = HLSMaster.parse(text, base: base).videoVariants
        guard !variants.isEmpty else { throw StreamSession.StartError.noVariants }
        // The player loads the very same master (same Twitch playback session) from the local
        // server, so the playlists Kestrel polls for stitched ads are the ones it plays.
        await StreamProxy.shared.ensureResponsive()
        guard !stopped, !Task.isCancelled else { return }
        let url = try StreamProxy.shared.publish(HLSMaster.localCopy(of: text, base: base), id: masterID)
        player.load(url)
        ActivityLog.shared.add("Low-latency player: \(login) (\(variants.map(\.label).joined(separator: ", ")))")
        startWatching()
      } catch is CancellationError {
      } catch {
        failed(error.localizedDescription, byPlayer: false)
      }
    }

    private func failed(_ message: String, byPlayer: Bool) {
      guard !stopped else { return }
      failures = failures.filter { Date().timeIntervalSince($0) < 90 } + [Date()]
      if byPlayer, !everReady, !useDirectURL {
        useDirectURL = true
        ActivityLog.shared.add("Low-latency player couldn't open the stream (\(message)); trying Twitch's URL directly")
        load()
      } else if failures.count <= 2 {
        ActivityLog.shared.add("Low-latency player error (\(message)), reconnecting")
        load()
      } else {
        model?.lowLatencyFailed(message)
      }
    }

    // MARK: Player events (forwarded from the delegate proxy on the main queue)

    fileprivate func stateChanged(_ state: IVSPlayer.State) {
      guard !stopped, let model else { return }
      switch state {
      case .ready:
        everReady = true
        refreshQualities()
        if model.phase != .playing { model.phase = .playing }
        if !pausedForBackground { player.play() }
      case .buffering:
        model.isBuffering = true
      case .playing:
        model.isBuffering = false
        if model.phase != .playing { model.phase = .playing }
      case .idle:
        break
      case .ended:
        Task { [weak self] in
          guard let controller = self else { return }
          if let page = try? await TwitchAPI.shared.channelPage(login: controller.login), page.stream == nil {
            controller.model?.lowLatencyOffline()
          } else {
            controller.load()
          }
        }
      @unknown default:
        break
      }
      isPaused = state == .idle && everReady
    }

    fileprivate func playerFailed(_ error: Error) {
      failed((error as NSError).localizedDescription, byPlayer: true)
    }

    fileprivate func qualityChanged(_ quality: IVSQuality?) {
      // Twitch can change the rendition list mid-stream (e.g. the broadcaster restarts).
      if let quality, !menuQualities.contains(where: { $0.isEqual(to: quality) }) { refreshQualities() }
    }

    // MARK: Qualities: always the best one unless picked otherwise

    private func refreshQualities() {
      let all = player.qualities
      let landscape = all.filter { $0.width > 0 && $0.width >= $0.height }.sorted { a, b in
        (a.height, Int(a.framerate.rounded()), Self.codecRank(a), a.bitrate)
          > (b.height, Int(b.framerate.rounded()), Self.codecRank(b), b.bitrate)
      }
      let audio = all.filter { $0.width == 0 }
      menuQualities = landscape + audio.prefix(1)
      model?.qualities =
        menuQualities.enumerated().map { PlayerModel.Quality(id: $0.offset, label: Self.label($0.element)) }
        + [PlayerModel.Quality(id: nil, label: "Auto")]
      if let chosen, chosen >= menuQualities.count { self.chosen = 0 }
      model?.selectedQuality = chosen
      if !audioOnlyForBackground { applyChosen() }
    }

    func select(_ index: Int?) {
      chosen = index
      applyChosen()
    }

    private func applyChosen() {
      guard let index = chosen else {
        player.autoQualityMode = true
        return
      }
      guard index < menuQualities.count else { return }
      let quality = menuQualities[index]
      player.autoQualityMode = false
      if player.quality.map({ !$0.isEqual(to: quality) }) ?? true { player.quality = quality }
    }

    private static func codecRank(_ quality: IVSQuality) -> Int {
      switch HLS.codecFamily(quality.codecs) {
      case "hevc": return 2
      case "av1": return 1
      default: return 0
      }
    }

    private static func label(_ quality: IVSQuality) -> String {
      if quality.width == 0 { return "Audio only" }
      let fps = quality.framerate > 31 ? String(Int(quality.framerate.rounded())) : ""
      let base = "\(min(quality.width, quality.height))p\(fps)"
      switch HLS.codecFamily(quality.codecs) {
      case "hevc": return base + " HEVC"
      case "av1": return base + " AV1"
      default: return base
      }
    }

    // MARK: Stitched ads (rare since Twitch moved to client-side ads)

    /// The playlist of the rendition being played, from the master Kestrel fetched.
    private var watchedPlaylistURL: URL? {
      guard !variants.isEmpty else { return nil }
      guard let quality = player.quality, quality.width > 0 else { return URL(string: variants[0].uri) }
      let family = HLS.codecFamily(quality.codecs)
      let match = variants.filter { $0.width == quality.width && $0.height == quality.height }
        .min { a, b in
          let ca = a.codecFamily == family ? 0 : 1, cb = b.codecFamily == family ? 0 : 1
          return (ca, abs(a.bandwidth - quality.bitrate)) < (cb, abs(b.bandwidth - quality.bitrate))
        }
      return URL(string: (match ?? variants[0]).uri)
    }

    private func startWatching() {
      watchTask?.cancel()
      adTimeline = AdTimeline()
      watchTask = Task { [weak self] in
        let http = URLSessionHTTPClient(timeout: 5)
        while !Task.isCancelled {
          guard let controller = self else { return }
          if let url = controller.watchedPlaylistURL,
            let result = try? await http.data(for: Usher.playlistRequest(url, timeout: 5)),
            result.1.statusCode == 200, let text = String(data: result.0, encoding: .utf8)
          {
            controller.adTimeline.update(with: HLSMediaPlaylist.parse(text, base: url))
          }
          try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
      }
    }

    // MARK: Ticking (PlayerModel's timer)

    func tick() {
      guard let model, !stopped else { return }
      let seconds = player.liveLatency.seconds
      let latency = seconds.isFinite && seconds >= 0 ? seconds : nil
      model.latency = latency

      // The frame on screen was stamped `latency` seconds ago.
      let inAd = latency.map { adTimeline.covers(Date().addingTimeInterval(-$0)) } ?? adTimeline.isActive
      if inAd != model.coveringAd { model.coveringAd = inAd }
      if inAd, !player.muted {
        player.muted = true
        mutedForAd = true
      } else if !inAd, mutedForAd {
        player.muted = false
        mutedForAd = false
      }
      let state: AdState = inAd ? .covering : (adTimeline.markerActive ? .skipped : .none)
      if model.adState != state { model.adState = state }
      if adTimeline.isActive, !loggedBreak {
        loggedBreak = true
        ActivityLog.shared.add("Ad stitched into \(login)'s stream: hidden and muted (low-latency player)")
      } else if !adTimeline.isActive, loggedBreak {
        loggedBreak = false
        ActivityLog.shared.add("Stitched ad over on \(login)")
      }
    }

    // MARK: Controls

    func togglePause() {
      if player.state == .playing || player.state == .buffering {
        player.pause()
        isPaused = true
      } else {
        // Paused live video is behind; start again at the live edge (with a fresh token, since
        // the old one may have expired).
        isPaused = false
        load()
      }
    }

    /// Reloads at the live edge.
    func goLive() {
      load()
    }

    var canPictureInPicture: Bool { pip?.isPictureInPicturePossible ?? false }

    func togglePictureInPicture() {
      guard let pip else { return }
      if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    // MARK: View, Picture in Picture, background audio

    func attach(_ view: IVSPlayerView) {
      guard self.view !== view else { return }
      self.view = view
      if !detachedForBackground { view.player = player }
      guard AVPictureInPictureController.isPictureInPictureSupported(),
        let pip = AVPictureInPictureController(ivsPlayerLayer: view.playerLayer)
      else { return }
      pip.canStartPictureInPictureAutomaticallyFromInline = true
      pip.delegate = proxy
      pipObservation = pip.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] pip, _ in
        let active = pip.isPictureInPictureActive
        guard let controller = self else { return }
        Task { @MainActor in controller.pictureInPictureActive = active }
      }
      self.pip = pip
    }

    private func enteredBackground() {
      guard !stopped, !proxy.pictureInPictureStarting, !(pip?.isPictureInPictureActive ?? false) else { return }
      if AppSettings.shared.backgroundAudio {
        // Keep the sound: take the picture off screen and switch to the audio-only rendition.
        detachedForBackground = true
        view?.player = nil
        if let audio = menuQualities.first(where: { $0.width == 0 }) {
          audioOnlyForBackground = true
          player.autoQualityMode = false
          player.quality = audio
        }
      } else {
        pausedForBackground = true
        player.pause()
      }
    }

    private func enteringForeground() {
      guard !stopped else { return }
      if detachedForBackground {
        detachedForBackground = false
        view?.player = player
      }
      if audioOnlyForBackground {
        audioOnlyForBackground = false
        applyChosen()
      }
      if pausedForBackground {
        pausedForBackground = false
        goLive()
      }
    }
  }

  /// IVS and AVKit call their delegates on the main queue; this forwards to the controller.
  final class LowLatencyDelegateProxy: NSObject, IVSPlayer.Delegate, AVPictureInPictureControllerDelegate {
    weak var controller: LowLatencyController?
    /// Set synchronously so the background handler knows PiP is taking over.
    private(set) var pictureInPictureStarting = false

    // Explicit selectors: IVS looks these up by their Objective-C names.
    @objc(player:didChangeState:)
    func player(_ player: IVSPlayer, didChangeState state: IVSPlayer.State) {
      let controller = self.controller
      Task { @MainActor in controller?.stateChanged(state) }
    }

    @objc(player:didFailWithError:)
    func player(_ player: IVSPlayer, didFailWithError error: Error) {
      let controller = self.controller
      Task { @MainActor in controller?.playerFailed(error) }
    }

    @objc(player:didChangeQuality:)
    func player(_ player: IVSPlayer, didChangeQuality quality: IVSQuality?) {
      let controller = self.controller
      Task { @MainActor in controller?.qualityChanged(quality) }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
      pictureInPictureStarting = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
      pictureInPictureStarting = false
    }

    func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
    ) {
      pictureInPictureStarting = false
    }

    func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
      completionHandler(true)
    }
  }

  struct LowLatencyVideoView: UIViewRepresentable {
    let controller: LowLatencyController

    func makeUIView(context: Context) -> IVSPlayerView {
      let view = IVSPlayerView()
      view.backgroundColor = .black
      view.videoGravity = .resizeAspect
      controller.attach(view)
      return view
    }

    func updateUIView(_ view: IVSPlayerView, context: Context) {
      controller.attach(view)
    }
  }

  /// The video plus minimal controls (the SDK's view has none): tap to show pause and PiP.
  struct LowLatencySurface: View {
    @ObservedObject var controller: LowLatencyController
    @State private var controlsVisible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
      ZStack {
        LowLatencyVideoView(controller: controller)
        Color.black.opacity(controlsVisible ? 0.35 : 0.001)
          .contentShape(Rectangle())
          .onTapGesture { toggleControls() }
        if controlsVisible || controller.isPaused {
          HStack(spacing: 36) {
            Button {
              controller.togglePause()
              scheduleHide()
            } label: {
              Image(systemName: controller.isPaused ? "play.fill" : "pause.fill").font(.system(size: 30))
            }
            .accessibilityLabel(controller.isPaused ? "Play" : "Pause")
            if AVPictureInPictureController.isPictureInPictureSupported() {
              Button {
                controller.togglePictureInPicture()
                scheduleHide()
              } label: {
                Image(systemName: controller.pictureInPictureActive ? "pip.exit" : "pip.enter").font(.system(size: 24))
              }
              .accessibilityLabel("Picture in Picture")
            }
          }
          .foregroundColor(.white)
          .transition(.opacity)
        }
      }
    }

    private func toggleControls() {
      withAnimation(.easeInOut(duration: 0.15)) { controlsVisible.toggle() }
      if controlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
      hideTask?.cancel()
      hideTask = Task {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
      }
    }
  }
#endif
