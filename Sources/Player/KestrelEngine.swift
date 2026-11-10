// Kestrel's own player, part 2: playing what TSDemuxer unpacks.
//
// Twitch's own player keeps its streams about a second behind live by downloading each segment
// while it's still being made (Twitch lists those ahead of time, as prefetch hints) and showing
// its frames as they arrive. The Apple player can't: it only plays finished segments, so it
// stays several seconds back. This does what Twitch's does, with the system's own pieces:
//
//   playlist (from the ad-free session)  →  LiveSegmentPlanner: which segments, in order
//   each segment streamed over HTTP       →  TSDemuxer: video and audio frames, as bytes arrive
//   frames                                →  sample buffers on one timeline (StreamTimeline)
//   pictures: AVSampleBufferDisplayLayer, on a clock kept on the sound
//   sound: decoded here, through AVAudioEngine with a time-pitch unit (AudioOutput)
//
// and steers the speed with the same LiveCatchUp as the low-latency player, so it
// stays close to live and rides out hiccups the same way. It starts already near the live edge:
// the frames before its starting point are decoded but not shown. It runs on iPhone and Apple TV.

import AVFoundation
import CoreMedia
import Foundation
import UIKit
import VideoToolbox

@MainActor
final class KestrelEngine: NSObject {
  enum State: Equatable {
    case starting
    case playing
    /// Ran out of video: waiting for more.
    case stalled
    case failed(String)
  }

  /// The picture on screen (replaced by a fresh one when the app comes back: see `catchUpScreen`).
  private(set) var displayLayer = AVSampleBufferDisplayLayer()
  /// The one it replaced, left showing underneath until the new one has a picture.
  private(set) var retiringLayer: AVSampleBufferDisplayLayer?
  /// Back from Picture in Picture: the frame the window was showing, held over the old layer
  /// until the new one draws (the old one's picture is often gone after the background: black).
  private(set) var coverLayer: CALayer?
  /// The screen's picture hidden while Picture in Picture's window is up (the window shows the
  /// copy; the system's "playing in Picture in Picture" shows in the app).
  var screenHiddenForPictureInPicture = false {
    didSet {
      if oldValue != screenHiddenForPictureInPicture { screenNote(screenHiddenForPictureInPicture ? "window opening: screen hidden" : "window heading back: screen shown") }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for layer in [displayLayer, retiringLayer, coverLayer].compactMap({ $0 }) { layer.isHidden = screenHiddenForPictureInPicture }
      CATransaction.commit()
    }
  }
  private var retiringSince = Date.distantPast
  private var caughtUpAt = Date.distantPast
  /// Since when the new screen layer has had a frame on screen (see `retireOldLayer`).
  private var drawingSince: Date?
  /// Told when the screen's layers change (the view puts the new one on top of the retiring one).
  /// Without it, the layer is caught up in place (flushed: black until it has a picture again).
  var onScreenLayers: (() -> Void)?
  /// Picture in Picture's window is up (the old picture isn't taken away before it's gone).
  var windowUp = false
  /// The screen's own layers are in the Picture in Picture window (the kind without controls):
  /// they go on being fed in the background.
  var screenInWindow = false
  /// The view the screen's layers are in (set by it), and who wants to know when it's there.
  weak var screenView: UIView? {
    didSet { if let screenView, screenView !== oldValue { onScreenView?(screenView) } }
  }
  var onScreenView: ((UIView) -> Void)?
  /// The screen's layer has a frame on screen and is caught up (nothing hidden).
  var screenDrawing: Bool {
    guard !screenBehind, !inBackground, !displayLayer.isHidden, displayLayer.status == .rendering,
      !displayLayer.requiresFlushToResumeDecoding
    else { return false }
    if #available(iOS 17.4, tvOS 17.4, *) { return displayLayer.sampleBufferRenderer.displayedPixelBuffer() != nil }
    return true
  }
  /// The Picture in Picture copy gets frames (only while it may be needed: see KestrelController).
  private(set) var mirrorFed = false

  /// Starts or stops feeding the copy. Starting brings it straight up to the frame playing now
  /// from the frames since the last keyframe (decoded out of sight), so a window opening right
  /// away has the picture.
  func feedMirror(_ on: Bool) {
    guard let mirrorLayer, on != mirrorFed else { return }
    mirrorFed = on
    // Stopped, it keeps the frame it shows: iOS only offers Picture in Picture (swiping home)
    // for a copy with a picture, and an empty one made the first swipe after opening a stream
    // just leave the app.
    guard on else { return }
    mirrorLayer.flush()
    guard decodeInLayer, group.first?.keyframe == true else {
      mirrorWaiting = true
      return
    }
    mirrorWaiting = false
    let showing = now
    for earlier in group {
      if let sample = earlier.sample(hidden: earlier.pts < showing - frameLength) { mirrorLayer.enqueue(sample) }
    }
  }

  /// The picture's shape (width to height), once known.
  var videoAspect: CGSize? {
    guard let videoFormat else { return nil }
    let size = CMVideoFormatDescriptionGetPresentationDimensions(videoFormat, usePixelAspectRatio: true, useCleanAperture: true)
    return size.width > 0 && size.height > 0 ? size : nil
  }

  /// Puts the Picture in Picture copy's view over the picture's spot again (set by the view).
  var placeMirror: (() -> Void)?
  /// Where the copy is, for the log (set by the view).
  var describeMirror: (() -> String)?
  /// The sound, decoded here and played through AVAudioEngine; it's also the clock (see `syncClock`).
  let audio = AudioOutput()
  /// The picture's clock: on the host clock, kept on the sound's (every screen layer runs on it).
  let videoClock: CMTimebase
  /// The speed playing at (0 when held).
  private(set) var speed: Float = 0

  /// The rendition playing (an index into the session's renditions).
  private(set) var rendition: Int
  private(set) var state: State = .starting {
    didSet { if state != oldValue { onState?(state) } }
  }
  var onState: ((State) -> Void)?

