// Keeping a low-latency live stream close to live, smoothly.
//
// Twitch's low-latency playlists hand the player each segment while it's still being made, so the
// video arrives within about a second of the broadcast, and what the player holds in its buffer
// adds straight on top of that. The less in hand, the closer to live; but too little, and the first
// hiccup (a broadcaster's upload that stutters, a slow moment on the connection) runs it dry and it
// stalls.
//
// Jumping to the live edge after a stall, or restarting the stream to get closer, empties the
// buffer and sets up the next stall: on a shaky stream that turned into a loop of skips and
// reloads. So this never jumps: it steers with the playback speed alone, the way YouTube's and
// ExoPlayer's live players do: faster in proportion to how much more is in hand than needed (1.04×
// a second over, at most 1.06×, or 1.2× far behind), easing off as it nears the margin so it never overshoots into a
// stall; slower in proportion while there's less (at least 0.95×). Right after a start it catches
// up a little more keenly (what's over then is only how far back the player joined), so it's close
// to live within seconds.
//
// It steers by what's in hand on average, not by each reading: video arrives in pieces, so the
// reading goes up with each piece and down until the next, and steering on it sped up after every
// piece. Within a fifth of a second of the margin it leaves the speed alone, and it doesn't speed
// up while the reading itself is low (between pieces).
//
// And it learns the margin each stream needs from how its video actually arrives: it keeps track of
// how far delivery falls behind playback when the stream hiccups (whatever playing faster or slower
// accounts for aside), and keeps that much in hand plus a little air. It starts from the least the
// connection allows (0.6 s on Wi-Fi), or what the channel needed lately. A hiccup bigger
// than any lately raises the margin at once; once none that big has come for a few minutes, the
// margin comes back down within a minute or two. A steady stream on good Wi-Fi ends up around a
// second from live; a shaky one a little further back, but without the stalls and skips.
//
// Tuned against a simulation of Twitch's low-latency delivery (steady Wi-Fi, small hiccups, a shaky
// broadcaster, cellular with dropouts, video in big pieces): a hiccup is remembered in full for a
// few minutes and then fades over ten (forgetting it all at once let the next one of the same size
// stall it again, then the margin jumped back up: a loop of stalls, slowing down and catching up);
// it only speeds up for a clear surplus (0.4 s over), and only gently (1.06× for the usual
// surplus), so the speed changes far less often; and a gap longer than any margin could cover (a
// dropout on the connection) is only learned up to a point, instead of holding several seconds
// in hand for minutes afterwards. Compared with before: on a shaky stream, under half the stalls
// and speed changes, for under a tenth of a second more latency.

import Foundation

struct LiveCatchUp: Sendable {
  /// Seconds of video to keep in hand.
  private(set) var targetBuffer: Double
  /// The playback rate to use now.
  private(set) var rate: Float = 1
  /// When the speed last changed.
  private var changedAt = Date.distantPast
  /// No steering before this (just started, stalled or switched quality).
  private var holdUntil: Date
  /// Hiccups lately: when, and how far delivery fell behind (seconds of video).
  private var hiccups: [(at: Date, depth: Double)] = []
  /// How far delivery is behind playback right now, and the most it reached in this hiccup.
  private var shortfall = 0.0
  private var shortfallPeak = 0.0
  /// When the shortfall last got deeper: one that stops deepening without the late video ever
  /// turning up is over all the same after a while (it kept the margin up indefinitely).
  private var deepenedAt: Date?
  /// The margin when the current gap in delivery began: a gap that turns out to be an outage
  /// takes it back there (plus what an outage teaches), rather than leaving it as high as the gap
  /// pushed it on the way.
  private var marginBeforeGap: Double?
  /// When it last ran dry, and the margin before that: a stall that lasts longer than an outage
  /// was the connection dropping out, not the stream's rhythm, and is learned as one once it's over.
  private var stalledAt: Date?
  private var marginBeforeStall = 0.0
  private static let settleAfter: TimeInterval = 10
  /// The last reading: buffer, when, the rate it played at since, and where the playhead was.
  private var last: (buffer: Double, at: Date, rate: Float, position: Double?)?
  private var lastShrink: Date
  /// When the margin last grew (it isn't brought back down for a while after).
  private(set) var grewAt = Date.distantPast
  /// What's in hand on average lately (see the top), and when it was last brought up to date.
  private(set) var level: Double?
  private var levelAt: Date?
  /// The least to keep in hand on this connection (more on cellular: see `setFloor`).
  private(set) var floor = LiveCatchUp.minBuffer
  /// When playback (re)started: the first seconds catch up straight away (see `startWindow`).
  private var startedAt: Date

