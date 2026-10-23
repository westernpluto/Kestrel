// Playlists for the low-latency player (Amazon IVS). Twitch's playlists go through the local
// server almost untouched, so Twitch's low-latency tags survive, but:
//  - ad markers are removed, so nothing in the player can act on them;
//  - while an ad is stitched into the video itself, the playlist of an ad-free copy of the stream
//    is served instead (the TwitchAdSolutions/vaft technique);
//  - if no copy is ad-free, the ad is served without low-latency prefetch and the app hides it.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct LowLatencyConfig: Sendable {
  var codecs = "h264"
  var backupStreams = true
  var allowLowQualityBackup = true
  var mainPlayerType = "popout"
  var backupPlayerTypes = ["site", "popout", "mobile_web", "embed"]
  /// How long the first playlist of an ad break may wait for an ad-free copy.
  var firstPollWait: TimeInterval = 1.5
  var searchDeadline: TimeInterval = 4
  var backupTokenLifetime: TimeInterval = 8 * 60
  /// Ad-free playlist proxies to try first (see AdFreeProxy).
  var adFreeProxies: [String] = []
  /// Signed in: ask Twitch first and play straight from it when it shows this account no ads.
  var checkAccountFirst = false
}

struct LowLatencyUpdate: Sendable {
  var state: AdState
  /// Stitched ads the player was given (only when no ad-free copy was found).
  var ads: AdTimeline
}

