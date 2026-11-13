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
  /// Recordings being made (and VODs downloading), by id.
  @Published private(set) var active: [String: RecorderStatus.State] = [:]
  /// VODs downloading: how far along (0…1), by id.
  @Published private(set) var downloadProgress: [String: Double] = [:]
  private var recorders: [String: StreamRecorder] = [:]
  private var downloaders: [String: VODDownloader] = [:]
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
      if recorders[id] != nil || downloaders[id] != nil, let current = recordings.first(where: { $0.id == id }) {
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
    return recordings.first { $0.login == login && $0.videoID == nil && active[$0.id] != nil }
  }

  // MARK: Downloading VODs

  /// The download of this video going on, if any.
  func download(of videoID: String) -> RecordingInfo? {
    recordings.first { $0.videoID == videoID && active[$0.id] != nil }
  }

  /// A finished download of this video, if any.
  func downloaded(_ videoID: String) -> RecordingInfo? {
    recordings.first { $0.videoID == videoID && active[$0.id] == nil && $0.duration > 0 }
  }

  /// Downloads a VOD at a quality (see VODDownloadChoice), into the list with the recordings.
  func download(_ video: Video, quality label: String) {
    guard download(of: video.id) == nil else { return }
    let owner = video.owner ?? Channel(id: "", login: "twitch", displayName: "Twitch", profileImageURL: nil)
    let id = "vod-\(video.id)-\(Int(Date().timeIntervalSince1970))"
    let info = RecordingInfo(
      id: id, login: owner.login.lowercased(), channelName: owner.name, channelID: owner.id.isEmpty ? nil : owner.id,
      profileImageURL: owner.profileImageURL, title: video.title, category: video.categoryName, quality: label,
      startedAt: Date(), endedAt: nil, duration: 0, bytes: 0, gaps: 0, endReason: nil,
      streamStartedAt: video.createdAt, firstSegmentAt: video.createdAt, videoID: video.id)
    recordings.insert(info, at: 0)
    active[id] = .starting
    downloadProgress[id] = 0
    keepAwake()
    Task {
      do {
        let variant = try await Self.vodRendition(videoID: video.id, label: label)
        guard let url = URL(string: variant.uri) else { throw PlayerModel.VODError(errorDescription: "No address for \(label).") }
        var started = info
        started.quality = variant.label
        let downloader = VODDownloader(
          info: started, playlistURL: url, directory: root.appendingPathComponent(id, isDirectory: true),
          http: AppSettings.shared.playbackClient(timeout: 30)
        ) { [weak self] status, done in
          Task { @MainActor in self?.updateDownload(status, done: done) }
        }
        downloaders[id] = downloader
        await downloader.start()
      } catch {
        ActivityLog.shared.add("Couldn't download \(owner.name)'s video: \(error.localizedDescription)")
        var failed = info
        failed.endedAt = Date()
        failed.endReason = "Couldn't start: \(error.localizedDescription)"
        updateDownload(RecorderStatus(state: .ended, info: failed), done: 0)
      }
    }
  }

  /// The VOD's rendition nearest a choice: the best at or under that height ("720p"), the best
  /// ("Best"), or the sound alone ("Audio only").
  private static func vodRendition(videoID: String, label: String) async throws -> HLSVariant {
    let all = try await TwitchAPI.shared.vodRenditions(id: videoID, codecs: AppSettings.shared.codecs, timeout: 15).variants
    let master = HLSMaster(variants: all)
    let videos = master.videoVariants
    let pick: HLSVariant?
    if label == VODDownloadChoice.audio {
      pick = master.audioVariant ?? videos.last
    } else if let height = RecordQuality.height(label) {
      pick = videos.first { min($0.width, $0.height) <= height } ?? videos.last
    } else {
      pick = videos.first ?? master.audioVariant
    }
    guard let pick else { throw PlayerModel.VODError(errorDescription: "No playable qualities were found.") }
    return pick
  }

  private func updateDownload(_ status: RecorderStatus, done: Double) {
    let id = status.info.id
    if let index = recordings.firstIndex(where: { $0.id == id }) { recordings[index] = status.info }
    if status.state == .ended {
      active[id] = nil
      downloadProgress[id] = nil
      downloaders[id] = nil
      if status.info.duration == 0 {
        // Nothing came down: don't leave an empty entry behind.
        recordings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
      }
      AutoRecorder.shared.updateKeepAlive()
    } else {
      if active[id] != status.state { active[id] = status.state }
      // (Whole percents: the list doesn't need to redraw for every part.)
      if (downloadProgress[id].map { Int($0 * 100) } ?? -1) != Int(done * 100) { downloadProgress[id] = done }
    }
    keepAwake()
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
      bytes: 0, gaps: 0, endReason: nil, streamID: streamID ?? stream?.id, automatic: automatic,
      streamStartedAt: stream?.startedAt)
    let settings = AppSettings.shared
    var config = LowLatencyConfig()
    config.adFreeProxies = settings.adFreeProxyHosts
    config.checkAccountFirst = TwitchAuth.shared.session != nil
    config.nearbyServers = settings.nearbyServers
    let recorder = StreamRecorder(
      info: info, directory: root.appendingPathComponent(id, isDirectory: true), maxHeight: maxHeight, config: config,
      // (Giving way to the stream being watched: recording the channel being watched, both at
      // 1080p60 over the same Wi-Fi, the player got under three quarters of what it needed and
      // stalled every few seconds. With the connection to itself, it gets all of it.)
      http: settings.playbackClient(timeout: 20, givesWay: true), tokens: TwitchAPI.shared
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
    if let downloader = downloaders[id] {
      Task { await downloader.stop() }
      return
    }
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
    if let downloader = downloaders.removeValue(forKey: info.id) { Task { await downloader.stop() } }
    downloadProgress[info.id] = nil
    active[info.id] = nil
    recordings.removeAll { $0.id == info.id }
    try? FileManager.default.removeItem(at: root.appendingPathComponent(info.id, isDirectory: true))
    keepAwake()
  }

  var totalBytes: Int64 { recordings.reduce(0) { $0 + $1.bytes } }

  func playbackURL(_ info: RecordingInfo) -> URL? { try? StreamProxy.shared.recordingURL(id: info.id) }

  /// One broadcast's recordings together (a recording of a live stream started again, by hand or
  /// by itself, is another piece of the same broadcast): newest broadcast first.
  var groups: [RecordingGroup] {
    var order: [String] = []
    var byKey: [String: [RecordingInfo]] = [:]
    for info in recordings {
      let key = info.videoID == nil ? info.streamID.map { "stream-\($0)" } ?? info.id : info.id
      if byKey[key] == nil { order.append(key) }
      byKey[key, default: []].append(info)
    }
    return order.map { RecordingGroup(id: $0, pieces: (byKey[$0] ?? []).sorted { $0.startedAt < $1.startedAt }) }
  }

  func playbackURL(_ group: RecordingGroup) -> URL? {
    // Still being recorded: what's recorded so far, as a finished video (the player asks for a
    // fresh one as it nears the end). Given the growing playlist itself, Apple's player kept
    // loading until Kestrel was closed (which finished the recording's files).
    if group.pieces.contains(where: { active[$0.id] != nil && $0.videoID == nil }) {
      return try? StreamProxy.shared.snapshotURL(ids: group.pieces.map(\.id))
    }
    return group.pieces.count == 1
      ? playbackURL(group.pieces[0]) : try? StreamProxy.shared.joinedRecordingURL(ids: group.pieces.map(\.id))
  }

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
    ScreenAwake.set("recordings", awake)
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
/// A broadcast's recordings, oldest piece first (see `RecordingStore.groups`).
struct RecordingGroup: Identifiable, Equatable {
  let id: String
  let pieces: [RecordingInfo]

