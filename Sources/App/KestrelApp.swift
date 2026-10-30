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
      // The system tab bar: the floating Liquid Glass bar (slide a finger along it to switch
      // sections). On iPhone Duo the system moves it to the side when that leaves more room.
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
    .background(WindowSizeReporter())
    .background(KeyboardDismisser())
  }
}

/// A tap anywhere outside the message box puts the keyboard away, wherever it lands (before, only
/// taps on chat or the video did). It watches taps on the whole window without taking them, so
/// whatever was tapped still gets the tap. Taps on the message box's row (the box, emoji and send
/// buttons, and the suggestions above it) keep the keyboard up.
struct KeyboardDismisser: UIViewRepresentable {
  func makeUIView(context: Context) -> DismisserView {
    let view = DismisserView()
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ view: DismisserView, context: Context) {}

  final class DismisserView: UIView, UIGestureRecognizerDelegate {
    private weak var installedOn: UIWindow?
    private lazy var tap: UITapGestureRecognizer = {
      let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
      tap.cancelsTouchesInView = false
      tap.delaysTouchesBegan = false
      tap.delaysTouchesEnded = false
      tap.delegate = self
      return tap
    }()

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard let window, window !== installedOn else { return }
      installedOn?.removeGestureRecognizer(tap)
      window.addGestureRecognizer(tap)
      installedOn = window
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
      guard let window = installedOn, let editor = FirstResponder.current as? UIView, editor.window === window else { return }
      let point = recognizer.location(in: window)
      let field = editor.convert(editor.bounds, to: window)
      if point.y >= field.minY - 56, point.y <= field.maxY + 14 { return }
      window.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
      true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      // Only while typing, and not on the text itself (moving the cursor).
      guard FirstResponder.current is UIView else { return false }
      var view = touch.view
      while let current = view {
        if current is UITextView || current is UITextField { return false }
        view = current.superview
      }
      return true
    }
  }
}

/// Whatever has the keyboard right now (found by asking the responder chain).
enum FirstResponder {
  private final class Finder: NSObject {
    static weak var found: UIResponder?
  }

  static var current: UIResponder? {
    Finder.found = nil
    UIApplication.shared.sendAction(#selector(UIResponder.kestrelReportFirstResponder), to: nil, from: nil, for: nil)
    return Finder.found
  }

  fileprivate static func report(_ responder: UIResponder) { Finder.found = responder }
}

extension UIResponder {
  @objc fileprivate func kestrelReportFirstResponder() { FirstResponder.report(self) }
}

/// Tells the orientation lock how big the window is: it changes when iPhone Duo is opened or
/// closed, and a large window is used whichever way it's held.
struct WindowSizeReporter: View {
  var body: some View {
    GeometryReader { proxy in
      Color.clear
        .onAppear { OrientationLock.windowSizeChanged(proxy.size) }
        .onChange(of: proxy.size) { size in OrientationLock.windowSizeChanged(size) }
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
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