actor LowLatencySession: PlaylistSource {
  nonisolated let id: String
  nonisolated let login: String
  private let config: LowLatencyConfig
  private let http: HTTPClient
  private let tokens: PlaybackTokenProvider
  private let log: ActivityLog
  private let onUpdate: @Sendable (LowLatencyUpdate) -> Void

  private var masterText = ""
  /// The ad-free proxy that delivered this stream, if any.
  private(set) var route: StreamRoute = .twitch
  /// Index i is served as `v/i.m3u8` (portrait renditions removed).
  private(set) var variants: [HLSVariant] = []
  private var lastServed: [Int: String] = [:]

  private var inBreak = false
  private var breakStart = Date.distantPast
  private var breakID = 0
  private var markerBreak = false
  private var markerStart = Date.distantPast
  private var active: StreamSession.BackupMaster?
  private var backupMasters: [String: StreamSession.BackupMaster] = [:]
  private var contaminated: Set<String> = []
  private var pinnedType: String?
  private var searchTask: Task<Void, Never>?
  private var searchSignal = OneShotSignal()
  private var lastSearchEnd = Date.distantPast
  private var state: AdState = .none
  private var ads = AdTimeline()

  init(
    id: String = UUID().uuidString, login: String, config: LowLatencyConfig, http: HTTPClient,
    tokens: PlaybackTokenProvider, log: ActivityLog = .shared,
    onUpdate: @escaping @Sendable (LowLatencyUpdate) -> Void = { _ in }
  ) {
    self.id = id
    self.login = login.lowercased()
    self.config = config
    self.http = http
    self.tokens = tokens
    self.log = log
    self.onUpdate = onUpdate
  }

  // MARK: - Start

  /// Fetches the master playlist. Returns Twitch's renditions (landscape and audio only).
  func start() async throws -> [HLSVariant] {
    let fetched = try await MasterPlaylistFetch.fetch(
      login: login, codecs: config.codecs, lowLatency: true, proxies: config.adFreeProxies,
      checkAccountFirst: config.checkAccountFirst, playerType: config.mainPlayerType, http: http, tokens: tokens, log: log)
    route = fetched.route
    let text = fetched.text
    let base = fetched.url
    var lines: [String] = []
    var pending: HLSVariant?
    var pendingLine = ""
    var found: [HLSVariant] = []
    for raw in HLS.lines(text) {
      let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
      if line.hasPrefix("#EXT-X-STREAM-INF") {
        // Parse this one rendition with the regular parser (it knows the portrait/audio rules).
        let single = HLSMaster.parse(line + "\nplaceholder.m3u8", base: nil).variants.first
        pending = single
        pendingLine = line
      } else if !line.hasPrefix("#"), !line.trimmingCharacters(in: .whitespaces).isEmpty, var variant = pending {
        pending = nil
        guard !variant.isPortrait else { continue }
        variant.uri = HLS.resolve(Substring(line), base: base)
        lines.append(pendingLine)
        lines.append("v/\(found.count).m3u8")
        found.append(variant)
      } else if !line.hasPrefix("#EXT-X-STREAM-INF") {
        lines.append(LowLatencyPlaylist.absolutizeTag(line, base: base))
      }
    }
    guard found.contains(where: { !$0.isAudioOnly }) else { throw StreamSession.StartError.noVariants }
    variants = found
    masterText = lines.joined(separator: "\n") + "\n"
    let labels = found.filter { !$0.isAudioOnly }.sorted { $0.height > $1.height }.map(\.label)
    log.add("Low-latency player: \(login) (Twitch offers \(labels.joined(separator: ", ")))")
    return found
  }

  func masterPlaylist(only: Int?) -> String { masterText }

  // MARK: - Media playlists

  func mediaPlaylist(_ index: Int) async -> (status: Int, body: String) {
    guard index >= 0, index < variants.count else { return (404, "") }
    let target = variants[index]
    let main: (text: String, url: URL, playlist: HLSMediaPlaylist)
    switch await fetch(URL(string: target.uri)) {
    case .success(let result):
      main = result
    case .failure(let status):
      // A hiccup upstream: repeat the last playlist. 404/403 mean the stream or token is gone.
      if status != 404, status != 403, let last = lastServed[index] { return (200, last) }
      return (status, "")
    }

    if main.playlist.isClean {
      if inBreak { endBreak() }
      let marker = main.playlist.adMarkerActive
      noteMarkers(marker)
      if marker, config.backupStreams { prewarm(target: target) }
      // While Twitch announces an ad break, hold back the segment it's still producing: if the ad
      // gets stitched in, that segment would be ad video the player shows before Kestrel can
      // tell (costs ~2 s of latency during the break, saves the ad flash).
      return serve(index, LowLatencyPlaylist.filter(main.text, base: main.url, dropPrefetch: marker))
    }

    // Ad video stitched into the stream.
    let firstPoll = !inBreak
    if firstPoll { beginBreak() }
    if config.backupStreams {
      if active == nil {
        startSearchIfNeeded(target: target)
        if firstPoll { await searchSignal.wait(timeout: config.firstPollWait) }
      }
      if let backup = active, let match = backup.master.bestMatch(for: target) {
        switch await fetch(URL(string: match.uri)) {
        case .success(let copy) where copy.playlist.isClean && !copy.playlist.regularSegments.isEmpty:
          ads.closeOpenBreak()
          publish(.replaced("\(backup.type) · \(match.label)"))
          return serve(index, LowLatencyPlaylist.filter(copy.text, base: copy.url, dropPrefetch: false))
        case .success:
          log.add("Ad-free copy (\(backup.type)) started showing ads, looking for another")
          contaminated.insert(backup.type)
          active = nil
          startSearchIfNeeded(target: target)
        case .failure:
          log.add("Ad-free copy (\(backup.type)) stopped responding, looking for another")
          active = nil
          startSearchIfNeeded(target: target)
        }
      }
    }
    // No ad-free copy (yet): give the player the ad, without prefetch so it can't run ahead into
    // it, and let the app hide it.
    ads.update(with: main.playlist)
    publish(.covering)
    return serve(index, LowLatencyPlaylist.filter(main.text, base: main.url, dropPrefetch: true))
  }

  private func serve(_ index: Int, _ body: String) -> (status: Int, body: String) {
    lastServed[index] = body
    return (200, body)
  }

  // MARK: - Ad breaks

  private func beginBreak() {
    inBreak = true
    breakID += 1
    breakStart = Date()
    contaminated = []
    active = nil
    lastSearchEnd = .distantPast
    log.add("Ad stitched into \(login)'s stream, looking for an ad-free copy")
    publish(config.backupStreams ? .searching : .covering)
  }

  private func endBreak() {
    inBreak = false
    breakID += 1
    active = nil
    searchTask?.cancel()
    searchTask = nil
    log.add("Stitched ad over after \(Int(Date().timeIntervalSince(breakStart).rounded()))s")
    ads.closeOpenBreak()
    publish(.none)
  }

  private func noteMarkers(_ markerActive: Bool) {
    if markerActive, !markerBreak {
      markerBreak = true
      markerStart = Date()
      log.add("Ad break on \(login): Twitch sends this ad to its own player, so it's skipped")
      publish(.skipped)
    } else if !markerActive, markerBreak {
      markerBreak = false
      log.add("Ad break over after \(Int(Date().timeIntervalSince(markerStart).rounded()))s (skipped)")
      publish(.none)
    } else if !markerActive, state != .none {
      publish(.none)
    }
  }

  private func publish(_ newState: AdState) {
    state = newState
    onUpdate(LowLatencyUpdate(state: newState, ads: ads))
  }

  private func playerTypes() -> [String] {
    var types = config.backupPlayerTypes
    if let pinned = pinnedType, let i = types.firstIndex(of: pinned) {
      types.remove(at: i)
      types.insert(pinned, at: 0)
    }
    if config.allowLowQualityBackup { types.append("autoplay") }
    let usable = types.filter { !contaminated.contains($0) }
    return usable.isEmpty ? types : usable
  }

  private var prewarmTask: Task<Void, Never>?

  /// Fetches ad-free-copy candidates ahead of a possible stitched ad, so the switch is instant.
  private func prewarm(target: HLSVariant) {
    guard prewarmTask == nil, backupMasters.isEmpty || backupMasters.values.allSatisfy({
      Date().timeIntervalSince($0.fetchedAt) > config.backupTokenLifetime
    })
    else { return }
    let types = playerTypes()
    prewarmTask = Task { [weak self] in
      guard let self else { return }
      let results = await self.probeAll(types: types, target: target, cached: [:])
      await self.storePrewarmed(results.values.compactMap(\.master))
    }
  }

  private func storePrewarmed(_ masters: [StreamSession.BackupMaster]) {
    prewarmTask = nil
    for master in masters { backupMasters[master.type] = master }
  }

  private func startSearchIfNeeded(target: HLSVariant) {
    guard searchTask == nil, inBreak, active == nil else { return }
    if Date().timeIntervalSince(lastSearchEnd) < 6 { return }
    let types = playerTypes()
    let cached = backupMasters
    let breakID = self.breakID
    let signal = OneShotSignal()
    searchSignal = signal
    searchTask = Task { [weak self] in
      guard let self else { return }
      let started = Date()
      let results = await self.probeAll(types: types, target: target, cached: cached)
      await self.finishSearch(results, types: types, target: target, breakID: breakID, started: started)
      signal.fire()
    }
  }

  private func finishSearch(
    _ results: [Int: (type: String, master: StreamSession.BackupMaster?, clean: Bool, failure: String?)], types: [String],
    target: HLSVariant, breakID: Int, started: Date
  ) {
    searchTask = nil
    lastSearchEnd = Date()
    for result in results.values { if let master = result.master { backupMasters[result.type] = master } }
    guard breakID == self.breakID, inBreak else { return }
    if let winner = types.indices.compactMap({ results[$0] }).first(where: { $0.clean }), let master = winner.master {
      active = master
      if winner.type != "autoplay" { pinnedType = winner.type }
      let label = master.master.bestMatch(for: target)?.label ?? "?"
      log.add("Switched to ad-free copy (\(winner.type), \(label)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    } else {
      for result in results.values where !result.clean && result.failure == nil { contaminated.insert(result.type) }
      let tried = types.indices.map { i -> String in
        guard let r = results[i] else { return "\(types[i]) (timeout)" }
        return r.clean ? r.type : "\(r.type) (\(r.failure ?? "ads"))"
      }
      log.add("No ad-free copy found (tried \(tried.joined(separator: ", "))); hiding the ad")
    }
  }

  private nonisolated func probeAll(
    types: [String], target: HLSVariant, cached: [String: StreamSession.BackupMaster]
  ) async -> [Int: (type: String, master: StreamSession.BackupMaster?, clean: Bool, failure: String?)] {
    typealias Result = (type: String, master: StreamSession.BackupMaster?, clean: Bool, failure: String?)
    let deadline = config.searchDeadline
    return await withTaskGroup(of: (Int, Result?).self) { group -> [Int: Result] in
      for (i, type) in types.enumerated() {
        group.addTask { (i, await self.probe(type: type, target: target, cached: cached[type])) }
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
        return (-1, nil)
      }
      var results: [Int: Result] = [:]
      var deadlineHit = false
      for await (i, result) in group {
        if i < 0 { deadlineHit = true } else if let result { results[i] = result }
        // The first clean copy in priority order wins once everything ahead of it has answered.
        var decided = deadlineHit || results.count == types.count
        for j in types.indices {
          guard let r = results[j] else { break }
          if r.clean {
            decided = true
            break
          }
        }
        if decided {
          group.cancelAll()
          break
        }
      }
      return results
    }
  }

  private nonisolated func probe(type: String, target: HLSVariant, cached: StreamSession.BackupMaster?) async
    -> (type: String, master: StreamSession.BackupMaster?, clean: Bool, failure: String?)
  {
    var master = cached
    if let cached, Date().timeIntervalSince(cached.fetchedAt) >= config.backupTokenLifetime { master = nil }
    if master == nil {
      do {
        let token = try await tokens.streamToken(login: login, playerType: type, platform: type == "autoplay" ? "android" : "web")
        let url = Usher.live(login: login, token: token, codecs: config.codecs, lowLatency: true)
        let (data, response) = try await http.data(for: Usher.playlistRequest(url, timeout: 5))
        guard response.statusCode == 200, let text = String(data: data, encoding: .utf8), HLS.looksLikePlaylist(data) else {
          return (type, nil, false, "HTTP \(response.statusCode)")
        }
        master = StreamSession.BackupMaster(type: type, master: HLSMaster.parse(text, base: response.url ?? url), fetchedAt: Date())
      } catch {
        return (type, nil, false, "failed")
      }
    }
    guard let master, let match = master.master.bestMatch(for: target) else { return (type, master, false, "no match") }
    switch await fetch(URL(string: match.uri)) {
    case .success(let copy): return (type, master, copy.playlist.isClean && !copy.playlist.regularSegments.isEmpty, nil)
    case .failure(let status): return (type, master, false, "HTTP \(status)")
    }
  }

  // MARK: - Networking

  private enum FetchResult {
    case success((text: String, url: URL, playlist: HLSMediaPlaylist))
    case failure(Int)
  }

  private nonisolated func fetch(_ url: URL?) async -> FetchResult {
    guard let url else { return .failure(404) }
    do {
      let (data, response) = try await http.data(for: Usher.playlistRequest(url, timeout: 5))
      guard response.statusCode == 200 else { return .failure(response.statusCode) }
      guard HLS.looksLikePlaylist(data), let text = String(data: data, encoding: .utf8) else { return .failure(502) }
      let base = response.url ?? url
      return .success((text, base, HLSMediaPlaylist.parse(text, base: base)))
    } catch {
      return .failure(504)
    }
  }
}

/// Rewriting Twitch media playlists for the low-latency player.
enum LowLatencyPlaylist {
  /// Removes ad markers (and optionally the prefetch hints) and makes every URI absolute, since
  /// the player loads this playlist from the local server.
  static func filter(_ text: String, base: URL?, dropPrefetch: Bool) -> String {
    var output: [String] = []
    for raw in HLS.lines(text) {
      let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
      if line.hasPrefix("#") {
        if isAdTag(line) { continue }
        if line.hasPrefix("#EXT-X-TWITCH-PREFETCH:") {
          if dropPrefetch { continue }
          output.append("#EXT-X-TWITCH-PREFETCH:" + HLS.resolve(line.dropFirst("#EXT-X-TWITCH-PREFETCH:".count), base: base))
          continue
        }
        output.append(absolutizeTag(line, base: base))
      } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
        output.append(line)
      } else {
        output.append(HLS.resolve(Substring(line), base: base))
      }
    }
    return output.joined(separator: "\n") + "\n"
  }

  /// Tags that announce, describe or track ads.
  static func isAdTag(_ line: String) -> Bool {
    if line.hasPrefix("#EXT-X-CUE") || line.hasPrefix("#EXT-X-SCTE35") || line.hasPrefix("#EXT-OATCLS-SCTE35")
      || line.hasPrefix("#EXT-X-ASSET")
    {
      return true
    }
    guard line.hasPrefix("#EXT-X-DATERANGE") else { return false }
    let lower = line.lowercased()
    if lower.contains("stitched") || lower.contains("twitch-maf-ad") || lower.contains("x-tv-twitch-ad")
      || lower.contains("twitch-ad") || lower.contains("scte35")
    {
      return true
    }
    // IVS-style source switches to an ad ("live" is the broadcast itself).
    return lower.contains("live-video-net-stream-source") && !lower.contains("stream-source=\"live\"")
  }

  /// `URI="…"` attributes made absolute.
  static func absolutizeTag(_ line: String, base: URL?) -> String {
    guard let range = line.range(of: "URI=\""), let end = line[range.upperBound...].firstIndex(of: "\"") else { return line }
    let uri = line[range.upperBound..<end]
    return line.replacingCharacters(in: range.upperBound..<end, with: HLS.resolve(uri, base: base))
  }
}
