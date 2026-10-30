// Recordings of live streams (see StreamRecorder): starting and stopping them, the list in the
// Following tab, and playing them back.

import AVKit
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class RecordingStore: ObservableObject {
  static let shared = RecordingStore()

  /// Newest first.
  @Published private(set) var recordings: [RecordingInfo] = []
  /// Recordings being made, by id.
  @Published private(set) var active: [String: RecorderStatus.State] = [:]
  private var recorders: [String: StreamRecorder] = [:]
  let root: URL
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var tokens: [NSObjectProtocol] = []

  private init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    var root = base.appendingPathComponent("Recordings", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? root.setResourceValues(values)
    self.root = root
    StreamProxy.shared.serveRecordings(from: root)
    reload()
    let center = NotificationCenter.default
    tokens.append(
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        guard let store = self else { return }
        Task { @MainActor in store.enteredBackground() }
      })
    tokens.append(
      center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
        guard let store = self else { return }
        Task { @MainActor in store.endBackgroundTask() }
      })
  }

  /// Reads the recordings on disk (finishing any the app was closed in the middle of).
  func reload() {
    let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    var list: [RecordingInfo] = []
    for folder in folders {
      let id = folder.lastPathComponent
      if recorders[id] != nil, let current = recordings.first(where: { $0.id == id }) {
        list.append(current)
      } else if let info = StreamRecorder.finishInterrupted(in: folder) {
        list.append(info)
      }
    }
    recordings = list.sorted { $0.startedAt > $1.startedAt }
  }

  /// The recording being made of this channel, if any.
  func recording(of login: String) -> RecordingInfo? {
    let login = login.lowercased()
    return recordings.first { $0.login == login && active[$0.id] != nil }
  }

  func isRecording(_ login: String) -> Bool { recording(of: login) != nil }

  /// - Parameter maxHeight: the highest rendition to record (lines, e.g. 720); nil for the best.
  /// - Parameters:
  ///   - maxHeight: the highest rendition to record (lines, e.g. 720); nil for the best.
  ///   - streamID: the broadcast (so a recording stopped by hand isn't started again for it).
  ///   - automatic: started because the channel went live (see AutoRecorder).
  /// - Returns: the recording's id.
  @discardableResult
  func start(channel: Channel, stream: LiveStream?, maxHeight: Int?, streamID: String? = nil, automatic: Bool = false) -> String? {
    guard !channel.login.isEmpty, !isRecording(channel.login) else { return nil }
    let login = channel.login.lowercased()
    let id = "\(login)-\(Int(Date().timeIntervalSince1970))"
    let info = RecordingInfo(
      id: id, login: login, channelName: channel.name, channelID: channel.id, profileImageURL: channel.profileImageURL,
      title: stream?.title, category: stream?.category?.name, quality: "", startedAt: Date(), endedAt: nil, duration: 0,
      bytes: 0, gaps: 0, endReason: nil, streamID: streamID ?? stream?.id, automatic: automatic)
    let settings = AppSettings.shared
    var config = LowLatencyConfig()
    config.adFreeProxies = settings.adFreeProxyHosts
    config.checkAccountFirst = TwitchAuth.shared.session != nil
    config.nearbyServers = settings.nearbyServers
    let recorder = StreamRecorder(
      info: info, directory: root.appendingPathComponent(id, isDirectory: true), maxHeight: maxHeight, config: config,
      http: settings.playbackClient(timeout: 20), tokens: TwitchAPI.shared
    ) { [weak self] status in
      Task { @MainActor in self?.update(status) }
    }
    recorders[id] = recorder
    active[id] = .starting
    recordings.insert(info, at: 0)
    keepAwake()
    Task { await recorder.start() }
    return id
  }

  /// Stopped by hand.
  func stop(_ id: String) {
    guard let recorder = recorders[id] else { return }
    Task { await recorder.stop(byUser: true) }
  }

  var hasActive: Bool { !active.isEmpty }

  /// A recording of that broadcast was stopped by hand (so it isn't started again by itself).
  func wasStoppedByUser(streamID: String) -> Bool {
    recordings.contains { $0.streamID == streamID && $0.stoppedByUser == true }
  }

  func delete(_ info: RecordingInfo) {
    if let recorder = recorders.removeValue(forKey: info.id) { Task { await recorder.stop() } }
    active[info.id] = nil
    recordings.removeAll { $0.id == info.id }
    try? FileManager.default.removeItem(at: root.appendingPathComponent(info.id, isDirectory: true))
    keepAwake()
  }

  var totalBytes: Int64 { recordings.reduce(0) { $0 + $1.bytes } }

  func playbackURL(_ info: RecordingInfo) -> URL? { try? StreamProxy.shared.recordingURL(id: info.id) }

  private func update(_ status: RecorderStatus) {
    if let index = recordings.firstIndex(where: { $0.id == status.info.id }) { recordings[index] = status.info }
    if status.state == .ended {
      let wasActive = active[status.info.id] != nil
      active[status.info.id] = nil
      recorders[status.info.id] = nil
      if wasActive, status.info.automatic == true, status.info.duration > 0 { notifyFinished(status.info) }
      // Nothing left to keep running for in the background.
      AutoRecorder.shared.updateKeepAlive()
    } else if active[status.info.id] != status.state {
      active[status.info.id] = status.state
    }
    keepAwake()
  }

  private func notifyFinished(_ info: RecordingInfo) {
    let content = UNMutableNotificationContent()
    content.title = "Recorded \(info.channelName)"
    content.body = "\(Format.duration(Int(info.duration))) saved (\(info.endReason?.lowercased() ?? "ended")). Tap to watch."
    content.threadIdentifier = "recordings"
    content.userInfo = ["recordingID": info.id]
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "rec-end-\(info.id)", content: content, trigger: nil))
  }

  /// While recording, the screen stays on in the foreground, so a phone left open on a stand
  /// keeps recording.
  private func keepAwake() {
    let awake = !active.isEmpty
    if UIApplication.shared.isIdleTimerDisabled != awake { UIApplication.shared.isIdleTimerDisabled = awake }
    if !awake { endBackgroundTask() }
  }

  /// iOS keeps an app going in the background only while it plays sound (Picture in Picture, or
  /// background audio). Otherwise it gives a little time, then pauses Kestrel, and the recording
  /// with it until Kestrel is opened again: say so.
  private func enteredBackground() {
    // Running in the background silently (see AutoRecorder) keeps the recording going.
    AutoRecorder.shared.updateKeepAlive()
    guard !active.isEmpty, !BackgroundKeepAlive.shared.running, backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Recording") { [weak self] in
      guard let store = self else { return }
      Task { @MainActor in
        // With a stream playing, its sound keeps Kestrel going; otherwise it's about to pause.
        if AppModel.shared.playing == nil, !BackgroundKeepAlive.shared.running { store.notifyPaused() }
        store.endBackgroundTask()
      }
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  private func notifyPaused() {
    guard !active.isEmpty else { return }
    let content = UNMutableNotificationContent()
    content.title = "Recording paused"
    content.body = "iOS pauses Kestrel in the background unless a stream is playing (or Run in the background is on, under Recordings). Open Kestrel to carry on recording."
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "recording-paused", content: content, trigger: nil))
  }
}

