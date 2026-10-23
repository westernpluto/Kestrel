import AVFoundation
import SwiftUI

@main
struct KestrelApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var app = AppModel.shared
  @StateObject private var favorites = FavoritesStore.shared
  @StateObject private var settings = AppSettings.shared

  init() {
    signal(SIGPIPE, SIG_IGN)
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    _ = try? StreamProxy.shared.ensureRunning()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(app)
        .environmentObject(favorites)
        .environmentObject(settings)
        .preferredColorScheme(.dark)
        .tint(.accentTeal)
    }
  }
}

struct RootView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var favorites: FavoritesStore
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    ZStack {
      TabView {
        NavigationStack { FollowingView().appDestinations().miniPlayerRoom() }
          .tabItem { Label("Following", systemImage: "heart") }
        NavigationStack { BrowseView().appDestinations().miniPlayerRoom() }
          .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
        NavigationStack { SearchView().appDestinations().miniPlayerRoom() }
          .tabItem { Label("Search", systemImage: "magnifyingglass") }
        NavigationStack { SettingsView().miniPlayerRoom() }
          .tabItem { Label("Settings", systemImage: "gearshape") }
      }
      // The player sits over the app (not in a separate screen) so it can shrink into the mini
      // player and keep playing while you browse.
      if let target = app.playing {
        PlayerScreen(target: target)
          .id(target.id)
          .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .opacity))
          .zIndex(1)
      }
    }
    .animation(.spring(response: 0.42, dampingFraction: 0.88), value: app.playing?.id)
  }
}

/// Leaves room under scrolling content for the mini player.
struct MiniPlayerRoom: ViewModifier {
  @EnvironmentObject private var app: AppModel

  func body(content: Content) -> some View {
    content.safeAreaInset(edge: .bottom, spacing: 0) {
      Color.clear.frame(height: app.playing != nil && app.playerMinimized ? PlayerLayout.miniInset : 0)
    }
  }
}

extension View {
  func miniPlayerRoom() -> some View { modifier(MiniPlayerRoom()) }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    OrientationLock.mask
  }
}