  /// A rendition's media playlist, or nil when it couldn't be had.
  private let playlist: @Sendable (Int) async -> String?
  /// From the newest complete segment (it starts with a keyframe): the frames from there up to
  /// the starting point are decoded without being shown (see `startIfReady`).
  private var planner = LiveSegmentPlanner(startBack: 0)
  private var timeline = StreamTimeline()
  private(set) var catchUp: LiveCatchUp
  private var loads: [SegmentLoad] = []
  private lazy var urlSession: URLSession = makeSession()
  private(set) var reconnects = 0

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.default
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 10
    configuration.httpMaximumConnectionsPerHost = 6
    return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
  }
  private var pollTask: Task<Void, Never>?
  private var ticker: Timer?
  private var running = false

  private var videoFormat: CMVideoFormatDescription?
  private var parameterSets: Data?
  private var audioFormat: CMAudioFormatDescription?
  private var audioConfig: ADTS.Config?
  /// The decoder needs a keyframe first (at the start, and after a gap).
  private var waitingForKeyframe = true
  /// The frames since the last keyframe (see `feedScreen`).
  private var group: [GroupFrame] = []
  /// The screen's layer missed frames in the background and needs bringing up to date.
  private var screenBehind = false
  /// The app's in the background (from the notifications: the application state lags behind
  /// them, and still read "background" while the app was already coming back).
  private var inBackground = UIApplication.shared.applicationState == .background
  private var lifecycleTokens: [NSObjectProtocol] = []
  /// The last few seconds of sound handed over (to refill after an automatic flush).
  private var audioHistory: [(AudioFrame, Int64)] = []
  private var lastAudioTime: Int64?
  private(set) var audioAutoFlushes = 0
  /// Times the sound was put back on the picture (see `syncClock`).
  private(set) var audioResyncs = 0
  private var lastAudioResync = Date.distantPast
  private var lastHeard: Int64?
  private var playingSince: Date?
  private var startSkipDone = false
  /// Started but not yet shown (see `startIfReady`).
  private(set) var settling = false
  /// The segment being made, before the start: when its frames came in (see `backlogIn`).
  private var liveArrivals: [(at: Date, newest: Int64)] = []
  private var liveSince: Date?
  private var delivery = KestrelEngine.deliveryDelay
  /// When the picture last moved (Picture in Picture opening or closing, the app leaving or coming
  /// back): a stall just after is the move's, not the connection's.
  private var lastScreenChange = Date.distantPast
  /// The newest video's delay on the way (seconds, learned from the stream's clock).
  var arrivalDelay: Double { delivery }
  /// How long each playlist took to come back, over the last minute.
  private var playlistTimes: [(at: Date, took: Double)] = []
  /// The slowest playlist in the last minute (seconds).
  var slowestPlaylist: Double { playlistTimes.map(\.took).max() ?? 0 }
  /// Latency has been high since then (see `noteIfStuckBehind`), and whether that was logged.
  private var highLatencySince: Date?
  private var highLatencyNoted = false
  private var lastHeardMoved = Date()
  private(set) var lateAudio = 0
  private(set) var audioGaps = 0
  private(set) var largestAudioGap = 0.0
  private(set) var audioOverlaps = 0
  private var inAudioOverlap = false
  private var lastAudioJumpNote = Date.distantPast
  /// The Picture in Picture copy (see `makeMirror`).
  private(set) var mirrorLayer: AVSampleBufferDisplayLayer?
  private var mirrorWaiting = true
  private var firstVideoTime: Int64?
  private var lastVideoTime: Int64?
  /// The newest sound in hand (nil while the stream has shown none).
  private var newestAudio: Int64?
  private var lastDecodeTime: Int64?
  /// Frame times put on an even rhythm (see FrameGrid).
  private var grid = FrameGrid()
  private var frameLength: Int64 = 3000
  /// Before the clock starts: the frames so far, held until where to start is known (then the
  /// ones before it are decoded but not shown).
  private var heldVideo: [(frame: VideoFrame, pts: Int64, dts: Int64)] = []
  private var heldAudio: [(frame: AudioFrame, pts: Int64)] = []
  /// Playing (the clock runs).
  private(set) var clockRunning = false
  private var stalledSince: Date?
  /// A frame time on the timeline and when it was captured (from the playlist's dates).
  private var anchor: (time: Int64, date: Date)?
  private var paused = false
  private var startedLoading = Date()
  private(set) var stalls = 0
  private(set) var segmentsLoaded = 0
  /// Fragmented MP4 initialization segments, by address (and the ones being fetched).
  private var inits: [String: FMP4Init] = [:]
  private var fetchingInits: Set<String> = []
  // For the stats (what to look at when a stream won't play).
  private(set) var container = "–"
  private(set) var videoFramesQueued = 0
  private(set) var videoFramesHidden = 0
  private(set) var audioFramesQueued = 0
  private(set) var decoderFailures = 0
  private(set) var lastDecoderError: String?
  /// Where it started, behind the newest frame it had (seconds).
  private(set) var startedBehind: Double?
  /// Video is decoded here (VideoToolbox) and the display layer is handed finished pictures, in
  /// the order they're shown. Handing it compressed frames left the picture black on streams with
  /// B-frames (High profile sources), with the layer reporting all was well; decoding ourselves
  /// puts frames in display order and tells us about every frame.
  private var decoder: VTDecompressionSession?
  private var decoderFormat: CMVideoFormatDescription?
  /// Decoded pictures earlier than this aren't shown (they're decoded so later ones can be).
  private var showFrom: Int64 = .min
  private(set) var framesDecoded = 0
  private(set) var framesShown = 0
  private(set) var decodeErrors = 0
  private(set) var lastDecodeStatus: OSStatus = noErr
  private var muted = false
  /// Compressed frames go to the display layer, which decodes them itself: that keeps decoding in
  /// Picture in Picture and the background, where our own decoding session is shut down. If the
  /// layer keeps failing on a stream, decoding moves here (VideoToolbox) for the rest of it.
  private(set) var decodeInLayer = true
  /// Decoding here by request (see `setDecodeHere`), not because the layer kept failing.
  private var decodingHereByRequest = false
  /// Every decoded picture and when it's shown, while decoding here (multi-view's Picture in
  /// Picture with controls draws all the streams into one picture from these).
  var onPicture: ((CVImageBuffer, CMTime) -> Void)?

  /// Decodes with VideoToolbox here (pictures handed to the screen's layer and `onPicture`)
  /// instead of in the layer, or back. From the next keyframe.
  func setDecodeHere(_ on: Bool) {
    if on, decodeInLayer {
      decodeInLayer = false
      decodingHereByRequest = true
      waitingForKeyframe = true
    } else if !on, decodingHereByRequest {
      decodingHereByRequest = false
      decodeInLayer = true
      displayLayer.flush()
      waitingForKeyframe = true
    }
  }

  /// The stream's clock: what's showing now.
  var clockTime: CMTime { CMTimebaseGetTime(videoClock) }
  private var layerFailures: [Date] = []

  // Quality: the best that plays smoothly (ConnectionFit), unless one is picked by hand.
  /// The renditions, best first.
  let renditions: [Int]
  private var fit: ConnectionFit
  /// Steps down after stalls and back up later (at the start and with Auto); off for a quality
  /// picked by hand.
  private(set) var autoQuality = true

  // How the video arrives (for the stats, and to tell bursts from hiccups).
  private var lastArrival: Date?
  private var arrivalGaps: [(at: Date, gap: Double)] = []
  /// The longest wait between pieces of a segment still being made, in the last minute.
  var longestArrivalGap: Double {
    arrivalGaps.filter { Date().timeIntervalSince($0.at) < 60 }.map(\.gap).max() ?? 0
  }
  /// The longest wait at a segment's end, in the last minute (its frames all in, the download
  /// not yet closed, the next one's frames waiting).
  private var handoffWaits: [(at: Date, wait: Double)] = []
  var longestHandoffWait: Double {
    handoffWaits.filter { Date().timeIntervalSince($0.at) < 60 }.map(\.wait).max() ?? 0
  }

  static let clock: Int32 = 90_000
  /// The fastest it plays (the sound pitch-corrected).
  static let maxRate: Float = 1.2

  /// - Parameters:
  ///   - renditions: the session's video renditions, best first (for stepping down and up).
  ///   - auto: steps down when the connection can't keep up (off: `rendition` stays).
  init(
    rendition: Int, renditions: [Int], auto: Bool = true, startMargin: Double? = nil,
    playlist: @escaping @Sendable (Int) async -> String?
  ) {
    self.rendition = rendition
    self.renditions = renditions
    self.playlist = playlist
    autoQuality = auto
    fit = ConnectionFit(count: renditions.count)
    // Video arrives over HTTP in bursts, so the buffer reading dips a few tenths between them:
    // those aren't hiccups to keep a margin for (counted, they raised it to over a second).
    catchUp = LiveCatchUp(targetBuffer: startMargin, noise: 0.35)
    var timebase: CMTimebase?
    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
    videoClock = timebase!
    super.init()
    let center = NotificationCenter.default
    lifecycleTokens.append(
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.inBackground = true
          self?.lastScreenChange = Date()
        }
      })
    lifecycleTokens.append(
      center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.enteringForeground() }
      })
    lifecycleTokens.append(
      center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        // Decoding is allowed again from here: catch up now if it couldn't before.
        MainActor.assumeIsolated { self?.enteringForeground() }
      })
    displayLayer.videoGravity = .resizeAspect
    displayLayer.controlTimebase = videoClock
    CMTimebaseSetRate(videoClock, rate: 0)
    // The system stopped the sound and it started again: what's still to come goes back in.
    audio.onReset = { [weak self] in self?.refillAudio() }
  }

  // MARK: Lifecycle

  func start() {
    guard !running else { return }
    running = true
    paused = false
    state = .starting
    startedLoading = Date()
    pollTask = Task { [weak self] in await self?.poll() }
    ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  /// - Parameter keepPicture: the frame showing stays up (a pause, a restart): only queued frames
  ///   go. Emptied, a pause turned the player black instead of holding the paused frame, and every
  ///   restart showed black until the new start's first frame.
  func stop(keepPicture: Bool = false) {
    running = false
    pollTask?.cancel()
    pollTask = nil
    ticker?.invalidate()
    ticker = nil
    for load in loads { load.task?.cancel() }
    loads = []
    setSpeed(0)
    if keepPicture {
      displayLayer.flush()
      mirrorLayer?.flush()
    } else {
      displayLayer.flushAndRemoveImage()
      mirrorLayer?.flushAndRemoveImage()
    }
    retireOldLayer(force: true)
    group = []
    audio.flush()
    audioHistory = []
    lastAudioTime = nil
    inAudioOverlap = false
    closeDecoder()
  }

  /// For good: the downloads' session is let go (it holds its delegate, this engine, until then).
  func shutDown() {
    stop()
    urlSession.invalidateAndCancel()
    placeMirror = nil
    onScreenLayers = nil
  }

  /// Starts over at the live edge (after a pause, a long dropout, a failure).
  func restart() {
    stop(keepPicture: true)
    // (Whole segments: one more back, to have a segment's worth on top of the margin.)
    planner = LiveSegmentPlanner(startBack: wholeSegments ? 1 : 0)
    aheadHistory = []
    paceHistory = []
    slowSince = nil
    timeline = StreamTimeline()
    heldVideo = []
    heldAudio = []
    liveArrivals = []
    liveSince = nil
    startSkipDone = false
    settling = false
    lastDecodeTime = nil
    grid.reset()
    videoFormat = nil
    parameterSets = nil
    audioFormat = nil
    audioConfig = nil
    waitingForKeyframe = true
    firstVideoTime = nil
    lastVideoTime = nil
    newestAudio = nil
    clockRunning = false
    stalledSince = nil
    anchor = nil
    catchUp.restart()
    start()
  }

  func setPaused(_ pause: Bool) {
    guard pause != paused else { return }
    if pause {
      paused = true
      stop(keepPicture: true)
    } else {
      // A live stream resumes at live.
      restart()
    }
  }

  /// Another rendition: from the next segment on (Twitch's renditions share their timeline).
  /// Picked by hand, it stays (no stepping down).
  func setRendition(_ index: Int, byHand: Bool = true) {
    if byHand { autoQuality = false }
    guard index != rendition else { return }
    // (Best first: further along the list is lower.)
    let lowered = (renditions.firstIndex(of: index) ?? 0) > (renditions.firstIndex(of: rendition) ?? 0)
    rendition = index
    catchUp.qualityChanged(lowered: lowered)
  }

  /// The best Auto may play, as a place in `renditions` (multi-view: no sharper than the picture
  /// is shown). Auto's own steps stay at or below it (they used to step straight past it: six
  /// tiles each "trying the better quality again" at 1080p flooded the connection).
  private var capPosition: Int?

  func setCap(_ rendition: Int?) {
    capPosition = rendition.flatMap { renditions.firstIndex(of: $0) }
    // Auto's steps count from the cap (a step down from above it would change nothing; a cap
    // raised for a bigger picture is taken at once).
    if let capPosition { fit.start(at: capPosition, tryAfter: 1e9) }
    if autoQuality { applyFit() }
  }

  /// Plays what Auto has settled on, within the cap.
  private func applyFit() {
    guard !renditions.isEmpty else { return }
    let position = min(renditions.count - 1, max(fit.step, capPosition ?? 0))
    setRendition(renditions[position], byHand: false)
  }

  /// An ad break (the stream from an ad-free copy meanwhile): nothing learned from how it arrives,
  /// and its playlists don't count toward "not low latency".
  private var inAdBreak = false

  func setAdBreak(_ active: Bool) {
    guard active != inAdBreak else { return }
    inAdBreak = active
    if active {
      catchUp.pauseLearning()
      playlistsWithoutPrefetch = 0
    } else {
      catchUp.resumeLearning()
      // (The surplus shows once Twitch's own segments are coming in: looked for for a few seconds.)
      jumpAfterAdUntil = Date().addingTimeInterval(10)
    }
  }

  /// The least to keep in hand on this connection (cellular: more, see NetworkWatch).
  func setMarginFloor(_ value: Double) {
    catchUp.setFloor(value)
  }

  /// Auto, starting `steps` qualities down from the best (on cellular), trying better once it's
  /// played smoothly a while.
  func startLower(steps: Int) {
    guard autoQuality, steps > 0, !renditions.isEmpty else { return }
    fit.start(at: steps)
    applyFit()
  }

  /// Auto: the best quality that plays smoothly.
  func setAuto() {
    autoQuality = true
    fit = ConnectionFit(count: renditions.count)
    if let capPosition { fit.start(at: capPosition, tryAfter: 1e9) }
    applyFit()
  }

  func setMuted(_ mute: Bool) {
    muted = mute
    audio.setMuted(mute || settling)
  }

  func setVolume(_ volume: Float) {
    audio.setVolume(volume)
  }

  // MARK: Readings

  /// Where playback is, on the timeline (90 kHz).
  private var now: Int64 { Int64(CMTimebaseGetTime(videoClock).convertScale(Self.clock, method: .default).value) }

  /// Seconds of video in hand ahead of what's showing.
  var bufferAhead: Double? {
    guard let playable = newestPlayable else { return nil }
    let ahead = clockRunning ? Double(playable - now) : Double(playable - (firstVideoTime ?? playable))
    return max(0, ahead / Double(Self.clock))
  }

  /// The end of what can play: picture and sound both in hand. In fragmented MP4 a chunk's sound
  /// can come in well after its picture; counting the picture alone, playback ran into sound that
  /// hadn't arrived (silence, then a stall), and started too close to it.
  private var newestPlayable: Int64? {
    guard let last = lastVideoTime else { return nil }
    let video = last + frameLength
    // (Sound that's stopped coming altogether, seconds behind, isn't waited for.)
    guard let audio = newestAudio, video - audio < 4 * Int64(Self.clock) else { return video }
    return min(video, audio)
  }

  /// Seconds behind live: now, less when the frame showing was captured.
  /// How far from live it plays: what's in hand ahead of the picture (on average: video comes in
  /// pieces) plus how long the newest video takes to get here. Both measured here; the stream's
  /// own clock (some channels have it seconds off) only nudges the second, within sense.
  var latency: Double? {
    guard clockRunning, let ahead = bufferAhead else { return nil }
    // (Whole segments: steered by the low point, so half a segment more is in hand on average.)
    return (catchUp.level ?? ahead) + (deliversWhole ? Self.segmentLength / 2 : 0) + delivery
  }

  /// From the stream's own timestamps (Twitch's program date-time), which some channels have well
  /// off (one read 33 s behind with 2.5 s in hand): only for lining up ad times.
  var rawLatency: Double? {
    streamClockLatency
  }

  /// By the stream's own clock, unclamped (a channel whose clock runs ahead reads below zero).
  private var streamClockLatency: Double? {
    guard clockRunning, let anchor else { return nil }
    let shown = anchor.date.addingTimeInterval(Double(now - anchor.time) / Double(Self.clock))
    let value = Date().timeIntervalSince(shown)
    return value.isFinite ? value : nil
  }


  /// How far the stream's timestamps are off, when they're clearly off: checked once a few
  /// seconds in, against what's in hand (the player is never much further behind live than that
  /// plus a second or two on the way).
  /// The newest video's delay on the way, learned slowly from the stream's clock where it makes
  /// sense (0.2 to 4 s), else left at the usual.
  private func learnDelivery(ahead: Double) {
    // (Not during an ad break: the stream comes another way then, and its delay isn't this one's.)
    guard !inAdBreak, let raw = streamClockLatency, let since = playingSince, Date().timeIntervalSince(since) > 2 else { return }
    let seen = raw - ahead
    guard seen > 0.2, seen < 4 else { return }
    delivery += (seen - delivery) * 0.03
  }

  /// Latency stuck high (3 s or more for half a minute, playing, outside ad breaks): one line in
  /// the activity log saying which part it is. Reopening a stream stuck like that brought it back
  /// to 1–2 s; what was behind (the video held here, or the video arriving late, and the
  /// playlists) wasn't known, so nothing's done about it yet.
  private func noteIfStuckBehind(ahead: Double) {
    guard let latency, !inAdBreak, stalledSince == nil else {
      highLatencySince = nil
      return
    }
    if latency < 2.5 {
      highLatencySince = nil
      highLatencyNoted = false
      return
    }
    guard latency >= 3 else { return }
    let since = highLatencySince ?? Date()
    highLatencySince = since
    guard !highLatencyNoted, Date().timeIntervalSince(since) > 30 else { return }
    highLatencyNoted = true
    ActivityLog.shared.add(
      String(
        format: "Kestrel player: %.1f s behind for half a minute: %.2f s in hand (margin %.1f s, speed %.2f×), video arriving %.1f s late, slowest playlist %.1f s, %@%@",
        latency, ahead, catchUp.targetBuffer, speed, delivery, slowestPlaylist,
        latestHasPrefetch ? "segments as they're made" : "whole segments", wholeSegments ? " (not low latency)" : ""))
  }

  /// How far behind the broadcast the newest video usually arrives (Twitch low latency).
  static let deliveryDelay = 0.8

  var rate: Float { speed }

  // MARK: Playlist

  /// The stream's video comes in whole segments (see `poll`): what's in hand jumps up by a
  /// segment each time one is listed and runs down in between. Steered by the low point of that
  /// (`trough`), not the reading of the moment: steered by the moment, every run-down looked like
  /// a hiccup, the margin kept growing and the stream drifted further and further behind.
  private(set) var wholeSegments = false
  /// Video is coming in whole segments right now: a channel not on low latency, or a low-latency one
  /// during an ad break (its prefetch hints are held back then, so an ad can't flash on screen).
  /// Steered for that meanwhile: a segment's worth more in hand, by the low point (it stalled
  /// between segments and learned a bigger margin, every break).
  private var deliversWhole: Bool { wholeSegments || (inAdBreak && !latestHasPrefetch) }
  private var latestHasPrefetch = true

  /// This stream has shown prefetch hints (it's on low latency), and playlists in a row without.
  private var prefetchSeen = false
  private var playlistsWithoutPrefetch = 0
  /// One segment's worth (Twitch's are two seconds).
  static let segmentLength = 2.0
  private var aheadHistory: [(at: Date, ahead: Double)] = []

  /// The least in hand over the last few seconds (longer than the gap between segments).
  private func trough(_ ahead: Double) -> Double {
    let now = Date()
    aheadHistory.append((now, ahead))
    aheadHistory.removeAll { now.timeIntervalSince($0.at) > 3 }
    return aheadHistory.map(\.ahead).min() ?? ahead
  }

  private func poll() async {
    while running, !Task.isCancelled {
      let asked = Date()
      let fetched = await playlist(rendition)
      if fetched != nil {
        playlistTimes.append((Date(), Date().timeIntervalSince(asked)))
        playlistTimes.removeAll { Date().timeIntervalSince($0.at) > 60 }
      }
      if let text = fetched, running {
        // No prefetch hints: a channel not on Twitch's low latency. Its video comes two seconds at
        // a time, once each segment is finished. A low-latency channel's playlist can lack them
        // too, for a while (an ad break, served without them on purpose; a moment of Twitch's):
        // judged by one playlist, a low-latency stream was taken for one that isn't and started
        // further back, keeping more in hand. So only a channel that hasn't shown any in this
        // session, over four playlists in a row (about three seconds), counts as not low latency.
        if text.contains("#EXTINF") {
          latestHasPrefetch = text.contains("#EXT-X-TWITCH-PREFETCH:")
          if text.contains("#EXT-X-TWITCH-PREFETCH:") {
            prefetchSeen = true
            playlistsWithoutPrefetch = 0
            wholeSegments = false
          } else if !inAdBreak, !text.contains(",Amazon"), !text.localizedCaseInsensitiveContains("stitched") {
            // (A playlist with ad segments in it doesn't count: an ad at the start of a low-latency
            // stream is served without the hints too.)
            playlistsWithoutPrefetch += 1
            if !prefetchSeen, playlistsWithoutPrefetch >= 4 { wholeSegments = true }
          }
        }
        let planned = planner.plan(text)
        for segment in planned { begin(segment) }
      }
      // Twitch's low-latency playlists move every couple of seconds, and list the next two
      // segments ahead: often enough to start each one as soon as it's listed.
      try? await Task.sleep(nanoseconds: 700_000_000)
    }
  }

  private func begin(_ planned: LiveSegmentPlanner.Planned) {
    guard URL(string: planned.uri) != nil else { return }
    let load = SegmentLoad(planned: planned)
    loads.append(load)
    request(load)
  }

  private func request(_ load: SegmentLoad) {
    guard let url = URL(string: load.planned.uri) else { return }
    var request = URLRequest(url: url)
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    // Part-way in already: just the rest.
    if load.received > 0 {
      request.setValue("bytes=\(load.received)-", forHTTPHeaderField: "Range")
      load.skip = load.received
    }
    let task = urlSession.dataTask(with: request)
    load.task = task
    load.requestedAt = Date()
    task.resume()
  }

  /// The segment due next stuck (nothing from it for two seconds) while the ones after it come in,
  /// with the video about to run out: asked for again (the rest of it, if part came in), and after
  /// two tries, gone on without. It waited out the full time limit before, ten seconds with the
  /// picture frozen, then the segments that had piled up behind it were skipped through.
  private func refetchStuckFront() {
    guard loads.count > 1, let front = loads.first, !front.finished, !front.handedOver, let asked = front.requestedAt else { return }
    let now = Date()
    let frontLast = max(front.lastArrival ?? asked, asked)
    guard now.timeIntervalSince(frontLast) > 2,
      loads.dropFirst().contains(where: { ($0.lastArrival ?? .distantPast) > frontLast }),
      stalledSince != nil || (clockRunning && (bufferAhead ?? 0) < 0.6)
    else { return }
    if front.retries >= 2 {
      front.task?.cancel()
      front.task = nil
      front.frames += front.demuxer?.flush() ?? []
      front.failed = true
      front.finished = true
      ActivityLog.shared.add("Kestrel player: segment \(front.planned.sequence) still stuck; going on without the rest of it")
      pump()
      return
    }
    front.retries += 1
    let stale = front.task
    request(front)
    stale?.cancel()
    ActivityLog.shared.add(
      String(
        format: "Kestrel player: segment %d stuck (%@) while the next ones came in; asked for it again",
        front.planned.sequence, front.received > 0 ? "\(front.received / 1024) KB in" : "nothing in"))
  }

  private var lastReconnect = Date.distantPast

  /// The downloads share a few connections to Twitch's video server, and one can go dead without
  /// closing (the Wi-Fi dropping packets for a moment, a router forgetting it): every segment on it
  /// then waits out the full time limit, and they failed together ten or more seconds later (20
  /// at once in one log, the picture frozen meanwhile). Once nothing has come in on any of them
  /// for a few seconds while a segment that's due waits, the ones not started are asked for again
  /// on fresh connections.
  private func reconnectIfStuck() {
    let now = Date()
    guard now.timeIntervalSince(lastReconnect) > 8, let first = loads.first, !first.finished,
      let asked = first.requestedAt, now.timeIntervalSince(asked) > 3
    else { return }
    let quietFor = now.timeIntervalSince(max(lastArrival ?? asked, asked))
    // (Not while the margin holds: the segment being made is meant to trickle.)
    let due = !clockRunning || (bufferAhead ?? 0) < 0.4
    let waiting = loads.filter { !$0.finished && $0.received == 0 }
    guard quietFor > 3, due, !waiting.isEmpty else { return }
    lastReconnect = now
    reconnects += 1
    let old = urlSession
    urlSession = makeSession()
    for load in waiting {
      // Not started yet: asked for again on the new connections.
      let stale = load.task
      request(load)
      stale?.cancel()
    }
    // One part-way in carries on where it is (the stream itself may have paused: dropping it would
    // lose the rest); the old connections close once it's done.
    old.finishTasksAndInvalidate()
    ActivityLog.shared.add(String(format: "Kestrel player: nothing came in for %.0f s; new connection (%d segments asked for again)", quietFor, waiting.count))
    pump()
  }

  // MARK: Frames, in segment order

  /// Hands over the frames that can go now: all of the first segment's so far, then the next
  /// segment's once the first is complete (a later segment's frames wait their turn).
  private func pump() {
    if !clockRunning { skipToLiveSegment() }
    while let first = loads.first {
      if !first.frames.isEmpty {
        let frames = first.frames
        first.frames = []
        for frame in frames { enqueue(frame, from: first) }
      }
      if !first.finished, loads.count > 1, readyToHandOver(first, to: loads[1]) {
        // Its frames are all in (it's gone quiet and the next one's frames have started): go on
        // without waiting for its download to close, which can come a while later.
        if let quiet = first.lastArrival {
          handoffWaits.append((Date(), Date().timeIntervalSince(quiet)))
          if handoffWaits.count > 200 { handoffWaits.removeFirst(100) }
        }
        first.frames += first.demuxer?.flush() ?? []
        let frames = first.frames
        first.frames = []
        for frame in frames { enqueue(frame, from: first) }
        first.handedOver = true
        first.finished = true
        first.task?.cancel()
      }
      guard first.finished else { break }
      loads.removeFirst()
      segmentsLoaded += 1
      if first.failed {
        // A gap: the decoder starts again from the next keyframe.
        waitingForKeyframe = true
      }
    }
    startIfReady()
  }

  /// Before the start: once the segment being made already holds the margin's worth of video (from
  /// its keyframe), start from it and drop the complete segment before it. That one was only
  /// there for a start just as a new segment began, and waiting for all of it (two seconds of
  /// video, often from a server in Europe through the ad-free route) held up every start.
  private func skipToLiveSegment() {
    guard let liveIndex = loads.firstIndex(where: { $0.planned.live }), liveIndex > 0 else { return }
    var firstKey: Int64?
    var newest: Int64?
    for frame in loads[liveIndex].frames {
      guard case .video(let video) = frame else { continue }
      if firstKey == nil, video.isKeyframe { firstKey = video.pts }
      if firstKey != nil { newest = max(newest ?? video.pts, video.pts) }
    }
    guard let firstKey, let newest else { return }
    let margin = max(catchUp.targetBuffer, 0.5)
    guard Double(newest - firstKey) / Double(Self.clock) >= margin + 0.1 else { return }
    for load in loads[..<liveIndex] { load.task?.cancel() }
    loads.removeFirst(liveIndex)
    heldVideo = []
    heldAudio = []
    firstVideoTime = nil
    lastVideoTime = nil
    newestAudio = nil
    ActivityLog.shared.add("Kestrel player: starting from the segment being made (it already had enough video)")
  }

  /// The front segment has gone quiet for a moment and the next one's frames are coming in (so
  /// nothing more of this one is on its way).
  private func readyToHandOver(_ first: SegmentLoad, to next: SegmentLoad) -> Bool {
    guard first.demuxer != nil, first.received > 0, let quiet = first.lastArrival, !next.frames.isEmpty else { return false }
    let quietFor = Date().timeIntervalSince(quiet)
    guard quietFor > 0.25 else { return false }
    // Its sound must be all in too: it ends where the next segment's begins. The last packet of
    // sound can come a moment after the last picture, and going on without it was a skip in the
    // sound at the seam. (A second of nothing: on without it.)
    if !next.planned.discontinuity, let end = first.audioEnd, let nextStart = next.firstAudio,
      nextStart - end > 900, nextStart - end < 90_000, quietFor < 1
    {
      return false
    }
    return true
  }

  private func enqueue(_ frame: DemuxedFrame, from load: SegmentLoad) {
    if !load.timed {
      load.timed = true
      let isVideo: Bool
      if case .video = frame { isVideo = true } else { isVideo = false }
      timeline.beginSegment(firstPTS: frame.pts, isVideo: isVideo, discontinuity: load.planned.discontinuity)
      if load.planned.discontinuity { waitingForKeyframe = true }
    }
    switch frame {
    case .video(let video):
      let mapped = timeline.map(video.pts, isVideo: true)
      // The decode time moves with it (streams with B-frames decode in another order than they
      // show: each frame has both times, and the decoder needs the decode one).
      let rawDecode = video.dts + (mapped - video.pts)
      // Both on an even rhythm: millisecond-rounded times made frames judder on 120 Hz screens.
      grid.learn(decodeTime: rawDecode)
      let time = grid.snap(mapped)
      let decodeTime = min(grid.snap(rawDecode), time)
      if !load.dated, let date = load.planned.programDate {
        load.dated = true
        anchor = (time, date)
      }
      if clockRunning {
        enqueueVideo(video, pts: time, dts: decodeTime, hidden: false)
      } else if video.isKeyframe || !heldVideo.isEmpty {
        heldVideo.append((video, time, decodeTime))
        if firstVideoTime == nil { firstVideoTime = time }
        if lastVideoTime.map({ time > $0 }) ?? true { lastVideoTime = time }
        if load.planned.live, let newest = lastVideoTime {
          // How fast the segment being made comes in (see `backlogIn`).
          let at = Date()
          liveArrivals.append((at, newest))
          liveArrivals.removeAll { at.timeIntervalSince($0.at) > 1.5 }
          if liveSince == nil { liveSince = at }
        }
      }
    case .audio(let audio):
      let time = timeline.map(audio.pts, isVideo: false)
      let length = Int64(1024 * 90_000 / max(audio.config.sampleRate, 8000))
      if newestAudio.map({ time + length > $0 }) ?? true { newestAudio = time + length }
      if clockRunning {
        enqueueAudio(audio, time: time)
      } else {
        heldAudio.append((audio, time))
      }
    }
  }

  private func enqueueVideo(_ frame: VideoFrame, pts time: Int64, dts: Int64, hidden: Bool) {
    // Every frame that arrived counts toward what's in hand, decodable or not: a frame skipped
    // while the picture waits for a keyframe (after the background, a decoder hiccup) isn't the
    // stream running dry. Counted as that, it stalled playback and taught the margin a "hiccup"
    // (2.3 s seen after coming back from Picture in Picture).
    defer {
      if firstVideoTime == nil { firstVideoTime = time }
      if lastVideoTime.map({ time > $0 }) ?? true { lastVideoTime = time }
    }
    if waitingForKeyframe, !frame.isKeyframe { return }
    let units = frame.codec == .av1 ? [] : AnnexB.units(frame.data)
    let payload: Data
    switch frame.codec {
    case .av1:
      if let config = frame.av1 {
        let key = config.record + Data([UInt8(config.width >> 8), UInt8(config.width & 0xFF), UInt8(config.height >> 8), UInt8(config.height & 0xFF)])
        if key != parameterSets || videoFormat == nil {
          videoFormat = Self.av1Format(config)
          parameterSets = key
        }
      }
      payload = frame.data
    case .h264:
      if frame.isKeyframe, let sets = H264.parameterSets(units) {
        let key = sets.sps + sets.pps
        if key != parameterSets || videoFormat == nil {
          videoFormat = Self.h264Format(sps: sets.sps, pps: sets.pps)
          parameterSets = key
        }
      }
      payload = H264.sample(units)
    case .hevc:
      if frame.isKeyframe, let sets = HEVC.parameterSets(units) {
        let key = sets.vps + sets.sps + sets.pps
        if key != parameterSets || videoFormat == nil {
          videoFormat = Self.hevcFormat(vps: sets.vps, sps: sets.sps, pps: sets.pps)
          parameterSets = key
        }
      }
      payload = HEVC.sample(units)
    }
    guard let format = videoFormat else { return }
    if let last = lastDecodeTime, dts > last, dts - last < 9000 { frameLength = dts - last }
    lastDecodeTime = dts
    let entry = GroupFrame(payload: payload, format: format, pts: time, dts: dts, duration: frameLength, keyframe: frame.isKeyframe)
    if decodeInLayer {
      // The picture on screen (left alone in the background: it can't decode there, and is
      // brought back up to the frame showing when the app returns).
      if (inBackground && !screenInWindow)
        || (UIApplication.shared.applicationState != .active && displayLayer.requiresFlushToResumeDecoding && !screenInWindow)
      {
        // (Past the keyframe check above: the copy goes on from here.) Not while the app is still
        // coming back and can't decode yet either: catching up then reset the screen with every
        // frame; it catches up once the app is active (see `enteringForeground`).
        waitingForKeyframe = false
        screenBehind = true
      } else if !feedScreen(entry, hidden: hidden) {
        return
      }
      if let mirrorLayer, mirrorFed { feedMirror(mirrorLayer, entry, hidden: hidden) }
    } else {
      guard let session = decoderSession(for: format), let sample = entry.sample(hidden: false) else {
        waitingForKeyframe = true
        if decodingHereByRequest {
          // (VideoToolbox can't take this stream here, e.g. AV1: back to the layer.)
          decodingHereByRequest = false
          decodeInLayer = true
          ActivityLog.shared.add("Kestrel player: can't decode this stream here; left to the layer")
        }
        return
      }
      waitingForKeyframe = false
      if hidden { showFrom = max(showFrom, time + 1) }
      decode(sample, in: session)
    }
    // Everything since the last keyframe, to bring the screen back up to date in one go.
    if frame.isKeyframe { group = [] }
    if group.count < 600 { group.append(entry) }
    videoFramesQueued += 1
    if hidden { videoFramesHidden += 1 }
  }

  /// A frame as handed to the decoder, kept to hand it again.
  struct GroupFrame {
    let payload: Data
    let format: CMVideoFormatDescription
    let pts: Int64
    let dts: Int64
    let duration: Int64
    let keyframe: Bool

    @MainActor func sample(hidden: Bool) -> CMSampleBuffer? {
      KestrelEngine.videoSample(payload, format: format, pts: pts, dts: dts, duration: duration, keyframe: keyframe, hidden: hidden)
    }
  }

  /// The screen's layer: false when the frame can't go (it's waiting for a keyframe).
  private func feedScreen(_ entry: GroupFrame, hidden: Bool) -> Bool {
    let layer = displayLayer
    // Interrupted (AVFoundationErrorDomain -11847: the app went to the background mid-decode)
    // isn't a frame it couldn't decode: brought back up to date like any return from the
    // background, and not counted toward giving up on the layer.
    if layer.status == .failed, (layer.error as NSError?)?.code == AVError.operationInterrupted.rawValue {
      screenBehind = true
    }
    if layer.status == .failed, !screenBehind {
      // A frame it couldn't decode.
      decoderFailures += 1
      let error = layer.error as NSError?
      lastDecoderError = error.map { "layer \($0.domain) \($0.code)" } ?? "layer failed"
      layerFailures = layerFailures.filter { Date().timeIntervalSince($0) < 30 } + [Date()]
      if layerFailures.count >= 3 {
        // It keeps failing on this stream: decode here instead.
        decodeInLayer = false
        ActivityLog.shared.add("Kestrel player: the display layer kept failing (\(lastDecoderError ?? "?")); decoding with VideoToolbox")
      }
      layer.flush()
      screenBehind = false
      waitingForKeyframe = true
      guard entry.keyframe else { return false }
    } else if layer.requiresFlushToResumeDecoding || screenBehind {
      // Back from the background: decode what came since the last keyframe out of sight, so the
      // picture is the one playing now straight away (not the one from before, or nothing until
      // the next keyframe up to two seconds later).
      if !entry.keyframe {
        guard catchUpScreen() else {
          waitingForKeyframe = true
          return false
        }
      } else {
        layer.flush()
        screenBehind = false
      }
    }
    if waitingForKeyframe {
      guard entry.keyframe else { return false }
      waitingForKeyframe = false
    }
    guard let sample = entry.sample(hidden: hidden) else { return false }
    layer.enqueue(sample)
    return true
  }

  /// Brings the screen's layer up to the frame playing now from the frames since the last
  /// keyframe (decoded out of sight up to now): false if there's no keyframe to start from.
  @discardableResult
  private func catchUpScreen() -> Bool {
    screenBehind = false
    guard group.first?.keyframe == true else {
      displayLayer.flush()
      return false
    }
    if onScreenLayers != nil {
      // A fresh layer on top: empty, it's see-through, so whatever picture is up stays until the
      // new one has the frame playing now. A layer on screen is never flushed (that went black
      // for a moment): the one showing a picture stays underneath, an empty one is let go.
      let current = displayLayer
      var currentShows = current.status != .failed
      if #available(iOS 17.4, tvOS 17.4, *) { currentShows = currentShows && current.sampleBufferRenderer.displayedPixelBuffer() != nil }
      if retiringLayer == nil || currentShows {
        if let previous = retiringLayer { previous.flushAndRemoveImage() }
        retiringLayer = current
      } else {
        current.flushAndRemoveImage()
      }
      retiringSince = Date()
      let fresh = AVSampleBufferDisplayLayer()
      fresh.videoGravity = current.videoGravity
      fresh.controlTimebase = videoClock
      fresh.isHidden = screenHiddenForPictureInPicture
      displayLayer = fresh
      if coverLayer == nil {
        coverLayer = makeCover(gravity: current.videoGravity)
        coverLayer?.isHidden = screenHiddenForPictureInPicture
      }
      onScreenLayers?()
      screenNote("caught up on a fresh layer")
    } else {
      displayLayer.flush()
    }
    caughtUpAt = Date()
    drawingSince = nil
    let layer = displayLayer
    let showing = now
    for earlier in group {
      if let sample = earlier.sample(hidden: earlier.pts < showing - frameLength) { layer.enqueue(sample) }
    }
    return true
  }

  /// A still of the frame the Picture in Picture copy is showing (it played on in the window).
  private func makeCover(gravity: AVLayerVideoGravity) -> CALayer? {
    guard #available(iOS 17.4, tvOS 17.4, *), let mirrorLayer, let buffer = mirrorLayer.sampleBufferRenderer.displayedPixelBuffer()
    else { return nil }
    var image: CGImage?
    VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
    guard let image else { return nil }
    let cover = CALayer()
    cover.contents = image
    cover.contentsGravity = gravity == .resizeAspectFill ? .resizeAspectFill : .resizeAspect
    cover.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    return cover
  }

  /// The old layer goes once the new one is drawing.
  private func retireOldLayer(force: Bool = false) {
    guard let old = retiringLayer else { return }
    // "Rendering" isn't enough: the new layer said so while the app was still coming back and not
    // yet allowed to decode, and taking the old picture away then showed black for a few frames.
    // It goes once the new layer has a frame on screen, and has kept drawing for a moment.
    var drawing = displayLayer.status == .rendering && !displayLayer.requiresFlushToResumeDecoding && !inBackground
    if drawing, #available(iOS 17.4, tvOS 17.4, *) { drawing = displayLayer.sampleBufferRenderer.displayedPixelBuffer() != nil }
    if !drawing { drawingSince = nil } else if drawingSince == nil { drawingSince = Date() }
    let settled = drawingSince.map { Date().timeIntervalSince($0) > 0.4 } ?? false
      && Date().timeIntervalSince(caughtUpAt) > 0.6 && Date().timeIntervalSince(retiringSince) > 0.6
    guard force || (settled && !windowUp) else { return }
    if !force { screenNote("old picture taken away") }
    drawingSince = nil
    retiringLayer = nil
    coverLayer = nil
    old.flushAndRemoveImage()
    onScreenLayers?()
  }

  /// The app is back and active (decoding allowed again): the screen catches up at once, onto a
  /// fresh layer, the picture that was up staying underneath until it draws.
  /// A line in the Activity log about the screen's layers around Picture in Picture, timed to the
  /// millisecond (to find the moment the picture goes black on the way back).
  func screenNote(_ text: String) {
    // (Each of these is the picture moving: into or out of Picture in Picture, the app leaving or
    // coming back. See `lastScreenChange`.)
    lastScreenChange = Date()
    let ms = Int(Date().timeIntervalSince1970 * 1000) % 100_000
    var showing = "?"
    if #available(iOS 17.4, tvOS 17.4, *) { showing = displayLayer.sampleBufferRenderer.displayedPixelBuffer() != nil ? "frame" : "empty" }
    ActivityLog.shared.add(
      "PiP screen \(ms): \(text) [screen \(showing)\(displayLayer.isHidden ? " hidden" : ""), old \(retiringLayer == nil ? "none" : "kept"), cover \(coverLayer == nil ? "none" : "up"), app \(UIApplication.shared.applicationState.rawValue)]")
  }

  private func enteringForeground() {
    screenNote("app back")
    inBackground = false
    // Decoding comes back with the app being active: catching up before that only reset the screen.
    guard UIApplication.shared.applicationState == .active else { return }
    guard running, decodeInLayer, screenBehind || displayLayer.requiresFlushToResumeDecoding else { return }
    if !catchUpScreen() { waitingForKeyframe = true }
  }

  /// The Picture in Picture copy: when it can't decode (the app's in the background without
  /// Picture in Picture), it starts again from the next keyframe.
  private func feedMirror(_ layer: AVSampleBufferDisplayLayer, _ entry: GroupFrame, hidden: Bool) {
    if layer.status == .failed || layer.requiresFlushToResumeDecoding {
      layer.flush()
      mirrorWaiting = true
    }
    if mirrorWaiting {
      guard entry.keyframe else { return }
      mirrorWaiting = false
    }
    if let sample = entry.sample(hidden: hidden) { layer.enqueue(sample) }
  }

  /// A second picture of the same video for Picture in Picture, kept behind the one on screen:
  /// the system puts its "playing in Picture in Picture" placeholder on the layer it takes, and on
  /// the screen's own layer that showed for a moment each time the window came back.
  func makeMirror() -> AVSampleBufferDisplayLayer {
    if let mirrorLayer { return mirrorLayer }
    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = displayLayer.videoGravity
    // A clock of its own that follows the picture's: the system works the Picture in Picture
    // layer's clock while it takes the layer into the window and hands it back, and on the shared
    // clock that moved the screen's picture too (a few black frames after the window landed).
    var follower: CMTimebase?
    CMTimebaseCreateWithSourceTimebase(allocator: kCFAllocatorDefault, sourceTimebase: videoClock, timebaseOut: &follower)
    if let follower {
      CMTimebaseSetTime(follower, time: CMTimebaseGetTime(videoClock))
      CMTimebaseSetRate(follower, rate: 1)
      layer.controlTimebase = follower
    } else {
      layer.controlTimebase = videoClock
    }
    mirrorLayer = layer
    mirrorWaiting = true
    return layer
  }

  // MARK: Decoding (VideoToolbox)

  /// The decompression session for this format (a new one when the format changes).
  private func decoderSession(for format: CMVideoFormatDescription) -> VTDecompressionSession? {
    if let decoder, let decoderFormat, CMFormatDescriptionEqual(decoderFormat, otherFormatDescription: format) { return decoder }
    closeDecoder()
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
    guard status == noErr, let session else {
      lastDecodeStatus = status
      decodeErrors += 1
      lastDecoderError = "couldn't start the decoder (\(status))"
      ActivityLog.shared.add("Kestrel player: couldn't start the video decoder (\(status))")
      return nil
    }
    decoder = session
    decoderFormat = format
    return session
  }

  private func closeDecoder() {
    if let decoder {
      VTDecompressionSessionWaitForAsynchronousFrames(decoder)
      VTDecompressionSessionInvalidate(decoder)
    }
    decoder = nil
    decoderFormat = nil
    showFrom = .min
  }

  private func decode(_ sample: CMSampleBuffer, in session: VTDecompressionSession) {
    // Temporal processing: pictures come out in the order they're shown, not decoded.
    let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._EnableTemporalProcessing]
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: nil) {
      [weak self] status, _, image, pts, duration in
      let picture = image.map { PictureBox($0) }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.decoded(status, picture?.image, pts: pts, duration: duration) }
      }
    }
    if status != noErr { decodeFailed(status) }
  }

  private func decoded(_ status: OSStatus, _ image: CVImageBuffer?, pts: CMTime, duration: CMTime) {
    guard running else { return }
    guard status == noErr, let image else {
      if status != noErr { decodeFailed(status) }
      return
    }
    framesDecoded += 1
    let time = Int64(pts.convertScale(Self.clock, method: .default).value)
    guard time >= showFrom else { return }
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
    guard let format else { return }
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
    guard let sample else { return }
    onPicture?(image, pts)
    // (A picture layer that stopped in the background just needs flushing.)
    if !inBackground {
      if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding { displayLayer.flush() }
      displayLayer.enqueue(sample)
    }
    if let mirrorLayer, mirrorFed {
      if mirrorLayer.status == .failed || mirrorLayer.requiresFlushToResumeDecoding { mirrorLayer.flush() }
      mirrorLayer.enqueue(sample)
    }
    framesShown += 1
  }

  private func decodeFailed(_ status: OSStatus) {
    decodeErrors += 1
    if status != lastDecodeStatus || decodeErrors % 30 == 1 {
      ActivityLog.shared.add("Kestrel player: a video frame didn't decode (\(status))")
    }
    lastDecodeStatus = status
    lastDecoderError = "decode \(status)"
    if status == kVTInvalidSessionErr {
      // The session is gone (the app was in the background): a new one from the next keyframe.
      decoder = nil
      decoderFormat = nil
      waitingForKeyframe = true
    }
  }

  private func enqueueAudio(_ frame: AudioFrame, time: Int64, refill: Bool = false) {
    if !refill {
      // What the stats show about the sound: arriving after its time, or not following on. Sound
      // past its time is left out (it would only push the sound behind the picture).
      if clockRunning, time + 1920 < now {
        lateAudio += 1
        lastAudioTime = time
        return
      }
      if let last = lastAudioTime {
        let step = Int64(1024 * 90_000 / max(frame.config.sampleRate, 8000))
        let off = time - last - step
        // Sound stamped at or before what's already queued (two encodes' sound overlapping at a
        // seam): the same moment twice, heard as a stutter and the picture stepping back. Left out
        // until it follows on.
        if off < -180, time <= last {
          if !inAudioOverlap {
            inAudioOverlap = true
            audioOverlaps += 1
            noteAudioJump(ms: Double(off) / 90)
          }
          return
        }
        inAudioOverlap = false
        if off > 180 {
          audioGaps += 1
          largestAudioGap = max(largestAudioGap, Double(off) / 90)
          noteAudioJump(ms: Double(off) / 90)
        }
      }
      lastAudioTime = time
      audioHistory.append((frame, time))
      if audioHistory.count > 250 { audioHistory.removeFirst(audioHistory.count - 250) }
    }
    audio.enqueue(frame, pts: time)
    audioFramesQueued += 1
  }

  /// A jump in the sound's times, in the activity log (a few a minute at most) with what was
  /// going on, so a pattern shows: the sound itself plays straight on.
  private func noteAudioJump(ms: Double) {
    guard Date().timeIntervalSince(lastAudioJumpNote) > 20 else { return }
    lastAudioJumpNote = Date()
    let what = ms > 0 ? String(format: "skipped %.0f ms of sound the stream didn't have", ms)
      : String(format: "left out %.0f ms of sound sent twice", -ms)
    ActivityLog.shared.add("Kestrel player: \(what) (played straight on)")
  }

  /// The system stopped the sound and it was started again: what's kept from now on goes back in.
  private func refillAudio() {
    audioAutoFlushes += 1
    let from = now
    for (frame, time) in audioHistory where time >= from { enqueueAudio(frame, time: time, refill: true) }
  }

  /// The speed for the picture's clock and the sound together (0 holds both where they are).
  private func setSpeed(_ rate: Float) {
    speed = rate
    CMTimebaseSetRate(videoClock, rate: Float64(rate))
    if rate == 0 {
      audio.pause()
    } else {
      audio.setSpeed(rate)
      if clockRunning, !audio.isPlaying { audio.play() }
    }
  }

  /// Keeps the picture on the sound: the sound is what's heard, and its device's clock runs a
  /// little apart from the host clock the picture runs on. Small differences are taken up by
  /// running the picture's clock a touch faster or slower (unseen); a big one (a gap in the
  /// sound, a restart of it) moves it straight there.
  private func syncClock() {
    guard clockRunning, speed > 0, audio.isPlaying, let heard = audio.position else { return }
    // Sound that stops moving while it should be playing is stuck (it ran dry, or the system held it).
    if heard != lastHeard {
      lastHeard = heard
      lastHeardMoved = Date()
    }
    let stuck = Date().timeIntervalSince(lastHeardMoved) > 0.6
    let drift = Double(heard - now) / Double(Self.clock)
    if !stuck, abs(drift) <= 0.08 {
      let trim = max(-0.02, min(0.02, drift * 0.5))
      CMTimebaseSetRate(videoClock, rate: Float64(speed) * (1 + trim))
      return
    }
    if !stuck, abs(drift) <= 1 {
      // A jump in the sound's times: the picture moves to it (a gap in the sound is worse).
      CMTimebaseSetTime(videoClock, time: CMTime(value: heard, timescale: Self.clock))
      CMTimebaseSetRate(videoClock, rate: Float64(speed))
      return
    }
    // Stuck, or far off: the picture leads and the sound is put back on it.
    CMTimebaseSetRate(videoClock, rate: Float64(speed))
    guard Date().timeIntervalSince(lastAudioResync) > 2 else { return }
    lastHeardMoved = Date()
    lastAudioResync = Date()
    audioResyncs += 1
    ActivityLog.shared.add(String(format: "Kestrel player: the sound was %.2f s off the picture; put back on it", drift))
    audio.flush()
    let from = now
    for (frame, time) in audioHistory where time >= from { enqueueAudio(frame, time: time, refill: true) }
    audio.play()
  }

  /// Starts the clock once there's video: just behind the newest frame in hand (the stream's
  /// margin), so it opens close to live instead of at the start of the first segment.
  /// Right after the start, video still comes in fast for a moment (Twitch first sends all of the
  /// segment being made so far), so there's more in hand than the margin. Catching that up at
  /// 1.1x took a few seconds on every start; instead, once, about a second in, the playhead moves
  /// straight to the margin (a fraction of a second, as the picture has only just come up).
  private func skipStartSurplus(ahead: Double) -> Bool {
    guard !startSkipDone, let since = playingSince else { return false }
    let elapsed = Date().timeIntervalSince(since)
    guard elapsed >= 0.7 else { return false }
    startSkipDone = true
    // (Whole segments: a segment's worth on top, to last until the next one is listed.)
    let surplus = ahead - catchUp.targetBuffer - (deliversWhole ? Self.segmentLength : 0)
    guard surplus > 0.12, surplus < 4 else { return false }
    jump(by: surplus)
    ActivityLog.shared.add(String(format: "Kestrel player: skipped %.2f s ahead after the start (no catching up)", surplus))
    return true
  }

  /// Moves the playhead straight ahead (picture and sound together), instead of catching up by
  /// playing faster.
  private func jump(by seconds: Double) {
    let to = now + Int64(seconds * Double(Self.clock))
    CMTimebaseSetTime(videoClock, time: CMTime(value: to, timescale: Self.clock))
    audio.flush()
    for (frame, time) in audioHistory where time >= to { enqueueAudio(frame, time: time, refill: true) }
    if speed > 0 { audio.play() }
    catchUp.hold(for: 2)
  }

  /// During an ad break and for a little while after it, falling behind isn't caught up by playing
  /// faster: the playhead jumps straight back to the margin. The ad-free copy played during a
  /// blocked ad comes from a server far away and falls further behind as it goes (it reached six
  /// seconds), and Twitch's own stream after it is ahead again; the break's video is a cut anyway.
  /// At most one jump every few seconds.
  private var jumpAfterAdUntil: Date?
  private var lastAdJump = Date.distantPast

  private func jumpAfterAd(ahead: Double) {
    let now = Date()
    let after = jumpAfterAdUntil.map { now < $0 } ?? false
    guard inAdBreak || after else {
      jumpAfterAdUntil = nil
      return
    }
    guard now.timeIntervalSince(lastAdJump) >= 3 else { return }
    let surplus = ahead - catchUp.targetBuffer - (deliversWhole ? Self.segmentLength : 0)
    // Under a second is caught up by playing a little faster instead (a few seconds, not
    // noticed): a jump that small was a visible hitch in the picture and the sound for very little.
    guard surplus > 1.0, surplus < 20 else { return }
    lastAdJump = now
    jump(by: surplus)
    ActivityLog.shared.add(
      String(format: "Kestrel player: %@, skipped %.2f s ahead to live (no catching up)", inAdBreak ? "ad break" : "back from the ad", surplus))
  }

  /// The segment being made has sent what it already had: its video now comes in at about the
  /// pace it's made. Asked for mid-way, the server first sends all of it made so far in one
  /// rush; starting during that rush put the start behind live by however much was still to
  /// come, and the player then had to catch up on every start.
  private var backlogIn: Bool {
    guard let since = liveSince else { return false }
    let now = Date()
    if now.timeIntervalSince(since) > 3 { return true }
    let window = liveArrivals.filter { now.timeIntervalSince($0.at) <= 1.0 }
    guard let first = window.first, let last = window.last, now.timeIntervalSince(since) >= 0.6 else { return false }
    let wall = max(now.timeIntervalSince(first.at), 0.6)
    let media = Double(last.newest - first.newest) / Double(Self.clock)
    return media / wall < 1.4
  }

  private func startIfReady() {
    guard !clockRunning, !paused, let first = heldVideo.first?.pts, let last = newestPlayable else { return }
    // Whole segments: a segment's worth more, to last until the next one is listed (started at
    // the margin alone, it ran dry before the next one came, every start).
    let margin = Int64((max(catchUp.targetBuffer, 0.5) + (deliversWhole ? Self.segmentLength : 0)) * Double(Self.clock))
    // Only once what's being unpacked is the segment still being made (everything before it is
    // in): starting earlier put the start seconds back, with all of that to catch up. (A stream
    // in whole segments has none being made: it starts once the newest is in.)
    let atLive = loads.first?.planned.live ?? true
    if deliversWhole, loads.contains(where: { !$0.downloaded }) { return }
    let waited = Date().timeIntervalSince(startedLoading)
    guard atLive || deliversWhole || waited > 6, last - first >= Int64(0.3 * Double(Self.clock)) else { return }
    let start = max(first, last - margin)
    // From the last keyframe at or before the start; frames before the start are decoded (later
    // ones need them) but not shown, so it opens on a clean picture at the start.
    let keyframe = heldVideo.lastIndex { $0.frame.isKeyframe && $0.pts <= start } ?? 0
    for held in heldVideo[keyframe...] { enqueueVideo(held.frame, pts: held.pts, dts: held.dts, hidden: held.pts < start) }
    for held in heldAudio where held.pts >= start { enqueueAudio(held.frame, time: held.pts) }
    heldVideo = []
    heldAudio = []
    startedBehind = Double(last - start) / Double(Self.clock)
    ActivityLog.shared.add(
      String(format: "Kestrel player: started %.2f s behind the newest frame, %.1f s after asking (%@, %d frames decoded ahead of it)", startedBehind ?? 0, Date().timeIntervalSince(startedLoading), container, videoFramesHidden))
    CMTimebaseSetTime(videoClock, time: CMTime(value: start, timescale: Self.clock))
    clockRunning = true
    playingSince = Date()
    setSpeed(1)
    catchUp.restart()
    // Settling: running, but not shown or heard yet (the app keeps its preview up) until the rest
    // of the opening rush is in and any surplus is skipped (see `skipStartSurplus`): then it
    // fades in already at the margin, with nothing to skip or catch up in view.
    settling = true
    audio.setMuted(true)
  }

  // MARK: Ticking: margin, stalls

  /// The newest video in hand over the last while (how fast it's coming in).
  private var paceHistory: [(at: Date, newest: Int64)] = []
  /// Since when it's come in slower than it plays.
  private var slowSince: Date?

  /// Video coming in slower than it plays for several seconds while what's in hand runs down: the
  /// connection can't carry this quality (a weak cellular signal, underground): one lower now,
  /// before it runs dry. (Only stalls stepped it down before, two of them: on a train that was
  /// stall after stall first.)
  private func checkPace(ahead: Double) {
    guard autoQuality, let newest = newestPlayable, speed > 0 else { return }
    let at = Date()
    paceHistory.append((at, newest))
    paceHistory.removeAll { at.timeIntervalSince($0.at) > 8 }
    guard let first = paceHistory.first, at.timeIntervalSince(first.at) >= 6 else { return }
    let pace = Double(newest - first.newest) / Double(Self.clock) / at.timeIntervalSince(first.at)
    // (Whole segments come two seconds at a time: judged over the whole window, that evens out.)
    if pace < 0.8, ahead < catchUp.targetBuffer + (deliversWhole ? Self.segmentLength : 0.5) {
      if slowSince == nil { slowSince = at }
    } else {
      slowSince = nil
    }
    guard let since = slowSince, at.timeIntervalSince(since) >= 3, fit.tooSlow(), fit.step < renditions.count else { return }
    slowSince = nil
    paceHistory = []
    applyFit()
    ActivityLog.shared.add(String(format: "Kestrel player: video coming in at %.0f%% of real time; one quality lower", pace * 100))
  }

  private func tick() {
    guard running else { return }
    retireOldLayer()
    // A segment whose frames are all in can hand over to the next before its download closes.
    pump()
    reconnectIfStuck()
    refetchStuckFront()
    guard clockRunning else { return }
    let ahead = bufferAhead ?? 0
    if stalledSince == nil, ahead < 0.03 {
      // Ran dry: hold the clock until there's the margin again.
      stalledSince = Date()
      stalls += 1
      // Why, in the activity log (the stats only counted them).
      var why: [String] = []
      if inAdBreak { why.append(latestHasPrefetch ? "during an ad break" : "during an ad break, Twitch sending whole segments") }
      else if wholeSegments { why.append("the stream sends whole segments") }
      else if prefetchSeen && !latestHasPrefetch { why.append("Twitch sending whole segments for now") }
      if let last = lastArrival { why.append(String(format: "nothing in for %.1f s", Date().timeIntervalSince(last))) }
      why.append(String(format: "margin %.1f s", catchUp.targetBuffer))
      setSpeed(0)
      // A low-latency stream that's just now sending whole segments (Twitch leaves out the
      // segment being made around ad breaks, sometimes for a while after one ends): it ran dry
      // waiting for a whole segment, which no margin the connection needs would cover. Learned,
      // one such stall put 0.4 s on the latency for the next ten minutes.
      let twitchsDoing = inAdBreak || (prefetchSeen && !latestHasPrefetch)
      // Just after Picture in Picture opened or closed, or the app went away or came back: that
      // move held things up for a moment. Learned, one put 0.7 s on the margin (3.9 s behind).
      let screenMoved = Date().timeIntervalSince(lastScreenChange) < 5
      if screenMoved { why.append("just after Picture in Picture or switching apps") }
      catchUp.stalled(learn: !twitchsDoing && !screenMoved)
      if twitchsDoing || screenMoved { why.append("not learned") }
      ActivityLog.shared.add("Kestrel player: ran out of video (\(why.joined(separator: ", ")))")
      state = .stalled
      // Twice in a few minutes while the video kept arriving: the connection can't carry this
      // quality; one lower from the next segment.
      if autoQuality, !twitchsDoing, !screenMoved, fit.stalled(), fit.step < renditions.count {
        applyFit()
        ActivityLog.shared.add("Kestrel player: stalling at this quality; one lower for now (trying again in a few minutes)")
      }
      return
    }
    // (Never past the cap: at it, there's nothing better to try.)
    if autoQuality, fit.step > (capPosition ?? 0), fit.tick(), fit.step < renditions.count {
      applyFit()
      ActivityLog.shared.add("Kestrel player: trying the better quality again")
    }
    if let since = stalledSince {
      // (Whole segments: enough to last until the next one is listed, or it runs dry again.)
      // In an ad break (Twitch leaving out the segment being made for a while): on as soon as one
      // segment's in. Waiting for the full whole-segment margin there held the picture for two
      // segments, a few seconds, for something that's over in half a minute.
      let resumeAt: Double
      if wholeSegments {
        resumeAt = min(3.5, catchUp.targetBuffer + Self.segmentLength)
      } else if deliversWhole {
        resumeAt = max(1.2, min(2.0, catchUp.targetBuffer + 0.8))
      } else {
        resumeAt = max(0.4, min(catchUp.targetBuffer, 1.5))
      }
      if ahead >= resumeAt {
        ActivityLog.shared.add(String(format: "Kestrel player: playing again after %.1f s", Date().timeIntervalSince(since)))
        stalledSince = nil
        setSpeed(1)
        state = .playing
      } else if Date().timeIntervalSince(since) > 12 {
        // Nothing for a long while: start over at live.
        restart()
      }
      return
    }
    learnDelivery(ahead: ahead)
    noteIfStuckBehind(ahead: ahead)
    checkPace(ahead: ahead)
    let skipped = skipStartSurplus(ahead: ahead)
    if !skipped, startSkipDone { jumpAfterAd(ahead: ahead) }
    if settling, startSkipDone {
      settling = false
      audio.setMuted(muted)
      state = .playing
    }
    if skipped { return }
    // Far behind (a long dropout, the background): start over at live. Judged by what's in hand
    // (judged by the stream's timestamps, a channel with them half a minute off started over
    // every quarter second and never got going).
    if ahead > 15 {
      restart()
      return
    }
    // Steered by what's in hand alone, measured here, never by the stream's own clock (which some
    // channels have off by seconds either way): how far from live it plays is what's in hand plus
    // the video's delay on the way, and only the first part is the player's to change. The
    // latency shown still comes from the clock (corrected when it's clearly off).
    let steering = deliversWhole ? trough(ahead) : ahead
    if !deliversWhole { aheadHistory = [] }
    let rate = catchUp.update(
      buffer: steering, latency: steering + Self.deliveryDelay, playing: true, position: Double(now) / Double(Self.clock),
      maxRate: Self.maxRate)
    if speed != rate { setSpeed(rate) }
    syncClock()
  }

  // MARK: Sample buffers

  private static func block(_ data: Data) -> CMBlockBuffer? {
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block) == kCMBlockBufferNoErr, let block
    else { return nil }
    let status = data.withUnsafeBytes { bytes in
      CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
    }
    return status == kCMBlockBufferNoErr ? block : nil
  }

  static func h264Format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
    var format: CMVideoFormatDescription?
    let status = sps.withUnsafeBytes { spsBytes in
      pps.withUnsafeBytes { ppsBytes -> OSStatus in
        let pointers = [
          spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
        ]
        let sizes = [sps.count, pps.count]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
          nalUnitHeaderLength: 4, formatDescriptionOut: &format)
      }
    }
    return status == noErr ? format : nil
  }

  /// AV1: the av1C record goes in as a sample description atom, as in an MP4 file.
  static func av1Format(_ config: AV1Config) -> CMVideoFormatDescription? {
    var format: CMVideoFormatDescription?
    let extensions: [CFString: Any] = [
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": config.record] as CFDictionary
    ]
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: CMVideoCodecType(0x6176_3031), width: Int32(config.width),
      height: Int32(config.height), extensions: extensions as CFDictionary, formatDescriptionOut: &format)
    return status == noErr ? format : nil
  }

  static func hevcFormat(vps: Data, sps: Data, pps: Data) -> CMVideoFormatDescription? {
    var format: CMVideoFormatDescription?
    let status = vps.withUnsafeBytes { v in
      sps.withUnsafeBytes { s in
        pps.withUnsafeBytes { p -> OSStatus in
          let pointers = [
            v.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!,
            p.bindMemory(to: UInt8.self).baseAddress!,
          ]
          let sizes = [vps.count, sps.count, pps.count]
          return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: 3, parameterSetPointers: pointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        }
      }
    }
    return status == noErr ? format : nil
  }

  static func videoSample(
    _ data: Data, format: CMVideoFormatDescription, pts: Int64, dts: Int64, duration: Int64, keyframe: Bool, hidden: Bool
  ) -> CMSampleBuffer? {
    guard !data.isEmpty, let block = block(data) else { return nil }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: duration, timescale: clock), presentationTimeStamp: CMTime(value: pts, timescale: clock),
      decodeTimeStamp: CMTime(value: dts, timescale: clock))
    var size = data.count
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
      let sample
    else { return nil }
    if !keyframe || hidden, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
      if !keyframe { dictionary[kCMSampleAttachmentKey_NotSync as String] = true }
      if hidden { dictionary[kCMSampleAttachmentKey_DoNotDisplay as String] = true }
    }
    return sample
  }

  /// The AAC format, with the decoder's configuration in an MPEG-4 elementary stream descriptor
  /// (the "magic cookie" Core Audio expects for AAC).
  static func aacFormat(_ config: ADTS.Config) -> CMAudioFormatDescription? {
    var description = AudioStreamBasicDescription(
      mSampleRate: Float64(config.sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
      mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(config.channels), mBitsPerChannel: 0, mReserved: 0)
    let cookie = esds(config.audioSpecificConfig)
    var format: CMAudioFormatDescription?
    let status = cookie.withUnsafeBytes { bytes in
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: cookie.count,
        magicCookie: bytes.baseAddress, extensions: nil, formatDescriptionOut: &format)
    }
    return status == noErr ? format : nil
  }

  /// An MPEG-4 ES_Descriptor wrapping the AudioSpecificConfig.
  static func esds(_ audioSpecificConfig: Data) -> Data {
    let specific = Data([0x05, UInt8(audioSpecificConfig.count)]) + audioSpecificConfig
    var decoderConfig = Data([0x04, UInt8(13 + specific.count), 0x40, 0x15])
    decoderConfig += Data(repeating: 0, count: 11)  // buffer size, max and average bitrate
    decoderConfig += specific
    let sl = Data([0x06, 0x01, 0x02])
    return Data([0x03, UInt8(3 + decoderConfig.count + sl.count), 0x00, 0x00, 0x00]) + decoderConfig + sl
  }

  static func audioSample(_ data: Data, format: CMAudioFormatDescription, pts: Int64) -> CMSampleBuffer? {
    guard !data.isEmpty, let block = block(data) else { return nil }
    var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
    var sample: CMSampleBuffer?
    guard
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
        presentationTimeStamp: CMTime(value: pts, timescale: clock), packetDescriptions: &packet, sampleBufferOut: &sample)
        == noErr
    else { return nil }
    return sample
  }
}

