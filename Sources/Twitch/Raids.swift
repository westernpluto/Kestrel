// Raids: when the channel you're watching raids another one, Twitch's website shows a countdown
// ("Raiding <channel>") and then moves you to the raided channel. It learns about this from the
// `raid.<channel id>` topic on Hermes, the live-event socket twitch.tv uses since PubSub was shut
// down (wss://hermes.twitch.tv/v1). The topic needs no sign-in.
//
// Messages (JSON):
//   server: {"type":"welcome","welcome":{"keepaliveSec":10,...}}
//   client: {"type":"subscribe","id":"…","subscribe":{"id":"…","type":"pubsub","pubsub":{"topic":"raid.123"}},"timestamp":"…"}
//   server: {"type":"subscribeResponse","subscribeResponse":{"result":"ok",...}}
//   server: {"type":"keepalive"}
//   server: {"type":"notification","notification":{"subscription":{"id":"…"},"type":"pubsub",
//            "pubsub":"{\"type\":\"raid_update_v2\",\"raid\":{\"target_login\":\"…\",…}}"}}
//   server: {"type":"reconnect","reconnect":{"url":"wss://…"}}
//
// The raid payload is the one PubSub used to carry: raid_update_v2 (countdown running),
// raid_go_v2 (raid happening now) and raid_cancel_v2.

import Foundation

struct RaidEvent: Equatable, Sendable {
  enum Kind: String, Sendable {
    case update = "raid_update_v2"
    case go = "raid_go_v2"
    case cancel = "raid_cancel_v2"
  }

  var kind: Kind
  var raidID: String
  var sourceID: String
  var targetID: String
  var targetLogin: String
  var targetDisplayName: String
  var targetProfileImage: String?
  var viewerCount: Int
  /// Seconds until the raid happens by itself (Twitch raids after 90 s unless the streamer goes
  /// sooner), when Twitch says.
  var forceRaidNowSeconds: Int?

  var target: Channel {
    Channel(id: targetID, login: targetLogin, displayName: targetDisplayName, profileImageURL: targetProfileImage)
  }

  /// A raid payload (`{"type":"raid_go_v2","raid":{…}}`).
  static func parse(payload: JSONValue) -> RaidEvent? {
    guard let type = payload["type"].string, let kind = Kind(rawValue: type) else { return nil }
    let raid = payload["raid"]
    guard let login = raid["target_login"].string, !login.isEmpty else { return nil }
    return RaidEvent(
      kind: kind, raidID: raid["id"].string ?? "", sourceID: raid["source_id"].string ?? "",
      targetID: raid["target_id"].string ?? "", targetLogin: login,
      targetDisplayName: raid["target_display_name"].string ?? login,
      targetProfileImage: raid["target_profile_image"].string.flatMap { $0.isEmpty ? nil : $0 },
      viewerCount: raid["viewer_count"].int ?? 0, forceRaidNowSeconds: raid["force_raid_now_seconds"].int)
  }
}

enum Hermes {
  static let url = URL(string: "wss://hermes.twitch.tv/v1?clientId=\(TwitchAPI.webClientID)")!

  enum Message: Equatable {
    case welcome(keepalive: TimeInterval)
    case keepalive
    case subscribed(ok: Bool)
    case reconnect(URL?)
    case raid(RaidEvent)
    case other
  }

  static func subscribe(topic: String, id: String = UUID().uuidString, subscriptionID: String = UUID().uuidString) -> String {
    let body: [String: Any] = [
      "type": "subscribe", "id": id,
      "subscribe": ["id": subscriptionID, "type": "pubsub", "pubsub": ["topic": topic]] as [String: Any],
      "timestamp": HLSDate.format(Date()),
    ]
    let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
  }

  static func raidTopic(channelID: String) -> String { "raid.\(channelID)" }

  static func parse(_ text: String) -> Message {
    guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return .other }
    let json = JSONValue(object)
    switch json["type"].string {
    case "welcome":
      return .welcome(keepalive: TimeInterval(json["welcome"]["keepaliveSec"].int ?? 10))
    case "keepalive":
      return .keepalive
    case "subscribeResponse":
      return .subscribed(ok: (json["subscribeResponse"]["result"].string ?? "ok").lowercased() == "ok")
    case "reconnect":
      return .reconnect(json["reconnect"]["url"].string.flatMap(URL.init(string:)))
    case "notification":
      let inner = json["notification"]["pubsub"]
      var payload = inner
      // Usually a JSON string inside the JSON; accept an object too.
      if let string = inner.string, let innerData = string.data(using: .utf8),
        let innerObject = try? JSONSerialization.jsonObject(with: innerData)
      {
        payload = JSONValue(innerObject)
      }
      if let event = RaidEvent.parse(payload: payload) { return .raid(event) }
      return .other
    default:
      return .other
    }
  }
}
