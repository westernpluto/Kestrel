// Twitch chat (IRC over WebSocket) parsing and third-party emotes. Foundation only.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct IRCMessage: Equatable {
  var tags: [String: String]
  var prefix: String?
  var command: String
  var params: [String]

  var trailing: String? { params.last }
  var nick: String? { prefix?.split(separator: "!").first.map(String.init) }

  static func unescapeTag(_ value: Substring) -> String {
    guard value.contains("\\") else { return String(value) }
    var result = ""
    var escaping = false
    for c in value {
      if escaping {
        switch c {
        case ":": result.append(";")
        case "s": result.append(" ")
        case "r": result.append("\r")
        case "n": result.append("\n")
        default: result.append(c)
        }
        escaping = false
      } else if c == "\\" {
        escaping = true
      } else {
        result.append(c)
      }
    }
    return result
  }

  static func parse(_ raw: String) -> IRCMessage? {
    var rest = Substring(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")))
    guard !rest.isEmpty else { return nil }
    var tags: [String: String] = [:]
    if rest.hasPrefix("@") {
      guard let space = rest.firstIndex(of: " ") else { return nil }
      for pair in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";") {
        if let eq = pair.firstIndex(of: "=") {
          tags[String(pair[..<eq])] = unescapeTag(pair[pair.index(after: eq)...])
        } else {
          tags[String(pair)] = ""
        }
      }
      rest = rest[rest.index(after: space)...].drop { $0 == " " }
    }
    var prefix: String?
    if rest.hasPrefix(":") {
      guard let space = rest.firstIndex(of: " ") else { return nil }
      prefix = String(rest[rest.index(after: rest.startIndex)..<space])
      rest = rest[rest.index(after: space)...].drop { $0 == " " }
    }
    var params: [String] = []
    var command = ""
    while !rest.isEmpty {
      if rest.hasPrefix(":"), !command.isEmpty {
        params.append(String(rest.dropFirst()))
        break
      }
      let end = rest.firstIndex(of: " ") ?? rest.endIndex
      let token = String(rest[..<end])
      if command.isEmpty { command = token } else { params.append(token) }
      rest = end == rest.endIndex ? "" : rest[rest.index(after: end)...].drop { $0 == " " }
    }
    guard !command.isEmpty else { return nil }
    return IRCMessage(tags: tags, prefix: prefix, command: command, params: params)
  }
}

enum ChatFragment: Equatable {
  case text(String)
  case emote(name: String, url: URL)
  /// A GIF from Twitch's GIF keyboard (Tier 2 and 3 subs): its name (the placeholder text) and
  /// picture.
  case gif(name: String, url: URL)
}

struct ChatMessage: Identifiable, Equatable {
  enum Kind: Equatable { case message, action, system, notice }

  var id: String
  var kind: Kind
  var login: String
  var displayName: String
  var color: String?
  var badges: [String]  // "subscriber/12"
  var text: String
  var systemText: String?
  /// Twitch emotes: id and Unicode-scalar ranges into `text`.
  var emotes: [(id: String, range: ClosedRange<Int>)]
  /// GIFs from Twitch's GIF keyboard: id, picture, and the Unicode-scalar range of the
  /// placeholder text they stand for (the IRC `gifs` tag).
  var gifs: [(id: String, url: URL, range: ClosedRange<Int>)] = []
  var timestamp: Date
  var isDeleted = false
  /// The sender's Twitch id (IRC `user-id`), for their personal 7TV emotes.
  var userID: String? = nil

  static func == (a: ChatMessage, b: ChatMessage) -> Bool { a.id == b.id && a.isDeleted == b.isDeleted }

