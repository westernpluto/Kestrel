// HLS playlist parsing tuned for Twitch's usher / weaver playlists.
// Ad markers follow streamlink's Twitch plugin and TwitchAdSolutions (vaft).

import Foundation

// MARK: - Dates

enum HLSDate {
  /// Parses `2026-10-21T07:00:04.123Z` / `...+00:00` quickly, falling back to ISO8601DateFormatter.
  static func parse(_ string: String) -> Date? {
    let s = string.trimmingCharacters(in: .whitespaces)
    let u = Array(s.utf8)
    func num(_ from: Int, _ count: Int) -> Int? {
      guard from + count <= u.count else { return nil }
      var v = 0
      for i in from..<(from + count) {
        let c = u[i]
        guard c >= 48, c <= 57 else { return nil }
        v = v * 10 + Int(c - 48)
      }
      return v
    }
    guard u.count >= 19, u[4] == 45, u[7] == 45, u[10] == 84 || u[10] == 116, u[13] == 58, u[16] == 58,
      let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
      let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2)
    else { return fallback(s) }
    var index = 19
    var fraction = 0.0
    if index < u.count, u[index] == 46 {  // '.'
      index += 1
      var scale = 0.1
      while index < u.count, u[index] >= 48, u[index] <= 57 {
        fraction += Double(u[index] - 48) * scale
        scale /= 10
        index += 1
      }
    }
    var offset = 0
    if index < u.count {
      let c = u[index]
      if c == 90 || c == 122 {  // Z
        offset = 0
      } else if c == 43 || c == 45 {  // + -
        guard let oh = num(index + 1, 2) else { return fallback(s) }
        var om = 0
        if index + 3 < u.count {
          let minuteStart = u[index + 3] == 58 ? index + 4 : index + 3
          om = num(minuteStart, 2) ?? 0
        }
        offset = (oh * 3600 + om * 60) * (c == 45 ? -1 : 1)
      } else {
        return fallback(s)
      }
    }
    // Days from civil (Howard Hinnant).
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (month + 9) % 12
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146097 + doe - 719468
    let seconds = Double(days * 86400 + hour * 3600 + minute * 60 + second - offset) + fraction
    return Date(timeIntervalSince1970: seconds)
  }

  private static let lock = NSLock()
  private static let fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private static let plain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  private static func fallback(_ s: String) -> Date? {
    lock.lock()
    defer { lock.unlock() }
    return fractional.date(from: s) ?? plain.date(from: s)
  }

  static func format(_ date: Date) -> String {
    let total = date.timeIntervalSince1970
    var seconds = Int(floor(total))
    var millis = Int(((total - floor(total)) * 1000).rounded())
    if millis >= 1000 {
      millis -= 1000
      seconds += 1
    }
    var days = seconds >= 0 ? seconds / 86400 : (seconds - 86399) / 86400
    let secondsOfDay = seconds - days * 86400
    days += 719468
    let era = (days >= 0 ? days : days - 146096) / 146097
    let doe = days - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = doy - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
    func pad(_ v: Int, _ width: Int) -> String {
      let s = String(v)
      return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
    return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(secondsOfDay / 3600, 2)):"
      + "\(pad(secondsOfDay % 3600 / 60, 2)):\(pad(secondsOfDay % 60, 2)).\(pad(millis, 3))Z"
  }
}

// MARK: - Helpers

enum HLS {
  static func lines(_ text: String) -> [Substring] {
    text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
  }

  /// Parses `KEY=VALUE,KEY="quoted, value"` attribute lists (everything after the first ':').
  static func attributes(_ line: Substring) -> [String: String] {
    var result: [String: String] = [:]
    let list: Substring
    if let colon = line.firstIndex(of: ":") { list = line[line.index(after: colon)...] } else { list = line }
    let chars = Array(list)
    var i = 0
    while i < chars.count {
      let keyStart = i
      while i < chars.count, chars[i] != "=", chars[i] != "," { i += 1 }
      let key = String(chars[keyStart..<i]).trimmingCharacters(in: .whitespaces)
      if i >= chars.count || chars[i] == "," {
        i += 1
        continue
      }
      i += 1  // '='
      var value = ""
      if i < chars.count, chars[i] == "\"" {
        i += 1
        let valueStart = i
        while i < chars.count, chars[i] != "\"" { i += 1 }
        value = String(chars[valueStart..<min(i, chars.count)])
        while i < chars.count, chars[i] != "," { i += 1 }
      } else {
        let valueStart = i
        while i < chars.count, chars[i] != "," { i += 1 }
        value = String(chars[valueStart..<i]).trimmingCharacters(in: .whitespaces)
      }
      if !key.isEmpty { result[key] = value }
      i += 1
    }
    return result
  }

