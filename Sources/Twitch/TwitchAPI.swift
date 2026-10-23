// Anonymous access to Twitch's GraphQL API (the same endpoint the website uses).
// Query shapes follow Xtra (github.com/crackededed/Xtra), which uses them in production.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Models

struct Channel: Identifiable, Hashable, Codable, Sendable {
  var id: String
  var login: String
  var displayName: String
  var profileImageURL: String?

  var name: String { displayName.isEmpty ? login : displayName }
}

struct Category: Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var slug: String?
  var boxArtURL: String?
  var viewers: Int
}

struct LiveStream: Identifiable, Hashable, Sendable {
  var id: String
  var title: String
  var viewers: Int
  var previewImageURL: String?
  var startedAt: Date?
  var category: Category?
  var channel: Channel
}

struct Video: Identifiable, Hashable, Sendable {
  var id: String
  var title: String
  var lengthSeconds: Int
  var previewURL: String?
  var createdAt: Date?
  var viewCount: Int
  var categoryName: String?
  var owner: Channel?
}

struct ChannelPage: Sendable {
  var channel: Channel
  var description: String?
  var followers: Int?
  var bannerURL: String?
  var lastBroadcast: Date?
  var stream: LiveStream?
}

struct Page<Item: Sendable>: Sendable {
  var items: [Item]
  var cursor: String?
  var hasNextPage: Bool
}

struct ChannelSearchResult: Identifiable, Hashable, Sendable {
  var channel: Channel
  var followers: Int?
  var liveViewers: Int?
  var id: String { channel.id }
}

struct Badge: Sendable {
  var setID: String
  var version: String
  var title: String
  var imageURL: String
}

enum TwitchAPIError: Error, LocalizedError {
  case gql(String)
  case http(Int)
  case decoding
  case noToken

  var errorDescription: String? {
    switch self {
    case .gql(let message): return "Twitch: \(message)"
    case .http(let status): return "Twitch returned HTTP \(status)."
    case .decoding: return "Unexpected response from Twitch."
    case .noToken: return "Twitch didn't return a playback token (the channel may be offline)."
    }
  }
}

// MARK: - Tiny JSON helper

struct JSONValue {
  let raw: Any?
  init(_ raw: Any?) { self.raw = raw is NSNull ? nil : raw }
  subscript(key: String) -> JSONValue { JSONValue((raw as? [String: Any])?[key]) }
  subscript(index: Int) -> JSONValue {
    guard let array = raw as? [Any], index >= 0, index < array.count else { return JSONValue(nil) }
    return JSONValue(array[index])
  }
  var string: String? {
    if let s = raw as? String { return s }
    if let n = raw as? NSNumber { return n.stringValue }
    return nil
  }
  var int: Int? {
    if let n = raw as? NSNumber { return n.intValue }
    if let s = raw as? String { return Int(s) }
    return nil
  }
  var bool: Bool? { (raw as? NSNumber)?.boolValue ?? (raw as? Bool) }
  var array: [JSONValue] { (raw as? [Any])?.map(JSONValue.init) ?? [] }
  var dictionary: [String: JSONValue] { ((raw as? [String: Any]) ?? [:]).mapValues(JSONValue.init) }
  var isNull: Bool { raw == nil }
  var date: Date? { string.flatMap(HLSDate.parse) }
}

// MARK: - API

final class TwitchAPI: PlaybackTokenProvider, @unchecked Sendable {
  static let shared = TwitchAPI(http: URLSessionHTTPClient(timeout: 12))

  static let webClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
  static let playbackAccessTokenHash = "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"

  let http: HTTPClient
  let deviceID: String

  init(http: HTTPClient, deviceID: String? = nil) {
    self.http = http
    if let deviceID {
      self.deviceID = deviceID
    } else if let stored = UserDefaults.standard.string(forKey: "kestrel.deviceID"), stored.count == 32 {
      self.deviceID = stored
    } else {
      let generated = (0..<32).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
      UserDefaults.standard.set(generated, forKey: "kestrel.deviceID")
      self.deviceID = generated
    }
  }

