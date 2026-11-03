// Kestrel's own player, part 1: unpacking Twitch's video as it arrives.
//
// Twitch's low-latency segments are MPEG transport streams: 188-byte packets carrying H.264 video
// (stream type 0x1B), AAC audio in ADTS frames (0x0F) and timed ID3 metadata (0x15), each
// segment starting with its own PAT/PMT and a keyframe. Video PES packets have no length (one
// frame each, ending where the next begins), with a presentation time on a 90 kHz clock and no
// decode time (no B-frames). This unpacks bytes as they come in, a few at a time from a segment
// still being made, into whole video frames and audio frames with their times, ready to hand
// to the system's decoder and renderers.

import Foundation

/// One video frame (access unit) in Annex B form (start codes before each NAL unit).
struct VideoFrame: Equatable, Sendable {
  enum Codec: Equatable, Sendable { case h264, hevc }
  var codec: Codec
  /// Presentation and decode time, 90 kHz.
  var pts: Int64
  var dts: Int64
  var data: Data
  var isKeyframe: Bool
}

/// One AAC frame (raw, its ADTS header taken off), with the stream's format.
struct AudioFrame: Equatable, Sendable {
  var pts: Int64
  var data: Data
  var config: ADTS.Config
}

enum DemuxedFrame: Equatable, Sendable {
  case video(VideoFrame)
  case audio(AudioFrame)

  var pts: Int64 {
    switch self {
    case .video(let frame): return frame.pts
    case .audio(let frame): return frame.pts
    }
  }
}

/// Unpacks an MPEG transport stream fed in pieces of any size.
struct TSDemuxer {
  static let packetSize = 188
  static let clock: Double = 90_000

  private enum Kind { case h264, hevc, aac }

  private var leftover = Data()
  private var pmtPID: Int?
  private var streams: [Int: Kind] = [:]
  /// The PES packet being put together on each elementary stream.
  private var pending: [Int: Data] = [:]
  /// The last video frame on each stream, held until the next PES: Twitch's encoders don't always
  /// line PES packets up with frames, and the first bytes of a PES (before its first start code)
  /// can be the end of the previous frame. Cut at the PES instead, frames lost their last bytes
  /// (the decoder rejected nearly all of them: a black picture on High-profile sources).
  private var heldFrames: [Int: VideoFrame] = [:]

  init() {}

  /// Feeds bytes; returns the frames completed by them, in stream order.
  mutating func feed(_ bytes: Data) -> [DemuxedFrame] {
    var data = leftover
    data.append(bytes)
    var out: [DemuxedFrame] = []
    var offset = data.startIndex
    // Find the first sync byte (a stream joined mid-packet).
    while offset < data.endIndex, data[offset] != 0x47 { offset += 1 }
    while data.endIndex - offset >= Self.packetSize {
      if data[offset] != 0x47 {
        // Lost sync: look for it again.
        offset += 1
        while offset < data.endIndex, data[offset] != 0x47 { offset += 1 }
        continue
      }
      packet(data[offset..<(offset + Self.packetSize)], into: &out)
      offset += Self.packetSize
    }
    leftover = Data(data[offset...])
    return out
  }

  /// The end of the stream (a segment that's complete): the last frames on each stream.
  mutating func flush() -> [DemuxedFrame] {
    var out: [DemuxedFrame] = []
    for (pid, data) in pending.sorted(by: { $0.key < $1.key }) where !data.isEmpty {
      if let kind = streams[pid] { pes(data, kind: kind, pid: pid, into: &out) }
    }
    for (_, frame) in heldFrames.sorted(by: { $0.key < $1.key }) { out.append(.video(frame)) }
    heldFrames = [:]
    pending = [:]
    leftover = Data()
    // (In decode order: sorting by presentation time put B-frames out of order.)
    return out
  }

