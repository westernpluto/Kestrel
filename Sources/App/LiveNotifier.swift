// Go-live alerts for the channels you follow. A sideloaded app has no push server, so Kestrel
// checks by itself: every minute while it's open or playing in the background, and when it's
// closed, whenever iOS lets it refresh in the background (iOS decides how often). New streams
// become notifications on the iPhone; tapping one opens the stream.

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

  private let defaults = UserDefaults.standard
  /// Channels seen live in the last complete check.
  private var knownLive: Set<String>
  /// Broadcasts already announced (never twice for the same stream), with when.
  private var announced: [String: Date]
  private var seeded: Bool
  private var timer: Timer?
  private var lastCheck = Date.distantPast

  private override init() {
    enabled = defaults.bool(forKey: "liveAlerts.enabled")
    knownLive = Set(defaults.stringArray(forKey: "liveAlerts.known") ?? [])
    announced = (defaults.dictionary(forKey: "liveAlerts.announced") as? [String: Date]) ?? [:]
    seeded = defaults.bool(forKey: "liveAlerts.seeded")
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
    } else {
      enabled = false
      defaults.set(false, forKey: "liveAlerts.enabled")
      timer?.invalidate()
      timer = nil
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
      ActivityLog.shared.add("Go-live alerts off")
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
    let ids = Set(live.map(\.channel.id))
    announced = announced.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
    if seeded {
      let watching = AppModel.shared.playing
      for stream in live where !knownLive.contains(stream.channel.id) && announced[stream.id] == nil {
        if case .live(let channel)? = watching, channel.id == stream.channel.id { continue }
        // Started a while ago (seen late, e.g. after the phone was off): still worth a heads-up,
        // but not for streams that have been on for hours.
        if let started = stream.startedAt, now.timeIntervalSince(started) > 3 * 3600 { continue }
        announced[stream.id] = now
        post(stream)
      }
    } else {
      seeded = true
      defaults.set(true, forKey: "liveAlerts.seeded")
      for stream in live { announced[stream.id] = now }
    }
    knownLive = ids
    defaults.set(Array(knownLive), forKey: "liveAlerts.known")
    defaults.set(announced, forKey: "liveAlerts.announced")
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
    if info["recordingID"] is String {
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
