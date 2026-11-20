// 7TV's live events for a channel's chat (its EventAPI, as the 7TV extension and Chatterino7 use):
// personal emotes (7TV subscribers' own emotes, usable in any channel, announced as people chat)
// and changes to the channel's emote set during the stream. Without them, those emotes showed as
// plain words.

import Foundation

@MainActor
final class SevenTVEvents {
  /// A Twitch user (by id) has this personal 7TV emote set.
  var onPersonalSet: ((String, String) -> Void)?
  /// An emote set changed: emotes added (by name) and names removed.
  var onSetChanged: ((String, [String: URL], [String]) -> Void)?

  private let channelID: String
  private var socket: URLSessionWebSocketTask?
  private var running = false
  private var failures = 0
  private var subscribedSets: Set<String> = []
  /// 7TV's heartbeat (it says how often in its hello) and when anything last came: silence for
  /// a few beats means the connection died without closing, and a new one is made.
  private var heartbeat: TimeInterval = 25
  private var lastHeard = Date()
  private var watchdog: Task<Void, Never>?

  init(channelID: String) {
    self.channelID = channelID
  }

  func start() {
    guard !running, !channelID.isEmpty else { return }
    running = true
    connect()
    watchdog = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        guard let self, self.running else { return }
        if let socket = self.socket, Date().timeIntervalSince(self.lastHeard) > self.heartbeat * 2 + 10 {
          socket.cancel(with: .goingAway, reason: nil)
          self.socket = nil
          self.connect()
        }
      }
    }
  }

  func stop() {
    watchdog?.cancel()
    watchdog = nil
    running = false
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
  }

  /// Live changes to this emote set (the channel's, or someone's personal one).
  /// - Parameter essential: the channel's own set (always); chatters' personal sets only up to a
  ///   limit (in a big chat there are thousands, each a subscription on 7TV's connection, which
  ///   allows only so many; their emotes come with 7TV's announcement anyway, so this is only for
  ///   a set changed while chat runs).
  func watch(set: String, essential: Bool = false) {
    guard essential || subscribedSets.count < 150 else { return }
    guard subscribedSets.insert(set).inserted else { return }
    send(["op": 35, "d": ["type": "emote_set.update", "condition": ["object_id": set]]])
  }

  private func connect() {
    guard running, let url = URL(string: "wss://events.7tv.io/v3") else { return }
    let task = URLSession.shared.webSocketTask(with: url)
    socket = task
    lastHeard = Date()
    task.resume()
    let channel: [String: Any] = ["ctx": "channel", "platform": "TWITCH", "id": channelID]
    send(["op": 35, "d": ["type": "entitlement.create", "condition": channel]])
    let sets = subscribedSets
    subscribedSets = []
    // (The channel's own first: it's never left out.)
    if let set = SevenTVSets.set(for: channelID) { watch(set: set, essential: true) }
    for set in sets { watch(set: set) }
    receive(task)
  }

  private func send(_ object: [String: Any]) {
    guard let socket, let data = try? JSONSerialization.data(withJSONObject: object),
      let text = String(data: data, encoding: .utf8)
    else { return }
    socket.send(.string(text)) { _ in }
  }

  private func receive(_ task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
      Task { @MainActor in
        guard let self, self.socket === task else { return }
        switch result {
        case .failure:
          self.reconnectLater()
        case .success(let message):
          self.failures = 0
          self.lastHeard = Date()
          if case .string(let text) = message { self.handle(text) }
          self.receive(task)
        }
      }
    }
  }

  private func reconnectLater() {
    socket = nil
    // (Never given up on: after a long outage, once a minute. It stopped for good after eight
    // tries, and emote changes and personal emotes were plain words for the rest of the stream.)
    guard running else { return }
    failures += 1
    let wait = min(60, 2 * pow(2, Double(min(failures, 6) - 1)))
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
      MainActor.assumeIsolated { self?.connect() }
    }
  }

  private func handle(_ text: String) {
    guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return }
    let message = JSONValue(object)
    switch message["op"].int {
    case 1:  // hello: how often it beats
      if let ms = message["d"]["heartbeat_interval"].int, ms > 0 { heartbeat = max(5, Double(ms) / 1000) }
    case 0:  // dispatch
      let body = message["d"]["body"]
      switch message["d"]["type"].string {
      case "entitlement.create":
        let entitled = body["object"]
        guard entitled["kind"].string == "EMOTE_SET", let set = entitled["ref_id"].string else { return }
        for connection in entitled["user"]["connections"].array where connection["platform"].string == "TWITCH" {
          if let user = connection["id"].string { onPersonalSet?(user, set) }
        }
      case "emote_set.update":
        guard let set = body["id"].string else { return }
        var added: [String: URL] = [:]
        var removed: [String] = []
        let pushed = body["pushed"].array.filter { $0["key"].string == "emotes" }.map { $0["value"] }
        added.merge(ThirdPartyEmotes.parse7TV(JSONValue(pushed.compactMap(\.raw)))) { _, new in new }
        for change in body["pulled"].array where change["key"].string == "emotes" {
          if let name = change["old_value"]["name"].string { removed.append(name) }
        }
        for change in body["updated"].array where change["key"].string == "emotes" {
          if let name = change["old_value"]["name"].string { removed.append(name) }
          added.merge(ThirdPartyEmotes.parse7TV(JSONValue([change["value"].raw].compactMap { $0 }))) { _, new in new }
        }
        if !added.isEmpty || !removed.isEmpty { onSetChanged?(set, added, removed) }
      default:
        break
      }
    case 4:  // reconnect asked
      socket?.cancel(with: .goingAway, reason: nil)
      socket = nil
      connect()
    default:
      break
    }
  }
}
