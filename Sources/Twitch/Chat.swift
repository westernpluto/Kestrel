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
  var timestamp: Date
  var isDeleted = false

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
    for emote in emotes {
      let start = emote.range.lowerBound
      let end = emote.range.upperBound + 1
      guard start >= cursor, end <= scalars.count, let url = Self.twitchEmoteURL(emote.id) else { continue }
      appendText(cursor, start)
      var name = String.UnicodeScalarView()
      name.append(contentsOf: scalars[start..<end])
      pieces.append(.emote(name: String(name), url: url))
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

// MARK: - Third-party emotes (7TV, BTTV, FFZ)

enum ThirdPartyEmotes {
  static func load(channelID: String?, http: HTTPClient) async -> [String: URL] {
    async let seventvGlobal = fetch(URL(string: "https://7tv.io/v3/emote-sets/global")!, http) { parse7TV($0["emotes"]) }
    async let bttvGlobal = fetch(URL(string: "https://api.betterttv.net/3/cached/emotes/global")!, http) {
      parseBTTV($0.array)
    }
    async let ffzGlobal = fetch(URL(string: "https://api.frankerfacez.com/v1/set/global")!, http) { parseFFZ($0["sets"]) }
    var channel7TV: [String: URL] = [:]
    var channelBTTV: [String: URL] = [:]
    var channelFFZ: [String: URL] = [:]
    if let channelID {
      async let a = fetch(URL(string: "https://7tv.io/v3/users/twitch/\(channelID)")!, http) {
        parse7TV($0["emote_set"]["emotes"])
      }
      async let b = fetch(URL(string: "https://api.betterttv.net/3/cached/users/twitch/\(channelID)")!, http) {
        parseBTTV($0["channelEmotes"].array + $0["sharedEmotes"].array)
      }
      async let c = fetch(URL(string: "https://api.frankerfacez.com/v1/room/id/\(channelID)")!, http) {
        parseFFZ($0["sets"])
      }
      (channel7TV, channelBTTV, channelFFZ) = await (a, b, c)
    }
    var result: [String: URL] = [:]
    // Lowest priority first; channel 7TV wins on name clashes.
    for map in await [ffzGlobal, bttvGlobal, seventvGlobal] + [channelFFZ, channelBTTV, channel7TV] {
      result.merge(map) { _, new in new }
    }
    return result
  }

  private static func fetch(_ url: URL, _ http: HTTPClient, _ parse: (JSONValue) -> [String: URL]) async -> [String: URL] {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    guard let (data, response) = try? await http.data(for: request), response.statusCode == 200,
      let object = try? JSONSerialization.jsonObject(with: data)
    else { return [:] }
    return parse(JSONValue(object))
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
        guard let name = emote["name"].string,
          var link = emote["urls"]["2"].string ?? emote["urls"]["1"].string
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