/// Carries a decoded picture to the main queue.
private final class PictureBox: @unchecked Sendable {
  let image: CVImageBuffer
  init(_ image: CVImageBuffer) { self.image = image }
}

// MARK: - Downloads

extension KestrelEngine {
  /// Unpacks a segment's bytes with the demuxer its first bytes call for: MPEG-TS, or fragmented
  /// MP4 once its init segment is in (bytes before that wait).
  fileprivate func feed(_ load: SegmentLoad, _ data: Data) {
    if load.demuxer != nil {
      load.frames += load.demuxer!.feed(data)
      return
    }
    load.raw.append(data)
    guard !load.raw.isEmpty else { return }
    if SegmentDemuxer.isTransportStream(load.raw) {
      load.demuxer = .ts(TSDemuxer())
      container = "MPEG-TS"
    } else if let uri = load.planned.mapURI {
      guard let initSegment = inits[uri] else {
        fetchInit(uri)
        return
      }
      load.demuxer = .mp4(FMP4Demuxer(initSegment: initSegment))
      container = "fragmented MP4"
    } else {
      // Neither: nothing to do with it.
      load.task?.cancel()
      load.failed = true
      load.finished = true
      return
    }
    let pending = load.raw
    load.raw = Data()
    load.frames += load.demuxer!.feed(pending)
  }

