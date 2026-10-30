// Recording channels by themselves when they go live, while Kestrel isn't being used (in the
// background, the phone locked), so there's a recording to catch up on even when the channel
// keeps no VOD.
//
// iOS only keeps an app running in the background while it plays sound, and wakes a closed app
// only now and then (Background App Refresh: a few times an hour at best, for seconds). So while a
// channel is scheduled (or a recording is being made), Kestrel keeps itself running by playing
// silence, mixed in with whatever else is playing. Apple doesn't allow that in App Store apps; it
// works in an app you install yourself, and costs some battery. Background App Refresh is the
// backup: if iOS stopped Kestrel anyway, a refresh that finds a scheduled channel live starts the
// recording and tries to keep running from there.

import AVFoundation
import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// A channel to record whenever it goes live.
struct AutoRecordRule: Codable, Identifiable, Equatable, Sendable {
  /// The channel's id.
  var id: String
  var login: String
  var displayName: String
  var profileImageURL: String?
  /// The highest rendition to record (lines); nil for the best.
  var maxHeight: Int?

  var channel: Channel { Channel(id: id, login: login, displayName: displayName, profileImageURL: profileImageURL) }
  var name: String { displayName.isEmpty ? login : displayName }
  var qualityLabel: String { maxHeight.map { "\($0)p" } ?? "best quality" }
}

@MainActor
final class AutoRecorder: ObservableObject {
  static let shared = AutoRecorder()
  /// Listed in Info.plist (BGTaskSchedulerPermittedIdentifiers).
  nonisolated static let taskID = "kestrel.auto-record"
  /// How often scheduled channels are checked while Kestrel runs.
  static let interval: TimeInterval = 45

  @Published private(set) var rules: [AutoRecordRule]
  /// Keep Kestrel running in the background (silently) so scheduled recordings start, and
  /// recordings carry on, with the phone locked.
  @Published var runInBackground: Bool {
    didSet {
      defaults.set(runInBackground, forKey: "autoRecord.background")
      updateKeepAlive()
    }
  }
  @Published private(set) var lastCheck: Date?

  private let defaults = UserDefaults.standard
  private var timer: Timer?
  private var checking = false

  private init() {
    if let data = defaults.data(forKey: "autoRecord.rules"), let saved = try? JSONDecoder().decode([AutoRecordRule].self, from: data) {
      rules = saved
    } else {
      rules = []
    }
    runInBackground = defaults.object(forKey: "autoRecord.background") as? Bool ?? true
  }

  // MARK: Rules

  func rule(for login: String) -> AutoRecordRule? {
    let login = login.lowercased()
    return rules.first { $0.login == login }
  }

  /// Records this channel whenever it goes live.
  func schedule(_ channel: Channel, maxHeight: Int?) {
    guard !channel.login.isEmpty else { return }
    let rule = AutoRecordRule(
      id: channel.id, login: channel.login.lowercased(), displayName: channel.displayName,
      profileImageURL: channel.profileImageURL, maxHeight: maxHeight)
    if let index = rules.firstIndex(where: { $0.login == rule.login }) {
      rules[index] = rule
    } else {
      rules.append(rule)
    }
    save()
    ActivityLog.shared.add("Recording \(rule.name) whenever they go live (\(rule.qualityLabel))")
    Task {
      // Notifications say when a recording starts and ends.
      let center = UNUserNotificationCenter.current()
      if await center.notificationSettings().authorizationStatus == .notDetermined {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
      }
    }
    startWatching()
    Task { await checkNow() }
  }

  func unschedule(_ login: String) {
    let login = login.lowercased()
    rules.removeAll { $0.login == login }
    save()
    if rules.isEmpty {
      timer?.invalidate()
      timer = nil
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
    }
    updateKeepAlive()
  }

