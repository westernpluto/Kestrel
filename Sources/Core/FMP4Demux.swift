// Kestrel's own player: unpacking fragmented MP4 (CMAF) segments.
//
// Twitch is moving channels from MPEG-TS to fragmented MP4 (H.264 included): the playlist names
// an initialization segment (#EXT-X-MAP: the tracks, with the decoder's configuration in avcC and
// esds), and each media segment is a run of small fragments, each a moof (where its samples are
// and their times) followed by an mdat (the samples), so a segment still being made can be shown
// fragment by fragment as it arrives. This turns them into the same frames as TSDemuxer: video in
// Annex B form with the parameter sets in front of each keyframe, AAC frames with their config,
// times on a 90 kHz clock, so the player doesn't care which container a channel uses.

import Foundation

/// The tracks of an initialization segment.
struct FMP4Init: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case h264(sps: [Data], pps: [Data], lengthSize: Int)
    case hevc(parameterSets: [Data], lengthSize: Int)
    case av1(AV1Config)
    case aac(ADTS.Config)
    case other
  }

  struct Track: Equatable, Sendable {
    var id: UInt32
    var timescale: UInt32
    var kind: Kind
    /// trex defaults.
    var defaultDuration: UInt32 = 0
    var defaultSize: UInt32 = 0
    var defaultFlags: UInt32 = 0
  }

  var tracks: [UInt32: Track]

  static func parse(_ data: Data) -> FMP4Init? {
    let d = Data(data)
    var tracks: [UInt32: Track] = [:]
    var defaults: [UInt32: (UInt32, UInt32, UInt32)] = [:]
    guard let moov = MP4.boxes(d, 0, d.count).first(where: { $0.type == "moov" }) else { return nil }
    for box in MP4.boxes(d, moov.body, moov.end) {
      if box.type == "trak", let track = parseTrack(d, box) { tracks[track.id] = track }
      if box.type == "mvex" {
        for trex in MP4.boxes(d, box.body, box.end) where trex.type == "trex" && trex.end - trex.body >= 24 {
          let b = trex.body + 4
          defaults[MP4.u32(d, b)] = (MP4.u32(d, b + 8), MP4.u32(d, b + 12), MP4.u32(d, b + 16))
        }
      }
    }
    for (id, value) in defaults where tracks[id] != nil {
      tracks[id]!.defaultDuration = value.0
      tracks[id]!.defaultSize = value.1
      tracks[id]!.defaultFlags = value.2
    }
    return tracks.isEmpty ? nil : FMP4Init(tracks: tracks)
  }

  private static func parseTrack(_ d: Data, _ trak: MP4.Box) -> Track? {
    var id: UInt32?
    var timescale: UInt32 = 90_000
    var kind: Kind = .other
    for box in MP4.boxes(d, trak.body, trak.end) {
      if box.type == "tkhd" {
        let version = d[box.body]
        id = MP4.u32(d, box.body + (version == 1 ? 20 : 12))
      } else if box.type == "mdia" {
        for inner in MP4.boxes(d, box.body, box.end) {
          if inner.type == "mdhd" {
            let version = d[inner.body]
            timescale = MP4.u32(d, inner.body + (version == 1 ? 20 : 12))
          } else if inner.type == "minf", let stbl = MP4.boxes(d, inner.body, inner.end).first(where: { $0.type == "stbl" }),
            let stsd = MP4.boxes(d, stbl.body, stbl.end).first(where: { $0.type == "stsd" })
          {
            kind = parseSampleEntry(d, stsd)
          }
        }
      }
    }
    guard let id else { return nil }
    return Track(id: id, timescale: timescale, kind: kind)
  }

  private static func parseSampleEntry(_ d: Data, _ stsd: MP4.Box) -> Kind {
    // Full box header (4) and entry count (4), then the entries.
    guard let entry = MP4.boxes(d, stsd.body + 8, stsd.end).first else { return .other }
    switch entry.type {
    case "avc1", "avc3":
      // A visual sample entry's fields take 78 bytes before its boxes.
      guard let avcC = MP4.boxes(d, entry.body + 78, entry.end).first(where: { $0.type == "avcC" }) else { return .other }
      return parseAVCC(d, avcC.body, avcC.end)
    case "hvc1", "hev1":
      guard let hvcC = MP4.boxes(d, entry.body + 78, entry.end).first(where: { $0.type == "hvcC" }) else { return .other }
      return parseHVCC(d, hvcC.body, hvcC.end)
    case "av01":
      guard let av1C = MP4.boxes(d, entry.body + 78, entry.end).first(where: { $0.type == "av1C" }), av1C.end > av1C.body
      else { return .other }
      // The visual sample entry's width and height (16 bits each, 24 bytes in).
      let width = Int(d[entry.body + 24]) << 8 | Int(d[entry.body + 25])
      let height = Int(d[entry.body + 26]) << 8 | Int(d[entry.body + 27])
      return .av1(AV1Config(record: d.subdata(in: av1C.body..<av1C.end), width: width, height: height))
    case "mp4a":
      // An audio sample entry's fields take 28 bytes before its boxes.
      guard let esds = MP4.boxes(d, entry.body + 28, entry.end).first(where: { $0.type == "esds" }),
        let config = MP4.audioSpecificConfig(inESDS: d, esds.body + 4, esds.end)
      else { return .other }
      return .aac(config)
    default:
      return .other
    }
  }

  static func parseAVCC(_ d: Data, _ start: Int, _ end: Int) -> Kind {
    guard end - start >= 7 else { return .other }
    let lengthSize = Int(d[start + 4] & 0x03) + 1
    var i = start + 5
    var sps: [Data] = []
    var pps: [Data] = []
    let spsCount = Int(d[i] & 0x1F)
    i += 1
    for _ in 0..<spsCount where i + 2 <= end {
      let n = Int(MP4.u16(d, i))
      i += 2
      guard i + n <= end else { break }
      sps.append(d[i..<(i + n)])
      i += n
    }
    if i < end {
      let ppsCount = Int(d[i])
      i += 1
      for _ in 0..<ppsCount where i + 2 <= end {
        let n = Int(MP4.u16(d, i))
        i += 2
        guard i + n <= end else { break }
        pps.append(d[i..<(i + n)])
        i += n
      }
    }
    return .h264(sps: sps.map { Data($0) }, pps: pps.map { Data($0) }, lengthSize: lengthSize)
  }

  static func parseHVCC(_ d: Data, _ start: Int, _ end: Int) -> Kind {
    guard end - start >= 23 else { return .other }
    let lengthSize = Int(d[start + 21] & 0x03) + 1
    var i = start + 23
    var sets: [Data] = []
    let arrays = Int(d[start + 22])
    for _ in 0..<arrays where i + 3 <= end {
      let count = Int(MP4.u16(d, i + 1))
      i += 3
      for _ in 0..<count where i + 2 <= end {
        let n = Int(MP4.u16(d, i))
        i += 2
        guard i + n <= end else { break }
        sets.append(Data(d[i..<(i + n)]))
        i += n
      }
    }
    return .hevc(parameterSets: sets, lengthSize: lengthSize)
  }
}

