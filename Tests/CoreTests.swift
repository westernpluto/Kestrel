// Linux test runner for the platform-independent core. Build with Tests/run.sh.

import Dispatch
import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: String = #file, line: Int = #line) {
  checks += 1
  if !condition() {
    failures += 1
    print("FAIL \((file as NSString).lastPathComponent):\(line) \(message())")
  }
}

func runAsync(_ body: @escaping @Sendable () async -> Void) {
  let done = DispatchSemaphore(value: 0)
  Task {
    await body()
    done.signal()
  }
  done.wait()
}

// MARK: - Fake Twitch

/// Simulates Twitch: 2-second segments, a moving live edge, per-session ad breaks.
final class FakeTwitch: HTTPClient, PlaybackTokenProvider, @unchecked Sendable {
  let lock = NSLock()
  var liveIndex = 20  // newest complete segment
  let base = Date(timeIntervalSince1970: 1_800_000_000)
  var mainAds: Range<Int> = 0..<0
  /// Client-side ad break: only the DATERANGE marker, the segments stay live content.
  var mainMarkers: Range<Int> = 0..<0
  var backupAds: [String: Range<Int>] = [:]  // per player type
  var failingTypes: Set<String> = []
  var tokenRequests: [String] = []
  var sessions: [String: String] = [:]  // token -> player type
  var sessionCounter = 0
  var mainToken: String?
  var delay: Double = 0.01
  var withPrefetch = true
  var mainMediaStatus: Int?
  /// EXTINF title of stitched ad segments ("Amazon|…" historically; IVS-style ads use an ID).
  var adTitle = "Amazon|5555"
  /// Tokens describe a signed-in account Twitch shows no ads (a sub).
  var subscriberAccount = false

  let variants = [("1080p60", "1920x1080", 60.0, 6_000_000), ("720p60", "1280x720", 60.0, 3_000_000), ("480p", "852x480", 30.0, 1_400_000)]

  func advance(_ n: Int = 1) {
    lock.lock()
    liveIndex += n
    lock.unlock()
  }

  func streamToken(login: String, playerType: String, platform: String) async throws -> PlaybackToken {
    lock.lock()
    sessionCounter += 1
    let token = "tok\(sessionCounter)"
    sessions[token] = playerType
    tokenRequests.append(playerType)
    if mainToken == nil { mainToken = token }
    lock.unlock()
    if subscriberAccount {
      return PlaybackToken(
        value: #"{"hide_ads":true,"show_ads":false,"subscriber":true,"turbo":false,"user_id":42,"k":"\#(token)"}"#,
        signature: "sig")
    }
    return PlaybackToken(value: token, signature: "sig")
  }

  func pdt(_ n: Int) -> Date { base.addingTimeInterval(Double(n) * 2) }

  func token(for type: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return sessions.first { $0.value == type }?.key
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
    let url = request.url!
    func respond(_ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
      (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
    lock.lock()
    defer { lock.unlock() }
    if url.host == "usher.ttvnw.net" {
      let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      var token = comps.queryItems?.first { $0.name == "token" }?.value ?? ""
      if token.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(token.utf8)) as? [String: Any],
        let key = object["k"] as? String
      {
        token = key
      }
      guard let type = sessions[token] else { return respond(403, "bad token") }
      if failingTypes.contains(type) { return respond(500, "nope") }
      var lines = ["#EXTM3U"]
      for (name, res, fps, bw) in variants {
        lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(bw),CODECS=\"avc1.4D402A,mp4a.40.2\",RESOLUTION=\(res),FRAME-RATE=\(fps),STABLE-VARIANT-ID=\"\(name)\",IVS-NAME=\"\(name)\",IVS-GROUPS=\"landscape\"")
        lines.append("https://weaver.test/\(token)/\(name).m3u8")
      }
      lines.append("#EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS=\"avc1.4D401F,mp4a.40.2\",RESOLUTION=480x852,FRAME-RATE=30.000,STABLE-VARIANT-ID=\"480p30-portrait\",IVS-GROUPS=\"portrait\"")
      lines.append("https://weaver.test/\(token)/portrait.m3u8")
      lines.append("#EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS=\"mp4a.40.2\",STABLE-VARIANT-ID=\"audio_only\",IVS-NAME=\"Audio Only\"")
      lines.append("https://weaver.test/\(token)/audio_only.m3u8")
      return respond(200, lines.joined(separator: "\n"))
    }
    if url.host == "weaver.test" {
      let parts = url.path.split(separator: "/")
      let token = String(parts[0])
      let variant = String(parts[1].dropLast(5))
      guard let type = sessions[token] else { return respond(404, "") }
      if failingTypes.contains(type) { return respond(500, "") }
      if token == mainToken, let status = mainMediaStatus { return respond(status, "") }
      let ads = token == mainToken ? mainAds : (backupAds[type] ?? 0..<0)
      let tag = "\(token)-\(variant)"
      if token == mainToken, !mainMarkers.isEmpty { return respond(200, mediaPlaylist(tag: tag, ads: mainMarkers, markersOnly: true)) }
      return respond(200, mediaPlaylist(tag: tag, ads: ads))
    }
    return respond(404, "")
  }

  func mediaPlaylist(tag: String, ads markerRange: Range<Int>, markersOnly: Bool = false) -> String {
    let ads = markersOnly ? 0..<0 : markerRange
    let first = liveIndex - 5
    var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:6", "#EXT-X-MEDIA-SEQUENCE:\(first)"]
    if !markerRange.isEmpty, markerRange.upperBound > first - 3, markerRange.lowerBound <= liveIndex + 3 {
      let start = ISO8601DateFormatter.fractional.string(from: pdt(markerRange.lowerBound))
      lines.append("#EXT-X-DATERANGE:ID=\"stitched-ad-\(markerRange.lowerBound)\",CLASS=\"twitch-stitched-ad\",START-DATE=\"\(start)\",DURATION=\(Double(markerRange.count) * 2),X-TV-TWITCH-AD-ROLL-TYPE=\"MIDROLL\"")
    }
    for n in first...liveIndex {
      let isAd = ads.contains(n)
      if n > first, isAd != ads.contains(n - 1) { lines.append("#EXT-X-DISCONTINUITY") }
      lines.append("#EXT-X-PROGRAM-DATE-TIME:\(ISO8601DateFormatter.fractional.string(from: pdt(n)))")
      lines.append(isAd ? "#EXTINF:2.000,\(adTitle)" : "#EXTINF:2.000,live")
      lines.append(isAd ? "https://edge.test/\(tag)/ad-\(n).ts" : "https://edge.test/\(tag)/\(n).ts")
    }
    if withPrefetch, !ads.contains(liveIndex), !ads.contains(liveIndex + 1) {
      lines.append("#EXT-X-TWITCH-PREFETCH:https://edge.test/\(tag)/\(liveIndex + 1).ts")
      lines.append("#EXT-X-TWITCH-PREFETCH:https://edge.test/\(tag)/\(liveIndex + 2).ts")
    }
    return lines.joined(separator: "\n")
  }
}

