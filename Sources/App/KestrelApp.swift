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
    TabView {
      NavigationStack { FollowingView().appDestinations() }
        .tabItem { Label("Following", systemImage: "heart") }
      NavigationStack { BrowseView().appDestinations() }
        .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
      NavigationStack { SearchView().appDestinations() }
        .tabItem { Label("Search", systemImage: "magnifyingglass") }
      NavigationStack { SettingsView() }
        .tabItem { Label("Settings", systemImage: "gearshape") }
    }
    .fullScreenCover(item: $app.playing) { target in
      PlayerScreen(target: target)
        .environmentObject(app)
        .environmentObject(favorites)
        .environmentObject(settings)
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    OrientationLock.mask
  }
}
