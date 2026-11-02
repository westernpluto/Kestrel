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
    /// The quality was picked in the menu (the best one by default otherwise, stepped down while
    /// the connection can't keep up with it: see ConnectionFit).
    private var pickedByHand = false
    private var connectionFit = ConnectionFit(count: 0)
    private var everReady = false
    private var reportedQualities = false
    private var useDirectURL = false
    private var failures: [Date] = []
    private var adTimeline = AdTimeline()
    private var adState: AdState = .none
    /// A multi-view tile: starts on Auto, no Picture in Picture (unless it's the picked one, see
    /// `pictureInPictureAllowed`), and pauses in the background unless it's the one being heard.
    var tile = false
    /// Multi-view: the picked stream can go into Picture in Picture (by the button, or by itself
    /// when the app goes to the background).
    var pictureInPictureAllowed = false {
      didSet {
        guard tile, oldValue != pictureInPictureAllowed else { return }
        if pictureInPictureAllowed {
          if let view, pip == nil { makePictureInPicture(for: view) }
        } else if !(pip?.isPictureInPictureActive ?? false) {
          pipObservation = nil
          pipPossibleObservation = nil
          pip = nil
        }
      }
    }
    private var offersPictureInPicture: Bool { !tile || pictureInPictureAllowed }
    /// Multi-view's all-streams Picture in Picture: the picture shows in this view (in the PiP
    /// window) instead of the tile's own, and carries on in the background like any PiP.
    private weak var sharedView: IVSPlayerView?
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
    /// Just back from the background: stalls until then are the return's doing.
    private var settlingUntil = Date.distantPast
    /// Just back from an ad-free copy to the main stream (see `apply`).
    private var switchedBackAt: Date?
    /// Since when this load has been playing, and whether how far from live it started is logged.
    private var playingSince: Date?
    private var reportedStart = false
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
    /// The player's bandwidth estimate, and when it last changed.
    private var bandwidthSeen: (value: Int, at: Date) = (0, Date())
    private var renderedFPS: Double?
    /// Paused while the viewer rewinds through the VOD.
    private var suspended = false
    /// Steers to the margin this stream needs with the playback speed alone, a touch faster or
    /// slower (see `LiveCatchUp`); never by jumping or restarting.
    private var catchUp: LiveCatchUp
    /// Keeps Auto from going back up to a quality that just stalled (see `SteadyAutoQuality`).
    private var steadyAuto = SteadyAutoQuality(count: 0)
    /// The cap last handed to the player (rank into the video qualities).
    private var appliedAutoCap: Int?
    /// The stall-driven limit last told to the log.
    private var lastLoggedSteady: Int?
    /// Played since the last load (buffering after that means the player ran dry).
    private var playedSinceLoad = false
    private var lastQualitySwitch = Date.distantPast
    /// IVS documents `buffered` as what's left in the buffer, but has also behaved like the
    /// buffer's end position: it's what's left once it's seen below the playhead.
    private var bufferedIsRemaining = false
    /// Kept across reloads, so going live again doesn't open new connections to Twitch.
    /// Twitch's playlist server for this stream, as the stats show it.
    private var videoServer: String?
    private var serverCheckedAt = Date.distantPast
    /// Buffering: the stream itself has stopped coming in for now (the broadcaster's side), so the
    /// player waits for it rather than restarting (see StreamArrival).
    private var waitingForStream = false
    /// Last ran dry, and last jumped ahead after falling far behind.
    private var lastStall = Date.distantPast
    private var lastFarJump = Date.distantPast
    /// The margin last logged (so the log says when it changes a lot, not every step).
    private var loggedMargin: Double

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

    /// How much video to have before starting. Low latency: always half a second (the player's own
    /// default is a second), even on a channel whose video arrived unevenly last time: waiting for
    /// more started those channels up to two seconds further from live. What such a channel needs
    /// is built up after the start instead, a touch slower for a few seconds (see `LiveCatchUp`).
    private func startBuffer(lowLatency: Bool) -> CMTime {
      CMTime(seconds: lowLatency ? 0.5 : 2.0, preferredTimescale: 1000)
    }

    // MARK: Starting at the live edge

    /// The jump to live after a start has been tried for this load.
    private var startJumpTried = false
    /// The first start: picture hidden and sound off (the spinner shows) until the jump to live is
    /// done, so it appears already close to live instead of visibly skipping ahead.
    private var concealing = false
    private static let concealAtMost: TimeInterval = 2.5

    private func reveal() {
      guard concealing else { return }
      concealing = false
      if let view {
        UIView.animate(withDuration: 0.18) { view.alpha = 1 }
      }
      let mute = userMuted || (model?.coveringAd ?? false)
      if player.muted != mute { player.muted = mute }
      if player.state == .playing { model?.isBuffering = false }
    }
    /// When it jumped (the buffering that can follow isn't a stall to learn from).
    private var startJumpAt = Date.distantPast
    /// Jumps only this soon after playback starts, and only for at least this much.
    private static let startJumpWindow: ClosedRange<TimeInterval> = 0.8...10
    private static let startJumpMinimum = 0.6

    /// Right after a start, the player often begins a couple of seconds back from the newest video
    /// it has. Winning that back by playing faster took up to half a minute; mid-stream that's the
    /// right way (a jump there empties what's in hand and sets up the next stall), but at the start
    /// there's nothing to lose. So once it's playing, it skips once over the extra video already
    /// downloaded, keeping what this stream needs in hand: no new request, no rebuffer, just playing
    /// from further ahead.
    private func jumpToLiveAfterStart(latency: Double?) {
      guard !startJumpTried, let since = playingSince else { return }
      let playing = Date().timeIntervalSince(since)
      // Hidden, it decides a little sooner (the extra video has come down by then).
      guard playing >= (concealing ? 0.5 : Self.startJumpWindow.lowerBound) else { return }
      guard playing <= Self.startJumpWindow.upperBound, AppSettings.shared.lowLatency, player.isLiveLowLatency,
        player.state == .playing, !pausedForBackground, let latency
      else {
        if playing > Self.startJumpWindow.upperBound || pausedForBackground || !AppSettings.shared.lowLatency {
          startJumpTried = true
          reveal()
        }
        return
      }
      startJumpTried = true
      // Only video known to be downloaded: the smaller of the two ways of reading `buffered` (see
      // `bufferAhead`), so the jump can't land past the end of it.
      let buffered = player.buffered.seconds
      let position = player.position.seconds
      guard buffered.isFinite, buffered > 0, position.isFinite else {
        reveal()
        return
      }
      let surely = bufferedIsRemaining || position <= 0 ? buffered : max(0, buffered - position)
      // Keep the margin in hand, lean: at most a second plus a little (more builds up after).
      let keep = max(catchUp.floor, min(catchUp.targetBuffer, LiveCatchUp.startBuffer)) + 0.25
      let skip = min(surely - keep, latency - keep - 0.3)
      guard skip >= Self.startJumpMinimum else {
        reveal()
        return
      }
      startJumpAt = Date()
      catchUp.hold(for: 2)
      if player.playbackRate != 1 { player.playbackRate = 1 }
      let login = self.login
      let skipped = String(format: "%.1f", skip), from = String(format: "%.1f", latency)
      player.seek(to: CMTime(seconds: position + skip, preferredTimescale: 1000)) { [weak self] finished in
        if finished {
          ActivityLog.shared.add("\(login): skipped \(skipped) s closer to live at the start (it was \(from) s behind)")
        } else {
          ActivityLog.shared.add("\(login): the player didn't take the skip to live at the start; catching up by speed instead")
        }
        // A moment for the picture after the skip to come up, then show it.
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 150_000_000)
          self?.reveal()
        }
      }
    }

    /// Quality-menu IDs at or above this pick a rendition for the Apple player.
    static let applePlayerQualityBase = 1000

    init(login: String, codecs: String, model: PlayerModel) {
      self.login = login.lowercased()
      self.codecs = codecs
      self.model = model
      // What this channel needed last time, so it doesn't have to stall to learn it again.
      // (At most a second to start with: more had it start close to live and then drift a couple
      // of seconds back while it built the rest up. It's learned again if this session needs it.)
      let remembered = ChannelMargins.margin(for: login, network: NetworkWatch.shared.memoryKey)
      catchUp = LiveCatchUp(targetBuffer: remembered.map { min($0, LiveCatchUp.startBuffer) })
      catchUp.setFloor(NetworkWatch.shared.floor)
      loggedMargin = catchUp.targetBuffer
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
      // After running dry, carry on from where it stopped, never skip to the live edge: the skip
      // empties what's in hand and sets up the next stall (on a shaky stream that became a loop of
      // skips). The speed steering wins the time back smoothly instead.
      player.setRebufferToLive(false)
      player.setNetworkRecoveryMode(.resume)
      if catchUp.learnedUneven {
        ActivityLog.shared.add(
          "\(login)'s video arrived unevenly last time: starting close to live, then building up \(Self.seconds(catchUp.targetBuffer)) in hand")
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
      notificationTokens.append(
        center.addObserver(forName: NetworkWatch.changed, object: nil, queue: .main) { [weak self] _ in
          guard let controller = self else { return }
          Task { @MainActor in controller.networkChanged() }
        })
      load()
    }

    func stop() {
      if !stopped { ChannelMargins.remember(catchUp.targetBuffer, for: login, network: NetworkWatch.shared.memoryKey) }
      stopped = true
      backgroundSettleTask?.cancel()
      loadTask?.cancel()
      audioOnlyTask?.cancel()
      player.pause()
      player.delegate = nil
      proxy.controller = nil
      view?.player = nil
      if let sharedView, sharedView.player === player { sharedView.player = nil }
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
      catchUp.restart()
      playedSinceLoad = false
      playingSince = nil
      reportedStart = false
      startJumpTried = false
      // Only the first start of the stream is hidden (later loads take over from a picture
      // that's already showing: going back to live, reloads).
      if !everReady, !tile, AppSettings.shared.lowLatency {
        concealing = true
        view?.alpha = 0
        if !player.muted { player.muted = true }
      }
      if player.playbackRate != 1 { player.playbackRate = 1 }
      player.load(url)
    }

    /// The playlists' HTTP client: shared by every stream, so its connections are already open.
    private func playbackHTTP() -> HTTPClient {
      AppSettings.shared.sharedPlaybackClient()
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
      // Back from an ad-free copy to the main stream. The player can get stuck on the switch: if it
      // does, it's started again within a few seconds (see `tick`). It used to be started again
      // every time, which showed as a refresh at the end of every ad break.
      if case .replaced = previous, update.state == .none || update.state == .skipped {
        switchedBackAt = Date()
      }
      // Onto or off an ad-free copy: a stall around the switch is the switch's doing, not the
      // stream's, so it doesn't raise the margin (which would keep it further behind afterwards).
      var switching = false
      if case .replaced = previous { switching = true }
      if case .replaced = update.state { switching = true }
      if switching, previous != update.state { settlingUntil = Date().addingTimeInterval(10) }
    }

    /// Starts playback over at the live edge (with the stream asked for afresh), at most every 20
    /// seconds. (Reloading the same playlists kept the player from reporting its latency.)
    private func reload(reason: String) {
      guard !stopped, Date().timeIntervalSince(lastReload) > 20 else { return }
      lastReload = Date()
      bufferingSince = nil
      ActivityLog.shared.add("Low-latency player: reloading (\(reason))")
      load()
    }

    /// Notes in the log when the margin this stream needs moves a fair way (a shaky upload, or one
    /// that settled down), and remembers it for the channel.
    private func noteMargin() {
      let margin = catchUp.targetBuffer
      guard abs(margin - loggedMargin) >= 0.5 else { return }
      let grew = margin > loggedMargin
      loggedMargin = margin
      ActivityLog.shared.add(
        grew
          ? "\(login)'s video is arriving unevenly: keeping \(Self.seconds(margin)) in hand (playing a touch slower to build it, no restarts)"
          : "\(login)'s video is arriving evenly again: down to \(Self.seconds(margin)) in hand")
      ChannelMargins.remember(margin, for: login, network: NetworkWatch.shared.memoryKey)
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
        if playedSinceLoad, !pausedForBackground, Date().timeIntervalSince(lastQualitySwitch) > 3,
          Date().timeIntervalSince(startJumpAt) > 3
        {
          lastStall = Date()
          if player.playbackRate != 1 { player.playbackRate = 1 }
          if Date() < settlingUntil || NetworkWatch.shared.sinceChange < 10 {
            catchUp.hold(for: 3)
          } else {
            catchUp.stalled()
            noteMargin()
            if chosen == nil, steadyAuto.stalled() { applyAutoCap() }
            // The stream kept arriving at the server, yet the player ran dry: the connection
            // couldn't keep up with this quality (no margin helps with that).
            if usesConnectionFit, let moved = session?.arrival.ages().moved, moved < 3, connectionFit.stalled() {
              applyConnectionFit(down: true)
            }
          }
        }
      case .playing:
        if playingSince == nil { playingSince = Date() }
        playedSinceLoad = true
        // (Still hidden while it jumps to live: the spinner stays until it's shown.)
        model.isBuffering = concealing
        setWaitingForStream(false)
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

    private static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

    private func setWaitingForStream(_ waiting: Bool) {
      guard waitingForStream != waiting else { return }
      waitingForStream = waiting
      if model?.waitingForStream != waiting { model?.waitingForStream = waiting }
    }

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
      // (A limit for the picture's size, multi-view or the mini player, isn't news.)
      if tile || cap != steady || steady == lastLoggedSteady { return }
      lastLoggedSteady = steady
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
          pickedByHand = true
        } else if applePlayerOnly.contains(where: { $0.label == label }) {
          model?.switchToApplePlayer(quality: label, reason: "picked \(label)")
          return
        }
      }
      model?.selectedQuality = chosen
      let videoCount = landscape.count
      if steadyAuto.count != videoCount {
        steadyAuto.reset(count: videoCount)
        appliedAutoCap = nil
      }
      if connectionFit.count != videoCount { connectionFit.reset(count: videoCount) }
      if !audioOnlyForBackground { applyChosen() }
    }

    func select(_ index: Int?) {
      if let index, index >= Self.applePlayerQualityBase {
        let offset = index - Self.applePlayerQualityBase
        guard offset < applePlayerOnly.count else { return }
        model?.switchToApplePlayer(quality: applePlayerOnly[offset].label, reason: "picked \(applePlayerOnly[offset].label)")
        return
      }
      chosen = index
      pickedByHand = index != nil
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
      // The best quality by default: as good as the connection keeps up with.
      let playing = usesConnectionFit ? min(connectionFit.step, max(0, videoQualities.count - 1)) : index
      guard playing < menuQualities.count else { return }
      let quality = menuQualities[playing]
      player.autoQualityMode = false
      guard player.quality.map({ !$0.isEqual(to: quality) }) ?? true else { return }
      lastQualitySwitch = Date()
      if smoothly {
        player.setQuality(quality, adaptive: true)
      } else {
        player.quality = quality
      }
    }

    /// The best quality, not picked by hand: stepped down while the connection can't carry it.
    private var usesConnectionFit: Bool { chosen == 0 && !pickedByHand && !tile }

    private func applyConnectionFit(down: Bool) {
      guard usesConnectionFit, !audioOnlyForBackground else { return }
      let video = videoQualities
      let step = connectionFit.step
      guard step < video.count else { return }
      if down, step > 0 {
        ActivityLog.shared.add(
          "\(Self.label(video[step - 1])) kept running dry on this connection while the stream itself was fine: "
            + "playing \(Self.label(video[step])) for now, trying again in a few minutes")
      } else if !down {
        ActivityLog.shared.add("Trying \(Self.label(video[step])) again")
      }
      applyChosen(smoothly: true)
    }

    /// Wi-Fi to cellular or back: connections drop for a moment. Not the stream's doing, so a
    /// stall now isn't learned from; and cellular keeps a little more in hand.
    private func networkChanged() {
      guard !stopped else { return }
      settlingUntil = Date().addingTimeInterval(10)
      catchUp.hold(for: 4)
      catchUp.setFloor(NetworkWatch.shared.floor)
      if player.playbackRate != 1 { player.playbackRate = 1 }
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

      // Stay close to live, smoothly: a touch faster while more is in hand than the stream needs, a
      // touch slower while less is (see LiveCatchUp).
      let steering =
        AppSettings.shared.lowLatency && player.isLiveLowLatency && player.state == .playing && !pausedForBackground
      // Just started a couple of seconds back: one skip over the extra in hand.
      jumpToLiveAfterStart(latency: latency)
      // Never hidden for long, whatever happened to the skip.
      if concealing, let since = playingSince, Date().timeIntervalSince(since) > Self.concealAtMost { reveal() }
      let position = player.position.seconds
      let rate = catchUp.update(
        buffer: bufferAhead, latency: latency, playing: steering, position: position.isFinite ? position : nil)
      if player.playbackRate != rate { player.playbackRate = rate }
      noteMargin()
      // For the record: how far from live it started (and how much of that is video in hand, which
      // catching up can win back, rather than video arriving late, which it can't).
      if !reportedStart, let since = playingSince, Date().timeIntervalSince(since) > 3, let latency, !tile {
        reportedStart = true
        let held = bufferAhead.map { String(format: ", %.1f s in hand", $0) } ?? ""
        ActivityLog.shared.add("\(login) started \(String(format: "%.1f", latency)) s from live\(held)")
      }

      // The session can go back to the ad-free server's playlist server mid-stream.
      if let session, Date().timeIntervalSince(serverCheckedAt) > 5 {
        serverCheckedAt = Date()
        Task { [weak self] in await self?.refreshServer(session) }
      }

      // The best quality, stepped down for the connection: try the one above again after a while.
      if usesConnectionFit, !audioOnlyForBackground, player.state == .playing, connectionFit.tick() {
        applyConnectionFit(down: false)
      }

      // Auto: let it try a better quality again once a hold is over; remember what plays well.
      if chosen == nil, !audioOnlyForBackground {
        if steadyAuto.tick() { applyAutoCap() }
        // (Not from a multi-view tile: its limit is its size on screen, not the connection.)
        if !tile, let rank = steadyAuto.steadyRank(), rank < videoQualities.count {
          PlaybackMemory.autoBitrate = videoQualities[rank].bitrate
        }
      }

      // Buffering for a while: start over only when that can help, i.e. the stream is coming in but
      // the player isn't playing it (or has stopped asking for it). When the stream itself has
      // stopped coming in (the broadcaster's upload dropped out), wait for it: a restart would
      // only throw away what's in hand (see StreamArrival).
      if player.state == .buffering, !pausedForBackground, !detachedForBackground, !isPaused {
        if bufferingSince == nil { bufferingSince = Date() }
        if let back = switchedBackAt, Date().timeIntervalSince(back) > 30 { switchedBackAt = nil }
        if let since = bufferingSince, switchedBackAt != nil, Date().timeIntervalSince(since) > 3 {
          // Stuck on the switch back from the ad-free copy: that's the one time starting over is
          // the fix straight away.
          switchedBackAt = nil
          reload(reason: "stuck switching back from the ad-free copy")
        } else if let since = bufferingSince, let arrival = session?.arrival {
          let ages = arrival.ages()
          switch StreamArrival.verdict(buffering: Date().timeIntervalSince(since), asked: ages.asked, moved: ages.moved) {
          case .wait:
            setWaitingForStream(false)
          case .waitingForStream:
            if !waitingForStream {
              ActivityLog.shared.add("\(login)'s stream stopped coming in for a moment (the broadcaster's side): waiting for it")
            }
            setWaitingForStream(true)
          case .restart:
            setWaitingForStream(false)
            reload(reason: ages.moved < 4.5 ? "the stream is coming in but the player is stuck" : "nothing for a long while")
          }
        }
      } else {
        bufferingSince = nil
        if player.state != .buffering { setWaitingForStream(false) }
      }

      // Far behind live after a long dropout: one jump back to live (winning back that much by
      // speed would take minutes). Only once it's playing steadily again, and rarely.
      if let latency, latency > 20, player.state == .playing, AppSettings.shared.lowLatency, !pausedForBackground,
        Date().timeIntervalSince(lastStall) > 15, Date().timeIntervalSince(lastFarJump) > 180
      {
        lastFarJump = Date()
        reload(reason: String(format: "%.0f s behind live after a dropout", latency))
      }
      // The picture's view lost the player somehow: give it back.
      if let sharedView {
        if sharedView.player !== player { sharedView.player = player }
      } else if let view, !detachedForBackground, view.player !== player {
        view.player = player
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
      if player.muted != (inAd || userMuted || concealing) { player.muted = inAd || userMuted || concealing }
      let shown: AdState = inAd ? .covering : (adState == .covering ? .searching : adState)
      if model.adState != shown { model.adState = shown }
    }

    /// Seconds of video buffered ahead of what's showing.
    /// IVS documents `buffered` as what's left ahead of the playhead, but has also behaved like the
    /// buffer's end position: once it's seen below the playhead it can only be what's left. Until
    /// then (the first seconds of a stream, with the playhead near its start) taking it for an end
    /// position read far too little in hand: it slowed down instead of catching up, took the
    /// shrinking reading for a hiccup and kept more in hand, and every stream started seconds
    /// further behind. So until it's known, what's left is taken to be the larger reading that
    /// still fits how far behind live it is (what's in hand can't be more than that).
    private var bufferAhead: Double? {
      let buffered = player.buffered.seconds
      guard buffered.isFinite, buffered >= 0 else { return nil }
      let position = player.position.seconds
      guard position.isFinite, position > 0 else { return buffered }
      if buffered + 0.5 < position { bufferedIsRemaining = true }
      if bufferedIsRemaining { return buffered }
      let endReading = max(0, buffered - position)
      let latency = player.liveLatency.seconds
      guard latency.isFinite, latency > 0 else { return endReading }
      return max(endReading, min(buffered, latency - 0.3))
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
      // The player only measures the connection when video comes in faster than it plays; in
      // low latency it arrives as it's made, so the figure mostly stays where it was measured.
      let estimate = player.bandwidthEstimate
      if estimate != bandwidthSeen.value { bandwidthSeen = (estimate, Date()) }
      let stale = Date().timeIntervalSince(bandwidthSeen.at) > 20
      lines.append(
        StatLine(label: "Bandwidth", value: StatFormat.mbps(Double(estimate)) + (stale ? " (last measured)" : "")))
      lines.append(StatLine(label: "Buffer", value: StatFormat.seconds(bufferAhead)))
      let latency = player.liveLatency.seconds
      lines.append(StatLine(label: "Latency", value: StatFormat.seconds(latency.isFinite && latency >= 0 ? latency : nil)))
      if AppSettings.shared.lowLatency {
        let rate = player.playbackRate
        let speed =
          rate > 1.001 ? String(format: "%.2f× (catching up)", rate)
          : rate < 0.999 ? String(format: "%.2f× (building margin)", rate) : "1×"
        lines.append(StatLine(label: "Speed", value: speed))
        let margin = String(format: "%.1f s", catchUp.targetBuffer)
        lines.append(
          StatLine(label: "Margin", value: catchUp.learnedUneven ? margin + " (this stream's video arrives unevenly)" : margin))
      }
      let network = NetworkWatch.shared
      lines.append(StatLine(label: "Connection", value: network.kind.rawValue + (network.constrained ? " (Low Data Mode)" : "")))
      if usesConnectionFit, connectionFit.step > 0, connectionFit.step < videoQualities.count {
        lines.append(
          StatLine(label: "Quality limit", value: "\(Self.label(videoQualities[connectionFit.step - 1])) ran dry on this connection; trying again soon"))
      }
      if let videoServer { lines.append(StatLine(label: "Video server", value: videoServer)) }
      if waitingForStream {
        lines.append(StatLine(label: "Stream", value: "waiting for the broadcaster's video"))
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
      } else {
        // Paused live video is behind; start again at the live edge (with a fresh token, since
        // the old one may have expired).
        isPaused = false
        load()
      }
    }

    /// Paused by the viewer, or playing again (at the live edge: paused live video is behind, and
    /// it's asked for afresh since its token may have expired). Played again in the background, it
    /// settles as it would have (heard: sound only; quiet: paused until the app's back).
    func setPaused(_ paused: Bool) {
      if paused {
        // The viewer's pause now: coming back to the app doesn't undo it.
        pausedForBackground = false
        guard !isPaused || player.state == .playing || player.state == .buffering else { return }
        player.pause()
        isPaused = true
      } else {
        guard isPaused || pausedForBackground else { return }
        isPaused = false
        pausedForBackground = false
        load()
        if UIApplication.shared.applicationState == .background { enteredBackground() }
      }
    }

    /// Starts over at the live edge, with the stream asked for afresh. The picture keeps playing
    /// meanwhile, until the new one is ready to load.
    func goLive() {
      lastReload = Date()
      lastFarJump = Date()
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
      let wanted = muted || (model?.coveringAd ?? false) || concealing
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
      // Off the old picture first: one being taken down after the new one is up (a screen
      // rebuilt mid-transition) took the video with it, leaving the new one black with the sound
      // still playing.
      if let old = self.view, old.player === player { old.player = nil }
      self.view = view
      view.alpha = concealing ? 0 : 1
      if !detachedForBackground, sharedView == nil { view.player = player }
      if offersPictureInPicture { makePictureInPicture(for: view) }
    }

    /// Into the all-streams Picture in Picture window (see MultiviewPictureInPicture): the
    /// picture moves there and keeps playing while Kestrel is in the background.
    func show(in shared: IVSPlayerView) {
      guard !stopped, sharedView !== shared else { return }
      backgroundSettleTask?.cancel()
      backgroundSettleTask = nil
      audioOnlyTask?.cancel()
      audioOnlyTask = nil
      if let view, view.player === player { view.player = nil }
      sharedView = shared
      detachedForBackground = false
      if audioOnlyForBackground {
        audioOnlyForBackground = false
        applyChosen(smoothly: true)
      }
      shared.player = player
      if pausedForBackground {
        pausedForBackground = false
        goLive()
      }
    }

    /// Back in the tile's own view (the PiP window closed). Still in the background: settles as
    /// usual (heard streams keep their sound, the others pause).
    func showInTile() {
      guard let shared = sharedView else { return }
      if shared.player === player { shared.player = nil }
      sharedView = nil
      if let view, !detachedForBackground { view.player = player }
      if UIApplication.shared.applicationState == .background { enteredBackground() }
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
        !proxy.pictureInPictureStarting, !(pip?.isPictureInPictureActive ?? false), sharedView == nil, !isPaused
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
        if let view, offersPictureInPicture, !(pip?.isPictureInPictureActive ?? false) { makePictureInPicture(for: view) }
      }
      if audioOnlyForBackground {
        // Back to the picture without stopping the sound to rebuffer.
        audioOnlyForBackground = false
        applyChosen(smoothly: true)
      }
      // Coming back disturbs the streams for a moment (the others starting up, the picture
      // returning from PiP): a stall now isn't the stream's doing, so it doesn't teach a bigger
      // margin (which kept the stream further behind, and slowed it to build the margin).
      settlingUntil = Date().addingTimeInterval(8)
      // Heard: make sure the sound has somewhere to go (a call or another app may have taken it).
      if !userMuted { try? AVAudioSession.sharedInstance().setActive(true) }
      let mute = userMuted || (model?.coveringAd ?? false) || concealing
      if player.muted != mute { player.muted = mute }
      if pausedForBackground {
        // Multi-view's quiet streams come back one after another, not all at once: starting
        // together, they took the bandwidth from the one still playing, which stalled. (Each
        // stays paused until its turn.)
        let delay = tile ? Self.nextResumeDelay() : 0
        if delay == 0 {
          pausedForBackground = false
          goLive()
        } else {
          Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let controller = self, controller.pausedForBackground, !controller.stopped, !controller.suspended,
              UIApplication.shared.applicationState != .background
            else { return }
            controller.pausedForBackground = false
            controller.goLive()
          }
        }
      }
    }

    private static var resumeTurns: (count: Int, since: Date) = (0, .distantPast)

    /// The wait before the next paused multi-view stream starts again: 1, 2.2, 3.4… seconds.
    private static func nextResumeDelay() -> Double {
      if Date().timeIntervalSince(resumeTurns.since) > 6 { resumeTurns = (0, Date()) }
      resumeTurns.count += 1
      return 1 + Double(resumeTurns.count - 1) * 1.2
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
