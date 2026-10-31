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
    /// Index into menuQualities, nil = Auto (which stays on for later streams once picked).
    private var chosen: Int? = AppSettings.shared.autoQuality ? nil : 0
    private var everReady = false
    private var reportedQualities = false
    private var useDirectURL = false
    private var failures: [Date] = []
    private var adTimeline = AdTimeline()
    private var adState: AdState = .none
    /// A multi-view tile: starts on Auto, no Picture in Picture, and pauses in the background
    /// unless it's the one being listened to.
    var tile = false
    /// Muted by choice (multi-view: every tile but the one being listened to).
    private var userMuted = false
    /// The tallest picture worth fetching (multi-view: as big as the tile is shown); nil for any.
    private var maxHeight: Int?
    private var stopped = false
    private weak var view: IVSPlayerView?
    private var pip: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var pipPossibleObservation: NSKeyValueObservation?
    /// The PiP button was pressed while PiP wasn't possible yet: start it as soon as it is.
    private var pipWanted = false
    /// Waits a moment after going to the background before taking the picture away (see
    /// `enteredBackground`).
    private var backgroundSettleTask: Task<Void, Never>?
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
    /// Keeps Auto from going back up to a quality that just stalled (see `SteadyAutoQuality`).
    private var steadyAuto = SteadyAutoQuality(count: 0)
    /// The cap last handed to the player (rank into the video qualities).
    private var appliedAutoCap: Int?
    /// Played since the last load (buffering after that means the player ran dry).
    private var playedSinceLoad = false
    /// Start at the newest video (see `LowLatencyPlaylist.startingAtNewest`). Turned off for this
    /// stream if a start that way doesn't get going.
    private var edgeStart = true
    /// When the player was handed the stream (until it plays).
    private var loadedAt: Date?
    private var lastQualitySwitch = Date.distantPast
    /// IVS documents `buffered` as what's left in the buffer, but has also behaved like the
    /// buffer's end position: it's what's left once it's seen below the playhead.
    private var bufferedIsRemaining = false
    /// Kept across reloads, so going live again doesn't open new connections to Twitch.
    private var http: (client: HTTPClient, proxy: HTTPProxy?)?
    /// The frames the picture shows, for the MetalFX upscaler (see VideoUpscaler).
    private(set) lazy var displayedFrames = DisplayedFrames { [weak self] in self?.view?.layer }
    /// Twitch's playlist server for this stream, as the stats show it.
    private var videoServer: String?
    private var serverCheckedAt = Date.distantPast
    /// A stream that keeps running dry gets a few seconds in hand instead of restarts (see
    /// `StreamSteadiness`); remembered for the channel for a day.
    private var steadiness: StreamSteadiness

    private func refreshServer(_ session: LowLatencySession) async {
      serverCheckedAt = Date()
      guard let host = await session.servingHost else { return }
      let nearby = await session.servingNearby
      var text = LowLatencySession.serverName(host: host)
      if nearby {
        text += " · near you"
      } else if case .adFreeServer = route {
        text += " · ad-free server's"
      }
      videoServer = text
    }

    /// How much video to have before starting. Low latency: half a second (the player's own
    /// default is a second; `LiveCatchUp` keeps it from building up after that); more for a stream
    /// that keeps running dry.
    private func startBuffer(lowLatency: Bool) -> CMTime {
      CMTime(seconds: steadiness.unsteady ? 2.5 : lowLatency ? 0.5 : 2.0, preferredTimescale: 1000)
    }

    /// Quality-menu IDs at or above this pick a rendition for the Apple player.
    static let applePlayerQualityBase = 1000

    init(login: String, codecs: String, model: PlayerModel) {
      self.login = login.lowercased()
      self.codecs = codecs
      self.model = model
      steadiness = StreamSteadiness(unsteady: UnsteadyChannels.contains(login))
      super.init()
    }

    // MARK: Lifecycle

    func start() {
      proxy.controller = self
      player.delegate = proxy
      player.setUserAgent(Browser.userAgent)
      player.setOrigin(URL(string: "https://player.twitch.tv"))
      player.setLiveLowLatencyEnabled(AppSettings.shared.lowLatency)
      player.setInitialBufferDuration(startBuffer(lowLatency: AppSettings.shared.lowLatency))
      // Auto starts from the quality that last played smoothly, not from a guess.
      if let bitrate = PlaybackMemory.autoBitrate { player.setAutoInitialBitrate(bitrate) }
      player.setRebufferToLive(!steadiness.unsteady)
      player.setNetworkRecoveryMode(.resume)
      if steadiness.unsteady {
        applySteadiness(announce: false)
        ActivityLog.shared.add("\(login) kept running dry last time: keeping \(Int(StreamSteadiness.buffer)) s in hand")
      }
      player.autoQualityMode = false
      if tile { chosen = nil }
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
      backgroundSettleTask?.cancel()
      loadTask?.cancel()
      audioOnlyTask?.cancel()
      player.pause()
      player.delegate = nil
      proxy.controller = nil
      view?.player = nil
      pipObservation = nil
      pipPossibleObservation = nil
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
        config.nearbyServers = settings.nearbyServers
        config.startAtLiveEdge = settings.lowLatency && edgeStart
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
        await refreshServer(session)
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
      loadedAt = Date()
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
        noteRestart()
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

    /// Starts playback over at the live edge (with the stream asked for afresh), at most every 20
    /// seconds. (Reloading the same playlists kept the player from reporting its latency.)
    private func reload(reason: String, trouble: Bool = false) {
      guard !stopped, Date().timeIntervalSince(lastReload) > 20 else { return }
      lastReload = Date()
      bufferingSince = nil
      ActivityLog.shared.add("Low-latency player: reloading (\(reason))")
      if trouble { noteRestart() }
      load()
    }

    // MARK: Streams that keep running dry

    private func noteStall() {
      if steadiness.stalled() { becameUnsteady() }
    }

    private func noteRestart() {
      if steadiness.restarted() { becameUnsteady() }
    }

    private func becameUnsteady() {
      ActivityLog.shared.add(
        "\(login)'s stream keeps running dry (a shaky upload or connection): keeping \(Int(StreamSteadiness.buffer)) s in hand instead of restarting, a little further behind live")
      UnsteadyChannels.mark(login)
      applySteadiness(announce: true)
    }

    /// Unsteady: more in hand, only gentle catching up, no jump to live after a stall (that skip
    /// and the restarts were what looked like the stream refreshing), no start at the newest
    /// segment. Steady again: back to keeping it close.
    private func applySteadiness(announce: Bool) {
      let unsteady = steadiness.unsteady
      catchUp.setFloor(unsteady ? StreamSteadiness.buffer : 0)
      player.setRebufferToLive(!unsteady)
      player.setInitialBufferDuration(startBuffer(lowLatency: AppSettings.shared.lowLatency))
      if unsteady { edgeStart = false }
      if announce, !unsteady {
        ActivityLog.shared.add("\(login)'s stream has played smoothly for a while: keeping it close to live again")
        UnsteadyChannels.clear(login)
      }
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
          noteStall()
          if player.playbackRate != 1 { player.playbackRate = 1 }
          if chosen == nil, steadyAuto.stalled() { applyAutoCap() }
        }
      case .playing:
        playedSinceLoad = true
        loadedAt = nil
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
      defer { updateAudioOnly() }
      // Twitch can change the rendition list mid-stream (e.g. the broadcaster restarts).
      if let quality, !menuQualities.contains(where: { $0.isEqual(to: quality) }) {
        refreshQualities()
        return
      }
      // Auto moved: don't speed up while the new quality fills in, and note it for keeping
      // Auto steady.
      guard let quality, chosen == nil, !audioOnlyForBackground else { return }
      catchUp.hold(for: 3)
      if let rank = videoQualities.firstIndex(where: { $0.isEqual(to: quality) }), steadyAuto.switched(to: rank) {
        applyAutoCap()
      }
    }

    private var videoQualities: [IVSQuality] { menuQualities.filter { $0.width > 0 } }

    /// Tells the screen when the audio-only rendition is playing (picked, or still on after the
    /// background while the picture comes back).
    private func updateAudioOnly() {
      guard let model else { return }
      let playingAudio = player.quality.map { $0.width == 0 } ?? false
      let pickedAudio = chosen.map { $0 < menuQualities.count && menuQualities[$0].width == 0 } ?? false
      let state: PlayerModel.AudioOnly? = playingAudio || pickedAudio ? (pickedAudio ? .chosen : .returning) : nil
      if model.audioOnly != state { model.audioOnly = state }
    }

    /// Hands the player Auto's current limit (see `SteadyAutoQuality`).
    private func applyAutoCap() {
      let video = videoQualities
      guard chosen == nil, !video.isEmpty else { return }
      let steady = steadyAuto.cap.map { min($0, video.count - 1) }
      var cap = steady
      if let maxHeight, let index = video.firstIndex(where: { min($0.width, $0.height) <= maxHeight }) {
        cap = max(cap ?? 0, index)
      }
      guard cap != appliedAutoCap else { return }
      appliedAutoCap = cap
      player.setAutoMaxQuality(video[cap ?? 0])
      if tile { return }
      if let cap, cap > 0 {
        ActivityLog.shared.add(
          "Auto quality: staying at \(Self.label(video[cap])) or lower for now (\(Self.label(video[cap - 1])) kept stalling)")
      } else {
        ActivityLog.shared.add("Auto quality: every quality allowed again")
      }
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
      let videoCount = landscape.count
      if steadyAuto.count != videoCount {
        steadyAuto.reset(count: videoCount)
        appliedAutoCap = nil
      }
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
      // Auto stays on for later streams; picking a quality goes back to starting at the best.
      AppSettings.shared.autoQuality = index == nil
      applyChosen()
    }

    /// - Parameter smoothly: switch at the next chance without dropping what's buffered (no
    ///   rebuffer; the new quality shows a moment later).
    private func applyChosen(smoothly: Bool = false) {
      guard let index = chosen else {
        player.autoQualityMode = true
        // The player forgets its limit on a new stream: hand it over again.
        appliedAutoCap = nil
        if steadyAuto.cap != nil || maxHeight != nil { applyAutoCap() }
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
      updateAudioOnly()

      // Stay close to live: eat any extra buffer by playing a touch faster.
      let catchingUp =
        AppSettings.shared.lowLatency && player.isLiveLowLatency && player.state == .playing && !pausedForBackground
      let rate = catchUp.update(buffer: bufferAhead, latency: latency, playing: catchingUp)
      if player.playbackRate != rate { player.playbackRate = rate }

      // The session can go back to the ad-free server's playlist server mid-stream.
      if let session, Date().timeIntervalSince(serverCheckedAt) > 5 {
        serverCheckedAt = Date()
        Task { [weak self] in await self?.refreshServer(session) }
      }

      // A start at the newest video that doesn't get going: start the usual way instead.
      if let since = loadedAt, edgeStart, AppSettings.shared.lowLatency, !pausedForBackground, !isPaused,
        Date().timeIntervalSince(since) > 8, player.state != .playing
      {
        edgeStart = false
        loadedAt = nil
        ActivityLog.shared.add("Low-latency player: starting at the newest video didn't get going; starting the usual way")
        load()
      }

      // Auto: let it try a better quality again once a hold is over; remember what plays well.
      if chosen == nil, !audioOnlyForBackground {
        if steadyAuto.tick() { applyAutoCap() }
        // (Not from a multi-view tile: its limit is its size on screen, not the connection.)
        if !tile, let rank = steadyAuto.steadyRank(), rank < videoQualities.count {
          PlaybackMemory.autoBitrate = videoQualities[rank].bitrate
        }
      }

      // Stuck buffering (e.g. after a switch between copies of the stream): start again. A stream
      // that keeps running dry gets longer to come back by itself first (a restart only loses what
      // was in hand).
      if player.state == .buffering, !pausedForBackground, !detachedForBackground {
        if bufferingSince == nil { bufferingSince = Date() }
        if let since = bufferingSince, Date().timeIntervalSince(since) > (steadiness.unsteady ? 20 : 8) {
          reload(reason: "stuck buffering", trouble: true)
        }
      } else {
        bufferingSince = nil
      }
      if player.state == .playing, steadiness.tick() { applySteadiness(announce: true) }
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
      if player.muted != (inAd || userMuted) { player.muted = inAd || userMuted }
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
      if steadiness.unsteady {
        lines.append(StatLine(label: "Steadier", value: "keeping \(Int(StreamSteadiness.buffer)) s in hand (stream kept running dry)"))
      }
      let video = videoQualities
      if chosen == nil, let cap = appliedAutoCap, cap > 0, cap < video.count {
        lines.append(StatLine(label: "Auto limit", value: "\(Self.label(video[cap])) for now (\(Self.label(video[cap - 1])) stalled)"))
      }
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
        loadedAt = nil
      } else {
        // Paused live video is behind; start again at the live edge (with a fresh token, since
        // the old one may have expired).
        isPaused = false
        load()
      }
    }

    /// Starts over at the live edge, with the stream asked for afresh. The picture keeps playing
    /// meanwhile, until the new one is ready to load.
    func goLive() {
      lastReload = Date()
      bufferingSince = nil
      load()
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
      player.setInitialBufferDuration(startBuffer(lowLatency: enabled))
      lastReload = .distantPast
      reload(reason: enabled ? "low latency on" : "low latency off")
    }

    func setFill(_ fill: Bool) {
      view?.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    func setMuted(_ muted: Bool) {
      userMuted = muted
      let wanted = muted || (model?.coveringAd ?? false)
      if player.muted != wanted { player.muted = wanted }
    }

    func setVolume(_ volume: Float) {
      if player.volume != volume { player.volume = volume }
    }

    func setMaxHeight(_ height: Int?) {
      guard height != maxHeight else { return }
      maxHeight = height
      applyAutoCap()
    }

    func togglePictureInPicture() {
      if let pip, pip.isPictureInPictureActive {
        pip.stopPictureInPicture()
        return
      }
      if let pip, pip.isPictureInPicturePossible {
        pip.startPictureInPicture()
        return
      }
      // Not possible right now (the controller can go stale once the picture has been taken off
      // screen for background audio): make a fresh one and start as soon as it's ready.
      pipWanted = true
      if let view { makePictureInPicture(for: view) }
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        self?.pipWanted = false
      }
    }

    // MARK: View, Picture in Picture, background audio

    func attach(_ view: IVSPlayerView) {
      guard self.view !== view else { return }
      self.view = view
      if !detachedForBackground { view.player = player }
      if !tile { makePictureInPicture(for: view) }
    }

    private func makePictureInPicture(for view: IVSPlayerView) {
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
      pipPossibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] pip, _ in
        guard pip.isPictureInPicturePossible, let controller = self else { return }
        Task { @MainActor in
          guard controller.pipWanted, let current = controller.pip, current.isPictureInPicturePossible,
            !current.isPictureInPictureActive
          else { return }
          controller.pipWanted = false
          current.startPictureInPicture()
        }
      }
      self.pip = pip
    }

    /// Going to the background: Picture in Picture starts on its own as the app goes (when it
    /// can), so wait a moment before taking the picture away for background audio, which would
    /// stop it (that's how a swipe home sometimes went to audio instead of PiP).
    private func enteredBackground() {
      backgroundSettleTask?.cancel()
      backgroundSettleTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let controller = self, !Task.isCancelled else { return }
        controller.settleInBackground()
      }
    }

    private func settleInBackground() {
      guard !stopped, !suspended, UIApplication.shared.applicationState == .background,
        !proxy.pictureInPictureStarting, !(pip?.isPictureInPictureActive ?? false)
      else { return }
      if AppSettings.shared.backgroundAudio, !(tile && userMuted) {
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
      backgroundSettleTask?.cancel()
      backgroundSettleTask = nil
      audioOnlyTask?.cancel()
      audioOnlyTask = nil
      guard !stopped, !suspended else { return }
      if detachedForBackground {
        detachedForBackground = false
        view?.player = player
        // A fresh PiP controller for the picture that's back (the old one could stop working).
        if let view, !tile, !(pip?.isPictureInPictureActive ?? false) { makePictureInPicture(for: view) }
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