/// Unpacks a fragmented MP4 segment fed in pieces of any size: each fragment's frames come out
/// once its mdat is complete.
struct FMP4Demuxer {
  let initSegment: FMP4Init
  private var buffer = Data()
  /// Bytes of the stream before `buffer`'s start.
  private var consumed = 0
  /// The current fragment's samples (from its moof), waiting for its mdat.
  private var pending: [Sample] = []

  private struct Sample {
    var track: FMP4Init.Track
    /// Position in the stream.
    var offset: Int
    var size: Int
    var decode: Int64
    var composition: Int64
    var sync: Bool
  }

  init(initSegment: FMP4Init) {
    self.initSegment = initSegment
  }

  mutating func feed(_ bytes: Data) -> [DemuxedFrame] {
    buffer.append(bytes)
    var out: [DemuxedFrame] = []
    while buffer.count >= 8 {
      let d = buffer
      var size = Int(MP4.u32(d, d.startIndex))
      let type = MP4.type(d, d.startIndex + 4)
      var header = 8
      if size == 1 {
        guard d.count >= 16 else { break }
        size = Int(MP4.u64(d, d.startIndex + 8))
        header = 16
      }
      guard size >= header else {
        // Not a box: give up on what's buffered.
        buffer = Data()
        break
      }
      guard d.count >= size else { break }
      let box = Data(d.prefix(size))
      let start = consumed
      if type == "moof" {
        pending = parseMoof(box, streamStart: start)
      } else if type == "mdat" {
        out += frames(fromMdat: box, streamStart: start, header: header)
        pending = []
      }
      buffer = Data(d.dropFirst(size))
      consumed += size
    }
    return out
  }

