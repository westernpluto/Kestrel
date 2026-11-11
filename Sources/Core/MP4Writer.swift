// Turns one segment's frames (H.264 video and AAC audio, as TSDemuxer unpacks them) into a small,
// self-contained MP4 file.
//
// For Apple Watch: watchOS has AVPlayer but no picture layer to feed frames to (the iPhone's
// player draws on an AVSampleBufferDisplayLayer) and no live HLS video, and it does play local MP4
// files. So the watch's player downloads each two-second segment, rewrites it here, and queues the
// files back to back. Twitch's segments each start on a keyframe, so every file plays on its own.
//
// The layout is the plain one: ftyp, then moov (one video track, one audio track, all of each in
// one chunk), then mdat with the video's samples followed by the audio's.

import Foundation

enum MP4Writer {
  /// The movie's clock (and the video track's): 90 kHz, as the stream's own times.
  static let movieTimescale: UInt32 = 90_000

  /// What's needed to write one segment.
  struct Segment {
    var video: [VideoFrame]
    var audio: [AudioFrame]
    /// The sound frame just before this file's (the end of the previous file): written first and
    /// edited out of what plays, so the AAC decoder starts already warmed up. Started cold, each
    /// file's first moment of sound came out wrong: a little click at every join between files.
    var audioPrimer: AudioFrame? = nil
  }

  /// The MP4 file for one segment, or nil when it has no H.264 keyframe with its parameter sets
  /// (nothing before the first keyframe can be shown).
  static func file(_ segment: Segment) -> Data? {
    // Video from the first keyframe on.
    guard let firstKey = segment.video.firstIndex(where: { $0.isKeyframe && $0.codec == .h264 }) else { return nil }
    let frames = segment.video[firstKey...].filter { $0.codec == .h264 }
    guard let sets = frames.lazy.compactMap({ H264.parameterSets(AnnexB.units($0.data)) }).first else { return nil }
    let size = H264.pictureSize(sps: sets.sps) ?? (width: 640, height: 360)

    // Samples in decode order, length-prefixed; each one's duration from the next's decode time.
    let videoSamples = frames.map { H264.sample(AnnexB.units($0.data)) }
    let ordered = Array(frames)
    var durations: [UInt32] = []
    for i in ordered.indices {
      if i + 1 < ordered.count {
        durations.append(UInt32(clamping: max(1, ordered[i + 1].dts - ordered[i].dts)))
      } else {
        durations.append(durations.last ?? 3000)
      }
    }
    let offsets = ordered.map { UInt32(clamping: max(0, $0.pts - $0.dts)) }
    let keyframes = ordered.indices.filter { ordered[$0].isKeyframe }.map { UInt32($0 + 1) }

    let audio = segment.audio
    let audioConfig = audio.first?.config
    // (Only one in the same format.)
    let primer = segment.audioPrimer.flatMap { $0.config == audioConfig ? $0 : nil }
    let audioSamples = (primer.map { [$0] } ?? []) + audio
    let audioRate = UInt32(audioConfig?.sampleRate ?? 48_000)

    // The movie starts with the sound's first frame. Files are played one after another, and each
    // one's sound carries on exactly where the last one's ended; started at the picture instead
    // (Twitch's is a little ahead of its sound in each segment, 14 ms or so), every file began with
    // a moment of silence: a blip in the sound at every join. Picture from before then is edited
    // out (decoded, not shown); a picture that starts later waits with an empty edit.
    let videoStart = ordered.map(\.pts).min() ?? 0
    let audioStart = audio.first?.pts
    let base = audioStart ?? videoStart
    let videoMediaDuration = durations.reduce(0) { $0 + UInt64($1) }
    let videoEnd = (ordered.map(\.pts).max() ?? videoStart) + Int64(durations.last ?? 3000)
    let videoShown = UInt32(clamping: max(0, videoEnd - max(videoStart, base)))
    // Where the shown picture starts in the track's own timeline (decode times from the first
    // frame's, plus its composition offset).
    let videoMediaStart = UInt32(clamping: max(videoStart, base) - (ordered.first?.dts ?? videoStart))
    let audioMediaDuration = UInt64(audioSamples.count) * 1024  // in the audio track's own clock (its rate)
    let audioShown = UInt32(clamping: UInt64(audio.count) * 1024 * UInt64(movieTimescale) / UInt64(audioRate))
    let videoDelay = UInt32(clamping: max(0, videoStart - base))
    let audioDelay = UInt32(clamping: (audioStart ?? base) - base)
    let movieDuration = max(videoDelay + videoShown, audio.isEmpty ? 0 : audioDelay + audioShown)

    let videoBytes = videoSamples.reduce(0) { $0 + $1.count }
    func moov(mdatStart: UInt32) -> Data {
      let videoChunk = mdatStart
      let audioChunk = mdatStart + UInt32(videoBytes)
      var tracks = Data()
      tracks += videoTrack(
        id: 1, width: size.width, height: size.height, sps: sets.sps, pps: sets.pps, sizes: videoSamples.map { UInt32($0.count) },
        durations: durations, offsets: offsets, keyframes: keyframes, chunk: videoChunk,
        mediaDuration: UInt32(clamping: videoMediaDuration), shown: videoShown, delay: videoDelay, mediaStart: videoMediaStart)
      if let audioConfig, !audio.isEmpty {
        tracks += audioTrack(
          id: 2, config: audioConfig, sizes: audioSamples.map { UInt32($0.data.count) }, chunk: audioChunk,
          mediaDuration: UInt32(clamping: audioMediaDuration), shown: audioShown, delay: audioDelay,
          mediaStart: primer == nil ? 0 : 1024)
      }
      return box("moov", mvhd(duration: movieDuration, nextTrack: 3) + tracks)
    }

    let ftyp = box("ftyp", ascii("isom") + u32(0x200) + ascii("isom") + ascii("iso2") + ascii("avc1") + ascii("mp41"))
    // The moov's size doesn't depend on the offsets in it: written once to measure, then for real.
    let measured = moov(mdatStart: 0)
    let mdatStart = UInt32(ftyp.count + measured.count + 8)
    var out = ftyp
    out += moov(mdatStart: mdatStart)
    let mdatSize = 8 + videoBytes + audioSamples.reduce(0) { $0 + $1.data.count }
    out += u32(UInt32(mdatSize)) + ascii("mdat")
    for sample in videoSamples { out += sample }
    for frame in audioSamples { out += frame.data }
    return out
  }

