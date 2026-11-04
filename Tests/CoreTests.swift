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
    check(video.count == 6 && video.first?.label == "1440p60" && video.last?.label == "160p", "landscape \(video.map(\.label))")
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
  check(mixed.videoVariants.map(\.codecFamily) == ["hevc", "av1", "avc"], "codec order \(mixed.videoVariants.map(\.codecFamily))")
  check(Set(mixed.videoVariants.map(\.label)) == ["1080p60"], "named without the codec")
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

func testCatchUpHoversWithoutFlipping() {
  // Latency hovering right at the speed-up line (target + 0.3) with a surplus in hand: the speed
  // changes a few times at most, not with every wobble.
  var catchUp = LiveCatchUp(targetBuffer: 0.6, noise: 0.35, now: Date(timeIntervalSince1970: 0))
  var changes = 0
  var previous: Float = 1
  var buffer = 1.06
  var latency = 0.95
  for i in 0..<240 {
    let now = Date(timeIntervalSince1970: 60 + Double(i) * 0.25)
    let wobble = (i % 3 == 0) ? 0.03 : -0.02
    let rate = catchUp.update(buffer: buffer + wobble, latency: latency + wobble, playing: true, position: Double(i) * 0.25, now: now)
    if rate != previous { changes += 1 }
    previous = rate
    // Speeding up brings both down; at 1x, they drift back up to where they were.
    let drain = Double(rate - 1) * 0.25
    buffer = max(0.7, buffer - drain + (rate > 1 ? 0 : 0.01))
    latency = max(0.6, latency - drain + (rate > 1 ? 0 : 0.01))
  }
  check(changes <= 12, "hovering at the line: \(changes) speed changes in a minute")
}

func testCatchUpHoldsOneSpeed() {
  // Catching up from 1.5 s over the margin: one speed until it's done, then normal. Easing off a
  // hundredth at a time changed the speed every couple of seconds, and each change cut the sound.
  var catchUp = LiveCatchUp(targetBuffer: 0.6, now: Date(timeIntervalSince1970: 0))
  var buffer = 2.1
  var rates: [Float] = []
  var position = 0.0
  for i in 0..<240 {
    let now = Date(timeIntervalSince1970: 30 + Double(i) * 0.25)
    let rate = catchUp.update(buffer: buffer, latency: buffer + 0.4, playing: true, position: position, now: now)
    rates.append(rate)
    buffer -= Double(rate - 1) * 0.25
    position += Double(rate) * 0.25
  }
  let changes = zip(rates, rates.dropFirst()).filter { $0 != $1 }.count
  check(changes <= 2 && Set(rates).isSubset(of: [1, LiveCatchUp.rates.gentle, LiveCatchUp.startRate, LiveCatchUp.rates.fast]),
    "one catch-up, one speed: \(changes) changes, speeds \(Set(rates).sorted())")
  check(buffer < 1.3, "caught up: \(buffer) s in hand")
}

func testAV1Init() {
  // An init segment with one AV1 track (2560x1440): its av1C record and size are read.
  func box(_ type: String, _ payload: Data) -> Data {
    var size = UInt32(8 + payload.count).bigEndian
    return Data(bytes: &size, count: 4) + Data(type.utf8) + payload
  }
  func u32(_ v: UInt32) -> Data { var b = v.bigEndian; return Data(bytes: &b, count: 4) }
  let record = Data([0x81, 0x0D, 0x0C, 0x00])
  var visual = Data(count: 24) + Data([0x0A, 0x00, 0x05, 0xA0])  // 2560 x 1440
  visual += Data(count: 50)
  let entry = box("av01", visual + box("av1C", record))
  let stsd = box("stsd", Data(count: 4) + u32(1) + entry)
  let stbl = box("stbl", stsd)
  let minf = box("minf", stbl)
  let mdhd = box("mdhd", Data(count: 12) + u32(90_000) + Data(count: 8))
  let mdia = box("mdia", mdhd + minf)
  let tkhd = box("tkhd", Data(count: 12) + u32(1) + Data(count: 68))
  let moov = box("moov", box("trak", tkhd + mdia))
  let parsed = FMP4Init.parse(box("ftyp", Data("iso6".utf8)) + moov)
  if case .av1(let config) = parsed?.tracks[1]?.kind {
    check(config.record == record && config.width == 2560 && config.height == 1440, "av1C and size: \(config)")
  } else {
    check(false, "AV1 track not found: \(String(describing: parsed))")
  }
}

func testFrameGrid() {
  // 60 fps stamped in whole milliseconds (16, 17, 17 ms): put on the exact 1/60 s grid.
  var grid = FrameGrid()
  var ms = 1000.0
  var out: [Int64] = []
  for i in 0..<300 {
    let raw = Int64(ms.rounded(.down)) * 90
    ms += 1000.0 / 60
    grid.learn(decodeTime: raw)
    let snapped = grid.snap(raw)
    check(abs(snapped - raw) <= 500, "frame \(i) moved at most a third of a frame")
    out.append(snapped)
  }
  check(grid.nominal == 1500, "60 fps found")
  let tail = zip(out.dropFirst(40), out.dropFirst(41)).map { $1 - $0 }
  check(tail.allSatisfy { $0 == 1500 }, "even rhythm once known: \(Set(tail))")
  // A jump starts a new grid instead of pulling frames toward the old one.
  let jumped = grid.snap(out.last! + 1500 * 10 + 700)
  check(jumped == out.last! + 1500 * 10 + 700, "jump kept as is")
  // 59.94 fps in milliseconds: told apart from 60 within a few seconds and kept even after.
  var ntsc = FrameGrid()
  var t = 0.0
  var last: Int64?
  var steps: Set<Int64> = []
  for i in 0..<1200 {
    let raw = Int64(t.rounded(.down)) * 90
    t += 1001.0 / 60
    ntsc.learn(decodeTime: raw)
    let snapped = ntsc.snap(raw)
    if i > 600, let last { steps.insert(snapped - last) }
    last = snapped
  }
  check(ntsc.nominal == 90_000 / (60000.0 / 1001), "59.94 fps found")
  check(steps.isSubset(of: [1501, 1502]), "59.94 kept even: \(steps)")
  // An odd rate is left alone.
  var odd = FrameGrid()
  for i in 0..<100 { odd.learn(decodeTime: Int64(i) * 2200) }
  check(odd.nominal == nil && odd.snap(12345) == 12345, "unknown rate untouched")
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
    case .gif(let n, _): return "g(\(n))"
    }
  }
  check(kinds == ["e(Kappa)", "t( )", "e(Keepo)", "t( )", "e(Kappa)", "t( )", "e(catJAM)", "t( 😀 ok)"], "fragments \(kinds)")

  // GIFs from Twitch's GIF keyboard: the `gifs` tag (a comma inside a URL doesn't split it).
  let gifRaw = "@gifs=0-12|joSNxe|https://media.giphy.com/media/joSNxe/giphy.gif?cid=a,b&rid=giphy.gif,14-18|k2|https://media.giphy.com/media/k2/giphy.gif;id=g1;login=a :a!a@a PRIVMSG #c :happy dancing Hello"
  let gifMessage = ChatMessage(irc: IRCMessage.parse(gifRaw)!)!
  check(gifMessage.gifs.count == 2 && gifMessage.gifs[0].id == "joSNxe" && gifMessage.gifs[0].url.absoluteString.hasSuffix("cid=a,b&rid=giphy.gif"), "gifs tag: \(gifMessage.gifs)")
  let gifFragments = gifMessage.fragments(thirdParty: [:])
  check(gifFragments.count == 3 && gifFragments[0] == .gif(name: "happy dancing", url: gifMessage.gifs[0].url) && gifFragments[1] == .text(" "), "gif fragments: \(gifFragments)")
  check(ChatMessage.parseGifs("x|y").isEmpty && ChatMessage.parseGifs("0-3|id|http://insecure").isEmpty, "bad gifs ignored")

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

func testChatReplay() {
  // A fake VOD chat: a message every 2 s for an hour. The API returns up to 40 messages from the
  // asked offset (only by offset, like Twitch for other apps).
  let all = (0..<1800).map { n -> ReplayComment in
    var message = ChatMessage(notice: "m\(n)")
    message.id = "id\(n)"
    return ReplayComment(offset: Double(n * 2), message: message)
  }
  func page(_ offset: Int) -> [ReplayComment] { Array(all.filter { $0.offset >= Double(offset) }.prefix(40)) }
  var buffer = ChatReplayBuffer()
  var shown: [String] = []
  var fetches = 0
  let start = Date(timeIntervalSince1970: 0)
  _ = buffer.move(to: 300)  // opened at 5:00
  // Ten minutes of playback, ticking twice a second; each fetch answers right away.
  for tick in 0...1200 {
    let position = 300 + Double(tick) * 0.5
    _ = buffer.move(to: position)
    while let offset = buffer.fetchNeeded(now: start.addingTimeInterval(Double(tick) / 2)) {
      fetches += 1
      buffer.received(page(offset), for: offset, generation: buffer.generation)
      if fetches > 500 { break }
    }
    shown += buffer.due().map(\.text)
  }
  check(shown.first == "m140" && shown.last == "m450", "replay ran from 4:40 to 15:00: \(shown.first ?? "-") … \(shown.last ?? "-")")
  check(Set(shown).count == shown.count && shown.count == 311, "every message once: \(shown.count)")
  check(fetches < 30, "paged sensibly: \(fetches)")
  // A seek back starts over; a late page for the old position is ignored.
  let old = buffer.generation
  check(buffer.move(to: 60), "seek detected")
  buffer.received(page(900), for: 900, generation: old)
  check(buffer.due().isEmpty, "stale page ignored")
  let offset = buffer.fetchNeeded(now: start)
  check(offset == 40, "refetch from just before: \(offset ?? -1)")
  buffer.received(page(40), for: 40, generation: buffer.generation)
  check(buffer.due().map(\.text).first == "m20", "context before the seek point")
  // The end of the chat (a recording VOD has no more yet): wait before asking again.
  var end = ChatReplayBuffer()
  _ = end.move(to: 3600)
  var endFetches = 0
  while let offset = end.fetchNeeded(now: start), endFetches < 10 {
    endFetches += 1
    end.received(page(offset), for: offset, generation: end.generation, now: start)
  }
  check(endFetches <= 3, "finds the end quickly: \(endFetches)")
  _ = end.move(to: 3600.5)
  check(end.due().last?.text == "m1799", "last message shown")
  check(end.fetchNeeded(now: start.addingTimeInterval(5)) == nil, "no hammering at the end")
  check(end.fetchNeeded(now: start.addingTimeInterval(25)) != nil, "asks again later")
}

