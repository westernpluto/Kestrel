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
//   AVSampleBufferDisplayLayer + AVSampleBufferAudioRenderer, on an AVSampleBufferRenderSynchronizer
//
// and steers the synchronizer's rate with the same LiveCatchUp as the low-latency player, so it
// stays close to live and rides out hiccups the same way. It starts already near the live edge:
// the frames before its starting point are decoded but not shown. It runs on iPhone and Apple TV.

import AVFoundation
import CoreMedia
import Foundation
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

  let displayLayer = AVSampleBufferDisplayLayer()
  let audioRenderer = AVSampleBufferAudioRenderer()
  let synchronizer = AVSampleBufferRenderSynchronizer()

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
  private var firstVideoTime: Int64?
  private var lastVideoTime: Int64?
  private var lastDecodeTime: Int64?
  private var frameLength: Int64 = 3000
  /// Before the clock starts: the frames so far, held until where to start is known (then the
  /// ones before it are decoded but not shown).
  private var heldVideo: [(frame: VideoFrame, pts: Int64, dts: Int64)] = []
  private var heldAudio: [(frame: AudioFrame, pts: Int64)] = []
  /// Playing (the synchronizer's clock runs).
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

  static let clock: Int32 = 90_000
  /// Rate limits for the synchronizer (it plays audio pitch-corrected within these).
  static let maxRate: Float = 1.2

  init(rendition: Int, startMargin: Double? = nil, playlist: @escaping @Sendable (Int) async -> String?) {
    self.rendition = rendition
    self.playlist = playlist
    catchUp = LiveCatchUp(targetBuffer: startMargin)
    super.init()
    displayLayer.videoGravity = .resizeAspect
    synchronizer.addRenderer(displayLayer)
    synchronizer.addRenderer(audioRenderer)
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
    synchronizer.setRate(0, time: synchronizer.currentTime())
    displayLayer.flushAndRemoveImage()
    audioRenderer.flush()
    closeDecoder()
  }

  /// Starts over at the live edge (after a pause, a long dropout, a failure).
  func restart() {
    stop()
    planner = LiveSegmentPlanner(startBack: 0)
    timeline = StreamTimeline()
    heldVideo = []
    heldAudio = []
    lastDecodeTime = nil
    videoFormat = nil
    parameterSets = nil
    audioFormat = nil
    audioConfig = nil
    waitingForKeyframe = true
    firstVideoTime = nil
    lastVideoTime = nil
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
  func setRendition(_ index: Int) {
    guard index != rendition else { return }
    rendition = index
    catchUp.hold(for: 3)
  }

  func setMuted(_ mute: Bool) {
    muted = mute
    audioRenderer.isMuted = mute
  }

  func setVolume(_ volume: Float) {
    audioRenderer.volume = volume
  }

  // MARK: Readings

  /// Where playback is, on the timeline (90 kHz).
  private var now: Int64 { Int64(synchronizer.currentTime().convertScale(Self.clock, method: .default).value) }

  /// Seconds of video in hand ahead of what's showing.
  var bufferAhead: Double? {
    guard let last = lastVideoTime else { return nil }
    let ahead = clockRunning ? Double(last + frameLength - now) : Double(last + frameLength - (firstVideoTime ?? last))
    return max(0, ahead / Double(Self.clock))
  }

  /// Seconds behind live: now, less when the frame showing was captured.
  var latency: Double? {
    guard clockRunning, let anchor else { return nil }
    let shown = anchor.date.addingTimeInterval(Double(now - anchor.time) / Double(Self.clock))
    let value = Date().timeIntervalSince(shown)
    return value.isFinite && value > -1 ? max(0, value) : nil
  }

  var rate: Float { synchronizer.rate }

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
    while let first = loads.first {
      if !first.frames.isEmpty {
        let frames = first.frames
        first.frames = []
        for frame in frames { enqueue(frame, from: first) }
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

  private func enqueue(_ frame: DemuxedFrame, from load: SegmentLoad) {
    if !load.timed {
      load.timed = true
      timeline.beginSegment(firstPTS: frame.pts, discontinuity: load.planned.discontinuity)
      if load.planned.discontinuity { waitingForKeyframe = true }
    }
    switch frame {
    case .video(let video):
      let time = timeline.map(video.pts, isVideo: true)
      // The decode time moves with it (streams with B-frames decode in another order than they
      // show: each frame has both times, and the decoder needs the decode one).
      let decodeTime = video.dts + (time - video.pts)
      if !load.dated, let date = load.planned.programDate {
        load.dated = true
        anchor = (time, date)
      }
      if clockRunning {
        enqueueVideo(video, pts: time, dts: decodeTime, hidden: false)
      } else if video.codec == .h264, video.isKeyframe || !heldVideo.isEmpty {
        heldVideo.append((video, time, decodeTime))
        if firstVideoTime == nil { firstVideoTime = time }
        if lastVideoTime.map({ time > $0 }) ?? true { lastVideoTime = time }
      }
    case .audio(let audio):
      let time = timeline.map(audio.pts, isVideo: false)
      if clockRunning {
        enqueueAudio(audio, time: time)
      } else {
        heldAudio.append((audio, time))
      }
    }
  }

  private func enqueueVideo(_ frame: VideoFrame, pts time: Int64, dts: Int64, hidden: Bool) {
    guard frame.codec == .h264 else { return }
    if waitingForKeyframe, !frame.isKeyframe { return }
    let units = AnnexB.units(frame.data)
    if frame.isKeyframe, let sets = H264.parameterSets(units) {
      let key = sets.sps + sets.pps
      if key != parameterSets || videoFormat == nil {
        videoFormat = Self.h264Format(sps: sets.sps, pps: sets.pps)
        parameterSets = key
      }
    }
    guard let format = videoFormat else { return }
    if let last = lastDecodeTime, dts > last, dts - last < 9000 { frameLength = dts - last }
    lastDecodeTime = dts
    guard
      let sample = Self.videoSample(
        H264.sample(units), format: format, pts: time, dts: dts, duration: frameLength, keyframe: frame.isKeyframe, hidden: false)
    else { return }
    if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
      // The layer gave up, or the app was in the background: start it again.
      if displayLayer.status == .failed {
        decoderFailures += 1
        let error = displayLayer.error as NSError?
        lastDecoderError = error.map { "layer \($0.domain) \($0.code)" } ?? "layer failed"
      }
      displayLayer.flush()
    }
    guard let session = decoderSession(for: format) else {
      waitingForKeyframe = true
      return
    }
    waitingForKeyframe = false
    if hidden { showFrom = max(showFrom, time + 1) }
    decode(sample, in: session)
    videoFramesQueued += 1
    if hidden { videoFramesHidden += 1 }
    if firstVideoTime == nil { firstVideoTime = time }
    if lastVideoTime.map({ time > $0 }) ?? true { lastVideoTime = time }
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
    displayLayer.enqueue(sample)
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

  private func enqueueAudio(_ frame: AudioFrame, time: Int64) {
    if frame.config != audioConfig || audioFormat == nil {
      audioFormat = Self.aacFormat(frame.config)
      audioConfig = frame.config
    }
    guard let format = audioFormat, let sample = Self.audioSample(frame.data, format: format, pts: time) else { return }
    audioRenderer.enqueue(sample)
    audioFramesQueued += 1
  }

  /// Starts the clock once there's video: just behind the newest frame in hand (the stream's
  /// margin), so it opens close to live instead of at the start of the first segment.
  private func startIfReady() {
    guard !clockRunning, !paused, let first = heldVideo.first?.pts, let last = lastVideoTime else { return }
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
    synchronizer.setRate(1, time: CMTime(value: start, timescale: Self.clock))
    clockRunning = true
    catchUp.restart()
    state = .playing
  }

  // MARK: Ticking: margin, stalls

  private func tick() {
    guard running, clockRunning else { return }
    let ahead = bufferAhead ?? 0
    if stalledSince == nil, ahead < 0.03 {
      // Ran dry: hold the clock until there's the margin again.
      stalledSince = Date()
      stalls += 1
      synchronizer.rate = 0
      catchUp.stalled()
      state = .stalled
      return
    }
    if let since = stalledSince {
      let resumeAt = max(0.4, min(catchUp.targetBuffer, 1.5))
      if ahead >= resumeAt {
        stalledSince = nil
        synchronizer.rate = 1
        state = .playing
      } else if Date().timeIntervalSince(since) > 12 {
        // Nothing for a long while: start over at live.
        restart()
      }
      return
    }
    let latency = self.latency
    if let latency, latency > 20 {
      restart()
      return
    }
    let rate = catchUp.update(
      buffer: ahead, latency: latency ?? ahead + 1, playing: true, position: Double(now) / Double(Self.clock),
      maxRate: Self.maxRate)
    if synchronizer.rate != rate { synchronizer.rate = rate }
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
      guard let load = loads.first(where: { $0.task === dataTask }) else { return }
      load.received += data.count
      feed(load, data)
      pump()
    }
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    MainActor.assumeIsolated {
      guard let load = loads.first(where: { $0.task === task }) else { return }
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