  private mutating func packet(_ p: Data.SubSequence, into out: inout [DemuxedFrame]) {
    let b = p.startIndex
    let unitStart = p[b + 1] & 0x40 != 0
    let pid = Int(p[b + 1] & 0x1F) << 8 | Int(p[b + 2])
    let adaptation = (p[b + 3] >> 4) & 0x3
    var start = b + 4
    if adaptation & 0x2 != 0 {
      start += 1 + Int(p[b + 4])
    }
    guard adaptation & 0x1 != 0, start < p.endIndex else { return }
    let payload = p[start...]

    if pid == 0 {
      if unitStart { parsePAT(payload) }
      return
    }
    if pid == pmtPID {
      if unitStart { parsePMT(payload) }
      return
    }
    guard let kind = streams[pid] else { return }
    if unitStart {
      if let previous = pending[pid], !previous.isEmpty { pes(previous, kind: kind, pid: pid, into: &out) }
      pending[pid] = Data(payload)
    } else if pending[pid] != nil {
      pending[pid]!.append(contentsOf: payload)
    }
  }

  /// A PSI section's bytes, past its pointer field.
  private static func section(_ payload: Data.SubSequence) -> Data.SubSequence? {
    guard let pointer = payload.first else { return nil }
    let start = payload.startIndex + 1 + Int(pointer)
    return start < payload.endIndex ? payload[start...] : nil
  }

  private mutating func parsePAT(_ payload: Data.SubSequence) {
    guard let s = Self.section(payload), s.count >= 12 else { return }
    let b = s.startIndex
    let length = Int(s[b + 1] & 0x0F) << 8 | Int(s[b + 2])
    var i = b + 8
    let end = min(s.endIndex, b + 3 + length - 4)
    while i + 4 <= end {
      let program = Int(s[i]) << 8 | Int(s[i + 1])
      let pid = Int(s[i + 2] & 0x1F) << 8 | Int(s[i + 3])
      if program != 0 {
        pmtPID = pid
        return
      }
      i += 4
    }
  }

  private mutating func parsePMT(_ payload: Data.SubSequence) {
    guard let s = Self.section(payload), s.count >= 16 else { return }
    let b = s.startIndex
    let length = Int(s[b + 1] & 0x0F) << 8 | Int(s[b + 2])
    let infoLength = Int(s[b + 10] & 0x0F) << 8 | Int(s[b + 11])
    var i = b + 12 + infoLength
    let end = min(s.endIndex, b + 3 + length - 4)
    var found: [Int: Kind] = [:]
    while i + 5 <= end {
      let type = s[i]
      let pid = Int(s[i + 1] & 0x1F) << 8 | Int(s[i + 2])
      let esInfo = Int(s[i + 3] & 0x0F) << 8 | Int(s[i + 4])
      switch type {
      case 0x1B: found[pid] = .h264
      case 0x24: found[pid] = .hevc
      case 0x0F: found[pid] = .aac
      default: break
      }
      i += 5 + esInfo
    }
    if !found.isEmpty { streams = found }
  }

  /// Where the first Annex B start code (00 00 01, or 00 00 00 01) begins.
  private static func firstStartCode(_ body: Data.SubSequence) -> Int? {
    var i = body.startIndex
    while i + 2 < body.endIndex {
      if body[i] == 0, body[i + 1] == 0 {
        if body[i + 2] == 1 { return i }
        if body[i + 2] == 0, i + 3 < body.endIndex, body[i + 3] == 1 { return i }
      }
      i += 1
    }
    return nil
  }

  /// A 33-bit PES timestamp.
  private static func timestamp(_ d: Data, _ i: Int) -> Int64 {
    Int64(d[i] >> 1 & 0x07) << 30 | Int64(d[i + 1]) << 22 | Int64(d[i + 2] >> 1) << 15 | Int64(d[i + 3]) << 7
      | Int64(d[i + 4] >> 1)
  }