  private func save() {
    if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "autoRecord.rules") }
  }

  // MARK: Running

  func appBecameActive() {
    BackgroundKeepAlive.shared.stop()
    startWatching()
    if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval - 5 { return }
    Task { await checkNow() }
  }

  func appEnteredBackground() {
    updateKeepAlive()
    scheduleBackgroundCheck()
  }

  /// Whether Kestrel keeps itself running in the background right now.
  private var wantsKeepAlive: Bool { runInBackground && (!rules.isEmpty || RecordingStore.shared.hasActive) }

  /// Starts or stops running in the background, as needed (only matters in the background).
  func updateKeepAlive() {
    guard UIApplication.shared.applicationState == .background else { return }
    if wantsKeepAlive {
      if BackgroundKeepAlive.shared.start() { startWatching() }
    } else {
      BackgroundKeepAlive.shared.stop()
    }
  }

  private func startWatching() {
    guard !rules.isEmpty, timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
      Task { @MainActor in await AutoRecorder.shared.checkNow() }
    }
    timer?.tolerance = 10
  }

  /// Checks the scheduled channels and starts recording any that are live.
  func checkNow() async {
    guard !rules.isEmpty, !checking else { return }
    checking = true
    defer { checking = false }
    lastCheck = Date()
    for rule in rules {
      guard let page = try? await TwitchAPI.shared.channelPage(login: rule.login), let stream = page.stream else { continue }
      startIfNeeded(rule, channel: page.channel, stream: stream)
    }
  }

  private func startIfNeeded(_ rule: AutoRecordRule, channel: Channel, stream: LiveStream) {
    let store = RecordingStore.shared
    // Already recording, or stopped by hand for this broadcast (not started again).
    guard !store.isRecording(rule.login), !store.wasStoppedByUser(streamID: stream.id) else { return }
    guard let id = store.start(channel: channel, stream: stream, maxHeight: rule.maxHeight, streamID: stream.id, automatic: true)
    else { return }
    updateKeepAlive()
    let content = UNMutableNotificationContent()
    content.title = "Recording \(channel.name)"
    content.body = stream.title.isEmpty ? "They just went live." : "Live: \(stream.title)"
    if UIApplication.shared.applicationState == .background, !BackgroundKeepAlive.shared.running {
      content.body += " Open Kestrel to keep recording."
    }
    content.sound = .default
    content.threadIdentifier = "recordings"
    content.userInfo = ["recordingID": id]
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "rec-start-\(id)", content: content, trigger: nil))
  }

  // MARK: Background App Refresh (Kestrel stopped)

  nonisolated static func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
      guard let task = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      let work = Task { @MainActor in
        AutoRecorder.shared.scheduleBackgroundCheck()
        await AutoRecorder.shared.checkNow()
        AutoRecorder.shared.updateKeepAlive()
        task.setTaskCompleted(success: true)
      }
      task.expirationHandler = {
        work.cancel()
        task.setTaskCompleted(success: false)
      }
    }
  }

  func scheduleBackgroundCheck() {
    guard !rules.isEmpty else { return }
    let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }
}

/// Keeps Kestrel running in the background by playing silence (see the top of this file).
@MainActor
final class BackgroundKeepAlive {
  static let shared = BackgroundKeepAlive()
  private var player: AVAudioPlayer?
  private var observers: [NSObjectProtocol] = []
  private(set) var running = false

  /// - Returns: whether it's running.
  @discardableResult
  func start() -> Bool {
    if running { return true }
    let session = AVAudioSession.sharedInstance()
    do {
      if AppModel.shared.playing == nil {
        // Alongside whatever else plays: music isn't interrupted, and Kestrel doesn't take over
        // the lock screen's controls.
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      }
      try session.setActive(true)
      let player = try AVAudioPlayer(data: Self.silence)
      player.numberOfLoops = -1
      player.volume = 0.01
      guard player.play() else { return false }
      self.player = player
      running = true
      observe()
      ActivityLog.shared.add("Running in the background for recordings")
      return true
    } catch {
      ActivityLog.shared.add("Couldn't keep running in the background (\(error.localizedDescription))")
      return false
    }
  }

  func stop() {
    guard running else { return }
    player?.stop()
    player = nil
    running = false
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    if AppModel.shared.playing == nil {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }
  }

  /// Picks up again after a phone call or another app's audio took over.
  private func observe() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .ended
        else { return }
        Task { @MainActor in self?.resume() }
      })
    observers.append(
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in
          guard let keepAlive = self, keepAlive.running else { return }
          keepAlive.running = false
          keepAlive.player = nil
          keepAlive.start()
        }
      })
  }

  private func resume() {
    guard running else { return }
    try? AVAudioSession.sharedInstance().setActive(true)
    player?.play()
  }

  /// A second of silence (16-bit mono PCM WAV).
  private static let silence: Data = {
    let rate: UInt32 = 8000
    let samples = Data(count: Int(rate) * 2)
    var data = Data()
    func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
    func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    append("RIFF")
    append32(UInt32(36 + samples.count))
    append("WAVE")
    append("fmt ")
    append32(16)
    append16(1)  // PCM
    append16(1)  // mono
    append32(rate)
    append32(rate * 2)  // bytes per second
    append16(2)  // bytes per frame
    append16(16)  // bits per sample
    append("data")
    append32(UInt32(samples.count))
    data.append(samples)
    return data
  }()
}