/// On a channel's page: record them whenever they go live (see AutoRecorder).
struct AutoRecordButton: View {
  let channel: Channel
  var font: Font = .title2
  @ObservedObject private var auto = AutoRecorder.shared

  static let heights = [1080, 720, 480, 360]

  var body: some View {
    let rule = auto.rule(for: channel.login)
    Menu {
      if let rule {
        Text("Recording whenever they go live (\(rule.qualityLabel))")
        Button(role: .destructive) {
          auto.unschedule(channel.login)
        } label: {
          Label("Stop recording when live", systemImage: "record.circle")
        }
      } else {
        Section("Record whenever they go live, even with Kestrel closed") {
          ForEach(Self.heights, id: \.self) { height in
            Button("\(height)p · \(RecordQuality.sizePerHour("\(height)p"))") { auto.schedule(channel, maxHeight: height) }
          }
        }
      }
    } label: {
      Image(systemName: rule == nil ? "record.circle" : "record.circle.fill")
        .font(font)
        .foregroundColor(rule == nil ? .primary : .liveRed)
        .frame(minWidth: 36, minHeight: 36)
        .contentShape(Rectangle())
    }
    .accessibilityLabel(rule == nil ? "Record when live" : "Recording when live")
  }
}

// MARK: - List

struct RecordingsView: View {
  @ObservedObject private var store = RecordingStore.shared
  @ObservedObject private var auto = AutoRecorder.shared
  @EnvironmentObject private var app: AppModel
  @State private var playing: RecordingInfo? = nil