  private mutating func pes(_ raw: Data, kind: Kind, pid: Int, into out: inout [DemuxedFrame]) {
    let d = Data(raw)  // zero-based
    guard d.count >= 9, d[0] == 0, d[1] == 0, d[2] == 1 else { return }
    let flags = d[7]
    let headerLength = Int(d[8])
    let bodyStart = 9 + headerLength
    guard bodyStart <= d.count, flags & 0x80 != 0, d.count >= 14 else { return }
    let pts = Self.timestamp(d, 9)
    let dts = flags & 0x40 != 0 && d.count >= 19 ? Self.timestamp(d, 14) : pts
    // A bounded PES (audio) ends at its length; an unbounded one (video) where the next began.
    let declared = Int(d[4]) << 8 | Int(d[5])
    let end = declared > 0 ? min(d.count, 6 + declared) : d.count
    guard bodyStart < end else { return }
    let body = d[bodyStart..<end]
    switch kind {
    case .h264, .hevc:
      // Bytes before the first start code finish the previous frame; it goes out now.
      let start = Self.firstStartCode(body) ?? body.endIndex
      if var previous = heldFrames[pid] {
        previous.data.append(contentsOf: body[body.startIndex..<start])
        out.append(.video(previous))
        heldFrames[pid] = nil
      }
      guard start < body.endIndex else { return }
      let data = Data(body[start...])
      let codec: VideoFrame.Codec = kind == .h264 ? .h264 : .hevc
      let key = kind == .h264 ? H264.isKeyframe(data[...]) : HEVC.isKeyframe(data[...])
      heldFrames[pid] = VideoFrame(codec: codec, pts: pts, dts: dts, data: data, isKeyframe: key)
    case .aac:
      var time = pts
      for frame in ADTS.frames(in: body) {
        out.append(.audio(AudioFrame(pts: time, data: frame.payload, config: frame.config)))
        time += Int64((1024.0 * Self.clock / Double(frame.config.sampleRate)).rounded())
      }
    }
  }
}

// MARK: - H.264 / HEVC

enum AnnexB {
  /// The NAL units in Annex B data (start codes taken off).
  static func units(_ data: Data) -> [Data] {
    let d = Data(data)
    var units: [Data] = []
    var start: Int?
    var i = 0
    while i + 3 <= d.count {
      if d[i] == 0, d[i + 1] == 0, d[i + 2] == 1 {
        if let s = start {
          var e = i
          if e > s, d[e - 1] == 0 { e -= 1 }  // the 4-byte form's leading zero
          if e > s { units.append(d[s..<e]) }
        }
        i += 3
        start = i
      } else {
        i += 1
      }
    }
    if let s = start, s < d.count { units.append(d[s..<d.count]) }
    return units.map { Data($0) }
  }

  /// Each NAL unit behind a 4-byte big-endian length (what the system's decoder takes), leaving
  /// out the ones `skip` picks (parameter sets, which go in the format, and delimiters).
  static func lengthPrefixed(_ units: [Data], skip: (Data) -> Bool) -> Data {
    var out = Data()
    for unit in units where !unit.isEmpty && !skip(unit) {
      var length = UInt32(unit.count).bigEndian
      withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
      out.append(unit)
    }
    return out
  }
}

enum H264 {
  static func type(_ unit: Data) -> UInt8 { (unit.first ?? 0) & 0x1F }

  static func isKeyframe(_ data: Data.SubSequence) -> Bool {
    AnnexB.units(Data(data)).contains { type($0) == 5 }
  }

  /// The sequence and picture parameter sets in a frame (a keyframe carries them).
  static func parameterSets(_ units: [Data]) -> (sps: Data, pps: Data)? {
    guard let sps = units.first(where: { type($0) == 7 }), let pps = units.first(where: { type($0) == 8 }) else { return nil }
    return (sps, pps)
  }

  /// What the decoder is given: everything but parameter sets and access unit delimiters.
  static func sample(_ units: [Data]) -> Data {
    AnnexB.lengthPrefixed(units) { [7, 8, 9].contains(type($0)) }
  }
}

enum HEVC {
  static func type(_ unit: Data) -> UInt8 { ((unit.first ?? 0) >> 1) & 0x3F }

