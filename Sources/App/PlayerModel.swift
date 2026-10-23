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
  /// The video stats overlay's rows (only filled while it's switched on).
  @Published var stats: [StatLine] = []
  /// The live player in use (VODs always use the Apple player).
  @Published private(set) var engine: PlayerEngine
  @Published var isPaused = false
  /// Zoomed to fill the screen (crops the sides) instead of fitting.
  @Published var fillsScreen = false
  @Published private(set) var pictureInPictureActive = false
  // VOD position, for the seek bar.
  @Published var position: Double = 0
  @Published private(set) var duration: Double = 0
  /// Set by the Apple player's view.
  weak var applePictureInPicture: AVPictureInPictureController? {
    didSet { observeApplePictureInPicture() }
  }
  private var pipObservation: NSKeyValueObservation?
  /// Where the live stream's playlist came from (stats overlay).
  @Published var route: StreamRoute?

  // Rewinding a live stream: the broadcast's VOD while it's being recorded.
  /// Set when the channel is recording a VOD of this broadcast and it plays for this account.
  @Published private(set) var rewind: LiveArchive?
  /// Playing the VOD (behind live) instead of the live stream.
  @Published private(set) var isRewinding = false
  /// Seconds into the broadcast being watched while rewinding.
  @Published private(set) var rewindPosition: Double = 0
  /// Seconds since the broadcast started (the live edge on the seek bar).
  @Published private(set) var broadcastElapsed: Double = 0
  let rewindPlayer = AVPlayer()
  /// The VOD is on screen (until then the paused live picture stays up, so going back in time
  /// doesn't flash black).
  @Published private(set) var rewindShowing = false
  /// Back to live: the VOD's last picture stays up until the live stream plays again.
  @Published private(set) var rewindLinger = false
  private var lingerSince: Date?
  private var rewindSeeking = false
  /// The VOD stays loaded (paused, out of sight) for a while after going back to live, and is
  /// loaded as soon as the seek bar is touched, so going back in time only has to seek.
  private var rewindIdleSince: Date?
  private var scrubTarget: Double?
  private var scrubSeeking = false
  /// A seek in a VOD is under way (playback state isn't read from the player meanwhile).
  private var seeking = false
  weak var rewindPictureInPicture: AVPictureInPictureController? {
    didSet { observeRewindPictureInPicture() }
  }
  private var rewindPipObservation: NSKeyValueObservation?
  private var rewindVariants: [HLSVariant] = []
  private var rewindQuality = 0
  private var rewindPendingSeek: Double?
  private var rewindItemObservation: NSKeyValueObservation?
  private var rewindEndSince: Date?
  private var lastArchiveCheck = Date.distantPast
  private var checkingArchive = false

  /// VOD seek previews (VODs, and live streams that can be rewound).
  @Published private(set) var storyboard: Storyboard?
  private var storyboardSource: (url: URL, videoID: String, duration: Double?)?

  // VODs
  /// VOD playlists served through the local server (muted parts fixed).
  private var vodSource: VODPlaylists?
  private var rewindSource: VODPlaylists?
  /// Where to start once the item is ready (VODs: the beginning or where you left off).
  private var pendingStart: Double?
  /// The VOD is still being recorded (its length grows).
  @Published private(set) var vodIsRecording = false
  /// Shown for a few seconds after resuming where you left off.
  @Published private(set) var resumedAt: Double?
  private var lastSavedPosition = Date()
  private var lastSyncedPosition = Date()
  private var lastExtended = Date.distantPast
  private var lastRewindReload = Date.distantPast
  /// Stall watchdog (VODs and rewinding): where playback got stuck and since when.
  private var stall: (position: Double, since: Date)?
  private var storyboardLoaded = Date.distantPast

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
  /// Rendition to start on (the Apple player taking over for a 1440p stream, or a quality picked
  /// that only plays without the ad-free server).
  private(set) var preferredQualityLabel: String?
  /// Better renditions Twitch offers straight away than the ad-free server's copy has (it asks
  /// anonymously, so e.g. 1440p for signed-in viewers can be missing).
  @Published private(set) var directOnly: [HLSVariant] = []
  /// Playing straight from Twitch for one of those, for this stream only (ads possible).
  private(set) var forceDirect = false
  private var checkedDirect = false
  /// What the ad-free server's copy goes up to (its best rendition's height), and the renditions
  /// only Twitch itself had: to offer the way back.
  private var adFreeBestHeight = 0
  private var directOffer: [HLSVariant] = []
  private var engineBeforeDirect: PlayerEngine?
  static let directQualityBase = 2000
  /// False once the user picked a player by hand: don't switch players behind their back.
  private(set) var mayAutoSwitchPlayer = true

  nonisolated init(target: PlaybackTarget) {
    self.target = target
    if case .live = target {
      // The low-latency (IVS) player when the build has it; the Apple player otherwise and as a
      // fallback.
      _engine = Published(initialValue: PlayerEngine.preferredDefault)
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
    NowPlaying.shared.attach(self)
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
    config.adFreeProxies = adFreeProxies
    config.checkAccountFirst = TwitchAuth.shared.session != nil
    let session = StreamSession(
      login: channel.login, config: config, http: AppSettings.shared.playbackClient(timeout: 8),
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
      route = await session.route
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
      checkDirectQualities(served: info.variants)
    } catch StreamSession.StartError.offline {
      phase = .offline
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private var liveVariants: [HLSVariant] = []
  private var vodVariants: [HLSVariant] = []

  // MARK: - Apple player (VOD)

  struct VODError: LocalizedError {
    var errorDescription: String?
  }

  /// A VOD's renditions, best first (then audio only).
  private func vodRenditions(id: String) async throws -> [HLSVariant] {
    let token = try await TwitchAPI.shared.videoToken(id: id)
    let url = Usher.vod(id: id, token: token, codecs: codecs)
    let (data, response) = try await URLSessionHTTPClient(timeout: 10).data(for: Usher.playlistRequest(url))
    guard response.statusCode == 200, let text = String(data: data, encoding: .utf8), HLS.looksLikePlaylist(data) else {
      throw VODError(
        errorDescription: response.statusCode == 403
          ? "This video is restricted (subscribers only or region locked)." : "Twitch returned HTTP \(response.statusCode).")
    }
    let master = HLSMaster.parse(text, base: response.url ?? url)
    let variants = master.videoVariants + (master.audioVariant.map { [$0] } ?? [])
    guard !variants.isEmpty else { throw VODError(errorDescription: "No playable qualities were found.") }
    return variants
  }

  private func startVideo(_ video: Video) async {
    do {
      async let renditions = vodRenditions(id: video.id)
      async let saved = WatchHistory.shared.resumePosition(for: video)
      vodVariants = try await renditions
      let resume = await saved
      guard !stopped else { return }
      await StreamProxy.shared.ensureResponsive()
      let source = VODPlaylists(variants: vodVariants, http: URLSessionHTTPClient(timeout: 10))
      _ = try StreamProxy.shared.register(source)
      vodSource = source
      qualities = vodVariants.enumerated().map { Quality(id: $0.offset, label: $0.element.label) }
      selectedQuality = 0
      // VODs start at the beginning (a VOD that's still recording would otherwise start at its
      // end), or where you left off.
      let length = Double(video.lengthSeconds)
      var start = 0.0
      if let resume, resume > 15, length <= 0 || resume < length - 20 {
        start = resume
        resumedAt = resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
          withAnimation(.easeOut(duration: 0.3)) { self?.resumedAt = nil }
        }
      }
      position = start
      // Play the best rendition's playlist directly, so the player can't switch to a lower one.
      play(StreamProxy.shared.mediaURL(for: source, index: 0), startAt: start)
      phase = .playing
      loadStoryboard(videoID: video.id, known: nil, duration: length > 0 ? length : nil)
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// "Start over" after resuming.
  func startOver() {
    resumedAt = nil
    seek(to: 0)
  }

  // MARK: - Seek previews

  private func loadStoryboard(videoID: String, known: URL?, duration: Double?) {
    Task {
      let url: URL?
      if let known { url = known } else { url = await TwitchAPI.shared.seekPreviewsURL(videoID: videoID) }
      guard let url, !stopped else { return }
      storyboardSource = (url, videoID, duration)
      await reloadStoryboard()
    }
  }

  private func reloadStoryboard() async {
    guard let source = storyboardSource else { return }
    storyboardLoaded = Date()
    // A VOD that's still recording: its storyboard covers its current length.
    var duration = source.duration
    if duration == nil || vodIsRecording || isLive {
      duration = await TwitchAPI.shared.videoProgress(videoID: source.videoID).length ?? duration
    }
    if let board = await TwitchAPI.shared.storyboard(url: source.url, duration: duration), !stopped {
      storyboard = board
    }
  }

  /// While scrubbing a recording: the storyboard grows with it.
  func refreshStoryboardIfStale() {
    guard isLive || vodIsRecording || storyboard == nil, Date().timeIntervalSince(storyboardLoaded) > 60 else { return }
    Task { await reloadStoryboard() }
  }

  /// - Parameter startAt: seconds to start from once the item is ready (VODs); nil plays at once
  ///   (live: the player picks the live edge).
  private func play(_ url: URL?, startAt seconds: Double? = nil) {
    guard let url else {
      phase = .failed("Couldn't start the local stream server.")
      return
    }
    let item = AVPlayerItem(url: url)
    pendingStart = seconds
    itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      let status = item.status
      let message = item.error?.localizedDescription ?? "Playback failed."
      guard let model = self else { return }
      Task { @MainActor in
        switch status {
        case .failed: model.handleItemFailure(message)
        case .readyToPlay: model.itemReady()
        default: break
        }
      }
    }
    player.replaceCurrentItem(with: item)
    if seconds == nil { player.play() }
  }

  private func itemReady() {
    guard let start = pendingStart else { return }
    pendingStart = nil
    if let vodSource, vodSource.isRecording != vodIsRecording { vodIsRecording = vodSource.isRecording }
    // A VOD starts at its beginning by itself: only seek for a later start.
    guard start >= 1 else {
      if !isPaused { player.play() }
      return
    }
    seeking = true
    player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: Self.seekTolerance) {
      [weak self] _ in
      Task { @MainActor in
        guard let model = self else { return }
        model.seeking = false
        guard !model.stopped, !model.isPaused else { return }
        model.player.play()
      }
    }
  }

  /// Seeks land on the first keyframe at or after the target (Twitch puts one every 2 s): quicker
  /// than an exact frame, and never before the target, so the seek bar doesn't jump back.
  static let seekTolerance = CMTime(seconds: 2, preferredTimescale: 600)

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

  /// The quality menu: the live stream's, or the VOD's while rewinding.
  var menuQualities: [Quality] {
    if isRewinding { return rewindVariants.enumerated().map { Quality(id: $0.offset, label: $0.element.label) } }
    if forceDirect {
      // Playing straight from Twitch for a better quality: the ones the ad-free server also has
      // say so, and picking one goes back to it.
      return qualities.map { quality in
        guard quality.id == nil || adFreeHas(quality.label) else { return quality }
        return Quality(id: quality.id, label: "\(quality.label) · ad-free")
      }
    }
    guard !directOnly.isEmpty else { return qualities }
    var list = qualities
    let extra = directOnly.enumerated().map {
      Quality(id: Self.directQualityBase + $0.offset, label: "\($0.element.label) · no ad-free server")
    }
    list.insert(contentsOf: extra, at: list.firstIndex { $0.id == nil } ?? list.count)
    return list
  }

  /// The ad-free servers to use (none once a quality only Twitch itself offers was picked).
  var adFreeProxies: [String] { forceDirect ? [] : AppSettings.shared.adFreeProxyHosts }

  /// Hands over the quality to start on (once).
  func takePreferredQualityLabel() -> String? {
    defer { preferredQualityLabel = nil }
    return preferredQualityLabel
  }

  /// Played through an ad-free server: does Twitch itself offer a better quality? Then it's
  /// listed in the quality menu, to play straight from Twitch at the viewer's choice.
  func checkDirectQualities(served: [HLSVariant]) {
    guard case .live(let channel) = target, !forceDirect, !checkedDirect, case .adFreeServer? = route else { return }
    checkedDirect = true
    let codecs = self.codecs
    Task { [weak self] in
      guard let token = try? await TwitchAPI.shared.streamToken(login: channel.login, playerType: "site", platform: "web")
      else { return }
      let url = Usher.live(login: channel.login, token: token, codecs: codecs, lowLatency: false)
      guard let (data, response) = try? await URLSessionHTTPClient(timeout: 8).data(for: Usher.playlistRequest(url)),
        response.statusCode == 200, let text = String(data: data, encoding: .utf8)
      else { return }
      let best = served.filter { !$0.isAudioOnly }.map(\.height).max() ?? 0
      let better = HLSMaster.parse(text, base: response.url ?? url).videoVariants.filter { $0.height > best }
      guard let model = self, !model.stopped, !better.isEmpty else { return }
      model.adFreeBestHeight = best
      model.directOffer = better
      model.directOnly = better
      ActivityLog.shared.add(
        "Twitch itself offers \(better.map(\.label).joined(separator: ", ")), which the ad-free server's copy doesn't: it's in the quality menu (plays without the ad-free server)")
    }
  }

  /// Restarts this stream straight from Twitch on a rendition the ad-free server didn't have.
  private func playDirect(_ variant: HLSVariant) {
    guard case .live = target, !stopped else { return }
    ActivityLog.shared.add("Playing \(variant.label) straight from Twitch for this stream (no ad-free server; ads possible)")
    forceDirect = true
    directOnly = []
    preferredQualityLabel = variant.label
    engineBeforeDirect = engine
    teardownPlayback()
    phase = .loading
    Task { await start() }
  }

  /// Whether the ad-free server's copy has this quality ("1080p60", "Audio only").
  private func adFreeHas(_ label: String) -> Bool {
    let digits = label.prefix { $0.isNumber }
    guard let height = Int(digits) else { return true }
    return height <= adFreeBestHeight
  }

  /// Back from playing straight from Twitch to the ad-free server (no ads), at `label`.
  private func returnToAdFree(label: String?) {
    guard case .live = target, !stopped else { return }
    ActivityLog.shared.add("Back to the ad-free server" + (label.map { " at \($0)" } ?? ""))
    forceDirect = false
    directOnly = directOffer
    preferredQualityLabel = label
    // The Apple player may have taken over for the better quality: back to the usual player.
    if let previous = engineBeforeDirect { engine = previous }
    engineBeforeDirect = nil
    teardownPlayback()
    phase = .loading
    Task { await start() }
  }

  var menuSelectedQuality: Int? { isRewinding ? rewindQuality : selectedQuality }

  func selectQuality(_ quality: Quality) {
    if isRewinding {
      guard let index = quality.id, index != rewindQuality, index < rewindVariants.count else { return }
      rewindQuality = index
      startRewindItem(at: rewindPosition)
      return
    }
    if let id = quality.id, id >= Self.directQualityBase {
      let offset = id - Self.directQualityBase
      if offset < directOnly.count { playDirect(directOnly[offset]) }
      return
    }
    if forceDirect, quality.id != selectedQuality {
      let label = qualities.first { $0.id == quality.id }?.label
      if quality.id == nil || label.map(adFreeHas) == true {
        returnToAdFree(label: quality.id == nil ? nil : label)
        return
      }
    }
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
    } else if let index = quality.id, index < vodVariants.count, let vodSource {
      selectedQuality = quality.id
      play(StreamProxy.shared.mediaURL(for: vodSource, index: index), startAt: player.currentTime().seconds)
    }
  }

  /// Jumps back to the live edge (Apple player) after stalls have pushed it behind.
  func goLive() {
    if isRewinding {
      returnToLive()
      return
    }
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

  // MARK: - Controls (both players)

  func togglePause() {
    setPaused(!isPaused)
  }

  /// Play or pause (the button, the lock screen, headphones).
  func setPaused(_ paused: Bool) {
    defer { NowPlaying.shared.update(self) }
    if isRewinding {
      if paused { rewindPlayer.pause() } else { rewindPlayer.play() }
      isPaused = paused
      return
    }
    #if canImport(AmazonIVSPlayer)
      if let lowLatency {
        if lowLatency.isPaused != paused { lowLatency.togglePause() }
        isPaused = lowLatency.isPaused
        return
      }
    #endif
    if !paused {
      if isLive { goLive() } else { player.play() }
      isPaused = false
    } else {
      player.pause()
      isPaused = true
      if case .video(let video) = target {
        WatchHistory.shared.save(videoID: video.id, position: position, length: duration, syncToTwitch: true)
      }
    }
  }

  /// The lock screen's progress bar.
  func seekFromRemote(to seconds: Double) {
    if isLive {
      if rewind != nil { seekBroadcast(to: seconds) }
    } else {
      seek(to: min(max(0, seconds), max(0, duration - 1)))
    }
  }

  /// The lock screen's skip buttons.
  func skip(by seconds: Double) {
    if isRewinding {
      seekBroadcast(to: rewindPosition + seconds)
    } else if isLive {
      if seconds < 0, rewind != nil { seekBroadcast(to: broadcastElapsed - 30 + seconds) }
    } else {
      seek(to: min(max(0, position + seconds), max(0, duration - 1)))
    }
  }

  func togglePictureInPicture() {
    if isRewinding, let pip = rewindPictureInPicture {
      if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
      return
    }
    #if canImport(AmazonIVSPlayer)
      if let lowLatency {
        lowLatency.togglePictureInPicture()
        return
      }
    #endif
    guard let pip = applePictureInPicture else { return }
    if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
  }

  private func observeRewindPictureInPicture() {
    rewindPipObservation = rewindPictureInPicture?.observe(\.isPictureInPictureActive, options: [.initial, .new]) {
      [weak self] pip, _ in
      let active = pip.isPictureInPictureActive
      guard let model = self else { return }
      Task { @MainActor in
        if model.isRewinding { model.pictureInPictureActive = active }
      }
    }
  }

  private func observeApplePictureInPicture() {
    pipObservation = applePictureInPicture?.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] pip, _ in
      let active = pip.isPictureInPictureActive
      guard let model = self else { return }
      Task { @MainActor in model.pictureInPictureActive = active }
    }
  }

  /// Twitch's low-latency mode (the low-latency player only).
  func setLowLatency(_ enabled: Bool) {
    AppSettings.shared.lowLatency = enabled
    #if canImport(AmazonIVSPlayer)
      lowLatency?.setLowLatency(enabled)
    #endif
  }

  var canToggleLowLatency: Bool {
    #if canImport(AmazonIVSPlayer)
      return lowLatency != nil
    #else
      return false
    #endif
  }

  func setFill(_ fill: Bool) {
    fillsScreen = fill
    #if canImport(AmazonIVSPlayer)
      lowLatency?.setFill(fill)
    #endif
  }

  func seek(to seconds: Double) {
    position = seconds
    resumedAt = nil
    seeking = true
    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: Self.seekTolerance) {
      [weak self] _ in
      Task { @MainActor in
        guard let model = self else { return }
        model.seeking = false
        if !model.isPaused { model.player.play() }
      }
    }
    if case .video(let video) = target { WatchHistory.shared.save(videoID: video.id, position: seconds, length: duration, syncToTwitch: false) }
  }

  func setEngine(_ newEngine: PlayerEngine) {
    guard isLive, newEngine != engine, PlayerEngine.available.contains(newEngine) else { return }
    mayAutoSwitchPlayer = false
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
    stopRewindPlayback()
    #if canImport(AmazonIVSPlayer)
      lowLatency?.stop()
      lowLatency = nil
    #endif
    player.pause()
    player.replaceCurrentItem(with: nil)
    itemObservation = nil
    if let session { StreamProxy.shared.remove(session.id) }
    session = nil
    if let vodSource { StreamProxy.shared.remove(vodSource.id) }
    vodSource = nil
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
    guard !stopped else { return }
    if case .video(let video) = target, position > 0, phase == .playing {
      WatchHistory.shared.save(videoID: video.id, position: position, length: duration, syncToTwitch: true)
    }
    if let rewindSource { StreamProxy.shared.remove(rewindSource.id) }
    NowPlaying.shared.detach(self)
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
    NowPlaying.shared.update(self)
    if isLive, now.timeIntervalSince(lastInfoRefresh) > 60 {
      lastInfoRefresh = now
      Task { await refreshInfo() }
    }
    if isLive, phase == .playing { checkForArchive() }
    if let rewind { broadcastElapsed = max(0, now.timeIntervalSince(rewind.startedAt)) }
    if isRewinding {
      tickRewind()
      return
    }
    if rewindLinger, let since = lingerSince {
      // Live is playing again (or it's taking too long): let the VOD's picture go.
      if (!isBuffering && phase == .playing && now.timeIntervalSince(since) > 0.3) || now.timeIntervalSince(since) > 5 {
        withAnimation(.easeInOut(duration: 0.2)) { endRewindLinger() }
      }
    } else if rewindPlayer.currentItem != nil, !scrubSeeking, scrubTarget == nil, let idle = rewindIdleSince,
      now.timeIntervalSince(idle) > 180
    {
      // Not gone back in time for a while: let the VOD go.
      rewindIdleSince = nil
      rewindItemObservation = nil
      rewindPlayer.replaceCurrentItem(with: nil)
    }
    let wantsStats = AppSettings.shared.showVideoStats
    if !wantsStats, !stats.isEmpty { stats = [] }
    #if canImport(AmazonIVSPlayer)
      if let lowLatency {
        lowLatency.tick()
        if wantsStats { stats = lowLatency.stats() }
        if isPaused != lowLatency.isPaused { isPaused = lowLatency.isPaused }
        if pictureInPictureActive != lowLatency.pictureInPictureActive { pictureInPictureActive = lowLatency.pictureInPictureActive }
        return
      }
    #endif
    if wantsStats { stats = appleStats() }
    // Only once the item is ready and not mid-start or mid-seek: before that the player reports
    // "paused" while it loads, which used to stop VODs from ever starting.
    if pendingStart == nil, !seeking, player.currentItem?.status == .readyToPlay, phase == .playing {
      let paused = player.timeControlStatus == .paused
      if paused != isPaused { isPaused = paused }
    }
    if !isLive, let item = player.currentItem {
      let seconds = item.duration.seconds
      if seconds.isFinite, seconds > 0, abs(seconds - duration) > 0.5 { duration = seconds }
      let current = player.currentTime().seconds
      // Held at the target while a seek is under way (the player still reports the old spot).
      if current.isFinite, pendingStart == nil, !seeking { position = current }
      // Still recording: it was loaded as what's been recorded so far; near the end, load it
      // again to get what's been recorded since.
      if vodIsRecording, duration > 0, position > duration - 30, pendingStart == nil,
        now.timeIntervalSince(lastExtended) > 45, let vodSource
      {
        lastExtended = now
        ActivityLog.shared.add("The VOD is still recording: loading what's been recorded since")
        play(StreamProxy.shared.mediaURL(for: vodSource, index: selectedQuality ?? 0), startAt: position)
      }
      watchForStall(player, position: position, pending: pendingStart != nil || seeking)
      if case .video(let video) = target, player.timeControlStatus == .playing, position > 0 {
        if now.timeIntervalSince(lastSavedPosition) > 15 {
          lastSavedPosition = now
          let sync = now.timeIntervalSince(lastSyncedPosition) > 60
          if sync { lastSyncedPosition = now }
          WatchHistory.shared.save(videoID: video.id, position: position, length: duration, syncToTwitch: sync)
        }
      }
    }
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

  /// Video stats for the Apple player.
  private func appleStats() -> [StatLine] {
    guard let item = player.currentItem else { return [] }
    var lines = [StatLine(label: "Player", value: isLive ? "Apple (AVPlayer)" : "Apple (AVPlayer), video")]
    if let variant = currentVariant {
      lines.append(StatLine(label: "Quality", value: variant.label))
      lines.append(StatLine(label: "Codecs", value: variant.codecs.isEmpty ? "–" : variant.codecs))
      if variant.frameRate > 0 { lines.append(StatLine(label: "Frame rate", value: String(format: "%.0f fps", variant.frameRate))) }
    } else {
      lines.append(StatLine(label: "Quality", value: "Auto"))
    }
    let size = item.presentationSize
    if size.width > 0 { lines.append(StatLine(label: "Resolution", value: "\(Int(size.width))×\(Int(size.height))")) }
    let events = item.accessLog()?.events ?? []
    if let event = events.last {
      lines.append(StatLine(label: "Bitrate", value: StatFormat.mbps(event.indicatedBitrate)))
      lines.append(StatLine(label: "Bandwidth", value: StatFormat.mbps(event.observedBitrate)))
    }
    let current = item.currentTime().seconds
    let buffered = item.loadedTimeRanges.map(\.timeRangeValue)
      .first { $0.start.seconds <= current + 0.5 && CMTimeRangeGetEnd($0).seconds >= current }
      .map { CMTimeRangeGetEnd($0).seconds - current }
    lines.append(StatLine(label: "Buffer", value: StatFormat.seconds(buffered)))
    if isLive { lines.append(StatLine(label: "Latency", value: StatFormat.seconds(latency))) }
    let dropped = events.reduce(0) { $0 + max(0, $1.numberOfDroppedVideoFrames) }
    let stalls = events.reduce(0) { $0 + max(0, $1.numberOfStalls) }
    lines.append(StatLine(label: "Dropped frames", value: "\(dropped)"))
    lines.append(StatLine(label: "Stalls", value: "\(stalls)"))
    if isLive {
      lines.append(StatLine(label: "Ads", value: adState.statsText))
      lines.append(StatLine(label: "Playlists", value: "Kestrel filter"))
      lines.append(StatLine(label: "Ad blocking", value: route?.summary ?? AppSettings.shared.adBlockingSummary))
      lines.append(StatLine(label: "Account", value: TwitchAuth.shared.session?.login ?? "not signed in"))
    }
    return lines
  }

  // MARK: - Rewind (the broadcast's VOD while it's recorded)

  private func checkForArchive() {
    guard rewind == nil, !checkingArchive, Date().timeIntervalSince(lastArchiveCheck) > 180,
      case .live(let channel) = target
    else { return }
    checkingArchive = true
    lastArchiveCheck = Date()
    Task {
      defer { checkingArchive = false }
      guard let archive = await TwitchAPI.shared.liveArchive(login: channel.login), !stopped else { return }
      // Only offer it when the VOD actually plays for this account (sub-only VODs may not).
      guard let variants = try? await vodRenditions(id: archive.videoID), !stopped else {
        ActivityLog.shared.add("This broadcast's VOD exists but doesn't play for you, so rewinding is off")
        return
      }
      rewindVariants = variants.filter { !$0.isAudioOnly }
      guard !rewindVariants.isEmpty else { return }
      let source = VODPlaylists(variants: rewindVariants, http: URLSessionHTTPClient(timeout: 10))
      _ = try? StreamProxy.shared.register(source)
      rewindSource = source
      Task.detached { await source.prefetch(0) }
      broadcastElapsed = max(0, Date().timeIntervalSince(archive.startedAt))
      rewind = archive
      ActivityLog.shared.add("Rewind available: the VOD of this broadcast is being recorded")
      loadStoryboard(videoID: archive.videoID, known: archive.seekPreviewsURL.flatMap(URL.init(string:)), duration: nil)
    }
  }

  /// Seeks within the broadcast: the VOD while behind, the live stream at the end.
  func seekBroadcast(to seconds: Double) {
    guard rewind != nil else { return }
    scrubTarget = nil
    if seconds >= broadcastElapsed - 20 {
      returnToLive()
      return
    }
    let target = max(0, seconds)
    rewindPosition = target
    stall = nil
    // The VOD is already loaded (rewinding, or loaded while the bar was held): just seek in it.
    if let item = rewindPlayer.currentItem, item.status == .readyToPlay,
      item.duration.seconds.isFinite, target < item.duration.seconds - 10
    {
      if !isRewinding { enterRewind() }
      rewindSeeking = true
      rewindPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: Self.seekTolerance) {
        [weak self] _ in
        Task { @MainActor in
          guard let model = self, model.isRewinding else { return }
          model.rewindSeeking = false
          if !model.isPaused { model.rewindPlayer.play() }
        }
      }
      return
    }
    // Still loading (the bar was only just touched): start it there once it's ready.
    if !isRewinding, let item = rewindPlayer.currentItem, item.status == .unknown {
      enterRewind()
      rewindPendingSeek = target
      isBuffering = true
      return
    }
    if !isRewinding { enterRewind() }
    startRewindItem(at: target)
  }

  private func enterRewind() {
    if rewindLinger { endRewindLinger() }
    isRewinding = true
    isPaused = false
    rewindShowing = false
    rewindIdleSince = nil
    suspendLive()
    ActivityLog.shared.add("Rewinding: playing this broadcast's VOD")
  }

  /// The VOD loaded out of sight (when the seek bar is touched while live).
  private func preloadRewindItem() {
    guard rewindQuality < rewindVariants.count, let rewindSource,
      let url = StreamProxy.shared.mediaURL(for: rewindSource, index: rewindQuality)
    else { return }
    let item = AVPlayerItem(url: url)
    rewindItemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      let status = item.status
      let message = item.error?.localizedDescription
      guard let model = self else { return }
      Task { @MainActor in model.rewindItemChanged(status, error: message) }
    }
    rewindPlayer.automaticallyWaitsToMinimizeStalling = true
    rewindPlayer.pause()
    rewindPlayer.replaceCurrentItem(with: item)
    rewindIdleSince = Date()
  }

  /// While the bar is held (live): keeps the loaded VOD near the finger, so letting go starts
  /// playing almost at once.
  func scrubRewind(to time: Double) {
    guard !isRewinding, time < broadcastElapsed - 20, let item = rewindPlayer.currentItem, item.status == .readyToPlay,
      item.duration.seconds.isFinite, time < item.duration.seconds - 10
    else { return }
    scrubTarget = time
    rewindIdleSince = Date()
    guard !scrubSeeking else { return }
    scrubSeek(to: time)
  }

  private func scrubSeek(to time: Double) {
    scrubSeeking = true
    let loose = CMTime(seconds: 4, preferredTimescale: 600)
    rewindPlayer.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: loose, toleranceAfter: loose) {
      [weak self] _ in
      Task { @MainActor in
        guard let model = self else { return }
        model.scrubSeeking = false
        // The finger moved on meanwhile: follow it (one seek at a time).
        if !model.isRewinding, let next = model.scrubTarget, abs(next - time) > 3 { model.scrubSeek(to: next) }
      }
    }
  }

  private func startRewindItem(at seconds: Double) {
    guard rewindQuality < rewindVariants.count, let rewindSource,
      let url = StreamProxy.shared.mediaURL(for: rewindSource, index: rewindQuality)
    else { return }
    rewindPendingSeek = seconds
    rewindEndSince = nil
    let item = AVPlayerItem(url: url)
    rewindItemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      let status = item.status
      let message = item.error?.localizedDescription
      guard let model = self else { return }
      Task { @MainActor in model.rewindItemChanged(status, error: message) }
    }
    rewindPlayer.automaticallyWaitsToMinimizeStalling = true
    rewindPlayer.replaceCurrentItem(with: item)
    isBuffering = true
  }

  private func rewindItemChanged(_ status: AVPlayerItem.Status, error: String?) {
    guard isRewinding || status == .failed else { return }
    switch status {
    case .readyToPlay:
      guard let target = rewindPendingSeek else { return }
      rewindPendingSeek = nil
      // Loaded before more was recorded and the target is past its end: load it again.
      if let item = rewindPlayer.currentItem, item.duration.seconds.isFinite, target > item.duration.seconds - 10 {
        startRewindItem(at: target)
        return
      }
      guard target >= 1 else {
        if !isPaused { rewindPlayer.play() }
        return
      }
      rewindSeeking = true
      rewindPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: Self.seekTolerance) {
        [weak self] _ in
        Task { @MainActor in
          guard let model = self, model.isRewinding else { return }
          model.rewindSeeking = false
          if !model.isPaused { model.rewindPlayer.play() }
        }
      }
    case .failed:
      guard isRewinding else {
        rewindItemObservation = nil
        rewindPlayer.replaceCurrentItem(with: nil)
        return
      }
      ActivityLog.shared.add("The VOD stopped playing (\(error ?? "error")); back to live")
      returnToLive()
    default:
      break
    }
  }

  /// Back to the live stream at the live edge.
  func returnToLive() {
    guard isRewinding else { return }
    // Keep the VOD's picture up (paused) until the live stream is playing again.
    isRewinding = false
    rewindPendingSeek = nil
    rewindSeeking = false
    rewindItemObservation = nil
    rewindPlayer.pause()
    rewindLinger = rewindShowing
    lingerSince = Date()
    rewindIdleSince = Date()
    scrubTarget = nil
    isBuffering = true
    isPaused = false
    #if canImport(AmazonIVSPlayer)
      if let lowLatency {
        lowLatency.resumeLive()
        return
      }
    #endif
    goLive()
  }

  private func stopRewindPlayback() {
    isRewinding = false
    rewindPendingSeek = nil
    rewindSeeking = false
    rewindItemObservation = nil
    rewindPlayer.pause()
    rewindPlayer.replaceCurrentItem(with: nil)
    rewindShowing = false
    rewindLinger = false
  }

  private func endRewindLinger() {
    rewindLinger = false
    rewindShowing = false
    lingerSince = nil
  }

  /// The seek bar was touched: get the VOD ready before it's needed.
  func prepareRewind() {
    guard rewindSource != nil else { return }
    if isRewinding { return }
    let item = rewindPlayer.currentItem
    if item == nil || item?.status == .failed { preloadRewindItem() }
    rewindIdleSince = Date()
  }

  private func suspendLive() {
    #if canImport(AmazonIVSPlayer)
      if let lowLatency {
        lowLatency.suspend()
        return
      }
    #endif
    player.pause()
  }

  private func tickRewind() {
    let current = rewindPlayer.currentTime().seconds
    // Held at the target while seeking (the player reports the old spot, or 0, until it lands).
    if current.isFinite, rewindPendingSeek == nil, !rewindSeeking { rewindPosition = current }
    let status = rewindPlayer.timeControlStatus
    let buffering = status == .waitingToPlayAtSpecifiedRate || rewindPendingSeek != nil || rewindSeeking
    if buffering != isBuffering { isBuffering = buffering }
    if status == .playing, !rewindShowing { rewindShowing = true }
    if !buffering, rewindPlayer.currentItem?.status == .readyToPlay, isPaused != (status == .paused) {
      isPaused = status == .paused
    }
    if pictureInPictureActive != (rewindPictureInPicture?.isPictureInPictureActive ?? false) {
      pictureInPictureActive = rewindPictureInPicture?.isPictureInPictureActive ?? false
    }
    latency = max(0, broadcastElapsed - rewindPosition)
    // The end of what was recorded when it was loaded: more has been recorded since, so load it
    // again, or go live if that's all but caught up.
    if let item = rewindPlayer.currentItem, rewindPendingSeek == nil, !rewindSeeking, !isPaused,
      item.duration.seconds.isFinite, item.duration.seconds > 0, current >= item.duration.seconds - 1.5
    {
      if rewindEndSince == nil { rewindEndSince = Date() }
      if let since = rewindEndSince, Date().timeIntervalSince(since) > 1 {
        rewindEndSince = nil
        if broadcastElapsed - current > 90, Date().timeIntervalSince(lastRewindReload) > 20 {
          lastRewindReload = Date()
          startRewindItem(at: current)
        } else {
          ActivityLog.shared.add("Caught up with the recording: back to live")
          returnToLive()
          return
        }
      }
    } else {
      rewindEndSince = nil
    }
    watchForStall(rewindPlayer, position: current, pending: rewindPendingSeek != nil || rewindSeeking)
    if AppSettings.shared.showVideoStats, let item = rewindPlayer.currentItem {
      var lines = [StatLine(label: "Player", value: "Apple (AVPlayer), rewinding the VOD")]
      if rewindQuality < rewindVariants.count { lines.append(StatLine(label: "Quality", value: rewindVariants[rewindQuality].label)) }
      let size = item.presentationSize
      if size.width > 0 { lines.append(StatLine(label: "Resolution", value: "\(Int(size.width))×\(Int(size.height))")) }
      if let event = item.accessLog()?.events.last {
        lines.append(StatLine(label: "Bitrate", value: StatFormat.mbps(event.indicatedBitrate)))
        lines.append(StatLine(label: "Bandwidth", value: StatFormat.mbps(event.observedBitrate)))
      }
      lines.append(StatLine(label: "Behind live", value: Format.duration(Int(broadcastElapsed - rewindPosition))))
      stats = lines
    } else if !stats.isEmpty {
      stats = []
    }
  }

  /// Stuck loading at the same spot for a while (a missing or broken part of a VOD): skip ahead
  /// a little instead of freezing.
  private func watchForStall(_ player: AVPlayer, position: Double, pending: Bool) {
    guard !pending, player.timeControlStatus == .waitingToPlayAtSpecifiedRate, position.isFinite else {
      stall = nil
      return
    }
    guard let current = stall, abs(current.position - position) < 0.5 else {
      stall = (position, Date())
      return
    }
    guard Date().timeIntervalSince(current.since) > 7 else { return }
    stall = nil
    let target = position + 8
    ActivityLog.shared.add("Playback stuck at \(Format.duration(Int(position))); skipping ahead a few seconds")
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: Self.seekTolerance, toleranceAfter: Self.seekTolerance) {
      _ in
      Task { @MainActor in player.play() }
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
