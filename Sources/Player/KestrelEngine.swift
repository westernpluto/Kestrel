// Kestrel's own player, part 2: playing what TSDemuxer unpacks.
//
// Amazon's player keeps Twitch streams about a second behind live by downloading each segment
// while it's still being made (Twitch lists those ahead of time, as prefetch hints) and showing
// its frames as they arrive. The Apple player can't: it only plays finished segments, so it
// stays several seconds back. This does what Amazon's does, with the system's own pieces:
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
  /// The screen's layer has a frame on screen and is caught up (nothing hidden).
  var screenDrawing: Bool {
    guard !screenBehind, !inBackground, !displayLayer.isHidden, displayLayer.status == .rendering,
      !displayLayer.requiresFlushToResumeDecoding
    else { return false }
    if #available(iOS 17.4, tvOS 17.4, *) { return displayLayer.sampleBufferRenderer.displayedPixelBuffer() != nil }
    return true
  }
  /// Hides or shows the Picture in Picture copy (out of sight while the window is handed back).
  func setMirrorHidden(_ hidden: Bool) {
    guard let mirrorLayer, mirrorLayer.isHidden != hidden else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mirrorLayer.isHidden = hidden
    CATransaction.commit()
    screenNote(hidden ? "copy hidden" : "copy shown")
  }

  /// Puts the Picture in Picture copy's view over the picture's spot again (set by the view).
  var placeMirror: (() -> Void)?
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
  private lazy var urlSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 10
    configuration.httpMaximumConnectionsPerHost = 6
    return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
  }()
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
  private var timestampsChecked = false
  private var timestampSkew = 0.0
  private var lastHeardMoved = Date()
  private(set) var lateAudio = 0
  private(set) var audioGaps = 0
  private(set) var largestAudioGap = 0.0
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
        MainActor.assumeIsolated { self?.inBackground = true }
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

  func stop() {
    running = false
    pollTask?.cancel()
    pollTask = nil
    ticker?.invalidate()
    ticker = nil
    for load in loads { load.task?.cancel() }
    loads = []
    setSpeed(0)
    displayLayer.flushAndRemoveImage()
    retireOldLayer(force: true)
    mirrorLayer?.flushAndRemoveImage()
    group = []
    audio.flush()
    audioHistory = []
    lastAudioTime = nil
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
    stop()
    planner = LiveSegmentPlanner(startBack: 0)
    timeline = StreamTimeline()
    heldVideo = []
    heldAudio = []
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
      stop()
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
    rendition = index
    catchUp.hold(for: 3)
  }

  /// Auto: the best quality that plays smoothly.
  func setAuto() {
    autoQuality = true
    fit = ConnectionFit(count: renditions.count)
    if let best = renditions.first { setRendition(best, byHand: false) }
  }

  func setMuted(_ mute: Bool) {
    muted = mute
    audio.setMuted(mute)
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
  var latency: Double? {
    guard let raw = rawLatency else { return nil }
    return max(0, raw - timestampSkew)
  }

  /// From the stream's own timestamps (Twitch's program date-time), which some channels have well
  /// off (one read 33 s behind with 2.5 s in hand): see `timestampSkew`.
  var rawLatency: Double? {
    guard clockRunning, let anchor else { return nil }
    let shown = anchor.date.addingTimeInterval(Double(now - anchor.time) / Double(Self.clock))
    let value = Date().timeIntervalSince(shown)
    return value.isFinite && value > -1 ? max(0, value) : nil
  }

  /// How far the stream's timestamps are off, when they're clearly off: checked once a few
  /// seconds in, against what's in hand (the player is never much further behind live than that
  /// plus a second or two on the way).
  private func checkTimestamps(ahead: Double) {
    guard !timestampsChecked, let raw = rawLatency, let since = playingSince, Date().timeIntervalSince(since) > 3 else { return }
    timestampsChecked = true
    let expected = ahead + 2
    if raw > expected + 4 {
      timestampSkew = raw - expected
      ActivityLog.shared.add(String(format: "Kestrel player: this stream's timestamps are about %.0f s off; latency shown corrected", timestampSkew))
    }
  }

  var rate: Float { speed }

  // MARK: Playlist

  private func poll() async {
    while running, !Task.isCancelled {
      if let text = await playlist(rendition), running {
        let planned = planner.plan(text)
        for segment in planned { begin(segment) }
      }
      // Twitch's low-latency playlists move every couple of seconds, and list the next two
      // segments ahead: often enough to start each one as soon as it's listed.
      try? await Task.sleep(nanoseconds: 700_000_000)
    }
  }

  private func begin(_ planned: LiveSegmentPlanner.Planned) {
    guard let url = URL(string: planned.uri) else { return }
    let load = SegmentLoad(planned: planned)
    var request = URLRequest(url: url)
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    let task = urlSession.dataTask(with: request)
    load.task = task
    loads.append(load)
    task.resume()
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
    return Date().timeIntervalSince(quiet) > 0.25
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
      if inBackground || (UIApplication.shared.applicationState != .active && displayLayer.requiresFlushToResumeDecoding) {
        // (Past the keyframe check above: the copy goes on from here.) Not while the app is still
        // coming back and can't decode yet either: catching up then reset the screen with every
        // frame; it catches up once the app is active (see `enteringForeground`).
        waitingForKeyframe = false
        screenBehind = true
      } else if !feedScreen(entry, hidden: hidden) {
        return
      }
      if let mirrorLayer { feedMirror(mirrorLayer, entry, hidden: hidden) }
    } else {
      guard let session = decoderSession(for: format), let sample = entry.sample(hidden: false) else {
        waitingForKeyframe = true
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
    // (A picture layer that stopped in the background just needs flushing.)
    if !inBackground {
      if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding { displayLayer.flush() }
      displayLayer.enqueue(sample)
    }
    if let mirrorLayer {
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
        if abs(off) > 180 {
          audioGaps += 1
          largestAudioGap = max(largestAudioGap, Double(off) / 90)
        }
      }
      lastAudioTime = time
      audioHistory.append((frame, time))
      if audioHistory.count > 250 { audioHistory.removeFirst(audioHistory.count - 250) }
    }
    audio.enqueue(frame, pts: time)
    audioFramesQueued += 1
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
  private func startIfReady() {
    guard !clockRunning, !paused, let first = heldVideo.first?.pts, let last = newestPlayable else { return }
    let margin = Int64(max(catchUp.targetBuffer, 0.5) * Double(Self.clock))
    // Only once what's being unpacked is the segment still being made (everything before it is
    // in): starting earlier put the start seconds back, with all of that to catch up.
    let atLive = loads.first?.planned.live ?? true
    let waited = Date().timeIntervalSince(startedLoading)
    guard atLive || waited > 6, last - first >= Int64(0.3 * Double(Self.clock)) else { return }
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
      String(format: "Kestrel player: started %.2f s behind the newest frame (%@, %d frames decoded ahead of it)", startedBehind ?? 0, container, videoFramesHidden))
    CMTimebaseSetTime(videoClock, time: CMTime(value: start, timescale: Self.clock))
    clockRunning = true
    playingSince = Date()
    setSpeed(1)
    catchUp.restart()
    state = .playing
  }

  // MARK: Ticking: margin, stalls

  private func tick() {
    guard running else { return }
    retireOldLayer()
    // A segment whose frames are all in can hand over to the next before its download closes.
    pump()
    guard clockRunning else { return }
    let ahead = bufferAhead ?? 0
    if stalledSince == nil, ahead < 0.03 {
      // Ran dry: hold the clock until there's the margin again.
      stalledSince = Date()
      stalls += 1
      setSpeed(0)
      catchUp.stalled()
      state = .stalled
      // Twice in a few minutes while the video kept arriving: the connection can't carry this
      // quality; one lower from the next segment.
      if autoQuality, fit.stalled(), fit.step < renditions.count {
        setRendition(renditions[fit.step], byHand: false)
        ActivityLog.shared.add("Kestrel player: stalling at this quality; one lower for now (trying again in a few minutes)")
      }
      return
    }
    if autoQuality, fit.tick(), fit.step < renditions.count {
      setRendition(renditions[fit.step], byHand: false)
      ActivityLog.shared.add("Kestrel player: trying the better quality again")
    }
    if let since = stalledSince {
      let resumeAt = max(0.4, min(catchUp.targetBuffer, 1.5))
      if ahead >= resumeAt {
        stalledSince = nil
        setSpeed(1)
        state = .playing
      } else if Date().timeIntervalSince(since) > 12 {
        // Nothing for a long while: start over at live.
        restart()
      }
      return
    }
    checkTimestamps(ahead: ahead)
    let latency = self.latency
    // Far behind (a long dropout, the background): start over at live. Judged by what's in hand
    // (judged by the stream's timestamps, a channel with them half a minute off started over
    // every quarter second and never got going).
    if ahead > 15 {
      restart()
      return
    }
    let rate = catchUp.update(
      buffer: ahead, latency: latency ?? ahead + 1, playing: true, position: Double(now) / Double(Self.clock),
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
  /// Handed over to the next segment before its download closed (its end is ignored).
  var handedOver = false
  /// Unpacked, not yet handed to the renderers.
  var frames: [DemuxedFrame] = []
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
      load.received += data.count
      feed(load, data)
      pump()
    }
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    MainActor.assumeIsolated {
      guard let load = loads.first(where: { $0.task === task }), !load.handedOver else { return }
      let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
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