  static func isKeyframe(_ data: Data.SubSequence) -> Bool {
    AnnexB.units(Data(data)).contains { (16...21).contains(type($0)) }
  }

  static func parameterSets(_ units: [Data]) -> (vps: Data, sps: Data, pps: Data)? {
    guard let vps = units.first(where: { type($0) == 32 }), let sps = units.first(where: { type($0) == 33 }),
      let pps = units.first(where: { type($0) == 34 })
    else { return nil }
    return (vps, sps, pps)
  }

  static func sample(_ units: [Data]) -> Data {
    AnnexB.lengthPrefixed(units) { [32, 33, 34, 35].contains(type($0)) }
  }
}

// MARK: - AAC (ADTS)

enum ADTS {
  struct Config: Equatable, Sendable {
    /// MPEG-4 audio object type (2: AAC LC).
    var objectType: Int
    var sampleRateIndex: Int
    var channels: Int

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    var sampleRate: Int { sampleRateIndex < Self.sampleRates.count ? Self.sampleRates[sampleRateIndex] : 44100 }

    /// The AudioSpecificConfig the system's decoder wants (2 bytes).
    var audioSpecificConfig: Data {
      let value = UInt16(objectType & 0x1F) << 11 | UInt16(sampleRateIndex & 0x0F) << 7 | UInt16(channels & 0x0F) << 3
      return Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }
  }

  struct Frame: Equatable {
    var config: Config
    var payload: Data
  }

  /// The ADTS frames in a PES body.
  static func frames(in body: Data.SubSequence) -> [Frame] {
    let d = Data(body)
    var frames: [Frame] = []
    var i = 0
    while i + 7 <= d.count {
      guard d[i] == 0xFF, d[i + 1] & 0xF0 == 0xF0 else {
        i += 1
        continue
      }
      let protectionAbsent = d[i + 1] & 0x01 == 1
      let objectType = Int(d[i + 2] >> 6) + 1
      let rateIndex = Int(d[i + 2] >> 2 & 0x0F)
      let channels = Int(d[i + 2] & 0x01) << 2 | Int(d[i + 3] >> 6)
      let length = Int(d[i + 3] & 0x03) << 11 | Int(d[i + 4]) << 3 | Int(d[i + 5] >> 5)
      let header = protectionAbsent ? 7 : 9
      guard length > header, i + length <= d.count else { break }
      frames.append(
        Frame(
          config: Config(objectType: objectType, sampleRateIndex: rateIndex, channels: channels),
          payload: Data(d[(i + header)..<(i + length)])))
      i += length
    }
    return frames
  }
}

// MARK: - One timeline across segments

/// Keeps the stream's timestamps on one continuous timeline. Inside a stream they run on, but at
/// a discontinuity (an ad-free copy swapped in for an ad, a broadcaster's restart) they jump; the
/// player's clock mustn't. Each segment's times are moved by an offset chosen so it carries on
/// right where the previous one ended. The 33-bit clock's wrap (every 26.5 hours) is handled the
/// same way.
struct StreamTimeline {
  private var offset: Int64 = 0
  /// The latest time handed out (on the timeline).
  private(set) var lastTime: Int64?
  /// Each track's latest time and frame length: a segment's start is checked against the same
  /// track's end (a stream's audio can sit a couple of hundred ms off its video at a segment's
  /// start, so comparing one with the other saw a jump at every segment and shifted it: a gap in
  /// the sound each time).
  private var lastVideo: Int64?
  private var previousVideo: Int64?
  private var videoSteps: [Int64] = []
  private var lastAudio: Int64?
  private var audioStep: Int64 = 1920
  /// The first segment's first time: the timeline starts there.
  private(set) var origin: Int64?
  /// How far off a segment's start may be and still count as following on (60 ms: under four
  /// frames at 60 fps).
  static let seamTolerance: Int64 = 5400

  init() {}

  /// A video frame's length: the smallest step between frames lately (in decode order, frames
  /// with B-frames jump about, but neighbours in time are always a frame apart somewhere).
  private var videoStep: Int64 { videoSteps.min() ?? 3000 }

