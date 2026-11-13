// Recording a live stream to the phone, for streams that don't keep a VOD (or to watch later
// anyway): Twitch's video saved as it's made, as an HLS recording (the segment files plus a
// playlist) that plays back from Kestrel's local server and can be watched from the start while
// it's still recording.
//
// It runs as long as Kestrel does. iOS pauses apps in the background unless they're playing
// sound, so a stretch the app spent paused is missing from the recording (marked as a jump).

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// What a recording is, saved next to it as `recording.json`.
struct RecordingInfo: Codable, Sendable, Identifiable, Equatable {
  var id: String
  var login: String
  var channelName: String
  var channelID: String?
  var profileImageURL: String?
  var title: String?
  var category: String?
  /// The rendition recorded, e.g. "720p60".
  var quality: String
  var startedAt: Date
  /// Nil while recording.
  var endedAt: Date?
  /// Seconds of video saved.
  var duration: Double
  var bytes: Int64
  /// Stretches that couldn't be recorded (the app was paused, a connection dropped, ads).
  var gaps: Int
  /// Why it ended ("Stopped", "The stream ended", …).
  var endReason: String?
  /// The broadcast recorded.
  var streamID: String? = nil
  /// Started by itself when the channel went live.
  var automatic: Bool? = nil
  /// Stopped by hand (not started again for the same broadcast).
  var stoppedByUser: Bool? = nil
  /// When the broadcast began, and when the first moment recorded was broadcast: where the
  /// recording sits in the stream ("from 1:12:40 in").
  var streamStartedAt: Date? = nil
  var firstSegmentAt: Date? = nil
  /// A downloaded VOD (not a recording of a live stream): the video's id.
  var videoID: String? = nil
}

extension RecordingInfo {
  /// How far into the broadcast the recording begins, when that's known.
  var streamOffset: Double? {
    guard let streamStartedAt else { return nil }
    let offset = (firstSegmentAt ?? startedAt).timeIntervalSince(streamStartedAt)
    return offset >= 0 && offset < 7 * 24 * 3600 ? offset : nil
  }
}

struct RecorderStatus: Sendable, Equatable {
  enum State: Sendable, Equatable {
    case starting
    case recording
    case reconnecting
    case ended
  }
  var state: State
  var info: RecordingInfo
}