  var body: some View {
    List {
      Section {
        if auto.rules.isEmpty {
          Text("Tap ⏺ on a channel's page, or Record in the player's gear menu, to record a channel whenever it goes live.")
            .font(.subheadline).foregroundColor(.secondary)
        }
        ForEach(auto.rules) { rule in
          HStack(spacing: 12) {
            Avatar(url: rule.profileImageURL, size: 36)
            VStack(alignment: .leading, spacing: 2) {
              Text(rule.name).font(.headline)
              Text(store.isRecording(rule.login) ? "Live: recording now" : "Whenever they go live · \(rule.qualityLabel)")
                .font(.caption).foregroundColor(store.isRecording(rule.login) ? .liveRed : .secondary)
            }
          }
          .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
              auto.unschedule(rule.login)
            } label: {
              Label("Remove", systemImage: "trash")
            }
          }
        }
        Toggle("Run in the background", isOn: $auto.runInBackground)
      } header: {
        Text("Record when live")
      } footer: {
        Text(
          "Kestrel checks these channels about every minute and starts recording as soon as one goes live, then lets you know (and again when it's done). To do that with the phone locked and Kestrel closed, Run in the background keeps it running by playing silence, mixed in with your other audio; Apple allows that only for apps you install yourself, not App Store apps. It uses some battery while channels are scheduled, and data while recording. If Kestrel is swiped away or the phone restarts, it can't record until it's opened again (iOS may still check now and then and pick it up)."
        )
      }

      Section {
        if store.recordings.isEmpty {
          Text("No recordings yet. Record a live stream from the player's gear menu, or schedule a channel above.")
            .font(.subheadline).foregroundColor(.secondary)
        }
        ForEach(store.recordings) { info in
          Button {
            play(info)
          } label: {
            RecordingRow(info: info, state: store.active[info.id])
          }
          .buttonStyle(.plain)
          .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
              store.delete(info)
            } label: {
              Label("Delete", systemImage: "trash")
            }
            if store.active[info.id] != nil {
              Button {
                store.stop(info.id)
              } label: {
                Label("Stop", systemImage: "stop.fill")
              }
              .tint(.orange)
            }
          }
        }
      } header: {
        Text("Recordings")
      } footer: {
        if !store.recordings.isEmpty {
          Text(
            "\(Self.size(store.totalBytes)) on this iPhone. Tap one to watch from the start (or where you left off), even while it's still recording. Swipe left to stop or delete."
          )
        }
      }
      MiniPlayerSpacer()
    }
    .navigationTitle("Recordings")
    .onAppear { store.reload() }
    .fullScreenCover(item: $playing) { info in
      RecordingPlayerScreen(info: info, url: store.playbackURL(info), recording: store.active[info.id] != nil)
    }
  }

  private func play(_ info: RecordingInfo) {
    guard info.duration > 0 else { return }
    // One thing playing at a time (a recording being made carries on).
    if app.playing != nil { app.playing = nil }
    playing = info
  }

  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

struct RecordingRow: View {
  let info: RecordingInfo
  let state: RecorderStatus.State?

