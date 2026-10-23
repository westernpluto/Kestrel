import Foundation
import SwiftUI
import UIKit

/// Twitch chat over WebSocket IRC: as yourself when signed in (so you can send), else read-only.
@MainActor
final class ChatController: ObservableObject {
  enum Status: Equatable { case connecting, connected, disconnected(String) }

  @Published private(set) var status: Status = .connecting
  /// Signed in and in the room: messages can be sent.
  @Published private(set) var canSend = false
  /// Room rules worth showing (slow mode, followers-only, …).
  @Published private(set) var roomRules: String?
  /// The room only takes emotes.
  @Published private(set) var emoteOnly = false
  /// A message that didn't go out (the room's rules, or Twitch refused it): back into the box.
  @Published private(set) var bounced: Bounced?

  struct Bounced: Equatable {
    let id = UUID()
    var text: String
    var reason: String
  }

  private var lastSent: (id: String, text: String, at: Date)?
  private(set) var messages: [ChatMessage] = []
  private(set) var thirdParty: [String: URL] = [:]
  private(set) var badges: [String: Badge] = [:]
  /// Emotes you can use here, for the picker (Recent first).
  @Published private(set) var emoteSections: [EmoteSection] = []
  /// Every emote you can type here, by name (autocomplete).
  private(set) var usableEmotes: [NamedEmote] = []
  private var emoteURLs: [String: URL] = [:]

  /// The picture for an emote name you can use here (the message box shows it).
  func emoteURL(for name: String) -> URL? { emoteURLs[name] }
  /// Your Twitch emotes: name → ID (to show them in your own messages).
  private(set) var twitchEmoteIDs: [String: String] = [:]
  private var thirdPartySets = ThirdPartyEmoteSets()
  private var twitchGroups: [TwitchEmoteGroup] = []
  /// Recent chatters, newest first (for @ autocomplete).
  private(set) var recentChatters: [String] = []
  /// Called with `true` when everything should be re-rendered (emotes/badges loaded).
  var onUpdate: ((_ fullReload: Bool) -> Void)?

  let channel: Channel
  private var socket: URLSessionWebSocketTask?
  private var pending: [ChatMessage] = []
  private var flushScheduled = false
  private var running = false
  private var attempt = 0
  private let maxMessages = 250
  private var userState: [String: String] = [:]
  private var room: [String: String] = [:]
  private var signedInLogin: String?
  private var authRefused = false

  /// Set for a VOD: chat is replayed in time with the video instead of joined live.
  let replayVideoID: String?
  private var replay = ChatReplayBuffer()

  nonisolated init(channel: Channel, replayVideoID: String? = nil) {
    self.channel = channel
    self.replayVideoID = replayVideoID
  }

  var isReplay: Bool { replayVideoID != nil }

  var ownLogin: String? { signedInLogin }

  func start() {
    guard !running else { return }
    running = true
    let channel = self.channel
    let replay = isReplay
    Task {
      let http = URLSessionHTTPClient(timeout: 10)
      async let history = replay ? [] : ThirdPartyEmotes.recentMessages(login: channel.login, http: http)
      async let badgeMap = TwitchAPI.shared.badges(channelID: channel.id)
      let emotes = await ThirdPartyEmotes.load(channelID: channel.id, http: http)
      let (recent, loadedBadges) = await (history, badgeMap)
      thirdPartySets = emotes
      thirdParty = emotes.byName
      badges = loadedBadges
      let old = recent.compactMap(ChatMessage.init(irc:)).filter { $0.kind != .notice }
      messages = Array((old + messages).suffix(maxMessages))
      for message in old.reversed() { noteChatter(message.displayName) }
      rebuildEmoteSections()
      onUpdate?(true)
    }
    if isReplay {
      status = .connected
      return
    }
    loadTwitchEmotes()
    connect()
  }

  // MARK: VOD chat replay

  /// Shows what was said up to `position` (seconds into the VOD), fetching ahead as it plays.
  func replay(at position: Double) {
    guard let videoID = replayVideoID, running, position.isFinite else { return }
    if replay.move(to: position) {
      // A seek: start over from a little before the new position.
      pending = []
      messages = []
      onUpdate?(true)
    }
    releaseReplay()
    fetchReplayIfNeeded(videoID: videoID)
  }

  private func releaseReplay() {
    for message in replay.due() { enqueue(message) }
  }

  private func fetchReplayIfNeeded(videoID: String) {
    guard let offset = replay.fetchNeeded() else { return }
    let generation = replay.generation
    Task {
      do {
        let page = try await TwitchAPI.shared.videoComments(videoID: videoID, offset: offset, cursor: nil)
        replay.received(page.comments, for: offset, generation: generation)
      } catch {
        replay.failed(generation: generation)
        if generation == replay.generation {
          ActivityLog.shared.add("Chat replay: \(error.localizedDescription)")
          if messages.isEmpty && pending.isEmpty {
            enqueue(ChatMessage(notice: "Chat replay isn't available for this video right now."))
          }
        }
      }
      guard generation == replay.generation else { return }
      releaseReplay()
      // Keep reading until there's chat ahead of the video (or there's none yet).
      fetchReplayIfNeeded(videoID: videoID)
    }
  }

  /// Your Twitch emotes for this channel (needs sign-in).
  func loadTwitchEmotes() {
    let channelID = channel.id.isEmpty ? nil : channel.id
    Task {
      twitchGroups = await TwitchAPI.shared.availableEmotes(channelID: channelID)
      rebuildEmoteSections()
    }
  }

