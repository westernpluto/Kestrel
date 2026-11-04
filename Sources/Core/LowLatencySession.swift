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
  /// Through an ad-free server: try the playlists on Twitch's server near the viewer.
  var nearbyServers = true
  /// Play straight from Twitch (its renditions for this viewer, 1440p included, and a quick
  /// start) and use the ad-free servers only for a copy of the stream during a stitched ad
  /// (asked first among the copies). Off: the stream comes through an ad-free server throughout.
  var adFreeServersForAdsOnly = false
}

struct LowLatencyUpdate: Sendable {
  var state: AdState
  /// Stitched ads the player was given (only when no ad-free copy was found).
  var ads: AdTimeline
}

actor LowLatencySession: PlaylistSource {
  nonisolated let id: String
  nonisolated let login: String
  /// Whether the stream is still coming in (the player asks; see StreamArrival).
  nonisolated let arrival = StreamArrival()
  private let config: LowLatencyConfig
  private let http: HTTPClient
  private let tokens: PlaybackTokenProvider
  private let log: ActivityLog
  private let onUpdate: @Sendable (LowLatencyUpdate) -> Void

  private var masterText = ""
  /// When the master playlist came from Twitch (its clock is moved on by the time since, see
  /// `LowLatencyPlaylist.advancingClock`).
  private var masterFetchedAt = Date()
  /// The ad-free proxy that delivered this stream, if any.
  private(set) var route: StreamRoute = .twitch
  /// Index i is served as `v/i.m3u8` (portrait renditions removed).
  private(set) var variants: [HLSVariant] = []
  /// Playing from Twitch's playlist server near the viewer instead of the one near the ad-free
  /// server: the ad-free server's addresses, to go back to (see `NearbyPlaylists`).
  private var farVariants: [HLSVariant]?
  /// The playlist server in use.
  private(set) var servingHost: String?
  /// Whether that's Twitch's server near the viewer, used instead of the ad-free server's.
  var servingNearby: Bool { farVariants != nil }
  private var lastServed: [Int: String] = [:]
  /// The segment addresses in the last playlist served for each rendition.
  private var servedURIs: [Int: Set<String>] = [:]

  private var inBreak = false
  /// This break's ad-free copy is already being served.
  private var replacedInBreak = false
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
      login: login, codecs: config.codecs, lowLatency: true, proxies: config.adFreeServersForAdsOnly ? [] : config.adFreeProxies,
      checkAccountFirst: config.checkAccountFirst, playerType: config.mainPlayerType, http: http, tokens: tokens, log: log)
    masterFetchedAt = Date()
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
    guard let first = found.firstIndex(where: { !$0.isAudioOnly }) else { throw StreamSession.StartError.noVariants }
    variants = found
    masterText = lines.joined(separator: "\n") + "\n"
    let farHost = URL(string: found[first].uri)?.host
    servingHost = farHost
    if case .adFreeServer = route, config.nearbyServers, let near = fetched.nearbyHost, let farHost, near != farHost,
      NearbyPlaylists.isTwitchPlaylistHost(farHost), NearbyPlaylists.worthTrying(near)
    {
      await tryNearby(near, far: farHost, first: first)
    }
    if warmed == nil {
      // Ask for the first rendition's playlist now, while the player is still being set up: the
      // connection to Twitch's playlist server is open by the time the player wants it, and its
      // first playlist is (nearly) ready, so the video starts sooner.
      let url = URL(string: variants[first].uri)
      warmed = (first, Task { await self.fetch(url) }, Date())
    }
    let labels = found.filter { !$0.isAudioOnly }.sorted { $0.height > $1.height }.map(\.label)
    let server = servingHost.map { " via \(Self.serverName(host: $0))" } ?? ""
    log.add("Low-latency player: \(login) (Twitch offers \(labels.joined(separator: ", "))\(server))")
    return variants
  }

  /// Tries the stream's playlists on Twitch's server near the viewer (see `NearbyPlaylists`):
  /// kept if that server hands over the first rendition's playlist, clean of ads.
  private func tryNearby(_ near: String, far: String, first: Int) async {
    let nearVariants = variants.map { variant -> HLSVariant in
      var copy = variant
      copy.uri = NearbyPlaylists.replacingHost(variant.uri, with: near)
      return copy
    }
    let started = Date()
    let probe = await fetch(URL(string: nearVariants[first].uri), timeout: 2)
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    switch probe {
    case .success(let result) where result.playlist.isClean && !result.playlist.regularSegments.isEmpty:
      farVariants = variants
      variants = nearVariants
      servingHost = near
      warmed = (first, Task { probe }, Date())
      log.add(
        "Playlists from Twitch's server near you (\(Self.serverName(host: near))) instead of the ad-free server's (\(Self.serverName(host: far))), checked in \(ms) ms"
      )
    case .success:
      log.add("Twitch's server near you (\(Self.serverName(host: near))) showed an ad; staying on \(Self.serverName(host: far))")
    case .failure(let status):
      if status == 403 || status == 404 || status == 400 { NearbyPlaylists.refused(near) }
      log.add("Twitch's server near you (\(Self.serverName(host: near))) didn't take this stream (HTTP \(status)); staying on \(Self.serverName(host: far))")
    }
  }

  /// Back to the ad-free server's playlist server for the rest of the stream.
  private func leaveNearby(_ reason: String) {
    guard let far = farVariants else { return }
    variants = far
    farVariants = nil
    servingHost = far.first.flatMap { URL(string: $0.uri)?.host }
    log.add("Back to the ad-free server's playlist server (\(reason))")
  }

  /// The first rendition's playlist, asked for at the start (see `start`).
  private var warmed: (index: Int, task: Task<FetchResult, Never>, startedAt: Date)?

  /// Which of Twitch's playlist servers this is: `euc13` for `euc13.playlist.ttvnw.net`, `fra05`
  /// for `video-weaver.fra05.hls.ttvnw.net`, else the host.
  static func serverName(host: String) -> String {
    let parts = host.split(separator: ".")
    if parts.count > 2, parts[0].hasPrefix("video-weaver") { return String(parts[1]) }
    if parts.count > 3, NearbyPlaylists.isTwitchPlaylistHost(host) { return String(parts[0]) }
    return host
  }

  func masterPlaylist(only: Int?) -> String {
    LowLatencyPlaylist.advancingClock(masterText, by: Date().timeIntervalSince(masterFetchedAt))
  }

  // MARK: - Media playlists

  func mediaPlaylist(_ index: Int) async -> (status: Int, body: String) {
    guard index >= 0, index < variants.count else { return (404, "") }
    arrival.asked()
    var target = variants[index]
    var fetched: FetchResult
    if let warm = warmed, warm.index == index, Date().timeIntervalSince(warm.startedAt) < 1 {
      // The player's first request, while the early one is in flight or only just back.
      warmed = nil
      fetched = await warm.task.value
    } else {
      warmed = nil
      fetched = await fetch(URL(string: target.uri))
    }
    // On Twitch's server near the viewer: if it turns the stream away or shows an ad, go back to
    // the ad-free server's for good.
    if servingNearby {
      var problem: String?
      switch fetched {
      case .failure(let status) where status == 403 || status == 404 || status == 400: problem = "HTTP \(status)"
      case .success(let result) where !result.playlist.isClean: problem = "it showed an ad"
      default: break
      }
      if let problem, servingNearby, index < variants.count {
        if problem.hasPrefix("HTTP"), let host = servingHost { NearbyPlaylists.refused(host) }
        leaveNearby("the one near you: \(problem)")
        target = variants[index]
        fetched = await fetch(URL(string: target.uri))
      }
    }
    let main: (text: String, url: URL, playlist: HLSMediaPlaylist)
    switch fetched {
    case .success(let result):
      main = result
      arrival.saw(index: index, end: result.playlist.mediaSequence + result.playlist.regularSegments.count)
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
      // The segment still being made is handed over during an announced break too. Holding it back
      // (in case an ad got stitched into it) made the player run dry at every break, stall, fall
      // ~2 s behind and catch up after, and the breaks seen are Twitch's own-player ones, clean.
      // If an ad is stitched in after all, what the player was already handed of it is covered
      // when it plays (see below: the player is about a second behind, so the cover is known in
      // time).
      let body = LowLatencyPlaylist.filter(main.text, base: main.url, dropPrefetch: false)
      return serve(index, body)
    }

    // Ad video stitched into the stream. Where it sits in time is noted straight away: the
    // player may already have some of it (the segment being made when the ad began), and that
    // part needs hiding even when an ad-free copy takes over at once.
    // Only until the player is on the ad-free copy: after that it gets no more of the ad, and
    // noting the rest of the break covered clean video ("Skipping an ad…" over the stream).
    let firstPoll = !inBreak
    if firstPoll { beginBreak() }
    if !replacedInBreak {
      // Only ad segments the player was already handed (in the last playlist it got, a prefetch
      // most likely) need hiding. At the start of a stream the player had none of the ad, and
      // covering the whole break's times put "Skipping an ad" over the clean copy for seconds.
      let handed = servedURIs[index] ?? []
      ads.cover(main.playlist.segments.filter { $0.isAd && handed.contains($0.uri) })
    }
    if config.backupStreams {
      if active == nil {
        startSearchIfNeeded(target: target)
        if firstPoll { await searchSignal.wait(timeout: config.firstPollWait) }
      }
      if let backup = active, let match = backup.master.bestMatch(for: target) {
        switch await fetch(URL(string: match.uri)) {
        case .success(let copy) where copy.playlist.isClean && !copy.playlist.regularSegments.isEmpty:
          ads.closeOpenBreak()
          replacedInBreak = true
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
    servedURIs[index] = Set(HLSMediaPlaylist.parse(body, base: nil).segments.map(\.uri))
    return (200, body)
  }

  // MARK: - Ad breaks

  private func beginBreak() {
    inBreak = true
    replacedInBreak = false
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
    if config.adFreeServersForAdsOnly {
      // The ad-free servers' copies first (in a country without these ads), then Twitch's other
      // player types.
      types = config.adFreeProxies.prefix(2).map { Self.proxyPrefix + $0 } + types
    }
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

  static let proxyPrefix = "server:"

  private nonisolated func probe(type: String, target: HLSVariant, cached: StreamSession.BackupMaster?) async
    -> (type: String, master: StreamSession.BackupMaster?, clean: Bool, failure: String?)
  {
    var master = cached
    if let cached, Date().timeIntervalSince(cached.fetchedAt) >= config.backupTokenLifetime { master = nil }
    if master == nil, type.hasPrefix(Self.proxyPrefix) {
      // An ad-free server's copy of the stream.
      let host = String(type.dropFirst(Self.proxyPrefix.count))
      guard let url = AdFreeProxy.masterURL(host: host, login: login, codecs: config.codecs, lowLatency: true) else {
        return (type, nil, false, "bad address")
      }
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
      request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
      guard let (data, response) = try? await http.data(for: request), response.statusCode == 200,
        let text = String(data: data, encoding: .utf8), HLS.looksLikePlaylist(data), text.contains("#EXT-X-STREAM-INF")
      else { return (type, nil, false, "no answer") }
      master = StreamSession.BackupMaster(type: type, master: HLSMaster.parse(text, base: response.url ?? url), fetchedAt: Date())
    }
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

  private nonisolated func fetch(_ url: URL?, timeout: TimeInterval = 5) async -> FetchResult {
    guard let url else { return .failure(404) }
    do {
      let (data, response) = try await http.data(for: Usher.playlistRequest(url, timeout: timeout))
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

  /// Twitch's master playlist says what its clock read when it was made (`SERVER-TIME`) and how
  /// far into the broadcast that was (`STREAM-TIME`), in `#EXT-X-TWITCH-INFO`. The player sets its
  /// idea of "now", and so the latency it reports, from them. Served later than it was fetched,
  /// they're moved on by the time since: served unchanged minutes later (to start over at the
  /// live edge), the player thought it was ahead of live and reported no latency at all.
  static func advancingClock(_ master: String, by seconds: TimeInterval) -> String {
    guard seconds > 0.01, master.contains("#EXT-X-TWITCH-INFO") else { return master }
    var lines = master.components(separatedBy: "\n")
    for index in lines.indices where lines[index].hasPrefix("#EXT-X-TWITCH-INFO") {
      lines[index] = advance("SERVER-TIME", in: lines[index], by: seconds)
      lines[index] = advance("STREAM-TIME", in: lines[index], by: seconds)
    }
    return lines.joined(separator: "\n")
  }

  private static func advance(_ attribute: String, in line: String, by seconds: TimeInterval) -> String {
    guard let start = line.range(of: attribute + "=\""), let end = line[start.upperBound...].firstIndex(of: "\""),
      let value = Double(line[start.upperBound..<end])
    else { return line }
    let old = line[start.upperBound..<end]
    let decimals = old.firstIndex(of: ".").map { old.distance(from: $0, to: old.endIndex) - 1 } ?? 0
    let moved = String(format: "%.\(min(max(decimals, 2), 9))f", value + seconds)
    return line.replacingCharacters(in: start.upperBound..<end, with: moved)
  }

  /// `URI="…"` attributes made absolute.
  static func absolutizeTag(_ line: String, base: URL?) -> String {
    guard let range = line.range(of: "URI=\""), let end = line[range.upperBound...].firstIndex(of: "\"") else { return line }
    let uri = line[range.upperBound..<end]
    return line.replacingCharacters(in: range.upperBound..<end, with: HLS.resolve(uri, base: base))
  }
}
