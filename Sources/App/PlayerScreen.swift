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
  private var token: NSObjectProtocol?

  func start() {
    guard token == nil else { return }
    refresh()
    if let scene = Self.scene {
      observation = scene.observe(\.effectiveGeometry, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.refresh() }
      }
    }
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    token = NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      // The interface follows the device a moment later.
      for delay in [0.05, 0.35, 0.8] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.refresh() }
      }
    }
  }

  deinit {
    if let token { NotificationCenter.default.removeObserver(token) }
  }

  private func refresh() {
    guard let value = Self.currentOrientation, value != orientation else { return }
    orientation = value
  }

  /// The interface orientation, or the device's when the scene can't say.
  private static var currentOrientation: UIInterfaceOrientation? {
    if let value = scene?.effectiveGeometry.interfaceOrientation, value != .unknown { return value }
    switch UIDevice.current.orientation {
    case .landscapeLeft: return .landscapeRight  // device and interface name the sides oppositely
    case .landscapeRight: return .landscapeLeft
    case .portrait: return .portrait
    default: return nil
    }
  }

  private static var scene: UIWindowScene? {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
  }

  /// In landscape: whether the camera (Dynamic Island) is on the left, read right now.
  static var cameraOnLeftNow: Bool? { cameraOnLeft(currentOrientation) }

  /// The last orientation seen.
  var cameraOnLeft: Bool? { Self.cameraOnLeft(orientation) }

  private static func cameraOnLeft(_ orientation: UIInterfaceOrientation?) -> Bool? {
    switch orientation {
    case .landscapeRight?: return true  // the phone's top is on the left
    case .landscapeLeft?: return false
    default: return nil
    }
  }
}

/// The keyboard's height from the bottom of the screen, animated like the keyboard, from the
/// keyboard's own notifications. (A probe on UIKit's keyboard layout guide reported nonsense
/// inside SwiftUI and threw the message box to the top of the screen.)
final class KeyboardObserver: ObservableObject {
  @Published private(set) var overlap: CGFloat = 0
  private var tokens: [NSObjectProtocol] = []