  /// The pieces as one: from the first's start, every piece's length and size, each join counted
  /// as a jump (the newest piece's id, so a recording still being made shows as one).
  var combined: RecordingInfo {
    guard var info = pieces.last, let first = pieces.first else { return pieces[0] }
    info.startedAt = first.startedAt
    info.firstSegmentAt = first.firstSegmentAt ?? first.startedAt
    info.streamStartedAt = pieces.compactMap(\.streamStartedAt).first
    info.duration = pieces.reduce(0) { $0 + $1.duration }
    info.bytes = pieces.reduce(0) { $0 + $1.bytes }
    info.gaps = pieces.reduce(0) { $0 + $1.gaps } + pieces.count - 1
    return info
  }

  /// Where the pieces join in the whole and how much wasn't recorded at each.
  var joins: [(at: Double, missing: Double)] {
    RecordingJoin.gaps(pieces.map { ($0.firstSegmentAt ?? $0.startedAt, $0.duration) })
  }
}

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
  @State private var playing: RecordingGroup? = nil

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
          Text("Nothing saved yet. Record a live stream or download a video from the player's gear menu, or schedule a channel above.")
            .font(.subheadline).foregroundColor(.secondary)
        }
        ForEach(store.groups) { group in
          let info = group.combined
          Button {
            play(group)
          } label: {
            RecordingRow(
              info: info, state: store.active[info.id], progress: store.downloadProgress[info.id], pieces: group.pieces.count)
          }
          .buttonStyle(.plain)
          .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
              group.pieces.forEach(store.delete)
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
        Text("Recordings and downloads")
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
    .fullScreenCover(item: $playing) { group in
      RecordingPlayerScreen(info: group.combined, url: store.playbackURL(group), positionKey: group.id, joins: group.joins)
    }
  }

  private func play(_ group: RecordingGroup) {
    guard group.combined.duration > 0 else { return }
    // One thing playing at a time (a recording being made carries on).
    if app.playing != nil { app.playing = nil }
    playing = group
  }

  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

