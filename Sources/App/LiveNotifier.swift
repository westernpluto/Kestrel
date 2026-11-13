// Go-live alerts for the channels you follow. A sideloaded app has no push server, so Kestrel
// checks by itself, every minute while it runs. iOS pauses an app soon after it leaves the
// screen, so Keep checking in the background keeps Kestrel running (silently, see
// BackgroundKeepAlive) and the checks going with the phone locked; without it, iOS only lets it
// check now and then (Background App Refresh). New streams become notifications; tapping one
// opens the stream. (Instant alerts through ntfy work even with Kestrel closed: InstantAlerts.)
//
// While Kestrel runs, alerts don't wait for the minute's check: Twitch's live-event socket (the one
// twitch.tv uses) says "stream-up" for a followed channel the moment its broadcast starts (see
// LiveWatch), and the alert goes then. Through the follows list alone it came a minute or two
// after (Twitch lists a stream a while after it starts), and at a check every minute.

import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

@MainActor
final class LiveNotifier: NSObject, ObservableObject {
  static let shared = LiveNotifier()
  /// Listed in Info.plist (BGTaskSchedulerPermittedIdentifiers).
  nonisolated static let taskID = "kestrel.live-check"

  @Published private(set) var enabled: Bool
  @Published private(set) var permission: UNAuthorizationStatus = .notDetermined
  /// Keep Kestrel running in the background so the checks carry on every minute (see the top).
  @Published var backgroundChecks: Bool {
    didSet {
      defaults.set(backgroundChecks, forKey: "liveAlerts.background")
      AutoRecorder.shared.updateKeepAlive()
    }
  }

  /// Kestrel should stay running in the background for these alerts.
  var keepsRunning: Bool { enabled && backgroundChecks }

  private let defaults = UserDefaults.standard
  /// Channels seen live in the last complete check.
  private var knownLive: Set<String>
  /// Broadcasts already announced (never twice for the same stream), with when.
  private var announced: [String: Date]
  private var seeded: Bool
  private var timer: Timer?
  private var lastCheck = Date.distantPast
  /// The live-event sockets for followed channels, and the channels they watch.
  private var events: [LiveWatch] = []
  private var eventChannels: [String] = []
  /// Channels announced from a live event, with when (the follows list's check doesn't announce
  /// the same broadcast again).
  private var upAnnounced: [String: Date]
  /// The most channels watched for live events (four sockets).
  static let mostWatched = 200
  /// The last complete look at who's live (to tell a catch-up after a pause from a regular check).
  private var lastObserved: Date

  private override init() {
    enabled = defaults.bool(forKey: "liveAlerts.enabled")
    backgroundChecks = defaults.object(forKey: "liveAlerts.background") as? Bool ?? true
    lastObserved = defaults.object(forKey: "liveAlerts.lastObserved") as? Date ?? .distantPast
    knownLive = Set(defaults.stringArray(forKey: "liveAlerts.known") ?? [])
    announced = (defaults.dictionary(forKey: "liveAlerts.announced") as? [String: Date]) ?? [:]
    seeded = defaults.bool(forKey: "liveAlerts.seeded")
    upAnnounced = (defaults.dictionary(forKey: "liveAlerts.upAnnounced") as? [String: Date]) ?? [:]
    super.init()
  }

  // MARK: Setup

