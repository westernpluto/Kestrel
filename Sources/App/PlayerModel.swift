import AVFoundation
import AVKit
import SwiftUI
import UIKit

@MainActor
final class PlayerModel: ObservableObject {
  enum Phase: Equatable {
    case loading
    case playing
    case offline
    case failed(String)
  }

  struct Quality: Identifiable, Hashable {
    let id: Int?  // nil = Auto
    let label: String
  }

  let target: PlaybackTarget
  let player = AVPlayer()
  @Published var phase: Phase = .loading
  @Published var qualities: [Quality] = []
  @Published var selectedQuality: Int?
  @Published var adState: AdState = .none
  @Published var coveringAd = false
  @Published var latency: Double?
  @Published private(set) var stream: LiveStream?
  @Published private(set) var channel: Channel?
  @Published var isBuffering = true
  /// The live player in use (VODs always use the Apple player).
  @Published private(set) var engine: PlayerEngine

  #if canImport(AmazonIVSPlayer)
    /// Set while the low-latency player is in use.
    @Published private(set) var lowLatency: LowLatencyController?
  #endif

  private var session: StreamSession?
  private var adRanges: [ClosedRange<Date>] = []
  private var timer: Timer?
  private var mutedForAd = false
  private var itemObservation: NSKeyValueObservation?
  private var statusObservation: NSKeyValueObservation?
  private var notificationTokens: [NSObjectProtocol] = []
  private var lastCatchUp = Date.distantPast
  private var lastInfoRefresh = Date.distantPast
  private var stopped = false
  /// Twitch `supported_codecs` for this playback; steps down to H.264 if a codec won't play.
  private var codecs = AppSettings.shared.codecs
  /// Rendition to start the Apple player on (when it took over for a 1440p stream).
  private var preferredQualityLabel: String?
  /// False once the user picked a player by hand: don't switch players behind their back.
  private(set) var mayAutoSwitchPlayer = true

  nonisolated init(target: PlaybackTarget) {
    self.target = target
    if case .live = target {
      _engine = Published(initialValue: AppSettings.shared.playerEngine)
    } else {
      _engine = Published(initialValue: .standard)
    }
  }

  var isLive: Bool {
    if case .live = target { return true }
    return false
  }