  private func request(body: [String: Any]) throws -> URLRequest {
    var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue(Self.webClientID, forHTTPHeaderField: "Client-ID")
    request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private static func vars(_ base: [String: Any], after cursor: String?) -> [String: Any] {
    var v = base
    if let cursor { v["after"] = cursor }
    return v
  }

  /// Sends a raw query. Like Xtra, the operation is named `null`.
  func query(_ text: String, variables: [String: Any] = [:]) async throws -> JSONValue {
    try await send(["query": text, "variables": variables])
  }

  private func send(_ body: [String: Any]) async throws -> JSONValue {
    let (data, response) = try await http.data(for: try request(body: body))
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      throw response.statusCode == 200 ? TwitchAPIError.decoding : TwitchAPIError.http(response.statusCode)
    }
    let json = JSONValue(object)
    if json["data"].isNull, let message = json["errors"][0]["message"].string ?? json["message"].string {
      throw TwitchAPIError.gql(message)
    }
    if json["data"].isNull { throw TwitchAPIError.http(response.statusCode) }
    return json["data"]
  }

  // MARK: Parsing helpers

  static func channel(_ j: JSONValue) -> Channel? {
    guard let id = j["id"].string, let login = j["login"].string else { return nil }
    return Channel(id: id, login: login, displayName: j["displayName"].string ?? login, profileImageURL: j["profileImageURL"].string)
  }

  static func category(_ j: JSONValue) -> Category? {
    guard let id = j["id"].string else { return nil }
    return Category(
      id: id, name: j["displayName"].string ?? j["name"].string ?? "", slug: j["slug"].string,
      boxArtURL: j["boxArtURL"].string, viewers: j["viewersCount"].int ?? 0)
  }

  static func stream(_ j: JSONValue, channel fallback: Channel? = nil) -> LiveStream? {
    guard let channel = channel(j["broadcaster"]) ?? fallback else { return nil }
    let title = j["broadcaster"]["broadcastSettings"]["title"].string ?? j["title"].string ?? ""
    return LiveStream(
      id: j["id"].string ?? channel.id, title: title, viewers: j["viewersCount"].int ?? 0,
      previewImageURL: j["previewImageURL"].string, startedAt: j["createdAt"].date,
      category: category(j["game"]), channel: channel)
  }

  static func video(_ j: JSONValue, owner: Channel? = nil) -> Video? {
    guard let id = j["id"].string else { return nil }
    return Video(
      id: id, title: j["title"].string ?? "", lengthSeconds: j["lengthSeconds"].int ?? 0,
      previewURL: j["previewThumbnailURL"].string, createdAt: j["createdAt"].date, viewCount: j["viewCount"].int ?? 0,
      categoryName: j["game"]["displayName"].string, owner: channel(j["owner"]) ?? owner)
  }

  private static func page<T>(_ connection: JSONValue, _ map: (JSONValue) -> T?) -> Page<T> {
    let edges = connection["edges"].array
    return Page(
      items: edges.compactMap { map($0["node"]) }, cursor: edges.last?["cursor"].string,
      hasNextPage: connection["pageInfo"]["hasNextPage"].bool ?? !edges.isEmpty)
  }

  private static let streamFields = """
    broadcaster { broadcastSettings { title } displayName id login profileImageURL(width: 300) }
    createdAt game { displayName id slug } id previewImageURL viewersCount
    """

  // MARK: Browse

  func topStreams(after cursor: String? = nil, first: Int = 30) async throws -> Page<LiveStream> {
    let data = try await query(
      """
      query null($sort: StreamSort, $first: Int, $after: Cursor) {
        streams(first: $first, after: $after, options: { sort: $sort }) {
          edges { cursor node { \(Self.streamFields) } }
          pageInfo { hasNextPage }
        }
      }
      """, variables: Self.vars(["sort": "VIEWER_COUNT", "first": first], after: cursor))
    return Self.page(data["streams"]) { Self.stream($0) }
  }

  func topCategories(after cursor: String? = nil, first: Int = 40) async throws -> Page<Category> {
    let data = try await query(
      """
      query null($first: Int, $after: Cursor) {
        games(first: $first, after: $after) {
          edges { cursor node { boxArtURL displayName id slug viewersCount } }
          pageInfo { hasNextPage }
        }
      }
      """, variables: Self.vars(["first": first], after: cursor))
    return Self.page(data["games"]) { Self.category($0) }
  }