  // MARK: Tracks

  private static func videoTrack(
    id: UInt32, width: Int, height: Int, sps: Data, pps: Data, sizes: [UInt32], durations: [UInt32], offsets: [UInt32],
    keyframes: [UInt32], chunk: UInt32, mediaDuration: UInt32, shown: UInt32, delay: UInt32, mediaStart: UInt32
  ) -> Data {
    var avcC = Data([1, sps.count > 1 ? sps[sps.startIndex + 1] : 66, sps.count > 2 ? sps[sps.startIndex + 2] : 0,
      sps.count > 3 ? sps[sps.startIndex + 3] : 30, 0xFF, 0xE1])
    avcC += u16(UInt16(sps.count)) + sps + Data([1]) + u16(UInt16(pps.count)) + pps
    var entry = Data(count: 6) + u16(1)  // reserved, data reference index
    entry += Data(count: 16)  // pre-defined and reserved
    entry += u16(UInt16(clamping: width)) + u16(UInt16(clamping: height))
    entry += u32(0x0048_0000) + u32(0x0048_0000) + u32(0) + u16(1)  // 72 dpi, reserved, one frame per sample
    entry += Data(count: 32)  // compressor name
    entry += u16(0x0018) + u16(0xFFFF)  // depth, pre-defined
    entry += box("avcC", avcC)
    let stsd = fullBox("stsd", payload: u32(1) + box("avc1", entry))

    var stbl = stsd + stts(durations)
    if offsets.contains(where: { $0 != 0 }) { stbl += ctts(offsets) }
    stbl += fullBox("stss", payload: u32(UInt32(keyframes.count)) + keyframes.reduce(Data()) { $0 + u32($1) })
    stbl += stsc(samples: UInt32(sizes.count)) + stsz(sizes) + fullBox("stco", payload: u32(1) + u32(chunk))
    let minf = box(
      "minf", fullBox("vmhd", flags: 1, payload: Data(count: 8)) + dinf() + box("stbl", stbl))
    let mdia = box(
      "mdia", mdhd(timescale: movieTimescale, duration: mediaDuration) + hdlr("vide", name: "Kestrel video") + minf)
    let edits = elst(delay: delay, shown: shown, mediaStart: mediaStart)
    return box(
      "trak", tkhd(id: id, duration: delay + shown, volume: 0, width: width, height: height) + edits + mdia)
  }

