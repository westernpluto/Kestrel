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
// reloads. So this never jumps: it steers with the playback speed alone, a touch faster (up to
// 1.2×) while more is in hand than needed, a touch slower (0.95×) while less is, which builds the
// margin back without a stall.
//
// And it learns the margin each stream needs from how its video actually arrives: it keeps track of
// how far delivery falls behind playback when the stream hiccups (whatever playing faster or slower
// accounts for aside), and keeps that much in hand plus a little air. A hiccup bigger than any
// lately raises the margin at once; when none that big has come for a few minutes, the margin
// creeps back down. A steady stream ends up under two seconds from live; a shaky one a little
// further back, but without the stalls and skips.

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
  /// The last reading: buffer, when, the rate it played at since, and where the playhead was.
  private var last: (buffer: Double, at: Date, rate: Float, position: Double?)?
  private var lastShrink: Date
  /// When the margin last grew: catching up stays gentle for a while after (playing fast spends
  /// the margin that rides out the next hiccup).
  private(set) var grewAt = Date.distantPast

  static let minBuffer = 0.7
  static let maxBuffer = 3.5
  static let startBuffer = 1.0
  /// Rates: well behind, behind, a little behind; and building the margin back up. Small enough
  /// that speech still sounds natural.
  static let rates: (fast: Float, medium: Float, gentle: Float, slow: Float) = (1.2, 1.1, 1.05, 0.95)
  /// Kept on top of the biggest hiccup lately.
  static let air = 0.3
  /// How long a hiccup counts.
  static let memory: TimeInterval = 300
  /// Smaller shortfalls are just the buffer's reading wobbling.
  private static let noise = 0.2
  private static let shrinkEvery: TimeInterval = 20
  private static let shrinkStep = 0.1
  private static let calmAfter: TimeInterval = 90

  /// - Parameter targetBuffer: the margin to start from (what this channel needed last time, so it
  ///   doesn't have to learn it again).
  init(targetBuffer: Double? = nil, now: Date = Date()) {
    self.targetBuffer = min(Self.maxBuffer, max(Self.minBuffer, targetBuffer ?? Self.startBuffer))
    holdUntil = now.addingTimeInterval(1)
    lastShrink = now
  }

  /// The margin the stream has needed lately (the biggest recent hiccup plus air; the minimum when
  /// there's been none).
  func neededBuffer(now: Date = Date()) -> Double {
    let recent = hiccups.filter { now.timeIntervalSince($0.at) < Self.memory }.map(\.depth).max()
    return min(Self.maxBuffer, max(Self.minBuffer, recent.map { $0 + Self.air } ?? 0))
  }

  /// Whether the margin is above the minimum because the stream's video arrives unevenly.
  var learnedUneven: Bool { targetBuffer > Self.startBuffer + 0.25 }

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
      return rate
    }
    let position = position.flatMap { $0.isFinite ? $0 : nil }
    track(buffer, position: position, now: now)

    // Back down toward what's been needed lately, a step at a time.
    let needed = neededBuffer(now: now)
    if needed < targetBuffer, now.timeIntervalSince(lastShrink) >= Self.shrinkEvery,
      now.timeIntervalSince(grewAt) > 60
    {
      targetBuffer = max(needed, targetBuffer - Self.shrinkStep)
      lastShrink = now
    }

    let excess = buffer - targetBuffer
    // Already well behind live (e.g. after a long outage): never slow down further.
    let wellBehind = latency > targetBuffer + 2.5
    let calm = now.timeIntervalSince(grewAt) > Self.calmAfter
    var next: Float = 1
    if !wellBehind, excess < -0.25 || (rate < 1 && excess < 0) {
      // Less in hand than the stream needs: build it back up (and carry on to the margin).
      next = Self.rates.slow
    } else if latency > targetBuffer + 0.5, maxRate > 1 {
      if excess > 3 {
        // Far more than needed in hand: catch up properly whatever the stream's like.
        next = Self.rates.fast
      } else if excess > 1.5 {
        next = calm ? Self.rates.fast : Self.rates.medium
      } else if excess > 0.6 {
        next = calm ? Self.rates.medium : Self.rates.gentle
      } else if excess > (rate > 1 ? 0.05 : 0.25) {
        // Once catching up, carry on down to the margin (no flapping around one threshold).
        next = Self.rates.gentle
      }
      if next > 1 { next = min(next, maxRate) }
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
    shortfall = max(0, shortfall + deficit)
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
    holdUntil = max(holdUntil, now.addingTimeInterval(3))
  }

  /// Normal speed for a while, with no reading of the buffer (e.g. while the quality changes,
  /// which can empty and refill it).
  mutating func hold(for seconds: TimeInterval, now: Date = Date()) {
    rate = 1
    last = nil
    holdUntil = max(holdUntil, now.addingTimeInterval(seconds))
  }

  /// A new start (load, resume): normal speed, then steering once it's settled. What the stream
  /// has needed is kept.
  mutating func restart(now: Date = Date()) {
    rate = 1
    last = nil
    shortfall = 0
    shortfallPeak = 0
    holdUntil = now.addingTimeInterval(1)
  }
}