  private func rebuildEmoteSections() {
    var sections: [EmoteSection] = []
    var ids: [String: String] = [:]
    // Group your Twitch emotes by owner: this channel first, then other channels, then Twitch's own.
    var byOwner: [String: (name: String?, image: String?, emotes: [TwitchEmote])] = [:]
    var ownerOrder: [String] = []
    for group in twitchGroups {
      let key = group.ownerID.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 } ?? "twitch"
      if byOwner[key] == nil { ownerOrder.append(key) }
      var entry = byOwner[key] ?? (group.ownerName, group.ownerImage, [])
      entry.emotes += group.emotes
      if entry.name == nil { entry.name = group.ownerName }
      if entry.image == nil { entry.image = group.ownerImage }
      byOwner[key] = entry
    }
    func twitchSection(_ key: String, title: String) -> EmoteSection? {
      guard let entry = byOwner[key] else { return nil }
      var seen = Set<String>()
      let emotes = entry.emotes.compactMap { emote -> NamedEmote? in
        guard seen.insert(emote.token).inserted, let url = emote.url else { return nil }
        ids[emote.token] = emote.id
        return NamedEmote(name: emote.token, url: url)
      }
      guard !emotes.isEmpty else { return nil }
      return EmoteSection(id: "twitch-\(key)", title: title, icon: entry.image.flatMap(URL.init(string:)), emotes: emotes)
    }
    if let own = twitchSection(channel.id, title: channel.name) { sections.append(own) }
    for section in thirdPartySets.channel {
      sections.append(EmoteSection(id: "channel-\(section.title)", title: "\(section.title) · \(channel.name)", icon: nil, emotes: section.emotes))
    }
    let others = ownerOrder.filter { $0 != channel.id && $0 != "twitch" }
      .sorted { (byOwner[$0]?.name ?? "~").localizedCaseInsensitiveCompare(byOwner[$1]?.name ?? "~") == .orderedAscending }
    for key in others {
      if let section = twitchSection(key, title: byOwner[key]?.name ?? "Subscriptions") { sections.append(section) }
    }
    if let global = twitchSection("twitch", title: "Twitch") { sections.append(global) }
    for section in thirdPartySets.global {
      sections.append(EmoteSection(id: "global-\(section.title)", title: section.title, icon: nil, emotes: section.emotes))
    }
    twitchEmoteIDs = ids