  static func resolve(_ uri: Substring, base: URL?) -> String {
    let trimmed = uri.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") { return trimmed }
    guard let base, let url = URL(string: trimmed, relativeTo: base) else { return trimmed }
    return url.absoluteString
  }

  static func codecFamily(_ codecs: String?) -> String {
    guard let codecs else { return "unknown" }
    for part in codecs.lowercased().split(separator: ",") {
      let c = part.trimmingCharacters(in: .whitespaces)
      if c.hasPrefix("avc") { return "avc" }
      if c.hasPrefix("hev") || c.hasPrefix("hvc") { return "hevc" }
      if c.hasPrefix("av01") { return "av1" }
    }
    return "unknown"
  }

  static func looksLikePlaylist(_ data: Data) -> Bool {
    guard let head = String(data: data.prefix(64), encoding: .utf8) else { return false }
    return head.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF} \t\r\n")).hasPrefix("#EXTM3U")
  }

  static let adSegmentPatterns = ["/adsquared/", "/_404/", "/processing"]
}

// MARK: - Master playlist

struct HLSVariant: Equatable {
  var uri: String
  var bandwidth: Int
  var width: Int
  var height: Int
  var frameRate: Double
  var codecs: String
  var name: String
  var isAudioOnly: Bool
  var isPortrait: Bool
  var codecFamily: String { HLS.codecFamily(codecs) }
  var resolution: String? { width > 0 ? "\(width)x\(height)" : nil }

  /// "1080p60", "720p", "1440p60 HEVC", "Audio only"
  var label: String {
    if isAudioOnly { return "Audio only" }
    let lines = min(width, height)
    let fps = frameRate > 31 ? String(Int(frameRate.rounded())) : ""
    switch codecFamily {
    case "hevc": return "\(lines)p\(fps) HEVC"
    case "av1": return "\(lines)p\(fps) AV1"
    default: return "\(lines)p\(fps)"
    }
  }

  /// Among variants with the same resolution and frame rate, the newer codecs look better at the
  /// same bitrate. HEVC ranks above AV1 because more players handle it.
  var codecRank: Int {
    switch codecFamily {
    case "hevc": return 2
    case "av1": return 1
    default: return 0
    }
  }
}

struct HLSMaster {
  var variants: [HLSVariant]

