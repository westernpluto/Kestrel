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
    /// Switches to audio only after a while in the background (not right away: a quick trip to
    /// Notification Center or another app shouldn't cost the picture a rebuffer on return).
    private var audioOnlyTask: Task<Void, Never>?
    private static let audioOnlyDelay: UInt64 = 45_000_000_000
    private var notificationTokens: [NSObjectProtocol] = []
    private var localURL: URL?
    private var route: StreamRoute = .twitch
    private var lastReload = Date.distantPast
    private var bufferingSince: Date?
    private var framesDecoded = (count: 0, at: Date())
    private var renderedFPS: Double?
    /// Paused while the viewer rewinds through the VOD.
    private var suspended = false
    /// Plays a touch faster while more is buffered than needed (see `LiveCatchUp`).
    private var catchUp = LiveCatchUp()
    /// Played since the last load (buffering after that means the player ran dry).
    private var playedSinceLoad = false
    private var lastQualitySwitch = Date.distantPast
    /// IVS documents `buffered` as what's left in the buffer, but has also behaved like the
    /// buffer's end position: it's what's left once it's seen below the playhead.
    private var bufferedIsRemaining = false
    /// Kept across reloads, so going live again doesn't open new connections to Twitch.
    private var http: (client: HTTPClient, proxy: HTTPProxy?)?
    /// Twitch's playlist server for this stream (`fra05`).
    private var videoServer: String?

    /// Low latency: start playing with half a second in hand (the player's own default is a
    /// second); `LiveCatchUp` keeps it from building up after that.
    private static let lowLatencyStartBuffer = CMTime(seconds: 0.5, preferredTimescale: 1000)
    private static let standardStartBuffer = CMTime(seconds: 2, preferredTimescale: 1000)

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
      player.setInitialBufferDuration(AppSettings.shared.lowLatency ? Self.lowLatencyStartBuffer : Self.standardStartBuffer)
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
      audioOnlyTask?.cancel()
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
          localURL = nil
          startPlayback(Usher.live(login: login, token: token, codecs: codecs, lowLatency: true))
          return
        }
        let settings = AppSettings.shared
        var config = LowLatencyConfig()
        config.codecs = codecs
        config.backupStreams = settings.backupStreams
        config.allowLowQualityBackup = settings.allowLowQualityBackup
        config.adFreeProxies = model?.adFreeProxies ?? settings.adFreeProxyHosts
        config.checkAccountFirst = TwitchAuth.shared.session != nil
        let session = LowLatencySession(
          login: login, config: config, http: playbackHTTP(), tokens: TwitchAPI.shared
        ) { [weak self] update in
          guard let controller = self else { return }
          Task { @MainActor in controller.apply(update) }
        }
        let variants = try await session.start()
        guard !stopped, !Task.isCancelled else { return }
        if TwitchAuth.shared.session != nil, let refused = TwitchAPI.shared.lastAuthFallback {
          ActivityLog.shared.add("Twitch refused the signed-in request (\(refused)), so this stream plays as a guest")
        }
        await StreamProxy.shared.ensureResponsive()
        guard !stopped, !Task.isCancelled else { return }
        if let old = self.session { StreamProxy.shared.remove(old.id) }
        self.session = session
        route = await session.route
        model?.route = route
        model?.checkDirectQualities(served: variants)
        upstream = variants.filter { !$0.isAudioOnly }.sorted {
          ($0.height, $0.frameRate, $0.codecRank, $0.bandwidth) > ($1.height, $1.frameRate, $1.codecRank, $1.bandwidth)
        }
        videoServer = variants.first.flatMap { LowLatencySession.serverName($0.uri) }
        adTimeline = AdTimeline()
        let url = try StreamProxy.shared.register(session)
        localURL = url
        lastReload = Date()
        startPlayback(url)
      } catch is CancellationError {
      } catch StreamSession.StartError.offline {
        model?.lowLatencyOffline()
      } catch {
        failed(error.localizedDescription, byPlayer: false)
      }
    }

    /// Loads into the player, at normal speed until it has settled.
    private func startPlayback(_ url: URL) {
      catchUp.restart()
      playedSinceLoad = false
      if player.playbackRate != 1 { player.playbackRate = 1 }
      player.load(url)
    }

    /// One HTTP client for this stream's playlists, kept while the proxy setting stays the same.
    private func playbackHTTP() -> HTTPClient {
      let settings = AppSettings.shared
      let proxy = settings.playbackProxy
      if let http, http.proxy == proxy { return http.client }
      let client = settings.playbackClient(timeout: 8)
      http = (client, proxy)
      return client
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
      let previous = adState
      adTimeline = update.ads
      adState = update.state
      // Back from an ad-free copy to the main stream: the player can get stuck on the switch
      // (TwitchAdSolutions reloads here too), so start it again at the live edge.
      if case .replaced = previous, update.state == .none || update.state == .skipped {
        reload(reason: "back from the ad-free copy")
      }
    }

    /// Restarts playback on the same playlists (quick: no new token).
    private func reload(reason: String) {
      guard !stopped, Date().timeIntervalSince(lastReload) > 20 else { return }
      lastReload = Date()
      bufferingSince = nil
      ActivityLog.shared.add("Low-latency player: reloading (\(reason))")
      if let localURL { startPlayback(localURL) } else { load() }
    }

    // MARK: Player events (forwarded from the delegate proxy on the main queue)

    fileprivate func stateChanged(_ state: IVSPlayer.State) {
      guard !stopped, !suspended, let model else { return }
      switch state {
      case .ready:
        everReady = true
        refreshQualities()
        if model.phase != .playing { model.phase = .playing }
        if !pausedForBackground { player.play() }
      case .buffering:
        model.isBuffering = true
        // Ran dry mid-stream (not a start, a pause or a quality switch): keep a bigger margin.
        if playedSinceLoad, !pausedForBackground, Date().timeIntervalSince(lastQualitySwitch) > 3 {
          catchUp.stalled()
          if player.playbackRate != 1 { player.playbackRate = 1 }
        }
      case .playing:
        playedSinceLoad = true
        model.isBuffering = false
        if model.phase != .playing { model.phase = .playing }
        model.liveResumed()
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

      model?.qualities =
        menuQualities.enumerated().map { PlayerModel.Quality(id: $0.offset, label: Self.label($0.element)) }
        + applePlayerOnly.enumerated().map {
          PlayerModel.Quality(id: Self.applePlayerQualityBase + $0.offset, label: "\($0.element.label) · Apple player")
        }
        + [PlayerModel.Quality(id: nil, label: "Auto")]
      if let chosen, chosen >= menuQualities.count { self.chosen = 0 }
      // Restarted for a particular quality (one only Twitch itself offered).
      if let label = model?.takePreferredQualityLabel() {
        if let index = menuQualities.firstIndex(where: { Self.label($0) == label }) {
          chosen = index
        } else if applePlayerOnly.contains(where: { $0.label == label }) {
          model?.switchToApplePlayer(quality: label, reason: "picked \(label)", automatic: false)
          return
        }
      }
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

    /// - Parameter smoothly: switch at the next chance without dropping what's buffered (no
    ///   rebuffer; the new quality shows a moment later).
    private func applyChosen(smoothly: Bool = false) {
      guard let index = chosen else {
        player.autoQualityMode = true
        return
      }
      guard index < menuQualities.count else { return }
      let quality = menuQualities[index]
      player.autoQualityMode = false
      guard player.quality.map({ !$0.isEqual(to: quality) }) ?? true else { return }
      lastQualitySwitch = Date()
      if smoothly {
        player.setQuality(quality, adaptive: true)
      } else {
        player.quality = quality
      }
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
      guard let model, !stopped, !suspended else { return }
      let seconds = player.liveLatency.seconds
      let latency = seconds.isFinite && seconds >= 0 ? seconds : nil
      model.setLatency(latency)

      // Stay close to live: eat any extra buffer by playing a touch faster.
      let catchingUp =
        AppSettings.shared.lowLatency && player.isLiveLowLatency && player.state == .playing && !pausedForBackground
      let rate = catchUp.update(buffer: bufferAhead, latency: latency, playing: catchingUp)
      if player.playbackRate != rate { player.playbackRate = rate }

      // Stuck buffering (e.g. after a switch between copies of the stream): start again.
      if player.state == .buffering, !pausedForBackground, !detachedForBackground {
        if bufferingSince == nil { bufferingSince = Date() }
        if let since = bufferingSince, Date().timeIntervalSince(since) > 8 { reload(reason: "stuck buffering") }
      } else {
        bufferingSince = nil
      }
      let decoded = player.videoFramesDecoded
      let elapsed = Date().timeIntervalSince(framesDecoded.at)
      if elapsed >= 1 {
        renderedFPS = decoded >= framesDecoded.count ? Double(decoded - framesDecoded.count) / elapsed : nil
        framesDecoded = (decoded, Date())
      }

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

    /// Seconds of video buffered ahead of what's showing.
    private var bufferAhead: Double? {
      let buffered = player.buffered.seconds
      let position = player.position.seconds
      guard buffered.isFinite, buffered >= 0 else { return nil }
      guard position.isFinite else { return buffered }
      if buffered + 0.5 < position { bufferedIsRemaining = true }
      return bufferedIsRemaining ? buffered : max(0, buffered - position)
    }

    /// Video stats for the overlay.
    func stats() -> [StatLine] {
      var lines = [StatLine(label: "Player", value: "Low latency (IVS \(player.version))")]
      lines.append(StatLine(label: "Low-latency mode", value: player.isLiveLowLatency ? "on" : "off"))
      if let quality = player.quality {
        lines.append(StatLine(label: "Quality", value: Self.label(quality) + (player.autoQualityMode ? " (auto)" : "")))
        lines.append(StatLine(label: "Codecs", value: quality.codecs.isEmpty ? "–" : quality.codecs))
        let fps = renderedFPS.map { String(format: " · rendering %.0f", $0) } ?? ""
        lines.append(StatLine(label: "Frame rate", value: String(format: "%.0f fps", quality.framerate) + fps))
      }
      let size = player.videoSize
      if size.width > 0 { lines.append(StatLine(label: "Resolution", value: "\(Int(size.width))×\(Int(size.height))")) }
      lines.append(StatLine(label: "Bitrate", value: StatFormat.mbps(Double(player.videoBitrate))))
      lines.append(StatLine(label: "Bandwidth", value: StatFormat.mbps(Double(player.bandwidthEstimate))))
      lines.append(StatLine(label: "Buffer", value: StatFormat.seconds(bufferAhead)))
      let latency = player.liveLatency.seconds
      lines.append(StatLine(label: "Latency", value: StatFormat.seconds(latency.isFinite && latency >= 0 ? latency : nil)))
      if AppSettings.shared.lowLatency {
        let margin = String(format: "keeping %.1f s", catchUp.targetBuffer)
        let speed = player.playbackRate > 1.001 ? String(format: "%.2f× · ", player.playbackRate) : "no · "
        lines.append(StatLine(label: "Catching up", value: speed + margin))
      }
      if let videoServer { lines.append(StatLine(label: "Video server", value: videoServer)) }
      lines.append(StatLine(label: "Frames", value: "\(player.videoFramesDecoded) decoded · \(player.videoFramesDropped) dropped"))
      lines.append(StatLine(label: "Ads", value: adState.statsText))
      lines.append(StatLine(label: "Playlists", value: localURL == nil ? "Twitch direct (no ad filtering)" : "Kestrel filter"))
      lines.append(StatLine(label: "Ad blocking", value: route.summary))
      lines.append(StatLine(label: "Account", value: TwitchAuth.shared.session?.login ?? "not signed in"))
      return lines
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

    /// Reloads at the live edge: on the same playlists while they're flowing (quick, over open
    /// connections), else with a fresh token.
    func goLive() {
      if let localURL, session != nil, player.state == .playing || player.state == .buffering {
        lastReload = Date()
        bufferingSince = nil
        startPlayback(localURL)
      } else {
        load()
      }
    }

    /// The viewer is watching the VOD (rewinding): stop the live stream for now.
    func suspend() {
      suspended = true
      loadTask?.cancel()
      player.pause()
      model?.coveringAd = false
    }

    /// Back from rewinding: live again at the live edge, on fresh playlists. (Reusing the old
    /// ones handed the player a stale playlist first, which threw off its idea of the live edge:
    /// latency read negative.) The VOD keeps playing meanwhile, so the wait doesn't show.
    func resumeLive() {
      suspended = false
      isPaused = false
      load()
    }

    /// Twitch's low-latency mode on or off (takes a quick reload).
    func setLowLatency(_ enabled: Bool) {
      player.setLiveLowLatencyEnabled(enabled)
      player.setInitialBufferDuration(enabled ? Self.lowLatencyStartBuffer : Self.standardStartBuffer)
      lastReload = .distantPast
      reload(reason: enabled ? "low latency on" : "low latency off")
    }

    func setFill(_ fill: Bool) {
      view?.videoGravity = fill ? .resizeAspectFill : .resizeAspect
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
      guard !stopped, !suspended, !proxy.pictureInPictureStarting, !(pip?.isPictureInPictureActive ?? false) else { return }
      if AppSettings.shared.backgroundAudio {
        // Keep the sound: take the picture off screen, and if it stays in the background a while,
        // switch to the audio-only rendition (saves data and battery while only listening).
        detachedForBackground = true
        view?.player = nil
        audioOnlyTask?.cancel()
        audioOnlyTask = Task { [weak self] in
          try? await Task.sleep(nanoseconds: Self.audioOnlyDelay)
          guard !Task.isCancelled else { return }
          self?.switchToAudioOnly()
        }
      } else {
        pausedForBackground = true
        player.pause()
      }
    }

    private func switchToAudioOnly() {
      guard detachedForBackground, !stopped, !suspended, !audioOnlyForBackground,
        let audio = menuQualities.first(where: { $0.width == 0 })
      else { return }
      audioOnlyForBackground = true
      lastQualitySwitch = Date()
      player.autoQualityMode = false
      player.quality = audio
    }

    private func enteringForeground() {
      audioOnlyTask?.cancel()
      audioOnlyTask = nil
      guard !stopped, !suspended else { return }
      if detachedForBackground {
        detachedForBackground = false
        view?.player = player
      }
      if audioOnlyForBackground {
        // Back to the picture without stopping the sound to rebuffer.
        audioOnlyForBackground = false
        applyChosen(smoothly: true)
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
    var fill: Bool

    func makeUIView(context: Context) -> IVSPlayerView {
      let view = IVSPlayerView()
      view.backgroundColor = .black
      view.videoGravity = fill ? .resizeAspectFill : .resizeAspect
      controller.attach(view)
      return view
    }

    func updateUIView(_ view: IVSPlayerView, context: Context) {
      controller.attach(view)
      let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
      if view.videoGravity != gravity { view.videoGravity = gravity }
    }
  }

#endif