  mutating func flush() -> [DemuxedFrame] {
    buffer = Data()
    pending = []
    return []
  }

  private func parseMoof(_ box: Data, streamStart: Int) -> [Sample] {
    var samples: [Sample] = []
    for traf in MP4.boxes(box, 8, box.count) where traf.type == "traf" {
      var track: FMP4Init.Track?
      var base = streamStart  // default-base-is-moof (what CMAF uses)
      var defaultDuration: UInt32 = 0
      var defaultSize: UInt32 = 0
      var defaultFlags: UInt32 = 0
      var decode: Int64 = 0
      for inner in MP4.boxes(box, traf.body, traf.end) {
        switch inner.type {
        case "tfhd":
          let flags = MP4.u32(box, inner.body) & 0xFFFFFF
          var i = inner.body + 4
          let id = MP4.u32(box, i)
          i += 4
          track = initSegment.tracks[id]
          defaultDuration = track?.defaultDuration ?? 0
          defaultSize = track?.defaultSize ?? 0
          defaultFlags = track?.defaultFlags ?? 0
          if flags & 0x01 != 0 {
            base = Int(MP4.u64(box, i))
            i += 8
          }
          if flags & 0x02 != 0 { i += 4 }
          if flags & 0x08 != 0 {
            defaultDuration = MP4.u32(box, i)
            i += 4
          }
          if flags & 0x10 != 0 {
            defaultSize = MP4.u32(box, i)
            i += 4
          }
          if flags & 0x20 != 0 { defaultFlags = MP4.u32(box, i) }
        case "tfdt":
          let version = box[inner.body]
          decode = version == 1 ? Int64(bitPattern: MP4.u64(box, inner.body + 4)) : Int64(MP4.u32(box, inner.body + 4))
        case "trun":
          guard let track else { continue }
          let version = box[inner.body]
          let flags = MP4.u32(box, inner.body) & 0xFFFFFF
          let count = Int(MP4.u32(box, inner.body + 4))
          var i = inner.body + 8
          var dataOffset = 0
          if flags & 0x01 != 0 {
            dataOffset = Int(Int32(bitPattern: MP4.u32(box, i)))
            i += 4
          }
          var firstFlags: UInt32?
          if flags & 0x04 != 0 {
            firstFlags = MP4.u32(box, i)
            i += 4
          }
          var offset = base + dataOffset
          for n in 0..<count {
            var duration = defaultDuration
            var size = defaultSize
            var sampleFlags = n == 0 ? (firstFlags ?? defaultFlags) : defaultFlags
            var cto: Int64 = 0
            if flags & 0x100 != 0 {
              duration = MP4.u32(box, i)
              i += 4
            }
            if flags & 0x200 != 0 {
              size = MP4.u32(box, i)
              i += 4
            }
            if flags & 0x400 != 0 {
              sampleFlags = MP4.u32(box, i)
              i += 4
            }
            if flags & 0x800 != 0 {
              let raw = MP4.u32(box, i)
              cto = version == 0 ? Int64(raw) : Int64(Int32(bitPattern: raw))
              i += 4
            }
            // sample_is_non_sync_sample is bit 16 of the flags.
            samples.append(
              Sample(track: track, offset: offset, size: Int(size), decode: decode, composition: decode + cto, sync: sampleFlags & 0x10000 == 0))
            offset += Int(size)
            decode += Int64(duration)
          }
        default:
          break
        }
      }
    }
    return samples
  }

