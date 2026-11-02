// Sub-only (and other restricted) VODs, the TwitchNoSub way (github.com/besuper/TwitchNoSub).
//
// For a VOD only subscribers may watch, Twitch's playlist server (usher) refuses the master
// playlist, but the video files themselves sit on Twitch's VOD CDN with no check at all. Where they
// are can be worked out from the VOD's storyboard address, which Twitch hands to anyone:
//
//   https://<cdn host>/<special id>/storyboards/<vod id>-info.json
//
// and each rendition's playlist lives next to it:
//
//   archives:           https://<cdn host>/<special id>/<rendition>/index-dvr.m3u8
//   highlights:         https://<cdn host>/<special id>/<rendition>/highlight-<vod id>.m3u8
//   uploads (older):    https://<cdn host>/<login>/<vod id>/<special id>/<rendition>/index-dvr.m3u8
//
// Kestrel only goes this way when usher says no, and then builds the list of renditions itself
// by asking for each one's playlist.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum RestrictedVOD {
  /// What's needed from Twitch's video metadata.
  struct Info: Equatable, Sendable {
    var broadcastType: String
    var createdAt: Date?
    var seekPreviewsURL: URL
    var ownerLogin: String
  }

  /// A rendition's folder name on the CDN and what it plays as.
  struct Rendition: Equatable, Sendable {
    var key: String
    var width: Int
    var height: Int
    var frameRate: Double
    var isAudioOnly: Bool { key == "audio_only" }
  }

  /// Best first. "chunked" is the source; its size isn't in its name, so it's worked out from
  /// the transcodes that exist (see `variants`).
  static let renditions: [Rendition] = [
    Rendition(key: "chunked", width: 0, height: 0, frameRate: 60),
    Rendition(key: "1440p60", width: 2560, height: 1440, frameRate: 60),
    Rendition(key: "1080p60", width: 1920, height: 1080, frameRate: 60),
    Rendition(key: "1080p30", width: 1920, height: 1080, frameRate: 30),
    Rendition(key: "720p60", width: 1280, height: 720, frameRate: 60),
    Rendition(key: "720p30", width: 1280, height: 720, frameRate: 30),
    Rendition(key: "480p30", width: 854, height: 480, frameRate: 30),
    Rendition(key: "360p30", width: 640, height: 360, frameRate: 30),
    Rendition(key: "160p30", width: 284, height: 160, frameRate: 30),
    Rendition(key: "audio_only", width: 0, height: 0, frameRate: 0),
  ]

  /// Uploads made before about this date are stored under the channel's name. This is TwitchNoSub's
  /// rule as written in its source (`patch_amazonworker.js`): "days since upload" is counted from
  /// a fixed `new Date("2023-02-10")`, not from today, and only uploads more than 7 days older than
  /// that use the channel-name path.
  static let uploadPathCutoff = Date(timeIntervalSince1970: 1_675_987_200 - 7 * 86_400)  // 2023-02-10 less 7 days

  static let infoQuery = """
    query null($id: ID) { video(id: $id) { broadcastType createdAt seekPreviewsURL owner { login } } }
    """

  static func parseInfo(_ data: JSONValue) -> Info? {
    let video = data["video"]
    guard let previews = video["seekPreviewsURL"].string.flatMap(URL.init(string:)) else { return nil }
    return Info(
      broadcastType: (video["broadcastType"].string ?? "ARCHIVE").lowercased(),
      createdAt: video["createdAt"].date,
      seekPreviewsURL: previews,
      ownerLogin: video["owner"]["login"].string ?? "")
  }

  /// The CDN host and the VOD's special folder, from its storyboard address.
  static func location(_ previews: URL) -> (host: String, specialID: String)? {
    guard let host = previews.host else { return nil }
    let parts = previews.path.split(separator: "/").map(String.init)
    guard let index = parts.firstIndex(where: { $0.contains("storyboards") }), index > 0 else { return nil }
    return (host, parts[index - 1])
  }

  /// Where a rendition's playlist would be.
  static func playlistURL(videoID: String, info: Info, rendition: String) -> URL? {
    guard let (host, special) = location(info.seekPreviewsURL) else { return nil }
    let path: String
    switch info.broadcastType {
    case "highlight":
      path = "/\(special)/\(rendition)/highlight-\(videoID).m3u8"
    case "upload" where (info.createdAt ?? Date()) < uploadPathCutoff && !info.ownerLogin.isEmpty:
      path = "/\(info.ownerLogin)/\(videoID)/\(special)/\(rendition)/index-dvr.m3u8"
    default:
      path = "/\(special)/\(rendition)/index-dvr.m3u8"
    }
    return URL(string: "https://\(host)\(path)")
  }

  /// The renditions that exist on the CDN, best first (audio only last), ready for the player.
  static func variants(videoID: String, info: Info, http: HTTPClient) async -> [HLSVariant] {
    let found = await withTaskGroup(of: (Int, URL, String)?.self) { group -> [(Int, URL, String)] in
      for (index, rendition) in renditions.enumerated() {
        guard let url = playlistURL(videoID: videoID, info: info, rendition: rendition.key) else { continue }
        group.addTask {
          guard let codecs = await probe(url, audioOnly: rendition.isAudioOnly, http: http) else { return nil }
          return (index, url, codecs)
        }
      }
      var all: [(Int, URL, String)] = []
      for await result in group { if let result { all.append(result) } }
      return all.sorted { $0.0 < $1.0 }
    }
    return build(found.map { (renditions[$0.0], $0.1, $0.2) })
  }

  /// Turns what was found into variants. The source gets the size one step above the best
  /// transcode (Twitch doesn't transcode to the source's own size), 1080p when there are none.
  static func build(_ found: [(Rendition, URL, String)]) -> [HLSVariant] {
    let steps = [160, 360, 480, 720, 1080, 1440, 2160]
    let bestTranscode = found.filter { $0.0.key != "chunked" && !$0.0.isAudioOnly }.map(\.0.height).max()
    var sourceHeight = 1080
    if let best = bestTranscode { sourceHeight = max(720, steps.first(where: { $0 > best }) ?? best) }
    // The source runs at the broadcast's frame rate: 60 when Twitch made 60 fps transcodes of it,
    // otherwise 30 (with none at all, 60 is the likelier guess for a channel big enough to have
    // sub-only VODs).
    let transcodes = found.filter { $0.0.key != "chunked" && !$0.0.isAudioOnly }
    let sourceFPS: Double = transcodes.isEmpty || transcodes.contains { $0.0.frameRate > 31 } ? 60 : 30
    var bandwidth = 8_534_030
    return found.map { rendition, url, codecs in
      var r = rendition
      if r.key == "chunked" {
        r.height = sourceHeight
        r.width = sourceHeight * 16 / 9
        r.frameRate = sourceFPS
      }
      defer { bandwidth -= 100_000 }
      return HLSVariant(
        uri: url.absoluteString, bandwidth: r.isAudioOnly ? 160_000 : bandwidth, width: r.width, height: r.height,
        frameRate: r.frameRate, codecs: codecs, name: r.key == "chunked" ? "\(sourceHeight)p (source)" : r.key,
        isAudioOnly: r.isAudioOnly, isPortrait: false)
    }
  }

  /// Whether the playlist is there, and its codecs: MPEG-TS parts are H.264; fragmented MP4 is
  /// HEVC or H.264, read from its init segment.
  static func probe(_ url: URL, audioOnly: Bool, http: HTTPClient) async -> String? {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await http.data(for: request), response.statusCode == 200,
      let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U")
    else { return nil }
    if audioOnly { return "mp4a.40.2" }
    if text.contains(".ts") { return "avc1.4D001E,mp4a.40.2" }
    guard text.contains(".mp4") else { return nil }
    let initURL = mapURI(text).flatMap { URL(string: $0, relativeTo: url) }
      ?? URL(string: url.absoluteString.replacingOccurrences(of: "index-dvr.m3u8", with: "init-0.mp4"))
    guard let initURL else { return "hev1.1.6.L93.B0,mp4a.40.2" }
    var initRequest = URLRequest(url: initURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
    initRequest.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    guard let (box, initResponse) = try? await http.data(for: initRequest), initResponse.statusCode == 200 else {
      return "hev1.1.6.L93.B0,mp4a.40.2"
    }
    return codecs(initSegment: box)
  }

  static func codecs(initSegment box: Data) -> String {
    func has(_ tag: String) -> Bool { box.range(of: Data(tag.utf8)) != nil }
    if has("hev1") || has("hvc1") { return "hev1.1.6.L93.B0,mp4a.40.2" }
    if has("av01") { return "av01.0.08M.08,mp4a.40.2" }
    return "avc1.4D001E,mp4a.40.2"
  }

  /// The init segment named by `#EXT-X-MAP`, if any.
  static func mapURI(_ text: String) -> String? {
    for line in HLS.lines(text) where line.hasPrefix("#EXT-X-MAP:") {
      return HLS.attributes(line)["URI"]
    }
    return nil
  }
}

