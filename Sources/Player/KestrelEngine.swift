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
  private var planner = LiveSegmentPlanner(startBack: 1)
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
  private var frameLength: Int64 = 3000
  /// Playing (the synchronizer's clock runs).
  private(set) var clockRunning = false
  private var stalledSince: Date?
  /// A frame time on the timeline and when it was captured (from the playlist's dates).
  private var anchor: (time: Int64, date: Date)?
  private var paused = false
  private var startedLoading = Date()
  private(set) var stalls = 0
  private(set) var segmentsLoaded = 0
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
  }

  /// Starts over at the live edge (after a pause, a long dropout, a failure).
  func restart() {
    stop()
    planner = LiveSegmentPlanner(startBack: 1)
    timeline = StreamTimeline()
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
      if !load.dated, let date = load.planned.programDate {
        load.dated = true
        anchor = (time, date)
      }
      enqueueVideo(video, time: time)
    case .audio(let audio):
      enqueueAudio(audio, time: timeline.map(audio.pts, isVideo: false))
    }
  }

  private func enqueueVideo(_ frame: VideoFrame, time: Int64) {
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
    if let last = lastVideoTime, time > last, time - last < 9000 { frameLength = time - last }
    guard let sample = Self.videoSample(H264.sample(units), format: format, pts: time, duration: frameLength, keyframe: frame.isKeyframe)
    else { return }
    if displayLayer.status == .failed {
      // The decoder gave up (a corrupt frame): flush and carry on from the next keyframe.
      displayLayer.flush()
      waitingForKeyframe = true
      if !frame.isKeyframe { return }
    }
    waitingForKeyframe = false
    displayLayer.enqueue(sample)
    if firstVideoTime == nil { firstVideoTime = time }
    if lastVideoTime.map({ time > $0 }) ?? true { lastVideoTime = time }
  }

  private func enqueueAudio(_ frame: AudioFrame, time: Int64) {
    if frame.config != audioConfig || audioFormat == nil {
      audioFormat = Self.aacFormat(frame.config)
      audioConfig = frame.config
    }
    guard let format = audioFormat, let sample = Self.audioSample(frame.data, format: format, pts: time) else { return }
    audioRenderer.enqueue(sample)
  }

  /// Starts the clock once there's video: just behind the newest frame in hand (the stream's
  /// margin), so it opens close to live instead of at the start of the first segment.
  private func startIfReady() {
    guard !clockRunning, !paused, let first = firstVideoTime, let last = lastVideoTime else { return }
    let margin = Int64(max(catchUp.targetBuffer, 0.5) * Double(Self.clock))
    let liveArriving = loads.contains { $0.planned.live && $0.received > 0 }
    let waited = Date().timeIntervalSince(startedLoading)
    guard last - first >= margin, liveArriving || waited > 4 || loads.isEmpty else { return }
    let start = max(first, last - margin)
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

  static func videoSample(_ data: Data, format: CMVideoFormatDescription, pts: Int64, duration: Int64, keyframe: Bool)
    -> CMSampleBuffer?
  {
    guard !data.isEmpty, let block = block(data) else { return nil }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: duration, timescale: clock), presentationTimeStamp: CMTime(value: pts, timescale: clock),
      decodeTimeStamp: CMTime(value: pts, timescale: clock))
    var size = data.count
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
      let sample
    else { return nil }
    if !keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
      dictionary[kCMSampleAttachmentKey_NotSync as String] = true
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

// MARK: - Downloads

/// One segment being downloaded and unpacked.
@MainActor
final class SegmentLoad {
  let planned: LiveSegmentPlanner.Planned
  var task: URLSessionDataTask?
  var demuxer = TSDemuxer()
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
      load.frames += load.demuxer.feed(data)
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
      } else {
        load.frames += load.demuxer.flush()
      }
      load.finished = true
      pump()
    }
  }
}
