import Foundation

/// The two live players.
enum PlayerEngine: String {
  /// Apple's AVPlayer with Kestrel's playlist filtering in front of it.
  case standard
  /// Kestrel's own low-latency player (KestrelEngine), the default (Settings → Playback).
  case kestrel

  static var preferredDefault: PlayerEngine {
    AppSettings.shared.kestrelPlayer ? .kestrel : .standard
  }
}