struct RecordingRow: View {
  let info: RecordingInfo
  let state: RecorderStatus.State?
  /// A VOD downloading: how far along.
  var progress: Double? = nil
  /// Pieces of one broadcast shown as one.
  var pieces = 1

  var body: some View {
    HStack(spacing: 12) {
      Avatar(url: info.profileImageURL, size: 44)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(info.channelName).font(.headline).lineLimit(1)
          if let progress {
            Label("\(Int(progress * 100))%", systemImage: "arrow.down.circle.fill")
              .font(.caption2.weight(.heavy).monospacedDigit()).foregroundColor(.accentTeal).labelStyle(.titleAndIcon)
          } else if info.videoID != nil {
            Image(systemName: "arrow.down.circle").font(.caption).foregroundColor(.secondary)
              .accessibilityLabel("Downloaded video")
          } else if let state {
            badge(state)
          }
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
    var parts = [Format.relative(info.startedAt)]
    // Where it sits in the broadcast, on the stream's own clock.
    if pieces > 1 {
      // (Pieces with stretches between them: the time recorded, not a range of the stream.)
      parts.append("\(Format.duration(Int(info.duration))) recorded")
    } else if let offset = info.streamOffset {
      parts.append("\(Format.duration(Int(offset)))–\(Format.duration(Int(offset + info.duration))) of the stream")
    } else {
      parts.append(Format.duration(Int(info.duration)))
    }
    if info.bytes > 0 { parts.append(RecordingsView.size(info.bytes)) }
    if !info.quality.isEmpty { parts.append(info.quality) }
    if pieces > 1 { parts.append("\(pieces) parts") }
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

/// Plays a recording with Kestrel's own controls: a seek bar from the start to the newest part
/// recorded (it keeps growing while the recording is made, like a stream's VOD while it's live),
/// ten-second skips, a jump to the newest part, Picture in Picture, and the sound carrying on in
/// the background. Picks up where it was left, or starts from the beginning.
struct RecordingPlayerScreen: View {
  let info: RecordingInfo
  let url: URL?
  /// Where it was left is kept under this (a broadcast's pieces as one: the broadcast's).
  var positionKey: String? = nil
  /// Pieces joined: where, and how much of the stream wasn't recorded there (said as it's passed).
  var joins: [(at: Double, missing: Double)] = []
  @State private var skipNotice: String?
  @State private var lastPosition: Double = 0
  @ObservedObject private var store = RecordingStore.shared
  @Environment(\.dismiss) private var dismiss
  @StateObject private var playback = RecordingPlayback()
  @State private var controlsVisible = true
  @State private var hideTask: Task<Void, Never>? = nil
  @State private var fill = false

  /// Still being recorded (a VOD still downloading plays like a finished video, just shorter).
  private var recording: Bool { store.active[info.id] != nil && info.videoID == nil }

  var body: some View {
    GeometryReader { geometry in
      let landscape = geometry.size.width > geometry.size.height
      ZStack {
        Color.black
        RecordingVideoSurface(playback: playback, fill: fill)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .ignoresSafeArea()
        Color.black.opacity(0.001)
          .contentShape(Rectangle())
          .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.25)) { fill.toggle() } }
          .onTapGesture { toggleControls() }
          .ignoresSafeArea()
        if playback.buffering && !playback.isPaused {
          ProgressView().tint(.white).scaleEffect(1.2).allowsHitTesting(false)
        }
        controls(landscape: landscape)
          .opacity(controlsShown ? 1 : 0)
          .allowsHitTesting(controlsShown)
          .animation(.easeInOut(duration: 0.22), value: controlsShown)
        if let skipNotice {
          Label(skipNotice, systemImage: "forward.end.fill")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 64)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .allowsHitTesting(false)
        }
      }
      .animation(.easeInOut(duration: 0.25), value: skipNotice)
    }
    .onChange(of: playback.position) { position in
      // Played across a join (not jumped over by seeking): says what wasn't recorded.
      defer { lastPosition = position }
      guard position > lastPosition, position - lastPosition < 3,
        let join = joins.first(where: { lastPosition < $0.at && position >= $0.at })
      else { return }
      let missing = join.missing >= 1 ? Format.duration(Int(join.missing)) : nil
      skipNotice = missing.map { "Skipped \($0) that wasn't recorded" } ?? "Next recorded part"
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { skipNotice = nil }
    }
    .background(Color.black.ignoresSafeArea())
    .preferredColorScheme(.dark)
    .statusBarHidden(!controlsShown)
    .onAppear {
      OrientationLock.playerVisible(true)
      AppModel.shared.watchingRecording = true
      if let url { playback.start(url: url, id: positionKey ?? info.id, growing: recording) }
      scheduleHide()
    }
    .onChange(of: recording) { playback.setGrowing($0) }
    .onDisappear {
      playback.finish()
      AppModel.shared.watchingRecording = false
      if AppModel.shared.playing == nil { OrientationLock.playerVisible(false) }
    }
  }

  private var controlsShown: Bool { controlsVisible || playback.isPaused }

  private func controls(landscape: Bool) -> some View {
    ZStack {
      LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
        .allowsHitTesting(false)
      VStack(spacing: 0) {
        topBar
        Spacer(minLength: 0)
        bottomBar
      }
      .padding(.horizontal, landscape ? 12 : 8)
      .padding(.vertical, 6)
      HStack(spacing: landscape ? 44 : 30) {
        roundButton(icon: "gobackward.10", size: 50, label: "Back 10 seconds") { playback.skip(by: -10) }
        roundButton(icon: playback.isPaused ? "play.fill" : "pause.fill", size: 64, label: playback.isPaused ? "Play" : "Pause") {
          playback.togglePause()
        }
        roundButton(icon: "goforward.10", size: 50, label: "Forward 10 seconds") { playback.skip(by: 10) }
          .opacity(playback.canSkipForward ? 1 : 0.35)
          .disabled(!playback.canSkipForward)
      }
    }
    .foregroundColor(.white)
  }

  private var topBar: some View {
    HStack(spacing: 10) {
      Button {
        dismiss()
      } label: {
        Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 40)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Close")
      Avatar(url: info.profileImageURL, size: 30)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text(info.channelName).font(.subheadline.weight(.bold))
          if recording {
            Label("REC", systemImage: "record.circle.fill").font(.caption2.weight(.heavy)).foregroundColor(.liveRed)
              .labelStyle(.titleAndIcon)
          }
        }
        if let title = info.title, !title.isEmpty {
          Text(title).font(.caption).foregroundColor(.white.opacity(0.75))
        }
      }
      .lineLimit(1)
      Spacer(minLength: 6)
      AirPlayButton().frame(width: 40, height: 40)
      if AVPictureInPictureController.isPictureInPictureSupported() {
        Button {
          playback.togglePictureInPicture()
        } label: {
          Image(systemName: playback.pictureInPictureActive ? "pip.exit" : "pip.enter")
            .font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .accessibilityLabel("Picture in Picture")
      }
      if recording {
        // Caught up: on to the stream itself.
        Button {
          let channel = Channel(
            id: info.channelID ?? "", login: info.login, displayName: info.channelName, profileImageURL: info.profileImageURL)
          dismiss()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { AppModel.shared.playing = .live(channel) }
        } label: {
          Text("Watch live").font(.footnote.weight(.semibold))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Color.liveRed, in: Capsule())
        }
        .accessibilityHint("Closes the recording and opens the live stream")
      }
    }
  }

  /// The stream's own clock at the recording's start (so every moment shows when in the broadcast
  /// it was, not how far into the recording): from the dated playlist, or worked out from when the
  /// recording began.
  private var streamBase: Double? {
    if let date = playback.currentDate, let start = info.streamStartedAt {
      let base = date.timeIntervalSince(start) - playback.position
      if base >= -5, base < 7 * 24 * 3600 { return max(0, base) }
    }
    return info.streamOffset
  }

  private var bottomBar: some View {
    let base = streamBase
    return VStack(spacing: 2) {
      if let base, playback.end > 0 {
        BroadcastStrip(
          start: base, end: base + playback.end, position: base + playback.position,
          live: recording, liveNow: info.streamStartedAt.map { Date().timeIntervalSince($0) })
          .padding(.horizontal, 8)
          .padding(.bottom, 6)
      }
      if playback.end > 0 {
        SeekBar(
          position: playback.position, duration: playback.end, storyboard: nil,
          // Where pieces join (stretches of the stream that weren't recorded).
          marks: joins.map { max(0, $0.at - 1)...($0.at + 1) },
          label: { [recording, playback, base] time in
            recording && playback.end - time < 15 ? "Latest" : Format.duration(Int((base ?? 0) + time))
          },
          onStart: { hideTask?.cancel() },
          onCommit: { time in
            playback.seek(to: time)
            scheduleHide()
          }
        )
        .padding(.horizontal, 4)
      }
      HStack(spacing: 10) {
        if let base {
          // On the stream's clock: when in the broadcast this is.
          HStack(spacing: 5) {
            Image(systemName: "clock").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.7))
            Text(Format.duration(Int(base + playback.position))).font(.caption.monospacedDigit().weight(.semibold))
            Text("into the stream").font(.caption2).foregroundColor(.white.opacity(0.6))
          }
          .lineLimit(1)
          .fixedSize()
          .accessibilityElement(children: .combine)
        } else {
          Text("\(Format.duration(Int(playback.position))) / \(Format.duration(Int(playback.end)))")
            .font(.caption.monospacedDigit())
        }
        if recording {
          // How far behind the newest recorded part, and a jump there.
          Button {
            playback.jumpToNewest()
            scheduleHide()
          } label: {
            Text("LATEST").font(.caption.weight(.heavy))
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(playback.atNewest ? Color.liveRed : Color.gray, in: RoundedRectangle(cornerRadius: 4))
          }
          .accessibilityLabel("Jump to the newest part recorded")
          if !playback.atNewest {
            Text("\(Format.duration(Int(playback.end - playback.position))) behind")
              .font(.caption.monospacedDigit()).foregroundColor(.white.opacity(0.75))
          }
        }
        Spacer()
        Button {
          withAnimation(.easeInOut(duration: 0.25)) { fill.toggle() }
          scheduleHide()
        } label: {
          Image(systemName: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .accessibilityLabel(fill ? "Fit the picture" : "Fill the screen")
      }
    }
  }

  private func roundButton(icon: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
    Button {
      action()
      scheduleHide()
    } label: {
      Image(systemName: icon)
        .font(.system(size: size > 60 ? 30 : 22, weight: .semibold))
        .frame(width: size, height: size)
        .background(.black.opacity(0.35), in: Circle())
    }
    .buttonStyle(PressableStyle(scale: 0.88))
    .accessibilityLabel(label)
  }

  private func toggleControls() {
    if controlsVisible {
      hideTask?.cancel()
      controlsVisible = false
    } else {
      scheduleHide()
    }
  }

  private func scheduleHide() {
    hideTask?.cancel()
    controlsVisible = true
    hideTask = Task {
      try? await Task.sleep(nanoseconds: 3_500_000_000)
      guard !Task.isCancelled else { return }
      controlsVisible = false
    }
  }
}