func testEmoteText() {
  let emotes: Set<String> = ["Kappa", "catJAM"]
  // A finished emote (space after it) is a picture; one still being typed stays text.
  var layout = EmoteText.pieces("hi Kappa ", cursor: 9) { emotes.contains($0) }
  check(layout.pieces == [.text("hi"), .text(" "), .emote("Kappa"), .text(" ")] && layout.cursor == 5, "\(layout)")
  layout = EmoteText.pieces("hi Kappa", cursor: 8) { emotes.contains($0) }
  check(layout.pieces == [.text("hi"), .text(" "), .text("Kappa")] && layout.cursor == 8, "still typing: \(layout)")
  // The cursor inside an emote's name lands after its picture; elsewhere it keeps its place.
  layout = EmoteText.pieces("Kappa catJAM yo", cursor: 2) { emotes.contains($0) }
  check(layout.pieces == [.emote("Kappa"), .text(" "), .emote("catJAM"), .text(" "), .text("yo")] && layout.cursor == 1, "\(layout)")
  layout = EmoteText.pieces("Kappa catJAM yo", cursor: 14) { emotes.contains($0) }
  check(layout.cursor == 5, "cursor in trailing text: \(layout.cursor)")
  layout = EmoteText.pieces("Kappa catJAM yo", cursor: 6) { emotes.contains($0) }
  check(layout.cursor == 2, "cursor before the second emote: \(layout.cursor)")
  layout = EmoteText.pieces("", cursor: 0) { emotes.contains($0) }
  check(layout.pieces.isEmpty && layout.cursor == 0, "empty")
  layout = EmoteText.pieces("👋 Kappa ", cursor: 9) { emotes.contains($0) }
  check(layout.pieces.last == .text(" ") && layout.cursor == 5, "UTF-16 counting: \(layout.cursor)")
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
    // Only the ad from before the switch is covered, not the rest of the break (the player was on
    // the clean copy by then: covering it put "Skipping an ad" over the stream).
    check(box.last?.ads.covers(fake.pdt(24).addingTimeInterval(1)) == false, "clean copy not covered")
  }

  // A stream that opens on an ad, with an ad-free copy: the player never got any of the ad, so
  // nothing is covered (it put "Skipping an ad" over the clean copy for a couple of seconds).
  runAsync {
    let fake = FakeTwitch()
    fake.mainAds = 0..<60
    fake.backupAds = ["site": 0..<100, "popout": 0..<100, "mobile_web": 0..<0, "embed": 0..<100]
    let box = UpdateBox()
    let session = LowLatencySession(login: "streamer", config: LowLatencyConfig(), http: fake, tokens: fake, log: ActivityLog()) { box.add($0) }
    _ = try! await session.start()
    for _ in 0..<3 {
      _ = await session.mediaPlaylist(0)
      fake.advance()
    }
    let covered = (fake.liveIndex - 8...fake.liveIndex + 2).filter { box.last?.ads.covers(fake.pdt($0).addingTimeInterval(0.5)) == true }
    check(covered.isEmpty, "opening ad, clean copy: nothing covered (\(covered))")
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
    if url.host == "hang.test" {
      // Never answers (until its timeout).
      try await Task.sleep(nanoseconds: 6_000_000_000)
      throw URLError(.timedOut)
    }
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

func testVODPlaylists() {
  let base = URL(string: "https://vod.test/abc_streamer_1/chunked/index-dvr.m3u8")!
  let upstream = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:10
    #EXT-X-PLAYLIST-TYPE:EVENT
    #EXT-X-MEDIA-SEQUENCE:0
    #EXTINF:10.000,
    0-unmuted.ts
    #EXTINF:10.000,
    1-muted.ts
    #EXTINF:10.000,
    2.ts
    """
  let rewritten = VODPlaylists.rewrite(upstream, base: base)
  check(rewritten.contains("https://vod.test/abc_streamer_1/chunked/0-muted.ts\n"), "muted part renamed: \(rewritten)")
  check(rewritten.contains("https://vod.test/abc_streamer_1/chunked/1-muted.ts") && rewritten.contains("/chunked/2.ts"), "absolute URIs")
  check(!rewritten.contains("unmuted") && VODPlaylists.isGrowing(rewritten), "growing VOD")
  // Served through the local server.
  final class Upstream: HTTPClient, @unchecked Sendable {
    let body: String
    private let lock = NSLock()
    private var _requests = 0
    var requests: Int { lock.lock(); defer { lock.unlock() }; return _requests }
    init(_ body: String) { self.body = body }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      lock.lock()
      _requests += 1
      lock.unlock()
      return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
  }
  let variant = HLSVariant(
    uri: base.absoluteString, bandwidth: 6_000_000, width: 1920, height: 1080, frameRate: 60, codecs: "avc1.64002A,mp4a.40.2",
    name: "1080p60", isAudioOnly: false, isPortrait: false)
  let counter = Upstream(upstream)
  let source = VODPlaylists(variants: [variant], http: counter)
  runAsync {
    // Fetched ahead (when the seek bar is touched): the player's own request is then instant.
    await source.prefetch(0)
    let media = await source.mediaPlaylist(0)
    check(counter.requests == 1, "prefetched playlist reused: \(counter.requests) requests")
    check(media.status == 200 && media.body.contains("0-muted.ts"), "served media playlist")
    // Still recording: served as a finished VOD of what's there so far.
    check(media.body.contains("#EXT-X-PLAYLIST-TYPE:VOD") && !media.body.contains("EVENT"), "VOD type: \(media.body)")
    check(media.body.hasSuffix("#EXT-X-ENDLIST\n"), "closed off")
    check(source.isRecording && source.recordedSeconds == 30, "recording, 30 s so far: \(source.recordedSeconds)")
    let master = await source.masterPlaylist(only: nil)
    check(master.contains("RESOLUTION=1920x1080") && master.contains("v/0.m3u8"), master)
  }
}

func testStreamTags() {
  let json = """
    {"id":"s1","viewersCount":1234,"previewImageURL":"https://x/{width}x{height}.jpg","createdAt":"2026-10-22T01:02:03Z",
     "game":{"id":"g","displayName":"Just Chatting"},
     "broadcaster":{"id":"1","login":"someone","displayName":"Someone","broadcastSettings":{"title":"Hello"}},
     "freeformTags":[{"name":"English"},{"name":"Chill"}]}
    """
  let stream = TwitchAPI.stream(JSONValue(try! JSONSerialization.jsonObject(with: Data(json.utf8))))
  check(stream?.tags == ["English", "Chill"] && stream?.title == "Hello" && stream?.category?.name == "Just Chatting", "tags parsed")
  let untagged = TwitchAPI.stream(JSONValue(try! JSONSerialization.jsonObject(with: Data(#"{"broadcaster":{"id":"1","login":"a"}}"#.utf8))))
  check(untagged?.tags == [], "no tags")
}

func testVODComments() {
  let json = """
    {"video":{"comments":{"edges":[
      {"cursor":"c1","node":{"id":"m1","contentOffsetSeconds":12,"createdAt":"2026-10-22T01:02:03Z",
        "commenter":{"displayName":"Viewer","id":"1","login":"viewer"},
        "message":{"fragments":[{"text":"hi ","emote":null},{"text":"Kappa","emote":{"emoteID":"25"}},{"text":" 👋 ok","emote":null}],
          "userBadges":[{"setID":"subscriber","version":"12"},{"setID":"","version":""}],"userColor":"#FF0000"}}}],
      "pageInfo":{"hasNextPage":true}}}}
    """
  let data = JSONValue(try! JSONSerialization.jsonObject(with: Data(json.utf8)))
  let page = VODComments.parsePage(data)
  check(page.comments.count == 1 && page.cursor == "c1" && page.hasMore, "page")
  let comment = page.comments.first
  check(comment?.offset == 12 && comment?.message.text == "hi Kappa 👋 ok", "text")
  check(comment?.message.emotes.first?.range == 3...7 && comment?.message.emotes.first?.id == "25", "emote range")
  check(comment?.message.badges == ["subscriber/12"] && comment?.message.color == "#FF0000", "badges and color")
}

func testLiveCatchUp() {
  let t0 = Date(timeIntervalSince1970: 1_000_000)
  var catchUp = LiveCatchUp(now: t0)
  // Settling after a start: normal speed.
  check(catchUp.update(buffer: 2.5, latency: 3.5, playing: true, now: t0) == 1)
  // Far more than needed in hand (well after the start): faster in proportion, easing off as it
  // nears the margin (never faster again on the way down), stopping at it without overshooting.
  var t = t0.addingTimeInterval(45)
  var buffer = 4.2
  var rates: [Float] = []
  var lowest = buffer
  for _ in 0..<400 {
    let rate = catchUp.update(buffer: buffer, latency: buffer + 1, playing: true, now: t)
    rates.append(rate)
    buffer -= Double(rate - 1) * 0.5
    lowest = min(lowest, buffer)
    t += 0.5
  }
  let easing = zip(rates, rates.dropFirst()).allSatisfy { $0 >= $1 }
  check((rates.first ?? 1) > 1 && easing && rates.last == 1, "eases in: \(Set(rates).sorted())")
  check((rates.first ?? 9) <= LiveCatchUp.rates.medium, "gently")
  check(abs(buffer - catchUp.targetBuffer) < 0.3, "ends at the margin: \(buffer)")
  check(lowest >= catchUp.targetBuffer - 0.2, "without overshooting: \(lowest)")
  check(catchUp.targetBuffer <= LiveCatchUp.minBuffer + 0.001, "spending the extra on purpose isn't a hiccup")
  // Paused or buffering: normal speed. Close to live already: leave it.
  check(catchUp.update(buffer: 3, latency: 4, playing: false, now: t) == 1)
  check(catchUp.update(buffer: catchUp.targetBuffer + 0.3, latency: catchUp.targetBuffer + 0.3, playing: true, now: t + 0.5) == 1)

  // Just started: whatever's over the margin is how far back it joined, caught up straight away and
  // within seconds.
  var start = LiveCatchUp(now: t0)
  var st = t0.addingTimeInterval(1.5)
  var joined = 1.6
  check(start.update(buffer: joined, latency: joined + 1, playing: true, now: st) > 1, "at once")
  var closeAt: Date?
  while st < t0.addingTimeInterval(60) {
    st += 0.5
    let rate = start.update(buffer: joined, latency: joined + 1, playing: true, now: st)
    joined -= Double(rate - 1) * 0.5
    if closeAt == nil, joined <= start.targetBuffer + 0.2 { closeAt = st }
  }
  check((closeAt ?? .distantFuture) <= t0.addingTimeInterval(30), "close to live within seconds: \(String(describing: closeAt))")
  // A fresh start a few seconds behind (the first connections are slow): up to 1.2× at first,
  // close to live within half a minute.
  var fresh = LiveCatchUp(now: t0)
  var f = t0.addingTimeInterval(1)
  var freshHeld = 4.0
  var freshRates: [Float] = []
  var freshCloseAt: Date?
  while f < t0.addingTimeInterval(90) {
    f += 0.5
    let rate = fresh.update(buffer: freshHeld, latency: freshHeld + 1, playing: true, now: f)
    freshRates.append(rate)
    freshHeld -= Double(rate - 1) * 0.5
    if freshCloseAt == nil, freshHeld <= fresh.targetBuffer + 0.2 { freshCloseAt = f }
  }
  check(freshRates.max() == LiveCatchUp.rates.fast, "quicker when far back at the start")
  check((freshCloseAt ?? .distantFuture) <= t0.addingTimeInterval(35), "close to live in half a minute: \(String(describing: freshCloseAt))")

  // Video arriving in pieces: the reading goes up and down around an average a little over the
  // margin. Hardly any steering for that (it used to speed up after every piece), never slower,
  // and never near running dry.
  var pieces = LiveCatchUp(targetBuffer: 1, now: t0)
  var p = t0.addingTimeInterval(45)
  var inPieces = 0.8
  var changes = 0
  var lastRate: Float = 1
  var slowed = false
  var lowestPiece = inPieces
  for step in 0..<240 {
    let rate = pieces.update(buffer: inPieces, latency: inPieces + 0.8, playing: true, now: p)
    if rate != lastRate {
      changes += 1
      lastRate = rate
    }
    if rate < 1 { slowed = true }
    // A second of video every other reading; half a second played each time.
    inPieces += (step % 2 == 0 ? 1.0 : 0) - Double(rate) * 0.5
    lowestPiece = min(lowestPiece, inPieces)
    p += 0.5
  }
  check(changes <= 4 && !slowed && lowestPiece > 0.3, "steady while video arrives in pieces: \(changes) changes")

  // More than needed, lasting: caught up, gently.
  var surplus = LiveCatchUp(targetBuffer: 1, now: t0)
  var s = t0.addingTimeInterval(45)
  var surplusRates: [Float] = []
  for _ in 0..<10 {
    surplusRates.append(surplus.update(buffer: 2.4, latency: 3.3, playing: true, now: s))
    s += 0.5
  }
  check((surplusRates.last ?? 1) > 1 && (surplusRates.max() ?? 9) <= LiveCatchUp.rates.medium, "\(surplusRates)")

  // A hiccup: 1.5 s of no video arriving (the buffer drains at normal speed). The margin grows to
  // cover it as it happens; then playback slows a touch to build the margin back, and stops there.
  var hiccup = LiveCatchUp(now: t0)
  var h = t0.addingTimeInterval(45)
  var held = 2.0
  hiccup.update(buffer: held, latency: 0.8, playing: true, now: h)
  for _ in 0..<3 {
    h += 0.5
    held -= 0.5
    hiccup.update(buffer: held, latency: 0.8, playing: true, now: h)
  }
  check(hiccup.targetBuffer >= 1.5 + LiveCatchUp.air - 0.01, "margin covers the hiccup: \(hiccup.targetBuffer)")
  h += 0.5
  held = 0.3
  check(hiccup.update(buffer: held, latency: 2, playing: true, now: h) == LiveCatchUp.rates.slow, "builds it back")
  var building: [Float] = []
  var atNormal: (held: Double, target: Double, needed: Double)?
  for _ in 0..<600 {
    h += 0.5
    let rate = hiccup.update(buffer: held, latency: held + 1, playing: true, now: h)
    building.append(rate)
    if rate == 1, atNormal == nil { atNormal = (held, hiccup.targetBuffer, hiccup.neededBuffer(now: h)) }
    held += (1 - Double(rate)) * 0.5
  }
  let normalFrom = building.firstIndex(of: 1) ?? building.count
  check(normalFrom < building.count && building[..<normalFrom].allSatisfy { $0 < 1 } && building[normalFrom...].allSatisfy { $0 >= 1 },
    "slower until the margin's back, then normal")
  check((atNormal?.held ?? 0) >= (atNormal?.target ?? 9) - 0.3, "back to the margin: \(String(describing: atNormal))")
  check((atNormal?.needed ?? 0) >= 1.5, "the hiccup is remembered")
  // Well behind live already: never slower.
  var behind = LiveCatchUp(now: t0)
  check(behind.update(buffer: 0.2, latency: 6, playing: true, now: t0.addingTimeInterval(45)) == 1)

  // A stall: more in hand from now on, then a pause before steering again.
  var stall = LiveCatchUp(now: t0)
  let before = stall.targetBuffer
  stall.stalled(now: t0.addingTimeInterval(5))
  check(stall.targetBuffer > before + 0.3, "stall grows the margin")
  check(stall.update(buffer: 6, latency: 7, playing: true, now: t0.addingTimeInterval(7)) == 1, "held after a stall")
  check(stall.update(buffer: 6, latency: 7, playing: true, now: t0.addingTimeInterval(9)) == LiveCatchUp.rates.fast, "far over: catches up")
  // Capped: gentle at most, or not at all.
  check(stall.update(buffer: 6, latency: 7, playing: true, maxRate: LiveCatchUp.rates.gentle, now: t0.addingTimeInterval(9.5)) == LiveCatchUp.rates.gentle)
  check(stall.update(buffer: 6, latency: 7, playing: true, maxRate: 1, now: t0.addingTimeInterval(10)) == 1)

  // A given starting margin (what the channel needed last time), within bounds; none: the least.
  check(LiveCatchUp(targetBuffer: 1.5).targetBuffer == 1.5)
  check(LiveCatchUp(targetBuffer: 9).targetBuffer == LiveCatchUp.maxBuffer)
  check(LiveCatchUp(targetBuffer: 0.1).targetBuffer == LiveCatchUp.minBuffer)
  check(LiveCatchUp().targetBuffer == LiveCatchUp.minBuffer)
  // On cellular: a little more kept from the start, and never less.
  var cellular = LiveCatchUp()
  cellular.setFloor(0.9)
  check(cellular.targetBuffer == 0.9 && cellular.neededBuffer() == 0.9)

  // No hiccups for long enough: the margin comes back down within a minute or so (spending what's
  // in hand by playing faster, read from the playhead), never under the minimum.
  var calm = LiveCatchUp(targetBuffer: 2, now: t0)
  var c = t0
  var inHand = 2.0
  var position = 0.0
  while calm.targetBuffer > LiveCatchUp.minBuffer + 0.001, c < t0.addingTimeInterval(600) {
    c += 0.5
    let rate = calm.update(buffer: inHand, latency: inHand + 1, playing: true, position: position, now: c)
    inHand -= Double(rate - 1) * 0.5
    position += Double(rate) * 0.5
  }
  check(c.timeIntervalSince(t0) < 120, "back down in \(c.timeIntervalSince(t0)) s")
}

func testConnectionFit() {
  let t0 = Date(timeIntervalSince1970: 2_000_000)
  var fit = ConnectionFit(count: 3)
  check(!fit.stalled(now: t0), "one stall isn't enough")
  check(fit.stalled(now: t0.addingTimeInterval(60)) && fit.step == 1, "two in a few minutes: one down")
  check(!fit.tick(now: t0.addingTimeInterval(120)), "waits before trying again")
  let tried = t0.addingTimeInterval(60 + ConnectionFit.firstWait + 1)
  check(fit.tick(now: tried) && fit.step == 0, "tries the best again")
  check(fit.stalled(now: tried.addingTimeInterval(20)) && fit.step == 1, "failing right away: straight back down")
  check(!fit.tick(now: tried.addingTimeInterval(20 + ConnectionFit.firstWait + 1)), "and waits longer this time")
  check(fit.tick(now: tried.addingTimeInterval(20 + 2 * ConnectionFit.firstWait + 1)) && fit.step == 0)
  // Far apart: no step.
  var spread = ConnectionFit(count: 3)
  spread.stalled(now: t0)
  check(!spread.stalled(now: t0.addingTimeInterval(ConnectionFit.window + 1)) && spread.step == 0)
  // Only one quality: nowhere to go.
  var single = ConnectionFit(count: 1)
  single.stalled(now: t0)
  check(!single.stalled(now: t0.addingTimeInterval(10)) && single.step == 0)
}

func testStreamArrival() {
  let t0 = Date(timeIntervalSince1970: 3_000_000)
  let arrival = StreamArrival(now: t0)
  arrival.saw(index: 0, end: 10, now: t0)
  arrival.saw(index: 0, end: 10, now: t0.addingTimeInterval(1))
  check(arrival.ages(now: t0.addingTimeInterval(2)).moved == 2, "the same playlist again isn't news")
  arrival.saw(index: 1, end: 11, now: t0.addingTimeInterval(3))
  check(arrival.ages(now: t0.addingTimeInterval(3)).moved == 3, "a rendition's first playlist isn't news")
  arrival.saw(index: 0, end: 11, now: t0.addingTimeInterval(4))
  arrival.asked(now: t0.addingTimeInterval(4))
  let ages = arrival.ages(now: t0.addingTimeInterval(5))
  check(ages.moved == 1 && ages.asked == 1)

  typealias V = StreamArrival.Verdict
  // A moment of buffering: wait.
  check(StreamArrival.verdict(buffering: 2, asked: 1, moved: 1) == V.wait)
  // The stream itself stopped arriving: wait for it (a restart can't help)...
  check(StreamArrival.verdict(buffering: 12, asked: 1, moved: 12) == V.waitingForStream)
  check(StreamArrival.verdict(buffering: 30, asked: 1, moved: 30) == V.waitingForStream)
  // ...unless it's been very long.
  check(StreamArrival.verdict(buffering: 50, asked: 1, moved: 50) == V.restart)
  // The stream's arriving but the player won't play it: restart.
  check(StreamArrival.verdict(buffering: 6, asked: 1, moved: 1) == V.wait)
  check(StreamArrival.verdict(buffering: 11, asked: 1, moved: 1) == V.restart)
  // The player stopped asking for more: stuck.
  check(StreamArrival.verdict(buffering: 9, asked: 8, moved: 8) == V.restart)
  check(StreamArrival.verdict(buffering: 5, asked: 7, moved: 7) == V.wait)
}

func testSteadyAutoQuality() {
  let t0 = Date(timeIntervalSince1970: 2_000_000)
  var auto = SteadyAutoQuality(count: 4)  // 1080p, 720p, 480p, 360p
  auto.switched(to: 2, now: t0)
  check(auto.cap == nil)
  // Up on a burst of bandwidth, straight back down: 720p is held off.
  auto.switched(to: 1, now: t0.addingTimeInterval(5))
  check(auto.switched(to: 2, now: t0.addingTimeInterval(12)))
  check(auto.cap == 2)
  // Not lifted before the hold is over; then one step at a time.
  check(!auto.tick(now: t0.addingTimeInterval(30)))
  check(auto.tick(now: t0.addingTimeInterval(43)))
  check(auto.cap == 1)
  check(auto.tick(now: t0.addingTimeInterval(74)))
  check(auto.cap == nil)
  // 720p stalls again: held off twice as long this time.
  auto.switched(to: 1, now: t0.addingTimeInterval(80))
  check(auto.stalled(now: t0.addingTimeInterval(90)))
  check(auto.cap == 2)
  check(!auto.tick(now: t0.addingTimeInterval(140)))
  check(auto.tick(now: t0.addingTimeInterval(151)))
  // The lowest quality can't be held off.
  var low = SteadyAutoQuality(count: 2)
  low.switched(to: 1, now: t0)
  check(!low.stalled(now: t0.addingTimeInterval(1)))
  check(low.cap == nil)
  // Smooth for a minute: worth starting at next time (reported once).
  var steady = SteadyAutoQuality(count: 3)
  steady.switched(to: 1, now: t0)
  check(steady.steadyRank(now: t0.addingTimeInterval(30)) == nil)
  check(steady.steadyRank(now: t0.addingTimeInterval(61)) == 1)
  check(steady.steadyRank(now: t0.addingTimeInterval(90)) == nil)
}

func testMasterClock() {
  let master = "#EXTM3U\n#EXT-X-TWITCH-INFO:NODE=\"a\",SERVER-TIME=\"1761772800.69\",USER-IP=\"1.2.3.4\",STREAM-TIME=\"3122.69299889\"\nv/0.m3u8\n"
  let moved = LowLatencyPlaylist.advancingClock(master, by: 90.5)
  check(moved.contains("SERVER-TIME=\"1761772891.19\""), moved)
  check(moved.contains("STREAM-TIME=\"3213.19299889\""), moved)
  check(moved.contains("USER-IP=\"1.2.3.4\"") && moved.hasSuffix("v/0.m3u8\n"))
  check(LowLatencyPlaylist.advancingClock("#EXTM3U\nv/0.m3u8\n", by: 5) == "#EXTM3U\nv/0.m3u8\n")
}

func testRecordingPlaylist() {
  let entries: [(file: String, duration: Double, discontinuity: Bool, map: String?)] = [
    ("000001.ts", 2.0, false, nil), ("000002.ts", 2.0, false, nil), ("000003.ts", 1.5, true, nil),
  ]
  let live = StreamRecorder.playlistText(entries: entries, ended: false)
  check(live.contains("#EXT-X-PLAYLIST-TYPE:EVENT") && !live.contains("ENDLIST"), live)
  check(live.contains("#EXTINF:2.000,\n000002.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:1.500,\n000003.ts"), live)
  check(live.contains("#EXT-X-TARGETDURATION:2"), live)
  let done = StreamRecorder.playlistText(entries: entries, ended: true)
  check(done.contains("#EXT-X-PLAYLIST-TYPE:VOD") && done.hasSuffix("#EXT-X-ENDLIST\n"), done)
  // Dated: the first stretch and the one after the jump carry when they were broadcast.
  let t0 = Date(timeIntervalSince1970: 1_761_800_000)
  let dated = StreamRecorder.playlistText(entries: entries, dates: [t0, t0 + 2, t0 + 30], ended: true)
  check(dated.components(separatedBy: "#EXT-X-PROGRAM-DATE-TIME:").count == 3, dated)
  check(dated.contains("#EXT-X-DISCONTINUITY\n#EXT-X-PROGRAM-DATE-TIME:" + HLSDate.format(t0 + 30)), dated)
  var info = RecordingInfo(
    id: "a", login: "a", channelName: "A", quality: "", startedAt: t0 + 5, duration: 0, bytes: 0, gaps: 0)
  check(info.streamOffset == nil)
  info.streamStartedAt = t0 - 3600
  info.firstSegmentAt = t0
  check(info.streamOffset == 3600)
  check(StreamProxy.isPlainName("000001.ts") && StreamProxy.isPlainName("ab-12_3"))
  check(!StreamProxy.isPlainName("..") && !StreamProxy.isPlainName("a/b") && !StreamProxy.isPlainName(".hidden"))
}

func testMutedParts() {
  let playlist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:10
    #EXTINF:10.000,
    0.ts
    #EXTINF:10.000,
    1-unmuted.ts
    #EXTINF:10.000,
    2-unmuted.ts
    #EXTINF:10.000,
    3.ts
    #EXTINF:5.500,
    4-muted.ts
    #EXT-X-ENDLIST
    """
  let parts = VODPlaylists.mutedParts(playlist)
  check(parts.count == 2, "\(parts)")
  check(parts.first.map { abs($0.lowerBound - 10) < 0.01 && abs($0.upperBound - 30) < 0.01 } == true, "joined: \(parts)")
  check(parts.last.map { abs($0.lowerBound - 40) < 0.01 && abs($0.upperBound - 45.5) < 0.01 } == true, "last: \(parts)")
  check(VODPlaylists.mutedParts("#EXTM3U\n#EXTINF:10,\n0.ts\n").isEmpty, "none")
}

func testWholeSegmentSteering() {
  // A channel off low latency: two seconds of video at a time, listed every two seconds (seen up to
  // 0.7 s late by the playlist poll). Started a segment plus the margin behind the newest frame
  // and steered by the low point of what's in hand over 3 s (as the player does), the margin stays
  // small and the speed barely moves. (Started just the margin behind, as before, it ran dry
  // before every next segment: each stall raised the margin, up to its 3.5 s limit.)
  var catchUp = LiveCatchUp(noise: 0.35)
  let t0 = Date(timeIntervalSince1970: 3_000_000)
  var position = 0.0
  var newest = 2.6  // started a segment plus the margin behind
  var nextListing = 2.0
  var history: [(Double, Double)] = []
  var changes = 0
  var lastRate: Float = 1
  var t = 0.0
  while t < 600 {
    if t >= nextListing {
      newest += 2
      nextListing += 2 + Double(Int(t * 7) % 7) / 10
    }
    let ahead = max(0, newest - position)
    history.append((t, ahead))
    history.removeAll { t - $0.0 > 3 }
    let trough = history.map(\.1).min() ?? ahead
    let rate = catchUp.update(buffer: trough, latency: trough + 0.8, playing: true, position: position, now: t0.addingTimeInterval(t))
    if rate != lastRate { changes += 1; lastRate = rate }
    position += Double(rate) * 0.1
    t += 0.1
  }
  check(catchUp.targetBuffer < 1.3, "whole segments: margin stays small (\(catchUp.targetBuffer))")
  check(changes <= 12, "whole segments: few speed changes (\(changes))")

  var old = LiveCatchUp(noise: 0.35)
  var oldPosition = 0.0
  var oldNewest = 0.6
  var oldListing = 2.0
  var u = 0.0
  while u < 300 {
    if u >= oldListing {
      oldNewest += 2
      oldListing += 2 + Double(Int(u * 7) % 7) / 10
    }
    let ahead = max(0, oldNewest - oldPosition)
    var rate = old.update(buffer: ahead, latency: ahead + 0.8, playing: true, position: oldPosition, now: t0.addingTimeInterval(u))
    if ahead < 0.03 {
      old.stalled(now: t0.addingTimeInterval(u))
      rate = 0
    }
    oldPosition += Double(rate) * 0.1
    u += 0.1
  }
  check(old.targetBuffer > 2, "started just the margin behind: the margin grows (\(old.targetBuffer))")
}

func testConnectionFitTooSlow() {
  let t0 = Date(timeIntervalSince1970: 4_000_000)
  var fit = ConnectionFit(count: 4)
  check(fit.tooSlow(now: t0) && fit.step == 1, "too slow: one down at once")
  check(!fit.tooSlow(now: t0.addingTimeInterval(5)), "not again straight away")
  check(fit.tooSlow(now: t0.addingTimeInterval(13)) && fit.step == 2, "again after a while")
  var cellular = ConnectionFit(count: 5)
  cellular.start(at: 2, tryAfter: 90, now: t0)
  check(cellular.step == 2 && !cellular.tick(now: t0.addingTimeInterval(60)), "cellular: lower first")
  check(cellular.tick(now: t0.addingTimeInterval(91)) && cellular.step == 1, "then tries better")
}

func testQualityChangeNotLearned() {
  let t0 = Date(timeIntervalSince1970: 5_000_000)
  var catchUp = LiveCatchUp(noise: 0.35, now: t0)
  // Steady at the margin for a while.
  var t = 0.0
  while t < 20 {
    _ = catchUp.update(buffer: 0.7, latency: 1.5, playing: true, position: t, now: t0.addingTimeInterval(t))
    t += 0.25
  }
  let before = catchUp.targetBuffer
  // A switch of quality, and the gap it leaves (a stall right after): nothing learned.
  catchUp.qualityChanged(lowered: false, now: t0.addingTimeInterval(t))
  catchUp.stalled(now: t0.addingTimeInterval(t + 4))
  check(catchUp.targetBuffer == before, "a switch's stall isn't learned (\(catchUp.targetBuffer) vs \(before))")
  // A real stall later raises it; stepping down afterwards forgets what was learned at that quality.
  catchUp.stalled(now: t0.addingTimeInterval(t + 30))
  check(catchUp.targetBuffer > before + 0.3, "a stall later is learned (\(catchUp.targetBuffer))")
  catchUp.qualityChanged(lowered: true, now: t0.addingTimeInterval(t + 40))
  check(catchUp.targetBuffer < before + 0.05, "stepped down: back to what was needed (\(catchUp.targetBuffer))")
  // An ad break: stalls during it aren't learned, even across a quality change; afterwards the
  // margin is what was needed before.
  catchUp.pauseLearning()
  catchUp.stalled(now: t0.addingTimeInterval(t + 60))
  catchUp.qualityChanged(lowered: false, now: t0.addingTimeInterval(t + 65))
  catchUp.stalled(now: t0.addingTimeInterval(t + 90))
  check(catchUp.targetBuffer < before + 0.05, "ad break: nothing learned (\(catchUp.targetBuffer))")
  catchUp.resumeLearning(now: t0.addingTimeInterval(t + 120))
  check(catchUp.targetBuffer < before + 0.05, "after the ad: margin as before (\(catchUp.targetBuffer))")
}

func testRecordingJoin() {
  let first = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PROGRAM-DATE-TIME:2026-11-04T01:00:00.000Z\n#EXT-X-MAP:URI=\"init0.mp4\"\n#EXTINF:2.000,\nseg0.m4s\n#EXTINF:2.000,\nseg1.m4s\n#EXT-X-ENDLIST\n"
  let second = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:3\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-START:TIME-OFFSET=0\n#EXTINF:2.500,\nseg0.ts\n"
  let joined = RecordingJoin.playlist([(id: "a", text: first), (id: "b", text: second)])
  let lines = joined.split(separator: "\n").map(String.init)
  check(lines.filter { $0 == "#EXTM3U" }.count == 1, "one header")
  check(lines.contains("#EXT-X-TARGETDURATION:3"), "longest target")
  check(lines.contains("#EXT-X-MAP:URI=\"/rec/a/init0.mp4\""), "map rewritten: \(joined)")
  check(lines.contains("/rec/a/seg0.m4s") && lines.contains("/rec/b/seg0.ts"), "segments rewritten")
  check(lines.filter { $0 == "#EXT-X-DISCONTINUITY" }.count == 1, "one join")
  check(!lines.contains("#EXT-X-ENDLIST") && lines.contains("#EXT-X-PLAYLIST-TYPE:EVENT"), "still recording: no end")
  check(lines.contains("#EXT-X-PROGRAM-DATE-TIME:2026-11-04T01:00:00.000Z"), "dates kept")
  let done = RecordingJoin.playlist([(id: "a", text: first), (id: "b", text: second + "#EXT-X-ENDLIST\n")])
  check(done.hasSuffix("#EXT-X-ENDLIST\n") && done.contains("PLAYLIST-TYPE:VOD"), "ended")
  let t0 = Date(timeIntervalSince1970: 1_000_000)
  let gaps = RecordingJoin.gaps([(t0, 100), (t0.addingTimeInterval(160), 50), (t0.addingTimeInterval(210), 10)])
  check(gaps.count == 2 && gaps[0].at == 100 && gaps[0].missing == 60 && gaps[1].at == 150 && gaps[1].missing == 0, "gaps: \(gaps)")
}

func testMultiviewLayout() {
  // Two streams: side by side when wide, stacked when tall.
  let wide = MultiviewLayout.grid(count: 2, in: CGSize(width: 800, height: 360))
  check(wide.count == 2 && abs(wide[0].minY - wide[1].minY) < 0.5 && wide[0].maxX <= wide[1].minX, "wide: \(wide)")
  let tall = MultiviewLayout.grid(count: 2, in: CGSize(width: 390, height: 500))
  check(tall.count == 2 && abs(tall[0].minX - tall[1].minX) < 0.5 && tall[0].maxY <= tall[1].minY, "tall: \(tall)")
  // Four in a 2×2 grid, all 16:9, inside the area, none overlapping.
  let area = CGRect(x: 0, y: 0, width: 900, height: 600)
  let four = MultiviewLayout.grid(count: 4, in: area.size)
  check(Set(four.map { Int($0.minY) }).count == 2 && Set(four.map { Int($0.minX) }).count == 2, "2x2: \(four)")
  for (index, rect) in four.enumerated() {
    check(area.contains(rect) && abs(rect.width / rect.height - 16.0 / 9) < 0.03, "inside, 16:9: \(rect)")
    for other in four[(index + 1)...] { check(!rect.intersects(other.insetBy(dx: 0.5, dy: 0.5)), "overlap \(rect) \(other)") }
  }
  // Three: the last row's one picture centred.
  let three = MultiviewLayout.grid(count: 3, in: CGSize(width: 900, height: 600))
  check(three.count == 3 && abs(three[2].midX - 450) < 1.5, "centred: \(three)")
  // Focus: the main one is the biggest, the others the same smaller size.
  let focus = MultiviewLayout.focus(count: 4, main: 2, in: CGSize(width: 900, height: 420))
  check(focus.count == 4 && focus[2].width > focus[0].width * 2 && focus[0].size == focus[1].size, "focus: \(focus)")
  for (index, rect) in focus.enumerated() {
    check(area.contains(rect), "focus inside: \(rect)")
    for other in focus[(index + 1)...] { check(!rect.intersects(other.insetBy(dx: 0.5, dy: 0.5)), "focus overlap") }
  }
  let portraitFocus = MultiviewLayout.focus(count: 3, main: 0, in: CGSize(width: 390, height: 500))
  check(portraitFocus[0].maxY <= portraitFocus[1].minY && portraitFocus[1].minY == portraitFocus[2].minY, "under: \(portraitFocus)")
  // Up to nine: a 3×3 grid; focus with eight others in two lanes, nothing overlapping or outside.
  let nine = MultiviewLayout.grid(count: 9, in: area.size)
  check(Set(nine.map { Int($0.minY) }).count == 3 && Set(nine.map { Int($0.minX) }).count == 3, "3x3: \(nine)")
  for size in [CGSize(width: 900, height: 420), CGSize(width: 390, height: 520)] {
    let bounds = CGRect(origin: .zero, size: size)
    let many = MultiviewLayout.focus(count: 9, main: 4, in: size)
    check(many.count == 9 && many[4].width > many[0].width * 2, "focus nine: \(many)")
    for (index, rect) in many.enumerated() {
      check(bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) && rect.width > 20, "focus nine inside: \(rect) in \(size)")
      for other in many[(index + 1)...] { check(!rect.intersects(other.insetBy(dx: 0.5, dy: 0.5)), "focus nine overlap \(rect) \(other)") }
    }
  }
  // Sharpness: a small picture doesn't fetch 1080p.
  check(MultiviewLayout.heightCap(points: 110, scale: 3, heard: false) == 360, "small cap")
  check(MultiviewLayout.heightCap(points: 200, scale: 3, heard: true) == 720, "heard cap")
  check(MultiviewLayout.heightCap(points: 400, scale: 3, heard: true) == nil, "big: any")
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
    // The stream came from the ad-free server's own session. Besides the regular token this test
    // asked for itself (above), the session may ask for one more alongside, to learn which of
    // Twitch's playlist servers is near the viewer (see NearbyPlaylists): that runs in parallel
    // and isn't what plays.
    let regular = twitch.tokenRequests.filter { $0 != "proxy" }.count
    check(twitch.tokenRequests.filter { $0 == "proxy" }.count == 1 && regular <= 2, "no regular token needed: \(twitch.tokenRequests)")
  }
  // Ad-free servers for ads only: the stream starts straight from Twitch (no server asked), and
  // when an ad is stitched in, the server's copy is the one switched to.
  runAsync {
    let twitch = FakeTwitch()
    twitch.mainAds = 21..<30
    twitch.backupAds = ["site": 0..<100, "popout": 0..<100, "mobile_web": 0..<100, "embed": 0..<100, "autoplay": 0..<100]
    let http = ProxyFake(twitch)
    let log = ActivityLog()
    var config = LowLatencyConfig()
    config.adFreeProxies = ["proxy.test"]
    config.adFreeServersForAdsOnly = true
    let session = LowLatencySession(login: "streamer", config: config, http: http, tokens: twitch, log: log)
    _ = try! await session.start()
    let route = await session.route
    check(route == .twitch && !http.requested.contains("proxy.test"), "started straight from Twitch: \(route) \(http.requested)")
    var sawCopy = false
    var adSegments = 0
    for _ in 0..<8 {
      let media = await session.mediaPlaylist(0)
      adSegments += media.body.components(separatedBy: "/ad-").count - 1
      let main = twitch.mainToken ?? "?"
      if media.body.components(separatedBy: "\n").contains(where: { $0.hasPrefix("https://edge.test/") && !$0.hasPrefix("https://edge.test/\(main)-") }) {
        sawCopy = true
      }
      twitch.advance()
    }
    check(sawCopy, "the ad-free server's copy during the ad: \(log.messages)")
    check(log.messages.contains { $0.contains("Switched to ad-free copy (server:proxy.test") }, "\(log.messages)")
  }
  // A server that doesn't answer at all doesn't hold the stream up for its whole timeout: the
  // next one is asked under a second later, and the first playlist back wins.
  runAsync {
    let twitch = FakeTwitch()
    let http = ProxyFake(twitch)
    var config = LowLatencyConfig()
    config.adFreeProxies = ["hang.test", "proxy.test"]
    let session = LowLatencySession(login: "streamer", config: config, http: http, tokens: twitch, log: ActivityLog())
    let started = Date()
    _ = try! await session.start()
    let took = Date().timeIntervalSince(started)
    let route = await session.route
    check(route == .adFreeServer("proxy.test") && took < 2.5, "next server raced in: \(route) after \(took) s")
  }
  // Through an ad-free server, an announced break doesn't cost low latency (nothing can be
  // stitched in, so the newest segment isn't held back).
  runAsync {
    let twitch = FakeTwitch()
    twitch.mainMarkers = 20..<40
    let http = ProxyFake(twitch)
    var config = LowLatencyConfig()
    config.adFreeProxies = ["proxy.test"]
    let session = LowLatencySession(login: "streamer", config: config, http: http, tokens: twitch, log: ActivityLog())
    _ = try! await session.start()
    twitch.advance(4)
    let media = await session.mediaPlaylist(0)
    check(media.body.contains("TWITCH-PREFETCH"), "prefetch kept through an ad-free server during an announced break")
  }
}