    // Everything usable by name (Twitch emotes win over third-party ones with the same name).
    var byName: [String: NamedEmote] = [:]
    for section in sections.reversed() {
      for emote in section.emotes { byName[emote.name] = emote }
    }
    usableEmotes = byName.values.sorted { $0.name.count < $1.name.count }
    emoteURLs = byName.mapValues(\.url)
    let recent = RecentEmotes.names.compactMap { byName[$0] }
    if !recent.isEmpty { sections.insert(EmoteSection(id: "recent", title: "Recent", icon: nil, emotes: recent), at: 0) }
    emoteSections = sections
  }

  /// Emotes for `query` (typed after ":"): prefix matches first, then the rest containing it.
  func emoteSuggestions(_ query: String, limit: Int = 40) -> [NamedEmote] {
    guard !query.isEmpty else { return [] }
    var prefix: [NamedEmote] = []
    var contains: [NamedEmote] = []
    for emote in usableEmotes {
      if emote.name.range(of: query, options: [.caseInsensitive, .anchored]) != nil {
        prefix.append(emote)
      } else if emote.name.range(of: query, options: .caseInsensitive) != nil {
        contains.append(emote)
      }
      if prefix.count >= limit { break }
    }
    return Array((prefix + contains).prefix(limit))
  }

  func chatterSuggestions(_ query: String, limit: Int = 20) -> [String] {
    recentChatters.filter { query.isEmpty || $0.range(of: query, options: [.caseInsensitive, .anchored]) != nil }
      .prefix(limit).map { $0 }
  }

  private func noteChatter(_ name: String) {
    guard !name.isEmpty else { return }
    if let index = recentChatters.firstIndex(of: name) { recentChatters.remove(at: index) }
    recentChatters.insert(name, at: 0)
    if recentChatters.count > 300 { recentChatters.removeLast() }
  }

  func stop() {
    running = false
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
  }

  /// After signing in or out.
  func reconnect() {
    guard running, !isReplay else { return }
    authRefused = false
    loadTwitchEmotes()
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    connect()
  }

  func send(_ raw: String) {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSend, !text.isEmpty, let socket, let login = signedInLogin else { return }
    // Emote-only: Twitch would refuse anything but Twitch emotes, so don't send it at all.
    if emoteOnly, !twitchEmoteIDs.isEmpty, !Self.onlyEmotes(text, twitchEmoteIDs) {
      bounced = Bounced(text: raw, reason: "Emote-only chat: only Twitch emotes you have can be sent")
      return
    }
    let line: String
    if text.hasPrefix("/me ") {
      line = "PRIVMSG #\(channel.login.lowercased()) :\u{1}ACTION \(text.dropFirst(4))\u{1}"
    } else {
      line = "PRIVMSG #\(channel.login.lowercased()) :\(text)"
    }
    socket.send(.string(line)) { [weak self] error in
      guard let error, let chat = self else { return }
      Task { @MainActor in chat.enqueue(ChatMessage(notice: "Couldn't send: \(error.localizedDescription)")) }
    }
    let echo = ChatMessage(sent: text, userState: userState, login: login, emoteIDs: twitchEmoteIDs)
    lastSent = (echo.id, raw, Date())
    enqueue(echo)
    let used = Set(text.split(separator: " ").map(String.init)).filter { emoteURLs[$0] != nil }
    if !used.isEmpty {
      RecentEmotes.add(Array(used))
      rebuildEmoteSections()
    }
  }

  /// Every word is a Twitch emote (third-party emotes are plain text to Twitch).
  static func onlyEmotes(_ text: String, _ emotes: [String: String]) -> Bool {
    let words = text.split(separator: " ").map(String.init)
    return !words.isEmpty && words.allSatisfy { emotes[$0] != nil }
  }

  /// Twitch refused the message just sent: take the echo back out and return the text.
  private func refused(_ reason: String) {
    guard let sent = lastSent, Date().timeIntervalSince(sent.at) < 10 else { return }
    lastSent = nil
    pending.removeAll { $0.id == sent.id }
    if messages.contains(where: { $0.id == sent.id }) {
      messages.removeAll { $0.id == sent.id }
      onUpdate?(true)
    }
    bounced = Bounced(text: sent.text, reason: reason)
  }

  private func connect() {
    guard running else { return }
    status = .connecting
    canSend = false
    let task = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
    socket = task
    task.resume()
    var lines = ["CAP REQ :twitch.tv/tags twitch.tv/commands"]
    if !authRefused, let session = TwitchAuth.shared.session {
      signedInLogin = session.login.lowercased()
      lines += ["PASS oauth:\(session.token)", "NICK \(session.login.lowercased())"]
    } else {
      signedInLogin = nil
      lines += ["PASS SCHMOOPIIE", "NICK justinfan\(Int.random(in: 10000...99999))"]
    }
    lines.append("JOIN #\(channel.login.lowercased())")
    for line in lines { task.send(.string(line)) { _ in } }
    receive(task)
  }

  private func receive(_ task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
      Task { @MainActor in
        guard let self, self.socket === task else { return }
        switch result {
        case .failure(let error):
          self.reconnect(after: error)
        case .success(let message):
          switch message {
          case .string(let text): self.handle(text)
          case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
          @unknown default: break
          }
          self.receive(task)
        }
      }
    }
  }

  private func reconnect(after error: Error) {
    socket = nil
    canSend = false
    guard running else { return }
    attempt += 1
    status = .disconnected("Reconnecting…")
    let delay = min(15.0, pow(2, Double(min(attempt, 4))))
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
  }

  private func handle(_ text: String) {
    for line in text.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" }) {
      guard let irc = IRCMessage.parse(String(line)) else { continue }
      switch irc.command {
      case "PING":
        socket?.send(.string("PONG :\(irc.trailing ?? "tmi.twitch.tv")")) { _ in }
      case "001":
        attempt = 0
      case "366":
        status = .connected
      case "ROOMSTATE":
        status = .connected
        room.merge(irc.tags) { _, new in new }
        roomRules = Self.describe(room)
        emoteOnly = room["emote-only"] == "1"
      case "USERSTATE":
        userState = irc.tags
        canSend = signedInLogin != nil
      case "CLEARMSG":
        if let id = irc.tags["target-msg-id"] { markDeleted { $0.id == id } }
      case "CLEARCHAT":
        if irc.params.count > 1, let login = irc.trailing?.lowercased() {
          markDeleted { $0.login.lowercased() == login }
        }
      case "RECONNECT":
        socket?.cancel(with: .goingAway, reason: nil)
      case "NOTICE":
        let message = irc.trailing ?? ""
        if message.localizedCaseInsensitiveContains("authentication failed")
          || message.localizedCaseInsensitiveContains("improperly formatted auth")
        {
          // The token doesn't work for chat: read as a guest instead of not at all.
          authRefused = true
          enqueue(ChatMessage(notice: "Twitch didn't accept your sign-in for chat, so it's read-only. Sign in again in Settings."))
          socket?.cancel(with: .goingAway, reason: nil)
          socket = nil
          connect()
          return
        }
        // msg_emoteonly, msg_followersonly, msg_slowmode, msg_duplicate, …: your message didn't go out.
        if let id = irc.tags["msg-id"], id.hasPrefix("msg_") { refused(message) }
        if let notice = ChatMessage(irc: irc) { enqueue(notice) }
      default:
        if let message = ChatMessage(irc: irc) {
          if message.kind == .message || message.kind == .action { noteChatter(message.displayName) }
          enqueue(message)
        }
      }
    }
  }

  static func describe(_ room: [String: String]) -> String? {
    var rules: [String] = []
    if let slow = room["slow"].flatMap(Int.init), slow > 0 { rules.append("Slow mode \(slow)s") }
    if let followers = room["followers-only"].flatMap(Int.init), followers >= 0 {
      rules.append(followers == 0 ? "Followers-only" : "Followers-only (\(followers) min)")
    }
    if room["subs-only"] == "1" { rules.append("Subscribers-only") }
    if room["emote-only"] == "1" { rules.append("Emote-only") }
    return rules.isEmpty ? nil : rules.joined(separator: " · ")
  }

  private func markDeleted(_ predicate: (ChatMessage) -> Bool) {
    var changed = false
    for i in messages.indices where predicate(messages[i]) && !messages[i].isDeleted {
      messages[i].isDeleted = true
      changed = true
    }
    if changed { onUpdate?(true) }
  }

  private func enqueue(_ message: ChatMessage) {
    pending.append(message)
    guard !flushScheduled else { return }
    flushScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.flush() }
  }

  private func flush() {
    flushScheduled = false
    guard !pending.isEmpty else { return }
    messages.append(contentsOf: pending)
    pending.removeAll()
    if messages.count > maxMessages { messages.removeFirst(messages.count - maxMessages) }
    onUpdate?(false)
  }
}

