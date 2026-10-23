// The watch screen, laid out like Twitch's app: video on top with controls that fade in on a
// tap (settings behind a gear: quality, low latency, video stats), chat below in portrait and
// beside the video in landscape.
//
// One layout for both orientations: the video, info bar and chat keep their identity and only
// move, so rotating, opening chat or bringing up the keyboard animates instead of rebuilding
// the player and chat. Safe areas and the keyboard are handled here (not by SwiftUI's keyboard
// avoidance, which left the message box under the keyboard in a full-screen cover).

import AVKit
import SwiftUI

// MARK: - Apple player surface

final class PlayerLayerView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// AVPlayer on a plain layer (Kestrel draws its own controls), with Picture in Picture and
/// audio that keeps playing in the background.
struct ApplePlayerSurface: UIViewRepresentable {
  enum Role { case main, rewind }
  let model: PlayerModel
  var role: Role = .main
  var fill: Bool

  private var player: AVPlayer { role == .main ? model.player : model.rewindPlayer }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.backgroundColor = .black
    view.playerLayer.player = player
    view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    context.coordinator.view = view
    context.coordinator.player = player
    if AVPictureInPictureController.isPictureInPictureSupported(),
      let pip = AVPictureInPictureController(playerLayer: view.playerLayer)
    {
      pip.canStartPictureInPictureAutomaticallyFromInline = true
      pip.delegate = context.coordinator
      context.coordinator.pip = pip
      switch role {
      case .main: model.applePictureInPicture = pip
      case .rewind: model.rewindPictureInPicture = pip
      }
    }
    return view
  }

  func updateUIView(_ view: PlayerLayerView, context: Context) {
    let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
    if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
  }

  final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
    weak var view: PlayerLayerView?
    weak var player: AVPlayer?
    var pip: AVPictureInPictureController?
    private var pictureInPicture = false
    private var detached = false
    private var tokens: [NSObjectProtocol] = []

    override init() {
      super.init()
      let center = NotificationCenter.default
      tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        self?.enteredBackground()
      })
      tokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
        self?.enteringForeground()
      })
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    /// Taking the player off the layer keeps the sound going in the background.
    private func enteredBackground() {
      guard !pictureInPicture, player?.currentItem != nil else { return }
      if AppSettings.shared.backgroundAudio {
        detached = true
        view?.playerLayer.player = nil
      } else {
        player?.pause()
      }
    }

    private func enteringForeground() {
      guard detached else { return }
      detached = false
      view?.playerLayer.player = player
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) { pictureInPicture = true }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) { pictureInPicture = false }
    func pictureInPictureController(
      _ controller: AVPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) { completionHandler(true) }
  }
}

struct AirPlayButton: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.tintColor = .white
    view.activeTintColor = UIColor(red: 0.16, green: 0.78, blue: 0.72, alpha: 1)
    view.prioritizesVideoDevices = true
    return view
  }
  func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

// MARK: - Orientation, keyboard

/// Browsing stays portrait; the player turns with the phone. The full-screen button and swipes
/// force an orientation, which then holds until the phone is physically turned that way (so
/// tapping full screen while holding the phone upright doesn't flip straight back).
enum OrientationLock {
  /// Read by `AppDelegate`.
  static private(set) var mask: UIInterfaceOrientationMask = .portrait
  private static var playerActive = false
  private static var forced: UIInterfaceOrientationMask?
  private static var observer: NSObjectProtocol?

  static func playerVisible(_ visible: Bool) {
    playerActive = visible
    forced = nil
    if visible {
      startObserving()
      apply(.allButUpsideDown, rotateTo: nil)
    } else {
      apply(.portrait, rotateTo: .portrait)
    }
  }

  /// `.portrait` or `.landscape`.
  static func force(_ orientation: UIInterfaceOrientationMask) {
    forced = orientation
    if orientation == .portrait {
      apply(.portrait, rotateTo: .portrait)
    } else {
      // Turn toward the side the phone is already tipped to, if any.
      let side: UIInterfaceOrientationMask = UIDevice.current.orientation == .landscapeRight ? .landscapeLeft : .landscapeRight
      apply(.landscape, rotateTo: side)
    }
  }

