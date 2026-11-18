// Opens one screen straight away when the app is launched for screenshots (the simulator job,
// .github/workflows/screens.yml): `-KestrelShow browse`, `player`, `player-landscape`, `mini`,
// `channel`, `search`, `settings`, `following`, `emotes`, `emotes-scroll` (scrolled down through
// them, as a finger would), `emotes-scroll-back` (down, then partway back up),
// `emotes-pick-scroll` (the fourth section picked in the strip, then scrolled on). Without the
// launch argument it does nothing.

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
    case "channel", "player", "player-landscape", "mini", "emotes", "emotes-scroll", "emotes-scroll-back", "emotes-pick-scroll":
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
      case "emotes-scroll", "emotes-scroll-back", "emotes-pick-scroll":
        NotificationCenter.default.post(name: openEmotes, object: nil)
        // Until the emotes have come (up to 75 s: slow on the simulator job), then a moment for them to settle.
        for _ in 0..<150 where pickerState.isEmpty { try? await Task.sleep(nanoseconds: 500_000_000) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        note(screen, "open · \(pickerState)")
        if screen == "emotes-pick-scroll" {
          NotificationCenter.default.post(name: pickEmoteSection, object: nil)
          try? await Task.sleep(nanoseconds: 1_500_000_000)
          note(screen, "picked · \(pickerState)")
        }
        guard let scroll = emoteScrollView() else {
          ActivityLog.shared.add("Screen tour: no emote list to scroll")
          return
        }
        let height = scroll.contentSize.height - scroll.bounds.height
        ActivityLog.shared.add("Screen tour: emote list \(Int(scroll.contentSize.height)) tall")
        // Moved in steps, each animated, the way a swipe moves it.
        let start = scroll.contentOffset.y
        let stops: [CGFloat] =
          switch screen {
          case "emotes-scroll": [0.15, 0.3, 0.45, 0.55].map { height * $0 }
          case "emotes-scroll-back": [0.2, 0.45, 0.7, 0.85, 0.6, 0.42].map { height * $0 }
          default: [120, 260, 420, 600].map { min(height, start + $0) }
          }
        note(screen, "list frame \(scroll.convert(scroll.bounds, to: nil)) content \(scroll.contentSize) at \(scroll.contentOffset.y) · \(pickerState)")
        frame(screen, 0)
        for (index, stop) in stops.enumerated() {
          scroll.setContentOffset(CGPoint(x: 0, y: stop.rounded()), animated: true)
          try? await Task.sleep(nanoseconds: 900_000_000)
          note(screen, "step \(index + 1): to \(Int(stop)), at \(Int(scroll.contentOffset.y)) · \(pickerState)")
          frame(screen, index + 1)
        }
      default: break
      }
    default: break
    }
  }

  /// What the emote picker takes as the section scrolled to (screen tour only).
  static var pickerState = ""

  /// Where the tour's own frames and notes go (the job copies them out of the app's folder).
  private static var folder: URL? {
    guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
    let folder = documents.appendingPathComponent("tour", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private static func note(_ screen: String, _ line: String) {
    ActivityLog.shared.add("Screen tour: \(line)")
    guard let file = folder?.appendingPathComponent("\(screen).txt") else { return }
    let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    try? (old + line + "\n").write(to: file, atomically: true, encoding: .utf8)
  }

  /// A picture of the screen as it is now.
  @MainActor
  private static func frame(_ screen: String, _ index: Int) {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    guard let window = windows.first(where: \.isKeyWindow) ?? windows.first, let folder else { return }
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    try? image.pngData()?.write(to: folder.appendingPathComponent("\(screen)-\(index).png"))
  }

  /// The emote picker's list: the lowest scroll view up and down on screen that isn't chat (the
  /// picker sits under it).
  @MainActor
  private static func emoteScrollView() -> UIScrollView? {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    var found: [UIScrollView] = []
    func walk(_ view: UIView) {
      if let scroll = view as? UIScrollView, !(scroll is UITableView), !(scroll is UITextView),
        scroll.contentSize.height > scroll.bounds.height + 100, scroll.bounds.width > 150
      {
        found.append(scroll)
      }
      view.subviews.forEach(walk)
    }
    windows.forEach(walk)
    for scroll in found { ActivityLog.shared.add("Screen tour: scroll view \(scroll.convert(scroll.bounds, to: nil)) content \(scroll.contentSize)") }
    return found.max { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
  }

  /// Asks chat's message box to open the emote picker (screen tour only).
  static let openEmotes = Notification.Name("KestrelTourOpenEmotes")
  /// Asks the emote picker to pick its fourth section, as a tap in its strip would (screen tour only).
  static let pickEmoteSection = Notification.Name("KestrelTourPickEmoteSection")
}