  init?(irc: IRCMessage) {
    let tags = irc.tags
    switch irc.command {
    case "PRIVMSG", "USERNOTICE":
      var text = irc.params.count > 1 ? irc.trailing ?? "" : ""
      var kind: Kind = irc.command == "USERNOTICE" ? .system : .message
      if text.hasPrefix("\u{1}ACTION "), text.hasSuffix("\u{1}") {
        text = String(text.dropFirst(8).dropLast())
        kind = .action
      }
      id = tags["id"] ?? UUID().uuidString
      self.kind = kind
      login = tags["login"] ?? irc.nick ?? ""
      displayName = tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? login
      color = tags["color"].flatMap { $0.isEmpty ? nil : $0 }
      badges = (tags["badges"] ?? "").split(separator: ",").map(String.init)
      self.text = text
      systemText = irc.command == "USERNOTICE" ? tags["system-msg"] : nil
      emotes = Self.parseEmotes(tags["emotes"] ?? "")
      userID = tags["user-id"]
      if irc.command == "PRIVMSG" { gifs = Self.parseGifs(tags["gifs"] ?? "") }
      timestamp = tags["tmi-sent-ts"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
      if kind == .system, systemText == nil, text.isEmpty { return nil }
    case "NOTICE":
      id = tags["msg-id"].map { "\($0)-\(UUID().uuidString)" } ?? UUID().uuidString
      kind = .notice
      login = ""
      displayName = ""
      color = nil
      badges = []
      text = irc.trailing ?? ""
      systemText = nil
      emotes = []
      timestamp = Date()
    default:
      return nil
    }
  }

  /// A message you sent: Twitch doesn't echo your own messages, so it's shown from your
  /// USERSTATE (name, color, badges).
  init(sent text: String, userState: [String: String], login: String, emoteIDs: [String: String] = [:]) {
    var body = text
    var kind: Kind = .message
    if body.hasPrefix("/me ") {
      body = String(body.dropFirst(4))
      kind = .action
    }
    id = "local-\(UUID().uuidString)"
    self.kind = kind
    self.login = login
    displayName = userState["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? login
    color = userState["color"].flatMap { $0.isEmpty ? nil : $0 }
    badges = (userState["badges"] ?? "").split(separator: ",").map(String.init)
    self.text = body
    systemText = nil
    emotes = Self.emoteRanges(in: body, ids: emoteIDs)
    timestamp = Date()
  }

  /// Twitch emotes in your own text (Twitch doesn't send them back): whole words matching an
  /// emote you have, as Unicode-scalar ranges like the IRC `emotes` tag.
  static func emoteRanges(in text: String, ids: [String: String]) -> [(id: String, range: ClosedRange<Int>)] {
    guard !ids.isEmpty else { return [] }
    var result: [(String, ClosedRange<Int>)] = []
    var offset = 0
    var word = ""
    var start = 0
    func flush() {
      if !word.isEmpty, let id = ids[word] { result.append((id, start...(offset - 1))) }
      word = ""
    }
    for scalar in text.unicodeScalars {
      if scalar == " " {
        flush()
        offset += 1
        start = offset
      } else {
        if word.isEmpty { start = offset }
        word.unicodeScalars.append(scalar)
        offset += 1
      }
    }
    flush()
    return result
  }

  /// A line from Kestrel itself (connection state, chat rules).
  init(notice text: String) {
    id = "notice-\(UUID().uuidString)"
    kind = .notice
    login = ""
    displayName = ""
    color = nil
    badges = []
    self.text = text
    systemText = nil
    emotes = []
    timestamp = Date()
  }

  /// Whether the message mentions `login` (for highlighting).
  func mentions(_ login: String) -> Bool {
    !login.isEmpty && text.range(of: "@\(login)", options: .caseInsensitive) != nil
  }

  static func parseEmotes(_ tag: String) -> [(id: String, range: ClosedRange<Int>)] {
    var result: [(String, ClosedRange<Int>)] = []
    for entry in tag.split(separator: "/") {
      let parts = entry.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { continue }
      for span in parts[1].split(separator: ",") {
        let bounds = span.split(separator: "-")
        guard bounds.count == 2, let a = Int(bounds[0]), let b = Int(bounds[1]), a <= b else { continue }
        result.append((String(parts[0]), a...b))
      }
    }
    return result.sorted { $0.1.lowerBound < $1.1.lowerBound }
  }

  /// The `gifs` tag: `start-end|id|url`, comma-separated. Commas aren't escaped (a URL can hold
  /// one), so it's split only at a comma followed by the next `digits-digits|`.
  static func parseGifs(_ tag: String) -> [(id: String, url: URL, range: ClosedRange<Int>)] {
    guard !tag.isEmpty else { return [] }
    var entries: [Substring] = []
    var start = tag.startIndex
    var index = tag.startIndex
    while index < tag.endIndex {
      if tag[index] == ",", Self.startsEntry(tag[tag.index(after: index)...]) {
        entries.append(tag[start..<index])
        start = tag.index(after: index)
      }
      index = tag.index(after: index)
    }
    entries.append(tag[start...])
    var result: [(String, URL, ClosedRange<Int>)] = []
    for entry in entries {
      let parts = entry.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3 else { continue }
      let bounds = parts[0].split(separator: "-")
      guard bounds.count == 2, let a = Int(bounds[0]), let b = Int(bounds[1]), a <= b, !parts[1].isEmpty,
        let url = URL(string: String(parts[2])), url.scheme == "https"
      else { continue }
      result.append((String(parts[1]), url, a...b))
    }
    return result.sorted { $0.2.lowerBound < $1.2.lowerBound }
  }

  private static func startsEntry(_ text: Substring) -> Bool {
    var sawDigit = false
    var sawDash = false
    for character in text {
      if character.isASCII, character.isNumber {
        sawDigit = true
      } else if character == "-", sawDigit, !sawDash {
        sawDash = true
        sawDigit = false
      } else {
        return character == "|" && sawDash && sawDigit
      }
    }
    return false
  }

  static func twitchEmoteURL(_ id: String) -> URL? {
    URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0")
  }

  /// Splits the text into plain text and emotes (Twitch emotes by position, third-party by word).
  func fragments(thirdParty: [String: URL]) -> [ChatFragment] {
    let scalars = Array(text.unicodeScalars)
    var pieces: [ChatFragment] = []
    var cursor = 0
    func appendText(_ from: Int, _ to: Int) {
      guard from < to else { return }
      var s = String.UnicodeScalarView()
      s.append(contentsOf: scalars[from..<to])
      pieces.append(contentsOf: Self.splitThirdParty(String(s), thirdParty))
    }
    // Twitch emotes and GIFs, in order.
    let placed: [(range: ClosedRange<Int>, url: URL?, gif: Bool)] =
      (emotes.map { ($0.range, Self.twitchEmoteURL($0.id), false) } + gifs.map { ($0.range, Optional($0.url), true) })
      .sorted { $0.range.lowerBound < $1.range.lowerBound }
    for item in placed {
      let start = item.range.lowerBound
      let end = item.range.upperBound + 1
      guard start >= cursor, end <= scalars.count, let url = item.url else { continue }
      appendText(cursor, start)
      var name = String.UnicodeScalarView()
      name.append(contentsOf: scalars[start..<end])
      pieces.append(item.gif ? .gif(name: String(name), url: url) : .emote(name: String(name), url: url))
      cursor = end
    }
    appendText(cursor, scalars.count)
    // merge adjacent text pieces
    var merged: [ChatFragment] = []
    for piece in pieces {
      if case .text(let t) = piece, case .text(let previous)? = merged.last {
        merged[merged.count - 1] = .text(previous + t)
      } else {
        merged.append(piece)
      }
    }
    return merged
  }

  private static func splitThirdParty(_ text: String, _ emotes: [String: URL]) -> [ChatFragment] {
    guard !emotes.isEmpty else { return [.text(text)] }
    var result: [ChatFragment] = []
    var buffer = ""
    var word = ""
    func flushWord() {
      if let url = emotes[word] {
        if !buffer.isEmpty { result.append(.text(buffer)) }
        buffer = ""
        result.append(.emote(name: word, url: url))
      } else {
        buffer += word
      }
      word = ""
    }
    for character in text {
      if character == " " {
        flushWord()
        buffer.append(character)
      } else {
        word.append(character)
      }
    }
    flushWord()
    if !buffer.isEmpty { result.append(.text(buffer)) }
    return result
  }
}

// MARK: - Message box text

/// How the message box shows a message: finished words that are emotes (a space after them)
/// become pictures, the rest stays text. Positions are UTF-16 offsets; a picture counts as one.
enum EmoteText {
  enum Piece: Equatable {
    case text(String)
    case emote(String)
  }

  /// - Parameter cursor: a position in `text`. Returns where it lands in what's shown.
  static func pieces(_ text: String, cursor: Int, isEmote: (String) -> Bool) -> (pieces: [Piece], cursor: Int) {
    let source = text as NSString
    var pieces: [Piece] = []
    var shownLength = 0
    var shownCursor: Int?
    var index = 0
    while index < source.length {
      if source.character(at: index) == 32 {
        if shownCursor == nil, cursor == index { shownCursor = shownLength }
        pieces.append(.text(" "))
        shownLength += 1
        index += 1
        continue
      }
      var end = index
      while end < source.length, source.character(at: end) != 32 { end += 1 }
      let word = source.substring(with: NSRange(location: index, length: end - index))
      if end < source.length, isEmote(word) {
        if shownCursor == nil, cursor == index { shownCursor = shownLength }
        if shownCursor == nil, cursor > index, cursor < end { shownCursor = shownLength + 1 }
        pieces.append(.emote(word))
        shownLength += 1
      } else {
        if shownCursor == nil, cursor >= index, cursor < end { shownCursor = shownLength + (cursor - index) }
        pieces.append(.text(word))
        shownLength += end - index
      }
      index = end
    }
    return (pieces, min(shownCursor ?? shownLength, shownLength))
  }
}

// MARK: - VOD chat (replay)

/// A VOD chat message and when it was sent, in seconds into the video.
struct ReplayComment {
  var offset: Double
  var message: ChatMessage
}

extension ChatMessage {
  /// A message from Twitch's VOD comments (`video.comments` nodes).
  init?(comment node: JSONValue) {
    guard let id = node["id"].string else { return nil }
    let fragments = node["message"]["fragments"].array
    var text = ""
    var emotes: [(id: String, range: ClosedRange<Int>)] = []
    var offset = 0
    for fragment in fragments {
      let piece = fragment["text"].string ?? ""
      let length = piece.unicodeScalars.count
      if let emote = fragment["emote"]["emoteID"].string ?? fragment["emote"]["id"].string, length > 0 {
        emotes.append((emote, offset...(offset + length - 1)))
      }
      text += piece
      offset += length
    }
    guard !text.isEmpty else { return nil }
    let commenter = node["commenter"]
    let login = commenter["login"].string ?? ""
    self.init(notice: text)
    self.id = id
    kind = .message
    self.login = login
    displayName = commenter["displayName"].string ?? login
    color = node["message"]["userColor"].string.flatMap { $0.isEmpty ? nil : $0 }
    badges = node["message"]["userBadges"].array.compactMap { badge in
      guard let set = badge["setID"].string, let version = badge["version"].string, !set.isEmpty else { return nil }
      return "\(set)/\(version)"
    }
    self.emotes = emotes
    timestamp = node["createdAt"].date ?? Date()
  }
}

/// The VOD chat replay's bookkeeping, separate from the network: what's been fetched, what's been
/// shown, and where the next page starts. Twitch only lets other apps page VOD chat by time (not
/// by its cursors), so pages are asked for by offset.
struct ChatReplayBuffer {
  private(set) var position: Double = -1
  private(set) var nextOffset = 0
  private(set) var exhaustedAt: Date?
  private(set) var loading = false
  private var queue: [ReplayComment] = []
  private var seen: Set<String> = []
  /// Bumped on every seek, so pages that arrive late for an old position are ignored.
  private(set) var generation = 0

  /// Moves to `position`. Returns true when that's a seek (chat should start over).
  mutating func move(to position: Double) -> Bool {
    let jumped = self.position < 0 || position < self.position - 3 || position > self.position + 25
    self.position = position
    guard jumped else { return false }
    generation += 1
    queue = []
    seen = []
    nextOffset = max(0, Int(position) - 20)
    exhaustedAt = nil
    loading = false
    return true
  }

  /// The offset to fetch now, if chat is running low (about half a minute is kept ready).
  mutating func fetchNeeded(now: Date = Date()) -> Int? {
    guard !loading else { return nil }
    if let exhaustedAt, now.timeIntervalSince(exhaustedAt) < 20 { return nil }
    let readyUntil = queue.last?.offset ?? Double(nextOffset)
    guard readyUntil < position + 30 || queue.isEmpty && Double(nextOffset) <= position + 30 else { return nil }
    loading = true
    return nextOffset
  }

  /// A page arrived for `offset` (ignored if it's for an old position).
  mutating func received(_ comments: [ReplayComment], for offset: Int, generation: Int, now: Date = Date()) {
    guard generation == self.generation else { return }
    loading = false
    let fresh = comments.filter { seen.insert($0.message.id).inserted }
    if let last = comments.last {
      // Next page from the last second seen (its messages already seen are skipped); a page with
      // nothing new moves a second on.
      let lastSecond = Int(last.offset)
      nextOffset = fresh.isEmpty || lastSecond <= offset ? max(offset, lastSecond) + 1 : lastSecond
      exhaustedAt = nil
    } else {
      exhaustedAt = now
    }
    queue = (queue + fresh).sorted { $0.offset < $1.offset }
  }

  mutating func failed(generation: Int, now: Date = Date()) {
    guard generation == self.generation else { return }
    loading = false
    exhaustedAt = now
  }

  /// Messages due by now.
  mutating func due() -> [ChatMessage] {
    var count = 0
    while count < queue.count, queue[count].offset <= position { count += 1 }
    guard count > 0 else { return [] }
    let messages = queue.prefix(count).map(\.message)
    queue.removeFirst(count)
    return messages
  }
}

enum VODComments {
  /// One page of comments: from an offset into the video, or after a cursor.
  static func parsePage(_ data: JSONValue) -> (comments: [ReplayComment], cursor: String?, hasMore: Bool) {
    let connection = data["video"]["comments"]
    let edges = connection["edges"].array
    let comments = edges.compactMap { edge -> ReplayComment? in
      let node = edge["node"]
      guard let message = ChatMessage(comment: node) else { return nil }
      return ReplayComment(offset: Double(node["contentOffsetSeconds"].int ?? 0), message: message)
    }
    let more = connection["pageInfo"]["hasNextPage"].bool ?? !edges.isEmpty
    return (comments, edges.last?["cursor"].string, more)
  }
}

// MARK: - Third-party emotes (7TV, BTTV, FFZ)

/// An emote you can type: its name and picture.
struct NamedEmote: Hashable, Sendable {
  var name: String
  var url: URL
}

/// 7TV, BTTV and FFZ emotes for a channel, by provider (for the emote picker) and merged by name
/// (for showing messages).
struct ThirdPartyEmoteSets: Sendable {
  struct Section: Sendable {
    var title: String
    var emotes: [NamedEmote]
  }
  var channel: [Section] = []
  var global: [Section] = []
  var byName: [String: URL] = [:]
  /// Every list came (else the chat tries again shortly for the rest).
  var complete = true
}

/// Emote sets fetched lately, kept in memory: the global ones once a session (half an hour),
/// each channel's for ten minutes. Every chat opened (switching chats in multi-view, above all)
/// fetched all six sets again and waited for the slowest before showing anything.
actor EmoteSetCache {
  static let shared = EmoteSetCache()
  typealias Sets = (seventv: [String: URL], bttv: [String: URL], ffz: [String: URL])
  /// The sets, and whether every one of them came (only complete ones are kept).
  typealias Loaded = (sets: Sets, complete: Bool)
  private var globals: (sets: Sets, at: Date)?
  private var globalsTask: Task<Loaded, Never>?
  private var channels: [String: (sets: Sets, at: Date)] = [:]
  private var channelTasks: [String: Task<Loaded, Never>] = [:]

  /// Fresh enough to use as is; older (up to `diskKeep`), used at once from disk and fetched
  /// again behind it. 7TV's lists are big and slow to come (a couple of seconds on Wi-Fi, far more
  /// on cellular with streams playing): a chat used to wait for them, its 7TV emotes showing as
  /// words meanwhile, every time it opened.
  private static let fresh: TimeInterval = 600
  private static let diskKeep: TimeInterval = 7 * 24 * 3600

  func globals(_ load: @escaping @Sendable () async -> Loaded) async -> Loaded {
    if globals == nil, let stored = Self.read("global") { globals = stored }
    if let globals {
      if Date().timeIntervalSince(globals.at) >= Self.fresh { refreshGlobals(load) }
      return (globals.sets, true)
    }
    return await fetchGlobals(load)
  }

  private func refreshGlobals(_ load: @escaping @Sendable () async -> Loaded) {
    guard globalsTask == nil else { return }
    Task { _ = await fetchGlobals(load) }
  }

  private func fetchGlobals(_ load: @escaping @Sendable () async -> Loaded) async -> Loaded {
    if let globalsTask { return await globalsTask.value }
    let task = Task { await load() }
    globalsTask = task
    let loaded = await task.value
    globalsTask = nil
    // (Something didn't come: not kept, so the next try fetches it again.)
    if loaded.complete {
      globals = (loaded.sets, Date())
      Self.write("global", loaded.sets)
    }
    return loaded
  }

  func channel(_ id: String, _ load: @escaping @Sendable () async -> Loaded) async -> Loaded {
    if channels[id] == nil, let stored = Self.read("channel-\(id)") { channels[id] = stored }
    if let cached = channels[id] {
      if Date().timeIntervalSince(cached.at) >= Self.fresh { refreshChannel(id, load) }
      return (cached.sets, true)
    }
    return await fetchChannel(id, load)
  }

  private func refreshChannel(_ id: String, _ load: @escaping @Sendable () async -> Loaded) {
    guard channelTasks[id] == nil else { return }
    Task { _ = await fetchChannel(id, load) }
  }

  private func fetchChannel(_ id: String, _ load: @escaping @Sendable () async -> Loaded) async -> Loaded {
    if let task = channelTasks[id] { return await task.value }
    let task = Task { await load() }
    channelTasks[id] = task
    let loaded = await task.value
    channelTasks[id] = nil
    if loaded.complete {
      channels[id] = (loaded.sets, Date())
      Self.write("channel-\(id)", loaded.sets)
    }
    return loaded
  }

  // MARK: On disk (the caches folder: iOS may clear it, and then they're fetched again)

  private struct Stored: Codable {
    var at: Date
    var seventv: [String: String]
    var bttv: [String: String]
    var ffz: [String: String]
  }

  private static var folder: URL? {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    let folder = caches.appendingPathComponent("EmoteSets", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private static func read(_ name: String) -> (sets: Sets, at: Date)? {
    guard let file = folder?.appendingPathComponent(name + ".json"), let data = try? Data(contentsOf: file),
      let stored = try? JSONDecoder().decode(Stored.self, from: data), Date().timeIntervalSince(stored.at) < diskKeep
    else { return nil }
    func urls(_ map: [String: String]) -> [String: URL] { map.compactMapValues(URL.init(string:)) }
    return ((urls(stored.seventv), urls(stored.bttv), urls(stored.ffz)), stored.at)
  }

  private static func write(_ name: String, _ sets: Sets) {
    guard let file = folder?.appendingPathComponent(name + ".json") else { return }
    let stored = Stored(
      at: Date(), seventv: sets.seventv.mapValues(\.absoluteString), bttv: sets.bttv.mapValues(\.absoluteString),
      ffz: sets.ffz.mapValues(\.absoluteString))
    try? JSONEncoder().encode(stored).write(to: file, options: .atomic)
  }
}

enum ThirdPartyEmotes {
  static func load(channelID: String?, http: HTTPClient) async -> ThirdPartyEmoteSets {
    async let globalSets = EmoteSetCache.shared.globals {
      async let seventv = fetch(URL(string: "https://7tv.io/v3/emote-sets/global")!, http) { parse7TV($0["emotes"]) }
      async let bttv = fetch(URL(string: "https://api.betterttv.net/3/cached/emotes/global")!, http) { parseBTTV($0.array) }
      async let ffz = fetch(URL(string: "https://api.frankerfacez.com/v1/set/global")!, http) { parseFFZ($0["sets"]) }
      let (a, b, c) = await (seventv, bttv, ffz)
      return ((a ?? [:], b ?? [:], c ?? [:]), a != nil && b != nil && c != nil)
    }
    var channel7TV: [String: URL] = [:]
    var channelBTTV: [String: URL] = [:]
    var channelFFZ: [String: URL] = [:]
    var channelComplete = true
    if let channelID, !channelID.isEmpty {
      let loaded = await EmoteSetCache.shared.channel(channelID) {
        async let a = fetch(URL(string: "https://7tv.io/v3/users/twitch/\(channelID)")!, http) {
          if let set = $0["emote_set"]["id"].string { SevenTVSets.remember(set, for: channelID) }
          return parse7TV($0["emote_set"]["emotes"])
        }
        async let b = fetch(URL(string: "https://api.betterttv.net/3/cached/users/twitch/\(channelID)")!, http) {
          parseBTTV($0["channelEmotes"].array + $0["sharedEmotes"].array)
        }
        async let c = fetch(URL(string: "https://api.frankerfacez.com/v1/room/id/\(channelID)")!, http) {
          parseFFZ($0["sets"])
        }
        let (x, y, z) = await (a, b, c)
        return ((x ?? [:], y ?? [:], z ?? [:]), x != nil && y != nil && z != nil)
      }
      (channel7TV, channelBTTV, channelFFZ) = loaded.sets
      channelComplete = loaded.complete
    }
    let globalLoaded = await globalSets
    let globals = globalLoaded.sets
    var result = ThirdPartyEmoteSets()
    result.complete = channelComplete && globalLoaded.complete
    // Lowest priority first; channel 7TV wins on name clashes.
    for map in [globals.2, globals.1, globals.0, channelFFZ, channelBTTV, channel7TV] {
      result.byName.merge(map) { _, new in new }
    }
    func section(_ title: String, _ map: [String: URL]) -> ThirdPartyEmoteSets.Section? {
      guard !map.isEmpty else { return nil }
      let emotes = map.map { NamedEmote(name: $0.key, url: $0.value) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      return ThirdPartyEmoteSets.Section(title: title, emotes: emotes)
    }
    result.channel = [section("7TV", channel7TV), section("BTTV", channelBTTV), section("FFZ", channelFFZ)].compactMap { $0 }
    result.global = [section("7TV global", globals.0), section("BTTV global", globals.1), section("FFZ global", globals.2)]
      .compactMap { $0 }
    return result
  }

  /// One emote list: its emotes, empty when the channel has none there (404), nil when it couldn't
  /// be fetched (a timeout, a server error), tried twice. (A failed fetch counted as "no emotes",
  /// was kept for ten minutes, and the channel's emotes showed as words, e.g. with six streams'
  /// video filling the connection in multi-view.)
  private static func fetch(_ url: URL, _ http: HTTPClient, _ parse: (JSONValue) -> [String: URL]) async -> [String: URL]? {
    for attempt in 1...2 {
      var request = URLRequest(url: url)
      request.timeoutInterval = attempt == 1 ? 15 : 25
      if let (data, response) = try? await http.data(for: request) {
        if response.statusCode == 404 { return [:] }
        if response.statusCode == 200, let object = try? JSONSerialization.jsonObject(with: data) {
          return parse(JSONValue(object))
        }
      }
      if attempt == 1 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
    }
    return nil
  }

  static func parse7TV(_ emotes: JSONValue) -> [String: URL] {
    var result: [String: URL] = [:]
    for emote in emotes.array {
      guard let name = emote["name"].string, let host = emote["data"]["host"]["url"].string else { continue }
      let base = host.hasPrefix("//") ? "https:" + host : host
      let files = emote["data"]["host"]["files"].array.compactMap { $0["name"].string }
      let file = files.first { $0 == "2x.webp" } ?? files.first { $0.hasSuffix(".webp") } ?? "2x.webp"
      if let url = URL(string: "\(base)/\(file)") { result[name] = url }
    }
    return result
  }

  static func parseBTTV(_ emotes: [JSONValue]) -> [String: URL] {
    var result: [String: URL] = [:]
    for emote in emotes {
      guard let id = emote["id"].string, let code = emote["code"].string,
        let url = URL(string: "https://cdn.betterttv.net/emote/\(id)/2x.webp")
      else { continue }
      result[code] = url
    }
    return result
  }

  static func parseFFZ(_ sets: JSONValue) -> [String: URL] {
    var result: [String: URL] = [:]
    for (_, set) in sets.dictionary {
      for emote in set["emoticons"].array {
        // Animated emotes list their moving version separately ("urls" is the still picture).
        guard let name = emote["name"].string,
          var link = emote["animated"]["2"].string ?? emote["animated"]["1"].string
            ?? emote["urls"]["2"].string ?? emote["urls"]["1"].string
        else { continue }
        if link.hasPrefix("//") { link = "https:" + link }
        if let url = URL(string: link) { result[name] = url }
      }
    }
    return result
  }

  /// Last messages from before you joined (recent-messages.robotty.de).
  static func recentMessages(login: String, http: HTTPClient) async -> [IRCMessage] {
    guard let url = URL(string: "https://recent-messages.robotty.de/api/v2/recent-messages/\(login.lowercased())?limit=100")
    else { return [] }
    var request = URLRequest(url: url)
    request.timeoutInterval = 8
    guard let (data, response) = try? await http.data(for: request), response.statusCode == 200,
      let object = try? JSONSerialization.jsonObject(with: data)
    else { return [] }
    return JSONValue(object)["messages"].array.compactMap { $0.string.flatMap(IRCMessage.parse) }
  }
}

/// Each channel's 7TV emote set id (for its live updates), kept between launches.
enum SevenTVSets {
  private static let key = "kestrel.7tvSets"

  static func remember(_ set: String, for channelID: String) {
    var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    guard all[channelID] != set else { return }
    all[channelID] = set
    UserDefaults.standard.set(all, forKey: key)
  }

  static func set(for channelID: String) -> String? {
    (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[channelID]
  }

  /// One 7TV emote set's emotes (a personal one), by name.
  static func emotes(of set: String, http: HTTPClient) async -> [String: URL]? {
    guard let url = URL(string: "https://7tv.io/v3/emote-sets/\(set)") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    guard let (data, response) = try? await http.data(for: request), response.statusCode == 200,
      let object = try? JSONSerialization.jsonObject(with: data)
    else { return nil }
    return ThirdPartyEmotes.parse7TV(JSONValue(object)["emotes"])
  }
}
