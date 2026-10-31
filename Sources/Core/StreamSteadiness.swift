// Telling a stream that keeps running dry from one that's fine.
//
// Low latency keeps under a second of video in hand. That's plenty for most broadcasts, but when
// a broadcaster's upload or encoder stutters (or the connection does), segments arrive late and
// that little runs out: the player stalls, jumps back to live or is restarted, and does it again a
// minute later. For such a stream it's better to sit a few seconds further back and play smoothly.
// This watches for that pattern (stalls and restarts close together), and lets go once the stream
// has played smoothly for a good while.

import Foundation

struct StreamSteadiness: Sendable {
  /// Keeping more in hand for this stream.
  private(set) var unsteady: Bool
  private var stalls: [Date] = []
  private var restarts: [Date] = []
  private var lastTrouble: Date?

  /// Seconds of video kept in hand while unsteady.
  static let buffer = 3.0
  /// Smooth this long: back to keeping it close.
  static let calmAfter: TimeInterval = 600
  private static let stallWindow: TimeInterval = 120
  private static let restartWindow: TimeInterval = 180

  /// - Parameter unsteady: the channel was unsteady lately (it starts that way, no stalls needed).
  init(unsteady: Bool = false, now: Date = Date()) {
    self.unsteady = unsteady
    lastTrouble = unsteady ? now : nil
  }

  /// The player ran dry mid-stream. Returns true when that makes the stream unsteady.
  mutating func stalled(now: Date = Date()) -> Bool {
    prune(now)
    stalls.append(now)
    lastTrouble = now
    return becomeUnsteady(stalls.count >= 3 || (stalls.count >= 2 && !restarts.isEmpty))
  }

  /// The player was restarted because of trouble (stuck, or an error). Returns true when that
  /// makes the stream unsteady.
  mutating func restarted(now: Date = Date()) -> Bool {
    prune(now)
    restarts.append(now)
    lastTrouble = now
    return becomeUnsteady(restarts.count >= 2 || !stalls.isEmpty)
  }

  /// Returns true when the stream has been smooth long enough to keep it close again.
  mutating func tick(now: Date = Date()) -> Bool {
    guard unsteady, let lastTrouble, now.timeIntervalSince(lastTrouble) > Self.calmAfter else { return false }
    unsteady = false
    stalls = []
    restarts = []
    return true
  }

  private mutating func prune(_ now: Date) {
    stalls.removeAll { now.timeIntervalSince($0) > Self.stallWindow }
    restarts.removeAll { now.timeIntervalSince($0) > Self.restartWindow }
  }

  private mutating func becomeUnsteady(_ condition: Bool) -> Bool {
    guard condition, !unsteady else { return false }
    unsteady = true
    return true
  }
}
