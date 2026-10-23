import Foundation

/// The two live players.
enum PlayerEngine: String, CaseIterable, Identifiable {
  /// Amazon IVS Player SDK: the playback engine Twitch's own apps are built on, with Twitch's
  /// real low-latency mode. Only present when the app was built with the SDK (the GitHub
  /// Actions build downloads it).
  case lowLatency
  /// Apple's AVPlayer with Kestrel's playlist filtering in front of it.
  case standard

  var id: String { rawValue }

  static var isLowLatencyBuilt: Bool {
    #if canImport(AmazonIVSPlayer)
      return true
    #else
      return false
    #endif
  }

  static var available: [PlayerEngine] { isLowLatencyBuilt ? [.lowLatency, .standard] : [.standard] }

  static var preferredDefault: PlayerEngine { isLowLatencyBuilt ? .lowLatency : .standard }

  /// Turns a stored value (including ones from older versions) into an engine this build has.
  static func resolve(_ stored: String?) -> PlayerEngine {
    guard let stored, let engine = PlayerEngine(rawValue: stored), available.contains(engine) else {
      return preferredDefault
    }
    return engine
  }

  var title: String {
    switch self {
    case .lowLatency: return "Low-latency player"
    case .standard: return "Apple player"
    }
  }
}