  static let minBuffer = 0.6
  static let maxBuffer = 3.5
  /// A margin above this (plus a little) means the stream's video arrives unevenly.
  static let startBuffer = 1.0
  /// Speed limits: well behind (after an outage), the usual most, a gentle one (multi-view's), and
  /// the slowest. Small enough that speech still sounds natural.
  static let rates: (fast: Float, medium: Float, gentle: Float, slow: Float) = (1.2, 1.06, 1.05, 0.95)
  /// Right after a start, what's over is only how far back it joined: won back more keenly.
  static let startRate: Float = 1.1
  /// Kept on top of the biggest hiccup lately.
  static let air = 0.4
  /// How quickly the average follows the readings (seconds).
  static let levelTime = 3.0
  /// Speed change per second of difference from the margin; a little more just after a start.
  static let gain = 0.04
  static let startGain = 0.1
  /// Steering starts this far from the margin and stops this close to it (no flip-flopping on a
  /// reading's wobble). Speeding up waits for a clearer surplus than slowing down waits for a
  /// shortfall: a little extra in hand costs a fraction of a second, a speed change is noticed.
  static let deadband = 0.25
  /// Slower when this far under the margin (later than this stalled more often in the shaky-stream
  /// simulation, which is worse than the speed change).
  static let slowDownBand = 0.25
  /// After a change of speed, this long at 1x before the next one starts (finishing one, or
  /// running nearly dry, needn't wait).
  static let restAfterChange: TimeInterval = 10
  static let speedUpBand = 0.4
  static let settle = 0.05
  /// The least change made (it eases in, but doesn't crawl over the last bit).
  static let minStep = 0.02
  /// The reading itself this low: slower at once, whatever the average says.
  static let nearlyDry = 0.35
  /// How long a hiccup counts: in full for `fullMemory`, then less and less (down to `fadeTo` of
  /// its depth) until `memory`.
  static let memory: TimeInterval = 600
  static let fullMemory: TimeInterval = 150
  static let fadeTo = 0.4
  /// A gap in delivery longer than this is an outage (the connection, not the stream's rhythm):
  /// no sensible margin covers it, so it's learned as no more than `outageLearned`.
  static let outage = 2.2
  static let outageLearned = 1.5
  /// Smaller shortfalls are just the buffer's reading wobbling (or, for a player that sees video
  /// arrive in bursts, the bursts): not hiccups to keep a margin for.
  let noise: Double
  /// Back down toward what's needed: a quarter of the way every few seconds, once the margin
  /// hasn't had to grow for a while (from 2 s to the minimum in about a minute and a half).
  private static let shrinkEvery: TimeInterval = 5
  private static let shrinkStep = 0.05
  private static let shrinkAfterGrowth: TimeInterval = 30
  /// Just started: whatever's over the margin is the join point's lag, not a burst of video, so
  /// it's caught up more keenly (it settles within seconds).
  static let startWindow: TimeInterval = 40
  /// The first seconds' readings aren't learned from (the player is still filling up, in bursts).
  static let learnAfterStart: TimeInterval = 3

  /// - Parameter targetBuffer: the margin to start from (what this channel needed lately, so it
  ///   doesn't have to stall to learn it again); otherwise the least the connection allows.
  /// - Parameter noise: shortfalls up to this are ignored (see `noise`).
  init(targetBuffer: Double? = nil, noise: Double = 0.2, now: Date = Date()) {
    self.noise = noise
    self.targetBuffer = min(Self.maxBuffer, max(Self.minBuffer, targetBuffer ?? Self.minBuffer))
    holdUntil = now.addingTimeInterval(1)
    lastShrink = now
    startedAt = now
  }