  var body: some View {
    HStack(spacing: 12) {
      Avatar(url: info.profileImageURL, size: 44)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(info.channelName).font(.headline).lineLimit(1)
          if let state { badge(state) }
        }
        if let title = info.title, !title.isEmpty {
          Text(title).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
        }
        Text(details).font(.caption.monospacedDigit()).foregroundColor(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      if info.duration > 0 {
        Image(systemName: "play.circle.fill").font(.title2).foregroundColor(.accentTeal)
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private var details: String {
    var parts = [Format.relative(info.startedAt), Format.duration(Int(info.duration))]
    if info.bytes > 0 { parts.append(RecordingsView.size(info.bytes)) }
    if !info.quality.isEmpty { parts.append(info.quality) }
    if info.gaps > 0 { parts.append(info.gaps == 1 ? "1 jump" : "\(info.gaps) jumps") }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private func badge(_ state: RecorderStatus.State) -> some View {
    switch state {
    case .recording, .starting:
      Label("REC", systemImage: "record.circle.fill")
        .font(.caption2.weight(.heavy)).foregroundColor(.liveRed).labelStyle(.titleAndIcon)
    case .reconnecting:
      Text("Reconnecting…").font(.caption2.weight(.semibold)).foregroundColor(.orange)
    case .ended:
      EmptyView()
    }
  }
}

// MARK: - Playback

/// Plays a recording with the system player (seek bar, skips, Picture in Picture), picking up
/// where it was left, or from the start.
struct RecordingPlayerScreen: View {
  let info: RecordingInfo
  let url: URL?
  let recording: Bool
  @Environment(\.dismiss) private var dismiss
  @StateObject private var playback = RecordingPlayback()

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(info.channelName).font(.headline)
            if recording {
              Label("REC", systemImage: "record.circle.fill").font(.caption2.weight(.heavy)).foregroundColor(.liveRed)
            }
          }
          if let title = info.title, !title.isEmpty {
            Text(title).font(.footnote).foregroundColor(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        if recording {
          // Caught up: on to the stream itself.
          Button {
            let channel = Channel(
              id: info.channelID ?? "", login: info.login, displayName: info.channelName, profileImageURL: info.profileImageURL)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { AppModel.shared.playing = .live(channel) }
          } label: {
            Text("Watch live").font(.subheadline.weight(.semibold))
              .padding(.horizontal, 12).padding(.vertical, 7)
              .background(Color.liveRed, in: Capsule())
          }
          .accessibilityHint("Closes the recording and opens the live stream")
        }
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Close")
      }
      .padding(.horizontal, 12)
      .foregroundColor(.white)
      SystemVideoPlayer(player: playback.player)
    }
    .background(Color.black.ignoresSafeArea())
    .preferredColorScheme(.dark)
    .onAppear { if let url { playback.start(url: url, id: info.id) } }
    .onDisappear { playback.finish() }
  }
}

final class RecordingPlayback: ObservableObject {
  let player = AVPlayer()
  private var id = ""
  private var statusObservation: NSKeyValueObservation?
  private var timeObserver: Any?

  private static func positionKey(_ id: String) -> String { "kestrel.recordingPosition.\(id)" }

  func start(url: URL, id: String) {
    self.id = id
    let item = AVPlayerItem(url: url)
    let resume = UserDefaults.standard.double(forKey: Self.positionKey(id))
    statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard item.status == .readyToPlay else { return }
      DispatchQueue.main.async {
        guard let playback = self, playback.statusObservation != nil else { return }
        playback.statusObservation = nil
        // Where it was left, or the start (a recording still being made would otherwise start at
        // its end, like a live stream).
        playback.player.seek(to: CMTime(seconds: resume > 5 ? resume - 3 : 0, preferredTimescale: 600)) { _ in
          playback.player.play()
        }
      }
    }
    player.replaceCurrentItem(with: item)
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) {
      [weak self] time in
      guard let playback = self, time.seconds.isFinite, time.seconds > 0 else { return }
      UserDefaults.standard.set(time.seconds, forKey: Self.positionKey(playback.id))
    }
  }

  func finish() {
    let seconds = player.currentTime().seconds
    if seconds.isFinite, seconds > 0 { UserDefaults.standard.set(seconds, forKey: Self.positionKey(id)) }
    player.pause()
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    statusObservation = nil
  }
}

/// The system's player controls around an AVPlayer.
struct SystemVideoPlayer: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.allowsPictureInPicturePlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.view.backgroundColor = .black
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player { controller.player = player }
  }
}
