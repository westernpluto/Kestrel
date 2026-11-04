// The best quality, as long as the connection keeps up with it.
//
// Streams start at the best quality, and the player never changes a quality it was given. When the
// connection can't carry it (the stream kept arriving at the server, yet the player still ran dry,
// twice within a few minutes), no margin helps: it would stall over and over. So this steps down
// one quality (smoothly, at the next segment), and tries the one above again after a while with no
// trouble, waiting longer each time that quality fails. A quality picked by hand is left alone.
//
// Steps: 0 is the best quality, 1 the one below, and so on.

import Foundation

struct ConnectionFit: Sendable {
  /// How many qualities below the best to play.
  private(set) var step = 0
  /// How many video qualities there are.
  private(set) var count: Int
  private var stalls: [Date] = []
  /// When it last stepped up (a stall soon after means that quality failed again).
  private var steppedUpAt: Date?
  private var upAfter = Date.distantFuture
  private var failures: [Int: Int] = [:]

  /// Two stalls in this long, the connection's fault: one step down.
  static let window: TimeInterval = 180
  /// Stalling this soon after stepping up: straight back down.
  static let tryWindow: TimeInterval = 60
  static let firstWait: TimeInterval = 240
  static let longestWait: TimeInterval = 30 * 60

  init(count: Int) {
    self.count = count
  }

  mutating func reset(count: Int) {
    self = ConnectionFit(count: count)
  }

  /// The player ran dry while the stream itself kept coming in.
  /// - Returns: true when it stepped down.
  @discardableResult
  mutating func stalled(now: Date = Date()) -> Bool {
    stalls = stalls.filter { now.timeIntervalSince($0) < Self.window } + [now]
    let justTried = steppedUpAt.map { now.timeIntervalSince($0) < Self.tryWindow } ?? false
    guard stalls.count >= 2 || justTried, step + 1 < count else { return false }
    let times = (failures[step] ?? 0) + 1
    failures[step] = times
    step += 1
    stalls = []
    steppedUpAt = nil
    upAfter = now.addingTimeInterval(min(Self.longestWait, Self.firstWait * pow(2, Double(times - 1))))
    return true
  }

  /// Seen coming in slower than it plays for a while (the connection can't carry this quality,
  /// e.g. cellular underground): one step down before it runs dry, not after two stalls. Not again
  /// for a little while (the lower quality needs a moment to show it keeps up).
  /// - Returns: true when it stepped down.
  @discardableResult
  mutating func tooSlow(now: Date = Date()) -> Bool {
    guard step + 1 < count, now.timeIntervalSince(lastSlowStep) >= Self.slowGap else { return false }
    lastSlowStep = now
    let times = (failures[step] ?? 0) + 1
    failures[step] = times
    step += 1
    stalls = []
    steppedUpAt = nil
    upAfter = now.addingTimeInterval(min(Self.longestWait, Self.firstWait * pow(2, Double(times - 1))))
    return true
  }

  private var lastSlowStep = Date.distantPast
  static let slowGap: TimeInterval = 12

  /// Starts a few steps down (a cellular connection: a lower quality first), trying better once
  /// it's played smoothly for `tryAfter`.
  mutating func start(at step: Int, tryAfter: TimeInterval = 90, now: Date = Date()) {
    self.step = max(0, min(step, count - 1))
    upAfter = self.step > 0 ? now.addingTimeInterval(tryAfter) : .distantFuture
  }

  /// Once it's been smooth long enough, tries one quality better.
  /// - Returns: true when it stepped up.
  @discardableResult
  mutating func tick(now: Date = Date()) -> Bool {
    guard step > 0, now >= upAfter else { return false }
    step -= 1
    steppedUpAt = now
    stalls = []
    upAfter = step > 0 ? now.addingTimeInterval(Self.firstWait) : .distantFuture
    return true
  }
}