  static func parse(_ text: String, base: URL?) -> HLSMaster {
    let lines = HLS.lines(text)
    var mediaNames: [String: String] = [:]  // v1: GROUP-ID -> NAME
    for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
      let a = HLS.attributes(line)
      if let group = a["GROUP-ID"], let name = a["NAME"] { mediaNames[group] = name }
    }
    var variants: [HLSVariant] = []
    var i = 0
    while i < lines.count {
      let line = lines[i]
      if line.hasPrefix("#EXT-X-STREAM-INF") {
        let a = HLS.attributes(line)
        var j = i + 1
        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty || lines[j].hasPrefix("#") {
          if lines[j].hasPrefix("#EXT-X-STREAM-INF") { break }
          j += 1
        }
        if j < lines.count, !lines[j].hasPrefix("#") {
          var width = 0, height = 0
          if let res = a["RESOLUTION"] {
            let parts = res.lowercased().split(separator: "x")
            if parts.count == 2 { width = Int(parts[0]) ?? 0; height = Int(parts[1]) ?? 0 }
          }
          let stable = a["STABLE-VARIANT-ID"]?.lowercased() ?? ""
          let group = a["VIDEO"] ?? ""
          let codecs = a["CODECS"] ?? ""
          let audioOnly = width == 0 && (stable.hasPrefix("audio") || group.hasPrefix("audio") || HLS.codecFamily(codecs) == "unknown")
          let portrait = (a["IVS-GROUPS"]?.lowercased() == "portrait") || stable.hasSuffix("portrait") || (height > width && width > 0)
          let name = a["IVS-NAME"] ?? mediaNames[group] ?? a["STABLE-VARIANT-ID"] ?? ""
          variants.append(
            HLSVariant(
              uri: HLS.resolve(lines[j], base: base), bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0,
              width: width, height: height, frameRate: Double(a["FRAME-RATE"] ?? "") ?? 0,
              codecs: codecs, name: name, isAudioOnly: audioOnly, isPortrait: portrait))
          i = j
        }
      }
      i += 1
    }
    return HLSMaster(variants: variants)
  }

  /// Landscape video variants, best first.
  var videoVariants: [HLSVariant] {
    variants.filter { !$0.isAudioOnly && !$0.isPortrait }.sorted {
      ($0.height, $0.frameRate, $0.codecRank, $0.bandwidth) > ($1.height, $1.frameRate, $1.codecRank, $1.bandwidth)
    }
  }

  /// The upstream master as another player should load it from the local server: portrait
  /// variants removed and every URI made absolute (Twitch's v2 masters use relative ones).
  static func localCopy(of text: String, base: URL?) -> String {
    var output: [String] = []
    var skipNextURI = false
    for line in HLS.lines(text) {
      if line.hasPrefix("#EXT-X-STREAM-INF") {
        let a = HLS.attributes(line)
        var width = 0, height = 0
        if let res = a["RESOLUTION"] {
          let parts = res.lowercased().split(separator: "x")
          if parts.count == 2 { width = Int(parts[0]) ?? 0; height = Int(parts[1]) ?? 0 }
        }
        let stable = a["STABLE-VARIANT-ID"]?.lowercased() ?? ""
        skipNextURI = (a["IVS-GROUPS"]?.lowercased() == "portrait") || stable.hasSuffix("portrait") || (height > width && width > 0)
        if !skipNextURI { output.append(String(line)) }
      } else if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
        output.append(String(line))
      } else {
        if !skipNextURI { output.append(HLS.resolve(line, base: base)) }
        skipNextURI = false
      }
    }
    return output.joined(separator: "\n") + "\n"
  }

  var audioVariant: HLSVariant? { variants.first { $0.isAudioOnly } }

  /// Picks the variant in `self` closest to `target`: same codec family, then resolution, then fps.
  func bestMatch(for target: HLSVariant) -> HLSVariant? {
    let pool = target.isAudioOnly ? variants.filter { $0.isAudioOnly } : variants.filter { !$0.isAudioOnly && !$0.isPortrait }
    let candidates = pool.isEmpty ? variants : pool
    return candidates.min { a, b in score(a, target) < score(b, target) }
  }

  private func score(_ v: HLSVariant, _ t: HLSVariant) -> Double {
    let sameCodec = v.codecFamily == t.codecFamily || v.codecFamily == "unknown" || t.codecFamily == "unknown"
    let pixels = abs(Double(v.width * v.height) - Double(t.width * t.height))
    return (sameCodec ? 0 : 1e15) + (v.resolution == t.resolution ? 0 : 1e12 + pixels)
      + (abs(v.frameRate - t.frameRate) < 0.5 ? 0 : 1e9)
  }
}

// MARK: - Media playlist

struct HLSDateRange {
  var id: String
  var cls: String
  var start: Date?
  var duration: Double?
  var isAd: Bool { cls == "twitch-stitched-ad" || id.hasPrefix("stitched-ad") || cls == "twitch-maf-ad" }
  func contains(_ date: Date) -> Bool {
    guard let start else { return false }
    let end = start.addingTimeInterval(duration ?? 30)
    return date >= start.addingTimeInterval(-0.05) && date < end
  }
}

struct HLSSegment: Equatable {
  var uri: String
  var duration: Double
  var title: String
  var pdt: Date?
  var discontinuity: Bool
  var map: String?
  var isPrefetch: Bool
  var isAd: Bool
  var end: Date? { pdt?.addingTimeInterval(duration) }
}

struct HLSMediaPlaylist {
  var targetDuration: Double = 6
  var mediaSequence: Int = 0
  var segments: [HLSSegment] = []
  var dateRanges: [HLSDateRange] = []
  var hasAdSignifier = false
  var isEnded = false

  var regularSegments: [HLSSegment] { segments.filter { !$0.isPrefetch } }
  var adDateRanges: [HLSDateRange] { dateRanges.filter { $0.isAd } }

  /// End of the newest complete (non-prefetch) segment.
  var liveEdge: Date? { regularSegments.last?.end }

  /// An ad is *stitched into the video itself* at the live edge (server-side ad insertion).
  /// Only then does the player need a different copy of the stream.
  var adBreakActive: Bool {
    regularSegments.last?.isAd ?? false
  }

  /// Twitch has marked an ad break (DATERANGE) at the live edge. Since 2026 Twitch mostly delivers
  /// these ads client-side: the segments keep carrying the real broadcast and Twitch's own player
  /// fetches the ad separately. Kestrel never fetches it, so nothing needs to change.
  var adMarkerActive: Bool {
    guard let edge = liveEdge else { return false }
    return adDateRanges.contains { range in
      guard let start = range.start else { return false }
      let end = start.addingTimeInterval(range.duration ?? 30)
      return start <= edge.addingTimeInterval(4) && end > edge.addingTimeInterval(-0.5)
    }
  }

