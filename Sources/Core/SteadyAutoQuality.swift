// Auto quality that settles down.
//
// The player's own automatic quality reacts to every burst of bandwidth: a moment of good signal
// sends it up a quality, the connection can't keep that up, it runs dry and drops back down, and
// round it goes, stalling each time. This keeps it from going back to a quality that just failed:
// once a quality stalls (or the player had to drop straight back down from it), auto is held
// below it for a while, longer each time that quality fails again, then allowed to try once more.
//
// Qualities are ranks: 0 is the best, higher numbers are lower qualities (audio only isn't one).

import Foundation

struct SteadyAutoQuality: Sendable {
  /// The best rank auto may use (nil: any).
  private(set) var cap: Int?
  /// How many video qualities there are.
  private(set) var count: Int
  private var capUntil = Date.distantPast
  private var failures: [Int: Int] = [:]
  /// The quality playing, and since when.
  private var current: (rank: Int, since: Date)?
  /// The last time the player moved up a quality.
  private var lastUp: (rank: Int, at: Date)?
  private var steadyReported: Int?

  static let firstHold: TimeInterval = 30
  static let longestHold: TimeInterval = 8 * 60
  /// Dropping back down this soon after going up counts as that quality failing.
  static let bounceWindow: TimeInterval = 20
  /// Playing this long at one quality without trouble makes it the one to start at next time.
  static let steadyAfter: TimeInterval = 60

  init(count: Int) {
    self.count = count
  }

  /// A new stream, or the list of qualities changed: forget the history.
  mutating func reset(count: Int) {
    self = SteadyAutoQuality(count: count)
  }

  /// The player switched to another quality on its own.
  /// - Returns: true when the cap changed.
  @discardableResult
  mutating func switched(to rank: Int, now: Date = Date()) -> Bool {
    var changed = false
    if let previous = current?.rank {
      if rank < previous {
        lastUp = (rank, now)
      } else if rank > previous, let up = lastUp, up.rank == previous, now.timeIntervalSince(up.at) < Self.bounceWindow {
        changed = fail(previous, now: now)
      }
    }
    current = (rank, now)
    return changed
  }

  /// Playback ran dry.
  /// - Returns: true when the cap changed.
  @discardableResult
  mutating func stalled(now: Date = Date()) -> Bool {
    guard let rank = current?.rank else { return false }
    current = (rank, now)
    return fail(rank, now: now)
  }

  /// Once a hold is over, lets auto try one quality better again.
  /// - Returns: true when the cap changed.
  @discardableResult
  mutating func tick(now: Date = Date()) -> Bool {
    guard let cap, now >= capUntil else { return false }
    self.cap = cap > 1 ? cap - 1 : nil
    // Another step up only after a while at this one.
    capUntil = now.addingTimeInterval(Self.firstHold)
    return true
  }

  /// A quality auto has played smoothly for a while (once each), to start at next time.
  mutating func steadyRank(now: Date = Date()) -> Int? {
    guard let current, now.timeIntervalSince(current.since) >= Self.steadyAfter, steadyReported != current.rank else {
      return nil
    }
    steadyReported = current.rank
    return current.rank
  }

  private mutating func fail(_ rank: Int, now: Date) -> Bool {
    let below = rank + 1
    guard below < count else { return false }  // already the lowest
    let times = (failures[rank] ?? 0) + 1
    failures[rank] = times
    let hold = min(Self.longestHold, Self.firstHold * pow(2, Double(times - 1)))
    lastUp = nil
    steadyReported = nil
    let stricter = max(cap ?? 0, below)
    let changed = stricter != cap
    cap = stricter
    capUntil = now.addingTimeInterval(hold)
    return changed
  }
}