struct EmoteSection: Identifiable {
  var id: String
  var title: String
  var icon: URL?
  var emotes: [NamedEmote]
}

/// Emotes you used lately, across channels.
enum RecentEmotes {
  private static let key = "recentEmotes"
  static var names: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

  static func add(_ used: [String]) {
    var list = names.filter { !used.contains($0) }
    list.insert(contentsOf: used, at: 0)
    UserDefaults.standard.set(Array(list.prefix(36)), forKey: key)
  }
}

// MARK: - Rendering

/// A message laid out as text, with image slots (badges, emotes) drawn by image views on top.
struct RenderedMessage {
  struct Slot {
    var range: NSRange
    var url: URL
    var size: CGSize
  }
  var text: NSAttributedString
  var slots: [Slot]
  var highlighted: Bool
}

enum ChatRenderer {
  static let accent = UIColor(red: 0.57, green: 0.38, blue: 1.0, alpha: 1)

  static func color(_ hex: String?, fallbackSeed: String) -> UIColor {
    var value: UInt64 = 0
    if let hex, hex.hasPrefix("#"), Scanner(string: String(hex.dropFirst())).scanHexInt64(&value) {
      var r = CGFloat((value >> 16) & 0xFF) / 255, g = CGFloat((value >> 8) & 0xFF) / 255, b = CGFloat(value & 0xFF) / 255
      let luminance = 0.299 * r + 0.587 * g + 0.114 * b
      if luminance < 0.45 {  // too dark on a dark background: lighten
        let boost = 0.45 - luminance
        r = min(1, r + boost)
        g = min(1, g + boost)
        b = min(1, b + boost)
      }
      return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
    let palette: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemPink]
    let seed = fallbackSeed.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
    return palette[Int(seed % UInt32(palette.count))]
  }

  /// An invisible placeholder the size of the image; an image view is placed over it.
  private static func slot(_ url: URL, height: CGFloat, font: UIFont, into text: NSMutableAttributedString, slots: inout [RenderedMessage.Slot]) {
    let image = ImagePipeline.shared.cached(url, maxPixels: 112)
    if image == nil { ImagePipeline.shared.load(url, maxPixels: 112) { _ in ChatImageEvents.imageArrived() } }
    let ratio = image.map { $0.size.height > 0 ? min(4, $0.size.width / $0.size.height) : 1 } ?? 1
    let size = CGSize(width: (height * ratio).rounded(), height: height)
    let attachment = NSTextAttachment()
    attachment.image = UIImage()
    attachment.bounds = CGRect(x: 0, y: (font.capHeight - height) / 2, width: size.width, height: size.height)
    slots.append(RenderedMessage.Slot(range: NSRange(location: text.length, length: 1), url: url, size: size))
    text.append(NSAttributedString(attachment: attachment))
  }

  static func render(_ message: ChatMessage, badges: [String: Badge], thirdParty: [String: URL], fontSize: CGFloat, me: String?)
    -> RenderedMessage
  {
    let font = UIFont.systemFont(ofSize: fontSize)
    let bold = UIFont.systemFont(ofSize: fontSize, weight: .bold)
    let text = NSMutableAttributedString()
    var slots: [RenderedMessage.Slot] = []
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2
    let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]

    if message.kind == .notice {
      text.append(NSAttributedString(string: message.text, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: paragraph]))
      return RenderedMessage(text: text, slots: [], highlighted: false)
    }
    if let system = message.systemText {
      text.append(NSAttributedString(string: system, attributes: [.font: bold, .foregroundColor: accent, .paragraphStyle: paragraph]))
      if message.text.isEmpty { return RenderedMessage(text: text, slots: [], highlighted: true) }
      text.append(NSAttributedString(string: "\n", attributes: plain))
    }
    for badge in message.badges {
      guard let info = badges[badge], let url = URL(string: info.imageURL) else { continue }
      slot(url, height: (fontSize + 3).rounded(), font: font, into: text, slots: &slots)
      text.append(NSAttributedString(string: " ", attributes: plain))
    }
    let nameColor = color(message.color, fallbackSeed: message.login)
    text.append(NSAttributedString(string: message.displayName, attributes: [.font: bold, .foregroundColor: nameColor, .paragraphStyle: paragraph]))
    if message.isDeleted {
      text.append(NSAttributedString(string: ": <message deleted>", attributes: [.font: font, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: paragraph]))
      return RenderedMessage(text: text, slots: slots, highlighted: false)
    }
    text.append(NSAttributedString(string: message.kind == .action ? " " : ": ", attributes: plain))
    var body = plain
    if message.kind == .action { body[.foregroundColor] = nameColor }
    for fragment in message.fragments(thirdParty: thirdParty) {
      switch fragment {
      case .text(let t): text.append(NSAttributedString(string: t, attributes: body))
      case .emote(_, let url): slot(url, height: (fontSize * 1.75).rounded(), font: font, into: text, slots: &slots)
      }
    }
    let highlighted = message.systemText != nil || (me.map { message.mentions($0) } ?? false)
    return RenderedMessage(text: text, slots: slots, highlighted: highlighted)
  }
}