  private func fetchInit(_ uri: String) {
    guard !fetchingInits.contains(uri), let url = URL(string: uri) else { return }
    fetchingInits.insert(uri)
    Task { [weak self] in
      var request = URLRequest(url: url)
      request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
      let fetched = try? await URLSession.shared.data(for: request)
      guard let self else { return }
      self.fetchingInits.remove(uri)
      let parsed = fetched.flatMap { FMP4Init.parse($0.0) }
      if let parsed { self.inits[uri] = parsed } else {
        ActivityLog.shared.add("Kestrel player: couldn't read the stream's init segment")
      }
      for load in self.loads where load.demuxer == nil && load.planned.mapURI == uri {
        if parsed == nil {
          load.task?.cancel()
          load.failed = true
          load.finished = true
          continue
        }
        self.feed(load, Data())
        if load.downloaded {
          load.frames += load.demuxer?.flush() ?? []
          load.finished = true
        }
      }
      self.pump()
    }
  }
}

/// One segment being downloaded and unpacked.
@MainActor
final class SegmentLoad {
  let planned: LiveSegmentPlanner.Planned
  var task: URLSessionDataTask?
  /// Chosen from the first bytes (see KestrelEngine.feed).
  var demuxer: SegmentDemuxer?
  /// Bytes that came before the demuxer could be made (waiting for an init segment).
  var raw = Data()
  /// Downloaded completely (it may still wait for its init segment).
  var downloaded = false
  /// When its last bytes came in.
  var lastArrival: Date?
  /// When it was (last) asked for.
  var requestedAt: Date?
  /// Asked for again after getting stuck (see KestrelEngine.refetchStuckFront).
  var retries = 0
  /// Asked for again part-way in: bytes at the start of the answer that are already in (when the
  /// server sends the whole file instead of the rest).
  var skip = 0
  /// Handed over to the next segment before its download closed (its end is ignored).
  var handedOver = false
  /// Unpacked, not yet handed to the renderers.
  var frames: [DemuxedFrame] = [] {
    didSet {
      guard frames.count > oldValue.count else { return }
      for frame in frames[oldValue.count...] {
        guard case .audio(let audio) = frame else { continue }
        let end = audio.pts + Int64(1024 * 90_000 / max(audio.config.sampleRate, 8000))
        if firstAudio == nil { firstAudio = audio.pts }
        if audioEnd.map({ end > $0 }) ?? true { audioEnd = end }
      }
    }
  }
  /// The first sound's time and where the sound in so far ends (the stream's own times).
  var firstAudio: Int64?
  var audioEnd: Int64?
  var received = 0
  var finished = false
  var failed = false
  var timed = false
  var dated = false

