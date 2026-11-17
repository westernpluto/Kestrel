// Opens one screen straight away when the app is launched for screenshots (the simulator job,
// .github/workflows/screens.yml): `-KestrelShow browse`, `player`, `player-landscape`, `mini`,
// `channel`, `search`, `settings`, `following`, `emotes`. Without the launch argument it does
// nothing.

import SwiftUI

enum ScreenTour {
  static var requested: String? { UserDefaults.standard.string(forKey: "KestrelShow") }

  @MainActor
  static func run() async {
    guard let screen = requested else { return }
    let app = AppModel.shared
    ActivityLog.shared.add("Screen tour: \(screen)")
    switch screen {
    case "following": app.tab = .following
    case "browse": app.tab = .browse
    case "search": app.tab = .search
    case "settings": app.tab = .settings
    case "channel", "player", "player-landscape", "mini", "emotes":
      app.tab = .browse
      // The most watched stream right now (a sure one to be live).
      guard let top = try? await TwitchAPI.shared.topStreams(first: 1).items.first else { return }
      if screen == "channel" {
        app.push(.channel(top.channel))
        return
      }
      app.playing = .live(top.channel)
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      switch screen {
      case "player-landscape": OrientationLock.force(.landscape)
      case "mini": withAnimation { app.playerMinimized = true }
      case "emotes": NotificationCenter.default.post(name: openEmotes, object: nil)
      default: break
      }
    default: break
    }
  }

  /// Asks chat's message box to open the emote picker (screen tour only).
  static let openEmotes = Notification.Name("KestrelTourOpenEmotes")
}