  private static func startObserving() {
    guard observer == nil else { return }
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    observer = NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
    ) { _ in releaseIfTurned() }
  }

  private static func releaseIfTurned() {
    guard playerActive, let forced else { return }
    let matches: Bool
    switch UIDevice.current.orientation {
    case .portrait: matches = forced == .portrait
    case .landscapeLeft, .landscapeRight: matches = forced == .landscape
    default: return
    }
    guard matches else { return }
    self.forced = nil
    apply(.allButUpsideDown, rotateTo: nil)
  }

  private static func apply(_ newMask: UIInterfaceOrientationMask, rotateTo target: UIInterfaceOrientationMask?) {
    mask = newMask
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
    for window in scene.windows {
      var controller = window.rootViewController
      while let current = controller {
        current.setNeedsUpdateOfSupportedInterfaceOrientations()
        controller = current.presentedViewController
      }
    }
    if let target { scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in } }
  }
}

/// Which way the interface is turned, so the layout knows which side the Dynamic Island is on
/// (a 180° turn doesn't change any sizes, so the layout can't tell by itself).
final class InterfaceOrientationObserver: ObservableObject {
  @Published private(set) var orientation: UIInterfaceOrientation = .portrait
  private var observation: NSKeyValueObservation?

  func start() {
    guard observation == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
    else { return }
    orientation = scene.interfaceOrientation
    observation = scene.observe(\.effectiveGeometry, options: [.new]) { [weak self] scene, _ in
      let value = scene.effectiveGeometry.interfaceOrientation
      DispatchQueue.main.async {
        guard let observer = self, observer.orientation != value else { return }
        observer.orientation = value
      }
    }
  }

  /// In landscape: whether the camera (Dynamic Island) is on the left. Nil when unknown.
  var cameraOnLeft: Bool? {
    switch orientation {
    case .landscapeRight: return true  // home side on the right, top of the phone on the left
    case .landscapeLeft: return false
    default: return nil
    }
  }
}

/// The keyboard's height from the bottom of the screen, animated like the keyboard.
final class KeyboardObserver: ObservableObject {
  @Published private(set) var overlap: CGFloat = 0
  private var tokens: [NSObjectProtocol] = []

  init() {
    let center = NotificationCenter.default
    for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
      tokens.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
          self?.handle(note)
        })
    }
  }

  deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

  private func handle(_ note: Notification) {
    let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
    let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    let screen = UIScreen.main.bounds
    let value = note.name == UIResponder.keyboardWillHideNotification || end.isEmpty ? 0 : max(0, screen.maxY - end.minY)
    guard abs(value - overlap) > 0.5 else { return }
    // The keyboard's own curve (a heavily damped spring).
    let animation: Animation? = duration > 0 ? .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0) : nil
    withAnimation(animation) { overlap = value }
  }
}

// MARK: - Layout

/// Where everything goes, in the coordinates of the safe area (frames can reach past it to the
/// screen edges).
struct PlayerLayout: Equatable {
  var video: CGRect
  /// Padding that keeps the controls inside the safe area.
  var controls: EdgeInsets
  var info: CGRect?
  var panel: CGRect
  /// Padding inside the panel (camera side, home indicator, keyboard).
  var panelPadding: EdgeInsets
  var panelVisible: Bool
  var landscape: Bool

  static let infoHeight: CGFloat = 62