  /// A segment begins with a frame stamped `firstPTS` (video or audio); `discontinuity` when the
  /// playlist marks one.
  mutating func beginSegment(firstPTS: Int64, isVideo: Bool = true, discontinuity: Bool) {
    guard let last = lastTime else {
      origin = firstPTS
      return
    }
    let mapped = firstPTS + offset
    // A segment that doesn't carry on where the last one ended (by more than a few frames, either
    // way) is joined on seamlessly, marked or not. Twitch's main stream and the ad-free copy
    // swapped in for an ad are encoded separately, and their times can be a tenth of a second
    // apart: the jump at each swap played as silence and a held picture (or overlapping sound),
    // a stutter in both. Within a stream, segments follow on to the frame.
    let expected: Int64
    if isVideo, let lastVideo {
      expected = lastVideo + videoStep
    } else if !isVideo, let lastAudio {
      expected = lastAudio + audioStep
    } else {
      expected = last + videoStep
    }
    if discontinuity || abs(mapped - expected) > Self.seamTolerance {
      offset = expected - firstPTS
    }
  }

  /// A frame's time on the timeline.
  mutating func map(_ pts: Int64, isVideo: Bool) -> Int64 {
    var time = pts + offset
    // The 33-bit wrap inside a segment.
    if let last = lastTime, last - time > (1 << 32) {
      offset += 1 << 33
      time += 1 << 33
    }
    if isVideo {
      if let previous = previousVideo {
        let step = abs(time - previous)
        if step > 0, step < 9000 {
          videoSteps.append(step)
          if videoSteps.count > 60 { videoSteps.removeFirst(videoSteps.count - 60) }
        }
      }
      previousVideo = time
      if lastVideo.map({ time > $0 }) ?? true { lastVideo = time }
    } else {
      if let previous = lastAudio, time > previous, time - previous < 9000 { audioStep = time - previous }
      if lastAudio.map({ time > $0 }) ?? true { lastAudio = time }
    }
    if lastTime.map({ time > $0 }) ?? true { lastTime = time }
    return time
  }
}

/// Evens out frame times that were rounded to whole milliseconds on the way in (RTMP carries
/// milliseconds: 60 frames a second arrive 16, 17, 17 ms apart instead of 16.67). On a 120 Hz
/// screen that jitter lands some frames a refresh early or late, so one shows twice as long as
/// the next: a fast, constant judder. Once the rhythm matches a standard frame rate, each time is
/// put on that rate's exact grid (never more than a third of a frame from where it was, so
/// sound stays in step and decode order is kept).
struct FrameGrid {
  /// The exact frame length on the 90 kHz clock, once known.
  private(set) var nominal: Double?
  private var base: Int64?
  /// The current run of evenly following frames: where it began and how many since.
  private var runStart: Int64?
  private var runFrames = 0
  private var lastDecode: Int64?

  static let rates: [Double] = [24, 25, 30, 48, 50, 60, 120, 24000.0 / 1001, 30000.0 / 1001, 60000.0 / 1001]

  init() {}

  /// Learns from a frame's decode time (these come in order).
  mutating func learn(decodeTime dts: Int64) {
    defer { lastDecode = dts }
    guard let last = lastDecode, dts > last, dts - last < 9000 else {
      runStart = dts
      runFrames = 0
      return
    }
    runFrames += 1
    // The average over the whole run: millisecond rounding is worth under a millisecond in all.
    guard let start = runStart, runFrames >= 20 else { return }
    let average = Double(dts - start) / Double(runFrames)
    // How close counts as a match: two milliseconds of rounding over the run, so 60 and 59.94
    // (a tenth of a percent apart) are told apart once the run is a few seconds long.
    let tolerance = 0.0003 + 180 / Double(dts - start)
    // The current rate stays while it fits (no flipping between close ones).
    if let nominal, abs(nominal - average) / nominal < tolerance { return }
    let match = Self.rates.map { 90_000 / $0 }.min { abs($0 - average) < abs($1 - average) }
    if let match, abs(match - average) / match < tolerance {
      if nominal != match { base = nil }
      nominal = match
    } else if runFrames >= 60 {
      nominal = nil
      base = nil
    }
  }

