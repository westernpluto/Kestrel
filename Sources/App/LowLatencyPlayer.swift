// The low-latency live player, built on the Amazon IVS Player SDK (the engine Twitch's own apps
// use). Compiled only when the SDK is present: the GitHub Actions build downloads it.
//
// The player loads its playlists from Kestrel's local server (LowLatencySession), which removes
// ad markers and swaps in an ad-free copy of the stream while an ad is stitched into the video.

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
    private var session: LowLatencySession?
    private var loadTask: Task<Void, Never>?
    /// Twitch's renditions (from the master playlist), best first.
    private var upstream: [HLSVariant] = []
    /// Qualities the player can play: landscape best first, then audio only.
    private var menuQualities: [IVSQuality] = []
    /// Better renditions Twitch offers that this player can't decode (played by the Apple player).
    private var applePlayerOnly: [HLSVariant] = []
    private var chosen: Int? = 0  // index into menuQualities, nil = Auto
    private var everReady = false
    private var reportedQualities = false
    private var useDirectURL = false
    private var failures: [Date] = []
    private var adTimeline = AdTimeline()
    private var adState: AdState = .none
    private var mutedForAd = false
    private var stopped = false
    private weak var view: IVSPlayerView?
    private var pip: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var detachedForBackground = false
    private var audioOnlyForBackground = false
    private var pausedForBackground = false
    private var notificationTokens: [NSObjectProtocol] = []

    /// Quality-menu IDs at or above this pick a rendition for the Apple player.
    static let applePlayerQualityBase = 1000

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
      player.pause()
      player.delegate = nil
      proxy.controller = nil
      view?.player = nil
      pipObservation = nil
      pip = nil
      notificationTokens.forEach(NotificationCenter.default.removeObserver)
      notificationTokens = []
      if let session { StreamProxy.shared.remove(session.id) }
      session = nil
    }

    /// Fresh token and playlists, then (re)load the player at the live edge.
    private func load() {
      guard !stopped else { return }
      loadTask?.cancel()
      loadTask = Task { [weak self] in
        guard let controller = self else { return }
        await controller.loadStream()
      }
    }

    private func loadStream() async {
      do {
        if useDirectURL {
          // Last resort if the player won't load playlists from the local server: Twitch's URL
          // as-is. Ads can't be filtered this way.
          let token = try await TwitchAPI.shared.streamToken(login: login, playerType: "popout", platform: "web")
          guard !stopped else { return }
          player.load(Usher.live(login: login, token: token, codecs: codecs, lowLatency: true))
          return
        }
        let settings = AppSettings.shared
        var config = LowLatencyConfig()
        config.codecs = codecs
        config.backupStreams = settings.backupStreams
        config.allowLowQualityBackup = settings.allowLowQualityBackup
        let session = LowLatencySession(
          login: login, config: config, http: URLSessionHTTPClient(timeout: 8), tokens: TwitchAPI.shared
        ) { [weak self] update in
          guard let controller = self else { return }
          Task { @MainActor in controller.apply(update) }
        }
        let variants = try await session.start()
        guard !stopped, !Task.isCancelled else { return }
        await StreamProxy.shared.ensureResponsive()
        guard !stopped, !Task.isCancelled else { return }
        if let old = self.session { StreamProxy.shared.remove(old.id) }
        self.session = session
        upstream = variants.filter { !$0.isAudioOnly }.sorted {
          ($0.height, $0.frameRate, $0.codecRank, $0.bandwidth) > ($1.height, $1.frameRate, $1.codecRank, $1.bandwidth)
        }
        adTimeline = AdTimeline()
        player.load(try StreamProxy.shared.register(session))
      } catch is CancellationError {
      } catch StreamSession.StartError.offline {
        model?.lowLatencyOffline()
      } catch {
        failed(error.localizedDescription, byPlayer: false)
      }
    }

    private func failed(_ message: String, byPlayer: Bool) {
      guard !stopped else { return }
      failures = failures.filter { Date().timeIntervalSince($0) < 90 } + [Date()]
      if byPlayer, !everReady, !useDirectURL {
        useDirectURL = true
        ActivityLog.shared.add("Low-latency player couldn't open the stream (\(message)); trying Twitch's URL directly (no ad filtering)")
        load()
      } else if failures.count <= 2 {
        ActivityLog.shared.add("Low-latency player error (\(message)), reconnecting")
        load()
      } else {
        model?.lowLatencyFailed(message)
      }
    }

    private func apply(_ update: LowLatencyUpdate) {
      adTimeline = update.ads
      adState = update.state
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

      // Renditions above the best one this player can decode (e.g. 1440p in a codec it doesn't
      // support): offered through the Apple player.
      let bestHeight = landscape.first?.height ?? 0
      applePlayerOnly = upstream.filter { $0.height > bestHeight }
      if !reportedQualities {
        reportedQualities = true
        var message = "Low-latency player can play: \(menuQualities.map(Self.label).joined(separator: ", "))"
        if !applePlayerOnly.isEmpty {
          message += ". Only in the Apple player: \(applePlayerOnly.map(\.label).joined(separator: ", "))"
        }
        ActivityLog.shared.add(message)
      }
      if let best = applePlayerOnly.first, AppSettings.shared.highestQualityOverLatency, model?.mayAutoSwitchPlayer == true {
        model?.switchToApplePlayer(quality: best.label, reason: "\(best.label) only plays in the Apple player", automatic: true)
        return
      }

      model?.qualities =
        menuQualities.enumerated().map { PlayerModel.Quality(id: $0.offset, label: Self.label($0.element)) }
        + applePlayerOnly.enumerated().map {
          PlayerModel.Quality(id: Self.applePlayerQualityBase + $0.offset, label: "\($0.element.label) · Apple player")
        }
        + [PlayerModel.Quality(id: nil, label: "Auto")]
      if let chosen, chosen >= menuQualities.count { self.chosen = 0 }
      model?.selectedQuality = chosen
      if !audioOnlyForBackground { applyChosen() }
    }

    func select(_ index: Int?) {
      if let index, index >= Self.applePlayerQualityBase {
        let offset = index - Self.applePlayerQualityBase
        guard offset < applePlayerOnly.count else { return }
        model?.switchToApplePlayer(quality: applePlayerOnly[offset].label, reason: "picked \(applePlayerOnly[offset].label)", automatic: false)
        return
      }
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

    // MARK: Ticking (PlayerModel's timer)

    func tick() {
      guard let model, !stopped else { return }
      let seconds = player.liveLatency.seconds
      let latency = seconds.isFinite && seconds >= 0 ? seconds : nil
      model.latency = latency

      // Only when no ad-free copy was found does the player get ad video; hide it while the frame
      // on screen (stamped `latency` seconds ago) is inside an ad.
      let inAd = latency.map { adTimeline.covers(Date().addingTimeInterval(-$0)) } ?? adTimeline.isActive
      if inAd != model.coveringAd { model.coveringAd = inAd }
      if inAd, !player.muted {
        player.muted = true
        mutedForAd = true
      } else if !inAd, mutedForAd {
        player.muted = false
        mutedForAd = false
      }
      let shown: AdState = inAd ? .covering : (adState == .covering ? .searching : adState)
      if model.adState != shown { model.adState = shown }
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
