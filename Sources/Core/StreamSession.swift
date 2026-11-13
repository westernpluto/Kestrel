// One live playback. Serves the master + media playlists AVPlayer asks the local proxy for,
// and keeps ads out of them. Technique (backup access tokens with other player types, ad
// markers) follows TwitchAdSolutions/vaft and streamlink, adapted to a native HLS player.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum AdFallback: String, CaseIterable, Sendable {
  /// Let the ad through but mute it and cover the picture.
  case muteAndCover
  /// Hold the picture until real content returns (can stall on long breaks).
  case wait
}

struct StreamSessionConfig: Sendable {
  /// Hand AVPlayer the segment Twitch is still producing. Off by default: AVPlayer stalls on
  /// segments that download in real time.
  var lowLatency = false
  /// Ask Twitch for its low-latency playlist (`fast_bread`): complete segments show up sooner.
  var fastBread = true
  var backupStreams = true
  var allowLowQualityBackup = true
  var fallback: AdFallback = .muteAndCover
  var codecs = "h264"
  var mainPlayerType = "popout"
  var backupPlayerTypes = ["site", "popout", "mobile_web", "embed"]
  /// How long the first playlist of an ad break may wait for an ad-free copy.
  var firstPollWait: TimeInterval = 1.2
  /// After this long without an ad-free copy, use the fallback.
  var fallbackGrace: TimeInterval = 3
  var searchDeadline: TimeInterval = 4
  var backupTokenLifetime: TimeInterval = 8 * 60
  /// Ad-free playlist proxies to try first (see AdFreeProxy).
  var adFreeProxies: [String] = []
  /// Signed in: ask Twitch first and play straight from it when it shows this account no ads.
  var checkAccountFirst = false
}

enum AdState: Equatable, Sendable {
  case none
  /// Client-side ad break: Twitch would play an ad in its own player; the stream itself is clean.
  case skipped
  case searching
  case replaced(String)  // "site · 720p60"
  case covering
}

struct StreamInfo: Sendable {
  var variants: [HLSVariant]  // served order: video variants best first, then audio-only
}

