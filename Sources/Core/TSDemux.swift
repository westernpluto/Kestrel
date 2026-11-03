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
      if let kind = streams[pid] { pes(data, kind: kind, into: &out) }
    }
    pending = [:]
    leftover = Data()
    return out.sorted { $0.pts < $1.pts }
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
      if let previous = pending[pid], !previous.isEmpty { pes(previous, kind: kind, into: &out) }
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

  /// A 33-bit PES timestamp.
  private static func timestamp(_ d: Data, _ i: Int) -> Int64 {
    Int64(d[i] >> 1 & 0x07) << 30 | Int64(d[i + 1]) << 22 | Int64(d[i + 2] >> 1) << 15 | Int64(d[i + 3]) << 7
      | Int64(d[i + 4] >> 1)
  }

  private func pes(_ raw: Data, kind: Kind, into out: inout [DemuxedFrame]) {
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
    case .h264:
      out.append(.video(VideoFrame(codec: .h264, pts: pts, dts: dts, data: Data(body), isKeyframe: H264.isKeyframe(body))))
    case .hevc:
      out.append(.video(VideoFrame(codec: .hevc, pts: pts, dts: dts, data: Data(body), isKeyframe: HEVC.isKeyframe(body))))
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
  /// The latest time handed out (on the timeline) and its frame's length.
  private(set) var lastTime: Int64?
  private var frameLength: Int64 = 3000
  /// The first segment's first time: the timeline starts there.
  private(set) var origin: Int64?

  init() {}

  /// A segment begins; `discontinuity` when the playlist marks one (or it doesn't follow on).
  mutating func beginSegment(firstPTS: Int64, discontinuity: Bool) {
    guard let last = lastTime else {
      origin = firstPTS
      return
    }
    let mapped = firstPTS + offset
    // A jump of more than a few seconds either way is a discontinuity even when unmarked.
    if discontinuity || abs(mapped - last) > 5 * 90_000 {
      offset = last + frameLength - firstPTS
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
    if isVideo, let last = lastTime, time > last, time - last < 9000 { frameLength = time - last }
    if lastTime.map({ time > $0 }) ?? true { lastTime = time }
    return time
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
    for raw in HLS.lines(text) {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
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
            programDate: pendingDate))
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
          programDate: lastDate.map { $0.addingTimeInterval(2 * Double(index + 1)) }))
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