  init(planned: LiveSegmentPlanner.Planned) {
    self.planned = planned
  }
}

extension KestrelEngine: URLSessionDataDelegate {
  // (The session's delegate queue is the main queue.)
  nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    MainActor.assumeIsolated {
      guard let load = loads.first(where: { $0.task === dataTask }), !load.handedOver else { return }
      // (An error's page isn't video.)
      if let code = (dataTask.response as? HTTPURLResponse)?.statusCode, code >= 300 { return }
      let now = Date()
      if load.planned.live, let last = load.lastArrival {
        let gap = now.timeIntervalSince(last)
        if gap > 0.15 {
          arrivalGaps.append((now, gap))
          if arrivalGaps.count > 200 { arrivalGaps.removeFirst(100) }
        }
      }
      load.lastArrival = now
      lastArrival = now
      var data = data
      if load.skip > 0 {
        // Asked for the rest: a server that sent all of it anyway has its start (already in) left out.
        if (dataTask.response as? HTTPURLResponse)?.statusCode == 206 {
          load.skip = 0
        } else {
          let drop = min(load.skip, data.count)
          load.skip -= drop
          data = data.dropFirst(drop)
          guard !data.isEmpty else { return }
          data = Data(data)
        }
      }
      load.received += data.count
      feed(load, data)
      pump()
    }
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    MainActor.assumeIsolated {
      guard let load = loads.first(where: { $0.task === task }), !load.handedOver else { return }
      var status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
      // The rest of one asked for again (206), or nothing was left of it (416: it was all in).
      if status == 206 || (status == 416 && load.received > 0) { status = 200 }
      if error != nil || status != 200 {
        load.failed = true
        if (error as? URLError)?.code != .cancelled {
          ActivityLog.shared.add("Kestrel player: segment \(load.planned.sequence) failed (\(error?.localizedDescription ?? "HTTP \(status)"))")
        }
      } else if load.demuxer == nil, !load.raw.isEmpty {
        // Downloaded, but its init segment isn't in yet: finished when it is.
        load.downloaded = true
        return
      } else {
        load.frames += load.demuxer?.flush() ?? []
      }
      load.finished = true
      pump()
    }
  }
}