// MARK: - Sub-only VODs (TwitchNoSub) and raids

final class CDNFake: HTTPClient, @unchecked Sendable {
  /// Path -> body (404 when missing).
  var files: [String: Data] = [:]
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let path = request.url!.path
    let body = files[path]
    return (body ?? Data(), HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: [:])!)
  }
}

func testRestrictedVOD() {
  let json = JSONValue([
    "video": [
      "broadcastType": "ARCHIVE", "createdAt": "2026-10-30T18:00:00Z",
      "seekPreviewsURL": "https://d2nvs31859zcd8.cloudfront.net/abc123_streamer_4242_1730000000/storyboards/2290000000-info.json",
      "owner": ["login": "streamer"],
    ] as [String: Any]
  ])
  guard let info = RestrictedVOD.parseInfo(json) else {
    check(false, "restricted info parse")
    return
  }
  check(info.broadcastType == "archive" && info.ownerLogin == "streamer", "restricted info \(info)")
  let loc = RestrictedVOD.location(info.seekPreviewsURL)
  check(loc?.host == "d2nvs31859zcd8.cloudfront.net" && loc?.specialID == "abc123_streamer_4242_1730000000", "cdn location \(String(describing: loc))")
  check(
    RestrictedVOD.playlistURL(videoID: "2290000000", info: info, rendition: "chunked")?.absoluteString
      == "https://d2nvs31859zcd8.cloudfront.net/abc123_streamer_4242_1730000000/chunked/index-dvr.m3u8", "archive url")
  var highlight = info
  highlight.broadcastType = "highlight"
  check(
    RestrictedVOD.playlistURL(videoID: "9", info: highlight, rendition: "720p60")?.path
      == "/abc123_streamer_4242_1730000000/720p60/highlight-9.m3u8", "highlight url")
  var oldUpload = info
  oldUpload.broadcastType = "upload"
  oldUpload.createdAt = HLSDate.parse("2021-05-01T00:00:00Z")
  check(
    RestrictedVOD.playlistURL(videoID: "9", info: oldUpload, rendition: "480p30")?.path
      == "/streamer/9/abc123_streamer_4242_1730000000/480p30/index-dvr.m3u8", "old upload url")
  var newUpload = oldUpload
  newUpload.createdAt = HLSDate.parse("2025-05-01T00:00:00Z")
  check(
    RestrictedVOD.playlistURL(videoID: "9", info: newUpload, rendition: "480p30")?.path
      == "/abc123_streamer_4242_1730000000/480p30/index-dvr.m3u8", "new upload url")
  check(RestrictedVOD.parseInfo(JSONValue(["video": ["seekPreviewsURL": NSNull()]])) == nil, "no storyboard -> nil")

  // Probing: source as TS, 720p60 as fMP4 HEVC, 360p30 and audio; the rest missing.
  let cdn = CDNFake()
  let base = "/abc123_streamer_4242_1730000000"
  let ts = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.000,\n0.ts\n#EXTINF:10.000,\n1-unmuted.ts\n#EXT-X-ENDLIST\n"
  let fmp4 = "#EXTM3U\n#EXT-X-MAP:URI=\"init-0.mp4\"\n#EXTINF:10.000,\n0.mp4\n#EXT-X-ENDLIST\n"
  cdn.files[base + "/chunked/index-dvr.m3u8"] = Data(ts.utf8)
  cdn.files[base + "/720p60/index-dvr.m3u8"] = Data(fmp4.utf8)
  cdn.files[base + "/720p60/init-0.mp4"] = Data("....ftypiso5....moov....trak....hvc1....".utf8)
  cdn.files[base + "/360p30/index-dvr.m3u8"] = Data(ts.utf8)
  cdn.files[base + "/audio_only/index-dvr.m3u8"] = Data(ts.utf8)
  runAsync {
    let variants = await RestrictedVOD.variants(videoID: "2290000000", info: info, http: cdn)
    check(variants.map(\.label) == ["1080p60", "720p60", "360p", "Audio only"], "cdn variants \(variants.map(\.label))")
    check(variants.first?.name == "1080p (source)", "source name \(variants.first?.name ?? "")")
    check(variants[1].codecs.hasPrefix("hev1"), "hevc from init segment")
    check(variants.last?.isAudioOnly == true, "audio last")
    let master = HLSMaster(variants: variants)
    check(master.videoVariants.count == 3 && master.audioVariant != nil, "usable as a master")
    let none = await RestrictedVOD.variants(videoID: "1", info: info, http: CDNFake())
    check(none.isEmpty, "nothing on the cdn")
  }
  check(RestrictedVOD.codecs(initSegment: Data("avc1".utf8)).hasPrefix("avc1"), "avc init")
}