  /// The margin the stream has needed lately (the biggest recent hiccup plus air; the minimum when
  /// there's been none).
  func neededBuffer(now: Date = Date()) -> Double {
    var recent: Double?
    for hiccup in hiccups {
      let age = now.timeIntervalSince(hiccup.at)
      guard age < Self.memory else { continue }
      let fade = age <= Self.fullMemory ? 0 : (age - Self.fullMemory) / (Self.memory - Self.fullMemory)
      recent = max(recent ?? 0, hiccup.depth * (1 - (1 - Self.fadeTo) * fade))
    }
    return min(Self.maxBuffer, max(floor, recent.map { $0 + Self.air } ?? 0))
  }

  /// How much of a gap is learned (see `outage`).
  static func learnable(_ depth: Double) -> Double { depth > outage ? min(depth, outageLearned) : depth }

  /// Whether the margin is above the minimum because the stream's video arrives unevenly.
  var learnedUneven: Bool { targetBuffer > max(Self.startBuffer, floor) + 0.25 }

  /// The least to keep in hand on this connection: a cellular one hiccups more than Wi-Fi, so a
  /// little more is kept from the start rather than learned from a stall.
  mutating func setFloor(_ value: Double) {
    floor = min(Self.maxBuffer, max(Self.minBuffer, value))
    targetBuffer = max(targetBuffer, floor)
  }

  /// - Parameters:
  ///   - buffer: seconds buffered ahead of the playhead (nil: unknown).
  ///   - latency: seconds behind live (nil: unknown).
  ///   - playing: playing, not paused or buffering.
  ///   - position: the playhead, if known (how much was actually played since the last reading;
  ///     otherwise worked out from the rate).
  ///   - maxRate: the most it may speed up.
  /// - Returns: the rate to play at.
  @discardableResult
  mutating func update(
    buffer: Double?, latency: Double?, playing: Bool, position: Double? = nil, maxRate: Float = LiveCatchUp.rates.fast,
    now: Date = Date()
  ) -> Float {
    if playing, let at = stalledAt {
      stalledAt = nil
      if now.timeIntervalSince(at) > Self.outage { outageStallEnded() }
    }
    guard playing, now >= holdUntil, let buffer, let latency, buffer.isFinite, latency.isFinite, buffer >= 0 else {
      rate = 1
      last = nil
      level = nil
      return rate
    }
    let position = position.flatMap { $0.isFinite ? $0 : nil }
    track(buffer, position: position, now: now)

    // The average in hand (see the top).
    if let previous = level, let at = levelAt, now > at {
      let weight = 1 - exp(-now.timeIntervalSince(at) / Self.levelTime)
      level = previous + (buffer - previous) * weight
    } else if level == nil {
      level = buffer
    }
    levelAt = now
    let average = level ?? buffer

    // Back down toward what's been needed lately, a step at a time.
    let needed = neededBuffer(now: now)
    if needed < targetBuffer, now.timeIntervalSince(lastShrink) >= Self.shrinkEvery,
      now.timeIntervalSince(grewAt) > Self.shrinkAfterGrowth
    {
      targetBuffer = max(needed, targetBuffer - max(Self.shrinkStep, (targetBuffer - needed) / 4))
      lastShrink = now
    }

    let excess = average - targetBuffer
    // Already well behind live (e.g. after a long outage): never slower.
    let wellBehind = latency > targetBuffer + 2.5
    let starting = now.timeIntervalSince(startedAt) < Self.startWindow
    var next = 1.0
    if buffer < Self.nearlyDry, !wellBehind {
      // About to run dry: slower at once.
      next = Double(Self.rates.slow)
    } else if excess < -(rate < 1 ? Self.settle : Self.slowDownBand), !wellBehind {
      // Less in hand than needed: slower in proportion, building it back up.
      next = max(Double(Self.rates.slow), 1 + min(-Self.minStep, excess * Self.gain))
    } else if excess > (rate > 1 ? Self.settle : Self.speedUpBand),
      // Sticky like the surplus: it starts 0.3 s over and goes on until 0.1 s over. Without that it
      // flipped on and off with each wobble while latency hovered right at the line, and each speed
      // change briefly held the picture (a judder every second or so on 60 fps streams).
      latency > targetBuffer + (rate > 1 ? 0.1 : 0.3), maxRate > 1,
      buffer > Self.nearlyDry + 0.15
    {
      // More than needed: faster in proportion, easing off toward the margin. Just started and
      // well back (a fresh start's slow first connections): up to 1.2× for the first few seconds.
      let far = excess > 4 || (starting && excess > 2)
      let top = Double(min(far ? Self.rates.fast : starting ? Self.startRate : Self.rates.medium, maxRate))
      next = min(top, 1 + max(starting ? Self.minStep * 1.5 : Self.minStep, excess * (starting ? Self.startGain : Self.gain)))
    }
    // A few fixed speeds, held: each change of speed made the sound cut out for a moment (the
    // audio is re-stretched for the new speed), and easing off a hundredth at a time changed it
    // every couple of seconds while catching up. Now a catch-up is one speed until it's done
    // (faster only when far behind), and slowing down one speed too.
    if next > 1 {
      let fast = Double(min(Self.rates.fast, maxRate))
      let far = next >= 1.15
      if rate > 1 {
        // Already catching up: the same speed until it's done (up to the fast one if it's fallen
        // far behind meanwhile).
        next = far && Double(rate) < fast ? fast : Double(rate)
      } else {
        next = far ? fast : Double(min(starting ? Self.startRate : Self.rates.gentle, maxRate))
      }
      // (Never over what's allowed now.)
      next = min(next, Double(maxRate))
    } else if next < 1 {
      next = Double(Self.rates.slow)
    }
    if Float(next) != rate {
      let finishing = rate != 1 && next == 1
      let dry = buffer < Self.nearlyDry
      if rate == 1, !finishing, !dry, !starting, now.timeIntervalSince(changedAt) < Self.restAfterChange {
        next = 1
      } else {
        changedAt = now
      }
    }
    rate = Float(next)
    last = (buffer, now, rate, position)
    return rate
  }