extension ISO8601DateFormatter {
  static let fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
}

// MARK: - Playlist checker (what AVPlayer would require)

struct RenderedPlaylist {
  var mediaSequence: Int
  var discontinuitySequence: Int
  var segments: [(seq: Int, dseq: Int, uri: String, pdt: Date?, discontinuity: Bool)]
  var target: Int

  init?(_ text: String) {
    let lines = text.split(separator: "\n").map(String.init)
    guard lines.first == "#EXTM3U" else { return nil }
    var ms = -1, ds = -1, target = -1
    var segs: [(Int, Int, String, Date?, Bool)] = []
    var pendingDisc = false
    var pendingPDT: Date?
    var discCount = 0
    for line in lines {
      if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { ms = Int(line.dropFirst(22))! }
      else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") { ds = Int(line.dropFirst(30))! }
      else if line.hasPrefix("#EXT-X-TARGETDURATION:") { target = Int(line.dropFirst(22))! }
      else if line == "#EXT-X-DISCONTINUITY" { pendingDisc = true; discCount += 1 }
      else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") { pendingPDT = HLSDate.parse(String(line.dropFirst(25))) }
      else if !line.hasPrefix("#") {
        segs.append((ms + segs.count, ds + discCount, line, pendingPDT, pendingDisc))
        pendingDisc = false
        pendingPDT = nil
      }
    }
    guard ms >= 0, ds >= 0, target > 0 else { return nil }
    mediaSequence = ms
    discontinuitySequence = ds
    self.target = target
    segments = segs.map { (seq: $0.0, dseq: $0.1, uri: $0.2, pdt: $0.3, discontinuity: $0.4) }
  }
}

/// Tracks successive reloads of one media playlist and checks HLS rules across them.
final class ReloadChecker {
  var seen: [Int: (uri: String, dseq: Int)] = [:]
  var lastSequence = -1
  var lastCount = 0
  var lastEndSeq = -1
  var name: String
  init(_ name: String) { self.name = name }

  func feed(_ text: String, line: Int = #line) {
    guard let playlist = RenderedPlaylist(text) else {
      check(false, "\(name): unparseable playlist:\n\(text)", line: line)
      return
    }
    check(playlist.mediaSequence >= lastSequence, "\(name): media sequence went backwards", line: line)
    let endSeq = playlist.segments.last.map(\.seq) ?? -1
    check(endSeq >= lastEndSeq, "\(name): playlist lost segments at the end (\(lastEndSeq) -> \(endSeq))", line: line)
    func source(_ uri: String) -> String { uri.components(separatedBy: "/").dropLast().last?.components(separatedBy: "-").first ?? "" }
    for (i, segment) in playlist.segments.enumerated() where i > 0 {
      if source(segment.uri) != source(playlist.segments[i - 1].uri) {
        check(segment.discontinuity, "\(name): source switch without discontinuity at seq \(segment.seq)", line: line)
      }
    }
    for segment in playlist.segments {
      if let previous = seen[segment.seq] {
        check(previous.uri == segment.uri || source(previous.uri) != source(segment.uri) || previous.uri.contains("/ad-") == segment.uri.contains("/ad-"), "\(name): seq \(segment.seq) changed content", line: line)
        check(previous.dseq == segment.dseq, "\(name): seq \(segment.seq) changed discontinuity number", line: line)
      }
      seen[segment.seq] = (segment.uri, segment.dseq)
    }
    lastSequence = playlist.mediaSequence
    lastEndSeq = endSeq
  }
}

// MARK: - Tests

func testDates() {
  let d = HLSDate.parse("2026-10-21T07:00:04.123Z")!
  check(abs(d.timeIntervalSince1970 - 1792566004.123) < 0.0005, "date parse \(d.timeIntervalSince1970)")
  check(HLSDate.format(d) == "2026-10-21T07:00:04.123Z", "format \(HLSDate.format(d))")
  check(HLSDate.parse("2026-10-21T09:00:04+02:00")!.timeIntervalSince1970 == 1792566004, "offset")
  check(HLSDate.parse("2026-10-21T07:00:04Z")!.timeIntervalSince1970 == 1792566004, "no fraction")
  for t in [0.0, 1.5, 999.999, 1792566004.5] {
    let date = Date(timeIntervalSince1970: t)
    check(abs(HLSDate.parse(HLSDate.format(date))!.timeIntervalSince(date)) < 0.001, "roundtrip \(t)")
  }
}

