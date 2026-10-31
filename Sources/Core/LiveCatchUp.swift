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
// reloads. So this never jumps: it steers with the playback speed alone, a touch faster while more
// is in hand than needed, a touch slower (0.95×) while less is, which builds the margin back
// without a stall.
//
// It steers by what's in hand on average, not by each reading. Video arrives in pieces, so the
// buffer goes up with each piece and down until the next: steering on the reading itself sped up
// after every piece and stopped before the next, catching up all the time for nothing. Now it only
// catches up when there's been clearly more than needed for a few seconds, gently (1.05×; faster
// only when far behind), and carries on down to the margin in one go. Except right after it
// starts: then what's over the margin is just how far back the player joined, so it catches up at
// once (1.1×) and is close to live within seconds.
//
// And it learns the margin each stream needs from how its video actually arrives: it keeps track of
// how far delivery falls behind playback when the stream hiccups (whatever playing faster or slower
// accounts for aside), and keeps that much in hand plus a little air. It starts from the least the
// connection allows (half a second on Wi-Fi), or what the channel needed lately. A hiccup bigger
// than any lately raises the margin at once; once none that big has come for a few minutes, the
// margin comes back down within a minute or two. A steady stream on good Wi-Fi ends up around a
// second from live; a shaky one a little further back, but without the stalls and skips.

import Foundation

struct LiveCatchUp: Sendable {
  /// Seconds of video to keep in hand.
  private(set) var targetBuffer: Double
  /// The playback rate to use now.
  private(set) var rate: Float = 1
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
  private static let settleAfter: TimeInterval = 10
  /// The last reading: buffer, when, the rate it played at since, and where the playhead was.
  private var last: (buffer: Double, at: Date, rate: Float, position: Double?)?
  private var lastShrink: Date
  /// When the margin last grew: catching up stays gentle for a while after (playing fast spends
  /// the margin that rides out the next hiccup).
  private(set) var grewAt = Date.distantPast
  /// What's in hand on average lately (see the top), and when it was last brought up to date.
  private(set) var level: Double?
  private var levelAt: Date?
  /// Since when there's been clearly more in hand than needed (catching up waits for it to last).
  private var overSince: Date?
  /// The least to keep in hand on this connection (more on cellular: see `setFloor`).
  private(set) var floor = LiveCatchUp.minBuffer
  /// When playback (re)started: the first seconds catch up straight away (see `startWindow`).
  private var startedAt: Date

  static let minBuffer = 0.5
  static let maxBuffer = 3.5
  /// A margin above this (plus a little) means the stream's video arrives unevenly.
  static let startBuffer = 1.0
  /// Rates: well behind (after an outage), behind, a little behind (the usual one); and building
  /// the margin back up. Small enough that speech still sounds natural.
  static let rates: (fast: Float, medium: Float, gentle: Float, slow: Float) = (1.2, 1.1, 1.05, 0.95)
  /// Kept on top of the biggest hiccup lately.
  static let air = 0.3
  /// How quickly the average follows the readings (seconds).
  static let levelTime = 3.0
  /// Catching up starts once the average has been this far over the margin for `catchUpAfter`
  /// seconds (or at once when it's `catchUpNow` over), and stops this close to it.
  static let catchUpFrom = 0.35
  static let catchUpAfter: TimeInterval = 3
  static let catchUpNow = 3.0
  static let catchUpTo = 0.1
  /// Slowing down: the average this far under the margin, or the reading itself nearly dry.
  static let shortBy = 0.3
  static let nearlyDry = 0.35
  /// How long a hiccup counts.
  static let memory: TimeInterval = 180
  /// Smaller shortfalls are just the buffer's reading wobbling.
  private static let noise = 0.2
  /// Back down toward what's needed: a quarter of the way every few seconds, once the margin
  /// hasn't had to grow for a while (from 2 s to the minimum in about a minute and a half).
  private static let shrinkEvery: TimeInterval = 5
  private static let shrinkStep = 0.05
  private static let shrinkAfterGrowth: TimeInterval = 30
  private static let calmAfter: TimeInterval = 45
  /// Just started: whatever's over the margin is the join point's lag, not a burst of video, so
  /// it's caught up at once and a little faster (it settles within seconds, not minutes).
  static let startWindow: TimeInterval = 20
  static let startCatchUp = 0.3

  /// - Parameter targetBuffer: the margin to start from (what this channel needed last time, so it
  ///   doesn't have to learn it again).
  /// - Parameter targetBuffer: the margin to start from (what this channel needed lately, so it
  ///   doesn't have to stall to learn it again); otherwise the least the connection allows.
  init(targetBuffer: Double? = nil, now: Date = Date()) {
    self.targetBuffer = min(Self.maxBuffer, max(Self.minBuffer, targetBuffer ?? Self.minBuffer))
    holdUntil = now.addingTimeInterval(1)
    lastShrink = now
    startedAt = now
  }