func testRaids() {
  let sub = Hermes.subscribe(topic: Hermes.raidTopic(channelID: "4242"), id: "a", subscriptionID: "b")
  check(sub.contains("\"topic\":\"raid.4242\"") && sub.contains("\"type\":\"subscribe\"") && sub.contains("\"type\":\"pubsub\""), "subscribe \(sub)")
  check(Hermes.parse(#"{"type":"welcome","welcome":{"keepaliveSec":12,"sessionId":"x"}}"#) == .welcome(keepalive: 12), "welcome")
  check(Hermes.parse(#"{"type":"keepalive","id":"1"}"#) == .keepalive, "keepalive")
  check(Hermes.parse(#"{"type":"subscribeResponse","subscribeResponse":{"result":"ok"}}"#) == .subscribed(ok: true), "subscribed")
  check(Hermes.parse(#"{"type":"reconnect","reconnect":{"url":"wss://hermes.twitch.tv/v1?x=1"}}"#) == .reconnect(URL(string: "wss://hermes.twitch.tv/v1?x=1")), "reconnect")
  let inner = #"{"type":"raid_update_v2","raid":{"id":"r1","creator_id":"4242","source_id":"4242","target_id":"77","target_login":"friend","target_display_name":"Friend","target_profile_image":"https://img/{width}.png","transition_jitter_seconds":3,"force_raid_now_seconds":85,"viewer_count":1234}}"#
  let escaped = inner.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  let note = #"{"type":"notification","notification":{"subscription":{"id":"b"},"type":"pubsub","pubsub":""# + escaped + #""}}"#
  guard case .raid(let event) = Hermes.parse(note) else {
    check(false, "raid notification not parsed")
    return
  }
  check(event.kind == .update && event.targetLogin == "friend" && event.targetDisplayName == "Friend", "raid event \(event)")
  check(event.viewerCount == 1234 && event.forceRaidNowSeconds == 85 && event.sourceID == "4242" && event.raidID == "r1", "raid numbers")
  check(event.target.id == "77" && event.target.login == "friend", "raid target channel")
  let go = Hermes.parse(#"{"type":"notification","notification":{"type":"pubsub","pubsub":{"type":"raid_go_v2","raid":{"id":"r1","target_login":"friend"}}}}"#)
  if case .raid(let e) = go { check(e.kind == .go && e.targetDisplayName == "friend", "go fallback name") } else { check(false, "raid go as object") }
  check(Hermes.parse(#"{"type":"notification","notification":{"pubsub":"{\"type\":\"something_else\"}"}}"#) == .other, "other pubsub")
  check(Hermes.parse("not json") == .other, "garbage")
}

/// A shaky broadcaster over Twitch's low-latency delivery (hiccups of 0.4–1.5 s about every 25 s,
/// video in half-second pieces), played for half an hour with the speed steering: few stalls, few
/// speed changes, close to live. (The tuning's guard: it used to stall about 1.6 times and change
/// speed about 11 times every ten minutes here.)
func testCatchUpSimulation() {
  struct Rand {
    var s: UInt64
    mutating func next() -> Double {
      s = s &* 6364136223846793005 &+ 1442695040888963407
      return Double(s >> 11) / Double(1 << 53)
    }
  }
  var stalls = 0, changes = 0, readings = 0
  var latencySum = 0.0
  let seeds: [UInt64] = [1, 2, 3, 4]
  let duration = 1800.0
  for seed in seeds {
    var rng = Rand(s: seed)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var catchUp = LiveCatchUp(now: t0)
    let dt = 0.05
    var extra = 0.0, growing = 0.0, wobble = 0.0, arrived = 0.0, visible = 0.0
    var nextHiccup = -log(1 - rng.next()) * 25
    var t = 0.0, tick = 0.0, position = -1.6
    var stalled = true
    var rate: Float = 1, lastRate: Float = 1
    while t < duration {
      if t >= nextHiccup {
        growing = 0.4 + rng.next() * 1.1
        nextHiccup = t - log(1 - rng.next()) * 25
      }
      if growing > 0 {
        let step = min(dt, growing)
        extra += step
        growing -= step
      } else if extra > 0 {
        extra = max(0, extra - dt * 3)
      }
      if Int(t / 0.5) != Int((t - dt) / 0.5) { wobble = (rng.next() - 0.5) * 0.4 }
      arrived = max(arrived, t - 0.35 - extra - max(0, wobble))
      visible = max(visible, (arrived / 0.5).rounded(.down) * 0.5)
      let buffer = visible - position
      if stalled {
        if buffer >= 0.5 { stalled = false }
      } else if buffer <= 0 {
        stalled = true
        if t > 3 { stalls += 1 }
        catchUp.stalled(now: t0.addingTimeInterval(t))
        rate = 1
      }
      if !stalled { position += Double(rate) * dt }
      if t >= tick {
        tick += 0.5
        let latency = t - position + 0.8
        rate = catchUp.update(
          buffer: max(0, visible - position), latency: latency, playing: !stalled, position: position, now: t0.addingTimeInterval(t))
        if t > 5 {
          latencySum += latency
          readings += 1
          // Each spell of faster or slower playback, not each step within one.
          if rate != 1, (rate > 1) != (lastRate > 1) || lastRate == 1 { changes += 1 }
        }
        lastRate = rate
      }
      t += dt
    }
  }
  let per10 = 600 / (duration * Double(seeds.count))
  let stallRate = Double(stalls) * per10, changeRate = Double(changes) * per10, latency = latencySum / Double(readings)
  check(stallRate < 1.0, "shaky stream: \(stallRate) stalls per 10 min")
  check(changeRate < 6, "shaky stream: \(changeRate) speed changes per 10 min")
  check(latency < 3.6, "shaky stream: \(latency) s from live on average")
  print("SHAKY stalls/10min", stallRate, "spells/10min", changeRate, "latency", latency)

  // A dropout on the connection (3 s with nothing arriving, ridden out on a big buffer): learned as
  // no more than an outage's worth, not three seconds in hand for the next ten minutes.
  let o0 = Date(timeIntervalSince1970: 2_000_000)
  var outage = LiveCatchUp(now: o0)
  var o = o0.addingTimeInterval(45)
  var held = 3.5
  var rateNow = outage.update(buffer: held, latency: 4.5, playing: true, now: o)
  for _ in 0..<6 {
    o += 0.5
    held -= Double(rateNow) * 0.5
    rateNow = outage.update(buffer: held, latency: 4.5, playing: true, now: o)
  }
  check(LiveCatchUp.learnable(4) == LiveCatchUp.outageLearned && LiveCatchUp.learnable(1) == 1, "learnable")
  check(outage.targetBuffer <= LiveCatchUp.outageLearned + LiveCatchUp.air + 0.01, "outage learned in moderation: \(outage.targetBuffer)")
  // A stall never lowers the margin, even after a gap that pushed it past the outage length.
  var deep = LiveCatchUp(now: o0)
  var d = o0.addingTimeInterval(45)
  var deepHeld = 3.4
  var deepRate = deep.update(buffer: deepHeld, latency: 4.4, playing: true, now: d)
  for _ in 0..<4 {
    d += 0.5
    deepHeld -= Double(deepRate) * 0.5
    deepRate = deep.update(buffer: deepHeld, latency: 4.4, playing: true, now: d)
  }
  let beforeStall = deep.targetBuffer
  deep.stalled(now: d)
  check(deep.targetBuffer >= beforeStall, "a stall doesn't lower the margin: \(beforeStall) -> \(deep.targetBuffer)")
  // Stalls on hiccups a little past the outage length still teach enough to cover them.
  var repeated = LiveCatchUp(targetBuffer: 2.0, now: o0)
  for i in 0..<3 { repeated.stalled(now: o0.addingTimeInterval(60 + Double(i) * 30)) }
  check(repeated.targetBuffer > 2.6, "repeated stalls keep growing it: \(repeated.targetBuffer)")
  // A long stall (the connection dropping out for seconds) is learned as an outage once it's over.
  var dropout = LiveCatchUp(targetBuffer: 2.2, now: o0)
  dropout.stalled(now: o0.addingTimeInterval(60))
  let grown = dropout.targetBuffer
  dropout.update(buffer: 0.6, latency: 6, playing: true, now: o0.addingTimeInterval(65))
  check(grown > 2.6 && dropout.targetBuffer <= max(2.2, LiveCatchUp.outageLearned + LiveCatchUp.air) + 0.01,
    "dropout cut back: \(grown) -> \(dropout.targetBuffer)")
  // A short stall keeps what it taught.
  var short = LiveCatchUp(targetBuffer: 2.2, now: o0)
  short.stalled(now: o0.addingTimeInterval(60))
  let taught = short.targetBuffer
  short.update(buffer: 0.6, latency: 3, playing: true, now: o0.addingTimeInterval(61.2))
  check(short.targetBuffer == taught, "short stall kept: \(taught) -> \(short.targetBuffer)")
  // Bursty delivery: a player that sees video arrive in bursts ignores dips up to its noise level
  // (they raised the Kestrel player's margin to over a second with no stalls at all).
  func dip(_ noise: Double) -> Double {
    var c = LiveCatchUp(noise: noise, now: o0)
    var t = o0.addingTimeInterval(45)
    var held = 0.9
    c.update(buffer: held, latency: 1.4, playing: true, now: t)
    for step in 0..<40 {
      t += 0.25
      // 0.3 s without video every two seconds, then a burst that brings it back.
      let phase = step % 8
      held += phase < 2 ? -0.15 : (phase == 2 ? 0.3 : 0)
      c.update(buffer: held, latency: held + 0.5, playing: true, now: t)
    }
    return c.targetBuffer
  }
  check(dip(0.35) <= LiveCatchUp.minBuffer + 0.01, "bursts below the noise level don't raise the margin: \(dip(0.35))")
  check(dip(0.2) > LiveCatchUp.minBuffer + 0.05, "with the default level they do (the low-latency player's reading is smooth): \(dip(0.2))")
  // A hiccup fades from memory rather than dropping out of it all at once.
  var fading = LiveCatchUp(now: o0)
  fading.stalled(now: o0.addingTimeInterval(50))
  let fresh = fading.neededBuffer(now: o0.addingTimeInterval(60))
  let mid = fading.neededBuffer(now: o0.addingTimeInterval(50 + 375))
  let gone = fading.neededBuffer(now: o0.addingTimeInterval(50 + 601))
  check(fresh > mid && mid > gone && gone == LiveCatchUp.minBuffer, "fades: \(fresh) \(mid) \(gone)")
}

func testDeviceLogin() {
  let started = Date(timeIntervalSince1970: 1000)
  let code = TwitchDeviceLogin.parseCode(
    Data(#"{"device_code":"dev123","expires_in":1800,"interval":5,"user_code":"ABCDEFGH","verification_uri":"https://www.twitch.tv/activate?device-code=ABCDEFGH"}"#.utf8),
    status: 200, scopes: "chat:read", now: started)
  check(code?.userCode == "ABCDEFGH" && code?.deviceCode == "dev123" && code?.interval == 5, "device code \(String(describing: code))")
  check(code?.expiresAt == started.addingTimeInterval(1800), "expiry")
  check(TwitchDeviceLogin.parseCode(Data(#"{"message":"invalid scope"}"#.utf8), status: 400, scopes: "x") == nil, "refused code")
  check(TwitchDeviceLogin.parsePoll(Data(#"{"status":400,"message":"authorization_pending"}"#.utf8), status: 400) == .pending, "pending")
  check(TwitchDeviceLogin.parsePoll(Data(#"{"message":"slow_down"}"#.utf8), status: 400) == .slowDown, "slow down")
  check(TwitchDeviceLogin.parsePoll(Data(#"{"message":"invalid device code"}"#.utf8), status: 400) == .expired, "expired")
  check(TwitchDeviceLogin.parsePoll(Data(#"{"message":"boom"}"#.utf8), status: 503) == .pending, "server error: try again")
  check(TwitchDeviceLogin.parsePoll(Data(#"{"message":"access_denied"}"#.utf8), status: 400) == .refused("access_denied"), "denied")
  let done = TwitchDeviceLogin.parsePoll(Data(#"{"access_token":"tok","refresh_token":"ref","expires_in":14000}"#.utf8), status: 200)
  check(done == .done(.init(accessToken: "tok", refreshToken: "ref", expiresIn: 14000)), "granted \(done)")
  let request = TwitchDeviceLogin.form("https://id.twitch.tv/oauth2/device", [("client_id", "abc"), ("scopes", "chat:read user_read")])
  let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
  check(body == "client_id=abc&scopes=chat%3Aread%20user_read" && request.httpMethod == "POST", "form \(body)")
  // A session saved before the client ID existed still loads (no client ID: the website's).
  let old = #"{"token":"t","login":"l","userID":"1","deviceID":"d"}"#
  let session = try? JSONDecoder().decode(TwitchAuth.Session.self, from: Data(old.utf8))
  check(session?.clientID == nil && session?.refreshToken == nil && session?.login == "l", "old session decodes")
}

func testTSDemux() {
  let dir = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
  guard let segment = try? Data(contentsOf: dir.appendingPathComponent("twitch_160p_segment.ts")) else {
    check(false, "fixture missing")
    return
  }
  // All at once.
  var whole = TSDemuxer()
  let all = whole.feed(segment) + whole.flush()
  let video = all.compactMap { if case .video(let f) = $0 { return f } else { return nil } }
  let audio = all.compactMap { if case .audio(let f) = $0 { return f } else { return nil } }
  check(video.count == 60, "video frames \(video.count)")
  check(video.first?.isKeyframe == true && video.first?.codec == .h264, "starts on a keyframe")
  let steps = Set(zip(video, video.dropFirst()).map { $1.pts - $0.pts })
  check(steps.allSatisfy { (2900...3100).contains($0) }, "30 fps steps \(steps)")
  check(audio.count >= 80 && audio.count <= 100, "audio frames \(audio.count)")
  check(audio.first.map { [44100, 48000].contains($0.config.sampleRate) && $0.config.objectType == 2 } ?? false, "AAC LC \(String(describing: audio.first?.config))")
  check(audio.first?.config.audioSpecificConfig.count == 2, "audio specific config")
  let audioSteps = Set(zip(audio, audio.dropFirst()).map { $1.pts - $0.pts })
  check(audioSteps.allSatisfy { (1800...2200).contains($0) }, "audio steps \(audioSteps)")
  // In awkward pieces (as a segment arrives over the network): exactly the same frames.
  var pieces = TSDemuxer()
  var chunked: [DemuxedFrame] = []
  var offset = 0
  var size = 1
  while offset < segment.count {
    let end = min(segment.count, offset + size)
    chunked += pieces.feed(segment.subdata(in: offset..<end))
    offset = end
    size = (size * 7 + 13) % 3001 + 1
  }
  chunked += pieces.flush()
  check(chunked.count == all.count, "chunked count \(chunked.count) vs \(all.count)")
  check(Set(chunked.map(\.pts)) == Set(all.map(\.pts)), "chunked frames match")
  // Frames come out as soon as the next one starts (not only at the end).
  var early = TSDemuxer()
  let half = early.feed(segment.prefix(segment.count / 2))
  check(half.count > 40, "frames out while it's still arriving: \(half.count)")
  // The decoder's form: parameter sets out of the first frame, the rest length-prefixed.
  if let first = video.first {
    let units = AnnexB.units(first.data)
    let sets = H264.parameterSets(units)
    check(sets != nil && H264.type(sets!.sps) == 7 && H264.type(sets!.pps) == 8, "SPS/PPS found")
    let sample = H264.sample(units)
    let firstLength = sample.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    check(firstLength > 0 && firstLength + 4 <= sample.count, "length-prefixed sample")
    check(!units.filter { H264.type($0) == 5 }.isEmpty, "IDR slice present")
  }

  // A source rendition with B-frames (High profile): frames come in decode order, each with a
  // decode time of its own that the decoder needs (giving it the presentation time instead
  // decoded them out of order: a frozen, green-smeared picture).
  if let bframes = try? Data(contentsOf: dir.appendingPathComponent("twitch_1080p_bframes.ts")) {
    var demuxer = TSDemuxer()
    let frames = (demuxer.feed(bframes) + demuxer.flush()).compactMap { if case .video(let f) = $0 { return f } else { return nil } }
    check(frames.count >= 10, "1080p frames \(frames.count)")
    check(frames.first?.isKeyframe == true, "1080p starts on a keyframe")
    check(frames.contains { $0.dts != $0.pts }, "decode times differ from presentation times")
    let decodeOrder = zip(frames, frames.dropFirst()).allSatisfy { $1.dts > $0.dts }
    check(decodeOrder, "decode times always increase: \(frames.prefix(8).map { ($0.pts, $0.dts) })")
    let presentationOrder = zip(frames, frames.dropFirst()).allSatisfy { $1.pts > $0.pts }
    check(!presentationOrder, "presentation times don't (B-frames)")
    check(frames.allSatisfy { $0.pts >= $0.dts }, "never shown before decoded")
    // Twitch's encoders don't line PES packets up with frames: a PES can begin with the end of
    // the previous frame. Every frame must start at its own start code, with nothing of the one
    // before (cut at the PES, frames lost their last bytes and the decoder rejected them).
    let startsClean = frames.allSatisfy { f in
      let b = [UInt8](f.data.prefix(4))
      return b.count == 4 && b[0] == 0 && b[1] == 0 && (b[2] == 1 || (b[2] == 0 && b[3] == 1))
    }
    check(startsClean, "every frame begins at a start code")
    check(frames.allSatisfy { AnnexB.units($0.data).first.map { H264.type($0) == 9 } ?? false }, "every frame begins with its delimiter")
  } else {
    check(false, "1080p fixture missing")
  }

  // One timeline across segments: a jump (a discontinuity) carries on right after the last frame.
  var timeline = StreamTimeline()
  timeline.beginSegment(firstPTS: 1_000_000, discontinuity: false)
  var t = Int64(1_000_000)
  for _ in 0..<60 {
    _ = timeline.map(t, isVideo: true)
    t += 3000
  }
  let lastBefore = timeline.lastTime ?? 0
  timeline.beginSegment(firstPTS: 50_000, discontinuity: true)
  let afterJump = timeline.map(50_000, isVideo: true)
  check(afterJump == lastBefore + 3000, "carries on after a discontinuity: \(afterJump) vs \(lastBefore)")
  // An unmarked jump of minutes is treated the same way.
  timeline.beginSegment(firstPTS: 90_000_000, discontinuity: false)
  check(timeline.map(90_000_000, isVideo: true) == afterJump + 3000, "unmarked jump")
  // Following on normally changes nothing.
  timeline.beginSegment(firstPTS: 90_003_000, discontinuity: false)
  check(timeline.map(90_003_000, isVideo: true) == afterJump + 6000, "no jump, no change")
  // Swapped to the ad-free copy, its times a tenth of a second ahead (and later back, a tenth
  // behind): joined on seamlessly, no gap or overlap (that played as a stutter in sound and video).
  timeline.beginSegment(firstPTS: 90_006_000 + 9000, discontinuity: false)
  check(timeline.map(90_006_000 + 9000, isVideo: true) == afterJump + 9000, "small jump ahead joined on")
  timeline.beginSegment(firstPTS: 90_009_000, discontinuity: false)
  check(timeline.map(90_009_000, isVideo: true) == afterJump + 12000, "small jump back joined on")
  // Real Twitch segments: the next one's first audio is a frame or so off the video's end.
  timeline.beginSegment(firstPTS: 90_012_000 + 1860, discontinuity: false)
  check(timeline.map(90_012_000 + 1860, isVideo: false) == afterJump + 15000 + 1860, "audio starting a frame off: left as is")

  // A stream whose audio starts a quarter of a second ahead of its video in every segment (the
  // segment's first frame is audio): segments follow on, nothing is shifted. Comparing the audio
  // with the video's end shifted every segment, a 240 ms gap in the sound each time.
  do {
    var line = StreamTimeline()
    var audioTimes: [Int64] = []
    var videoTimes: [Int64] = []
    var audioPTS: Int64 = 1_000_000 - 22_500
    for segment in 0..<4 {
      let videoStart = Int64(1_000_000 + segment * 180_000)
      line.beginSegment(firstPTS: audioPTS, isVideo: false, discontinuity: false)
      // Interleaved as muxed: audio up to the segment's end, video frames (with B-frame order).
      var a = audioPTS
      for k in 0..<120 {
        let order = [0, 3, 1, 2]
        let v = videoStart + Int64((k / 4) * 4 + order[k % 4]) * 1500
        videoTimes.append(line.map(v, isVideo: true))
        while a < videoStart + Int64(k + 1) * 1500 - 22_500 {
          audioTimes.append(line.map(a, isVideo: false))
          a += 1920
        }
      }
      audioPTS = a
    }
    let audioSteps = Set(zip(audioTimes, audioTimes.dropFirst()).map { $1 - $0 })
    let videoSorted = videoTimes.sorted()
    let videoSteps = Set(zip(videoSorted, videoSorted.dropFirst()).map { $1 - $0 })
    check(audioSteps == [1920], "audio leading video: continuous sound \(audioSteps)")
    check(videoSteps == [1500], "audio leading video: video untouched \(videoSteps)")
  }

  // Which segments to fetch.
  func playlist(_ first: Int, count: Int, prefetch: Int, discontinuityAt: Int? = nil) -> String {
    var lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:5", "#EXT-X-MEDIA-SEQUENCE:\(first)"]
    for i in 0..<count {
      if first + i == discontinuityAt { lines.append("#EXT-X-DISCONTINUITY") }
      lines.append("#EXT-X-PROGRAM-DATE-TIME:2026-11-03T00:00:\(String(format: "%02d", (2 * (first + i)) % 60)).000Z")
      lines.append("#EXTINF:2.000,live")
      lines.append("https://cdn/s\(first + i).ts")
    }
    for p in 0..<prefetch { lines.append("#EXT-X-TWITCH-PREFETCH:https://cdn/s\(first + count + p).ts") }
    return lines.joined(separator: "\n")
  }
  var planner = LiveSegmentPlanner(startBack: 1)
  let start = planner.plan(playlist(100, count: 10, prefetch: 2))
  check(start.map(\.sequence) == [108, 109, 110, 111], "starts near the edge: \(start.map(\.sequence))")
  check(start.map(\.live) == [false, false, true, true], "prefetch marked live")
  check(start[2].programDate != nil, "prefetch dated")
  let next = planner.plan(playlist(101, count: 10, prefetch: 2))
  check(next.map(\.sequence) == [112], "only the new one: \(next.map(\.sequence))")
  check(planner.plan(playlist(101, count: 10, prefetch: 2)).isEmpty, "nothing twice")
  let marked = planner.plan(playlist(103, count: 10, prefetch: 2, discontinuityAt: 113))
  check(marked.first?.sequence == 113 && marked.first?.discontinuity == false, "a fetched prefetch isn't fetched again")
  check(marked.map(\.sequence) == [113, 114], "on from there \(marked.map(\.sequence))")
  // Far behind (the playlist moved on past it): carry on from its start.
  let behind = planner.plan(playlist(200, count: 10, prefetch: 2))
  check(behind.first?.sequence == 200, "jumps to the playlist's start when far behind")
}

func testFMP4Demux() {
  let dir = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
  guard let initData = try? Data(contentsOf: dir.appendingPathComponent("twitch_fmp4_init.mp4")),
    let segment = try? Data(contentsOf: dir.appendingPathComponent("twitch_fmp4_segment.m4s"))
  else {
    check(false, "fMP4 fixtures missing")
    return
  }
  guard let initSegment = FMP4Init.parse(initData) else {
    check(false, "init segment didn't parse")
    return
  }
  let kinds = initSegment.tracks.values.map(\.kind)
  let video = kinds.compactMap { kind -> (Int, Int)? in if case .h264(let sps, let pps, _) = kind { return (sps.count, pps.count) } else { return nil } }
  check(video.first.map { $0.0 >= 1 && $0.1 >= 1 } ?? false, "avcC parameter sets \(kinds)")
  let audio = kinds.compactMap { kind -> ADTS.Config? in if case .aac(let c) = kind { return c } else { return nil } }
  check(audio.first.map { $0.objectType == 2 && [44100, 48000].contains($0.sampleRate) && $0.channels == 2 } ?? false, "esds config \(audio)")
  // A real segment: whole, then in awkward pieces.
  var whole = FMP4Demuxer(initSegment: initSegment)
  let all = whole.feed(segment)
  let frames = all.compactMap { if case .video(let f) = $0 { return f } else { return nil } }
  let sounds = all.compactMap { if case .audio(let f) = $0 { return f } else { return nil } }
  check(frames.count >= 10, "fMP4 video frames \(frames.count)")
  check(sounds.count >= 10, "fMP4 audio frames \(sounds.count)")
  check(frames.first?.isKeyframe == true, "fMP4 starts on a keyframe")
  if let first = frames.first {
    let units = AnnexB.units(first.data)
    check(H264.parameterSets(units) != nil, "parameter sets put in front of the keyframe")
    check(units.contains { H264.type($0) == 5 }, "IDR slice in the keyframe")
  }
  check(zip(frames, frames.dropFirst()).allSatisfy { $1.dts > $0.dts }, "fMP4 decode times increase")
  let steps = Set(zip(frames, frames.dropFirst()).map { $1.dts - $0.dts })
  check(steps.allSatisfy { (1400...3100).contains($0) }, "fMP4 frame steps on 90 kHz \(steps)")
  check(frames.allSatisfy { $0.pts >= $0.dts }, "shown no earlier than decoded")
  if let v = frames.first, let a = sounds.first { check(abs(v.pts - a.pts) < 90_000, "audio and video on one clock \(v.pts) \(a.pts)") }
  var pieces = FMP4Demuxer(initSegment: initSegment)
  var chunked: [DemuxedFrame] = []
  var offset = 0
  var size = 3
  while offset < segment.count {
    let end = min(segment.count, offset + size)
    chunked += pieces.feed(segment.subdata(in: offset..<end))
    offset = end
    size = (size * 13 + 7) % 9001 + 1
  }
  check(chunked == all, "chunked fMP4 gives the same frames (\(chunked.count) vs \(all.count))")
  // The right demuxer from the first bytes.
  check(!SegmentDemuxer.isTransportStream(segment) && SegmentDemuxer.isTransportStream(Data([0x47, 0, 0])), "format sniffing")
  // Timescale conversion without overflow.
  check(FMP4Demuxer.to90k(48_000 * 3, 48_000) == 270_000 && FMP4Demuxer.to90k(1 << 50, 1000) == (1 << 50) * 90, "to 90 kHz")
  // The planner keeps the init segment with each segment.
  var planner = LiveSegmentPlanner(startBack: 0)
  let planned = planner.plan("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:5\n#EXT-X-MAP:URI=\"https://cdn/init.mp4\"\n#EXTINF:2.000,\nhttps://cdn/a.m4s\n#EXT-X-TWITCH-PREFETCH:https://cdn/b.m4s\n")
  check(planned.map(\.mapURI) == ["https://cdn/init.mp4", "https://cdn/init.mp4"], "init segment carried: \(planned.map(\.mapURI))")
}

testFMP4Demux()
testTSDemux()
testDeviceLogin()
testCatchUpSimulation()
testRestrictedVOD()
testRaids()
testAdFreeProxy()
testVODPlaylists()
testVODComments()
testStreamTags()
testAccountRoute()
testStoryboard()
testTokenInfo()
testDates()
testMasterParsing()
testFullWindowAdDetection()
testLowLatencySession()
testLiveCatchUp()
testConnectionFit()
testSteadyAutoQuality()
testMasterClock()
testRecordingPlaylist()
testMutedParts()
testMultiviewLayout()
testRecordingJoin()
testWholeSegmentSteering()
testConnectionFitTooSlow()
testQualityChangeNotLearned()
testStreamArrival()
testMediaParsing()
testFrameGrid()
testAV1Init()
testCatchUpHoldsOneSpeed()
testCatchUpHoversWithoutFlipping()
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
testEmoteText()
testChatReplay()
testAPIParsing()
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