func testMasterParsing() {
  let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
  if let text = try? String(contentsOfFile: path) {
    let master = HLSMaster.parse(text, base: URL(string: "https://usher.ttvnw.net/api/v2/channel/hls/x.m3u8"))
    check(master.variants.count == 12, "v2 variants \(master.variants.count)")
    let video = master.videoVariants
    check(video.count == 6 && video.first?.label == "1440p60 HEVC" && video.last?.label == "160p", "landscape \(video.map(\.label))")
    check(!video.contains { $0.isPortrait }, "portrait filtered")
    check(master.audioVariant?.label == "Audio only", "audio")
    check(video[0].uri == "https://usher.ttvnw.net/1440p60.m3u8", "uri \(video[0].uri)")
    check(video[0].codecFamily == "hevc" && video[1].codecFamily == "avc", "codecs")
    // The copy the low-latency player loads from the local server.
    let local = HLSMaster.localCopy(of: text, base: URL(string: "https://usher.ttvnw.net/api/v2/channel/hls/x.m3u8"))
    let reparsed = HLSMaster.parse(local, base: nil)
    check(reparsed.variants.count == 7 && !reparsed.variants.contains { $0.isPortrait }, "local copy drops portrait \(reparsed.variants.count)")
    check(reparsed.variants.allSatisfy { $0.uri.hasPrefix("https://usher.ttvnw.net/") }, "local copy absolute URIs")
    check(local.contains("IVS-NAME=\"1440p60\"") && local.hasPrefix("#EXTM3U"), "local copy keeps attributes")
  } else {
    print("(skipping v2 master fixture: pass path as first argument)")
  }
  let v1 = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="chunked",NAME="1080p60 (source)",AUTOSELECT=YES,DEFAULT=YES
    #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080,CODECS="avc1.64002A,mp4a.40.2",VIDEO="chunked",FRAME-RATE=60.000
    https://a/src.m3u8
    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="audio_only",NAME="audio_only",AUTOSELECT=NO,DEFAULT=NO
    #EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS="mp4a.40.2",VIDEO="audio_only"
    audio.m3u8
    """
  // Same resolution and frame rate: HEVC ranks above H.264 and AV1.
  let mixed = HLSMaster.parse(
    """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080,CODECS="avc1.64002A,mp4a.40.2",FRAME-RATE=60.000
    avc.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="av01.0.08M.08,mp4a.40.2",FRAME-RATE=60.000
    av1.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="hvc1.1.6.L123.90,mp4a.40.2",FRAME-RATE=60.000
    hevc.m3u8
    """, base: URL(string: "https://a/"))
  check(mixed.videoVariants.map(\.label) == ["1080p60 HEVC", "1080p60 AV1", "1080p60"], "codec order \(mixed.videoVariants.map(\.label))")
  let m = HLSMaster.parse(v1, base: URL(string: "https://a/b/master.m3u8"))
  check(m.videoVariants.count == 1 && m.videoVariants[0].name == "1080p60 (source)", "v1 names")
  check(m.audioVariant?.uri == "https://a/b/audio.m3u8", "v1 relative audio")
}

func testMediaParsing() {
  let fake = FakeTwitch()
  fake.liveIndex = 30
  let clean = HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 0..<0), base: nil)
  check(clean.regularSegments.count == 6 && clean.segments.count == 8, "segments \(clean.segments.count)")
  check(clean.segments[6].isPrefetch && clean.segments[6].pdt == fake.pdt(31), "prefetch pdt")
  check(!clean.adBreakActive && clean.isClean, "clean")

  let midroll = HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 29..<40), base: nil)
  check(midroll.adBreakActive && !midroll.isClean, "midroll active")
  check(midroll.segments.filter(\.isAd).count == 2, "ad count \(midroll.segments.filter(\.isAd).count)")
  check(!midroll.segments.contains { $0.isPrefetch }, "no prefetch in ads")

  let upcoming = HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 32..<40), base: nil)
  check(!upcoming.adBreakActive && upcoming.adMarkerActive, "announced ad: marker only, no stitched segments yet")
  let past = HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 20..<27), base: nil)
  check(!past.adBreakActive && past.segments.filter(\.isAd).count == 2, "past ad: not active, old ads flagged")

  // Client-side ad break (Twitch 2026): marker present, segments are the real broadcast.
  let csai = HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 29..<40, markersOnly: true), base: nil)
  check(csai.segments.filter(\.isAd).isEmpty && !csai.adBreakActive && csai.adMarkerActive && csai.isClean, "client-side break")
  check(csai.segments.filter(\.isPrefetch).count == 2, "prefetch kept during client-side break")
}

func testAdTimeline() {
  let fake = FakeTwitch()
  var ads = AdTimeline()
  fake.liveIndex = 30
  ads.update(with: HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 0..<0), base: nil), now: fake.pdt(31))
  check(!ads.isActive && !ads.covers(fake.pdt(29)), "clean: nothing covered")
  // Stitched break starts at 29: covered from there on while it lasts.
  ads.update(with: HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 29..<33), base: nil), now: fake.pdt(31))
  check(ads.isActive && ads.covers(fake.pdt(29).addingTimeInterval(1)) && ads.covers(fake.pdt(40)), "open break covered")
  check(!ads.covers(fake.pdt(27)), "content before the break")
  // Break over: only its own time range stays covered, so a player a few seconds behind still hides it.
  fake.liveIndex = 36
  ads.update(with: HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 29..<33), base: nil), now: fake.pdt(37))
  check(!ads.isActive, "break ended")
  check(ads.covers(fake.pdt(30)) && ads.covers(fake.pdt(32).addingTimeInterval(1.9)), "past break range kept")
  check(!ads.covers(fake.pdt(34)) && !ads.covers(fake.pdt(28)), "content around the break")
  // Client-side break: marker only.
  ads.update(with: HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 35..<45, markersOnly: true), base: nil), now: fake.pdt(37))
  check(ads.markerActive && !ads.isActive && !ads.covers(fake.pdt(36)), "client-side break: nothing to hide")
}

func testTimelineAndRender() {
  var timeline = SlotTimeline()
  var store = SegmentStore()
  let fake = FakeTwitch()
  fake.liveIndex = 10
  let p1 = HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "m", ads: 0..<0), base: nil)
  store.record(p1.segments)
  timeline.setInitialSequence(p1.mediaSequence)
  timeline.append(p1.segments, source: .main)
  check(timeline.slots.count == 8, "slots incl. prefetch \(timeline.slots.count)")
  check(timeline.slots.first?.seq == 5, "initial seq")
  fake.advance()
  let p2 = HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "m", ads: 0..<0), base: nil)
  store.record(p2.segments)
  let added = timeline.append(p2.segments, source: .main)
  check(added == 1, "promoted prefetch not duplicated, one new prefetch (\(added))")
  let text = timeline.render(window: 10, targetDuration: 2) { store.lookup($0) }!
  let parsed = RenderedPlaylist(text)!
  check(parsed.segments.count == 9 && parsed.segments.last!.uri.hasSuffix("/13.ts"), "render \(text)")
  check(parsed.segments.allSatisfy { !$0.discontinuity }, "no discontinuities")
}

func testSession(lowLatency: Bool) {
  let fake = FakeTwitch()
  fake.mainAds = 25..<40
  fake.backupAds = ["site": 0..<100, "popout": 0..<100, "mobile_web": 0..<0, "embed": 0..<100]
  let log = ActivityLog()
  var config = StreamSessionConfig()
  config.lowLatency = lowLatency
  config.firstPollWait = 1.5
  let session = StreamSession(login: "streamer", config: config, http: fake, tokens: fake, log: log)
  runAsync {
    let info = try! await session.start()
    check(info.variants.map(\.label) == ["1080p60", "720p60", "480p", "Audio only"], "served \(info.variants.map(\.label))")
    let master = await session.masterPlaylist(only: nil)
    check(master.contains("v/0.m3u8") && master.contains("v/2.m3u8") && !master.contains("v/3.m3u8"), "auto master")
    check(!master.contains("VIDEO=") && !master.contains("IVS-"), "clean master")
    let manual = await session.masterPlaylist(only: 1)
    check(manual.components(separatedBy: "#EXT-X-STREAM-INF").count == 2 && manual.contains("v/1.m3u8"), "manual")

    let checker720 = ReloadChecker("720p")
    let checker1080 = ReloadChecker("1080p")
    var sawBackup = false
    var adURIs = 0
    for step in 0..<30 {
      // The player mostly polls 720p, switches to 1080p for a while mid-break.
      let index = (14...18).contains(step) ? 0 : 1
      let result = await session.mediaPlaylist(index)
      check(result.status == 200, "status \(result.status) at step \(step)")
      if index == 1 { checker720.feed(result.body) } else { checker1080.feed(result.body) }
      if result.body.contains("/ad-") { adURIs += 1 }
      if let token = fake.token(for: "mobile_web"), result.body.contains("edge.test/\(token)-") { sawBackup = true }
      fake.advance()
    }
    check(adURIs == 0, "an ad segment reached the player \(adURIs) times")
    check(sawBackup, "backup stream used")
    let rendered = await session.mediaPlaylist(1).body
    check(rendered.contains("#EXT-X-TARGETDURATION:2\n"), "honest target duration (Twitch says 6, segments are 2 s)")
    let messages = log.messages
    check(messages.contains { $0.hasPrefix("Ad break started") }, "log start \(messages)")
    check(messages.contains { $0.contains("Switched to ad-free copy (mobile_web") }, "log switch \(messages)")
    check(messages.contains { $0.hasPrefix("Ad break over") }, "log end \(messages)")
    // Token requests: main + one parallel search.
    check(fake.tokenRequests.count <= 7, "token requests \(fake.tokenRequests)")
  }
}

func testClientSideBreak() {
  // Twitch's current ads: markers only. Kestrel must keep the main stream at full quality,
  // never search for backups, never cut content.
  let fake = FakeTwitch()
  fake.mainMarkers = 24..<40
  let log = ActivityLog()
  let states = AdRangeBox()
  let session = StreamSession(login: "streamer", config: StreamSessionConfig(), http: fake, tokens: fake, log: log) { state, ranges in
    states.set(state, ranges)
  }
  runAsync {
    _ = try! await session.start()
    let checker = ReloadChecker("csai")
    var seenStates: [AdState] = []
    var foreign = 0
    var discontinuities = 0
    for _ in 0..<30 {
      let result = await session.mediaPlaylist(0)
      check(result.status == 200, "status \(result.status)")
      checker.feed(result.body)
      if let mainToken = fake.mainToken, result.body.contains("edge.test/") && result.body.components(separatedBy: "\n").contains(where: { $0.hasPrefix("https://edge.test/") && !$0.hasPrefix("https://edge.test/\(mainToken)-1080p60/") }) {
        foreign += 1
      }
      discontinuities += result.body.components(separatedBy: "#EXT-X-DISCONTINUITY\n").count - 1
      states.lock.lock(); seenStates.append(states.state); states.lock.unlock()
      fake.advance()
    }
    check(foreign == 0, "only main segments served")
    check(discontinuities == 0, "no cuts")
    check(fake.tokenRequests == ["popout"], "no backup tokens requested: \(fake.tokenRequests)")
    check(seenStates.contains(.skipped) && seenStates.last == AdState.none, "skipped state shown then cleared: \(seenStates)")
    check(log.messages.contains { $0.contains("skipped (stream stays at full quality)") }, "\(log.messages)")
    check(log.messages.contains { $0.hasPrefix("Ad break over") && $0.contains("skipped") }, "\(log.messages)")
  }
}

func testSessionFallback() {
  let fake = FakeTwitch()
  fake.mainAds = 24..<30
  fake.backupAds = ["site": 0..<100, "popout": 0..<100, "mobile_web": 0..<100, "embed": 0..<100, "autoplay": 0..<100]
  let log = ActivityLog()
  var config = StreamSessionConfig()
  config.firstPollWait = 0.5
  config.fallbackGrace = 0
  let ranges = AdRangeBox()
  let session = StreamSession(login: "streamer", config: config, http: fake, tokens: fake, log: log) { state, adRanges in
    ranges.set(state, adRanges)
  }
  runAsync {
    _ = try! await session.start()
    let checker = ReloadChecker("fallback")
    var sawAds = false
    for _ in 0..<16 {
      let result = await session.mediaPlaylist(1)
      check(result.status == 200, "status \(result.status)")
      checker.feed(result.body)
      if result.body.contains("/ad-") { sawAds = true }
      fake.advance()
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    check(sawAds, "fallback lets ads through (muted) when nothing is ad-free")
    check(!ranges.ranges.isEmpty, "ad ranges published for muting")
    check(log.messages.contains { $0.hasPrefix("No ad-free copy found") }, "log \(log.messages)")
  }
}

func testPreroll() {
  // Stream opens in the middle of an ad: first playlist must still not show the ad if a backup is clean.
  let fake = FakeTwitch()
  fake.mainAds = 0..<26
  fake.backupAds = ["site": 0..<100, "popout": 0..<0]
  let log = ActivityLog()
  var config = StreamSessionConfig()
  config.firstPollWait = 2
  let session = StreamSession(login: "streamer", config: config, http: fake, tokens: fake, log: log)
  runAsync {
    _ = try! await session.start()
    let first = await session.mediaPlaylist(0)
    check(first.status == 200 && !first.body.contains("/ad-"), "preroll replaced: \(first.body)")
    check(log.messages.contains { $0.contains("Switched to ad-free copy (popout") }, "\(log.messages)")
  }
}

final class AdRangeBox: @unchecked Sendable {
  let lock = NSLock()
  var ranges: [ClosedRange<Date>] = []
  var state: AdState = .none
  func set(_ s: AdState, _ r: [ClosedRange<Date>]) {
    lock.lock()
    state = s
    ranges = r
    lock.unlock()
  }
}

/// Raw socket HTTP GET, so the test checks our server rather than the platform's URL loading.
func rawGET(_ port: UInt16, _ path: String) -> (status: Int, headers: String, body: String) {
  #if os(Linux)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
  #else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
  #endif
  defer { close(fd) }
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = in_port_t(port).bigEndian
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  guard connected == 0 else { return (-1, "", "") }
  let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: AppleCoreMedia/1.0\r\n\r\n"
  _ = request.withCString { send(fd, $0, strlen($0), 0) }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let n = read(fd, &buffer, buffer.count)
    if n <= 0 { break }
    data.append(contentsOf: buffer[0..<n])
  }
  let text = String(data: data, encoding: .utf8) ?? ""
  let parts = text.components(separatedBy: "\r\n\r\n")
  let head = parts.first ?? ""
  let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? -1
  return (status, head, parts.dropFirst().joined(separator: "\r\n\r\n"))
}

func testUpstreamErrors() {
  let fake = FakeTwitch()
  let session = StreamSession(login: "streamer", config: StreamSessionConfig(), http: fake, tokens: fake, log: ActivityLog())
  runAsync {
    _ = try! await session.start()
    let first = await session.mediaPlaylist(0)
    fake.lock.lock(); fake.mainMediaStatus = 500; fake.lock.unlock()
    let hiccup = await session.mediaPlaylist(0)
    check(hiccup.status == 200 && hiccup.body == first.body, "transient error serves last playlist")
    fake.lock.lock(); fake.mainMediaStatus = 404; fake.lock.unlock()
    let gone = await session.mediaPlaylist(0)
    check(gone.status == 404, "stream gone -> 404 (\(gone.status))")
  }
}

func testLocalServer() {
  // Blocking socket calls stay off the Swift concurrency pool (like AVPlayer, a separate client).
  let fake = FakeTwitch()
  let session = StreamSession(login: "streamer", config: StreamSessionConfig(), http: fake, tokens: fake, log: ActivityLog())
  runAsync { _ = try! await session.start() }
  let proxy = StreamProxy()
  let master = try! proxy.register(session)
  let port = UInt16(master.port!)
  let base = "/live/\(session.id)"
  let m = rawGET(port, "\(base)/master.m3u8")
  check(m.status == 200 && m.body.contains("v/0.m3u8"), "master over HTTP: \(m.status)")
  check(m.headers.contains("Content-Type: application/vnd.apple.mpegurl"), "content type")
  check(m.headers.contains("Content-Length: \(m.body.utf8.count)"), "content length")
  let v = rawGET(port, "\(base)/v/1.m3u8")
  check(v.status == 200 && v.body.contains("#EXTINF") && v.body.contains("https://edge.test/"), "media over HTTP")
  check(rawGET(port, "/live/nope/master.m3u8").status == 404, "unknown session 404")
  check(rawGET(port, "\(base)/v/9.m3u8").status == 404, "unknown variant 404")
  let published = try! proxy.publish("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://a/b.m3u8\n", id: "ll-1")
  let fixed = rawGET(port, published.path)
  check(fixed.status == 200 && fixed.body.contains("https://a/b.m3u8"), "static playlist \(fixed.status)")
  proxy.remove("ll-1")
  check(rawGET(port, published.path).status == 404, "static playlist removed")
  let lock = NSLock()
  var statuses: [Int] = []
  DispatchQueue.concurrentPerform(iterations: 30) { i in
    let status = rawGET(port, "\(base)/v/\(i % 3).m3u8").status
    lock.lock()
    statuses.append(status)
    lock.unlock()
  }
  check(statuses.count == 30 && statuses.allSatisfy { $0 == 200 }, "concurrent \(statuses)")
  // Restart keeps the port, so AVPlayer's URLs stay valid after iOS reclaims the socket.
  let newPort = try! proxy.restart()
  check(newPort == port, "restart port \(newPort) vs \(port)")
  check(rawGET(port, "\(base)/master.m3u8").status == 200, "after restart")
  runAsync {
    let client = URLSessionHTTPClient(timeout: 5)
    let viaURLSession = try? await client.data(for: URLRequest(url: master))
    check(viaURLSession?.1.statusCode == 200, "URLSession request")
    await proxy.ensureResponsive()
  }
  check(proxy.isAlive && rawGET(port, "/ping").status == 200, "still responsive after ping check")
}

func testIRC() {
  let raw = "@badge-info=subscriber/14;badges=subscriber/12,premium/1;color=#FF4500;display-name=Some\\sUser;emotes=25:0-4,12-16/1902:6-10;id=abc-123;login=someuser;tmi-sent-ts=1700000000000 :someuser!someuser@someuser.tmi.twitch.tv PRIVMSG #chan :Kappa Keepo Kappa catJAM 😀 ok"
  let irc = IRCMessage.parse(raw)!
  check(irc.command == "PRIVMSG" && irc.params == ["#chan", "Kappa Keepo Kappa catJAM 😀 ok"], "params \(irc.params)")
  check(irc.tags["display-name"] == "Some User", "unescape")
  let message = ChatMessage(irc: irc)!
  check(message.badges == ["subscriber/12", "premium/1"] && message.color == "#FF4500", "badges")
  let fragments = message.fragments(thirdParty: ["catJAM": URL(string: "https://cdn.7tv.app/emote/1/2x.webp")!])
  let kinds = fragments.map { f -> String in
    switch f {
    case .text(let t): return "t(\(t))"
    case .emote(let n, _): return "e(\(n))"
    }
  }
  check(kinds == ["e(Kappa)", "t( )", "e(Keepo)", "t( )", "e(Kappa)", "t( )", "e(catJAM)", "t( 😀 ok)"], "fragments \(kinds)")

  // Emote positions count Unicode scalars (emoji before an emote).
  let emoji = IRCMessage.parse("@emotes=25:2-6;id=x :a!a@a PRIVMSG #c :😀 Kappa")!
  let emojiFragments = ChatMessage(irc: emoji)!.fragments(thirdParty: [:])
  check(emojiFragments.count == 2 && emojiFragments[1] == .emote(name: "Kappa", url: ChatMessage.twitchEmoteURL("25")!), "scalar indices \(emojiFragments)")

  let action = ChatMessage(irc: IRCMessage.parse(":a!a@a PRIVMSG #c :\u{1}ACTION waves\u{1}")!)!
  check(action.kind == .action && action.text == "waves", "action")
  let sub = ChatMessage(irc: IRCMessage.parse("@system-msg=X\\ssubscribed!;login=x;id=s1 :tmi.twitch.tv USERNOTICE #c")!)!
  check(sub.kind == .system && sub.systemText == "X subscribed!" && sub.text.isEmpty, "usernotice")
  check(IRCMessage.parse("PING :tmi.twitch.tv")!.command == "PING", "ping")
  check(ChatMessage(irc: IRCMessage.parse(":tmi.twitch.tv 001 justinfan1 :Welcome")!) == nil, "numeric ignored")
}

func testOwnEmotes() {
  let sent = ChatMessage(sent: "hi Kappa  catJAM Kappa", userState: [:], login: "me", emoteIDs: ["Kappa": "25"])
  check(sent.emotes.count == 2 && sent.emotes[0].range == 3...7 && sent.emotes[1].range == 17...21, "\(sent.emotes)")
  let fragments = sent.fragments(thirdParty: ["catJAM": URL(string: "https://cdn.7tv.app/emote/1/2x.webp")!])
  check(fragments.filter { if case .emote = $0 { return true } else { return false } }.count == 3, "\(fragments)")
}

func testEmoteParsers() {
  let seventv = JSONValue(try! JSONSerialization.jsonObject(with: Data("""
    {"emotes":[{"name":"catJAM","data":{"host":{"url":"//cdn.7tv.app/emote/60ae","files":[{"name":"1x.webp","format":"WEBP"},{"name":"2x.webp","format":"WEBP"}]}}}]}
    """.utf8)))
  check(ThirdPartyEmotes.parse7TV(seventv["emotes"])["catJAM"]?.absoluteString == "https://cdn.7tv.app/emote/60ae/2x.webp", "7tv")
  let bttv = JSONValue(try! JSONSerialization.jsonObject(with: Data(#"[{"id":"566c","code":"FeelsGoodMan"}]"#.utf8)))
  check(ThirdPartyEmotes.parseBTTV(bttv.array)["FeelsGoodMan"]?.absoluteString == "https://cdn.betterttv.net/emote/566c/2x.webp", "bttv")
  let ffz = JSONValue(try! JSONSerialization.jsonObject(with: Data(#"{"sets":{"3":{"emoticons":[{"name":"OMEGALUL","urls":{"1":"https://cdn.frankerfacez.com/emote/128054/1","2":"https://cdn.frankerfacez.com/emote/128054/2"}}]}}}"#.utf8)))
  check(ThirdPartyEmotes.parseFFZ(ffz["sets"])["OMEGALUL"]?.absoluteString.hasSuffix("/2") == true, "ffz")
}

func testAPIParsing() {
  check(TwitchAPI.image("https://x/a-{width}x{height}.jpg", width: 440, height: 248)?.absoluteString == "https://x/a-440x248.jpg", "template")
  check(TwitchAPI.image("https://x/a-320x180.jpg", width: 640, height: 360)?.absoluteString == "https://x/a-640x360.jpg", "regex")
  check(TwitchAPI.image("https://x/v-%{width}x%{height}.jpg", width: 1, height: 2)?.absoluteString == "https://x/v-1x2.jpg", "percent")
  let node = JSONValue(try! JSONSerialization.jsonObject(with: Data("""
    {"broadcaster":{"broadcastSettings":{"title":"hi"},"displayName":"Name","id":"1","login":"name","profileImageURL":"p"},"createdAt":"2026-10-21T07:00:04Z","game":{"displayName":"Just Chatting","id":"509658","slug":"just-chatting"},"id":"99","previewImageURL":"u","viewersCount":1234}
    """.utf8)))
  let stream = TwitchAPI.stream(node)!
  check(stream.title == "hi" && stream.viewers == 1234 && stream.category?.name == "Just Chatting" && stream.channel.login == "name", "stream decode")
  let url = Usher.live(login: "SomeOne", token: PlaybackToken(value: "{\"a\":1}", signature: "abc"), codecs: "h264", lowLatency: true)
  check(url.path == "/api/v2/channel/hls/someone.m3u8", "usher path")
  check(url.query!.contains("token=%7B%22a%22%3A1%7D") && url.query!.contains("fast_bread=true") && url.query!.contains("sig=abc"), "usher query \(url.query!)")
  check(url.query!.contains("multigroup_video=true") && url.query!.contains("supported_codecs=h264"), "usher enhanced params")
}

func testFullWindowAdDetection() {
  // A long break fills the whole playlist window: no "live" title left to compare against.
  let fake = FakeTwitch()
  fake.liveIndex = 40
  fake.adTitle = "3f0b6c2e-9d1a-4c8e-b1f2-7a6d5e4c3b2a"
  let all = HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 30..<60), base: nil)
  check(all.regularSegments.allSatisfy(\.isAd) && all.adBreakActive && !all.isClean, "whole-window ad with ID titles")
  fake.adTitle = "Amazon|5555"
  let amazon = HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 30..<60), base: nil)
  check(amazon.adBreakActive, "whole-window Amazon ad")
  let csai = HLSMediaPlaylist.parse(fake.mediaPlaylist(tag: "t", ads: 30..<60, markersOnly: true), base: nil)
  check(csai.isClean && !csai.adBreakActive, "markers over live segments stay client-side")
}

final class UpdateBox: @unchecked Sendable {
  let lock = NSLock()
  var updates: [LowLatencyUpdate] = []
  func add(_ update: LowLatencyUpdate) {
    lock.lock()
    updates.append(update)
    lock.unlock()
  }
  var last: LowLatencyUpdate? {
    lock.lock()
    defer { lock.unlock() }
    return updates.last
  }
}

func testLowLatencySession() {
  // Clean stream and client-side breaks: Twitch's playlist passes through with its low-latency
  // tags, minus ad markers.
  runAsync {
    let fake = FakeTwitch()
    fake.mainMarkers = 26..<34
    let box = UpdateBox()
    let session = LowLatencySession(login: "streamer", config: LowLatencyConfig(), http: fake, tokens: fake, log: ActivityLog()) {
      box.add($0)
    }
    let variants = try! await session.start()
    check(variants.count == 4 && !variants.contains { $0.isPortrait }, "variants \(variants.map(\.label))")
    let master = await session.masterPlaylist(only: nil)
    check(master.contains("v/0.m3u8") && master.contains("v/3.m3u8") && !master.contains("v/4.m3u8"), "local master \(master)")
    check(master.contains("IVS-NAME=\"1080p60\"") && !master.contains("portrait"), "attributes kept, portrait gone")
    let normal = await session.mediaPlaylist(0)
    check(normal.status == 200 && normal.body.contains("#EXT-X-TWITCH-PREFETCH:https://edge.test/"), "prefetch kept: \(normal.body)")
    fake.advance(4)  // the announced break reaches the live edge
    let announced = await session.mediaPlaylist(0)
    check(!announced.body.contains("DATERANGE:ID=\"stitched"), "ad marker removed")
    check(!announced.body.contains("TWITCH-PREFETCH"), "prefetch held back while an ad is announced")
    check(announced.body.contains("#EXTINF:2.000,live") && announced.body.contains("https://edge.test/"), "segments kept")
    check(box.last?.state == .skipped, "client-side break shown as skipped: \(String(describing: box.last?.state))")
    let main = fake.mainToken!
    check(!announced.body.contains("edge.test/tok") || announced.body.components(separatedBy: "\n").filter { $0.hasPrefix("https://edge.test/") }.allSatisfy { $0.hasPrefix("https://edge.test/\(main)-") }, "only the main stream served")
    fake.advance(12)  // break over
    let after = await session.mediaPlaylist(0)
    check(after.body.contains("TWITCH-PREFETCH"), "prefetch back after the break")
  }

  // Stitched ad with an ad-free copy available: the copy's playlist is served.
  runAsync {
    let fake = FakeTwitch()
    fake.mainAds = 21..<26
    fake.backupAds = ["site": 0..<100, "popout": 0..<100, "mobile_web": 0..<0, "embed": 0..<100]
    let box = UpdateBox()
    let log = ActivityLog()
    let session = LowLatencySession(login: "streamer", config: LowLatencyConfig(), http: fake, tokens: fake, log: log) { box.add($0) }
    _ = try! await session.start()
    var adSegments = 0
    var usedBackup = false
    var sawMainAfter = false
    for step in 0..<16 {
      let result = await session.mediaPlaylist(0)
      check(result.status == 200, "status \(result.status) at \(step)")
      adSegments += result.body.components(separatedBy: "/ad-").count - 1
      let main = fake.mainToken ?? "?"
      let segments = result.body.components(separatedBy: "\n").filter { $0.hasPrefix("https://edge.test/") }
      if segments.contains(where: { !$0.hasPrefix("https://edge.test/\(main)-") }) {
        usedBackup = true
        check(result.body.contains("#EXT-X-TWITCH-PREFETCH:"), "copy keeps low latency")
      }
      if usedBackup, let main = fake.mainToken, result.body.contains("edge.test/\(main)-") { sawMainAfter = true }
      fake.advance()
    }
    check(adSegments == 0, "an ad segment reached the player \(adSegments) times")
    check(usedBackup && sawMainAfter, "switched to the copy and back (\(usedBackup), \(sawMainAfter))")
    check(log.messages.contains { $0.contains("Switched to ad-free copy (mobile_web") }, "\(log.messages)")
    check(box.last?.state == AdState.none, "state cleared after the break")
  }

  // No ad-free copy: the ad goes through without prefetch, and the app is told to hide it.
  runAsync {
    let fake = FakeTwitch()
    fake.mainAds = 21..<40
    fake.liveIndex = 24
    fake.adTitle = "3f0b6c2e-9d1a"
    fake.backupAds = ["site": 0..<100, "popout": 0..<100, "mobile_web": 0..<100, "embed": 0..<100, "autoplay": 0..<100]
    let box = UpdateBox()
    var config = LowLatencyConfig()
    config.firstPollWait = 2
    let session = LowLatencySession(login: "streamer", config: config, http: fake, tokens: fake, log: ActivityLog()) { box.add($0) }
    _ = try! await session.start()
    let first = await session.mediaPlaylist(0)
    check(first.body.contains("/ad-") && !first.body.contains("TWITCH-PREFETCH"), "ad served without prefetch")
    check(box.last?.state == .covering && box.last?.ads.isActive == true, "app told to cover")
    check(box.last?.ads.covers(fake.pdt(21).addingTimeInterval(1)) == true, "ad time range known")
  }

  // Upstream hiccup: the last playlist is repeated; a gone stream is passed on.
  runAsync {
    let fake = FakeTwitch()
    let session = LowLatencySession(login: "streamer", config: LowLatencyConfig(), http: fake, tokens: fake, log: ActivityLog())
    _ = try! await session.start()
    let good = await session.mediaPlaylist(1)
    fake.mainMediaStatus = 502
    let hiccup = await session.mediaPlaylist(1)
    check(hiccup.status == 200 && hiccup.body == good.body, "hiccup repeats last playlist")
    fake.mainMediaStatus = 404
    let gone = await session.mediaPlaylist(1)
    check(gone.status == 404, "404 passed on")
  }

  // Filtering details.
  let text = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXT-X-DATERANGE:ID="playlist-session-1",CLASS="twitch-session",START-DATE="2026-10-22T00:00:00Z"
    #EXT-X-DATERANGE:ID="stitched-ad-1",CLASS="twitch-stitched-ad",START-DATE="2026-10-22T00:00:00Z",X-TV-TWITCH-AD-URL="https://ads"
    #EXT-X-DATERANGE:ID="q",CLASS="twitch-ad-quartile",START-DATE="2026-10-22T00:00:00Z"
    #EXT-X-DATERANGE:ID="source-1",CLASS="live-video-net-stream-source",START-DATE="2026-10-22T00:00:00Z",X-NET-LIVE-VIDEO-STREAM-SOURCE="0f26"
    #EXT-X-DATERANGE:ID="source-2",CLASS="live-video-net-stream-source",START-DATE="2026-10-22T00:00:00Z",X-NET-LIVE-VIDEO-STREAM-SOURCE="live"
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:2.000,live
    seg1.mp4
    #EXT-X-TWITCH-PREFETCH:seg2.mp4
    """
  let filtered = LowLatencyPlaylist.filter(text, base: URL(string: "https://weaver.test/a/b.m3u8"), dropPrefetch: false)
  check(filtered.contains("playlist-session-1") && filtered.contains("source-2"), "non-ad markers kept")
  check(!filtered.contains("stitched") && !filtered.contains("quartile") && !filtered.contains("source-1"), "ad markers dropped: \(filtered)")
  check(filtered.contains("URI=\"https://weaver.test/a/init.mp4\"") && filtered.contains("\nhttps://weaver.test/a/seg1.mp4\n"), "URIs absolute")
  check(filtered.contains("#EXT-X-TWITCH-PREFETCH:https://weaver.test/a/seg2.mp4"), "prefetch absolute")
  check(!LowLatencyPlaylist.filter(text, base: nil, dropPrefetch: true).contains("PREFETCH"), "prefetch dropped")

  // Served over the local server like any other source.
  let fake = FakeTwitch()
  let session = LowLatencySession(login: "streamer", config: LowLatencyConfig(), http: fake, tokens: fake, log: ActivityLog())
  runAsync { _ = try! await session.start() }
  let proxy = StreamProxy()
  let url = try! proxy.register(session)
  let port = UInt16(url.port!)
  let master = rawGET(port, url.path)
  check(master.status == 200 && master.body.contains("v/0.m3u8"), "LL master over HTTP")
  let media = rawGET(port, "/live/\(session.id)/v/0.m3u8")
  check(media.status == 200 && media.body.contains("#EXT-X-TWITCH-PREFETCH"), "LL media over HTTP")
}