/// Coalesces "an image finished loading" into one refresh per quarter second.
enum ChatImageEvents {
  static let notification = Notification.Name("KestrelChatImageArrived")
  private static var scheduled = false

  static func imageArrived() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      scheduled = false
      NotificationCenter.default.post(name: notification, object: nil)
    }
  }
}

/// Draws a message with TextKit and puts (animated) image views exactly over its image slots.
final class ChatMessageView: UIView {
  private let storage = NSTextStorage()
  private let manager = NSLayoutManager()
  private let container = NSTextContainer(size: .zero)
  private var imageViews: [LoadingImageView] = []
  private var slots: [RenderedMessage.Slot] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    container.lineFragmentPadding = 0
    isOpaque = false
    backgroundColor = .clear
    contentMode = .redraw
  }

  required init?(coder: NSCoder) { fatalError() }

  func show(_ rendered: RenderedMessage) {
    storage.setAttributedString(rendered.text)
    slots = rendered.slots
    while imageViews.count < slots.count {
      let view = LoadingImageView()
      view.contentMode = .scaleAspectFit
      addSubview(view)
      imageViews.append(view)
    }
    for (index, view) in imageViews.enumerated() {
      view.isHidden = index >= slots.count
      if index < slots.count { view.load(slots[index].url, maxPixels: 112, fallback: nil) }
    }
    setNeedsLayout()
    setNeedsDisplay()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    container.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
    manager.ensureLayout(for: container)
    var baselines: [Int: CGFloat] = [:]
    for (index, slot) in slots.enumerated() where index < imageViews.count {
      let glyph = manager.glyphIndexForCharacter(at: slot.range.location)
      guard glyph < manager.numberOfGlyphs else { continue }
      var lineRange = NSRange()
      let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
      let location = manager.location(forGlyphAt: glyph)
      let attachment = storage.attribute(.attachment, at: slot.range.location, effectiveRange: nil) as? NSTextAttachment
      let bounds = attachment?.bounds ?? CGRect(origin: .zero, size: slot.size)
      let baseline: CGFloat
      if let known = baselines[lineRange.location] {
        baseline = known
      } else {
        baseline = line.minY + baselineOffset(inLine: lineRange, attachmentGlyph: glyph, attachmentBounds: bounds)
        baselines[lineRange.location] = baseline
      }
      imageViews[index].frame = CGRect(
        x: line.minX + location.x, y: baseline - (bounds.origin.y + bounds.height), width: bounds.width, height: bounds.height)
    }
  }

  /// The line's baseline, from a text character on it. (An attachment's reported location is its
  /// bottom edge, not the baseline, which put emotes too low.)
  private func baselineOffset(inLine lineRange: NSRange, attachmentGlyph: Int, attachmentBounds: CGRect) -> CGFloat {
    let string = storage.string as NSString
    for glyph in lineRange.location..<NSMaxRange(lineRange) {
      let character = manager.characterIndexForGlyph(at: glyph)
      guard character < string.length else { continue }
      let unit = string.character(at: character)
      if unit != 0xFFFC, unit != 0x0A, unit != 0x0D { return manager.location(forGlyphAt: glyph).y }
    }
    return manager.location(forGlyphAt: attachmentGlyph).y + attachmentBounds.origin.y
  }

  override func draw(_ rect: CGRect) {
    let range = manager.glyphRange(for: container)
    manager.drawBackground(forGlyphRange: range, at: .zero)
    manager.drawGlyphs(forGlyphRange: range, at: .zero)
  }

  private static let measuring: (NSTextStorage, NSLayoutManager, NSTextContainer) = {
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: .zero)
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    return (storage, manager, container)
  }()

  static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
    let (storage, manager, container) = measuring
    storage.setAttributedString(text)
    container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
    manager.ensureLayout(for: container)
    return ceil(manager.usedRect(for: container).height)
  }
}

