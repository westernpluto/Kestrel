// Is the stream still coming in?
//
// When the player sits buffering, there are two very different reasons. Either the stream itself
// has stopped arriving (the broadcaster's upload dropped out for a moment): starting the player over
// can't fix that, it only throws away what's in hand, so the right thing is to wait. Or the stream
// is arriving fine and the player is stuck by itself (it happens, e.g. after a switch between
// copies of the stream): then starting it over is the fix. The playlist server's session sees
// which: each playlist the player asks for says how far the stream has got.

import Foundation

final class StreamArrival: @unchecked Sendable {
  private let lock = NSLock()
  /// Per rendition: where its playlist ended (media sequence + segment count).
  private var ends: [Int: Int] = [:]
  private var askedAt: Date
  private var movedAt: Date

  init(now: Date = Date()) {
    askedAt = now
    movedAt = now
  }

  /// The player asked for a playlist.
  func asked(now: Date = Date()) {
    lock.lock()
    askedAt = now
    lock.unlock()
  }

  /// A playlist for rendition `index` ended at segment `end`.
  func saw(index: Int, end: Int, now: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    // (A rendition's first playlist says nothing about whether the stream is moving.)
    if let previous = ends[index], previous != end { movedAt = now }
    ends[index] = end
  }

  /// Seconds since the player last asked for a playlist, and since the stream last moved on.
  func ages(now: Date = Date()) -> (asked: TimeInterval, moved: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    return (now.timeIntervalSince(askedAt), now.timeIntervalSince(movedAt))
  }

  /// What to do about a player that has been buffering for `buffering` seconds.
  enum Verdict: Equatable {
    /// Give it time (it's only been a moment, or the stream itself hasn't come in).
    case wait
    /// The stream hasn't come in for a while: the broadcaster's side, most likely.
    case waitingForStream
    /// Start the player over: it's stuck while the stream is fine, or it stopped asking for more.
    case restart
  }

  static func verdict(buffering: TimeInterval, asked: TimeInterval, moved: TimeInterval) -> Verdict {
    // Segments are two seconds long, so a stream that's moving moves within about that.
    let streamMoving = moved < 4.5
    if buffering < 3 { return .wait }
    // A live player asks for the playlist every couple of seconds: one that stopped asking is
    // stuck (and the stream's progress, only learned when it asks, says nothing).
    if asked > 6 { return buffering > 8 ? .restart : .wait }
    if !streamMoving {
      // Nothing to play yet; starting over can't help (unless it's been very long: something
      // may be wedged between here and Twitch).
      return buffering > 45 ? .restart : .waitingForStream
    }
    // The stream's coming in but the player isn't playing it.
    return buffering > 10 ? .restart : .wait
  }
}