func testTokenInfo() {
  let anonymous = PlaybackToken(
    value: #"{"adblock":false,"chansub":{"restricted_bitrates":[],"view_until":1924905600},"hide_ads":false,"server_ads":true,"show_ads":true,"subscriber":false,"turbo":false,"user_id":null}"#,
    signature: "s")
  check(anonymous.info?.signedIn == false && anonymous.info?.showAds == true, "anonymous info")
  check(anonymous.summary == "Twitch session: ads possible (not signed in)", anonymous.summary)
  let turbo = PlaybackToken(
    value: #"{"chansub":{"restricted_bitrates":["chunked"]},"hide_ads":true,"server_ads":false,"show_ads":false,"subscriber":false,"turbo":true,"user_id":123456}"#,
    signature: "s")
  check(turbo.info?.signedIn == true && turbo.info?.turbo == true, "turbo info")
  check(turbo.summary == "Twitch session: no ads (signed in, Turbo); subscriber-only qualities: chunked", turbo.summary)
  check(PlaybackToken(value: "not json", signature: "").info == nil, "bad token value")
  // Proxy settings build a session without crashing (credentials included).
  let client = URLSessionHTTPClient(timeout: 5, proxy: HTTPProxy(host: "proxy.example", port: 8080, username: "u", password: "p"))
  check(client.proxy?.description == "proxy.example:8080", "proxy client")
}