final class ChatCell: UITableViewCell {
  let messageView = ChatMessageView()
  static let insets = UIEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none
    contentView.addSubview(messageView)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    messageView.frame = contentView.bounds.inset(by: Self.insets)
  }
}

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
  private let chat: ChatController
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let resumeButton = UIButton(type: .system)
  private var displayed: [ChatMessage] = []
  private var rendered: [String: RenderedMessage] = [:]
  private var heights: [String: CGFloat] = [:]
  private var lastWidth: CGFloat = 0
  private var lastHeight: CGFloat = 0
  private var following = true
  private var imageObserver: NSObjectProtocol?
  var onMention: ((String) -> Void)?

  init(chat: ChatController) {
    self.chat = chat
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(ChatCell.self, forCellReuseIdentifier: "chat")
    tableView.keyboardDismissMode = .onDrag
    tableView.showsVerticalScrollIndicator = false
    tableView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tableView)

    var configuration = UIButton.Configuration.filled()
    configuration.title = "More messages"
    configuration.image = UIImage(systemName: "arrow.down")
    configuration.imagePadding = 6
    configuration.cornerStyle = .capsule
    configuration.baseBackgroundColor = ChatRenderer.accent
    configuration.baseForegroundColor = .white
    configuration.buttonSize = .small
    resumeButton.configuration = configuration
    resumeButton.translatesAutoresizingMaskIntoConstraints = false
    resumeButton.isHidden = true
    resumeButton.addAction(UIAction { [weak self] _ in self?.resume() }, for: .touchUpInside)
    view.addSubview(resumeButton)

    NSLayoutConstraint.activate([
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      resumeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      resumeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
    ])

    chat.onUpdate = { [weak self] full in self?.chatUpdated(fullReload: full) }
    imageObserver = NotificationCenter.default.addObserver(
      forName: ChatImageEvents.notification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.chatUpdated(fullReload: true)
    }
    chatUpdated(fullReload: true)
  }

  deinit {
    if let imageObserver { NotificationCenter.default.removeObserver(imageObserver) }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if abs(tableView.bounds.width - lastWidth) > 0.5 {
      lastWidth = tableView.bounds.width
      lastHeight = tableView.bounds.height
      heights = [:]
      tableView.reloadData()
      if following { scrollToBottom(animated: false) }
    } else if abs(tableView.bounds.height - lastHeight) > 0.5 {
      // Keyboard or emote picker: stay on the newest messages.
      lastHeight = tableView.bounds.height
      if following { scrollToBottom(animated: false) }
    }
  }

  private func key(_ message: ChatMessage) -> String { "\(message.id)-\(message.isDeleted)" }

  private func render(_ message: ChatMessage) -> RenderedMessage {
    let k = key(message)
    if let cached = rendered[k] { return cached }
    let result = ChatRenderer.render(
      message, badges: chat.badges, thirdParty: chat.thirdParty, fontSize: AppSettings.shared.chatFontSize, me: chat.ownLogin)
    rendered[k] = result
    return result
  }

  private func chatUpdated(fullReload: Bool) {
    if fullReload {
      rendered = [:]
      heights = [:]
    }
    guard following else {
      if resumeButton.isHidden {
        resumeButton.alpha = 0
        resumeButton.isHidden = false
        UIView.animate(withDuration: 0.2) { self.resumeButton.alpha = 1 }
      }
      if fullReload { tableView.reloadData() }
      return
    }
    let old = displayed
    let new = chat.messages
    // Usually the newest messages were added and the oldest dropped: update just those rows and
    // glide down instead of reloading the list (which made chat jump).
    if !fullReload, tableView.window != nil, let first = new.first, let start = old.firstIndex(where: { $0.id == first.id }),
      old.count - start <= new.count,
      zip(old[start...], new).allSatisfy({ $0.id == $1.id && $0.isDeleted == $1.isDeleted })
    {
      let added = new.count - (old.count - start)
      guard start > 0 || added > 0 else { return }
      // Measured before the data changes: where the first remaining row sits now (UIKit's own
      // figure, estimated or not) is exactly how far everything moves up.
      let removedHeight = start > 0 ? tableView.rectForRow(at: IndexPath(row: start, section: 0)).minY : 0
      displayed = new
      UIView.performWithoutAnimation {
        tableView.performBatchUpdates {
          if start > 0 { tableView.deleteRows(at: (0..<start).map { IndexPath(row: $0, section: 0) }, with: .none) }
          if added > 0 {
            tableView.insertRows(at: ((new.count - added)..<new.count).map { IndexPath(row: $0, section: 0) }, with: .none)
          }
        }
        // Rows left the top: keep what's on screen where it was before gliding.
        if removedHeight > 0 { tableView.contentOffset.y = max(-tableView.adjustedContentInset.top, tableView.contentOffset.y - removedHeight) }
      }
      prune()
      scrollToBottom(animated: true)
      return
    }
    displayed = new
    prune()
    tableView.reloadData()
    scrollToBottom(animated: false)
  }

  private func prune() {
    let live = Set(displayed.map(key))
    rendered = rendered.filter { live.contains($0.key) }
    heights = heights.filter { live.contains($0.key) }
  }

  private func scrollToBottom(animated: Bool) {
    guard !displayed.isEmpty else { return }
    tableView.layoutIfNeeded()
    let bottom = max(
      -tableView.adjustedContentInset.top,
      tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
    guard abs(tableView.contentOffset.y - bottom) > 0.5 else { return }
    if animated {
      UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
        self.tableView.contentOffset.y = bottom
      }
    } else {
      tableView.contentOffset.y = bottom
    }
  }

  private func resume() {
    following = true
    UIView.animate(withDuration: 0.2) { self.resumeButton.alpha = 0 } completion: { _ in
      if self.following { self.resumeButton.isHidden = true }
    }
    chatUpdated(fullReload: false)
    scrollToBottom(animated: true)
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { displayed.count }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    let message = displayed[indexPath.row]
    let k = key(message)
    if let height = heights[k] { return height }
    let width = max(10, tableView.bounds.width - ChatCell.insets.left - ChatCell.insets.right)
    let height = ChatMessageView.height(of: render(message).text, width: width) + ChatCell.insets.top + ChatCell.insets.bottom
    heights[k] = height
    return height
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "chat", for: indexPath) as! ChatCell
    let result = render(displayed[indexPath.row])
    cell.messageView.show(result)
    cell.contentView.backgroundColor = result.highlighted ? ChatRenderer.accent.withAlphaComponent(0.14) : .clear
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let message = displayed[indexPath.row]
    guard !message.login.isEmpty, message.kind != .notice else { return }
    onMention?(message.login)
  }

  func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint)
    -> UIContextMenuConfiguration?
  {
    let message = displayed[indexPath.row]
    guard message.kind != .notice else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      var actions = [
        UIAction(title: "Copy message", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = message.text }
      ]
      if self?.onMention != nil {
        actions.append(UIAction(title: "Reply to @\(message.displayName)", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
          self?.onMention?(message.login)
        })
      }
      return UIMenu(children: actions)
    }
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    following = false
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { checkBottom(scrollView) }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    checkBottom(scrollView)
  }

  private func checkBottom(_ scrollView: UIScrollView) {
    let bottom = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
    if scrollView.contentOffset.y >= bottom - 30 { resume() }
  }
}