actor StreamSession {
  nonisolated let id: String
  nonisolated let login: String
  private let config: StreamSessionConfig
  private let http: HTTPClient
  /// For the media playlists (and video), when not `http`: with the user's own proxy, only the token
  /// and the stream's address need to go through it (where Twitch decides about ads); the
  /// playlists, asked for every second or so for as long as it plays, go straight.
  private let mediaHTTP: HTTPClient
  private let tokens: PlaybackTokenProvider
  private let log: ActivityLog
  private let onAdState: @Sendable (AdState, [ClosedRange<Date>]) -> Void

  private var served: [HLSVariant] = []
  /// Where the master playlist came from.
  private(set) var route: StreamRoute = .twitch
  private var timeline = SlotTimeline()
  private var mainStores: [Int: SegmentStore] = [:]
  private var backupStores: [Int: [String: SegmentStore]] = [:]
  private var targetDuration: Int?

  // Ad break state
  private var inBreak = false
  private var breakID = 0
  private var breakStart = Date.distantPast
  private var committed: BackupMaster?
  private var contaminated: Set<String> = []
  private var pinnedType: String?
  private var searchTask: Task<Void, Never>?
  private var searchSignal = OneShotSignal()
  private var lastSearchEnd = Date.distantPast
  private var backupMasters: [String: BackupMaster] = [:]
  private var breakSummary = ""
  private var adState: AdState = .none

  struct BackupMaster: Sendable {
    var type: String
    var master: HLSMaster
    var fetchedAt: Date
  }

  private struct Probe: Sendable {
    var type: String
    var master: BackupMaster?
    var media: HLSMediaPlaylist?
    var clean: Bool
    var failure: String?
  }

  init(
    id: String = UUID().uuidString, login: String, config: StreamSessionConfig, http: HTTPClient, mediaHTTP: HTTPClient? = nil,
    tokens: PlaybackTokenProvider, log: ActivityLog = .shared,
    onAdState: @escaping @Sendable (AdState, [ClosedRange<Date>]) -> Void = { _, _ in }
  ) {
    self.id = id
    self.login = login.lowercased()
    self.config = config
    self.http = http
    self.mediaHTTP = mediaHTTP ?? http
    self.tokens = tokens
    self.log = log
    self.onAdState = onAdState
  }

  // MARK: - Start

  enum StartError: Error, LocalizedError {
    case offline
    case usher(Int)
    case noVariants

    var errorDescription: String? {
      switch self {
      case .offline: return "This channel is offline."
      case .usher(let status): return "Twitch refused the stream (HTTP \(status))."
      case .noVariants: return "No playable qualities were found."
      }
    }
  }

  func start() async throws -> StreamInfo {
    let fetched = try await MasterPlaylistFetch.fetch(
      login: login, codecs: config.codecs, lowLatency: config.fastBread, proxies: config.adFreeProxies,
      checkAccountFirst: config.checkAccountFirst, playerType: config.mainPlayerType, http: http, tokens: tokens, log: log)
    route = fetched.route
    let master = HLSMaster.parse(fetched.text, base: fetched.url)
    var variants = master.videoVariants
    if let audio = master.audioVariant { variants.append(audio) }
    guard !variants.isEmpty else { throw StartError.noVariants }
    served = variants
    log.add("Playing \(login) (\(variants.map(\.label).joined(separator: ", ")))")
    return StreamInfo(variants: variants)
  }

  // MARK: - Playlists served to AVPlayer

  /// - Parameter only: serve just this variant (manual quality), or all video variants (auto).
  func masterPlaylist(only: Int?) -> String {
    var lines = ["#EXTM3U", "#EXT-X-INDEPENDENT-SEGMENTS"]
    for (index, variant) in served.enumerated() {
      if let only {
        guard index == only else { continue }
      } else if variant.isAudioOnly {
        continue
      }
      var attributes = ["BANDWIDTH=\(max(variant.bandwidth, 1))"]
      if let resolution = variant.resolution { attributes.append("RESOLUTION=\(resolution)") }
      if !variant.codecs.isEmpty { attributes.append("CODECS=\"\(variant.codecs)\"") }
      if variant.frameRate > 0 { attributes.append("FRAME-RATE=\(String(format: "%.3f", variant.frameRate))") }
      lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
      lines.append("v/\(index).m3u8")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  func mediaPlaylist(_ index: Int) async -> (status: Int, body: String) {
    guard index >= 0, index < served.count else { return (404, "") }
    let variant = served[index]

    let main: HLSMediaPlaylist
    switch await fetchMedia(URL(string: variant.uri)) {
    case .success(let playlist):
      main = playlist
    case .failure(let status):
      // A hiccup upstream: hand the player what it already has instead of an error.
      // (404/403 mean the stream or the token is gone; the player handles that.)
      if status != 404, status != 403, let body = render(index) { return (200, body) }
      return (status, "")
    }

    mainStores[index, default: SegmentStore()].record(main.segments)
    timeline.setInitialSequence(main.mediaSequence)
    // The real segment length (Twitch says 6 but cuts 2 s segments). AVPlayer starts three target
    // durations from the end and reloads every target duration, so an inflated value only adds
    // latency. It may grow if a longer segment shows up, never shrink.
    let longest = Int(((main.regularSegments.map(\.duration).max() ?? 2) - 0.01).rounded(.up))
    targetDuration = max(targetDuration ?? 2, longest, 2)

    var candidates: [HLSSegment] = []
    var source = SlotSource.main

    if !main.adBreakActive {
      if inBreak { endBreak() }
      noteMarkers(main.adMarkerActive)
      candidates = playable(main)
    } else {
      let firstPoll = !inBreak
      if firstPoll { beginBreak() }

      if config.backupStreams {
        if committed == nil { startSearchIfNeeded(trigger: index) }
        if committed == nil, firstPoll {
          await searchSignal.wait(timeout: config.firstPollWait)
        }
        if let backup = committed {
          if let playlist = await fetchBackupMedia(backup, variantIndex: index) {
            if playlist.isClean {
              candidates = playable(playlist)
              source = .backup(backup.type)
            } else if committed?.type == backup.type {
              committed = nil
              contaminated.insert(backup.type)
              log.add("Backup stream (\(backup.type)) started showing ads, looking for another")
              startSearchIfNeeded(trigger: index)
            }
          } else if committed?.type == backup.type {
            committed = nil
            log.add("Backup stream (\(backup.type)) stopped responding, looking for another")
            startSearchIfNeeded(trigger: index)
          }
        }
      }

      if candidates.isEmpty {
        source = .main
        candidates = main.regularSegments.filter { !$0.isAd }
        let waitedLongEnough = Date().timeIntervalSince(breakStart) >= config.fallbackGrace
        let nothingToShow = timeline.isEmpty && candidates.isEmpty
        if nothingToShow || (config.fallback == .muteAndCover && waitedLongEnough && searchTask == nil) {
          candidates = main.regularSegments
          if main.regularSegments.contains(where: \.isAd) { setAdState(.covering) }
        }
      }
    }

    timeline.append(candidates, source: source)
    await ensureBackupStores(for: index)
    publishAdRangesIfNeeded()

    guard let body = render(index) else { return (503, "") }
    return (200, body)
  }

  private func render(_ index: Int) -> String? {
    let window = config.lowLatency ? 10 : 15
    return timeline.render(window: window, targetDuration: targetDuration ?? 2) { slot in
      switch slot.source {
      case .main: return mainStores[index]?.lookup(slot)
      case .backup(let type): return backupStores[index]?[type]?.lookup(slot)
      }
    }
  }

  /// Regular segments plus, in low-latency mode, the segment Twitch is producing right now.
  /// (Only one: AVPlayer measures bandwidth on these slow, real-time downloads.)
  private func playable(_ playlist: HLSMediaPlaylist) -> [HLSSegment] {
    var result = playlist.regularSegments.filter { !$0.isAd }
    if config.lowLatency, let next = playlist.segments.first(where: { $0.isPrefetch }), !next.isAd {
      result.append(next)
    }
    return result
  }

  // MARK: - Ad breaks

  private func beginBreak() {
    inBreak = true
    breakID += 1
    breakStart = Date()
    breakSummary = ""
    contaminated = []
    committed = nil
    lastSearchEnd = .distantPast
    setAdState(config.backupStreams ? .searching : .covering)
    log.add("Ad break started on \(login)")
  }

  private var markerBreak = false
  private var markerStart = Date.distantPast

  private func noteMarkers(_ active: Bool) {
    if active, !markerBreak {
      markerBreak = true
      markerStart = Date()
      log.add("Ad break on \(login): Twitch sends this ad to its own player, so it's skipped (stream stays at full quality)")
      setAdState(.skipped)
    } else if !active, markerBreak {
      markerBreak = false
      log.add("Ad break over after \(Int(Date().timeIntervalSince(markerStart).rounded()))s (skipped)")
      setAdState(.none)
    }
  }

  private func endBreak() {
    inBreak = false
    breakID += 1
    let seconds = Int(Date().timeIntervalSince(breakStart).rounded())
    log.add("Ad break over after \(seconds)s\(breakSummary)")
    committed = nil
    contaminated = []
    searchTask?.cancel()
    searchTask = nil
    setAdState(.none)
  }

  private func setAdState(_ state: AdState) {
    guard state != adState else { return }
    adState = state
    onAdState(state, timeline.adRanges)
  }

  private var lastPublishedAdRanges: [ClosedRange<Date>] = []
  private func publishAdRangesIfNeeded() {
    let ranges = timeline.adRanges
    if ranges != lastPublishedAdRanges {
      lastPublishedAdRanges = ranges
      onAdState(adState, ranges)
    }
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

  private func startSearchIfNeeded(trigger index: Int) {
    guard searchTask == nil, inBreak, committed == nil else { return }
    // Don't hammer Twitch: a failed search is retried at most every 6 seconds.
    if Date().timeIntervalSince(lastSearchEnd) < 6 { return }
    let types = playerTypes()
    let target = served[index]
    let breakID = self.breakID
    let cached = backupMasters
    let signal = OneShotSignal()
    searchSignal = signal
    searchTask = Task { [weak self] in
      guard let self else { return }
      let started = Date()
      let probes = await self.runProbes(types: types, target: target, cached: cached)
      await self.finishSearch(probes: probes, types: types, index: index, breakID: breakID, started: started)
      signal.fire()
    }
  }

  private func finishSearch(probes: [Int: Probe], types: [String], index: Int, breakID: Int, started: Date) {
    searchTask = nil
    lastSearchEnd = Date()
    for probe in probes.values {
      if let master = probe.master { backupMasters[probe.type] = master }
    }
    guard breakID == self.breakID, inBreak else { return }
    let winner = types.indices.compactMap { probes[$0] }.first { $0.clean }
    if let winner, let master = winner.master, let media = winner.media {
      committed = master
      backupStores[index, default: [:]][winner.type, default: SegmentStore()].record(media.segments)
      if winner.type != "autoplay" { pinnedType = winner.type }
      let label = master.master.bestMatch(for: served[index])?.label ?? "?"
      let ms = Int(Date().timeIntervalSince(started) * 1000)
      breakSummary = " (ad-free copy: \(winner.type))"
      log.add("Switched to ad-free copy (\(winner.type), \(label)) in \(ms) ms")
      setAdState(.replaced("\(winner.type) · \(label)"))
    } else {
      for probe in probes.values where !probe.clean && probe.failure == nil { contaminated.insert(probe.type) }
      let tried = types.indices.map { i -> String in
        guard let p = probes[i] else { return "\(types[i]) (timeout)" }
        return p.clean ? p.type : "\(p.type) (\(p.failure ?? "ads"))"
      }
      breakSummary = " (no ad-free copy)"
      log.add("No ad-free copy found (tried \(tried.joined(separator: ", ")))")
      setAdState(config.fallback == .muteAndCover ? .covering : .searching)
    }
  }

  private nonisolated func runProbes(types: [String], target: HLSVariant, cached: [String: BackupMaster]) async
    -> [Int: Probe]
  {
    let deadline = config.searchDeadline
    return await withTaskGroup(of: (Int, Probe?).self) { group -> [Int: Probe] in
      for (i, type) in types.enumerated() {
        group.addTask { (i, await self.probe(type: type, target: target, cached: cached[type])) }
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
        return (-1, nil)
      }
      var results: [Int: Probe] = [:]
      var deadlineHit = false
      for await (i, probe) in group {
        if i < 0 {
          deadlineHit = true
        } else if let probe {
          results[i] = probe
        }
        // First clean result in priority order wins, as soon as everything ahead of it resolved.
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

  private nonisolated func probe(type: String, target: HLSVariant, cached: BackupMaster?) async -> Probe {
    if let cached, Date().timeIntervalSince(cached.fetchedAt) < config.backupTokenLifetime {
      let probe = await probeMedia(cached, target: target)
      if probe.clean || Task.isCancelled { return probe }
    }
    do {
      let token = try await tokens.streamToken(
        login: login, playerType: type, platform: type == "autoplay" ? "android" : "web")
      let url = Usher.live(login: login, token: token, codecs: config.codecs, lowLatency: config.fastBread)
      let (data, response) = try await http.data(for: Usher.playlistRequest(url, timeout: 5))
      guard response.statusCode == 200, let text = String(data: data, encoding: .utf8), HLS.looksLikePlaylist(data)
      else {
        return Probe(
          type: type, master: nil, media: nil, clean: false, failure: "HTTP \(response.statusCode)")
      }
      let master = BackupMaster(type: type, master: HLSMaster.parse(text, base: response.url ?? url), fetchedAt: Date())
      return await probeMedia(master, target: target)
    } catch {
      return Probe(type: type, master: nil, media: nil, clean: false, failure: "failed")
    }
  }

  private nonisolated func probeMedia(_ master: BackupMaster, target: HLSVariant) async -> Probe {
    guard let match = master.master.bestMatch(for: target), let url = URL(string: match.uri) else {
      return Probe(type: master.type, master: master, media: nil, clean: false, failure: "no match")
    }
    switch await fetchMedia(url) {
    case .success(let playlist):
      return Probe(
        type: master.type, master: master, media: playlist,
        clean: playlist.isClean && !playlist.regularSegments.isEmpty, failure: nil)
    case .failure(let status):
      return Probe(type: master.type, master: master, media: nil, clean: false, failure: "HTTP \(status)")
    }
  }

  private func fetchBackupMedia(_ backup: BackupMaster, variantIndex: Int) async -> HLSMediaPlaylist? {
    guard let match = backup.master.bestMatch(for: served[variantIndex]), let url = URL(string: match.uri) else {
      return nil
    }
    guard case .success(let playlist) = await fetchMedia(url) else { return nil }
    backupStores[variantIndex, default: [:]][backup.type, default: SegmentStore()].record(playlist.segments)
    return playlist
  }

  /// Makes sure every backup slot in the render window can be resolved for this quality level
  /// (needed when the player switches quality after a break).
  private func ensureBackupStores(for index: Int) async {
    let recent = timeline.slots.suffix(16)
    var needed: Set<String> = []
    for slot in recent {
      if case .backup(let type) = slot.source, backupStores[index]?[type]?.contains(slot) != true {
        needed.insert(type)
      }
    }
    for type in needed {
      guard let master = backupMasters[type] ?? (committed?.type == type ? committed : nil) else { continue }
      _ = await fetchBackupMedia(master, variantIndex: index)
    }
  }

  // MARK: - Networking

  private enum FetchResult {
    case success(HLSMediaPlaylist)
    case failure(Int)
  }

  private nonisolated func fetchMedia(_ url: URL?) async -> FetchResult {
    guard let url else { return .failure(404) }
    do {
      let (data, response) = try await mediaHTTP.data(for: Usher.playlistRequest(url, timeout: 5))
      guard response.statusCode == 200 else { return .failure(response.statusCode) }
      guard HLS.looksLikePlaylist(data), let text = String(data: data, encoding: .utf8) else { return .failure(502) }
      return .success(HLSMediaPlaylist.parse(text, base: response.url ?? url))
    } catch {
      return .failure(504)
    }
  }
}