  private static func audioTrack(
    id: UInt32, config: ADTS.Config, sizes: [UInt32], chunk: UInt32, mediaDuration: UInt32, shown: UInt32, delay: UInt32,
    mediaStart: UInt32
  ) -> Data {
    let channels = UInt16(max(1, min(config.channels, 2)))
    let rate = UInt32(config.sampleRate)
    var entry = Data(count: 6) + u16(1)
    entry += Data(count: 8)  // reserved
    entry += u16(channels) + u16(16) + u16(0) + u16(0) + u32(rate << 16)
    entry += esds(config.audioSpecificConfig)
    let stsd = fullBox("stsd", payload: u32(1) + box("mp4a", entry))
    let stbl = stsd + stts(Array(repeating: 1024, count: sizes.count)) + stsc(samples: UInt32(sizes.count)) + stsz(sizes)
      + fullBox("stco", payload: u32(1) + u32(chunk))
    let minf = box("minf", fullBox("smhd", payload: Data(count: 4)) + dinf() + box("stbl", stbl))
    let mdia = box("mdia", mdhd(timescale: rate, duration: mediaDuration) + hdlr("soun", name: "Kestrel audio") + minf)
    let edits = elst(delay: delay, shown: shown, mediaStart: mediaStart)
    return box("trak", tkhd(id: id, duration: delay + shown, volume: 0x0100, width: 0, height: 0) + edits + mdia)
  }

  /// The AAC decoder's configuration (an MPEG-4 elementary stream descriptor).
  static func esds(_ audioSpecificConfig: Data) -> Data {
    func descriptor(_ tag: UInt8, _ body: Data) -> Data {
      // The size in the four-byte form (0x80 continuation bytes), as most writers do.
      let n = body.count
      return Data([tag, 0x80 | UInt8((n >> 21) & 0x7F), 0x80 | UInt8((n >> 14) & 0x7F), 0x80 | UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
        + body
    }
    let specific = descriptor(5, audioSpecificConfig)
    // AAC (0x40), an audio stream (5 << 2 | 1), no buffer size or bitrates given.
    let decoderConfig = descriptor(4, Data([0x40, 0x15, 0, 0, 0]) + u32(0) + u32(0) + specific)
    let sl = descriptor(6, Data([2]))
    let es = descriptor(3, u16(1) + Data([0]) + decoderConfig + sl)
    return fullBox("esds", payload: es)
  }

  // MARK: Boxes

  private static func mvhd(duration: UInt32, nextTrack: UInt32) -> Data {
    var p = u32(0) + u32(0) + u32(movieTimescale) + u32(duration)
    p += u32(0x0001_0000) + u16(0x0100) + Data(count: 10)  // rate 1, volume 1, reserved
    p += matrix + Data(count: 24) + u32(nextTrack)
    return fullBox("mvhd", payload: p)
  }

  private static func tkhd(id: UInt32, duration: UInt32, volume: UInt16, width: Int, height: Int) -> Data {
    var p = u32(0) + u32(0) + u32(id) + u32(0) + u32(duration)
    p += Data(count: 8) + u16(0) + u16(0) + u16(volume) + u16(0)
    p += matrix + u32(UInt32(clamping: width) << 16) + u32(UInt32(clamping: height) << 16)
    return fullBox("tkhd", flags: 3, payload: p)  // enabled, in the movie
  }

  private static func mdhd(timescale: UInt32, duration: UInt32) -> Data {
    fullBox("mdhd", payload: u32(0) + u32(0) + u32(timescale) + u32(duration) + u16(0x55C4) + u16(0))  // "und"
  }

  private static func hdlr(_ type: String, name: String) -> Data {
    fullBox("hdlr", payload: u32(0) + ascii(type) + Data(count: 12) + Data(name.utf8) + Data([0]))
  }

  private static func dinf() -> Data {
    box("dinf", fullBox("dref", payload: u32(1) + fullBox("url ", flags: 1, payload: Data())))
  }

  /// An empty edit for a track that starts later than the movie, then the track itself.
  private static func elst(delay: UInt32, shown: UInt32, mediaStart: UInt32) -> Data {
    var entries: [(UInt32, Int32)] = []
    if delay > 0 { entries.append((delay, -1)) }
    entries.append((shown, Int32(clamping: mediaStart)))
    var p = u32(UInt32(entries.count))
    for (duration, start) in entries { p += u32(duration) + u32(UInt32(bitPattern: start)) + u32(0x0001_0000) }
    return box("edts", fullBox("elst", payload: p))
  }

  private static func stts(_ durations: [UInt32]) -> Data {
    var runs: [(count: UInt32, delta: UInt32)] = []
    for d in durations {
      if let last = runs.last, last.delta == d { runs[runs.count - 1].count += 1 } else { runs.append((1, d)) }
    }
    return fullBox("stts", payload: u32(UInt32(runs.count)) + runs.reduce(Data()) { $0 + u32($1.count) + u32($1.delta) })
  }

  private static func ctts(_ offsets: [UInt32]) -> Data {
    var runs: [(count: UInt32, offset: UInt32)] = []
    for o in offsets {
      if let last = runs.last, last.offset == o { runs[runs.count - 1].count += 1 } else { runs.append((1, o)) }
    }
    return fullBox("ctts", payload: u32(UInt32(runs.count)) + runs.reduce(Data()) { $0 + u32($1.count) + u32($1.offset) })
  }

  private static func stsc(samples: UInt32) -> Data {
    fullBox("stsc", payload: u32(1) + u32(1) + u32(samples) + u32(1))
  }

  private static func stsz(_ sizes: [UInt32]) -> Data {
    fullBox("stsz", payload: u32(0) + u32(UInt32(sizes.count)) + sizes.reduce(Data()) { $0 + u32($1) })
  }

  private static let matrix: Data = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000].reduce(Data()) { $0 + u32($1) }

  static func box(_ type: String, _ payload: Data) -> Data {
    u32(UInt32(8 + payload.count)) + ascii(type) + payload
  }

  static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, payload: Data) -> Data {
    box(type, Data([version, UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)]) + payload)
  }

  private static func ascii(_ s: String) -> Data { Data(s.utf8) }
  private static func u16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
  private static func u32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
}