actor StreamRecorder {
  nonisolated let id: String
  nonisolated let login: String
  private let directory: URL
  private var info: RecordingInfo
  /// The highest rendition to record (lines, e.g. 720); nil for the best there is.
  private let maxHeight: Int?
  private let config: LowLatencyConfig
  private let http: HTTPClient
  private let tokens: PlaybackTokenProvider
  private let log: ActivityLog
  private let onStatus: @Sendable (RecorderStatus) -> Void

  private struct Entry {
    var file: String
    var duration: Double
    var discontinuity: Bool
    var map: String?
    /// When it was broadcast (Twitch's playlists say).
    var date: Date?
  }

  private var variantURL: URL?
  private var lastSequence: Int?
  private var entries: [Entry] = []
  private var pendingDiscontinuity = false
  private var targetDuration = 6.0
  /// Init sections (fMP4 renditions): remote address → saved file.
  private var maps: [String: String] = [:]
  private var task: Task<Void, Never>?
  private var finished = false

  static let playlistName = "index.m3u8"
  /// The playlists' target duration: Twitch's (its segments are at most this long), so it never
  /// changes while a recording is watched (see playlistText).
  static let stableTargetDuration = 6
  static let infoName = "recording.json"

  /// - Parameters:
  ///   - directory: where this recording goes (created).
  ///   - maxHeight: the highest rendition to record (nil: the best).
  init(
    info: RecordingInfo, directory: URL, maxHeight: Int?, config: LowLatencyConfig, http: HTTPClient,
    tokens: PlaybackTokenProvider, log: ActivityLog = .shared, onStatus: @escaping @Sendable (RecorderStatus) -> Void
  ) {
    id = info.id
    login = info.login.lowercased()
    self.info = info
    self.directory = directory
    self.maxHeight = maxHeight
    self.config = config
    self.http = http
    self.tokens = tokens
    self.log = log
    self.onStatus = onStatus
  }

  func start() {
    guard task == nil else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    writeInfo()
    task = Task { [weak self] in await self?.run() }
  }

  func stop(reason: String = "Stopped", byUser: Bool = false) {
    if byUser { info.stoppedByUser = true }
    task?.cancel()
    finish(reason)
  }

  var current: RecordingInfo { info }

  // MARK: - Loop

  private func run() async {
    publish(.starting)
    var failures = 0
    while !finished, !Task.isCancelled {
      let started = Date()
      if variantURL == nil {
        do {
          try await pickRendition()
          failures = 0
        } catch StreamSession.StartError.offline {
          finish("The stream ended")
          return
        } catch {
          failures += 1
          if failures > 40 {
            finish("Couldn't reach Twitch")
            return
          }
          publish(.reconnecting)
          await pause(seconds: 5)
          continue
        }
      }
      guard let url = variantURL else { continue }
      switch await fetchPlaylist(url) {
      case .success(let playlist):
        failures = 0
        await save(from: playlist)
        if playlist.isEnded {
          finish("The stream ended")
          return
        }
        publish(.recording)
      case .failure(let status):
        failures += 1
        // Gone (the token ran out, or the stream restarted): ask for the stream again.
        if status == 403 || status == 404 || failures % 5 == 0 { variantURL = nil }
        if failures > 60 {
          finish("Couldn't reach Twitch")
          return
        }
        publish(.reconnecting)
      }
      // About three times a segment, so none slips out of the playlist's window.
      let wait = max(0.4, min(2, targetDuration / 3) - Date().timeIntervalSince(started))
      await pause(seconds: wait)
    }
  }

  private func pause(seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }

  /// The rendition to record: the best one up to `maxHeight` (landscape, not audio only).
  private func pickRendition() async throws {
    let fetched = try await MasterPlaylistFetch.fetch(
      login: login, codecs: "h264", lowLatency: false, proxies: config.adFreeProxies,
      checkAccountFirst: config.checkAccountFirst, playerType: config.mainPlayerType, http: http, tokens: tokens, log: log)
    let renditions = HLSMaster.parse(fetched.text, base: fetched.url).variants
      .filter { !$0.isAudioOnly && !$0.isPortrait }
      .sorted { ($0.height, $0.frameRate, $0.bandwidth) > ($1.height, $1.frameRate, $1.bandwidth) }
    guard !renditions.isEmpty else { throw StreamSession.StartError.noVariants }
    let pick = maxHeight.flatMap { limit in renditions.first { min($0.width, $0.height) <= limit } } ?? renditions.last!
    var uri = maxHeight == nil ? renditions[0].uri : pick.uri
    let label = maxHeight == nil ? renditions[0].label : pick.label
    // Twitch's server near you instead of the ad-free server's (see NearbyPlaylists): more
    // bandwidth, so recording keeps up.
    if case .adFreeServer = fetched.route, config.nearbyServers, let near = fetched.nearbyHost,
      let host = URL(string: uri)?.host, near != host, NearbyPlaylists.isTwitchPlaylistHost(host),
      NearbyPlaylists.worthTrying(near), let swapped = URL(string: NearbyPlaylists.replacingHost(uri, with: near))
    {
      if case .success(let playlist) = await fetchPlaylist(swapped), playlist.isClean, !playlist.regularSegments.isEmpty {
        uri = swapped.absoluteString
      }
    }
    variantURL = URL(string: uri)
    if info.quality.isEmpty || info.quality != label {
      if !info.quality.isEmpty { pendingDiscontinuity = true }
      info.quality = label
    }
    log.add("Recording \(login) at \(label)")
  }

  // MARK: - Saving

  private func save(from playlist: HLSMediaPlaylist) async {
    targetDuration = playlist.targetDuration
    let regular = playlist.regularSegments
    var wanted: [(sequence: Int, segment: HLSSegment)] = []
    for (offset, segment) in regular.enumerated() {
      let sequence = playlist.mediaSequence + offset
      if let last = lastSequence, sequence <= last { continue }
      wanted.append((sequence, segment))
    }
    guard !wanted.isEmpty else { return }
    if let last = lastSequence, let first = wanted.first?.sequence, first > last + 1 {
      // Segments went by while the app was paused (or a connection was down).
      pendingDiscontinuity = true
      info.gaps += 1
    }
    // A few at a time (one connection rarely keeps up with a high bitrate far from the server),
    // saved in order.
    var index = 0
    while index < wanted.count, !finished {
      let batch = Array(wanted[index..<min(index + 4, wanted.count)])
      index += batch.count
      let results = await withTaskGroup(of: (Int, Data?).self) { group -> [Int: Data] in
        for (position, item) in batch.enumerated() where !item.segment.isAd {
          group.addTask { [http] in
            (position, await Self.download(item.segment.uri, http: http))
          }
        }
        var out: [Int: Data] = [:]
        for await (position, data) in group { if let data { out[position] = data } }
        return out
      }
      for (position, item) in batch.enumerated() {
        lastSequence = item.sequence
        guard !item.segment.isAd, let data = results[position] else {
          // An ad (skipped) or a segment that couldn't be fetched: a jump in the recording.
          if !pendingDiscontinuity, !entries.isEmpty { info.gaps += 1 }
          pendingDiscontinuity = true
          continue
        }
        var mapFile: String?
        if let map = item.segment.map {
          mapFile = await saveMap(map)
          if mapFile == nil {
            pendingDiscontinuity = true
            continue
          }
        }
        let ext = mapFile == nil ? "ts" : "m4s"
        let file = String(format: "%06d", entries.count + 1) + "." + ext
        do {
          try data.write(to: directory.appendingPathComponent(file))
        } catch {
          finish("Couldn't save (is the phone full?)")
          return
        }
        let previousMap = entries.last?.map
        entries.append(
          Entry(
            file: file, duration: item.segment.duration,
            discontinuity: pendingDiscontinuity || item.segment.discontinuity || (mapFile != nil && mapFile != previousMap),
            map: mapFile, date: item.segment.pdt))
        if info.firstSegmentAt == nil { info.firstSegmentAt = item.segment.pdt }
        pendingDiscontinuity = false
        info.duration += item.segment.duration
        info.bytes += Int64(data.count)
      }
    }
    // (Stopped meanwhile: the playlist stays finished.)
    writePlaylist(ended: finished)
    writeInfo()
  }

  private func saveMap(_ remote: String) async -> String? {
    if let saved = maps[remote] { return saved }
    guard let data = await Self.download(remote, http: http) else { return nil }
    let file = "init-\(maps.count + 1).mp4"
    guard (try? data.write(to: directory.appendingPathComponent(file))) != nil else { return nil }
    maps[remote] = file
    return file
  }

  private static func download(_ uri: String, http: HTTPClient) async -> Data? {
    guard let url = URL(string: uri) else { return nil }
    for _ in 0..<2 {
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
      request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
      if let (data, response) = try? await http.data(for: request), response.statusCode == 200, !data.isEmpty {
        return data
      }
    }
    return nil
  }

  // MARK: - Files

  private func writePlaylist(ended: Bool) {
    try? Self.playlistText(
      entries: entries.map { ($0.file, $0.duration, $0.discontinuity, $0.map) }, dates: entries.map(\.date), ended: ended
    ).write(to: directory.appendingPathComponent(Self.playlistName), atomically: true, encoding: .utf8)
  }

  /// The recording's playlist: an event playlist that grows while recording and gets its end
  /// added when it's done. With the segments' broadcast times (`dates`), each stretch is dated, so
  /// the player knows when in the stream every moment was (the recording's own clock restarts at
  /// zero).
  ///
  /// The header is the same from the first segment to the end: a player watching it while it's
  /// made reloads it, and AVPlayer stalls a playlist whose target duration or type changes between
  /// reloads (HLS allows only adding segments and the end). So the target duration is Twitch's own
  /// bound (6 s), not the longest segment so far (2 s, then 3 when one ran a little long), and the
  /// type stays EVENT once it's ended (an event with its end plays like a finished video).
  static func playlistText(
    entries: [(file: String, duration: Double, discontinuity: Bool, map: String?)], dates: [Date?] = [], ended: Bool
  ) -> String {
    let longest = entries.map(\.duration).max() ?? 2
    var lines = [
      "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(stableTargetDuration, Int(longest.rounded(.up))))",
      "#EXT-X-PLAYLIST-TYPE:EVENT", "#EXT-X-MEDIA-SEQUENCE:0",
      // Start from the beginning, not at the newest part like a live stream.
      "#EXT-X-START:TIME-OFFSET=0",
    ]
    var currentMap: String?
    for (index, entry) in entries.enumerated() {
      if entry.discontinuity, index > 0 { lines.append("#EXT-X-DISCONTINUITY") }
      if index < dates.count, let date = dates[index], index == 0 || entry.discontinuity || dates[index - 1] == nil {
        lines.append("#EXT-X-PROGRAM-DATE-TIME:" + HLSDate.format(date))
      }
      if let map = entry.map, map != currentMap {
        lines.append("#EXT-X-MAP:URI=\"\(map)\"")
        currentMap = map
      }
      lines.append(String(format: "#EXTINF:%.3f,", entry.duration))
      lines.append(entry.file)
    }
    if ended { lines.append("#EXT-X-ENDLIST") }
    return lines.joined(separator: "\n") + "\n"
  }

  private func writeInfo() {
    Self.save(info, in: directory)
  }

  static func save(_ info: RecordingInfo, in directory: URL) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    if let data = try? encoder.encode(info) { try? data.write(to: directory.appendingPathComponent(infoName), options: .atomic) }
  }

  static func load(from directory: URL) -> RecordingInfo? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(infoName)) else { return nil }
    return try? decoder.decode(RecordingInfo.self, from: data)
  }

  /// A recording the app stopped making without finishing it (it was closed): finish its files.
  static func finishInterrupted(in directory: URL) -> RecordingInfo? {
    guard var info = load(from: directory) else { return nil }
    guard info.endedAt == nil else { return info }
    let playlistURL = directory.appendingPathComponent(playlistName)
    if var text = try? String(contentsOf: playlistURL, encoding: .utf8), !text.contains("#EXT-X-ENDLIST") {
      text += "#EXT-X-ENDLIST\n"
      try? text.write(to: playlistURL, atomically: true, encoding: .utf8)
    }
    let modified = (try? FileManager.default.attributesOfItem(atPath: playlistURL.path))?[.modificationDate] as? Date
    info.endedAt = modified ?? Date()
    info.endReason = "Kestrel was closed"
    save(info, in: directory)
    return info
  }

  private func finish(_ reason: String) {
    guard !finished else { return }
    finished = true
    info.endedAt = Date()
    info.endReason = reason
    writePlaylist(ended: true)
    writeInfo()
    log.add("Recording \(login) ended: \(reason)")
    publish(.ended)
  }

  private var lastPublished: RecorderStatus?

  private func publish(_ state: RecorderStatus.State) {
    let status = RecorderStatus(state: state, info: info)
    guard status != lastPublished else { return }
    lastPublished = status
    onStatus(status)
  }

  // MARK: - Network

  private enum PlaylistResult {
    case success(HLSMediaPlaylist)
    case failure(Int)
  }

  private func fetchPlaylist(_ url: URL) async -> PlaylistResult {
    do {
      let (data, response) = try await http.data(for: Usher.playlistRequest(url, timeout: 8))
      guard response.statusCode == 200 else { return .failure(response.statusCode) }
      guard HLS.looksLikePlaylist(data), let text = String(data: data, encoding: .utf8) else { return .failure(502) }
      return .success(HLSMediaPlaylist.parse(text, base: response.url ?? url))
    } catch {
      return .failure(504)
    }
  }
}
