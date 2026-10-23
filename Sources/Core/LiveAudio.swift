// The stream's sound on its own, for live captions: Twitch's "audio only" rendition is a live
// playlist of MPEG-TS segments carrying AAC. LiveAudioFeed follows that playlist and hands over
// each new segment's audio as ADTS (AAC frames with headers, which Apple's decoders read
// directly); TSAudio takes the audio out of a segment.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum TSAudio {
  static let packetSize = 188

  /// The audio elementary stream (ADTS AAC) carried in an MPEG-TS segment, or nil if there's
  /// none (or it isn't MPEG-TS).
  static func adts(fromTS data: Data) -> Data? {
    let bytes = [UInt8](data)
    guard bytes.count >= packetSize, bytes[0] == 0x47 else { return nil }
    var audioPID: Int?
    var collecting = false
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var index = 0
    while index + packetSize <= bytes.count {
      guard bytes[index] == 0x47 else {
        index += 1  // lost sync: find the next packet
        continue
      }
      let end = index + packetSize
      let startsUnit = bytes[index + 1] & 0x40 != 0
      let pid = Int(bytes[index + 1] & 0x1F) << 8 | Int(bytes[index + 2])
      let adaptation = (bytes[index + 3] >> 4) & 0x3
      var payload = index + 4
      if adaptation & 0x2 != 0 { payload += 1 + Int(bytes[index + 4]) }
      if adaptation & 0x1 != 0, payload < end {
        if startsUnit {
          // A new PES packet: 00 00 01, stream ID (audio is 0xC0–0xDF), length, flags, header length.
          if payload + 9 <= end, bytes[payload] == 0, bytes[payload + 1] == 0, bytes[payload + 2] == 1 {
            let streamID = bytes[payload + 3]
            if audioPID == nil, (0xC0...0xDF).contains(streamID) { audioPID = pid }
            if pid == audioPID {
              payload += 9 + Int(bytes[payload + 8])
              collecting = true
            }
          } else if pid == audioPID {
            collecting = false
          }
        }
        if pid == audioPID, collecting, payload < end { out.append(contentsOf: bytes[payload..<end]) }
      }
      index = end
    }
    return out.isEmpty ? nil : Data(out)
  }

  struct ADTSInfo: Equatable {
    var sampleRate: Int
    var channels: Int
    var frames: Int
  }

  /// Sample rate, channels and frame count of an ADTS stream (nil if it doesn't start with one).
  static func adtsInfo(_ data: Data) -> ADTSInfo? {
    let bytes = [UInt8](data)
    let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    var info: ADTSInfo?
    var index = 0
    while index + 7 <= bytes.count, bytes[index] == 0xFF, bytes[index + 1] & 0xF0 == 0xF0 {
      let rateIndex = Int((bytes[index + 2] >> 2) & 0xF)
      let channels = Int((bytes[index + 2] & 0x1) << 2 | bytes[index + 3] >> 6)
      let length = Int(bytes[index + 3] & 0x3) << 11 | Int(bytes[index + 4]) << 3 | Int(bytes[index + 5] >> 5)
      guard rateIndex < rates.count, length >= 7 else { break }
      if info == nil { info = ADTSInfo(sampleRate: rates[rateIndex], channels: channels, frames: 0) }
      info?.frames += 1
      index += length
    }
    return info
  }
}

/// One segment's sound, in whichever form the stream carries it.
enum LiveAudioChunk: Equatable {
  /// AAC with ADTS headers (taken out of an MPEG-TS segment).
  case adts(Data)
  /// A fragmented-MP4 segment and the initialization segment it needs.
  case fragmentedMP4(initialization: Data, segment: Data)
}

/// What the feed has done so far (for live captions' status line).
struct LiveAudioProgress: Equatable, Sendable {
  var playlistLoads = 0
  var playlistFailures = 0
  var segments = 0
  var unreadable = 0
}

/// Follows a live audio-only playlist and hands over each new segment's audio once, in order,
/// starting at the live edge. Ad segments are left out.
final class LiveAudioFeed: @unchecked Sendable {
  let playlistURL: URL
  private let http: HTTPClient
  private let log: ActivityLog
  private let lock = NSLock()
  private var _progress = LiveAudioProgress()
  private var initSegments: [String: Data] = [:]