  /// A time on the grid (as is, until the rate is known).
  mutating func snap(_ time: Int64) -> Int64 {
    guard let nominal else { return time }
    guard let base else {
      self.base = time
      return time
    }
    let steps = (Double(time - base) / nominal).rounded()
    let snapped = base + Int64((steps * nominal).rounded())
    if Double(abs(snapped - time)) > nominal / 3 {
      // Off the grid (a jump, a new rendition): a new grid from here.
      self.base = time
      return time
    }
    return snapped
  }

  mutating func reset() {
    self = FrameGrid()
  }
}

// MARK: - Which segments to fetch

/// Decides, from each new playlist, which segments to fetch next and in what order: every
/// segment once, including the ones still being made (Twitch's prefetch hints, fetched while they
/// download in real time), and no further back than `startBack` segments when starting.
struct LiveSegmentPlanner {
  struct Planned: Equatable {
    var sequence: Int
    var uri: String
    /// Still being made (a prefetch hint): it downloads in real time.
    var live: Bool
    var discontinuity: Bool
    var programDate: Date?
    /// The fragmented MP4 initialization segment (#EXT-X-MAP) in force, if the stream has one.
    var mapURI: String? = nil
  }

  /// How many complete segments before the newest to start from.
  var startBack = 1
  private(set) var nextSequence: Int?

  init(startBack: Int = 1) {
    self.startBack = startBack
  }

  /// The segments to fetch from this playlist, in order.
  mutating func plan(_ text: String) -> [Planned] {
    var mediaSequence = 0
    var segments: [Planned] = []
    var pendingDiscontinuity = false
    var pendingDate: Date?
    var prefetch: [String] = []
    var map: String?
    for raw in HLS.lines(text) {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("#EXT-X-MAP:") {
        map = HLS.attributes(Substring(line))["URI"]
      } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
        mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
      } else if line.hasPrefix("#EXT-X-DISCONTINUITY"), !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
        pendingDiscontinuity = true
      } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
        pendingDate = HLSDate.parse(String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count)))
      } else if line.hasPrefix("#EXT-X-TWITCH-PREFETCH:") {
        prefetch.append(String(line.dropFirst("#EXT-X-TWITCH-PREFETCH:".count)))
      } else if !line.isEmpty, !line.hasPrefix("#") {
        segments.append(
          Planned(
            sequence: mediaSequence + segments.count, uri: line, live: false, discontinuity: pendingDiscontinuity,
            programDate: pendingDate, mapURI: map))
        pendingDiscontinuity = false
        pendingDate = nil
      }
    }
    // The prefetch hints follow the last complete segment, two seconds apart.
    let lastDate = segments.last?.programDate
    for (index, uri) in prefetch.enumerated() {
      segments.append(
        Planned(
          sequence: mediaSequence + segments.count, uri: uri, live: true, discontinuity: false,
          programDate: lastDate.map { $0.addingTimeInterval(2 * Double(index + 1)) }, mapURI: map))
    }
    guard !segments.isEmpty else { return [] }
    let completeCount = segments.count - prefetch.count
    if nextSequence == nil {
      // Starting: a little behind the newest complete one, then everything after it.
      let start = max(0, completeCount - 1 - startBack)
      nextSequence = segments[min(start, segments.count - 1)].sequence
    }
    guard let next = nextSequence else { return [] }
    if next < segments[0].sequence {
      // Fell further behind than the playlist reaches: carry on from its start.
      nextSequence = segments[0].sequence
    }
    let wanted = segments.filter { $0.sequence >= (nextSequence ?? 0) }
    if let last = wanted.last { nextSequence = last.sequence + 1 }
    return wanted
  }
}
