import Foundation

/// The two live players.
enum PlayerEngine: String {
  /// Amazon IVS Player SDK: the playback engine Twitch's own apps are built on, with Twitch's
  /// real low-latency mode. Only present when the app was built with the SDK (the GitHub
  /// Actions build downloads it).
  case lowLatency
  /// Apple's AVPlayer with Kestrel's playlist filtering in front of it.
  case standard

  static var isLowLatencyBuilt: Bool {
    #if canImport(AmazonIVSPlayer)
      return true
    #else
      return false
    #endif
  }

  static var preferredDefault: PlayerEngine { isLowLatencyBuilt ? .lowLatency : .standard }
}