  var progress: LiveAudioProgress {
    lock.lock()
    defer { lock.unlock() }
    return _progress
  }

  init(playlistURL: URL, http: HTTPClient, log: ActivityLog = .shared) {
    self.playlistURL = playlistURL
    self.http = http
    self.log = log
  }

  private func count(_ change: (inout LiveAudioProgress) -> Void) {
    lock.lock()
    change(&_progress)
    lock.unlock()
  }

  /// Runs until the task is cancelled (or the stream ends).
  func run(_ deliver: @escaping (LiveAudioChunk) async -> Void) async {
    var lastSequence: Int?
    var failures = 0
    var reportedFormat = false
    while !Task.isCancelled {
      var wait = 1.0
      if let playlist = await fetchPlaylist() {
        failures = 0
        count { $0.playlistLoads += 1 }
        wait = min(3, max(1, playlist.targetDuration / 2))
        let numbered = playlist.segments.enumerated()
          .filter { !$0.element.isPrefetch }
          .map { (sequence: playlist.mediaSequence + $0.offset, segment: $0.element) }
        // Start at the newest segment (the live edge), then take each new one as it appears.
        let newest = numbered.last?.sequence
        let fresh = numbered.filter { item in
          if let last = lastSequence { return item.sequence > last }
          return item.sequence == newest
        }
        for item in fresh {
          guard !Task.isCancelled else { return }
          lastSequence = item.sequence
          if item.segment.isAd { continue }
          guard let url = URL(string: item.segment.uri), let data = await fetch(url) else { continue }
          if let chunk = await chunk(data, map: item.segment.map) {
            count { $0.segments += 1 }
            await deliver(chunk)
          } else {
            count { $0.unreadable += 1 }
            if !reportedFormat {
              reportedFormat = true
              log.add("Live captions: the stream's audio isn't in a format Kestrel can read (\(Self.describe(data)))")
            }
          }
        }
        if playlist.isEnded { return }
      } else {
        failures += 1
        count { $0.playlistFailures += 1 }
        if failures == 3 { log.add("Live captions: can't load the stream's audio playlist") }
        wait = min(8, Double(failures) * 1.5)
      }
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }
  }

  private func chunk(_ data: Data, map: String?) async -> LiveAudioChunk? {
    if let audio = TSAudio.adts(fromTS: data) { return .adts(audio) }
    guard Self.isMP4(data) else { return nil }
    guard let map else { return Self.isMP4Initialization(data) ? .fragmentedMP4(initialization: Data(), segment: data) : nil }
    if initSegments[map] == nil, let url = URL(string: map), let initialization = await fetch(url) {
      initSegments = [map: initialization]
    }
    guard let initialization = initSegments[map] else { return nil }
    return .fragmentedMP4(initialization: initialization, segment: data)
  }

  /// MP4 boxes ("styp", "moof", "ftyp", …) rather than a transport stream.
  static func isMP4(_ data: Data) -> Bool {
    guard data.count >= 8 else { return false }
    let type = String(decoding: data[data.startIndex + 4..<data.startIndex + 8], as: UTF8.self)
    return ["styp", "moof", "ftyp", "sidx", "prft", "emsg"].contains(type)
  }

  static func isMP4Initialization(_ data: Data) -> Bool {
    guard data.count >= 8 else { return false }
    return String(decoding: data[data.startIndex + 4..<data.startIndex + 8], as: UTF8.self) == "ftyp"
  }

  private static func describe(_ data: Data) -> String {
    let head = data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
    return "\(data.count) bytes, starts \(head)"
  }

  private func fetchPlaylist() async -> HLSMediaPlaylist? {
    guard let data = await fetch(playlistURL), let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U")
    else { return nil }
    return HLSMediaPlaylist.parse(text, base: playlistURL)
  }

  private func fetch(_ url: URL) async -> Data? {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await http.data(for: request), response.statusCode == 200 else { return nil }
    return data
  }
}
