// VODs (and a live broadcast's VOD while it's being recorded, for rewinding) served through the
// local server so their playlists can be fixed on the way.
//
// Twitch lists the parts of a VOD that were muted for copyright as "N-unmuted.ts", but those files
// only exist as "N-muted.ts" (Twitch's own player renames them). Played as listed, the player
// stalls on the first muted part: often the very start of a stream (intro music), which is why
// rewinding to the beginning froze.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class VODPlaylists: PlaylistSource, @unchecked Sendable {
  let id: String
  /// Twitch's renditions, best first.
  let variants: [HLSVariant]
  private let http: HTTPClient

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
    return (200, Self.rewrite(text, base: response.url ?? url))
  }

  /// Absolute segment addresses (the playlist is served from localhost) and muted parts under
  /// the names that exist.
  static func rewrite(_ text: String, base: URL) -> String {
    var out: [String] = []
    for raw in HLS.lines(text) {
      let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
      if line.hasPrefix("#") {
        out.append(LowLatencyPlaylist.absolutizeTag(line, base: base))
      } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
        out.append(line)
      } else {
        out.append(HLS.resolve(Substring(line), base: base).replacingOccurrences(of: "-unmuted.", with: "-muted."))
      }
    }
    return out.joined(separator: "\n") + "\n"
  }

  /// Whether the VOD is still being recorded (no end tag yet).
  static func isGrowing(_ text: String) -> Bool { !text.contains("#EXT-X-ENDLIST") }
}
