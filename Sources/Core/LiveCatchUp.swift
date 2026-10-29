// Keeping a low-latency live stream close to live.
//
// Twitch's low-latency playlists hand the player each segment while it's still being made, so the
// video arrives within about a second of the broadcast. What the player then holds in its buffer
// adds straight on top of that. It has to start on a keyframe (the start of a two-second segment),
// so it starts anywhere from zero to two seconds further back than it needs to, and it never makes
// that up by itself: that's why a stream could sit at 3–4 s until "Live" was pressed, and why each
// reload landed somewhere different.
//
// This plays a little faster while more is buffered than needed, until only a small safety margin
// is left. The margin grows when the player runs dry (a slow or bumpy connection) and creeps back
// down while playback is smooth.

import Foundation

struct LiveCatchUp: Sendable {
  /// Seconds of video to keep in hand.
  private(set) var targetBuffer: Double
  /// The playback rate to use now.
  private(set) var rate: Float = 1
  /// Nothing happens before this (just started, or just stalled).
  private var holdUntil: Date
  /// Smooth playback since then (the margin shrinks a step each `relaxAfter`).
  private var smoothSince: Date

  static let minBuffer = 0.7
  static let maxBuffer = 2.6
  static let startBuffer = 0.9
  /// Rates: well behind, behind, a little behind. Small enough that speech still sounds natural.
  static let rates: (fast: Float, medium: Float, gentle: Float) = (1.2, 1.1, 1.05)
  private static let relaxAfter: TimeInterval = 90

  init(now: Date = Date()) {
    targetBuffer = Self.startBuffer
    holdUntil = now.addingTimeInterval(1)
    smoothSince = now
  }

  /// - Parameters:
  ///   - buffer: seconds buffered ahead of the playhead (nil: unknown).
  ///   - latency: seconds behind live (nil: unknown).
  ///   - playing: playing, not paused or buffering.
  /// - Returns: the rate to play at.
  @discardableResult
  mutating func update(buffer: Double?, latency: Double?, playing: Bool, now: Date = Date()) -> Float {
    guard playing, now >= holdUntil, let buffer, let latency, buffer.isFinite, latency.isFinite else {
      rate = 1
      return rate
    }
    if now.timeIntervalSince(smoothSince) > Self.relaxAfter {
      targetBuffer = max(Self.minBuffer, targetBuffer - 0.1)
      smoothSince = now
    }
    // Already about as close as it gets: don't push it.
    guard latency > targetBuffer + 0.5 else {
      rate = 1
      return rate
    }
    let excess = buffer - targetBuffer
    let next: Float
    if excess > 1.5 {
      next = Self.rates.fast
    } else if excess > 0.6 {
      next = Self.rates.medium
    } else if excess > (rate > 1 ? 0.05 : 0.25) {
      // Once catching up, carry on down to the margin (no flapping around one threshold).
      next = Self.rates.gentle
    } else {
      next = 1
    }
    rate = next
    return rate
  }

  /// The player ran out of video: keep more in hand from now on, and leave it be for a while.
  mutating func stalled(now: Date = Date()) {
    targetBuffer = min(Self.maxBuffer, targetBuffer + 0.4)
    rate = 1
    holdUntil = now.addingTimeInterval(8)
    smoothSince = now
  }

  /// A new start (load, resume): normal speed, then catch up once it's settled.
  mutating func restart(now: Date = Date()) {
    rate = 1
    holdUntil = now.addingTimeInterval(1)
  }
}
