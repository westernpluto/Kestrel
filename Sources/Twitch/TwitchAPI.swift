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
  /// Where you left off on Twitch (seconds), when signed in.
  var watchedPosition: Double?
  var watchedAt: Date?
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

struct TwitchEmote: Hashable, Sendable {
  var id: String
  var token: String
  var setID: String?
  var ownerID: String?
  var type: String?

  var url: URL? { ChatMessage.twitchEmoteURL(id) }
}

struct TwitchEmoteGroup: Sendable {
  var ownerID: String?
  var ownerName: String?
  var ownerImage: String?
  var emotes: [TwitchEmote]
}

struct LiveArchive: Equatable, Sendable {
  var videoID: String
  /// When the recording (and the broadcast) started.
  var startedAt: Date
  var seekPreviewsURL: String?
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
  private let lock = NSLock()
  private var _playbackHTTP: HTTPClient?
  private var _lastAuthFallback: String?

  /// Used for playback tokens instead of `http` (e.g. through a proxy in an ad-free country).
  var playbackHTTP: HTTPClient? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _playbackHTTP
    }
    set {
      lock.lock()
      _playbackHTTP = newValue
      lock.unlock()
    }
  }

  private func noteAuthFallback(_ message: String) {
    lock.lock()
    _lastAuthFallback = message
    lock.unlock()
  }

  /// Set when a signed-in token request failed and an anonymous one was used instead.
  var lastAuthFallback: String? {
    lock.lock()
    defer { lock.unlock() }
    return _lastAuthFallback
  }

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

  private func request(body: [String: Any], anonymous: Bool = false) throws -> URLRequest {
    var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue(Self.webClientID, forHTTPHeaderField: "Client-ID")
    let auth = anonymous ? nil : TwitchAuth.shared.session
    request.setValue(auth?.deviceID ?? deviceID, forHTTPHeaderField: "X-Device-Id")
    if let auth { request.setValue("OAuth \(auth.token)", forHTTPHeaderField: "Authorization") }
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
  /// Browsing queries go out anonymously; only account features send the sign-in token.
  func query(_ text: String, variables: [String: Any] = [:], authenticated: Bool = false) async throws -> JSONValue {
    try await send(["query": text, "variables": variables], anonymous: !authenticated)
  }

  private func send(_ body: [String: Any], anonymous: Bool = false, via client: HTTPClient? = nil) async throws -> JSONValue {
    let (data, response) = try await (client ?? http).data(for: try request(body: body, anonymous: anonymous))
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
      categoryName: j["game"]["displayName"].string, owner: channel(j["owner"]) ?? owner,
      watchedPosition: j["self"]["viewingHistory"]["position"].int.map(Double.init),
      watchedAt: j["self"]["viewingHistory"]["updatedAt"].date)
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
    // Signed in: also where you left off in each one (Twitch's watch history).
    if TwitchAuth.shared.session != nil, let page = try? await videos(login: login, after: cursor, first: first, withHistory: true) {
      return page
    }
    return try await videos(login: login, after: cursor, first: first, withHistory: false)
  }

  private func videos(login: String, after cursor: String?, first: Int, withHistory: Bool) async throws -> Page<Video> {
    let history = withHistory ? " self { viewingHistory { position updatedAt } }" : ""
    let data = try await query(
      """
      query null($login: String, $sort: VideoSort, $types: [BroadcastType!], $first: Int, $after: Cursor) {
        user(login: $login, lookupType: ALL) {
          displayName id login profileImageURL(width: 300)
          videos(first: $first, after: $after, types: $types, sort: $sort) {
            edges { cursor node { broadcastType createdAt game { displayName id slug } id lengthSeconds previewThumbnailURL title viewCount\(history) } }
            pageInfo { hasNextPage }
          }
        }
      }
      """,
      variables: Self.vars(
        ["login": login.lowercased(), "sort": "TIME", "types": ["ARCHIVE", "HIGHLIGHT", "UPLOAD"], "first": first],
        after: cursor), authenticated: withHistory)
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
    guard TwitchAuth.shared.session != nil else {
      return try await playbackToken(login: login, vodID: vodID, playerType: playerType, platform: platform, anonymous: true)
    }
    do {
      return try await playbackToken(login: login, vodID: vodID, playerType: playerType, platform: platform, anonymous: false)
    } catch {
      // Twitch sometimes demands an integrity check for signed-in requests: watch anonymously.
      let token = try await playbackToken(login: login, vodID: vodID, playerType: playerType, platform: platform, anonymous: true)
      noteAuthFallback(error.localizedDescription)
      return token
    }
  }

  private func playbackToken(login: String?, vodID: String?, playerType: String, platform: String, anonymous: Bool)
    async throws -> PlaybackToken
  {
    let isLive = login != nil
    let client = playbackHTTP
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
      let data = try await send(
        [
          "operationName": "PlaybackAccessToken",
          "extensions": ["persistedQuery": persisted],
          "variables": variables,
        ], anonymous: anonymous, via: client)
      if let token = parse(data) { return token }
    } catch {
      lastError = error
    }
    // 2. Raw query fallback, in case the persisted hash rotates.
    do {
      let data: JSONValue
      if isLive {
        data = try await send(
          [
            "query": """
            query null($login: String!, $platform: String!, $playerType: String!) {
              streamPlaybackAccessToken(channelName: $login, params: { platform: $platform, playerType: $playerType }) { signature value }
            }
            """,
            "variables": ["login": login ?? "", "platform": platform, "playerType": playerType],
          ], anonymous: anonymous, via: client)
      } else {
        data = try await send(
          [
            "query": """
            query null($id: ID!, $platform: String!, $playerType: String!) {
              videoPlaybackAccessToken(id: $id, params: { platform: $platform, playerType: $playerType }) { signature value }
            }
            """,
            "variables": ["id": vodID ?? "", "platform": platform, "playerType": playerType],
          ], anonymous: anonymous, via: client)
      }
      if let token = parse(data) { return token }
    } catch {
      lastError = error
    }
    throw lastError
  }

  // MARK: Account

  /// Whether the signed-in account has Turbo (nil if unknown).
  func currentUserHasTurbo() async -> Bool? {
    guard TwitchAuth.shared.session != nil,
      let data = try? await query("query null { currentUser { login hasTurbo } }", authenticated: true)
    else {
      return nil
    }
    return data["currentUser"]["hasTurbo"].bool
  }

  struct FollowedChannel: Identifiable, Sendable {
    var channel: Channel
    var stream: LiveStream?
    var lastLive: Date?
    var id: String { channel.id }
  }

  /// The signed-in account's followed channels (up to 600), with who's live.
  func followedChannels() async throws -> [FollowedChannel] {
    guard TwitchAuth.shared.session != nil else { return [] }
    var result: [FollowedChannel] = []
    var cursor: String?
    for _ in 0..<6 {
      var variables: [String: Any] = [:]
      if let cursor { variables["after"] = cursor }
      let data = try await query(
        """
        query null($after: Cursor) {
          currentUser {
            follows(first: 100, after: $after) {
              edges {
                cursor
                node {
                  displayName id login profileImageURL(width: 300)
                  lastBroadcast { startedAt }
                  stream { createdAt game { boxArtURL displayName id slug } id previewImageURL title viewersCount }
                }
              }
              pageInfo { hasNextPage }
            }
          }
        }
        """, variables: variables, authenticated: true)
      let follows = data["currentUser"]["follows"]
      let edges = follows["edges"].array
      for edge in edges {
        let node = edge["node"]
        guard let channel = Self.channel(node) else { continue }
        let stream = node["stream"].isNull ? nil : Self.stream(node["stream"], channel: channel)
        result.append(FollowedChannel(channel: channel, stream: stream, lastLive: node["lastBroadcast"]["startedAt"].date))
      }
      guard follows["pageInfo"]["hasNextPage"].bool == true, let last = edges.last?["cursor"].string else { break }
      cursor = last
    }
    return result
  }

  // MARK: Emotes you can use

  /// The signed-in account's emotes that work in `channelID`'s chat (subs, follower emotes,
  /// Turbo/Prime sets, globals), grouped by owner.
  func availableEmotes(channelID: String?) async -> [TwitchEmoteGroup] {
    guard TwitchAuth.shared.session != nil else { return [] }
    var groups: [TwitchEmoteGroup] = []
    // 1. What the website's emote picker uses.
    if let channelID {
      var cursor: String?
      for _ in 0..<4 {
        var variables: [String: Any] = ["channelID": channelID, "pageLimit": 350, "withOwner": true]
        if let cursor { variables["cursor"] = cursor }
        guard
          let data = try? await send(
            [
              "operationName": "AvailableEmotesForChannelPaginated",
              "extensions": ["persistedQuery": ["version": 1, "sha256Hash": Self.availableEmotesHash] as [String: Any]],
              "variables": variables,
            ])
        else { break }
        let sets = data["channel"]["self"]["availableEmoteSetsPaginated"]
        for edge in sets["edges"].array {
          let node = edge["node"]
          let emotes = node["emotes"].array.compactMap(Self.twitchEmote)
          guard !emotes.isEmpty else { continue }
          let owner = node["owner"]
          groups.append(
            TwitchEmoteGroup(
              ownerID: owner["id"].string ?? emotes.first?.ownerID, ownerName: owner["displayName"].string ?? owner["login"].string,
              ownerImage: owner["profileImageURL"].string, emotes: emotes))
        }
        guard sets["pageInfo"]["hasNextPage"].bool == true, let next = sets["edges"].array.last?["cursor"].string else { break }
        cursor = next
      }
    }
    // 2. Fallback: every emote set the account owns.
    if groups.isEmpty,
      let data = try? await query(
        "query null { user { emoteSets { emotes { id owner { id } setID token type } } } }", authenticated: true)
    {
      var byOwner: [String: [TwitchEmote]] = [:]
      var order: [String] = []
      for set in data["user"]["emoteSets"].array {
        for emote in set["emotes"].array.compactMap(Self.twitchEmote) {
          // Follower emotes only work in their own channel.
          if emote.type?.uppercased() == "FOLLOWER", let owner = emote.ownerID, owner != channelID { continue }
          let key = emote.ownerID ?? "0"
          if byOwner[key] == nil { order.append(key) }
          byOwner[key, default: []].append(emote)
        }
      }
      groups = order.map { TwitchEmoteGroup(ownerID: $0, ownerName: nil, ownerImage: nil, emotes: byOwner[$0] ?? []) }
    }
    // Names and pictures for the owners the response didn't describe.
    let unnamed = groups.compactMap { $0.ownerName == nil ? $0.ownerID : nil }.filter { $0 != "0" && !$0.isEmpty }
    if !unnamed.isEmpty,
      let data = try? await query(
        "query null($ids: [ID!]) { users(ids: $ids) { id displayName login profileImageURL(width: 70) } }",
        variables: ["ids": Array(Set(unnamed)).prefix(100).map { $0 }])
    {
      var names: [String: (String, String?)] = [:]
      for user in data["users"].array {
        if let id = user["id"].string { names[id] = (user["displayName"].string ?? user["login"].string ?? id, user["profileImageURL"].string) }
      }
      for index in groups.indices {
        if groups[index].ownerName == nil, let id = groups[index].ownerID, let found = names[id] {
          groups[index].ownerName = found.0
          groups[index].ownerImage = found.1
        }
      }
    }
    return groups
  }

  static let availableEmotesHash = "6c45e0ecaa823cc7db3ecdd1502af2223c775bdcfb0f18a3a0ce9a0b7db8ef6c"

  static func twitchEmote(_ j: JSONValue) -> TwitchEmote? {
    guard let id = j["id"].string, var token = j["token"].string, !token.isEmpty else { return nil }
    let type = j["type"].string
    if type?.uppercased() == "SMILIES" {
      // Classic smileys are stored as regexes (e.g. "\\:-?\\)"): show the plain form.
      token = token.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "?", with: "")
        .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
      token = token.replacingOccurrences(of: #"\((.)\|.\)"#, with: "$1", options: .regularExpression)
      token = token.replacingOccurrences(of: #"\[(.).*?\]"#, with: "$1", options: .regularExpression)
    }
    return TwitchEmote(id: id, token: token, setID: j["setID"].string, ownerID: j["owner"]["id"].string, type: type)
  }

  // MARK: Rewinding a live stream

  /// The VOD being recorded for the live broadcast, if the channel saves VODs.
  func liveArchive(login: String) async -> LiveArchive? {
    let withStatus = try? await query(
      """
      query null($login: String) {
        user(login: $login, lookupType: ALL) {
          stream { createdAt id }
          videos(first: 1, types: [ARCHIVE], sort: TIME) { edges { node { createdAt id status seekPreviewsURL } } }
        }
      }
      """, variables: ["login": login.lowercased()])
    let data: JSONValue
    if let withStatus {
      data = withStatus
    } else if let plain = try? await query(
      """
      query null($login: String) {
        user(login: $login, lookupType: ALL) {
          stream { createdAt id }
          videos(first: 1, types: [ARCHIVE], sort: TIME) { edges { node { createdAt id } } }
        }
      }
      """, variables: ["login": login.lowercased()])
    {
      data = plain
    } else {
      return nil
    }
    let user = data["user"]
    guard !user["stream"].isNull, let streamStart = user["stream"]["createdAt"].date,
      let node = user["videos"]["edges"].array.first?["node"], let id = node["id"].string, let created = node["createdAt"].date
    else { return nil }
    if let status = node["status"].string, status.uppercased() != "RECORDING" { return nil }
    // The archive of this broadcast starts when the broadcast did.
    guard abs(created.timeIntervalSince(streamStart)) < 15 * 60 else { return nil }
    return LiveArchive(videoID: id, startedAt: created, seekPreviewsURL: node["seekPreviewsURL"].string)
  }

  /// Where a VOD's storyboard (seek preview thumbnails) is described.
  func seekPreviewsURL(videoID: String) async -> URL? {
    if let data = try? await query("query null($id: ID) { video(id: $id) { seekPreviewsURL } }", variables: ["id": videoID]),
      let url = data["video"]["seekPreviewsURL"].string.flatMap(URL.init(string:))
    {
      return url
    }
    let data = try? await send([
      "operationName": "VideoPlayer_VODSeekbarPreviewVideo",
      "extensions": ["persistedQuery": ["version": 1, "sha256Hash": "07e99e4d56c5a7c67117a154777b0baf85a5ffefa393b213f4bc712ccaf85dd6"] as [String: Any]],
      "variables": ["includePrivate": false, "videoID": videoID] as [String: Any],
    ], anonymous: true)
    return data?["video"]["seekPreviewsURL"].string.flatMap(URL.init(string:))
  }

  func storyboard(url: URL, duration: Double?) async -> Storyboard? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await http.data(for: request), response.statusCode == 200 else { return nil }
    return Storyboard.parse(data, base: url, duration: duration)
  }

  // MARK: VOD chat

  /// A page of a VOD's chat, starting at `offset` seconds or after `cursor`.
  func videoComments(videoID: String, offset: Int?, cursor: String?) async throws -> (
    comments: [ReplayComment], cursor: String?, hasMore: Bool
  ) {
    var variables: [String: Any] = ["id": videoID]
    if let cursor { variables["after"] = cursor } else { variables["offset"] = offset ?? 0 }
    do {
      let data = try await query(
        """
        query null($id: ID, $after: Cursor, $offset: Int) {
          video(id: $id) {
            comments(after: $after, contentOffsetSeconds: $offset) {
              edges {
                cursor
                node {
                  commenter { displayName id login }
                  contentOffsetSeconds createdAt id
                  message { fragments { emote { emoteID } text } userBadges { setID version } userColor }
                }
              }
              pageInfo { hasNextPage }
            }
          }
        }
        """, variables: variables)
      return VODComments.parsePage(data)
    } catch {
      // The website's own query (may need Twitch's integrity check).
      var persistedVariables: [String: Any] = ["videoID": videoID]
      if let cursor { persistedVariables["cursor"] = cursor } else { persistedVariables["contentOffsetSeconds"] = offset ?? 0 }
      let data = try await send(
        [
          "operationName": "VideoCommentsByOffsetOrCursor",
          "extensions": ["persistedQuery": ["version": 1, "sha256Hash": "b70a3591ff0f4e0313d126c6a1502d79a1c02baebb288227c582044aa76adf6a"] as [String: Any]],
          "variables": persistedVariables,
        ], anonymous: true)
      return VODComments.parsePage(data)
    }
  }

  // MARK: Where you left off (synced with Twitch)

  /// Your saved position in a VOD on Twitch, in seconds.
  func viewingPosition(videoID: String) async -> (position: Double, updated: Date?)? {
    guard TwitchAuth.shared.session != nil,
      let data = try? await query(
        "query null($id: ID) { video(id: $id) { self { viewingHistory { position updatedAt } } } }",
        variables: ["id": videoID], authenticated: true),
      let position = data["video"]["self"]["viewingHistory"]["position"].int
    else { return nil }
    return (Double(position), data["video"]["self"]["viewingHistory"]["updatedAt"].date)
  }

  /// Saves your position the way Twitch's player does, so the website and apps resume there.
  func saveViewingPosition(videoID: String, position: Double, live: Bool = false) async throws {
    guard let session = TwitchAuth.shared.session else { return }
    let input: [String: Any] = [
      "userID": session.userID, "videoID": videoID, "position": Int(position), "videoType": live ? "LIVE" : "VOD",
    ]
    let data = try await send(
      [
        "operationName": "updateUserViewedVideo",
        "query": """
          mutation updateUserViewedVideo($input: UpdateUserViewedVideoInput!) {
            updateUserViewedVideo(input: $input) { __typename }
          }
          """,
        "variables": ["input": input],
      ])
    if data["updateUserViewedVideo"].isNull { throw TwitchAPIError.gql("Twitch didn't save the position") }
  }

  /// A VOD's length so far (it grows while the broadcast is recorded) and its seek previews.
  func videoProgress(videoID: String) async -> (length: Double?, previews: URL?) {
    guard
      let data = try? await query(
        "query null($id: ID) { video(id: $id) { lengthSeconds seekPreviewsURL } }", variables: ["id": videoID])
    else { return (nil, nil) }
    return (data["video"]["lengthSeconds"].int.map(Double.init), data["video"]["seekPreviewsURL"].string.flatMap(URL.init(string:)))
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