  /// A time in a track's timescale on the 90 kHz clock (without overflowing for large times).
  static func to90k(_ value: Int64, _ timescale: UInt32) -> Int64 {
    let scale = Int64(max(1, timescale))
    if scale == 90_000 { return value }
    return value / scale * 90_000 + value % scale * 90_000 / scale
  }

  private func frames(fromMdat box: Data, streamStart: Int, header: Int) -> [DemuxedFrame] {
    var out: [DemuxedFrame] = []
    for sample in pending {
      let start = sample.offset - streamStart
      guard start >= header, start + sample.size <= box.count, sample.size > 0 else { continue }
      let bytes = box.subdata(in: start..<(start + sample.size))
      let pts = Self.to90k(sample.composition, sample.track.timescale)
      let dts = Self.to90k(sample.decode, sample.track.timescale)
      switch sample.track.kind {
      case .h264(let sps, let pps, let lengthSize):
        var annexB = Data()
        var units = MP4.lengthPrefixedUnits(bytes, lengthSize: lengthSize)
        let keyframe = sample.sync || units.contains { H264.type($0) == 5 }
        // The parameter sets live in the init segment: put them in front of each keyframe, as
        // they are in a transport stream.
        if keyframe, !units.contains(where: { H264.type($0) == 7 }) { units = sps + pps + units }
        for unit in units { annexB.append(contentsOf: [0, 0, 0, 1]); annexB.append(unit) }
        out.append(.video(VideoFrame(codec: .h264, pts: pts, dts: dts, data: annexB, isKeyframe: keyframe)))
      case .hevc(let sets, let lengthSize):
        var annexB = Data()
        var units = MP4.lengthPrefixedUnits(bytes, lengthSize: lengthSize)
        let keyframe = sample.sync || units.contains { (16...21).contains(HEVC.type($0)) }
        if keyframe, !units.contains(where: { HEVC.type($0) == 32 }) { units = sets + units }
        for unit in units { annexB.append(contentsOf: [0, 0, 0, 1]); annexB.append(unit) }
        out.append(.video(VideoFrame(codec: .hevc, pts: pts, dts: dts, data: annexB, isKeyframe: keyframe)))
      case .av1(let config):
        // As stored (OBUs with sizes): what the decoder takes. The keyframe flag comes from trun.
        out.append(.video(VideoFrame(codec: .av1, pts: pts, dts: dts, data: bytes, isKeyframe: sample.sync, av1: config)))
      case .aac(let config):
        out.append(.audio(AudioFrame(pts: pts, data: bytes, config: config)))
      case .other:
        break
      }
    }
    // (In decode order, as stored: each track's frames in the order the decoder takes them.)
    return out
  }
}

/// Reading MP4 boxes.
enum MP4 {
  struct Box {
    var type: String
    var start: Int
    var body: Int
    var end: Int
  }

  static func u16(_ d: Data, _ i: Int) -> UInt16 { UInt16(d[i]) << 8 | UInt16(d[i + 1]) }
  static func u32(_ d: Data, _ i: Int) -> UInt32 {
    UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
  }
  static func u64(_ d: Data, _ i: Int) -> UInt64 { UInt64(u32(d, i)) << 32 | UInt64(u32(d, i + 4)) }
  static func type(_ d: Data, _ i: Int) -> String { String(decoding: d[i..<(i + 4)], as: UTF8.self) }

  /// The boxes between `start` and `end` (indexes into `d`).
  static func boxes(_ d: Data, _ start: Int, _ end: Int) -> [Box] {
    var out: [Box] = []
    var i = start
    while i + 8 <= end {
      var size = Int(u32(d, i))
      var header = 8
      if size == 1, i + 16 <= end {
        size = Int(u64(d, i + 8))
        header = 16
      } else if size == 0 {
        size = end - i
      }
      guard size >= header, i + size <= end else { break }
      out.append(Box(type: type(d, i + 4), start: i, body: i + header, end: i + size))
      i += size
    }
    return out
  }