  /// How far delivery falls behind: in each moment, video should arrive as fast as time passes; what
  /// arrived is what the buffer gained plus what was played. A hiccup deeper than the margin allows
  /// for raises it at once.
  private mutating func track(_ buffer: Double, position: Double?, now: Date) {
    guard let previous = last, now.timeIntervalSince(startedAt) >= Self.learnAfterStart, now >= quietUntil else { return }
    let elapsed = now.timeIntervalSince(previous.at)
    guard elapsed > 0, elapsed < 3 else { return }
    let played: Double
    if let position, let before = previous.position, position >= before, position - before < elapsed * 2 + 0.5 {
      played = position - before
    } else {
      played = Double(previous.rate) * elapsed
    }
    let deficit = elapsed - (buffer - previous.buffer) - played
    let before = shortfall
    shortfall = max(0, shortfall + deficit)
    if before == 0, shortfall > 0 { marginBeforeGap = targetBuffer }
    if shortfall > before + 0.05 || before == 0 { deepenedAt = now }
    if shortfall > 0, let deepenedAt, now.timeIntervalSince(deepenedAt) >= Self.settleAfter {
      if shortfallPeak > noise { remember(shortfallPeak, now: now) }
      shortfall = 0
      shortfallPeak = 0
      marginBeforeGap = nil
      return
    }
    if shortfall > 0 {
      shortfallPeak = max(shortfallPeak, shortfall)
      if shortfallPeak > noise { grow(toCover: shortfallPeak, now: now) }
    } else if shortfallPeak > 0 {
      // Caught up again: remember how deep it went.
      if shortfallPeak > noise { remember(shortfallPeak, now: now) }
      shortfallPeak = 0
      marginBeforeGap = nil
    }
  }

  /// - Parameter asIs: a stall's depth, already worked out (not put through the outage rule).
  private mutating func remember(_ depth: Double, now: Date, asIs: Bool = false) {
    let depth = asIs ? depth : Self.learnable(depth)
    hiccups.removeAll { now.timeIntervalSince($0.at) >= Self.memory }
    hiccups.append((now, depth))
  }

  private mutating func grow(toCover depth: Double, now: Date, asIs: Bool = false) {
    if !asIs, depth > Self.outage, let before = marginBeforeGap {
      let capped = max(before, min(Self.maxBuffer, Self.outageLearned + Self.air))
      if targetBuffer > capped { targetBuffer = capped }
      return
    }
    let wanted = min(Self.maxBuffer, (asIs ? depth : Self.learnable(depth)) + Self.air)
    guard wanted > targetBuffer + 0.01 else { return }
    targetBuffer = wanted
    grewAt = now
  }

