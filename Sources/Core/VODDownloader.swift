// Downloading a VOD to the iPhone: every segment of one rendition, saved with a playlist of its
// own, so it plays like a recording (it's listed with them) with no connection at all. It can be
// watched while it downloads (the playlist grows), and stopping keeps what's been saved.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

actor VODDownloader {
  nonisolated let id: String
  private let directory: URL
  private var info: RecordingInfo
  /// The rendition's media playlist on Twitch.
  private let playlistURL: URL
  private let http: HTTPClient
  private let log: ActivityLog
  /// Each change, with how much is done (0…1).
  private let onStatus: @Sendable (RecorderStatus, Double) -> Void

  private var entries: [(file: String, duration: Double, discontinuity: Bool, map: String?)] = []
  private var maps: [String: String] = [:]
  private var task: Task<Void, Never>?
  private var finished = false

  /// Segments fetched at once (a few, so a long VOD comes down quickly without hogging the
  /// connection).
  static let parallel = 4

  init(
    info: RecordingInfo, playlistURL: URL, directory: URL, http: HTTPClient, log: ActivityLog = .shared,
    onStatus: @escaping @Sendable (RecorderStatus, Double) -> Void
  ) {
    id = info.id
    self.info = info
    self.playlistURL = playlistURL
    self.directory = directory
    self.http = http
    self.log = log
    self.onStatus = onStatus
  }

  func start() {
    guard task == nil else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    StreamRecorder.save(info, in: directory)
    task = Task { [weak self] in await self?.run() }
  }

  /// Stopped by hand: what's saved stays, as a shorter video.
  func stop() {
    task?.cancel()
    finish(entries.isEmpty ? "Stopped" : "Stopped part way")
  }

  private func run() async {
    onStatus(RecorderStatus(state: .starting, info: info), 0)
    guard let text = await Self.fetchText(playlistURL, http: http) else {
      finish("Couldn't reach Twitch")
      return
    }
    // Absolute addresses, and muted parts under the names Twitch actually serves.
    let playlist = HLSMediaPlaylist.parse(VODPlaylists.rewrite(text, base: playlistURL), base: playlistURL)
    let segments = playlist.regularSegments
    guard !segments.isEmpty else {
      finish("Nothing to download")
      return
    }
    log.add("Downloading \(info.channelName)'s video (\(segments.count) parts, \(info.quality))")
    var index = 0
    var pendingGap = false
    var lastWrite = Date.distantPast
    while index < segments.count, !finished, !Task.isCancelled {
      let batch = Array(segments[index..<min(index + Self.parallel, segments.count)])
      index += batch.count
      let results = await withTaskGroup(of: (Int, Data?).self) { group -> [Int: Data] in
        for (position, segment) in batch.enumerated() {
          group.addTask { [http] in (position, await Self.download(segment.uri, http: http)) }
        }
        var out: [Int: Data] = [:]
        for await (position, data) in group { if let data { out[position] = data } }
        return out
      }
      guard !finished, !Task.isCancelled else { break }
      for (position, segment) in batch.enumerated() {
        guard let data = results[position] else {
          // Couldn't be fetched: a jump in the video rather than giving up on the rest.
          if !pendingGap, !entries.isEmpty { info.gaps += 1 }
          pendingGap = true
          continue
        }
        var mapFile: String?
        if let map = segment.map {
          mapFile = await saveMap(map)
          if mapFile == nil {
            pendingGap = true
            continue
          }
        }
        let file = String(format: "%06d", entries.count + 1) + "." + (mapFile == nil ? "ts" : "m4s")
        do {
          try data.write(to: directory.appendingPathComponent(file))
        } catch {
          finish("Couldn't save (is the phone full?)")
          return
        }
        let previousMap = entries.last?.map
        entries.append(
          (file, segment.duration, pendingGap || segment.discontinuity || (mapFile != nil && mapFile != previousMap), mapFile))
        pendingGap = false
        info.duration += segment.duration
        info.bytes += Int64(data.count)
      }
      // The playlist grows as it goes (watchable already), written now and then, not per part.
      if Date().timeIntervalSince(lastWrite) > 5 {
        lastWrite = Date()
        writePlaylist(ended: false)
        StreamRecorder.save(info, in: directory)
      }
      onStatus(RecorderStatus(state: .recording, info: info), Double(index) / Double(segments.count))
    }
    if !finished {
      finish(playlist.isEnded ? "Downloaded" : "Downloaded (it was still being recorded)")
    }
  }

  private func finish(_ reason: String) {
    guard !finished else { return }
    finished = true
    info.endedAt = Date()
    info.endReason = reason
    writePlaylist(ended: true)
    StreamRecorder.save(info, in: directory)
    log.add("Download of \(info.channelName)'s video: \(reason.lowercased())")
    onStatus(RecorderStatus(state: .ended, info: info), 1)
  }

  private func writePlaylist(ended: Bool) {
    try? StreamRecorder.playlistText(entries: entries, ended: ended)
      .write(to: directory.appendingPathComponent(StreamRecorder.playlistName), atomically: true, encoding: .utf8)
  }

  private func saveMap(_ remote: String) async -> String? {
    if let saved = maps[remote] { return saved }
    guard let data = await Self.download(remote, http: http) else { return nil }
    let file = "init-\(maps.count + 1).mp4"
    guard (try? data.write(to: directory.appendingPathComponent(file))) != nil else { return nil }
    maps[remote] = file
    return file
  }

  private static func fetchText(_ url: URL, http: HTTPClient) async -> String? {
    guard let data = await download(url.absoluteString, http: http) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func download(_ uri: String, http: HTTPClient) async -> Data? {
    guard let url = URL(string: uri) else { return nil }
    for attempt in 0..<3 {
      if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000) }
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
      request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
      if let (data, response) = try? await http.data(for: request), response.statusCode == 200, !data.isEmpty {
        return data
      }
      if Task.isCancelled { return nil }
    }
    return nil
  }
}