final class ProxyFake: HTTPClient, @unchecked Sendable {
  let twitch: FakeTwitch
  var requested: [String] = []
  init(_ twitch: FakeTwitch) { self.twitch = twitch }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    requested.append(url.host ?? "")
    if url.host == "down.test" { throw URLError(.timedOut) }
    if url.host == "proxy.test" {
      check(url.path == "/live/streamer" && url.query?.contains("allow_source=true") == true, "proxy URL \(url)")
      // The proxy answers with an ad-free session's master playlist.
      let token = try await twitch.streamToken(login: "streamer", playerType: "proxy", platform: "web")
      let master = Usher.live(login: "streamer", token: token, codecs: "h264", lowLatency: true)
      var (data, response) = try await twitch.data(for: URLRequest(url: master))
      data = Data(("#EXTM3U\n#EXT-X-TWITCH-INFO:NODE=\"x\",USER-COUNTRY=\"RU\"\n" + String(decoding: data, as: UTF8.self).dropFirst(8)).utf8)
      return (data, HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: nil, headerFields: [:])!)
    }
    return try await twitch.data(for: request)
  }
}

func testAccountRoute() {
  // Signed in with a sub: Twitch says no ads, so the ad-free servers aren't asked at all.
  runAsync {
    let twitch = FakeTwitch()
    twitch.subscriberAccount = true
    let http = ProxyFake(twitch)
    let log = ActivityLog()
    var config = LowLatencyConfig()
    config.adFreeProxies = ["proxy.test"]
    config.checkAccountFirst = true
    let session = LowLatencySession(login: "streamer", config: config, http: http, tokens: twitch, log: log)
    _ = try! await session.start()
    let route = await session.route
    check(route == .twitchAdFree("subscribed"), "sub plays direct: \(route)")
    check(!http.requested.contains("proxy.test"), "no proxy request: \(http.requested)")
    check(log.messages.contains { $0.contains("playing straight from Twitch") }, "\(log.messages)")
  }
  // Signed in without a sub: the token says ads are possible, so the server is used, and the
  // token already fetched is reused if the servers fail.
  runAsync {
    let twitch = FakeTwitch()
    let http = ProxyFake(twitch)
    var config = StreamSessionConfig()
    config.adFreeProxies = ["down.test"]
    config.checkAccountFirst = true
    let session = StreamSession(login: "streamer", config: config, http: http, tokens: twitch, log: ActivityLog()) { _, _ in }
    _ = try! await session.start()
    let route = await session.route
    check(route == .twitch, "falls back to Twitch: \(route)")
    check(twitch.tokenRequests == ["popout"], "one token: \(twitch.tokenRequests)")
  }
}