/// The recording's picture (with Picture in Picture).
/// The whole broadcast as a thin line, with the stretch this recording covers lit and where
/// playback is in it: "recorded from 0:42:10 to 1:30:05 of the stream" at a glance.
struct BroadcastStrip: View {
  /// On the stream's clock (seconds since it went live).
  let start: Double
  let end: Double
  let position: Double
  /// Still recording: the stream is live, now `liveNow` seconds in.
  let live: Bool
  var liveNow: Double?

  var body: some View {
    let total = max(end, live ? (liveNow ?? end) : end, 1)
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text("Recorded \(Format.duration(Int(start)))–\(live ? "now" : Format.duration(Int(end))) of the stream")
        Spacer(minLength: 6)
        Text(live ? "Live · \(Format.duration(Int(total)))" : Format.duration(Int(total)))
      }
      .font(.caption2.monospacedDigit())
      .foregroundColor(.white.opacity(0.65))
      .lineLimit(1)
      GeometryReader { geometry in
        let width = geometry.size.width
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.14))
          Capsule().fill(Color.white.opacity(0.38))
            .frame(width: max(3, width * CGFloat((end - start) / total)))
            .offset(x: width * CGFloat(start / total))
          Circle().fill(Color.accentTeal)
            .frame(width: 8, height: 8)
            .offset(x: width * CGFloat(min(position, total) / total) - 4)
        }
      }
      .frame(height: 4)
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Recorded from \(Format.duration(Int(start))) of the stream")
  }
}