  /// No stitched ad segments (used to decide whether a backup copy is usable). Markers are fine.
  var isClean: Bool {
    !segments.contains { $0.isAd }
  }

  static func parse(_ text: String, base: URL?) -> HLSMediaPlaylist {
    var playlist = HLSMediaPlaylist()
    let lines = HLS.lines(text)
    var pendingDuration: Double?
    var pendingTitle = ""
    var pendingPDT: Date?
    var pendingDiscontinuity = false
    var currentMap: String?
    var anyLiveTitle = false

    for raw in lines {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if line.hasPrefix("#") {
        if line.hasPrefix("#EXTINF:") {
          let value = line.dropFirst("#EXTINF:".count)
          let parts = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
          pendingDuration = Double(parts.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") ?? 2
          pendingTitle = parts.count > 1 ? String(parts[1]) : ""
          if pendingTitle.hasPrefix("live") { anyLiveTitle = true }
        } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
          pendingPDT = HLSDate.parse(String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count)))
        } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
          // not used
        } else if line.hasPrefix("#EXT-X-DISCONTINUITY") {
          pendingDiscontinuity = true
        } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
          playlist.targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 6
        } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
          playlist.mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
        } else if line.hasPrefix("#EXT-X-MAP:") {
          if let uri = HLS.attributes(Substring(line))["URI"] { currentMap = HLS.resolve(Substring(uri), base: base) }
        } else if line.hasPrefix("#EXT-X-DATERANGE:") {
          let a = HLS.attributes(Substring(line))
          let range = HLSDateRange(
            id: a["ID"] ?? "", cls: a["CLASS"] ?? "", start: a["START-DATE"].flatMap(HLSDate.parse),
            duration: a["DURATION"].flatMap(Double.init) ?? a["PLANNED-DURATION"].flatMap(Double.init))
          playlist.dateRanges.append(range)
        } else if line.hasPrefix("#EXT-X-TWITCH-PREFETCH:") {
          let uri = HLS.resolve(line.dropFirst("#EXT-X-TWITCH-PREFETCH:".count), base: base)
          guard let last = playlist.segments.last else { continue }
          let regular = playlist.segments.filter { !$0.isPrefetch }
          let average = regular.isEmpty ? last.duration : regular.map(\.duration).reduce(0, +) / Double(regular.count)
          let duration = last.isPrefetch ? last.duration : average
          let pdt = last.end
          playlist.segments.append(
            HLSSegment(
              uri: uri, duration: duration, title: "", pdt: pdt,
              discontinuity: false, map: currentMap, isPrefetch: true,
              isAd: false))
        } else if line.hasPrefix("#EXT-X-ENDLIST") {
          playlist.isEnded = true
        }
        if line.contains("stitched-ad") || line.contains("EXT-X-CUE-OUT") || line.contains("twitch-stitched")
          || line.contains("twitch-maf-ad") || line.contains("twitch-trigger")
        {
          playlist.hasAdSignifier = true
        }
        continue
      }
      // URI line
      guard let duration = pendingDuration else { continue }
      let uri = HLS.resolve(Substring(line), base: base)
      var pdt = pendingPDT
      if pdt == nil, let last = playlist.segments.last { pdt = last.end }
      playlist.segments.append(
        HLSSegment(
          uri: uri, duration: duration, title: pendingTitle, pdt: pdt,
          discontinuity: pendingDiscontinuity, map: currentMap, isPrefetch: false, isAd: false))
      pendingDuration = nil
      pendingTitle = ""
      pendingPDT = nil
      pendingDiscontinuity = false
    }

    // Ad classification: only segments that really contain ad video count (stitched ads are
    // titled "Amazon|…" instead of "live"). A DATERANGE marker alone is not an ad segment.
    for index in playlist.segments.indices {
      var segment = playlist.segments[index]
      let byTitle = segment.title.contains("Amazon")
      let byURL = HLS.adSegmentPatterns.contains { segment.uri.contains($0) }
      let byLiveTitle = !segment.isPrefetch && playlist.hasAdSignifier && anyLiveTitle && !segment.title.hasPrefix("live")
      if byTitle || byURL || byLiveTitle { segment.isAd = true }
      if segment.isPrefetch, index > 0, playlist.segments[index - 1].isAd { segment.isAd = true }
      playlist.segments[index] = segment
    }
    return playlist
  }
}