  /// The margin the stream has needed lately (the biggest recent hiccup plus air; the minimum when
  /// there's been none).
  func neededBuffer(now: Date = Date()) -> Double {
    let recent = hiccups.filter { now.timeIntervalSince($0.at) < Self.memory }.map(\.depth).max()
    return min(Self.maxBuffer, max(floor, recent.map { $0 + Self.air } ?? 0))
  }

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
    guard playing, now >= holdUntil, let buffer, let latency, buffer.isFinite, latency.isFinite, buffer >= 0 else {
      rate = 1
      last = nil
      level = nil
      overSince = nil
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
    // Already well behind live (e.g. after a long outage): never slow down further.
    let wellBehind = latency > targetBuffer + 2.5
    let calm = now.timeIntervalSince(grewAt) > Self.calmAfter
    var next: Float = 1
    let short = buffer < Self.nearlyDry || excess < -Self.shortBy
    if !wellBehind, short || (rate < 1 && excess < 0) {
      // Less in hand than the stream needs (or about to run dry): build it back up, to the margin.
      next = Self.rates.slow
      overSince = nil
    } else if latency > targetBuffer + 0.5, maxRate > 1 {
      if excess > Self.catchUpFrom {
        if overSince == nil { overSince = now }
      } else if excess <= Self.catchUpTo {
        overSince = nil
      }
      let lasting = overSince.map { now.timeIntervalSince($0) >= Self.catchUpAfter } ?? false
      // Already catching up: carry on down to the margin (no stopping and starting).
      let catching = rate > 1 && excess > Self.catchUpTo
      let starting = now.timeIntervalSince(startedAt) < Self.startWindow && excess > Self.startCatchUp
      if catching || lasting || starting || excess > Self.catchUpNow {
        if excess > 4 || (starting && excess > 2.5) {
          // Far more than needed in hand (after an outage, or joining well back): catch up properly.
          next = Self.rates.fast
        } else if (excess > 1 && calm) || now.timeIntervalSince(startedAt) < Self.startWindow {
          next = Self.rates.medium
        } else {
          next = Self.rates.gentle
        }
        next = min(next, maxRate)
      }
    } else {
      overSince = nil
    }
    rate = next
    last = (buffer, now, rate, position)
    return rate
  }

  /// How far delivery falls behind: in each moment, video should arrive as fast as time passes; what
  /// arrived is what the buffer gained plus what was played. A hiccup deeper than the margin allows
  /// for raises it at once.
  private mutating func track(_ buffer: Double, position: Double?, now: Date) {
    guard let previous = last else { return }
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
    if shortfall > before + 0.05 || before == 0 { deepenedAt = now }
    if shortfall > 0, let deepenedAt, now.timeIntervalSince(deepenedAt) >= Self.settleAfter {
      if shortfallPeak > Self.noise { remember(shortfallPeak, now: now) }
      shortfall = 0
      shortfallPeak = 0
      return
    }
    if shortfall > 0 {
      shortfallPeak = max(shortfallPeak, shortfall)
      if shortfallPeak > Self.noise { grow(toCover: shortfallPeak, now: now) }
    } else if shortfallPeak > 0 {
      // Caught up again: remember how deep it went.
      if shortfallPeak > Self.noise { remember(shortfallPeak, now: now) }
      shortfallPeak = 0
    }
  }

  private mutating func remember(_ depth: Double, now: Date) {
    hiccups.removeAll { now.timeIntervalSince($0.at) >= Self.memory }
    hiccups.append((now, depth))
  }

  private mutating func grow(toCover depth: Double, now: Date) {
    let wanted = min(Self.maxBuffer, depth + Self.air)
    guard wanted > targetBuffer + 0.01 else { return }
    targetBuffer = wanted
    grewAt = now
  }

  /// The player ran out of video: the hiccup was deeper than the margin. Keep more in hand from
  /// now on (it plays slower for a bit to build it), and leave it be for a moment.
  mutating func stalled(now: Date = Date()) {
    let depth = max(shortfallPeak, targetBuffer) + 0.4
    remember(depth, now: now)
    grow(toCover: depth, now: now)
    shortfall = 0
    shortfallPeak = 0
    rate = 1
    last = nil
    level = nil
    overSince = nil
    holdUntil = max(holdUntil, now.addingTimeInterval(3))
  }

  /// Normal speed for a while, with no reading of the buffer (e.g. while the quality changes,
  /// which can empty and refill it).
  mutating func hold(for seconds: TimeInterval, now: Date = Date()) {
    rate = 1
    last = nil
    level = nil
    overSince = nil
    holdUntil = max(holdUntil, now.addingTimeInterval(seconds))
  }

  /// A new start (load, resume): normal speed, then steering once it's settled. What the stream
  /// has needed is kept.
  mutating func restart(now: Date = Date()) {
    startedAt = now
    rate = 1
    last = nil
    level = nil
    overSince = nil
    shortfall = 0
    shortfallPeak = 0
    holdUntil = now.addingTimeInterval(1)
  }
}
