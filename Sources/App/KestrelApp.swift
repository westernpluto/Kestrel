import AVFoundation
import SwiftUI

@main
struct KestrelApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var app = AppModel.shared
  @StateObject private var favorites = FavoritesStore.shared
  @StateObject private var settings = AppSettings.shared
  @Environment(\.scenePhase) private var scenePhase

  init() {
    // Before anything reads the Keychain: a reinstall starts signed out.
    AppReset.clearLeftoversAfterReinstall()
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
    .onChange(of: scenePhase) { phase in
      switch phase {
      case .active: LiveNotifier.shared.appBecameActive()
      case .background: LiveNotifier.shared.appEnteredBackground()
      default: break
      }
    }
  }
}

struct RootView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var favorites: FavoritesStore
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject private var following = FollowingStore.shared

  var body: some View {
    ZStack {
      // The system tab bar: built with the iOS 26 SDK it's the floating Liquid Glass bar (slide a
      // finger along it to switch sections).
      TabView(selection: $app.tab) {
        NavigationStack(path: $app.followingPath) { FollowingView().appDestinations().miniPlayerRoom() }
          .tabItem { Label("Following", systemImage: "heart") }
          .tag(AppTab.following)
        NavigationStack(path: $app.browsePath) { BrowseView().appDestinations().miniPlayerRoom() }
          .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
          .tag(AppTab.browse)
        NavigationStack(path: $app.searchPath) { SearchView().appDestinations().miniPlayerRoom() }
          .tabItem { Label("Search", systemImage: "magnifyingglass") }
          .tag(AppTab.search)
        NavigationStack { SettingsView().miniPlayerRoom() }
          .tabItem { Label("Settings", systemImage: "gearshape") }
          .tag(AppTab.settings)
      }
      .alert(
        "Following",
        isPresented: Binding(get: { following.notice != nil }, set: { if !$0 { following.notice = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(following.notice ?? "")
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

/// Measures the tab bar, so the mini player sits just above it. (Room for the mini player under
/// lists is a spacer row at their end: shrinking the screen's safe area for it left a black
/// block above the tab bar, and flickered as the player shrank.)
struct MiniPlayerRoom: ViewModifier {
  @EnvironmentObject private var app: AppModel

  func body(content: Content) -> some View {
    content
      .background(TabBarProbe { height in
        if abs(app.tabBarHeight - height) > 0.5 { app.tabBarHeight = height }
      })
  }
}

/// The last row of a list: room to scroll its end out from under the mini player.
struct MiniPlayerSpacer: View {
  @EnvironmentObject private var app: AppModel

  var body: some View {
    Color.clear
      .frame(height: app.playing != nil && app.playerMinimized ? PlayerLayout.miniInset : 1)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .accessibilityHidden(true)
  }
}

/// Reports how much of the screen's bottom the tab bar covers.
struct TabBarProbe: UIViewRepresentable {
  var report: (CGFloat) -> Void

  func makeUIView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.isUserInteractionEnabled = false
    view.report = report
    return view
  }

  func updateUIView(_ view: ProbeView, context: Context) {
    view.report = report
  }

  final class ProbeView: UIView {
    var report: ((CGFloat) -> Void)?
    private var measuring = false

    override func didMoveToWindow() {
      super.didMoveToWindow()
      measureSoon()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      measureSoon()
    }

    /// The bar settles after the screen does (and animates in iOS 26): measure now and again a
    /// moment later. Layout passes meanwhile (every frame of an animation) don't add more.
    private func measureSoon() {
      guard !measuring else { return }
      measuring = true
      DispatchQueue.main.async { [weak self] in self?.measure() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        self?.measuring = false
        self?.measure()
      }
    }

    private func measure() {
      guard let window, let bar = tabBarController()?.tabBar, !bar.isHidden, bar.window != nil else { return }
      let frame = bar.convert(bar.bounds, to: window)
      guard frame.height > 0 else { return }
      let covered = window.bounds.maxY - frame.minY
      guard covered > 20, covered < 200 else { return }
      DispatchQueue.main.async { [weak self] in self?.report?(covered.rounded()) }
    }

    private func tabBarController() -> UITabBarController? {
      var responder: UIResponder? = self
      while let current = responder {
        if let controller = current as? UIViewController, let tabs = controller.tabBarController { return tabs }
        if let tabs = current as? UITabBarController { return tabs }
        responder = current.next
      }
      return nil
    }
  }
}

extension View {
  func miniPlayerRoom() -> some View { modifier(MiniPlayerRoom()) }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    // Go-live alerts: background checks and taps on the notifications.
    LiveNotifier.register()
    return true
  }

  func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    OrientationLock.mask
  }
}