struct RecordingVideoSurface: UIViewRepresentable {
  let playback: RecordingPlayback
  var fill: Bool

  func makeUIView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.backgroundColor = .black
    view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    playback.attach(view)
    return view
  }

  func updateUIView(_ view: PlayerLayerView, context: Context) {
    let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
    if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
  }
}

@MainActor
final class RecordingPlayback: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
  let player = AVPlayer()
  @Published private(set) var position: Double = 0
  /// The newest moment recorded (grows while the recording is made), or the whole length.
  @Published private(set) var end: Double = 0
  @Published private(set) var isPaused = false
  @Published private(set) var buffering = true
  @Published private(set) var pictureInPictureActive = false
  /// When what's showing was broadcast (from the recording's dated playlist).
  @Published private(set) var currentDate: Date?
  private var id = ""
  private var statusObservation: NSKeyValueObservation?
  private var pipObservation: NSKeyValueObservation?
  private var ticker: Timer?
  private var pip: AVPictureInPictureController?
  private weak var view: PlayerLayerView?
  private var detached = false
  private var seekingTo: Double?
  private var lastSaved = Date.distantPast
  private var tokens: [NSObjectProtocol] = []
  private var url: URL?
  /// Where to go once the item is ready (the start, where it was left, or where it stalled).
  private var pendingSeek: Double?
  /// Waiting for video since then (not seeking).
  private var stalledSince: Date?
  private var lastReload = Date.distantPast
  /// Each load's number (a load waits for the server check; only the newest goes ahead).
  private var loadGeneration = 0
  private var loadStartedAt = Date.distantPast

  nonisolated override init() {
    super.init()
  }

  private static func positionKey(_ id: String) -> String { "kestrel.recordingPosition.\(id)" }

  var atNewest: Bool { end - position < 15 }
  var canSkipForward: Bool { end - position > 3 }

  func start(url: URL, id: String, growing: Bool = false) {
    self.id = id
    self.url = url
    self.growing = growing
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)
    let resume = UserDefaults.standard.double(forKey: Self.positionKey(id))
    player.automaticallyWaitsToMinimizeStalling = true
    // Where it was left, or the start (a recording still being made would otherwise start at its
    // end, like a live stream).
    load(url, at: resume > 5 ? resume - 3 : 0)
    // On the wall clock, not the player's (a periodic time observer goes quiet while the video
    // doesn't move, which is just when a stall needs noticing).
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
    let center = NotificationCenter.default
    tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { Task { @MainActor in self?.settleInBackground() } }
    })
    tokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        self?.reattach()
        await self?.checkServer()
      }
    })
    tokens.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
      guard let ended = (note.object as AnyObject?).map(ObjectIdentifier.init) else { return }
      Task { @MainActor in
        // Played to the end of what was recorded when it was loaded, and it's still recording:
        // on with what's been recorded since.
        guard let playback = self, playback.growing, let item = playback.player.currentItem, ObjectIdentifier(item) == ended else { return }
        playback.refreshSnapshot(at: playback.position)
      }
    })
    tokens.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
      guard let failed = (note.object as AnyObject?).map(ObjectIdentifier.init) else { return }
      Task { @MainActor in
        guard let playback = self, let item = playback.player.currentItem, ObjectIdentifier(item) == failed else { return }
        playback.recover("it stopped playing")
      }
    })
  }

  /// A fresh item for the recording, going to `seconds` once it's ready. Kestrel's local server
  /// (which serves recordings) is checked first: iOS can take its socket while Kestrel is in the
  /// background, and then nothing loads until it's restarted (as quitting Kestrel did).
  private func load(_ url: URL, at seconds: Double) {
    pendingSeek = seconds
    stalledSince = nil
    loadStartedAt = Date()
    loadGeneration += 1
    let generation = loadGeneration
    Task { @MainActor in
      await StreamProxy.shared.ensureResponsive()
      guard self.url != nil, generation == self.loadGeneration else { return }
      let address = (try? StreamProxy.shared.currentAddress(of: url)) ?? url
      if address != url {
        ActivityLog.shared.add("Recording playback: Kestrel's local server moved, following it")
        self.url = address
      }
      self.makeItem(address)
    }
  }

  /// Back from the background: the local server may have been taken meanwhile (and restarted by
  /// another player, maybe on another port). Loaded again where it was if so.
  private func checkServer() async {
    guard let url, pendingSeek == nil else { return }
    await StreamProxy.shared.ensureResponsive()
    let moved = (try? StreamProxy.shared.currentAddress(of: url)).map { $0 != url } ?? false
    if moved || player.currentItem?.status == .failed {
      lastReload = .distantPast
      recover("Kestrel's local server was restarted")
    }
  }

  private func makeItem(_ url: URL) {
    let item = AVPlayerItem(url: url)
    let identity = ObjectIdentifier(item)
    statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      let status = item.status
      let error = item.error?.localizedDescription ?? "no reason given"
      Task { @MainActor in
        guard let playback = self, let current = playback.player.currentItem, ObjectIdentifier(current) == identity else { return }
        if status == .failed {
          playback.recover("it failed (\(error))")
        } else if status == .readyToPlay, let target = playback.pendingSeek {
          playback.pendingSeek = nil
          if target.isInfinite {
            // The newest part: a little before the end of this fresh snapshot.
            let length = item.duration.seconds
            playback.seek(to: length.isFinite ? max(0, length - 8) : 0)
          } else {
            playback.seek(to: target)
          }
        }
      }
    }
    player.replaceCurrentItem(with: item)
  }

  /// The player gave up on the recording, or has waited for video it has: load it again where it
  /// was. (AVPlayer can stop following a playlist that's still growing, or fail on a part read
  /// while it was being saved.) At most every few seconds, so a recording that really can't play
  /// doesn't spin.
  private func recover(_ why: String) {
    guard let url, Date().timeIntervalSince(lastReload) > 6 else { return }
    lastReload = Date()
    let current = player.currentTime().seconds
    // Where it was going, or a second before where it stopped.
    let at = seekingTo ?? pendingSeek ?? max(0, (current.isFinite && current > 0 ? current : position) - 1)
    ActivityLog.shared.add("Recording playback: \(why); loading it again at \(at.isFinite ? Format.duration(Int(at)) : "the newest part")")
    seekingTo = nil
    load(url, at: at)
  }

  private func tick() {
    // Loaded but never ready, or failed (and not loaded again yet: at most every few seconds).
    if pendingSeek != nil, Date().timeIntervalSince(loadStartedAt) > 20 {
      recover("it didn't load")
      return
    }
    guard let item = player.currentItem else { return }
    if item.status == .failed {
      recover("it failed (\(item.error?.localizedDescription ?? "no reason given"))")
      return
    }
    let seekable = item.seekableTimeRanges.map(\.timeRangeValue).last.map { CMTimeRangeGetEnd($0).seconds } ?? 0
    let length = item.duration.seconds.isFinite ? item.duration.seconds : 0
    let newEnd = max(seekable, length)
    if newEnd.isFinite, abs(newEnd - end) >= 0.5 { end = newEnd.rounded(.down) }
    let current = player.currentTime().seconds
    if let target = seekingTo ?? pendingSeek, target.isFinite {
      position = target
    } else if current.isFinite, seekingTo == nil, pendingSeek == nil {
      position = current
    }
    // Still recording, and playing near the end of what was recorded when this snapshot was made:
    // a fresh one, where it is (with what's been recorded since).
    if growing, seekingTo == nil, pendingSeek == nil, end > 0, position > end - Self.snapshotAhead,
      player.timeControlStatus != .paused, Date().timeIntervalSince(lastSnapshot) > Self.snapshotEvery
    {
      refreshSnapshot(at: position)
    }
    if seekingTo == nil, pendingSeek == nil, let date = item.currentDate(), date != currentDate { currentDate = date }
    let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate || seekingTo != nil || pendingSeek != nil
    if waiting != buffering { buffering = waiting }
    // Stuck: waiting with more recorded ahead (or for long at the newest part, where new video
    // should turn up every couple of seconds).
    if player.timeControlStatus == .waitingToPlayAtSpecifiedRate, seekingTo == nil, pendingSeek == nil {
      let since = stalledSince ?? Date()
      stalledSince = since
      let stuck = Date().timeIntervalSince(since)
      if (end - position > 8 && stuck > 8) || stuck > 25 { recover("it waited \(Int(stuck)) s for video") }
    } else {
      stalledSince = nil
    }
    let paused = player.timeControlStatus == .paused && seekingTo == nil && pendingSeek == nil
    if paused != isPaused { isPaused = paused }
    if Date().timeIntervalSince(lastSaved) > 5, current.isFinite, current > 0 {
      lastSaved = Date()
      UserDefaults.standard.set(current, forKey: Self.positionKey(id))
    }
  }

  func seek(to seconds: Double) {
    let target = max(0, end > 0 ? min(seconds, end - 1) : seconds)
    seekingTo = target
    position = target
    player.seek(
      to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero,
      toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600)
    ) { [weak self] _ in
      Task { @MainActor in
        guard let playback = self else { return }
        playback.seekingTo = nil
        playback.player.play()
        playback.isPaused = false
      }
    }
  }

  func skip(by seconds: Double) { seek(to: position + seconds) }

  /// The newest part recorded (a little back, so it doesn't run straight into the end). Still
  /// recording: a fresh snapshot first, with everything recorded up to now.
  func jumpToNewest() {
    if growing, let url {
      lastSnapshot = Date()
      load(url, at: .infinity)
      return
    }
    seek(to: max(0, end - 8))
  }

  /// Still being recorded: played as what's been recorded so far (see RecordingJoin.snapshot),
  /// reloaded as it nears the end.
  private(set) var growing = false
  private var lastSnapshot = Date()
  /// How close to the end of a snapshot a fresh one is asked for, and how often at most.
  static let snapshotAhead: Double = 15
  static let snapshotEvery: TimeInterval = 10

  /// The recording stopped (or started) while it's being watched. Stopped: one last snapshot, so
  /// the end of it is in.
  func setGrowing(_ value: Bool) {
    let was = growing
    growing = value
    if was, !value { refreshSnapshot(at: position) }
  }

  /// A fresh snapshot of the recording, at `seconds`.
  func refreshSnapshot(at seconds: Double) {
    guard let url, pendingSeek == nil else { return }
    lastSnapshot = Date()
    load(url, at: max(0, seconds))
  }

  func togglePause() {
    if isPaused {
      player.play()
      isPaused = false
    } else {
      player.pause()
      isPaused = true
    }
  }

  func attach(_ view: PlayerLayerView) {
    self.view = view
    view.playerLayer.player = player
    guard AVPictureInPictureController.isPictureInPictureSupported(),
      let pip = AVPictureInPictureController(playerLayer: view.playerLayer)
    else { return }
    pip.canStartPictureInPictureAutomaticallyFromInline = true
    pip.delegate = self
    pipObservation = pip.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] pip, _ in
      let active = pip.isPictureInPictureActive
      Task { @MainActor in self?.pictureInPictureActive = active }
    }
    self.pip = pip
  }

  func togglePictureInPicture() {
    guard let pip else { return }
    if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
  }

  /// In the background without Picture in Picture: the sound carries on (with the picture taken off).
  private func settleInBackground() {
    guard UIApplication.shared.applicationState == .background, !(pip?.isPictureInPictureActive ?? false) else { return }
    if AppSettings.shared.backgroundAudio {
      detached = true
      view?.playerLayer.player = nil
    } else {
      player.pause()
    }
  }

  private func reattach() {
    guard detached else { return }
    detached = false
    view?.playerLayer.player = player
  }

  func finish() {
    let seconds = player.currentTime().seconds
    if seconds.isFinite, seconds > 0 { UserDefaults.standard.set(seconds, forKey: Self.positionKey(id)) }
    pip?.stopPictureInPicture()
    url = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    ticker?.invalidate()
    ticker = nil
    statusObservation = nil
    pipObservation = nil
    tokens.forEach(NotificationCenter.default.removeObserver)
    tokens = []
  }

  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) { completionHandler(true) }
}

/// What a VOD can be downloaded at, offered before its qualities are known (holding it in a list):
/// the nearest the video has is used.
enum VODDownloadChoice {
  static let best = "Best"
  static let audio = "Audio only"
  static let all = [best, "1080p", "720p", "480p", "360p", audio]

  /// Roughly how big a download of that length is at that choice.
  static func size(_ label: String, seconds: Int) -> String {
    let perHour: Double
    switch label == best ? 1080 : RecordQuality.height(label) ?? 0 {
    case 1080...: perHour = 3
    case 720...: perHour = 1.5
    case 480...: perHour = 0.6
    case 360...: perHour = 0.3
    default: perHour = 0.08
    }
    let gigabytes = perHour * max(Double(seconds) / 3600, 0.05)
    return gigabytes >= 1 ? String(format: "≈%.1f GB", gigabytes) : String(format: "≈%.0f MB", gigabytes * 1000)
  }
}
