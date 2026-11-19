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
  private(set) var thirdParty: [String: URL] = [:] {
    didSet { mergedMaps = [:] }
  }
  /// 7TV's live events for this channel: personal emotes and changes to its set.
  private var sevenTV: SevenTVEvents?
  /// Personal 7TV emote sets (by set id), and whose they are (Twitch user id → set ids).
  private var personalSets: [String: [String: URL]] = [:] {
    didSet { mergedMaps = [:] }
  }
  /// The channel's emotes with a chatter's personal 7TV sets on top, by set: made once, not for
  /// every message (each copied and merged the channel's thousands of emotes; in xQc's chat, many
  /// chatters have personal sets).
  private var mergedMaps: [String: [String: URL]] = [:]
  private var userSets: [String: Set<String>] = [:]

  /// The emotes a message can use: the channel's and the global ones, plus its sender's personal
  /// 7TV emotes.
  func emoteMap(for message: ChatMessage) -> [String: URL] {
    guard let user = message.userID, let sets = userSets[user], !sets.isEmpty else { return thirdParty }
    let key = sets.sorted().joined(separator: ",")
    if let made = mergedMaps[key] { return made }
    var map = thirdParty
    for set in sets.sorted() { if let emotes = personalSets[set] { map.merge(emotes) { _, personal in personal } } }
    // (Kept few: chatters' sets come and go.)
    if mergedMaps.count > 200 { mergedMaps = [:] }
    mergedMaps[key] = map
    return map
  }

  private func startSevenTV() {
    guard sevenTV == nil, !channel.id.isEmpty else { return }
    let events = SevenTVEvents(channelID: channel.id)
    events.onPersonalSet = { [weak self] user, set in self?.personal(set, for: user) }
    events.onSetChanged = { [weak self] set, added, removed in self?.setChanged(set, added: added, removed: removed) }
    sevenTV = events
    events.start()
  }

  private func personal(_ set: String, for user: String) {
    let isNew = userSets[user, default: []].insert(set).inserted
    guard isNew else { return }
    sevenTV?.watch(set: set)
    // (Its emotes usually came with 7TV's announcement already.)
    guard personalSets[set]?.isEmpty ?? true else {
      redrawFor(user)
      return
    }
    personalSets[set] = [:]
    Task { [weak self] in
      guard let emotes = await SevenTVSets.emotes(of: set, http: Self.emoteHTTP), let self else { return }
      self.personalSets[set] = emotes
      // (Their messages already in chat get them too.)
      if !emotes.isEmpty { self.redrawFor(user) }
    }
  }

  /// A chatter's personal emotes came: chat redrawn if they've said something on screen, a few
  /// together at most once a second. (Every one redrew all of chat at once, and in a big chat 7TV
  /// tells of many: most of them hadn't said anything yet.)
  private func redrawFor(_ user: String) {
    guard messages.contains(where: { $0.userID == user }) || pending.contains(where: { $0.userID == user }) else { return }
    guard !personalRedrawScheduled else { return }
    personalRedrawScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self else { return }
      self.personalRedrawScheduled = false
      if self.running { self.onUpdate(true) }
    }
  }
  private var personalRedrawScheduled = false

  /// The channel's 7TV set (or a personal one) changed during the stream.
  private func setChanged(_ set: String, added: [String: URL], removed: [String]) {
    // Anything but the channel's own set is someone's personal one (7TV sends a personal set's
    // emotes before saying whose it is).
    guard set == SevenTVSets.set(for: channel.id) else {
      for name in removed { personalSets[set]?[name] = nil }
      personalSets[set, default: [:]].merge(added) { _, new in new }
      return
    }
    for name in removed { thirdParty[name] = nil }
    thirdParty.merge(added) { _, new in new }
    thirdPartySets.byName = thirdParty
    rebuildEmoteSections()
    ActivityLog.shared.add("Chat (\(channel.name)): 7TV emotes changed live (\(added.count) added, \(removed.count) removed)")
  }
  private(set) var badges: [String: Badge] = [:]
  /// Emotes you can use here, for the picker (Recent first).
  @Published private(set) var emoteSections: [EmoteSection] = []
  /// The emote lists have been asked for (whatever came): the picker stops saying it's loading.
  @Published private(set) var emotesLoaded = false
  /// Every emote you can type here, by name (autocomplete).
  private(set) var usableEmotes: [NamedEmote] = []
  /// (For the message box's suggestions: what they were found among has changed.)
  var usableEmoteCount: Int { usableEmotes.count }
  private var emoteURLs: [String: URL] = [:]

  /// The picture for an emote name you can use here (the message box shows it).
  func emoteURL(for name: String) -> URL? { emoteURLs[name] }
  /// Your Twitch emotes: name → ID (to show them in your own messages).
  private(set) var twitchEmoteIDs: [String: String] = [:]
  private var thirdPartySets = ThirdPartyEmoteSets()
  private var twitchGroups: [TwitchEmoteGroup] = []
  /// Recent chatters, newest first (for @ autocomplete).
  private(set) var recentChatters: [String] = []
  /// The views showing this chat (the panel, and the overlay in full screen), told of new messages;
  /// `true` when everything should be re-rendered (emotes/badges loaded).
  private struct Listener {
    weak var owner: AnyObject?
    let update: (_ fullReload: Bool) -> Void
  }
  private var listeners: [Listener] = []

  /// `update` is called until `owner` goes away (capture it weakly).
  func addListener(_ owner: AnyObject, _ update: @escaping (_ fullReload: Bool) -> Void) {
    listeners.removeAll { $0.owner == nil || $0.owner === owner }
    listeners.append(Listener(owner: owner, update: update))
  }

  private func onUpdate(_ fullReload: Bool) {
    listeners.removeAll { $0.owner == nil }
    for listener in listeners { listener.update(fullReload) }
  }

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
  /// Rewinding a live stream: chat replays what was said at that point of the broadcast (from
  /// its VOD) while live chat keeps arriving in the background, and comes back on return.
  @Published private(set) var rewindReplay = false
  private var rewindVideoID: String?
  private var liveStash: [ChatMessage] = []
  /// Bumped whenever replaying starts or stops, so late answers for the old replay are dropped.
  private var replayEpoch = 0
  private var replaySourceID: String? { replayVideoID ?? rewindVideoID }

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
      let http = Self.emoteHTTP
      async let history = replay ? [] : ThirdPartyEmotes.recentMessages(login: channel.login, http: http)
      // Badges as soon as they're in (they waited for the recent messages, a slow service at times).
      Task { [weak self] in
        let loaded = await TwitchAPI.shared.badges(channelID: channel.id)
        guard let self, self.running, !loaded.isEmpty else { return }
        self.badges = loaded
        self.onUpdate(true)
      }
      // (Each list shown as it comes, not only once all six are in.)
      async let emoteSets = ThirdPartyEmotes.load(channelID: channel.id, http: http) { [weak self] partial in
        Task { @MainActor in self?.applyEarlyEmotes(partial) }
      }
      // Emotes (usually from memory now) are waited for only briefly: the recent messages show as
      // soon as they're in, and any emotes that come later are put into them then (it used to
      // wait for the slowest of six emote services before showing anything).
      let recent = await history
      let old = recent.compactMap(ChatMessage.init(irc:)).filter { $0.kind != .notice }
      messages = Array((old + messages).suffix(maxMessages))
      for message in old.reversed() { noteChatter(message.displayName) }
      if !old.isEmpty { onUpdate(true) }
      let emotes = await emoteSets
      emotesFinal = true
      thirdPartySets = emotes
      thirdParty = emotes.byName
      rebuildEmoteSections()
      onUpdate(true)
      if !emotes.complete { retryEmotes(attempt: 1) }
      keepImagesWarm()
      // (The channel's 7TV set is known now, on a first visit: its live changes from here.)
      if let set = SevenTVSets.set(for: channel.id) { sevenTV?.watch(set: set) }
      // The channel's own emotes' still pictures fetched ahead, so the picker shows them at once.
      // (They stay on disk, so this is mostly once per channel. A little after the chat opens, and
      // not too many: 7TV's connection is slow all told, and the emotes chat is showing come
      // first.)
      let ahead = NetworkWatch.shared.kind == .cellular || NetworkWatch.shared.constrained ? 40 : 150
      let urls = emotes.channel.flatMap(\.emotes).prefix(ahead).map(\.url)
      try? await Task.sleep(nanoseconds: 12_000_000_000)
      guard running else { return }
      for url in urls where ImagePipeline.shared.cached(url, maxPixels: 112) == nil {
        ImagePipeline.shared.prefetch(url, stillPixels: 112)
      }
    }
    if isReplay {
      status = .connected
      return
    }
    loadTwitchEmotes()
    connect()
    startSevenTV()
  }

  /// For the emote lists and recent messages: one for every chat, so its connections to 7TV,
  /// BTTV, FFZ and the recent-messages service are kept and used again (each chat opened made its
  /// own, with new secure connections to each).
  nonisolated static let emoteHTTP = URLSessionHTTPClient(timeout: 25)

  /// All six emote lists have come (or given up): a list arriving late from the first load (a
  /// refresh behind the cache) doesn't put back fewer.
  private var emotesFinal = false

  /// Some of the emote lists, while the rest are still coming: shown in chat and the picker now.
  private func applyEarlyEmotes(_ partial: ThirdPartyEmoteSets) {
    guard running, !emotesFinal, partial.byName.count > thirdParty.count else { return }
    thirdPartySets = partial
    thirdParty = partial.byName
    rebuildEmoteSections()
    onUpdate(true)
  }

  /// The connection to the emote hosts (7TV above all) kept open while chat runs (see `keepWarm`).
  private func keepImagesWarm() {
    if UIApplication.shared.applicationState != .background {
      let hosts = Dictionary(grouping: thirdParty.values, by: { $0.host ?? "" }).compactMap { $0.value.first }
      for url in hosts { ImagePipeline.shared.keepWarm(url) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
      guard let self, self.running else { return }
      self.keepImagesWarm()
    }
  }

  /// A list of emotes didn't come (a timeout, a server error): asked for again a little later,
  /// a few times, and the chat redrawn with what it brings (until then those emotes show as words).
  private func retryEmotes(attempt: Int) {
    let channel = self.channel
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(6 * attempt) * 1_000_000_000)
      guard let self, self.running else { return }
      let emotes = await ThirdPartyEmotes.load(channelID: channel.id, http: Self.emoteHTTP)
      guard self.running else { return }
      if emotes.byName.count > self.thirdParty.count {
        self.thirdPartySets = emotes
        self.thirdParty = emotes.byName
        self.rebuildEmoteSections()
        self.onUpdate(true)
        ActivityLog.shared.add("Chat (\(channel.name)): emotes that didn't load at first are in now")
      }
      if !emotes.complete, attempt < 4 {
        self.retryEmotes(attempt: attempt + 1)
      } else if !emotes.complete {
        ActivityLog.shared.add("Chat (\(channel.name)): an emote list (7TV, BTTV or FFZ) couldn't be loaded")
      }
    }
  }

  // MARK: VOD chat replay

  /// Shows what was said up to `position` (seconds into the VOD), fetching ahead as it plays.
  func replay(at position: Double) {
    guard let videoID = replaySourceID, running, position.isFinite else { return }
    if replay.move(to: position) {
      // A seek: start over from a little before the new position.
      pending = []
      messages = []
      onUpdate(true)
    }
    releaseReplay()
    fetchReplayIfNeeded(videoID: videoID)
  }

  /// Rewinding a live stream: show chat as it was at `position` (seconds into the broadcast).
  func startRewindReplay(videoID: String, at position: Double) {
    guard replayVideoID == nil, running, rewindVideoID == nil else { return }
    rewindVideoID = videoID
    rewindReplay = true
    replayEpoch += 1
    liveStash = Array((messages + pending).suffix(maxMessages))
    pending = []
    messages = []
    replay = ChatReplayBuffer()
    onUpdate(true)
    replay(at: position)
  }

  /// Back to live: live chat again, including what arrived meanwhile.
  func endRewindReplay() {
    guard rewindVideoID != nil else { return }
    rewindVideoID = nil
    rewindReplay = false
    replayEpoch += 1
    replay = ChatReplayBuffer()
    // Pending messages are the replay's; live ones went to the stash.
    pending = []
    messages = Array(liveStash.suffix(maxMessages))
    liveStash = []
    onUpdate(true)
  }

  private func releaseReplay() {
    for message in replay.due() { enqueue(message, live: false) }
  }

  private func fetchReplayIfNeeded(videoID: String) {
    guard let offset = replay.fetchNeeded() else { return }
    let generation = replay.generation
    let epoch = replayEpoch
    Task {
      do {
        let page = try await TwitchAPI.shared.videoComments(videoID: videoID, offset: offset, cursor: nil)
        guard epoch == replayEpoch else { return }
        replay.received(page.comments, for: offset, generation: generation)
      } catch {
        guard epoch == replayEpoch else { return }
        replay.failed(generation: generation)
        if generation == replay.generation {
          ActivityLog.shared.add("Chat replay: \(error.localizedDescription)")
          if messages.isEmpty && pending.isEmpty {
            let text = rewindReplay ? "Chat from this part of the stream isn't available yet." : "Chat replay isn't available for this video right now."
            enqueue(ChatMessage(notice: text), live: false)
          }
        }
      }
      guard epoch == replayEpoch, generation == replay.generation else { return }
      releaseReplay()
      // Keep reading until there's chat ahead of the video (or there's none yet).
      fetchReplayIfNeeded(videoID: videoID)
    }
  }

  /// Your Twitch emotes for this channel (needs sign-in).
  /// Your Twitch emotes here: the ones saved from last time at once, then fetched again behind
  /// them (up to four pages, one after another, which the picker and your messages used to wait
  /// for every time a chat opened).
  func loadTwitchEmotes() {
    let channelID = channel.id.isEmpty ? nil : channel.id
    // Signed out (or just signed out): none of your Twitch emotes.
    guard let login = TwitchAuth.shared.session?.login else {
      if !twitchGroups.isEmpty {
        twitchGroups = []
        rebuildEmoteSections()
      }
      return
    }
    let key = TwitchEmoteStore.key(login: login, channelID: channelID)
    Task {
      // Saved from last time, read off the main thread (with many subs, a big file to decode
      // while the stream opens), unless the fresh list beat it.
      async let fetched = TwitchAPI.shared.availableEmotes(channelID: channelID)
      if let key, twitchGroups.isEmpty {
        let saved = await Task.detached(priority: .userInitiated) { TwitchEmoteStore.read(key) }.value
        if let saved, twitchGroups.isEmpty {
          twitchGroups = saved
          rebuildEmoteSections()
        }
      }
      let fresh = await fetched
      // (Nothing came, a hiccup: what's shown stays.)
      guard !fresh.isEmpty || twitchGroups.isEmpty else { return }
      twitchGroups = fresh
      rebuildEmoteSections()
      if let key, !fresh.isEmpty { TwitchEmoteStore.write(fresh, key) }
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
    emotesLoaded = true
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
    sevenTV?.stop()
    sevenTV = nil
    if let returnToken { NotificationCenter.default.removeObserver(returnToken) }
    returnToken = nil
  }

  private var returnToken: NSObjectProtocol?

  /// Messages held while in the background go on screen as soon as the app's back.
  private func watchForReturn() {
    guard returnToken == nil else { return }
    returnToken = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let chat = self else { return }
      Task { @MainActor in chat.returned() }
    }
  }

  private func returned() {
    if let returnToken { NotificationCenter.default.removeObserver(returnToken) }
    returnToken = nil
    flush()
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
      onUpdate(true)
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
      // Read here, off the main thread (in fast chat, dozens of lines a second), and only what
      // they mean handed over.
      var lines: [ParsedLine] = []
      if case .success(let message) = result {
        switch message {
        case .string(let text): lines = Self.parse(text)
        case .data(let data): lines = Self.parse(String(decoding: data, as: UTF8.self))
        @unknown default: break
        }
      }
      Task { @MainActor in
        guard let self, self.socket === task else { return }
        switch result {
        case .failure(let error):
          self.reconnect(after: error)
        case .success:
          self.handle(lines)
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

  /// A line from chat's connection, read: what it says, and the chat message it makes (if any).
  private struct ParsedLine: @unchecked Sendable {
    var irc: IRCMessage
    var message: ChatMessage?
  }

  private nonisolated static func parse(_ text: String) -> [ParsedLine] {
    text.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" }).compactMap { line in
      guard let irc = IRCMessage.parse(String(line)) else { return nil }
      return ParsedLine(irc: irc, message: ChatMessage(irc: irc))
    }
  }

  private func handle(_ lines: [ParsedLine]) {
    for line in lines {
      let irc = line.irc
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
        if let notice = line.message { enqueue(notice) }
      default:
        if let message = line.message {
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
    if changed { onUpdate(false) }
  }

  /// - Parameter live: from live chat (held back while rewinding), or the replay's.
  private func enqueue(_ message: ChatMessage, live: Bool = true) {
    if live, rewindVideoID != nil {
      liveStash.append(message)
      if liveStash.count > maxMessages + 50 { liveStash.removeFirst(liveStash.count - maxMessages) }
      return
    }
    pending.append(message)
    guard !flushScheduled else { return }
    flushScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.flush() }
  }

  private func flush() {
    flushScheduled = false
    guard !pending.isEmpty else { return }
    // In the background nothing's on screen: keep collecting (no laying out and measuring
    // messages nobody sees) and hand them all over on the way back.
    if UIApplication.shared.applicationState == .background {
      if pending.count > maxMessages { pending.removeFirst(pending.count - maxMessages) }
      watchForReturn()
      return
    }
    messages.append(contentsOf: pending)
    pending.removeAll()
    if messages.count > maxMessages { messages.removeFirst(messages.count - maxMessages) }
    onUpdate(false)
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
    /// How sharp to load it (a GIF is bigger than an emote).
    var maxPixels: CGFloat = 112
  }
  var text: NSAttributedString
  var slots: [Slot]
  var highlighted: Bool
  /// Pictures that weren't loaded yet when it was laid out (their width was a guess).
  var waiting: [URL] = []
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
  private static func slot(
    _ url: URL, height: CGFloat, font: UIFont, into text: NSMutableAttributedString, slots: inout [RenderedMessage.Slot],
    waiting: inout [URL]
  ) {
    let image = ImagePipeline.shared.cached(url, maxPixels: 112)
    if image == nil {
      waiting.append(url)
      ImagePipeline.shared.load(url, maxPixels: 112) { _ in ChatImageEvents.imageArrived() }
    }
    // (Its shape from a first frame decoded ahead if the picture isn't in yet: no re-layout when it comes.)
    let shape = image ?? ImagePipeline.shared.still(url, maxPixels: 112)
    let ratio = shape.map { $0.size.height > 0 ? min(4, $0.size.width / $0.size.height) : 1 } ?? 1
    let size = CGSize(width: (height * ratio).rounded(), height: height)
    let attachment = NSTextAttachment()
    attachment.image = UIImage()
    attachment.bounds = CGRect(x: 0, y: (font.capHeight - height) / 2, width: size.width, height: size.height)
    slots.append(RenderedMessage.Slot(range: NSRange(location: text.length, length: 1), url: url, size: size))
    text.append(NSAttributedString(attachment: attachment))
  }

  /// A GIF from Twitch's GIF keyboard: on a line of its own, in a fixed box (its shape isn't known
  /// before it loads, and a fixed box keeps the line from jumping when it does).
  private static func gifSlot(
    _ url: URL, fontSize: CGFloat, font: UIFont, into text: NSMutableAttributedString, slots: inout [RenderedMessage.Slot],
    attributes: [NSAttributedString.Key: Any]
  ) {
    let height = (fontSize * 7).rounded()
    let size = CGSize(width: (height * 4 / 3).rounded(), height: height)
    if text.length > 0, !text.string.hasSuffix("\n") { text.append(NSAttributedString(string: "\n", attributes: attributes)) }
    let attachment = NSTextAttachment()
    attachment.image = UIImage()
    attachment.bounds = CGRect(origin: .zero, size: size)
    slots.append(RenderedMessage.Slot(range: NSRange(location: text.length, length: 1), url: url, size: size, maxPixels: 360))
    text.append(NSAttributedString(attachment: attachment))
  }

  /// A soft shadow under the text: readable over a moving picture (the chat overlay).
  private static let overlayShadow: NSShadow = {
    let shadow = NSShadow()
    shadow.shadowColor = UIColor.black.withAlphaComponent(0.9)
    shadow.shadowOffset = CGSize(width: 0, height: 1)
    shadow.shadowBlurRadius = 2
    return shadow
  }()

  static func render(
    _ message: ChatMessage, badges: [String: Badge], thirdParty: [String: URL], fontSize: CGFloat, me: String?,
    shadowed: Bool = false
  ) -> RenderedMessage {
    var rendered = renderPlain(message, badges: badges, thirdParty: thirdParty, fontSize: fontSize, me: me)
    if shadowed {
      let text = NSMutableAttributedString(attributedString: rendered.text)
      text.addAttribute(.shadow, value: overlayShadow, range: NSRange(location: 0, length: text.length))
      rendered.text = text
    }
    return rendered
  }

  private static func renderPlain(_ message: ChatMessage, badges: [String: Badge], thirdParty: [String: URL], fontSize: CGFloat, me: String?)
    -> RenderedMessage
  {
    let font = UIFont.systemFont(ofSize: fontSize)
    let bold = UIFont.systemFont(ofSize: fontSize, weight: .bold)
    let text = NSMutableAttributedString()
    var slots: [RenderedMessage.Slot] = []
    var waiting: [URL] = []
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
      slot(url, height: (fontSize + 3).rounded(), font: font, into: text, slots: &slots, waiting: &waiting)
      text.append(NSAttributedString(string: " ", attributes: plain))
    }
    let nameColor = color(message.color, fallbackSeed: message.login)
    text.append(NSAttributedString(string: message.displayName, attributes: [.font: bold, .foregroundColor: nameColor, .paragraphStyle: paragraph]))
    if message.isDeleted {
      text.append(NSAttributedString(string: ": <message deleted>", attributes: [.font: font, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: paragraph]))
      return RenderedMessage(text: text, slots: slots, highlighted: false, waiting: waiting)
    }
    text.append(NSAttributedString(string: message.kind == .action ? " " : ": ", attributes: plain))
    var body = plain
    if message.kind == .action { body[.foregroundColor] = nameColor }
    for fragment in message.fragments(thirdParty: thirdParty) {
      switch fragment {
      case .text(let t): text.append(NSAttributedString(string: t, attributes: body))
      case .emote(let name, let url):
        if ImagePipeline.shared.hasFailed(url, maxPixels: 112) {
          // Its picture couldn't be had: its name, not a blank.
          text.append(NSAttributedString(string: name, attributes: body))
        } else {
          slot(url, height: (fontSize * 1.75).rounded(), font: font, into: text, slots: &slots, waiting: &waiting)
        }
      case .gif(_, let url): gifSlot(url, fontSize: fontSize, font: font, into: text, slots: &slots, attributes: body)
      }
    }
    let highlighted = message.systemText != nil || (me.map { message.mentions($0) } ?? false)
    return RenderedMessage(text: text, slots: slots, highlighted: highlighted, waiting: waiting)
  }
}

/// Coalesces "an image finished loading" into one check per quarter second (only messages laid
/// out before their pictures arrived are touched).
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
  fileprivate var imageViews: [LoadingImageView] = []
  private var slots: [RenderedMessage.Slot] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    container.lineFragmentPadding = 0
    isOpaque = false
    backgroundColor = .clear
    contentMode = .redraw
    // The text is drawn off the main thread, so busy chat doesn't take frames from animations.
    layer.drawsAsynchronously = true
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
      // (A spare one lets go of what it was loading: nobody will see it.)
      view.load(index < slots.count ? slots[index].url : nil, maxPixels: index < slots.count ? slots[index].maxPixels : nil, fallback: nil)
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

extension ChatMessageView {
  /// Off screen: the pictures it was still waiting for are let go (it's shown again, and asks
  /// again, if it scrolls back).
  func letGoOfPictures() {
    // (All of them, animations still coming included: what's in memory is back at once.)
    for view in imageViews { view.load(nil, maxPixels: nil, fallback: nil) }
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
  /// Glides the list down to new messages frame by frame (an animated jump left blank space in
  /// busy chats, since rows only appeared once it ended).
  private var glide: CADisplayLink?
  private var lastGlideFrame: CFTimeInterval = 0
  /// A message's menu is open (or opening): chat holds still underneath so the menu stays on its
  /// message (it used to keep scrolling, leaving the highlight on an empty spot), and catches up
  /// once the menu closes.
  private var menuHold = false
  private var menuShown = false
  private var holdGeneration = 0
  /// What arrived meanwhile: nil = nothing, true = a full reload is due.
  private var heldReload: Bool?
  private var heldImages = false
  /// When rows were last measured for a new width (see `reflowForWidth`).
  private var lastReflow: CFTimeInterval = 0
  private var reflowScheduled = false
  var onMention: ((String) -> Void)?

  /// The chat panel, or the see-through overlay on a full-screen video (read-only, always on the
  /// newest messages, text with a shadow).
  enum Style { case panel, overlay }
  let style: Style

  init(chat: ChatController, style: Style = .panel) {
    self.chat = chat
    self.style = style
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
    // Scrolling chat puts the keyboard away (by Kestrel, in scrollViewWillBeginDragging, so it
    // slides: see Keyboard.dismiss).
    tableView.keyboardDismissMode = .none
    // Chat lays itself out (the panel already keeps clear of the Dynamic Island): without these the
    // list added the screen's side margin again, leaving an empty strip beside the text.
    tableView.insetsContentViewsToSafeArea = false
    tableView.contentInsetAdjustmentBehavior = .never
    tableView.cellLayoutMarginsFollowReadableWidth = false
    // Every row's height up front (they're cached), so "the bottom" is always exact.
    tableView.estimatedRowHeight = 0
    tableView.showsVerticalScrollIndicator = false
    tableView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tableView)
    if style == .overlay {
      // Nothing to touch: the overlay is moved as a whole, and taps go to the video.
      view.isUserInteractionEnabled = false
      tableView.isScrollEnabled = false
    }
    // A tap anywhere in chat (between messages too) puts the keyboard away; rows and menus still
    // get their touches.
    let tap = UITapGestureRecognizer(target: self, action: #selector(tappedChat))
    tap.cancelsTouchesInView = false
    tableView.addGestureRecognizer(tap)

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

    chat.addListener(self) { [weak self] full in self?.chatUpdated(fullReload: full) }
    imageObserver = NotificationCenter.default.addObserver(
      forName: ChatImageEvents.notification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.imagesArrived()
    }
    chatUpdated(fullReload: true)
  }

  deinit {
    if let imageObserver { NotificationCenter.default.removeObserver(imageObserver) }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopGlide()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if abs(tableView.bounds.width - lastWidth) > 0.5 {
      reflowForWidth()
    } else if abs(tableView.bounds.height - lastHeight) > 0.5 {
      // Keyboard or emote picker: stay on the newest messages.
      lastHeight = tableView.bounds.height
      if following { scrollToBottom(animated: false) }
    }
  }

  /// The width changed, so every row is measured again. While it keeps changing (dragging chat's
  /// edge, turning the phone) that happens about a dozen times a second instead of every frame,
  /// which measured all of chat 120 times a second and made those animations stutter.
  private func reflowForWidth() {
    let now = CACurrentMediaTime()
    let wait = 0.08 - (now - lastReflow)
    if wait > 0 {
      guard !reflowScheduled else { return }
      reflowScheduled = true
      DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
        guard let self else { return }
        self.reflowScheduled = false
        if abs(self.tableView.bounds.width - self.lastWidth) > 0.5 { self.reflowForWidth() }
      }
      return
    }
    lastReflow = now
    lastWidth = tableView.bounds.width
    lastHeight = tableView.bounds.height
    heights = [:]
    tableView.reloadData()
    if following { scrollToBottom(animated: false) }
  }

  private func key(_ message: ChatMessage) -> String { "\(message.id)-\(message.isDeleted)" }

  private func render(_ message: ChatMessage) -> RenderedMessage {
    let k = key(message)
    if let cached = rendered[k] { return cached }
    let result = freshRender(message)
    rendered[k] = result
    return result
  }

  private func freshRender(_ message: ChatMessage) -> RenderedMessage {
    let size = AppSettings.shared.chatFontSize
    return ChatRenderer.render(
      message, badges: chat.badges, thirdParty: chat.emoteMap(for: message), fontSize: style == .overlay ? max(12, size - 1) : size,
      me: chat.ownLogin, shadowed: style == .overlay)
  }

  private func chatUpdated(fullReload: Bool) {
    if menuHold {
      heldReload = (heldReload ?? false) || fullReload
      return
    }
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
      zip(old[start...], new).allSatisfy({ $0.id == $1.id })
    {
      let added = new.count - (old.count - start)
      // Messages removed by moderators since: just those rows are redrawn (rows as numbered
      // before the update).
      let deleted = zip(old[start...], new).enumerated().compactMap { $0.element.0.isDeleted != $0.element.1.isDeleted ? $0.offset + start : nil }
      guard start > 0 || added > 0 || !deleted.isEmpty else { return }
      // Measured before the data changes: where the first remaining row sits now (UIKit's own
      // figure, estimated or not) is exactly how far everything moves up.
      let removedHeight = start > 0 ? tableView.rectForRow(at: IndexPath(row: start, section: 0)).minY : 0
      displayed = new
      UIView.performWithoutAnimation {
        tableView.performBatchUpdates {
          if start > 0 { tableView.deleteRows(at: (0..<start).map { IndexPath(row: $0, section: 0) }, with: .none) }
          if !deleted.isEmpty { tableView.reloadRows(at: deleted.map { IndexPath(row: $0, section: 0) }, with: .none) }
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
    // (Only once a good few have gone: in fast chat this came several times a second, each time
    // going through every message.)
    guard rendered.count > displayed.count + 120 || heights.count > displayed.count + 120 else { return }
    let live = Set(displayed.map(key))
    rendered = rendered.filter { live.contains($0.key) }
    heights = heights.filter { live.contains($0.key) }
  }

  /// Pictures finished loading: messages laid out before theirs arrived get their real widths.
  /// Only those rows change (a full reload made busy chats flash and jump).
  private func imagesArrived() {
    if menuHold {
      heldImages = true
      return
    }
    var changed: [Int] = []
    var heightChanged = false
    var shiftAbove: CGFloat = 0
    let firstVisible = tableView.indexPathsForVisibleRows?.first?.row ?? 0
    let width = max(10, tableView.bounds.width - ChatCell.insets.left - ChatCell.insets.right)
    for (row, message) in displayed.enumerated() {
      let k = key(message)
      guard let old = rendered[k], !old.waiting.isEmpty,
        old.waiting.contains(where: {
          ImagePipeline.shared.cached($0, maxPixels: 112) != nil || ImagePipeline.shared.hasFailed($0, maxPixels: 112)
        })
      else { continue }
      let fresh = freshRender(message)
      rendered[k] = fresh
      guard fresh.slots.map(\.size) != old.slots.map(\.size) else { continue }
      changed.append(row)
      if let oldHeight = heights[k] {
        let height = ChatMessageView.height(of: fresh.text, width: width) + ChatCell.insets.top + ChatCell.insets.bottom
        heights[k] = height
        if abs(height - oldHeight) > 0.5 {
          heightChanged = true
          if row < firstVisible { shiftAbove += height - oldHeight }
        }
      }
    }
    guard !changed.isEmpty else { return }
    for row in changed {
      guard let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? ChatCell,
        let fresh = rendered[key(displayed[row])]
      else { continue }
      cell.messageView.show(fresh)
    }
    guard heightChanged else { return }
    UIView.performWithoutAnimation {
      tableView.performBatchUpdates(nil)
      // Scrolled back through chat: what's on screen stays put while rows above it grow.
      if !following, shiftAbove != 0 { tableView.contentOffset.y += shiftAbove }
    }
    if following { scrollToBottom(animated: true) }
  }

  private var bottomOffset: CGFloat {
    max(
      -tableView.adjustedContentInset.top,
      tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
  }

  private func scrollToBottom(animated: Bool) {
    guard !displayed.isEmpty, !menuHold else { return }
    tableView.layoutIfNeeded()
    let bottom = bottomOffset
    let distance = bottom - tableView.contentOffset.y
    guard abs(distance) > 0.5 else { return }
    guard animated, tableView.window != nil else {
      stopGlide()
      tableView.contentOffset.y = bottom
      return
    }
    // A long way behind (a burst after seeking): skip most of it, glide the last stretch.
    if distance > tableView.bounds.height * 1.5 { tableView.contentOffset.y = bottom - tableView.bounds.height * 0.5 }
    startGlide()
  }

  private func startGlide() {
    guard glide == nil else { return }
    // Reduce Motion: new messages appear in place, without the list sliding up to them.
    if UIAccessibility.isReduceMotionEnabled {
      tableView.contentOffset.y = bottomOffset
      return
    }
    let link = CADisplayLink(target: GlideTarget(self), selector: #selector(GlideTarget.step(_:)))
    // 60 a second is smooth for text sliding up; asking for ProMotion's 120 kept the screen at its
    // most power-hungry rate the whole time a busy chat moved.
    // (In Low Power Mode, 30: in busy chat this runs nearly all the time.)
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange =
        ProcessInfo.processInfo.isLowPowerModeEnabled
        ? CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30) : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }
    lastGlideFrame = 0
    link.add(to: .main, forMode: .common)
    glide = link
  }

  private func stopGlide() {
    glide?.invalidate()
    glide = nil
  }

  fileprivate func glideStep(_ link: CADisplayLink) {
    guard following, !menuHold, !tableView.isDragging, !tableView.isDecelerating else {
      stopGlide()
      return
    }
    let dt = lastGlideFrame == 0 ? link.duration : max(0.001, link.timestamp - lastGlideFrame)
    lastGlideFrame = link.timestamp
    let bottom = bottomOffset
    let remaining = bottom - tableView.contentOffset.y
    // Eases out: most of the way in ~0.2 s, and catches up smoothly when more arrives meanwhile.
    var step = remaining * CGFloat(1 - exp(-dt / 0.075))
    if abs(step) < 0.35 { step = remaining }
    tableView.contentOffset.y += step
    if abs(bottom - tableView.contentOffset.y) < 0.5 {
      tableView.contentOffset.y = bottom
      stopGlide()
    }
  }

  private func resume() {
    // Still coasting from a flick: stopped here, so the jump down starts now (it waited for the
    // coasting to end).
    if tableView.isDecelerating { tableView.setContentOffset(tableView.contentOffset, animated: false) }
    following = true
    UIView.animate(withDuration: 0.2) { self.resumeButton.alpha = 0 } completion: { _ in
      if self.following { self.resumeButton.isHidden = true }
    }
    chatUpdated(fullReload: false)
    scrollToBottom(animated: true)
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { displayed.count }

  /// A message scrolled out of view (in fast chat, seconds after it came): the emotes it was
  /// still waiting for aren't downloaded for nobody.
  func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
    (cell as? ChatCell)?.messageView.letGoOfPictures()
  }

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
    cell.contentView.backgroundColor =
      result.highlighted ? ChatRenderer.accent.withAlphaComponent(style == .overlay ? 0.3 : 0.14) : .clear
    return cell
  }

  @objc private func tappedChat() {
    Keyboard.dismiss()
  }

  /// A tap on chat just puts the keyboard away (reply by holding a message instead).
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    Keyboard.dismiss()
  }

  func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint)
    -> UIContextMenuConfiguration?
  {
    guard style == .panel, indexPath.row < displayed.count else { return nil }
    let message = displayed[indexPath.row]
    guard message.kind != .notice else { return nil }
    holdForMenu()
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

  func tableView(
    _ tableView: UITableView, willDisplayContextMenu configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    menuShown = true
  }

  func tableView(
    _ tableView: UITableView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    // Catch up once the menu has gone (rows moving under the closing menu looked broken too).
    if let animator {
      animator.addCompletion { [weak self] in self?.releaseMenuHold() }
    } else {
      releaseMenuHold()
    }
  }

  /// Holds chat still from the moment a press may become a menu.
  private func holdForMenu() {
    menuHold = true
    menuShown = false
    stopGlide()
    holdGeneration += 1
    let generation = holdGeneration
    // The press may never become a menu (a tap, a scroll): don't hold long without one.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self, self.holdGeneration == generation, !self.menuShown else { return }
      self.releaseMenuHold()
    }
  }

  private func releaseMenuHold() {
    guard menuHold else { return }
    menuHold = false
    menuShown = false
    holdGeneration += 1
    if let full = heldReload {
      heldReload = nil
      chatUpdated(fullReload: full)
    }
    if heldImages {
      heldImages = false
      imagesArrived()
    }
    if following { scrollToBottom(animated: true) }
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    Keyboard.dismiss()
    releaseMenuHold()
    following = false
    stopGlide()
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

/// Holds the chat list weakly for its display link (which keeps its target alive).
private final class GlideTarget: NSObject {
  weak var owner: ChatViewController?

  init(_ owner: ChatViewController) {
    self.owner = owner
  }

  @objc func step(_ link: CADisplayLink) {
    guard let owner else {
      link.invalidate()
      return
    }
    owner.glideStep(link)
  }
}

struct ChatMessagesView: UIViewControllerRepresentable {
  let chat: ChatController
  var style: ChatViewController.Style = .panel
  var onMention: ((String) -> Void)?
  /// False while the player is in the mini player: the hidden chat takes no touches. (SwiftUI's
  /// own switch didn't reach this UIKit view: hidden under the app, it took touches meant for it.)
  var active = true

  func makeUIViewController(context: Context) -> ChatViewController {
    let controller = ChatViewController(chat: chat, style: style)
    controller.onMention = onMention
    controller.view.isUserInteractionEnabled = active
    return controller
  }

  func updateUIViewController(_ controller: ChatViewController, context: Context) {
    controller.onMention = onMention
    if controller.view.isUserInteractionEnabled != active { controller.view.isUserInteractionEnabled = active }
  }
}

/// The room the open emote picker takes at the bottom of the window (0 when it's closed): the
/// player makes room for chat above it as it does for the keyboard (on iPhone Duo's outer screen
/// the picture stayed full size and the picker covered chat).
final class ChatPickerSpace: ObservableObject {
  static let shared = ChatPickerSpace()
  @Published var height: CGFloat = 0
}

/// Messages plus the box to write in (or a prompt to sign in), with emote picker and
/// autocomplete (":" for emotes, "@" for people in chat).
struct ChatPanel: View {
  @ObservedObject var chat: ChatController
  /// Space to keep clear at the bottom: the keyboard (and a little air) while it's up, else the
  /// home indicator.
  var bottomInset: CGFloat = 0
  /// The keyboard is up (`bottomInset` is the keyboard's).
  var keyboardUp = false
  /// The home indicator's room (under the emote picker).
  var safeBottom: CGFloat = 0
  /// Landscape: a shorter emote picker.
  var compact = false
  /// False while the player is shrunk into the mini player: the message box can't take focus.
  var active = true
  @ObservedObject private var account = TwitchAccount.shared
  @State private var draft = ""
  @State private var showLogin = false
  @State private var pickerOpen = false
  /// The picker takes the keyboard's place exactly, so switching between them leaves the message
  /// box where it is.
  @State private var pickerHeight: CGFloat = 280
  @State private var pickerSwap = 0
  @State private var focused = false
  @State private var warning: String? = nil
  /// The picker's tab: emotes (0) or GIFs (1).
  @State private var pickerTab = 0
  @StateObject private var gifKeyboard = GifKeyboardModel()

  private static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
  private var pickerPad: CGFloat { min(safeBottom, 24) }

  var body: some View {
    VStack(spacing: 0) {
      ZStack(alignment: .top) {
        ChatMessagesView(chat: chat, onMention: account.session == nil ? nil : { login in
          draft = "@\(login) " + draft
          focused = true
        }, active: active)
        // The oldest line in view fades out at the top instead of being cut off by a hard edge.
        .mask(
          VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
            Color.black
          }
        )
        statusPill
      }
      Divider().overlay(Color.white.opacity(0.08))
      if !suggestions.isEmpty {
        suggestionStrip
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      VStack(spacing: 0) {
        inputBar
        if pickerOpen {
          VStack(spacing: 0) {
            // Emotes, or Twitch's GIF keyboard (signed in, in a channel).
            if account.session != nil, !chat.channel.id.isEmpty {
              Picker("Picker", selection: $pickerTab) {
                Text("Emotes").tag(0)
                Text("GIFs").tag(1)
              }
              .pickerStyle(.segmented)
              .padding(.horizontal, 10)
              .padding(.top, 6)
              .onChange(of: pickerTab) { tab in if tab == 1 { gifKeyboard.prepare(channelID: chat.channel.id) } }
            }
            if pickerTab == 1 {
              GifKeyboard(model: gifKeyboard) {
                withAnimation(Self.spring) { pickerOpen = false }
              }
            } else {
              EmotePicker(sections: chat.emoteSections, loaded: chat.emotesLoaded) { insert($0.name) }
            }
          }
          .frame(height: pickerHeight)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      // The open picker and the box: a tap anywhere else closes the picker (as for the keyboard).
      .background(
        GeometryReader { proxy in
          Color.clear
            .onAppear { if pickerOpen { EmotePickerArea.frame = proxy.frame(in: .global) } }
            .onChange(of: proxy.frame(in: .global)) { frame in if pickerOpen { EmotePickerArea.frame = frame } }
            .onChange(of: pickerOpen) { open in EmotePickerArea.frame = open ? proxy.frame(in: .global) : nil }
        }
      )
      .onDisappear { if pickerOpen { EmotePickerArea.frame = nil } }
      .onReceive(NotificationCenter.default.publisher(for: ScreenTour.openEmotes)) { _ in
        if !pickerOpen { openPicker() }
      }
      .onReceive(NotificationCenter.default.publisher(for: EmotePickerArea.closeNotification)) { _ in
        guard pickerOpen else { return }
        withAnimation(Self.spring) { pickerOpen = false }
      }
    }
    // While the keyboard comes or goes behind the open picker, the box stays on top of whichever
    // is taller.
    .padding(.bottom, pickerOpen ? max(pickerPad, bottomInset - pickerHeight) : bottomInset)
    .animation(.easeOut(duration: 0.15), value: suggestions.isEmpty)
    .sheet(isPresented: $showLogin) { TwitchLoginView() }
    .onChange(of: account.session?.login) { _ in chat.reconnect() }
    .onChange(of: focused) { isFocused in
      if isFocused, pickerOpen { closePickerUnderKeyboard() }
      if isFocused { KeyboardObserver.shared.checkSoon() } else { KeyboardObserver.shared.messageBoxLeft() }
    }
    .onChange(of: pickerOpen) { open in
      let space = open ? pickerHeight + pickerPad : 0
      guard ChatPickerSpace.shared.height != space else { return }
      withAnimation(Self.spring) { ChatPickerSpace.shared.height = space }
    }
    .onDisappear { if pickerOpen { ChatPickerSpace.shared.height = 0 } }
    .onChange(of: active) { isActive in
      guard !isActive else { return }
      focused = false
      pickerOpen = false
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
      if chat.rewindReplay {
        pill("Chat from this point of the stream", systemImage: "clock.arrow.circlepath")
      } else if case .disconnected(let reason) = chat.status {
        pill(reason)
      } else if chat.status == .connecting {
        pill("Connecting to chat…")
      }
    }
    .transition(.opacity.combined(with: .move(edge: .top)))
    .animation(.easeInOut(duration: 0.2), value: chat.status)
    .animation(.easeInOut(duration: 0.2), value: chat.rewindReplay)
  }

  private func pill(_ text: String, systemImage: String? = nil) -> some View {
    HStack(spacing: 5) {
      if let systemImage { Image(systemName: systemImage) }
      Text(text)
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 10).padding(.vertical, 5)
    .background(.ultraThinMaterial, in: Capsule())
    .padding(.top, 8)
    .allowsHitTesting(false)
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
    // (Once per word typed: the view asks three times each time it's drawn, and each search ran
    // through all of the channel's emotes, thousands on a big channel.)
    let query = String(word.dropFirst())
    // (Chatters: a short list, looked through each time, as it changes with every message.)
    guard word.hasPrefix(":") else { return chat.chatterSuggestions(query).map(Suggestion.chatter) }
    let key = "\(word)|\(chat.usableEmoteCount)"
    if suggestionCache.key == key { return suggestionCache.value }
    let found = chat.emoteSuggestions(query).map(Suggestion.emote)
    suggestionCache.key = key
    suggestionCache.value = found
    return found
  }

  private final class SuggestionCache {
    var key = ""
    var value: [Suggestion] = []
  }
  @State private var suggestionCache = SuggestionCache()

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

  // MARK: Emote picker ↔ keyboard

  private func openPicker() {
    pickerSwap += 1
    if keyboardUp {
      // Exactly where the keyboard is: it slides away underneath, and the box doesn't move.
      pickerHeight = max(140, bottomInset - pickerPad)
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { pickerOpen = true }
      focused = false
    } else {
      pickerHeight = KeyboardObserver.lastHeight.map { max(140, $0 + 14 - pickerPad) } ?? (compact ? 190 : 280)
      withAnimation(Self.spring) { pickerOpen = true }
    }
  }

  /// The keyboard was asked for: it comes up over the picker, which goes once it's covered (the
  /// box rides on whichever is taller meanwhile, so nothing jumps).
  private func closePickerUnderKeyboard() {
    pickerSwap += 1
    let swap = pickerSwap
    let pad = pickerPad
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
      guard swap == pickerSwap, pickerOpen, focused else { return }
      let keyboardSpace = (KeyboardObserver.lastHeight ?? 0) + 14
      if FirstResponder.current is EmoteTextView, abs(keyboardSpace - (pickerHeight + pad)) < 3 {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pickerOpen = false }
      } else {
        withAnimation(Self.spring) { pickerOpen = false }
      }
    }
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
        // Bottom-aligned: as the box grows with longer messages, its buttons stay by the last line.
        HStack(alignment: .bottom, spacing: 8) {
          EmoteTextField(
            text: $draft, isFocused: $focused,
            placeholder: !chat.canSend ? "Joining chat…" : chat.emoteOnly ? "Emotes only" : "Send a message",
            enabled: chat.canSend && active,
            emoteURL: { chat.emoteURL(for: $0) }, onSubmit: send
          )
          .frame(minHeight: EmoteTextField.minHeight)
          .padding(.leading, 12)
          .padding(.trailing, 40)
          .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
          // Part of the box itself (not a neighbour in a row), so it moves with the box and can't
          // drift out of it while the keyboard comes and goes.
          .overlay(alignment: .bottomTrailing) {
            Button {
              if pickerOpen { focused = true } else { openPicker() }
            } label: {
              Image(systemName: pickerOpen ? "keyboard" : "face.smiling")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(pickerOpen ? .accentTeal : .white.opacity(0.75))
                .frame(width: 32, height: 32)
                // (A finger's worth to tap: 44 pt, the look unchanged.)
                .contentShape(Rectangle().inset(by: -6))
            }
            .padding(.trailing, 4)
            .padding(.bottom, 2)
            .accessibilityLabel(pickerOpen ? "Keyboard" : "Emotes")
          }
          Button(action: send) {
            Image(systemName: "paperplane.fill").font(.system(size: 16, weight: .semibold))
              .frame(width: 36, height: 36)
              .background(draftIsEmpty ? Color.white.opacity(0.08) : Color.accentTeal, in: Circle())
              .contentShape(Rectangle().inset(by: -4))
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
    Haptics.tap()
    chat.send(text)
    draft = ""
  }
}

/// Twitch-style emote picker: every emote you can use here, by channel, with a strip to jump.
struct EmotePicker: View {
  let sections: [EmoteSection]
  /// Nothing more is coming: with no sections, there are none to show (not still loading).
  var loaded = false
  var onPick: (NamedEmote) -> Void

  var body: some View {
    VStack(spacing: 0) {
      if sections.isEmpty, loaded {
        // (It said "Loading emotes…" forever: signed out, on a channel with no 7TV, BTTV or FFZ
        // emotes, there are none to load.)
        VStack(spacing: 6) {
          Image(systemName: "face.smiling").font(.title2).foregroundColor(.secondary)
          Text(TwitchAccount.shared.session == nil ? "Sign in to use your Twitch emotes" : "No emotes here yet")
            .font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if sections.isEmpty {
        VStack(spacing: 6) {
          ProgressView()
          Text("Loading emotes…").font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        EmoteGrid(sections: sections, jump: jump, onPick: onPick) { id in
          if id != current { current = id }
        }
        Divider().overlay(Color.white.opacity(0.08))
        ScrollViewReader { strip in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
              ForEach(sections) { section in
                let selected = section.id == (current ?? sections.first?.id)
                Button {
                  current = section.id
                  jump = EmoteGrid.Jump(section: section.id, serial: jump.serial + 1)
                } label: {
                  tabIcon(section)
                    .frame(width: 38, height: 34)
                    .background(
                      RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.14) : Color.clear)
                    )
                    .overlay(alignment: .bottom) {
                      Capsule().fill(Color.accentTeal).frame(width: 16, height: 2.5).opacity(selected ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .id("strip-" + section.id)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
              }
            }
            .padding(.horizontal, 6)
            .animation(.easeInOut(duration: 0.2), value: current)
          }
          .frame(height: 38)
          // The strip keeps the section scrolled to in view.
          .onChange(of: current) { id in
            guard let id else { return }
            withAnimation(.easeInOut(duration: 0.25)) { strip.scrollTo("strip-" + id, anchor: .center) }
          }
        }
      }
    }
    .background(Color(white: 0.09))
    .onChange(of: tourState) { state in
      if ScreenTour.requested != nil { ScreenTour.pickerState = state }
    }
    .onAppear {
      if ScreenTour.requested != nil { ScreenTour.pickerState = tourState }
    }
    // (Screen tour: a pick in the strip, as a tap on its fourth icon.)
    .onReceive(NotificationCenter.default.publisher(for: ScreenTour.pickEmoteSection)) { _ in
      guard !sections.isEmpty else { return }
      let id = sections[min(3, sections.count - 1)].id
      current = id
      jump = EmoteGrid.Jump(section: id, serial: jump.serial + 1)
    }
  }

  /// What the screen tour notes down (empty while there are no sections yet).
  private var tourState: String {
    sections.isEmpty ? "" : "current \(current ?? "-") · sections " + sections.map(\.id).joined(separator: ", ")
  }

  /// The section scrolled to (nil: the first).
  @State private var current: String?
  /// The latest section picked in the strip, for the grid to scroll to.
  @State private var jump = EmoteGrid.Jump()

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

/// The emote picker's grid: a collection view, its section titles staying at the top while their
/// emotes scroll under them. (A SwiftUI scroll view put back where it liked as you scrolled a big
/// list, xQc's 7TV emotes above all: it went back up to just past them, and a far section picked
/// in the strip was missed. A collection view has every emote's place worked out exactly.)
struct EmoteGrid: UIViewRepresentable {
  struct Jump: Equatable {
    var section: String?
    var serial = 0
  }

  let sections: [EmoteSection]
  let jump: Jump
  var onPick: (NamedEmote) -> Void
  /// The section scrolled to changed (the last whose title has reached the top).
  var onSection: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UICollectionView {
    let coordinator = context.coordinator
    let layout = UICollectionViewCompositionalLayout { _, environment in
      Coordinator.section(width: environment.container.effectiveContentSize.width)
    }
    let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
    view.backgroundColor = .clear
    view.alwaysBounceVertical = true
    view.contentInsetAdjustmentBehavior = .never
    view.contentInset.bottom = 8
    view.keyboardDismissMode = .none
    view.register(EmoteGridCell.self, forCellWithReuseIdentifier: EmoteGridCell.reuse)
    view.register(
      EmoteGridHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: EmoteGridHeader.reuse)
    view.dataSource = coordinator
    view.delegate = coordinator
    coordinator.view = view
    return view
  }

  func updateUIView(_ view: UICollectionView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onPick = onPick
    coordinator.onSection = onSection
    coordinator.show(sections)
    if jump.serial != coordinator.jumpSerial {
      coordinator.jumpSerial = jump.serial
      if let id = jump.section { coordinator.scroll(to: id) }
    }
  }

  final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
    weak var view: UICollectionView?
    var onPick: (NamedEmote) -> Void = { _ in }
    var onSection: (String) -> Void = { _ in }
    var jumpSerial = 0
    private var sections: [EmoteSection] = []
    /// What the sections were last time (shown again only when that changes).
    private var shape: [String] = []
    /// Scrolling to a picked section: the ones passed on the way aren't taken as scrolled to.
    private var jumpingTo: String?
    private var reported: String?

    static let headerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 42
    static let spacing: CGFloat = 4

    /// As many columns as fit at 42 points or more (as the SwiftUI grid had it).
    static func section(width: CGFloat) -> NSCollectionLayoutSection {
      let usable = max(1, width - 16)
      let columns = max(1, Int((usable + spacing) / (rowHeight + spacing)))
      let item = NSCollectionLayoutItem(
        layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalHeight(1)))
      let group = NSCollectionLayoutGroup.horizontal(
        layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(rowHeight)),
        repeatingSubitem: item, count: columns)
      group.interItemSpacing = .fixed(spacing)
      // (Inset in the rows, so the title runs the whole width.)
      group.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
      let section = NSCollectionLayoutSection(group: group)
      section.interGroupSpacing = spacing
      // (Nothing above the first row: a section begins exactly a title's height above it.)
      section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: spacing * 2, trailing: 0)
      let header = NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(headerHeight)),
        elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
      header.pinToVisibleBounds = true
      header.zIndex = 2
      section.boundarySupplementaryItems = [header]
      return section
    }

    /// Sections that came while the list was moving, shown once it stops.
    private var waitingSections: [EmoteSection]?

    func show(_ new: [EmoteSection]) {
      let newShape = new.map { "\($0.id)#\($0.emotes.count)#\($0.emotes.first?.name ?? "")#\($0.emotes.last?.name ?? "")" }
      guard let view else { return }
      if newShape == shape {
        // (Back to what's shown: nothing waits any more.)
        waitingSections = nil
        sections = new
        return
      }
      // Not while it's moving (a finger on it, coasting, or on its way to a section picked): a
      // list arriving then stopped it dead, or put it back where it had been.
      if view.isTracking || view.isDragging || view.isDecelerating || jumpingTo != nil {
        waitingSections = new
        return
      }
      waitingSections = nil
      let oldIDs = sections.map(\.id)
      let changed = newShape.indices.filter { $0 >= shape.count || shape[$0] != newShape[$0] }
      sections = new
      shape = newShape
      if oldIDs == new.map(\.id) {
        // The same sections, some with more or other emotes: only those shown again (the others'
        // pictures stay up, and it stays where it is).
        UIView.performWithoutAnimation { view.reloadSections(IndexSet(changed)) }
      } else {
        // (Where it was is kept: lists coming in one by one don't throw it back to the top.)
        let offset = view.contentOffset
        view.reloadData()
        view.layoutIfNeeded()
        let maxY = max(-view.adjustedContentInset.top, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        view.contentOffset = CGPoint(x: offset.x, y: min(offset.y, maxY))
      }
      followScroll()
    }

    /// The list has stopped: sections that came meanwhile go up now.
    private func settled() {
      guard let waiting = waitingSections else { return }
      waitingSections = nil
      show(waiting)
    }

    /// Where a section begins: its title's place before it sticks to the top.
    private func top(of index: Int) -> CGFloat? {
      guard let view, index < sections.count, !sections[index].emotes.isEmpty,
        let first = view.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: index))
      else { return nil }
      return first.frame.minY - Self.headerHeight
    }

    private var maxOffset: CGFloat {
      guard let view else { return 0 }
      return max(0, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
    }

    func scroll(to id: String) {
      guard let view, let index = sections.firstIndex(where: { $0.id == id }) else { return }
      view.layoutIfNeeded()
      guard let top = top(of: index) else { return }
      let y = min(max(0, top), maxOffset) - view.adjustedContentInset.top
      guard abs(view.contentOffset.y - y) > 0.5 else {
        report(id)
        return
      }
      jumpingTo = id
      report(id)
      view.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }

    /// The section scrolled to: the last whose title has reached the top; scrolled to the end,
    /// a section picked there stays while its title is in view (it can't come up to the top).
    private func followScroll() {
      guard jumpingTo == nil, let view, !sections.isEmpty else { return }
      let y = view.contentOffset.y + view.adjustedContentInset.top
      var reached = sections.first?.id
      for index in sections.indices {
        guard let top = top(of: index) else { continue }
        if top <= y + 1 { reached = sections[index].id } else { break }
      }
      if y >= maxOffset - 2, let picked = reported, let index = sections.firstIndex(where: { $0.id == picked }),
        let top = top(of: index), top >= y - 1, top < y + view.bounds.height
      {
        reached = picked
      }
      if let reached { report(reached) }
    }

    private func report(_ id: String) {
      guard id != reported else { return }
      reported = id
      // (Told after this pass: it may come while SwiftUI is updating the grid.)
      DispatchQueue.main.async { [weak self] in self?.onSection(id) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { followScroll() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
      jumpingTo = nil
      followScroll()
      settled()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate { settled() }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      // (A finger takes over from a jump still on its way.)
      jumpingTo = nil
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
      sections[section].emotes.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
      let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmoteGridCell.reuse, for: indexPath) as! EmoteGridCell
      cell.show(sections[indexPath.section].emotes[indexPath.item])
      return cell
    }

    func collectionView(
      _ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath
    ) -> UICollectionReusableView {
      let header = collectionView.dequeueReusableSupplementaryView(
        ofKind: kind, withReuseIdentifier: EmoteGridHeader.reuse, for: indexPath) as! EmoteGridHeader
      header.label.text = sections[indexPath.section].title
      return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
      collectionView.deselectItem(at: indexPath, animated: false)
      Haptics.tap()
      onPick(sections[indexPath.section].emotes[indexPath.item])
    }
  }
}

/// One emote in the picker's grid: its picture (animated ones play), shrinking a little while
/// pressed.
///
/// Its first frame comes first, fetched on its own and dropped as soon as the cell scrolls away;
/// the animation only once the emote has stayed in view a moment. (Asking for whole pictures, a
/// fast scroll through xQc's thousands of emotes queued hundreds of downloads and animations
/// nobody would see, and the emotes in view waited behind them: a grid of blanks.)
final class EmoteGridCell: UICollectionViewCell {
  static let reuse = "emote"
  private static let pixels: CGFloat = 112
  private let stillView = UIImageView()
  private let animatedView = LoadingImageView()
  /// While the picture is still coming: a faint tile, so a slow connection doesn't look empty.
  private let tile = UIView()
  private var loading: Task<Void, Never>?
  private var url: URL?

  override init(frame: CGRect) {
    super.init(frame: frame)
    tile.backgroundColor = UIColor(white: 1, alpha: 0.06)
    tile.layer.cornerRadius = 7
    tile.layer.cornerCurve = .continuous
    for view in [tile, stillView, animatedView] {
      view.contentMode = .scaleAspectFit
      view.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(view)
      NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalToConstant: 32), view.heightAnchor.constraint(equalToConstant: 32),
        view.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        view.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      ])
    }
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The whole animation, asked for once the emote stayed in view (called off if it goes).
  private var animationTicket: (id: Int, url: URL)?

  private func callOffAnimation() {
    guard let ticket = animationTicket else { return }
    animationTicket = nil
    ImagePipeline.shared.cancel(ticket.id, ticket.url, maxPixels: Self.pixels)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    loading?.cancel()
    loading = nil
    callOffAnimation()
  }

  func show(_ emote: NamedEmote) {
    accessibilityLabel = emote.name
    guard emote.url != url || loading == nil && stillView.image == nil && animatedView.shownPicture == nil else { return }
    url = emote.url
    loading?.cancel()
    callOffAnimation()
    stillView.image = nil
    animatedView.load(nil, maxPixels: Self.pixels, fallback: nil)
    animatedView.isHidden = true
    let url = emote.url
    // Already in memory (seen in chat, or a moment ago): as it is, animation and all.
    if ImagePipeline.shared.cached(url, maxPixels: Self.pixels) != nil {
      tile.isHidden = true
      animatedView.isHidden = false
      animatedView.load(url, maxPixels: Self.pixels, fallback: nil)
      return
    }
    tile.isHidden = false
    loading = Task { @MainActor [weak self] in
      var still: UIImage?
      for attempt in 0..<4 {
        if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000) }
        guard !Task.isCancelled else { return }
        still = await ImagePipeline.shared.stillImage(url, maxPixels: Self.pixels)
        if still != nil || Task.isCancelled { break }
      }
      guard let self, !Task.isCancelled, self.url == url else { return }
      if let still {
        UIView.transition(with: self.stillView, duration: 0.15, options: .transitionCrossDissolve) {
          self.stillView.image = still
          self.tile.isHidden = true
        }
      }
      // Animated ones play once the emote has stayed in view a moment (not for every one flicked
      // past).
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      let ticket = ImagePipeline.shared.load(url, maxPixels: Self.pixels) { [weak self] image in
        guard let self, self.url == url, let image else { return }
        guard (image.images?.count ?? 0) > 1 || self.stillView.image == nil else { return }
        self.animatedView.load(url, maxPixels: Self.pixels, fallback: nil)
        self.animatedView.isHidden = false
        self.stillView.image = nil
        self.tile.isHidden = true
      }
      if let ticket { self.animationTicket = (ticket, url) }
    }
  }

  override var isHighlighted: Bool {
    didSet {
      guard isHighlighted != oldValue else { return }
      let reduce = UIAccessibility.isReduceMotionEnabled
      UIView.animate(
        withDuration: isHighlighted ? 0.12 : 0.25, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0,
        options: [.allowUserInteraction, .beginFromCurrentState]
      ) {
        self.contentView.transform = self.isHighlighted && !reduce ? CGAffineTransform(scaleX: 0.82, y: 0.82) : .identity
        self.contentView.alpha = self.isHighlighted ? 0.85 : 1
      }
    }
  }
}