func testStoryboard() {
  let json = """
    [{"count":120,"width":220,"rows":10,"images":["v1-low-0.jpg"],"interval":15,"quality":"low","height":124,"cols":12},
     {"count":120,"width":320,"rows":5,"images":["v1-high-0.jpg","v1-high-1.jpg","v1-high-2.jpg"],"interval":15,"quality":"high","height":180,"cols":8}]
    """
  let base = URL(string: "https://cdn.test/abc_streamer_1/storyboards/v1-info.json")!
  let board = Storyboard.parse(Data(json.utf8), base: base, duration: nil)
  check(board?.width == 320 && board?.images.count == 3, "sharpest board")
  check(board?.images[1].absoluteString == "https://cdn.test/abc_streamer_1/storyboards/v1-high-1.jpg", "relative image URL")
  // 15 s per thumbnail, 40 per sheet: 700 s = thumbnail 46 = sheet 1, cell 6 (column 6, row 0).
  check(board?.frame(at: 700) == Storyboard.Frame(image: board!.images[1], column: 6, row: 0), "frame math")
  check(board?.frame(at: 1e9)?.image == board?.images[2], "clamped to the last thumbnail")
  let noInterval = #"[{"count":10,"width":100,"rows":2,"images":["a.jpg"],"height":50,"cols":5}]"#
  check(Storyboard.parse(Data(noInterval.utf8), base: base, duration: 100)?.interval == 10, "interval from duration")
  check(Storyboard.parse(Data(noInterval.utf8), base: base, duration: nil) == nil, "needs an interval")
}