  func start() async {
    guard session == nil, phase == .loading, !stopped else { return }
    #if canImport(AmazonIVSPlayer)
      guard lowLatency == nil else { return }
    #endif
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)
    switch target {
    case .live(let channel):
      self.channel = channel
      lastInfoRefresh = Date()
      Task { await refreshInfo() }
      #if canImport(AmazonIVSPlayer)
        if engine == .lowLatency {
          startLowLatency(channel)
          startTimer()
          return
        }
      #endif
      startObservingAVPlayer()
      await startLive(channel)
    case .video(let video):
      channel = video.owner
      startObservingAVPlayer()
      await startVideo(video)
    }
    if !stopped { startTimer() }
  }

  private func startObservingAVPlayer() {
    guard statusObservation == nil else { return }
    player.automaticallyWaitsToMinimizeStalling = true
    statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
      let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      guard let model = self else { return }
      Task { @MainActor in model.isBuffering = buffering }
    }
  }

  // MARK: - Apple player (live)

  private func startLive(_ channel: Channel) async {
    var config = AppSettings.shared.sessionConfig
    config.codecs = codecs
    let session = StreamSession(
      login: channel.login, config: config, http: URLSessionHTTPClient(timeout: 8),
      tokens: TwitchAPI.shared
    ) { [weak self] state, ranges in
      guard let model = self else { return }
      Task { @MainActor in
        model.adState = state
        model.adRanges = ranges
      }
    }
    do {
      let info = try await session.start()
      guard !stopped, engine == .standard else { return }
      self.session = session
      _ = try StreamProxy.shared.register(session)
      qualities = info.variants.enumerated().map { Quality(id: $0.offset, label: $0.element.label) }
        + [Quality(id: nil, label: "Auto")]
      // Always the highest quality: the player is given only that one rendition, so it can't drop
      // to a lower one on its own. (Picking another in the menu applies to this stream only.)
      selectedQuality = preferredQualityLabel.flatMap { label in info.variants.firstIndex { $0.label == label } } ?? 0
      preferredQualityLabel = nil
      liveVariants = info.variants
      play(StreamProxy.shared.masterURL(for: session, quality: selectedQuality))
      phase = .playing
    } catch StreamSession.StartError.offline {
      phase = .offline
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private var liveVariants: [HLSVariant] = []
  private var vodVariants: [HLSVariant] = []

  // MARK: - Apple player (VOD)

  private func startVideo(_ video: Video) async {
    do {
      let token = try await TwitchAPI.shared.videoToken(id: video.id)
      guard !stopped else { return }
      let url = Usher.vod(id: video.id, token: token, codecs: codecs)
      let (data, response) = try await URLSessionHTTPClient(timeout: 10).data(for: Usher.playlistRequest(url))
      guard response.statusCode == 200, let text = String(data: data, encoding: .utf8), HLS.looksLikePlaylist(data) else {
        phase = .failed(
          response.statusCode == 403
            ? "This video is restricted (subscribers only or region locked)." : "Twitch returned HTTP \(response.statusCode).")
        return
      }
      let master = HLSMaster.parse(text, base: response.url ?? url)
      vodVariants = master.videoVariants + (master.audioVariant.map { [$0] } ?? [])
      guard let best = vodVariants.first, let mediaURL = URL(string: best.uri) else {
        phase = .failed("No playable qualities were found.")
        return
      }
      qualities = vodVariants.enumerated().map { Quality(id: $0.offset, label: $0.element.label) }
      selectedQuality = 0
      // Play the best rendition's playlist directly, so the player can't switch to a lower one.
      play(mediaURL)
      phase = .playing
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private func play(_ url: URL?, resumeAt position: CMTime? = nil) {
    guard let url else {
      phase = .failed("Couldn't start the local stream server.")
      return
    }
    let item = AVPlayerItem(url: url)
    itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard item.status == .failed else { return }
      let message = item.error?.localizedDescription ?? "Playback failed."
      guard let model = self else { return }
      Task { @MainActor in model.handleItemFailure(message) }
    }
    player.replaceCurrentItem(with: item)
    if let position { player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) }
    player.play()
  }

  /// The rendition the Apple player is on (nil = Auto).
  private var currentVariant: HLSVariant? {
    let variants = isLive ? liveVariants : vodVariants
    guard let index = selectedQuality, index < variants.count else { return nil }
    return variants[index]
  }

  private var recentFailures: [Date] = []

  private func handleItemFailure(_ message: String) {
    guard !stopped, engine == .standard else { return }
    // A 1440p HEVC/AV1 rendition the decoder rejected: ask Twitch again without that codec.
    if let variant = currentVariant, variant.codecFamily != "avc", let fallback = DeviceCodecs.fallback(after: codecs) {
      ActivityLog.shared.add("\(variant.label) didn't play (\(message)); retrying with \(fallback)")
      codecs = fallback
      restartPlayback()
      return
    }
    recentFailures = recentFailures.filter { Date().timeIntervalSince($0) < 90 } + [Date()]
    guard isLive, case .live(let channel) = target, recentFailures.count <= 3 else {
      phase = .failed(message)
      return
    }
    // The stream may have ended, its token expired, or iOS reclaimed the local server.
    Task {
      if let page = try? await TwitchAPI.shared.channelPage(login: channel.login), page.stream == nil {
        phase = .offline
        return
      }
      if !StreamProxy.shared.isAlive { _ = try? StreamProxy.shared.restart() }
      if let session { StreamProxy.shared.remove(session.id) }
      session = nil
      ActivityLog.shared.add("Playback error (\(message)), reconnecting")
      await startLive(channel)
    }
  }

  func selectQuality(_ quality: Quality) {
    guard quality.id != selectedQuality else { return }
    #if canImport(AmazonIVSPlayer)
      if let lowLatency {
        selectedQuality = quality.id
        lowLatency.select(quality.id)
        return
      }
    #endif
    if let session {
      selectedQuality = quality.id
      play(StreamProxy.shared.masterURL(for: session, quality: quality.id))
    } else if let index = quality.id, index < vodVariants.count, let url = URL(string: vodVariants[index].uri) {
      selectedQuality = quality.id
      play(url, resumeAt: player.currentTime())
    }
  }

  /// Jumps back to the live edge (Apple player) after stalls have pushed it behind.
  func goLive() {
    #if canImport(AmazonIVSPlayer)
      if let lowLatency {
        lowLatency.goLive()
        return
      }
    #endif
    guard isLive, let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
    lastCatchUp = Date()
    let offset = item.recommendedTimeOffsetFromLive.isValid ? item.recommendedTimeOffsetFromLive : CMTime(seconds: 6, preferredTimescale: 600)
    let target = CMTimeSubtract(CMTimeRangeGetEnd(range), offset)
    player.seek(to: CMTimeMaximum(target, range.start), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
    player.play()
  }

  func setEngine(_ newEngine: PlayerEngine) {
    guard isLive, newEngine != engine, PlayerEngine.available.contains(newEngine) else { return }
    mayAutoSwitchPlayer = false
    AppSettings.shared.playerEngine = newEngine
    teardownPlayback()
    engine = newEngine
    recentFailures = []
    phase = .loading
    Task { await start() }
  }

  func retry() {
    recentFailures = []
    codecs = AppSettings.shared.codecs
    restartPlayback()
  }

  private func restartPlayback() {
    teardownPlayback()
    phase = .loading
    Task { await start() }
  }

  /// Stops whichever player is running, keeping the model usable.
  private func teardownPlayback() {
    #if canImport(AmazonIVSPlayer)
      lowLatency?.stop()
      lowLatency = nil
    #endif
    player.pause()
    player.replaceCurrentItem(with: nil)
    itemObservation = nil
    if let session { StreamProxy.shared.remove(session.id) }
    session = nil
    qualities = []
    selectedQuality = nil
    latency = nil
    adState = .none
    adRanges = []
    coveringAd = false
    if mutedForAd {
      player.isMuted = false
      mutedForAd = false
    }
    isBuffering = true
  }

  func stop() {
    stopped = true
    timer?.invalidate()
    timer = nil
    teardownPlayback()
    statusObservation = nil
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    notificationTokens = []
  }

  /// Called when the app returns to the foreground.
  func ensureServerAlive() {
    guard isLive, let session, !stopped else { return }
    Task.detached {
      var alive = false
      if let port = try? StreamProxy.shared.ensureRunning(), let url = URL(string: "http://127.0.0.1:\(port)/ping") {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        alive = (try? await URLSession.shared.data(for: request)) != nil
      }
      if !alive {
        _ = try? StreamProxy.shared.restart()
        await MainActor.run { [weak self] in
          guard let self, self.session === session else { return }
          self.play(StreamProxy.shared.masterURL(for: session, quality: self.selectedQuality))
        }
      }
    }
  }

  // MARK: - Ticking: latency, ad cover

  private func startTimer() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let model = self else { return }
      Task { @MainActor in model.tick() }
    }
    notificationTokens.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        guard let model = self else { return }
        Task { @MainActor in model.ensureServerAlive() }
      })
  }

  private func tick() {
    let now = Date()
    if isLive, now.timeIntervalSince(lastInfoRefresh) > 60 {
      lastInfoRefresh = now
      Task { await refreshInfo() }
    }
    #if canImport(AmazonIVSPlayer)
      if let lowLatency {
        lowLatency.tick()
        return
      }
    #endif
    guard isLive, let item = player.currentItem else { return }
    let currentDate = item.currentDate()
    if let currentDate { latency = max(0, now.timeIntervalSince(currentDate)) }

    let inAd = currentDate.map { date in adRanges.contains { $0.contains(date) } } ?? false
    if inAd != coveringAd { coveringAd = inAd }
    if inAd, !player.isMuted {
      player.isMuted = true
      mutedForAd = true
    } else if !inAd, mutedForAd {
      player.isMuted = false
      mutedForAd = false
    }

    // No speed-up tricks (they starved the buffer and froze the picture). Only if repeated stalls
    // have left playback far behind, jump back once in a while.
    if let latency, latency > 30, player.timeControlStatus == .playing, !inAd, now.timeIntervalSince(lastCatchUp) > 60 {
      ActivityLog.shared.add(String(format: "%.0f s behind live, jumping ahead", latency))
      goLive()
    }
  }

  private func refreshInfo() async {
    guard case .live(let channel) = target, let page = try? await TwitchAPI.shared.channelPage(login: channel.login) else {
      return
    }
    self.channel = page.channel
    stream = page.stream
  }

  #if canImport(AmazonIVSPlayer)
    private func startLowLatency(_ channel: Channel) {
      let controller = LowLatencyController(login: channel.login, codecs: codecs, model: self)
      lowLatency = controller
      controller.start()
    }

    /// The low-latency player gave up: use the Apple player for the rest of this stream.
    func lowLatencyFailed(_ message: String) {
      guard engine == .lowLatency, !stopped else { return }
      ActivityLog.shared.add("Low-latency player failed (\(message)); switching to the Apple player")
      teardownPlayback()
      engine = .standard
      phase = .loading
      Task { await start() }
    }

    /// For this stream only (the setting stays): e.g. a 1440p rendition the low-latency player
    /// can't decode.
    func switchToApplePlayer(quality label: String?, reason: String, automatic: Bool) {
      guard engine == .lowLatency, !stopped else { return }
      if automatic, !mayAutoSwitchPlayer { return }
      ActivityLog.shared.add("Switching to the Apple player: \(reason)")
      teardownPlayback()
      engine = .standard
      preferredQualityLabel = label
      phase = .loading
      Task { await start() }
    }

    func lowLatencyOffline() {
      guard !stopped else { return }
      teardownPlayback()
      phase = .offline
    }
  #endif
}