struct ChatMessagesView: UIViewControllerRepresentable {
  let chat: ChatController
  var onMention: ((String) -> Void)?

  func makeUIViewController(context: Context) -> ChatViewController {
    let controller = ChatViewController(chat: chat)
    controller.onMention = onMention
    return controller
  }

  func updateUIViewController(_ controller: ChatViewController, context: Context) {
    controller.onMention = onMention
  }
}

/// Messages plus the box to write in (or a prompt to sign in), with emote picker and
/// autocomplete (":" for emotes, "@" for people in chat).
struct ChatPanel: View {
  @ObservedObject var chat: ChatController
  /// Space to keep clear at the bottom (home indicator or keyboard).
  var bottomInset: CGFloat = 0
  /// Landscape: a shorter emote picker.
  var compact = false
  @ObservedObject private var account = TwitchAccount.shared
  @State private var draft = ""
  @State private var showLogin = false
  @State private var pickerOpen = false
  @State private var focused = false
  @State private var inputHeight = EmoteTextField.minHeight
  @State private var warning: String?

  private static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)

  var body: some View {
    VStack(spacing: 0) {
      ZStack(alignment: .top) {
        ChatMessagesView(chat: chat, onMention: account.session == nil ? nil : { login in
          draft = "@\(login) " + draft
          focused = true
        })
        statusPill
      }
      Divider().overlay(Color.white.opacity(0.08))
      if !suggestions.isEmpty {
        suggestionStrip
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      inputBar
      if pickerOpen {
        EmotePicker(sections: chat.emoteSections) { insert($0.name) }
          .frame(height: compact ? 190 : 280)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .padding(.bottom, pickerOpen ? min(bottomInset, 24) : bottomInset)
    .animation(Self.spring, value: pickerOpen)
    .animation(.easeOut(duration: 0.15), value: suggestions.isEmpty)
    .sheet(isPresented: $showLogin) { TwitchLoginView() }
    .onChange(of: account.session?.login) { _ in chat.reconnect() }
    .onChange(of: focused) { isFocused in
      if isFocused, pickerOpen { pickerOpen = false }
    }
    .onChange(of: chat.bounced) { bounced in
      guard let bounced else { return }
      draft = bounced.text
      withAnimation(.easeOut(duration: 0.2)) { warning = bounced.reason }
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        withAnimation(.easeOut(duration: 0.3)) { if warning == bounced.reason { warning = nil } }
      }
    }
  }

  @ViewBuilder
  private var statusPill: some View {
    Group {
      if case .disconnected(let reason) = chat.status {
        pill(reason)
      } else if chat.status == .connecting {
        pill("Connecting to chat…")
      }
    }
    .transition(.opacity.combined(with: .move(edge: .top)))
    .animation(.easeInOut(duration: 0.2), value: chat.status)
  }

  private func pill(_ text: String) -> some View {
    Text(text).font(.caption.weight(.semibold))
      .padding(.horizontal, 10).padding(.vertical, 5)
      .background(.ultraThinMaterial, in: Capsule())
      .padding(.top, 8)
  }

  // MARK: Autocomplete

  private enum Suggestion: Hashable {
    case emote(NamedEmote)
    case chatter(String)
  }

  /// The word being typed, if it asks for suggestions.
  private var currentWord: String? {
    guard let last = draft.split(separator: " ", omittingEmptySubsequences: false).last, last.count >= 2 else { return nil }
    return last.hasPrefix(":") || last.hasPrefix("@") ? String(last) : nil
  }

  private var suggestions: [Suggestion] {
    guard account.session != nil, !chat.isReplay, let word = currentWord else { return [] }
    let query = String(word.dropFirst())
    if word.hasPrefix(":") { return chat.emoteSuggestions(query).map(Suggestion.emote) }
    return chat.chatterSuggestions(query).map(Suggestion.chatter)
  }

  private var suggestionStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(suggestions, id: \.self) { suggestion in
          switch suggestion {
          case .emote(let emote):
            Button {
              complete(with: emote.name)
            } label: {
              HStack(spacing: 6) {
                CachedImage(url: emote.url, maxPixels: 112, contentMode: .scaleAspectFit, placeholder: nil)
                  .frame(width: 26, height: 26)
                Text(emote.name).font(.footnote.weight(.semibold)).lineLimit(1)
              }
              .padding(.horizontal, 8).padding(.vertical, 5)
              .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(PressableStyle())
          case .chatter(let name):
            Button {
              complete(with: "@" + name)
            } label: {
              Text("@" + name).font(.footnote.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(PressableStyle())
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
    }
    .foregroundColor(.white)
  }

  private func complete(with text: String) {
    guard let word = currentWord else { return }
    draft = String(draft.dropLast(word.count)) + text + " "
  }

  private func insert(_ name: String) {
    if !draft.isEmpty, !draft.hasSuffix(" ") { draft += " " }
    draft += name + " "
  }

  // MARK: Input

  @ViewBuilder
  private var inputBar: some View {
    if chat.isReplay {
      HStack(spacing: 6) {
        Image(systemName: "clock.arrow.circlepath")
        Text("Chat replay")
      }
      .font(.caption.weight(.semibold))
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
    } else if account.session != nil {
      VStack(alignment: .leading, spacing: 4) {
        if let warning {
          Label(warning, systemImage: "exclamationmark.circle.fill")
            .font(.caption2.weight(.semibold)).foregroundColor(.orange).padding(.horizontal, 4)
            .transition(.opacity)
        } else if let rules = chat.roomRules {
          Text(rules).font(.caption2).foregroundColor(.secondary).padding(.horizontal, 4)
        }
        HStack(spacing: 8) {
          HStack(spacing: 4) {
            EmoteTextField(
              text: $draft, isFocused: $focused, height: $inputHeight,
              placeholder: !chat.canSend ? "Joining chat…" : chat.emoteOnly ? "Emotes only" : "Send a message",
              enabled: chat.canSend,
              emoteURL: { chat.emoteURL(for: $0) }, onSubmit: send
            )
            .frame(height: inputHeight)
            Button {
              if pickerOpen {
                focused = true
              } else {
                focused = false
                pickerOpen = true
              }
            } label: {
              Image(systemName: pickerOpen ? "keyboard" : "face.smiling")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(pickerOpen ? .accentTeal : .white.opacity(0.75))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(pickerOpen ? "Keyboard" : "Emotes")
          }
          .padding(.leading, 12)
          .padding(.trailing, 4)
          .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
          .animation(.easeOut(duration: 0.15), value: inputHeight)
          Button(action: send) {
            Image(systemName: "paperplane.fill").font(.system(size: 16, weight: .semibold))
              .frame(width: 36, height: 36)
              .background(draftIsEmpty ? Color.white.opacity(0.08) : Color.accentTeal, in: Circle())
              .foregroundColor(.white)
              .animation(.easeInOut(duration: 0.15), value: draftIsEmpty)
          }
          .buttonStyle(PressableStyle())
          .disabled(!chat.canSend || draftIsEmpty)
          .accessibilityLabel("Send")
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    } else {
      Button {
        showLogin = true
      } label: {
        Label("Sign in with Twitch to chat", systemImage: "bubble.left.and.text.bubble.right")
          .font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
    }
  }

  private var draftIsEmpty: Bool { draft.trimmingCharacters(in: .whitespaces).isEmpty }

  private func send() {
    let text = draft
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    chat.send(text)
    draft = ""
  }
}

/// Twitch-style emote picker: every emote you can use here, by channel, with a strip to jump.
struct EmotePicker: View {
  let sections: [EmoteSection]
  var onPick: (NamedEmote) -> Void
  private let columns = [GridItem(.adaptive(minimum: 42, maximum: 56), spacing: 4)]

  var body: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 0) {
        if sections.isEmpty {
          VStack(spacing: 6) {
            ProgressView()
            Text("Loading emotes…").font(.footnote).foregroundColor(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
              ForEach(sections) { section in
                Section {
                  LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(section.emotes, id: \.self) { emote in
                      Button {
                        onPick(emote)
                      } label: {
                        CachedImage(url: emote.url, maxPixels: 112, contentMode: .scaleAspectFit, placeholder: nil)
                          .frame(width: 32, height: 32)
                          .frame(maxWidth: .infinity, minHeight: 42)
                          .contentShape(Rectangle())
                      }
                      .buttonStyle(PressableStyle(scale: 0.82))
                      .accessibilityLabel(emote.name)
                    }
                  }
                  .padding(.horizontal, 8)
                } header: {
                  Text(section.title)
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.09).opacity(0.97))
                    .id(section.id)
                }
              }
            }
            .padding(.bottom, 8)
          }
          Divider().overlay(Color.white.opacity(0.08))
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
              ForEach(sections) { section in
                Button {
                  withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(section.id, anchor: .top) }
                } label: {
                  tabIcon(section)
                    .frame(width: 38, height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(section.title)
              }
            }
            .padding(.horizontal, 6)
          }
          .frame(height: 38)
        }
      }
      .background(Color(white: 0.09))
    }
  }

  @ViewBuilder
  private func tabIcon(_ section: EmoteSection) -> some View {
    if section.id == "recent" {
      Image(systemName: "clock").font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary)
    } else if let icon = section.icon {
      CachedImage(url: icon, maxPixels: 72, contentMode: .scaleAspectFill)
        .frame(width: 22, height: 22)
        .clipShape(Circle())
    } else if let first = section.emotes.first {
      CachedImage(url: first.url, maxPixels: 72, contentMode: .scaleAspectFit, placeholder: nil)
        .frame(width: 22, height: 22)
    }
  }
}

/// A light press effect for buttons.
struct PressableStyle: ButtonStyle {
  var scale: CGFloat = 0.92

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? scale : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
  }
}