/// A section's title in the picker's grid.
final class EmoteGridHeader: UICollectionReusableView {
  static let reuse = "title"
  let label = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor(white: 0.09, alpha: 0.97)
    let base = UIFont.preferredFont(forTextStyle: .caption1)
    label.font = UIFont.systemFont(ofSize: base.pointSize, weight: .bold)
    label.adjustsFontForContentSizeCategory = false
    label.textColor = .secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    isAccessibilityElement = true
    accessibilityTraits = .header
  }

  required init?(coder: NSCoder) { fatalError() }

  override var accessibilityLabel: String? {
    get { label.text }
    set {}
  }
}

/// A light press effect for buttons.
struct PressableStyle: ButtonStyle {
  var scale: CGFloat = 0.92

  func makeBody(configuration: Configuration) -> some View {
    Pressed(configuration: configuration, scale: scale)
  }

  /// With Reduce Motion on, a press only dims (no shrinking).
  private struct Pressed: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      configuration.label
        .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
        .opacity(configuration.isPressed ? (reduceMotion ? 0.6 : 0.85) : 1)
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
  }
}

/// Your Twitch emotes in each channel, saved for next time (the caches folder: iOS may clear it).
enum TwitchEmoteStore {
  static func key(login: String?, channelID: String?) -> String? {
    guard let login, !login.isEmpty else { return nil }
    let safe = { (s: String) in s.filter { $0.isLetter || $0.isNumber || $0 == "_" } }
    return "twitch-\(safe(login))-\(safe(channelID ?? "none"))"
  }

  private static func file(_ key: String) -> URL? {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    let folder = caches.appendingPathComponent("EmoteSets", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(key + ".json")
  }

  private struct Stored: Codable {
    var at: Date
    var groups: [TwitchEmoteGroup]
  }

  /// Saved within the last week.
  static func read(_ key: String) -> [TwitchEmoteGroup]? {
    guard let file = file(key), let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data),
      Date().timeIntervalSince(stored.at) < 7 * 24 * 3600, !stored.groups.isEmpty
    else { return nil }
    return stored.groups
  }

  static func write(_ groups: [TwitchEmoteGroup], _ key: String) {
    guard let file = file(key) else { return }
    let stored = Stored(at: Date(), groups: groups)
    DispatchQueue.global(qos: .utility).async { try? JSONEncoder().encode(stored).write(to: file, options: .atomic) }
  }
}

