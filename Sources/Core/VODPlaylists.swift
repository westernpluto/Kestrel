// VODs (and a live broadcast's VOD while it's being recorded, for rewinding) served through the
// local server so their playlists can be fixed on the way.
//
// Twitch lists the parts of a VOD that were muted for copyright as "N-unmuted.ts", but those files
// only exist as "N-muted.ts" (Twitch's own player renames them). Played as listed, the player
// stalls on the first muted part: often the very start of a stream (intro music), which is why
// rewinding to the beginning froze.
//
// A VOD that's still being recorded is an open-ended ("EVENT") playlist, which the Apple player
// treats like a live stream: it reloads it constantly, starts at its end and stalled near the
// beginning. It's served as a finished VOD instead (what's been recorded so far); the player
// reloads it to get more as playback nears the end.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class VODPlaylists: PlaylistSource, @unchecked Sendable {
  let id: String
  /// Twitch's renditions, best first.
  let variants: [HLSVariant]
  private let http: HTTPClient
  private let lock = NSLock()
  private var _isRecording = false
  private var _recordedSeconds: Double = 0

  /// The upstream playlist had no end yet (the broadcast is still being recorded).
  var isRecording: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _isRecording
  }

  /// How much of it the last served playlist covered.
  var recordedSeconds: Double {
    lock.lock()
    defer { lock.unlock() }
    return _recordedSeconds
  }

  init(id: String = UUID().uuidString, variants: [HLSVariant], http: HTTPClient) {
    self.id = id
    self.variants = variants
    self.http = http
  }

  func masterPlaylist(only: Int?) async -> String {
    var lines = ["#EXTM3U", "#EXT-X-INDEPENDENT-SEGMENTS"]
    for (index, variant) in variants.enumerated() where only == nil || only == index {
      var attributes = ["BANDWIDTH=\(variant.bandwidth)"]
      if let resolution = variant.resolution { attributes.append("RESOLUTION=\(resolution)") }
      if !variant.codecs.isEmpty { attributes.append("CODECS=\"\(variant.codecs)\"") }
      if variant.frameRate > 0 { attributes.append(String(format: "FRAME-RATE=%.3f", variant.frameRate)) }
      lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
      lines.append("v/\(index).m3u8")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  func mediaPlaylist(_ index: Int) async -> (status: Int, body: String) {
    guard index >= 0, index < variants.count, let url = URL(string: variants[index].uri) else { return (404, "") }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await http.data(for: request) else { return (502, "") }
    guard response.statusCode == 200, let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
      return (response.statusCode == 200 ? 502 : response.statusCode, "")
    }
    let growing = Self.isGrowing(text)
    let rewritten = Self.rewrite(text, base: response.url ?? url, finish: true)
    note(recording: growing, seconds: Self.totalDuration(rewritten))
    return (200, rewritten)
  }

  private func note(recording: Bool, seconds: Double) {
    lock.lock()
    _isRecording = recording
    _recordedSeconds = seconds
    lock.unlock()
  }

  /// Absolute segment addresses (the playlist is served from localhost), muted parts under the
  /// names that exist, and (with `finish`) a still-recording playlist closed off as a VOD.
  static func rewrite(_ text: String, base: URL, finish: Bool = false) -> String {
    var out: [String] = []
    var sawType = false
    for raw in HLS.lines(text) {
      let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
      if line.hasPrefix("#EXT-X-PLAYLIST-TYPE") {
        sawType = true
        out.append(finish ? "#EXT-X-PLAYLIST-TYPE:VOD" : line)
      } else if line.hasPrefix("#") {
        out.append(LowLatencyPlaylist.absolutizeTag(line, base: base))
      } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
        out.append(line)
      } else {
        out.append(HLS.resolve(Substring(line), base: base).replacingOccurrences(of: "-unmuted.", with: "-muted."))
      }
    }
    if finish {
      while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
      if !sawType, let header = out.firstIndex(where: { $0.hasPrefix("#EXTM3U") }) {
        out.insert("#EXT-X-PLAYLIST-TYPE:VOD", at: header + 1)
      }
      if isGrowing(text) { out.append("#EXT-X-ENDLIST") }
    }
    return out.joined(separator: "\n") + "\n"
  }

  /// Sum of the segment durations.
  static func totalDuration(_ text: String) -> Double {
    var total = 0.0
    for line in HLS.lines(text) where line.hasPrefix("#EXTINF:") {
      let value = line.dropFirst(8).split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
      total += Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
    }
    return total
  }

  /// Whether the VOD is still being recorded (no end tag yet).
  static func isGrowing(_ text: String) -> Bool { !text.contains("#EXT-X-ENDLIST") }
}