  /// - Parameters:
  ///   - safe: size of the safe area; `insets`: from it to the screen edges.
  ///   - keyboard: keyboard height from the bottom of the screen.
  ///   - cameraOnLeft: landscape only; nil = unknown (keep clear on both sides).
  init(safe: CGSize, insets: EdgeInsets, keyboard: CGFloat, chatOpen: Bool, chatWidth: CGFloat, cameraOnLeft: Bool?) {
    landscape = safe.width > safe.height
    let bottomPad = max(insets.bottom, keyboard)
    if !landscape {
      let width = safe.width
      let videoHeight = (width * 9 / 16).rounded()
      video = CGRect(x: 0, y: 0, width: width, height: videoHeight)
      controls = EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
      info = CGRect(x: 0, y: videoHeight, width: width, height: Self.infoHeight)
      let top = videoHeight + Self.infoHeight
      panel = CGRect(x: 0, y: top, width: width, height: max(0, safe.height + insets.bottom - top))
      panelPadding = EdgeInsets(top: 0, leading: 0, bottom: bottomPad, trailing: 0)
      panelVisible = true
      return
    }
    info = nil
    let left = -insets.leading
    let right = safe.width + insets.trailing
    let screenWidth = right - left
    let top = -insets.top
    let height = safe.height + insets.top + insets.bottom
    let chat = min(max(chatWidth, 240), screenWidth * 0.5).rounded()
    let cameraLeft = cameraOnLeft ?? true
    let cameraRight = cameraOnLeft.map { !$0 } ?? true
    if chatOpen {
      // Chat runs to the screen edge (its text stays clear of the camera if it's on that side);
      // the video gets everything else, and only keeps clear of the camera.
      panel = CGRect(x: right - chat, y: top, width: chat, height: height)
      panelPadding = EdgeInsets(
        top: insets.top + 4, leading: 0, bottom: bottomPad, trailing: cameraRight ? insets.trailing : 10)
      panelVisible = true
      let videoLeft = cameraLeft ? 0 : left
      video = CGRect(x: videoLeft, y: top, width: panel.minX - videoLeft, height: height)
      controls = EdgeInsets(
        top: insets.top + 8, leading: cameraLeft ? 8 : insets.leading, bottom: insets.bottom + 4, trailing: 8)
    } else {
      // Full screen: a 16:9 picture at full height leaves room for the camera on its own.
      video = CGRect(x: left, y: top, width: screenWidth, height: height)
      controls = EdgeInsets(top: insets.top + 8, leading: insets.leading, bottom: insets.bottom + 4, trailing: insets.trailing)
      panel = CGRect(x: right + 1, y: top, width: chat, height: height)
      panelPadding = EdgeInsets(top: insets.top + 4, leading: 0, bottom: bottomPad, trailing: insets.trailing)
      panelVisible = false
    }
  }
}

// MARK: - Screen

struct PlayerScreen: View {
  let target: PlaybackTarget
  @StateObject private var model: PlayerModel
  @StateObject private var chat: ChatController
  @StateObject private var keyboard = KeyboardObserver()
  @StateObject private var orientation = InterfaceOrientationObserver()
  @Environment(\.dismiss) private var dismiss
  @AppStorage("landscapeChat") private var landscapeChat = true
  /// Landscape chat width, as a share of the screen width (drag the chat's edge to change it).
  @AppStorage("landscapeChatShare") private var chatShare = 0.32
  @State private var resizingFrom: CGFloat?
  @State private var resizedWidth: CGFloat?

  static let spring = Animation.spring(response: 0.34, dampingFraction: 0.9)

  init(target: PlaybackTarget) {
    self.target = target
    _model = StateObject(wrappedValue: PlayerModel(target: target))
    let channel: Channel
    switch target {
    case .live(let c): channel = c
    case .video(let video): channel = video.owner ?? Channel(id: "", login: "", displayName: "", profileImageURL: nil)
    }
    _chat = StateObject(wrappedValue: ChatController(channel: channel))
  }