  /// At launch (before it finishes): background checks and notification taps.
  nonisolated static func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
      guard let task = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      LiveNotifier.handle(task)
    }
    Task { @MainActor in
      UNUserNotificationCenter.current().delegate = LiveNotifier.shared
      await LiveNotifier.shared.refreshPermission()
    }
  }

  func setEnabled(_ on: Bool) async {
    if on {
      let center = UNUserNotificationCenter.current()
      let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
      await refreshPermission()
      guard granted else {
        enabled = false
        defaults.set(false, forKey: "liveAlerts.enabled")
        return
      }
      enabled = true
      defaults.set(true, forKey: "liveAlerts.enabled")
      // Whoever's live right now isn't news: only streams that start from here on are announced.
      seeded = false
      defaults.set(false, forKey: "liveAlerts.seeded")
      ActivityLog.shared.add("Go-live alerts on")
      startPolling()
      await FollowingStore.shared.refresh(force: true)
      scheduleBackgroundCheck()
      AutoRecorder.shared.updateKeepAlive()
    } else {
      enabled = false
      defaults.set(false, forKey: "liveAlerts.enabled")
      timer?.invalidate()
      timer = nil
      watchLiveEvents([])
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
      ActivityLog.shared.add("Go-live alerts off")
      AutoRecorder.shared.updateKeepAlive()
    }
  }

  func refreshPermission() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    permission = settings.authorizationStatus
  }

  // MARK: Checking

  /// While the app runs (in the foreground, or playing in the background): a check a minute.
  func startPolling() {
    guard enabled, timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
      Task { @MainActor in await LiveNotifier.shared.checkNow() }
    }
    timer?.tolerance = 10
  }

  func appBecameActive() {
    guard enabled else { return }
    startPolling()
    if Date().timeIntervalSince(lastCheck) > 50 { Task { await checkNow() } }
  }

  func appEnteredBackground() {
    guard enabled else { return }
    scheduleBackgroundCheck()
  }

  func checkNow() async {
    guard enabled else { return }
    lastCheck = Date()
    // The follows list does the fetching; it reports back to `observe`.
    await FollowingStore.shared.refresh(force: true)
  }

  /// Every refresh of the follows list ends here. `complete`: the list loaded without errors (a
  /// failed request must not look like everyone went offline and came back).
  func observe(live: [LiveStream], complete: Bool) {
    guard enabled, complete else { return }
    let now = Date()
    let gap = now.timeIntervalSince(lastObserved)
    lastObserved = now
    defaults.set(now, forKey: "liveAlerts.lastObserved")
    let ids = Set(live.map(\.channel.id))
    announced = announced.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
    if seeded {
      let watching = AppModel.shared.playing
      var fresh: [LiveStream] = []
      for stream in live where !knownLive.contains(stream.channel.id) && announced[stream.id] == nil {
        if case .live(let channel)? = watching, channel.id == stream.channel.id { continue }
        // Announced already, the moment it started (a live event): not again.
        if let up = upAnnounced[stream.channel.id],
          stream.startedAt.map({ abs($0.timeIntervalSince(up)) < 600 }) ?? (now.timeIntervalSince(up) < 3600)
        {
          announced[stream.id] = now
          continue
        }
        // Started a while ago (seen late, e.g. after the phone was off): still worth a heads-up,
        // but not for streams that have been on for hours.
        if let started = stream.startedAt, now.timeIntervalSince(started) > 3 * 3600 { continue }
        announced[stream.id] = now
        fresh.append(stream)
      }
      if UIApplication.shared.applicationState == .active, gap > 150 {
        // Catching up after Kestrel was paused, with Kestrel open in front of you: Following
        // shows who's live, and a pile of alerts at once would only be noise.
        if !fresh.isEmpty {
          ActivityLog.shared.add(
            "Went live while Kestrel was paused: \(fresh.map(\.channel.name).joined(separator: ", ")) (no alerts: it's open)")
        }
      } else if fresh.count >= 3 {
        // Several at once (iOS let Kestrel check after a while): one alert for all of them.
        postSummary(fresh)
      } else {
        fresh.forEach(post)
      }
    } else {
      seeded = true
      defaults.set(true, forKey: "liveAlerts.seeded")
      for stream in live { announced[stream.id] = now }
    }
    knownLive = ids
    defaults.set(Array(knownLive), forKey: "liveAlerts.known")
    defaults.set(announced, forKey: "liveAlerts.announced")
    // Watch who's offline for the moment they go live: the ones live most lately first.
    let offline = FollowingStore.shared.offline.sorted { ($0.lastLive ?? .distantPast) > ($1.lastLive ?? .distantPast) }
    watchLiveEvents(offline.prefix(Self.mostWatched).map(\.channel.id).filter { !ids.contains($0) })
  }

  // MARK: Live events

  /// Watches these channels for going live (sockets of up to 50 each), replacing what was watched.
  private func watchLiveEvents(_ channels: [String]) {
    guard channels != eventChannels else { return }
    events.forEach { $0.stop() }
    events = []
    eventChannels = channels
    guard enabled, !channels.isEmpty else { return }
    var start = 0
    while start < channels.count {
      let group = Array(channels[start..<min(start + LiveWatch.perSocket, channels.count)])
      let watch = LiveWatch(channelIDs: group) { id in
        LiveNotifier.shared.streamUp(channelID: id)
      }
      watch.start()
      events.append(watch)
      start += LiveWatch.perSocket
    }
  }

  /// A followed channel's broadcast just started: alerted now, not at the next check.
  private func streamUp(channelID id: String) {
    guard enabled, seeded, !knownLive.contains(id) else { return }
    let now = Date()
    // (A broadcaster whose connection dropped and came back isn't news.)
    if let up = upAnnounced[id], now.timeIntervalSince(up) < 30 * 60 { return }
    if case .live(let channel)? = AppModel.shared.playing, channel.id == id { return }
    guard let channel = FollowingStore.shared.offline.first(where: { $0.channel.id == id })?.channel else { return }
    upAnnounced = upAnnounced.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
    upAnnounced[id] = now
    defaults.set(upAnnounced, forKey: "liveAlerts.upAnnounced")
    ActivityLog.shared.add("\(channel.name) went live (Twitch's live events)")
    // (Its title and game come with the next look at the follows list; the alert goes now.)
    post(LiveStream(id: "up-\(id)-\(Int(now.timeIntervalSince1970))", title: "", viewers: 0, startedAt: now, channel: channel))
  }

  private func post(_ stream: LiveStream) {
    let content = UNMutableNotificationContent()
    content.title = "\(stream.channel.name) is live"
    var body = stream.title.isEmpty ? "Started streaming" : stream.title
    if let category = stream.category?.name, !category.isEmpty { body += "\n" + category }
    content.body = body
    content.sound = .default
    content.threadIdentifier = "live"
    content.userInfo = [
      "channelID": stream.channel.id, "login": stream.channel.login,
      "displayName": stream.channel.displayName, "avatar": stream.channel.profileImageURL ?? "",
    ]
    let id = "live-\(stream.id)"
    let avatar = TwitchAPI.image(stream.channel.profileImageURL, width: 150, height: 150)
    Task {
      if let avatar, let attachment = await Self.attachment(avatar, name: stream.channel.id) {
        content.attachments = [attachment]
      }
      try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    ActivityLog.shared.add("Go-live alert: \(stream.channel.name)")
  }

  private func postSummary(_ streams: [LiveStream]) {
    let names = streams.map(\.channel.name)
    let content = UNMutableNotificationContent()
    content.title = "\(streams.count) channels went live"
    content.body =
      names.count > 4
      ? names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
      : ListFormatter.localizedString(byJoining: names)
    content.sound = .default
    content.threadIdentifier = "live"
    content.userInfo = ["following": true]
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "live-summary-\(UUID().uuidString)", content: content, trigger: nil))
    ActivityLog.shared.add("Go-live alert: \(names.joined(separator: ", "))")
  }

  /// The streamer's picture on the notification (it has to be a file).
  private static func attachment(_ url: URL, name: String) async -> UNNotificationAttachment? {
    guard let (data, response) = try? await URLSessionHTTPClient(timeout: 4).data(for: URLRequest(url: url)),
      response.statusCode == 200, !data.isEmpty
    else { return nil }
    let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-\(name)-\(UUID().uuidString).\(ext)")
    guard (try? data.write(to: file)) != nil else { return nil }
    return try? UNNotificationAttachment(identifier: "avatar", url: file)
  }

  // MARK: Background refresh (the app closed)

  func scheduleBackgroundCheck() {
    guard enabled else { return }
    let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
    // The soonest iOS may run it; in practice it picks the time itself.
    request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      ActivityLog.shared.add("Couldn't schedule background checks for go-live alerts (\(error.localizedDescription))")
    }
  }

  nonisolated private static func handle(_ task: BGAppRefreshTask) {
    let work = Task { @MainActor in
      LiveNotifier.shared.scheduleBackgroundCheck()
      await LiveNotifier.shared.checkNow()
      // Give the notifications (and their pictures) a moment to be handed over.
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      task.setTaskCompleted(success: true)
    }
    task.expirationHandler = {
      work.cancel()
      task.setTaskCompleted(success: false)
    }
  }
}

extension LiveNotifier: UNUserNotificationCenterDelegate {
  /// Shown even while Kestrel is open.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  /// Tapped: open the stream.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    if info["following"] != nil {
      // Several channels went live: the Following list.
      DispatchQueue.main.async {
        let app = AppModel.shared
        app.playerMinimized = app.playing != nil
        app.tab = .following
        app.followingPath = []
      }
    } else if info["recordingID"] is String {
      // A recording started or finished: the recordings list.
      DispatchQueue.main.async {
        let app = AppModel.shared
        app.playerMinimized = app.playing != nil
        app.tab = .following
        app.push(.recordings)
      }
    } else if let id = info["channelID"] as? String, let login = info["login"] as? String {
      let avatar = (info["avatar"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      let channel = Channel(id: id, login: login, displayName: info["displayName"] as? String ?? login, profileImageURL: avatar)
      DispatchQueue.main.async { AppModel.shared.playing = .live(channel) }
    }
    completionHandler()
  }
}
