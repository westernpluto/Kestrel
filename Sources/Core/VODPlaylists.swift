// VODs (and a live broadcast's VOD while it's being recorded, for rewinding) served through the
// local server so their playlists can be fixed on the way.
//
// Twitch lists the parts of a VOD that were muted for copyright as "N-unmuted.ts", but those files
// only exist as "N-muted.ts" (Twitch's own player renames them). Played as listed, the player
// stalls on the first muted part: often the very start of a stream (intro music), which is why
// rewinding to the beginning froze.
//
// Muted parts are unmuted where Twitch still has the original (as the "Twitch VOD Unmute"
// extension does): the original segment "N.ts" stays on its servers for a while beside
// "N-muted.ts" (a day-old VOD still had some; a two-day-old one, none). Which ones are there
// varies segment by segment (and from one server to the next), so each muted segment is played
// through the local server, which asks for the original as the player needs it and hands over the
// muted one when it isn't there: never a segment that isn't there, and nothing to check first.
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
  private var _mutedParts: [ClosedRange<Double>] = []
  /// The last playlist served per rendition, reused for a little while (so a prefetch makes the
  /// player's own request instant).
  private var cache: [Int: (body: String, at: Date)] = [:]

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

  /// The parts Twitch muted for copyright (seconds into the video), from the last playlist read.
  var mutedParts: [ClosedRange<Double>] {
    lock.lock()
    defer { lock.unlock() }
    return _mutedParts
  }

  /// Muted parts played from Twitch's originals where it still has them (see the top).
  let unmute: Bool

  init(id: String = UUID().uuidString, variants: [HLSVariant], http: HTTPClient, unmute: Bool = false) {
    self.id = id
    self.variants = variants
    self.http = http
    self.unmute = unmute
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
    if let cached = cached(index, maxAge: 15) { return (200, cached) }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await http.data(for: request) else { return (502, "") }
    guard response.statusCode == 200, let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
      return (response.statusCode == 200 ? 502 : response.statusCode, "")
    }
    let growing = Self.isGrowing(text)
    var rewritten = Self.rewrite(text, base: response.url ?? url, finish: true)
    note(recording: growing, seconds: Self.totalDuration(rewritten), muted: Self.mutedParts(rewritten))
    if unmute {
      rewritten = throughLocal(rewritten, index: index)
      // (What's still muted: the ones whose originals came aren't.)
      refreshMutedParts()
    }
    store(index, rewritten)
    return (200, rewritten)
  }

  /// The muted segments played through the local server (by key): where the original and the
  /// muted one are, and when in the video it plays.
  private struct Muted {
    var original: URL
    var muted: URL
    var range: ClosedRange<Double>
  }
  private var muted: [String: Muted] = [:]
  /// Whether each one's original came (true) or wasn't there (false); not yet asked, absent.
  private var resolved: [String: Bool] = [:]
  /// The rendition last served (its muted segments are the ones that count for `mutedParts`).
  private var servedIndex = 0

  /// The playlist with each muted segment pointed at the local server (see the top).
  private func throughLocal(_ playlist: String, index: Int) -> String {
    var lines: [String] = []
    var time = 0.0
    var length = 0.0
    var found: [String: Muted] = [:]
    for raw in HLS.lines(playlist) {
      let line = String(raw)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#EXTINF:") {
        let value = trimmed.dropFirst(8).split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        length = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
        lines.append(line)
        continue
      }
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
        lines.append(line)
        continue
      }
      let end = time + length
      if trimmed.contains("-muted."), let mutedURL = URL(string: trimmed), let originalURL = URL(string: Self.original(trimmed)) {
        let name = mutedURL.deletingPathExtension().lastPathComponent
        let key = "\(index)-" + name.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        found[key] = Muted(original: originalURL, muted: mutedURL, range: time...max(time, end))
        // (Served next to the playlist: /live/<id>/u/<key>.ts.)
        lines.append("../u/\(key).ts")
      } else {
        lines.append(line)
      }
      time = end
      length = 0
    }
    lock.lock()
    muted.merge(found) { _, new in new }
    servedIndex = index
    lock.unlock()
    return lines.joined(separator: "\n") + "\n"
  }

  /// What's still muted: the muted segments of the rendition playing whose originals haven't come,
  /// joined into stretches.
  private func stillMuted() -> [ClosedRange<Double>] {
    lock.lock()
    let prefix = "\(servedIndex)-"
    let ranges = muted.filter { $0.key.hasPrefix(prefix) && resolved[$0.key] != true }.map(\.value.range)
    lock.unlock()
    var parts: [ClosedRange<Double>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = parts.last, range.lowerBound - last.upperBound < 0.05 {
        parts[parts.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
      } else {
        parts.append(range)
      }
    }
    return parts
  }

  /// A muted segment, as the player asks for it: the original if Twitch still has it, else the
  /// muted one.
  func segment(_ key: String) async -> (status: Int, body: Data) {
    let (entry, known) = lookUp(key)
    guard let entry else { return (404, Data()) }
    if known != false, let data = await Self.fetch(entry.original, http: http) {
      setResolved(key, true)
      refreshMutedParts()
      return (200, data)
    }
    setResolved(key, false)
    guard let data = await Self.fetch(entry.muted, http: http) else { return (502, Data()) }
    return (200, data)
  }

  private func lookUp(_ key: String) -> (Muted?, Bool?) {
    lock.lock()
    defer { lock.unlock() }
    return (muted[key], resolved[key])
  }

  private func setResolved(_ key: String, _ there: Bool) {
    lock.lock()
    resolved[key] = there
    lock.unlock()
  }

  private func refreshMutedParts() {
    let parts = stillMuted()
    lock.lock()
    _mutedParts = parts
    lock.unlock()
  }

  private static func fetch(_ url: URL, http: HTTPClient) async -> Data? {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await http.data(for: request), response.statusCode == 200, !data.isEmpty else { return nil }
    return data
  }

  /// A muted segment's original: "N-muted.ts" as "N.ts".
  static func original(_ muted: String) -> String { muted.replacingOccurrences(of: "-muted.", with: ".") }

  /// Fetches a rendition's playlist ahead of time.
  func prefetch(_ index: Int) async {
    _ = await mediaPlaylist(index)
  }

  private func cached(_ index: Int, maxAge: TimeInterval) -> String? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = cache[index], Date().timeIntervalSince(entry.at) < maxAge else { return nil }
    return entry.body
  }

  private func store(_ index: Int, _ body: String) {
    lock.lock()
    cache[index] = (body, Date())
    lock.unlock()
  }

  private func note(recording: Bool, seconds: Double, muted: [ClosedRange<Double>]) {
    lock.lock()
    _isRecording = recording
    _recordedSeconds = seconds
    _mutedParts = muted
    lock.unlock()
  }

  /// Where the muted segments are ("N-unmuted.ts" as Twitch lists them, or "N-muted.ts"), as
  /// stretches of seconds; neighbouring segments are joined into one stretch.
  static func mutedParts(_ text: String) -> [ClosedRange<Double>] {
    var parts: [ClosedRange<Double>] = []
    var time = 0.0
    var length = 0.0
    for raw in HLS.lines(text) {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("#EXTINF:") {
        let value = line.dropFirst(8).split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        length = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
      } else if !line.isEmpty, !line.hasPrefix("#") {
        let end = time + length
        if line.contains("-unmuted.") || line.contains("-muted."), length > 0 {
          if let last = parts.last, abs(last.upperBound - time) < 0.05 {
            parts[parts.count - 1] = last.lowerBound...end
          } else {
            parts.append(time...end)
          }
        }
        time = end
        length = 0
      }
    }
    return parts
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