  var body: some View {
    GeometryReader { geometry in
      let insets = Self.insets(geometry)
      let landscape = geometry.size.width > geometry.size.height
      let chatOpen = landscape && model.isLive && landscapeChat
      let screenWidth = geometry.size.width + insets.leading + insets.trailing
      let layout = PlayerLayout(
        safe: geometry.size, insets: insets, keyboard: keyboard.overlap, chatOpen: chatOpen,
        chatWidth: resizedWidth ?? screenWidth * chatShare, cameraOnLeft: orientation.cameraOnLeft)
      ZStack(alignment: .topLeading) {
        PlayerVideoArea(
          model: model, landscape: landscape, chatOpen: chatOpen, controlInsets: layout.controls,
          toggleChat: { withAnimation(Self.spring) { landscapeChat.toggle() } }, close: { dismiss() }
        )
        .frame(width: layout.video.width, height: layout.video.height)
        .offset(x: layout.video.minX, y: layout.video.minY)

        if let info = layout.info {
          StreamInfoBar(model: model, target: target)
            .frame(width: info.width, height: info.height)
            .offset(x: info.minX, y: info.minY)
            .transition(.opacity)
        }

        sidePanel(layout)
          .frame(width: layout.panel.width, height: layout.panel.height)
          .background(landscape ? Color(white: 0.07) : Color.black)
          .overlay(alignment: .top) {
            if !landscape { Divider().overlay(Color.white.opacity(0.08)) }
          }
          .offset(x: layout.panel.minX, y: layout.panel.minY)
          .opacity(layout.panelVisible ? 1 : 0)
          .allowsHitTesting(layout.panelVisible)

        if chatOpen { resizeHandle(layout, screenWidth: screenWidth) }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      .statusBarHidden(landscape)
      .persistentSystemOverlays(landscape ? .hidden : .automatic)
    }
    .ignoresSafeArea(.keyboard)
    .background(Color.black.ignoresSafeArea())
    .preferredColorScheme(.dark)
    .animation(Self.spring, value: landscapeChat)
    .task {
      orientation.start()
      OrientationLock.playerVisible(true)
      if model.isLive { chat.start() }
      await model.start()
    }
    .onDisappear {
      model.stop()
      chat.stop()
      OrientationLock.playerVisible(false)
    }
  }

  /// Distances from the safe area to the screen edges.
  private static func insets(_ geometry: GeometryProxy) -> EdgeInsets {
    let frame = geometry.frame(in: .global)
    var screen = UIScreen.main.bounds.size
    // Mid-rotation the screen can still report the old orientation: trust the safe area's shape.
    if (screen.width > screen.height) != (geometry.size.width > geometry.size.height) {
      screen = CGSize(width: screen.height, height: screen.width)
    }
    return EdgeInsets(
      top: max(0, frame.minY), leading: max(0, frame.minX),
      bottom: max(0, screen.height - frame.maxY), trailing: max(0, screen.width - frame.maxX))
  }

  @ViewBuilder
  private func sidePanel(_ layout: PlayerLayout) -> some View {
    Group {
      if model.isLive {
        ChatPanel(chat: chat, bottomInset: layout.panelPadding.bottom, compact: layout.landscape)
      } else {
        VideoDetails(target: target).padding(.bottom, layout.panelPadding.bottom)
      }
    }
    .padding(.top, layout.panelPadding.top)
    .padding(.trailing, layout.panelPadding.trailing)
  }

  /// Drag the line between video and chat to make chat wider or narrower.
  private func resizeHandle(_ layout: PlayerLayout, screenWidth: CGFloat) -> some View {
    Capsule()
      .fill(Color.white.opacity(resizingFrom == nil ? 0.22 : 0.6))
      .frame(width: 4, height: 44)
      .frame(width: 24, height: layout.panel.height)
      .contentShape(Rectangle())
      .offset(x: layout.panel.minX - 12, y: layout.panel.minY)
      .gesture(
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
          .onChanged { value in
            if resizingFrom == nil { resizingFrom = layout.panel.width }
            let width = (resizingFrom ?? layout.panel.width) - value.translation.width
            resizedWidth = min(max(width, 240), screenWidth * 0.5)
          }
          .onEnded { _ in
            if let width = resizedWidth { chatShare = Double(width / max(screenWidth, 1)) }
            resizingFrom = nil
            resizedWidth = nil
          }
      )
      .accessibilityLabel("Resize chat")
  }
}