  func categoryStreams(id: String, after cursor: String? = nil, first: Int = 30) async throws -> Page<LiveStream> {
    let data = try await query(
      """
      query null($id: ID, $sort: StreamSort, $first: Int, $after: Cursor) {
        game(id: $id) {
          streams(first: $first, after: $after, options: { sort: $sort }) {
            edges { cursor node { \(Self.streamFields) } }
            pageInfo { hasNextPage }
          }
        }
      }
      """, variables: Self.vars(["id": id, "sort": "VIEWER_COUNT", "first": first], after: cursor))
    return Self.page(data["game"]["streams"]) { Self.stream($0) }
  }

  // MARK: Search

  func searchChannels(_ text: String, first: Int = 25) async throws -> [ChannelSearchResult] {
    let data = try await query(
      """
      query null($query: String!, $first: Int) {
        searchUsers(userQuery: $query, first: $first) {
          edges { node { displayName followers { totalCount } id login profileImageURL(width: 300) stream { viewersCount } } }
        }
      }
      """, variables: ["query": text, "first": first])
    return data["searchUsers"]["edges"].array.compactMap { edge in
      let node = edge["node"]
      guard let channel = Self.channel(node) else { return nil }
      return ChannelSearchResult(
        channel: channel, followers: node["followers"]["totalCount"].int,
        liveViewers: node["stream"].isNull ? nil : (node["stream"]["viewersCount"].int ?? 0))
    }
  }

  func searchCategories(_ text: String, first: Int = 25) async throws -> [Category] {
    let data = try await query(
      """
      query null($query: String!, $first: Int) {
        searchCategories(query: $query, first: $first) {
          edges { node { boxArtURL displayName id slug viewersCount } }
        }
      }
      """, variables: ["query": text, "first": first])
    return data["searchCategories"]["edges"].array.compactMap { Self.category($0["node"]) }
  }

  // MARK: Channels

  /// Live status for a list of channels (used by the Following tab).
  func users(logins: [String]) async throws -> [(Channel, LiveStream?)] {
    guard !logins.isEmpty else { return [] }
    var result: [(Channel, LiveStream?)] = []
    for chunk in stride(from: 0, to: logins.count, by: 50).map({ Array(logins[$0..<min($0 + 50, logins.count)]) }) {
      let data = try await query(
        """
        query null($logins: [String!]) {
          users(logins: $logins) {
            displayName id login profileImageURL(width: 300)
            stream { broadcaster { broadcastSettings { title } } createdAt game { displayName id slug } id previewImageURL viewersCount }
          }
        }
        """, variables: ["logins": chunk])
      for user in data["users"].array {
        guard let channel = Self.channel(user) else { continue }
        let stream = user["stream"].isNull ? nil : Self.stream(user["stream"], channel: channel)
        result.append((channel, stream))
      }
    }
    return result
  }

  func channelPage(login: String) async throws -> ChannelPage? {
    let data = try await query(
      """
      query null($login: String) {
        user(login: $login, lookupType: ALL) {
          bannerImageURL description displayName followers { totalCount } id login profileImageURL(width: 300)
          lastBroadcast { startedAt }
          stream { createdAt game { displayName id slug } id previewImageURL title viewersCount }
        }
      }
      """, variables: ["login": login.lowercased()])
    let user = data["user"]
    guard let channel = Self.channel(user) else { return nil }
    return ChannelPage(
      channel: channel, description: user["description"].string, followers: user["followers"]["totalCount"].int,
      bannerURL: user["bannerImageURL"].string, lastBroadcast: user["lastBroadcast"]["startedAt"].date,
      stream: user["stream"].isNull ? nil : Self.stream(user["stream"], channel: channel))
  }

  func videos(login: String, after cursor: String? = nil, first: Int = 20) async throws -> Page<Video> {
    let data = try await query(
      """
      query null($login: String, $sort: VideoSort, $types: [BroadcastType!], $first: Int, $after: Cursor) {
        user(login: $login, lookupType: ALL) {
          displayName id login profileImageURL(width: 300)
          videos(first: $first, after: $after, types: $types, sort: $sort) {
            edges { cursor node { broadcastType createdAt game { displayName id slug } id lengthSeconds previewThumbnailURL title viewCount } }
            pageInfo { hasNextPage }
          }
        }
      }
      """,
      variables: Self.vars(
        ["login": login.lowercased(), "sort": "TIME", "types": ["ARCHIVE", "HIGHLIGHT", "UPLOAD"], "first": first],
        after: cursor))
    let owner = Self.channel(data["user"])
    return Self.page(data["user"]["videos"]) { Self.video($0, owner: owner) }
  }