// MARK: - The picture's size, from the SPS

extension H264 {
  /// Width and height in pixels (after cropping), read from a sequence parameter set.
  static func pictureSize(sps: Data) -> (width: Int, height: Int)? {
    var r = BitReader(rbsp: sps.dropFirst())  // past the NAL header
    guard let profile = r.bits(8) else { return nil }
    _ = r.bits(8)  // constraint flags
    _ = r.bits(8)  // level
    _ = r.ue()  // seq_parameter_set_id
    var chroma = 1
    if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
      chroma = r.ue() ?? 1
      if chroma == 3 { _ = r.bits(1) }
      _ = r.ue()  // bit depth luma
      _ = r.ue()  // bit depth chroma
      _ = r.bits(1)
      if r.bits(1) == 1 {
        for i in 0..<(chroma == 3 ? 12 : 8) where r.bits(1) == 1 {
          var last = 8
          var next = 8
          for _ in 0..<(i < 6 ? 16 : 64) where next != 0 {
            next = (last + (r.se() ?? 0) + 256) % 256
            last = next == 0 ? last : next
          }
        }
      }
    }
    _ = r.ue()  // log2_max_frame_num_minus4
    let pocType = r.ue() ?? 0
    if pocType == 0 {
      _ = r.ue()
    } else if pocType == 1 {
      _ = r.bits(1)
      _ = r.se()
      _ = r.se()
      for _ in 0..<(r.ue() ?? 0) { _ = r.se() }
    }
    _ = r.ue()  // max_num_ref_frames
    _ = r.bits(1)
    guard let widthMbs = r.ue(), let heightMaps = r.ue(), let frameMbsOnly = r.bits(1) else { return nil }
    if frameMbsOnly == 0 { _ = r.bits(1) }
    _ = r.bits(1)
    var crop = (left: 0, right: 0, top: 0, bottom: 0)
    if r.bits(1) == 1 {
      crop = (r.ue() ?? 0, r.ue() ?? 0, r.ue() ?? 0, r.ue() ?? 0)
    }
    let subWidth = chroma == 1 || chroma == 2 ? 2 : 1
    let subHeight = chroma == 1 ? 2 : 1
    let cropX = chroma == 0 ? 1 : subWidth
    let cropY = (chroma == 0 ? 1 : subHeight) * (2 - frameMbsOnly)
    let width = (widthMbs + 1) * 16 - cropX * (crop.left + crop.right)
    let height = (2 - frameMbsOnly) * (heightMaps + 1) * 16 - cropY * (crop.top + crop.bottom)
    guard width > 0, height > 0, width < 8192, height < 8192 else { return nil }
    return (width, height)
  }
}

/// Reads bits (and Exp-Golomb numbers) from a NAL unit's payload, emulation-prevention bytes taken
/// out.
struct BitReader {
  private let bytes: [UInt8]
  private var position = 0

  init<S: Sequence>(rbsp: S) where S.Element == UInt8 {
    var out: [UInt8] = []
    var zeros = 0
    for byte in rbsp {
      if zeros >= 2, byte == 3 {
        zeros = 0
        continue
      }
      out.append(byte)
      zeros = byte == 0 ? zeros + 1 : 0
    }
    bytes = out
  }

  mutating func bits(_ count: Int) -> Int? {
    var value = 0
    for _ in 0..<count {
      guard position < bytes.count * 8 else { return nil }
      let bit = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
      value = value << 1 | Int(bit)
      position += 1
    }
    return value
  }

  mutating func ue() -> Int? {
    var zeros = 0
    while let bit = bits(1), bit == 0 {
      zeros += 1
      if zeros > 31 { return nil }
    }
    guard zeros > 0 else { return 0 }
    guard let rest = bits(zeros) else { return nil }
    return (1 << zeros) - 1 + rest
  }

  mutating func se() -> Int? {
    guard let k = ue() else { return nil }
    return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
  }
}