  init() {
    let center = NotificationCenter.default
    for name in [
      UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification,
      UIResponder.keyboardDidChangeFrameNotification,
    ] {
      tokens.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
          self?.handle(note)
        })
    }
  }

  deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

  private func handle(_ note: Notification) {
    let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
    let screen = UIScreen.main.bounds
    let hiding = note.name == UIResponder.keyboardWillHideNotification || end.isEmpty || end.minY >= screen.maxY - 1
    // Never more than the keyboard can be (guards against a bogus frame).
    let value = hiding ? 0 : min(screen.height * 0.6, max(0, screen.maxY - end.minY))
    guard abs(value - overlap) > 0.5 else { return }
    // The keyboard's own curve (a heavily damped spring).
    withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)) { overlap = value }
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
  /// Landscape chat sits on the side away from the Dynamic Island, so its text can run to the
  /// edge; the island's strip becomes the edge of the video's black border instead.
  var chatOnLeft = false

  static let infoHeight: CGFloat = 62
  /// How far from the screen edge the Dynamic Island reaches in landscape (plus a little air).
  static let cameraClearance: CGFloat = 52

  /// - Parameters:
  ///   - safe: size of the safe area; `insets`: from it to the screen edges.
  ///   - keyboard: keyboard height from the bottom of the screen.
  ///   - cameraOnLeft: landscape only; nil = unknown (keep clear on both sides).
  init(safe: CGSize, insets: EdgeInsets, keyboard: CGFloat, chatOpen: Bool, chatWidth: CGFloat, cameraOnLeft: Bool?) {
    landscape = safe.width > safe.height
    // A little air above the keyboard (newer keyboards draw slightly above the frame they report).
    let bottomPad = keyboard > 0 ? keyboard + 14 : insets.bottom
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
    let clearance = min(Self.cameraClearance, max(insets.leading, insets.trailing))
    // Camera on the right: chat goes left. Unknown: chat right, clear of a camera on either side.
    chatOnLeft = cameraOnLeft == false
    let cameraOnChatSide = cameraOnLeft == nil
    if chatOpen {
      if chatOnLeft {
        panel = CGRect(x: left, y: top, width: chat, height: height)
        panelPadding = EdgeInsets(top: insets.top + 6, leading: 12, bottom: bottomPad, trailing: 0)
        let videoRight = right - clearance
        video = CGRect(x: panel.maxX, y: top, width: videoRight - panel.maxX, height: height)
        controls = EdgeInsets(top: insets.top + 8, leading: 8, bottom: insets.bottom + 4, trailing: 8)
      } else {
        panel = CGRect(x: right - chat, y: top, width: chat, height: height)
        panelPadding = EdgeInsets(
          top: insets.top + 6, leading: 0, bottom: bottomPad, trailing: cameraOnChatSide ? clearance : 12)
        let videoLeft = left + clearance
        video = CGRect(x: videoLeft, y: top, width: panel.minX - videoLeft, height: height)
        controls = EdgeInsets(top: insets.top + 8, leading: 8, bottom: insets.bottom + 4, trailing: 8)
      }
      panelVisible = true
    } else {
      // Full screen: a 16:9 picture at full height leaves room for the camera on its own.
      video = CGRect(x: left, y: top, width: screenWidth, height: height)
      controls = EdgeInsets(top: insets.top + 8, leading: clearance, bottom: insets.bottom + 4, trailing: clearance)
      panel = chatOnLeft
        ? CGRect(x: left - chat - 1, y: top, width: chat, height: height)
        : CGRect(x: right + 1, y: top, width: chat, height: height)
      panelPadding = EdgeInsets(
        top: insets.top + 6, leading: chatOnLeft ? 12 : 0, bottom: bottomPad, trailing: chatOnLeft ? 0 : 12)
      panelVisible = false
    }
  }

  /// The mini player: a small floating video just above the tab bar, bottom right.
  /// - Parameter tabBar: how much of the screen's bottom the tab bar covers.
  static func mini(safe: CGSize, bottomInset: CGFloat, tabBar: CGFloat) -> CGRect {
    let width = (min(safe.width, 520) * 0.5).rounded()
    let height = (width * 9 / 16).rounded()
    let bottom = safe.height + bottomInset - max(tabBar, 49 + bottomInset) - 10
    return CGRect(x: safe.width - width - 10, y: bottom - height, width: width, height: height)
  }

  /// Room to leave under scrolling content for the mini player.
  static var miniInset: CGFloat {
    let width = min(UIScreen.main.bounds.width, 520) * 0.5
    return (width * 9 / 16).rounded() + 20
  }
}

private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
  CGRect(
    x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
    width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
}

// MARK: - Screen

/// The player, shown over the app: full screen, or shrunk into the mini player.
struct PlayerScreen: View {
  let target: PlaybackTarget
  @StateObject private var model: PlayerModel
  @StateObject private var chat: ChatController
  @StateObject private var keyboard = KeyboardObserver()
  @StateObject private var orientation = InterfaceOrientationObserver()
  @EnvironmentObject private var app: AppModel
  @AppStorage("landscapeChat") private var landscapeChat = true
  /// Landscape chat width, as a share of the screen width (drag the chat's edge to change it).
  @AppStorage("landscapeChatShare") private var chatShare = 0.32
  @State private var resizingFrom: CGFloat?
  @State private var resizedWidth: CGFloat?
  /// 0 = full screen … 1 = mini player, while a finger is moving it.
  @State private var dragProgress: CGFloat?
  /// The mini player following a finger (to throw it away).
  @State private var miniOffset: CGSize = .zero
  @State private var closing = false