  /// The player ran out of video: the hiccup was deeper than the margin. Keep more in hand from
  /// now on (it plays slower for a bit to build it), and leave it be for a moment.
  mutating func stalled(now: Date = Date()) {
    // Right after a change of quality: the switch's gap, not the connection's. Not learned.
    if now < quietUntil {
      stalledAt = now
      marginBeforeStall = targetBuffer
      shortfall = 0
      shortfallPeak = 0
      marginBeforeGap = nil
      rate = 1
      last = nil
      level = nil
      holdUntil = max(holdUntil, now.addingTimeInterval(3))
      return
    }
    // Deeper than the margin it had before this gap began (a gap that ran on into an outage is
    // only counted up to what an outage teaches). A stall only ever raises the margin: run
    // through the outage rule as a whole it could lower it, and a stream whose hiccups ran a
    // little past the outage length could never learn enough to stop stalling.
    let base = marginBeforeGap ?? targetBuffer
    let depth = min(Self.maxBuffer, max(Self.learnable(shortfallPeak), base) + 0.4)
    stalledAt = now
    marginBeforeStall = base
    remember(depth, now: now, asIs: true)
    grow(toCover: depth, now: now, asIs: true)
    shortfall = 0
    shortfallPeak = 0
    marginBeforeGap = nil
    rate = 1
    last = nil
    level = nil
    holdUntil = max(holdUntil, now.addingTimeInterval(3))
  }

  /// The stall that just ended lasted longer than an outage: the connection dropped out. What it
  /// taught is cut back to what an outage teaches (no margin covers a dropout; holding seconds
  /// more in hand for ten minutes afterwards only costs latency).
  private mutating func outageStallEnded() {
    let capped = max(marginBeforeStall, min(Self.maxBuffer, Self.outageLearned + Self.air))
    if targetBuffer > capped { targetBuffer = capped }
    if let last = hiccups.indices.last { hiccups[last].depth = min(hiccups[last].depth, Self.outageLearned) }
  }

  /// Normal speed for a while, with no reading of the buffer (e.g. while the quality changes,
  /// which can empty and refill it).
  /// Until when nothing is learned (just after a change of quality: the switch itself leaves a gap
  /// in delivery that isn't the connection's).
  private var quietUntil = Date.distantPast

  /// The quality changed. The gap the switch leaves isn't learned from (Auto's switches each
  /// raised the margin, and latency crept up while a picked quality stayed low). Stepped down
  /// because a quality was too much: what was learned at it lately is forgotten too, and the
  /// margin goes back to what's been needed otherwise.
  mutating func qualityChanged(lowered: Bool, now: Date = Date()) {
    hold(for: 3, now: now)
    // (Not shortening a pause for an ad break.)
    quietUntil = max(quietUntil, now.addingTimeInterval(10))
    shortfall = 0
    shortfallPeak = 0
    marginBeforeGap = nil
    guard lowered else { return }
    hiccups.removeAll { now.timeIntervalSince($0.at) < 180 }
    let needed = neededBuffer(now: now)
    if targetBuffer > needed { targetBuffer = needed }
  }

  /// An ad break: the stream comes from an ad-free copy meanwhile (another server, often far away,
  /// without Twitch's low latency), unevenly. Nothing is learned from it: learned, the margin grew
  /// during every blocked ad and stayed up for minutes after.
  mutating func pauseLearning() {
    quietUntil = .distantFuture
    shortfall = 0
    shortfallPeak = 0
    marginBeforeGap = nil
  }

  /// The ad break is over: learning again a few seconds on, and the margin back to what was
  /// needed before it (whatever crept in around the switches is forgotten).
  mutating func resumeLearning(now: Date = Date()) {
    quietUntil = now.addingTimeInterval(10)
    hiccups.removeAll { now.timeIntervalSince($0.at) < 300 }
    let needed = neededBuffer(now: now)
    if targetBuffer > needed { targetBuffer = needed }
  }

  mutating func hold(for seconds: TimeInterval, now: Date = Date()) {
    rate = 1
    last = nil
    level = nil
    holdUntil = max(holdUntil, now.addingTimeInterval(seconds))
  }

  /// A new start (load, resume): normal speed, then steering once it's settled. What the stream
  /// has needed is kept.
  mutating func restart(now: Date = Date()) {
    startedAt = now
    rate = 1
    last = nil
    level = nil
    shortfall = 0
    shortfallPeak = 0
    marginBeforeGap = nil
    holdUntil = now.addingTimeInterval(1)
  }
}