func testAdFreeProxy() {
  let url = AdFreeProxy.masterURL(host: "eu.luminous.dev", login: "SomeOne", codecs: "h265,h264", lowLatency: true)!
  check(url.absoluteString.hasPrefix("https://eu.luminous.dev/live/someone?") && url.query!.contains("fast_bread=true"), "\(url)")
  check(AdFreeProxy.userCountry("#EXTM3U\n#EXT-X-TWITCH-INFO:NODE=\"a\",USER-COUNTRY=\"RU\",X=1\n") == "RU", "country")
  check(AdFreeProxy.all.count == 12 && Set(AdFreeProxy.all.map(\.host)).count == 12, "presets")
  // A dead proxy is skipped, the next one delivers, and the stream plays from that session.
  runAsync {
    let twitch = FakeTwitch()
    twitch.mainAds = 0..<100  // the regular session would have ads
    _ = try? await twitch.streamToken(login: "streamer", playerType: "popout", platform: "web")  // that session
    let http = ProxyFake(twitch)
    let log = ActivityLog()
    var config = LowLatencyConfig()
    config.adFreeProxies = ["down.test", "proxy.test"]
    let session = LowLatencySession(login: "streamer", config: config, http: http, tokens: twitch, log: log)
    _ = try! await session.start()
    let route = await session.route
    check(route == .adFreeServer("proxy.test"), "proxy used")
    let media = await session.mediaPlaylist(0)
    check(!media.body.contains("/ad-") && media.body.contains("edge.test/"), "proxied session has no ads")
    check(log.messages.contains { $0.contains("proxy.test delivered the stream, Twitch sees RU") }, "\(log.messages)")
    check(log.messages.contains { $0.contains("down.test didn't answer") }, "\(log.messages)")
    check(twitch.tokenRequests == ["popout", "proxy"], "no regular token needed: \(twitch.tokenRequests)")
  }
}

testAdFreeProxy()
testAccountRoute()
testStoryboard()
testTokenInfo()
testDates()
testMasterParsing()
testFullWindowAdDetection()
testLowLatencySession()
testMediaParsing()
testAdTimeline()
testTimelineAndRender()
testSession(lowLatency: true)
testSession(lowLatency: false)
testClientSideBreak()
testSessionFallback()
testPreroll()
testUpstreamErrors()
testLocalServer()
testIRC()
testEmoteParsers()
testOwnEmotes()
testAPIParsing()
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