  static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)

  init(target: PlaybackTarget) {
    self.target = target
    _model = StateObject(wrappedValue: PlayerModel(target: target))
    switch target {
    case .live(let channel):
      _chat = StateObject(wrappedValue: ChatController(channel: channel))
    case .video(let video):
      let owner = video.owner ?? Channel(id: "", login: "", displayName: "", profileImageURL: nil)
      _chat = StateObject(wrappedValue: ChatController(channel: owner, replayVideoID: video.id))
    }
  }

  var body: some View {
    GeometryReader { geometry in
      let insets = Self.insets(geometry)
      let landscape = geometry.size.width > geometry.size.height
      let progress = landscape ? 0 : (dragProgress ?? (app.playerMinimized ? 1 : 0))
      let chatOpen = landscape && landscapeChat
      let screenWidth = geometry.size.width + insets.leading + insets.trailing
      let layout = PlayerLayout(
        safe: geometry.size, insets: insets, keyboard: keyboard.overlap, chatOpen: chatOpen,
        chatWidth: resizedWidth ?? screenWidth * chatShare,
        cameraOnLeft: landscape ? (InterfaceOrientationObserver.cameraOnLeftNow ?? orientation.cameraOnLeft) : nil)
      let mini = PlayerLayout.mini(safe: geometry.size, bottomInset: insets.bottom, tabBar: app.tabBarHeight)
        .offsetBy(dx: miniOffset.width, dy: miniOffset.height)
      let video = lerp(layout.video, mini, progress)
      let pullDistance = max(240, mini.minY - layout.video.minY)
      let expandedOpacity = Double(max(0, 1 - progress * 2.2))

      ZStack(alignment: .topLeading) {
        // Backdrop: fades away as the player shrinks, revealing the app.
        Color.black
          .frame(width: screenWidth, height: geometry.size.height + insets.top + insets.bottom)
          .offset(x: -insets.leading, y: -insets.top)
          .opacity(Double(1 - progress))
          .allowsHitTesting(progress < 0.01)

        if let info = layout.info {
          StreamInfoBar(model: model, target: target)
            .frame(width: info.width, height: info.height)
            .offset(x: info.minX, y: info.minY + progress * 140)
            .opacity(expandedOpacity)
            .allowsHitTesting(progress == 0)
        }

        sidePanel(layout)
          .frame(width: layout.panel.width, height: layout.panel.height)
          .background(landscape ? Color(white: 0.07) : Color.black)
          .overlay(alignment: .top) {
            if !landscape { Divider().overlay(Color.white.opacity(0.08)) }
          }
          .offset(x: layout.panel.minX, y: layout.panel.minY + progress * 260)
          .opacity(layout.panelVisible ? expandedOpacity : 0)
          .allowsHitTesting(layout.panelVisible && progress == 0)

        PlayerVideoArea(
          model: model, landscape: landscape, chatOpen: chatOpen, controlInsets: layout.controls,
          chromeVisible: progress == 0, minimized: app.playerMinimized, chatOnLeft: layout.chatOnLeft,
          toggleChat: { withAnimation(Self.spring) { landscapeChat.toggle() } },
          minimize: minimize,
          onPull: { dy in
            if dragProgress == nil { dismissKeyboard() }
            dragProgress = min(1, max(0, dy / pullDistance))
          },
          onPullEnd: { dy, predicted in
            let finish = (dragProgress ?? 0) > 0.5 || predicted / pullDistance > 0.55
            withAnimation(Self.spring) {
              app.playerMinimized = finish
              dragProgress = nil
            }
          }
        )
        .frame(width: video.width, height: video.height)
        .clipShape(RoundedRectangle(cornerRadius: 12 * progress, style: .continuous))
        .shadow(color: .black.opacity(0.5 * Double(progress)), radius: 14 * progress, y: 5 * progress)
        .offset(x: video.minX, y: video.minY)

        if chatOpen && progress == 0 { resizeHandle(layout, screenWidth: screenWidth) }

        if app.playerMinimized || progress > 0.5 {
          MiniPlayerOverlay(
            model: model,
            expand: expand,
            close: close,
            onDrag: { translation in
              if translation.height < -8, abs(translation.height) > abs(translation.width) {
                miniOffset = .zero
                dragProgress = min(1, max(0, 1 + translation.height / pullDistance))
              } else if dragProgress == nil {
                miniOffset = translation
              }
            },
            onDragEnd: { translation, predicted in
              if dragProgress != nil {
                let expandIt = (dragProgress ?? 1) < 0.55 || predicted.height / pullDistance < -0.5
                withAnimation(Self.spring) {
                  app.playerMinimized = !expandIt
                  dragProgress = nil
                }
              } else if abs(predicted.width) > 160 || predicted.height > 120 {
                // Thrown away.
                withAnimation(.easeOut(duration: 0.22)) {
                  miniOffset = CGSize(
                    width: abs(predicted.width) > 160 ? (predicted.width > 0 ? 1 : -1) * screenWidth : 0,
                    height: predicted.height > 120 ? 300 : 0)
                }
                close()
              } else {
                withAnimation(Self.spring) { miniOffset = .zero }
              }
            }
          )
          .frame(width: mini.width, height: mini.height)
          .offset(x: video.minX, y: video.minY)
          .opacity(Double(max(0, min(1, (progress - 0.5) * 2))))
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      .opacity(closing ? 0 : 1)
      .scaleEffect(closing ? 0.96 : 1, anchor: .bottomTrailing)
      .statusBarHidden(landscape && progress == 0)
      .persistentSystemOverlays(landscape && progress == 0 ? .hidden : .automatic)
    }
    .ignoresSafeArea(.keyboard)
    .preferredColorScheme(.dark)
    .animation(Self.spring, value: landscapeChat)
    .task {
      orientation.start()
      OrientationLock.playerVisible(true)
      chat.start()
      await model.start()
    }
    .onChange(of: model.position) { position in
      if chat.isReplay { chat.replay(at: position) }
    }
    .onChange(of: app.playerMinimized) { minimized in
      // The app is portrait; only the full-screen player turns.
      OrientationLock.playerVisible(!minimized)
      if minimized { dismissKeyboard() }
    }
    .onDisappear {
      model.stop()
      chat.stop()
      OrientationLock.playerVisible(false)
    }
  }

  private func minimize() {
    dismissKeyboard()
    withAnimation(Self.spring) { app.playerMinimized = true }
  }

  private func expand() {
    withAnimation(Self.spring) {
      miniOffset = .zero
      app.playerMinimized = false
    }
  }

  private func close() {
    // Stop right away (not when the view goes): closing has to end the sound for sure.
    model.stop()
    chat.stop()
    OrientationLock.playerVisible(false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      // Let other apps' audio carry on (fails harmlessly if something else is still playing).
      if app.playing == nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    withAnimation(.easeIn(duration: 0.2)) { closing = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
      if app.playing?.id == target.id { app.playing = nil }
    }
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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

  private func sidePanel(_ layout: PlayerLayout) -> some View {
    ChatPanel(chat: chat, bottomInset: layout.panelPadding.bottom, compact: layout.landscape)
      .padding(.top, layout.panelPadding.top)
      .padding(.leading, layout.panelPadding.leading)
      .padding(.trailing, layout.panelPadding.trailing)
  }

  /// Drag the line between video and chat to make chat wider or narrower.
  private func resizeHandle(_ layout: PlayerLayout, screenWidth: CGFloat) -> some View {
    Capsule()
      .fill(Color.white.opacity(resizingFrom == nil ? 0.22 : 0.6))
      .frame(width: 4, height: 44)
      .frame(width: 24, height: layout.panel.height)
      .contentShape(Rectangle())
      .offset(x: (layout.chatOnLeft ? layout.panel.maxX : layout.panel.minX) - 12, y: layout.panel.minY)
      .gesture(
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
          .onChanged { value in
            if resizingFrom == nil { resizingFrom = layout.panel.width }
            let dx = layout.chatOnLeft ? value.translation.width : -value.translation.width
            let width = (resizingFrom ?? layout.panel.width) + dx
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

/// On top of the mini player: tap to open, pause, close; drag up to open, throw to close.
struct MiniPlayerOverlay: View {
  @ObservedObject var model: PlayerModel
  var expand: () -> Void
  var close: () -> Void
  var onDrag: (CGSize) -> Void
  var onDragEnd: (CGSize, CGSize) -> Void

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.001)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
        .gesture(
          // Measured on the screen, not on the mini player (which moves with the finger: measuring
          // on it made it shake).
          DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { onDrag($0.translation) }
            .onEnded { onDragEnd($0.translation, $0.predictedEndTranslation) }
        )
      LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .center)
        .allowsHitTesting(false)
      HStack {
        Button {
          model.togglePause()
        } label: {
          Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            .font(.system(size: 17, weight: .bold))
            .frame(width: 40, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.85))
        .accessibilityLabel(model.isPaused ? "Play" : "Pause")
        Spacer()
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.system(size: 16, weight: .bold))
            .frame(width: 40, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.85))
        .accessibilityLabel("Close")
      }
      .foregroundColor(.white)
      .shadow(color: .black.opacity(0.6), radius: 3)
      .padding(.horizontal, 2)
    }
  }
}