  /// NAL units behind lengths of `lengthSize` bytes.
  static func lengthPrefixedUnits(_ sample: Data, lengthSize: Int) -> [Data] {
    let d = Data(sample)
    var units: [Data] = []
    var i = 0
    while i + lengthSize <= d.count {
      var n = 0
      for k in 0..<lengthSize { n = n << 8 | Int(d[i + k]) }
      i += lengthSize
      guard n > 0, i + n <= d.count else { break }
      units.append(d.subdata(in: i..<(i + n)))
      i += n
    }
    return units
  }

  /// An esds box's AudioSpecificConfig, read as an ADTS config (object type, rate, channels).
  static func audioSpecificConfig(inESDS d: Data, _ start: Int, _ end: Int) -> ADTS.Config? {
    // Walk the descriptors to DecoderSpecificInfo (tag 5).
    var i = start
    func length(_ i: inout Int) -> Int {
      var n = 0
      for _ in 0..<4 where i < end {
        let b = d[i]
        i += 1
        n = n << 7 | Int(b & 0x7F)
        if b & 0x80 == 0 { break }
      }
      return n
    }
    while i < end {
      let tag = d[i]
      i += 1
      let n = length(&i)
      switch tag {
      case 0x03: i += 3  // ES_ID, flags
      case 0x04: i += 13  // object type, stream type, buffer, bitrates
      case 0x05:
        guard n >= 2, i + 2 <= end else { return nil }
        let value = Int(d[i]) << 8 | Int(d[i + 1])
        return ADTS.Config(objectType: value >> 11, sampleRateIndex: value >> 7 & 0x0F, channels: value >> 3 & 0x0F)
      default: i += n
      }
    }
    return nil
  }
}

/// Picks the demuxer for a segment from its first bytes: MPEG-TS (sync byte 0x47) or fragmented
/// MP4 (needs its init segment).
enum SegmentDemuxer {
  case ts(TSDemuxer)
  case mp4(FMP4Demuxer)

  static func isTransportStream(_ first: Data) -> Bool { first.first == 0x47 }

  /// MPEG-TS: how far a segment's picture and sound reach so far, and where they start (see
  /// TSDemuxer.reach); nil for fragmented MP4.
  var transportReach: (video: Int64?, audioEnd: Int64?)? {
    if case .ts(let demuxer) = self { return demuxer.reach() }
    return nil
  }

  var transportStart: (video: Int64?, audio: Int64?)? {
    if case .ts(let demuxer) = self { return demuxer.start() }
    return nil
  }

  /// Whether a segment that reaches `end` runs right up to one that starts at `next`: the picture
  /// to within a couple of frames (`frame`, 90 kHz), the sound to within one of its frames (about
  /// 2,100 ticks). Nil when it can't be told (a stream missing on either side).
  static func joins(
    end: (video: Int64?, audioEnd: Int64?), next: (video: Int64?, audio: Int64?), frame: Int64
  ) -> Bool? {
    var verdicts: [Bool] = []
    if let last = end.video, let first = next.video {
      let gap = first - last
      verdicts.append(gap >= -frame && gap <= 2 * frame)
    }
    if let last = end.audioEnd, let first = next.audio {
      let gap = first - last
      verdicts.append(abs(gap) <= 2100)
    }
    return verdicts.isEmpty ? nil : verdicts.allSatisfy { $0 }
  }

  mutating func feed(_ data: Data) -> [DemuxedFrame] {
    switch self {
    case .ts(var demuxer):
      let out = demuxer.feed(data)
      self = .ts(demuxer)
      return out
    case .mp4(var demuxer):
      let out = demuxer.feed(data)
      self = .mp4(demuxer)
      return out
    }
  }

  mutating func flush() -> [DemuxedFrame] {
    switch self {
    case .ts(var demuxer):
      let out = demuxer.flush()
      self = .ts(demuxer)
      return out
    case .mp4(var demuxer):
      let out = demuxer.flush()
      self = .mp4(demuxer)
      return out
    }
  }
}