  // MARK: Chat badges

  func badges(channelID: String?) async -> [String: Badge] {
    var result: [String: Badge] = [:]
    func add(_ list: [JSONValue]) {
      for b in list {
        guard let set = b["setID"].string, let version = b["version"].string, let url = b["imageURL"].string else { continue }
        result["\(set)/\(version)"] = Badge(setID: set, version: version, title: b["title"].string ?? set, imageURL: url)
      }
    }
    if let data = try? await query("query null { badges { imageURL(size: DOUBLE) setID title version } }") {
      add(data["badges"].array)
    }
    if let channelID,
      let data = try? await query(
        "query null($id: ID) { user(id: $id, lookupType: ALL) { broadcastBadges { imageURL(size: DOUBLE) setID title version } } }",
        variables: ["id": channelID])
    {
      add(data["user"]["broadcastBadges"].array)
    }
    return result
  }

  // MARK: Playback tokens

  func streamToken(login: String, playerType: String, platform: String) async throws -> PlaybackToken {
    try await playbackToken(login: login, vodID: nil, playerType: playerType, platform: platform)
  }

  func videoToken(id: String) async throws -> PlaybackToken {
    try await playbackToken(login: nil, vodID: id, playerType: "site", platform: "web")
  }

  private func playbackToken(login: String?, vodID: String?, playerType: String, platform: String) async throws
    -> PlaybackToken
  {
    let isLive = login != nil
    let key = isLive ? "streamPlaybackAccessToken" : "videoPlaybackAccessToken"
    func parse(_ data: JSONValue) -> PlaybackToken? {
      let t = data[key]
      guard let value = t["value"].string, let signature = t["signature"].string else { return nil }
      return PlaybackToken(value: value, signature: signature)
    }
    var lastError: Error = TwitchAPIError.noToken
    // 1. Persisted query used by the website (and streamlink / Xtra).
    do {
      let persisted: [String: Any] = ["version": 1, "sha256Hash": Self.playbackAccessTokenHash]
      let variables: [String: Any] = [
        "isLive": isLive, "login": login ?? "", "isVod": !isLive, "vodID": vodID ?? "",
        "playerType": playerType, "platform": platform,
      ]
      let data = try await send([
        "operationName": "PlaybackAccessToken",
        "extensions": ["persistedQuery": persisted],
        "variables": variables,
      ])
      if let token = parse(data) { return token }
    } catch {
      lastError = error
    }
    // 2. Raw query fallback, in case the persisted hash rotates.
    do {
      let data: JSONValue
      if isLive {
        data = try await query(
          """
          query null($login: String!, $platform: String!, $playerType: String!) {
            streamPlaybackAccessToken(channelName: $login, params: { platform: $platform, playerType: $playerType }) { signature value }
          }
          """, variables: ["login": login ?? "", "platform": platform, "playerType": playerType])
      } else {
        data = try await query(
          """
          query null($id: ID!, $platform: String!, $playerType: String!) {
            videoPlaybackAccessToken(id: $id, params: { platform: $platform, playerType: $playerType }) { signature value }
          }
          """, variables: ["id": vodID ?? "", "platform": platform, "playerType": playerType])
      }
      if let token = parse(data) { return token }
    } catch {
      lastError = error
    }
    throw lastError
  }

  // MARK: Image URL helpers

  static func image(_ template: String?, width: Int, height: Int) -> URL? {
    guard var s = template, !s.isEmpty else { return nil }
    if s.contains("{width}") || s.contains("%{width}") {
      s = s.replacingOccurrences(of: "%{width}", with: "\(width)").replacingOccurrences(of: "%{height}", with: "\(height)")
      s = s.replacingOccurrences(of: "{width}", with: "\(width)").replacingOccurrences(of: "{height}", with: "\(height)")
    } else if let range = s.range(of: #"-\d+x\d+\."#, options: .regularExpression) {
      s.replaceSubrange(range, with: "-\(width)x\(height).")
    }
    return URL(string: s)
  }
}