// MARK: - Loading a VOD's renditions

extension TwitchAPI {
  struct VODRenditions: Sendable {
    /// Best first, audio only last.
    var variants: [HLSVariant]
    /// It plays straight from the CDN: Twitch's playlist server refused it or didn't answer.
    var unlocked: Bool
    /// Twitch refused it outright (HTTP 403: sub-only, or the like), rather than failing to answer.
    var restricted: Bool = false
  }

  /// A VOD's renditions: from Twitch's playlist server, or (when it refuses, e.g. a sub-only VOD)
  /// worked out from the CDN.
  func vodRenditions(id: String, codecs: String, timeout: TimeInterval = 10) async throws -> VODRenditions {
    let http = URLSessionHTTPClient(timeout: timeout)
    var refusal = "Twitch didn't return the video."
    var restricted = false
    do {
      let token = try await videoToken(id: id)
      let url = Usher.vod(id: id, token: token, codecs: codecs)
      let (data, response) = try await http.data(for: Usher.playlistRequest(url, timeout: timeout))
      if response.statusCode == 200, let text = String(data: data, encoding: .utf8), HLS.looksLikePlaylist(data) {
        let master = HLSMaster.parse(text, base: response.url ?? url)
        let variants = master.videoVariants + (master.audioVariant.map { [$0] } ?? [])
        if !variants.isEmpty { return VODRenditions(variants: variants, unlocked: false) }
        refusal = "No playable qualities were found."
      } else {
        restricted = response.statusCode == 403
        refusal =
          response.statusCode == 403
          ? "This video is restricted (subscribers only or region locked)." : "Twitch returned HTTP \(response.statusCode)."
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      refusal = error.localizedDescription
    }
    // Closed while loading: don't go on to ask the CDN.
    try Task.checkCancellation()
    // Usher said no (or didn't answer): try the CDN directly.
    if let data = try? await query(RestrictedVOD.infoQuery, variables: ["id": id]),
      let info = RestrictedVOD.parseInfo(data)
    {
      let variants = await RestrictedVOD.variants(videoID: id, info: info, http: http)
      if !variants.isEmpty { return VODRenditions(variants: variants, unlocked: true, restricted: restricted) }
    }
    throw VODUnavailable(errorDescription: refusal)
  }
}

struct VODUnavailable: LocalizedError {
  var errorDescription: String?
}
