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

    private var settleWork: DispatchWorkItem?

    /// Taking the player off the layer keeps the sound going in the background. Picture in
    /// Picture starts on its own as the app goes (when it can), so this waits a moment first:
    /// taking the picture away right away stopped it.
    private func enteredBackground() {
      settleWork?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.settleInBackground() }
      settleWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func settleInBackground() {
      guard UIApplication.shared.applicationState == .background, !pictureInPicture,
        !(pip?.isPictureInPictureActive ?? false), player?.currentItem != nil
      else { return }
      if AppSettings.shared.backgroundAudio {
        detached = true
        view?.playerLayer.player = nil
      } else {
        player?.pause()
      }
    }

    private func enteringForeground() {
      settleWork?.cancel()
      settleWork = nil
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
///
/// A large window (iPhone Duo's inner display, an iPad) is never locked or turned: the app is used
/// whichever way the device is held, and full screen there just gives the video the whole window.
enum OrientationLock {
  /// Read by `AppDelegate`.
  static var mask: UIInterfaceOrientationMask { largeWindow ? .all : lockedMask }
  private static var lockedMask: UIInterfaceOrientationMask = .portrait
  /// The window is big enough to use any way up (at least 600 points both ways).
  static private(set) var largeWindow = false
  private static var playerActive = false
  private static var forced: UIInterfaceOrientationMask?
  private static var observer: NSObjectProtocol?

  /// The window's size (it changes when iPhone Duo is opened or closed).
  static func windowSizeChanged(_ size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    let large = isLarge(size)
    guard large != largeWindow else { return }
    largeWindow = large
    forced = nil
    apply(lockedMask, rotateTo: nil)
  }

  static func isLarge(_ size: CGSize) -> Bool { min(size.width, size.height) >= 600 }

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
    guard !largeWindow else { return }
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
    lockedMask = newMask
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
    for window in scene.windows {
      var controller = window.rootViewController
      while let current = controller {
        current.setNeedsUpdateOfSupportedInterfaceOrientations()
        controller = current.presentedViewController
      }
    }
    if let target, !largeWindow { scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in } }
  }
}

/// The app's window: its size is what layouts go by. (Not "the screen": iPhone Duo has two, and
/// the window doesn't always fill one.)
enum AppWindow {
  static var current: UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    return active?.windows.first { $0.isKeyWindow } ?? active?.windows.first
  }

  static var bounds: CGRect { current?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844) }
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
    // The keyboard's frame is in screen coordinates: where it starts in the app's window.
    let window = AppWindow.current
    let frame: CGRect
    if let window, let screen = window.windowScene?.screen, !end.isEmpty {
      frame = window.convert(end, from: screen.coordinateSpace)
    } else {
      frame = end
    }
    let bounds = window?.bounds ?? AppWindow.bounds
    let hiding = note.name == UIResponder.keyboardWillHideNotification || end.isEmpty || frame.minY >= bounds.maxY - 1
    // Never more than the keyboard can be (guards against a bogus frame).
    let value = hiding ? 0 : min(bounds.height * 0.6, max(0, bounds.maxY - frame.minY))
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
  /// A large window (iPhone Duo's inner display, iPad): never turned, chat stays beside or below
  /// the video, and full screen gives the video the whole window.
  var large = false
  /// Phone landscape, or full screen in a large window: the controls take their full-screen form
  /// (leave full screen, show or hide chat, the title on top).
  var fullScreen = false
  /// Large window, landscape: the room left under the video and its info bar, for the stream's
  /// details (the video is as wide as its column allows; a taller one would only add black bars).
  var details: CGRect?
  /// Landscape chat sits on the side away from the Dynamic Island (or iPhone Duo's status strip),
  /// so its text can run to the edge; the video takes the side with the camera instead.
  var chatOnLeft = false
  /// Chat lies over the video (phone landscape, by choice) instead of beside it.
  var chatOverlay = false

  static let infoHeight: CGFloat = 62
  /// Narrowest landscape chat on a phone (iPhone Duo's outer screen is short of width).
  static let minPhoneChat: CGFloat = 200
  /// How far from the screen edge the Dynamic Island reaches in landscape (plus a little air).
  static let cameraClearance: CGFloat = 52

  /// - Parameters:
  ///   - safe: size of the safe area; `insets`: from it to the screen edges.
  ///   - keyboard: keyboard height from the bottom of the screen.
  ///   - chatOpen: phone: landscape chat shown; large window: not in full screen.
  ///   - cameraOnLeft: landscape only; nil = unknown (keep clear on both sides).
  ///   - large: a large window (see `large`).
  ///   - theater: large window, landscape: just the video (halfway down its column) and chat, with
  ///     no info bar or details.
  ///   - chatOverVideo: phone landscape: chat over the video (which then gets the whole screen).
  init(
    safe: CGSize, insets: EdgeInsets, keyboard: CGFloat, chatOpen: Bool, chatWidth: CGFloat, cameraOnLeft: Bool?,
    large: Bool = false, theater: Bool = false, chatOverVideo: Bool = false
  ) {
    landscape = safe.width > safe.height
    self.large = large
    // A little air above the keyboard (newer keyboards draw slightly above the frame they report).
    let bottomPad = keyboard > 0 ? keyboard + 14 : insets.bottom
    // The window's edges, in safe-area coordinates.
    let windowLeft = -insets.leading
    let windowRight = safe.width + insets.trailing
    let windowTop = -insets.top
    let windowHeight = safe.height + insets.top + insets.bottom
    // A strip down one side that content has to stay out of: iPhone Duo's inner display runs its
    // status bar (and camera) down one edge in landscape.
    let stripOnRight = insets.trailing > insets.leading + 1
    if large && !chatOpen {
      // Full screen in a large window: the video gets all of it, whichever way it's held.
      fullScreen = true
      info = nil
      video = CGRect(x: windowLeft, y: windowTop, width: windowRight - windowLeft, height: windowHeight)
      controls = EdgeInsets(top: insets.top + 8, leading: insets.leading + 8, bottom: insets.bottom + 4, trailing: insets.trailing + 8)
      let chat = min(max(chatWidth, 280), (windowRight - windowLeft) * 0.45).rounded()
      chatOnLeft = landscape && stripOnRight
      panel = chatOnLeft
        ? CGRect(x: video.minX - chat - 1, y: video.minY, width: chat, height: video.height)
        : CGRect(x: video.maxX + 1, y: video.minY, width: chat, height: video.height)
      panelPadding = EdgeInsets(
        top: insets.top + 6, leading: chatOnLeft ? insets.leading : 0, bottom: bottomPad, trailing: chatOnLeft ? 0 : insets.trailing)
      panelVisible = false
      return
    }
    if large && landscape {
      // Chat in a full-height column on one side; the video at the top of the other, its info bar
      // under it, and the stream's details in the rest. When a strip runs down one side, the video
      // goes on that side and runs under it to the window's edge (only its controls and the text
      // below it keep clear), and chat takes the other side right up to that edge: chat beside the
      // strip would only leave an empty band, since text can't go under it.
      let chat = min(max(chatWidth, 280), (windowRight - windowLeft) * 0.45).rounded()
      chatOnLeft = stripOnRight
      let columnLeft: CGFloat
      let columnRight: CGFloat
      if chatOnLeft {
        panel = CGRect(x: windowLeft, y: windowTop, width: chat, height: windowHeight)
        panelPadding = EdgeInsets(top: insets.top + 6, leading: insets.leading, bottom: bottomPad, trailing: 0)
        columnLeft = panel.maxX + 1
        columnRight = windowRight
      } else {
        panel = CGRect(x: windowRight - chat, y: windowTop, width: chat, height: windowHeight)
        panelPadding = EdgeInsets(top: insets.top + 6, leading: 0, bottom: bottomPad, trailing: insets.trailing)
        columnLeft = windowLeft
        columnRight = panel.minX - 1
      }
      let column = columnRight - columnLeft
      let videoHeight = min((column * 9 / 16).rounded(), max(0, windowHeight - Self.infoHeight))
      // Text stays inside the safe area.
      let textLeft = max(columnLeft, 0)
      let textWidth = min(columnRight, safe.width) - textLeft
      let windowBottom = safe.height + insets.bottom
      if theater {
        // Theater: the stream and chat, nothing else; the video halfway down its column.
        let fullHeight = (column * 9 / 16).rounded()
        let height = min(fullHeight, windowHeight)
        video = CGRect(x: columnLeft, y: windowTop + ((windowHeight - height) / 2).rounded(), width: column, height: height)
        info = nil
      } else {
        video = CGRect(x: columnLeft, y: windowTop, width: column, height: videoHeight)
        info = CGRect(x: textLeft, y: video.maxY, width: textWidth, height: Self.infoHeight)
        let detailsTop = video.maxY + Self.infoHeight
        let room = windowBottom - detailsTop
        details = room >= 80 ? CGRect(x: textLeft, y: detailsTop, width: textWidth, height: room) : nil
      }
      controls = EdgeInsets(
        top: max(0, -video.minY) + 2, leading: max(0, -columnLeft) + 6, bottom: 2,
        trailing: max(0, columnRight - safe.width) + 6)
      panelVisible = true
      return
    }
    if !landscape {
      let width = safe.width
      // A strip down one side (iPhone Duo's outer screen runs its status bar and camera down the
      // side in portrait too): the video runs under it to the window's edges, its controls kept
      // clear; text below stays inside the safe area.
      let videoLeft = insets.leading + insets.trailing > 0 ? windowLeft : 0
      let videoSpan = insets.leading + insets.trailing > 0 ? windowRight - windowLeft : width
      let fullHeight = (videoSpan * 9 / 16).rounded()
      let windowBottom = safe.height + insets.bottom
      var videoHeight = fullHeight
      var showInfo = true
      if keyboard > 0 {
        // Typing: the message box and some chat have to fit above the keyboard. The info bar goes
        // first, then the video shrinks (iPhone Duo's inner display has a tall keyboard, and on
        // its own it left no room at all).
        let room = windowBottom - bottomPad
        let minChat: CGFloat = large ? 200 : 150
        if room - fullHeight - Self.infoHeight < minChat {
          showInfo = false
          videoHeight = min(fullHeight, max(min(110, fullHeight), room - minChat)).rounded()
        }
      }
      let videoWidth = videoHeight < fullHeight ? (videoHeight * 16 / 9).rounded() : videoSpan
      video = CGRect(x: videoLeft + ((videoSpan - videoWidth) / 2).rounded(), y: 0, width: videoWidth, height: videoHeight)
      controls = EdgeInsets(
        top: 2, leading: max(0, -video.minX) + 6, bottom: 2, trailing: max(0, video.maxX - width) + 6)
      info = showInfo ? CGRect(x: 0, y: videoHeight, width: width, height: Self.infoHeight) : nil
      let top = videoHeight + (showInfo ? Self.infoHeight : 0)
      panel = CGRect(x: 0, y: top, width: width, height: max(0, windowBottom - top))
      panelPadding = EdgeInsets(top: 0, leading: 0, bottom: bottomPad, trailing: 0)
      panelVisible = true
      return
    }
    info = nil
    fullScreen = true
    let left = -insets.leading
    let right = safe.width + insets.trailing
    let screenWidth = right - left
    let top = -insets.top
    let height = safe.height + insets.top + insets.bottom
    let chat = min(max(chatWidth, Self.minPhoneChat), screenWidth * 0.5).rounded()
    // An iPhone's landscape inset is a little wider than its Dynamic Island reaches; a wider one
    // (iPhone Duo's status strip) is kept clear in full.
    let sideInset = max(insets.leading, insets.trailing)
    let clearance = sideInset > 62 ? sideInset : min(Self.cameraClearance, sideInset)
    // Camera on the right: chat goes left. Unknown: chat right, clear of a camera on either side.
    chatOnLeft = cameraOnLeft == false
    let cameraOnChatSide = cameraOnLeft == nil
    if chatOpen && chatOverVideo {
      // Chat over the video: the video gets the whole screen (as wide as it goes), chat lies on
      // top of its side, and the controls keep to the uncovered part.
      chatOverlay = true
      video = CGRect(x: left, y: top, width: screenWidth, height: height)
      if chatOnLeft {
        panel = CGRect(x: left, y: top, width: chat, height: height)
        panelPadding = EdgeInsets(top: insets.top + 6, leading: 12, bottom: bottomPad, trailing: 0)
        controls = EdgeInsets(top: insets.top + 8, leading: chat + 8, bottom: insets.bottom + 4, trailing: clearance + 8)
      } else {
        panel = CGRect(x: right - chat, y: top, width: chat, height: height)
        panelPadding = EdgeInsets(
          top: insets.top + 6, leading: 0, bottom: bottomPad, trailing: cameraOnChatSide ? clearance : 12)
        controls = EdgeInsets(top: insets.top + 8, leading: clearance + 8, bottom: insets.bottom + 4, trailing: chat + 8)
      }
      panelVisible = true
    } else if chatOpen {
      // The video runs under the camera's side too (only its controls keep clear): every point of
      // width makes a 16:9 picture taller here.
      if chatOnLeft {
        panel = CGRect(x: left, y: top, width: chat, height: height)
        panelPadding = EdgeInsets(top: insets.top + 6, leading: 12, bottom: bottomPad, trailing: 0)
        video = CGRect(x: panel.maxX, y: top, width: right - panel.maxX, height: height)
        controls = EdgeInsets(top: insets.top + 8, leading: 8, bottom: insets.bottom + 4, trailing: clearance + 8)
      } else {
        panel = CGRect(x: right - chat, y: top, width: chat, height: height)
        panelPadding = EdgeInsets(
          top: insets.top + 6, leading: 0, bottom: bottomPad, trailing: cameraOnChatSide ? clearance : 12)
        video = CGRect(x: left, y: top, width: panel.minX - left, height: height)
        controls = EdgeInsets(top: insets.top + 8, leading: clearance + 8, bottom: insets.bottom + 4, trailing: 8)
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
    let width = min(AppWindow.bounds.width, 520) * 0.5
    return (width * 9 / 16).rounded() + 20
  }
}

private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
  CGRect(
    x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
    width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
}

// MARK: - Screen

/// Owns a player screen's player and chat without passing their changes on (see `PlayerScreen`).
final class PlayerSession: ObservableObject {
  let model: PlayerModel
  let chat: ChatController

  init(target: PlaybackTarget) {
    model = PlayerModel(target: target)
    switch target {
    case .live(let channel):
      chat = ChatController(channel: channel)
    case .video(let video):
      let owner = video.owner ?? Channel(id: "", login: "", displayName: "", profileImageURL: nil)
      chat = ChatController(channel: owner, replayVideoID: video.id)
    }
  }
}

/// Keeps chat in step with the video: VOD chat replay, and chat from the VOD while rewinding.
private struct ChatFollower: View {
  @ObservedObject var model: PlayerModel
  let chat: ChatController

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .allowsHitTesting(false)
      .onChange(of: model.position) { position in
        if chat.isReplay { chat.replay(at: position) }
      }
      // Rewinding a live stream: chat follows the VOD; back to live chat on return.
      .onChange(of: model.isRewinding) { rewinding in
        if rewinding, let videoID = model.rewind?.videoID {
          chat.startRewindReplay(videoID: videoID, at: model.rewindPosition)
        } else if !rewinding {
          chat.endRewindReplay()
        }
      }
      .onChange(of: model.rewindPosition) { position in
        if model.isRewinding { chat.replay(at: position) }
      }
  }
}

/// The player, shown over the app: full screen, or shrunk into the mini player.
struct PlayerScreen: View {
  let target: PlaybackTarget
  /// The player and chat are owned here but not watched: this screen's layout doesn't depend on
  /// their state, so it isn't rebuilt every time the player ticks (the views that show player
  /// state watch it themselves). Rebuilding all of it twice a second cost animations frames.
  @StateObject private var session: PlayerSession
  private var model: PlayerModel { session.model }
  private var chat: ChatController { session.chat }
  @StateObject private var keyboard = KeyboardObserver()
  @StateObject private var orientation = InterfaceOrientationObserver()
  @EnvironmentObject private var app: AppModel
  @AppStorage("landscapeChat") private var landscapeChat = true
  /// Landscape chat width, as a share of the screen width (drag the chat's edge to change it).
  @AppStorage("landscapeChatShare") private var chatShare = 0.32
  /// Large window, landscape: theater mode (just the stream and chat).
  @AppStorage("largeTheater") private var theater = false
  /// Phone landscape: chat over the video instead of beside it.
  @AppStorage("chatOverVideo") private var chatOverVideo = false
  @State private var resizingFrom: CGFloat? = nil
  @State private var resizedWidth: CGFloat? = nil
  /// 0 = full screen … 1 = mini player, while a finger is moving it.
  @State private var dragProgress: CGFloat? = nil
  /// The mini player following a finger (to throw it away).
  @State private var miniOffset: CGSize = .zero
  @State private var closing = false
  /// Full screen in a large window (iPhone Duo's inner display): the video takes the whole window
  /// instead of the phone being turned.
  @State private var largeFullScreen = false

  static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)

  init(target: PlaybackTarget) {
    self.target = target
    _session = StateObject(wrappedValue: PlayerSession(target: target))
  }

  var body: some View {
    GeometryReader { geometry in
      let insets = Self.insets(geometry)
      let landscape = geometry.size.width > geometry.size.height
      let screenWidth = geometry.size.width + insets.leading + insets.trailing
      let large = OrientationLock.isLarge(CGSize(width: screenWidth, height: geometry.size.height + insets.top + insets.bottom))
      let chatOpen = large ? !largeFullScreen : landscape && landscapeChat
      let layout = PlayerLayout(
        safe: geometry.size, insets: insets, keyboard: keyboard.overlap, chatOpen: chatOpen,
        chatWidth: resizedWidth ?? screenWidth * chatShare,
        cameraOnLeft: landscape && !large ? (InterfaceOrientationObserver.cameraOnLeftNow ?? orientation.cameraOnLeft) : nil,
        large: large, theater: theater, chatOverVideo: chatOverVideo)
      // The layout choice the gear menu offers here, if any.
      let layoutToggle: LayoutToggle? =
        landscape && chatOpen
        ? (large
          ? LayoutToggle(title: "Theater mode", systemImage: "theatermasks", isOn: theater)
          : LayoutToggle(title: "Chat over video", systemImage: "text.bubble", isOn: chatOverVideo))
        : nil
      let progress = layout.fullScreen ? 0 : (dragProgress ?? (app.playerMinimized ? 1 : 0))
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
          StreamInfoBar(model: model, target: target, showsTitle: layout.details == nil)
            .frame(width: info.width, height: info.height)
            .offset(x: info.minX, y: info.minY + progress * 140)
            .opacity(expandedOpacity)
            .allowsHitTesting(progress == 0)
        }

        if let details = layout.details {
          StreamDetailsPanel(model: model, target: target)
            .frame(width: details.width, height: details.height)
            .offset(x: details.minX, y: details.minY + progress * 140)
            .opacity(expandedOpacity)
            .allowsHitTesting(progress == 0)
        }

        sidePanel(layout)
          .frame(width: layout.panel.width, height: layout.panel.height)
          .background(layout.chatOverlay ? Color.black.opacity(0.55) : landscape ? Color(white: 0.07) : Color.black)
          .overlay(alignment: .top) {
            if !landscape { Divider().overlay(Color.white.opacity(0.08)) }
          }
          .offset(x: layout.panel.minX, y: layout.panel.minY + progress * 260)
          .opacity(layout.panelVisible ? expandedOpacity : 0)
          .allowsHitTesting(layout.panelVisible && progress == 0)
          // Over the video when chat lies on top of it.
          .zIndex(layout.chatOverlay ? 1 : 0)

        // The mini player's shadow, cast from a fixed outline that moves with the video. (A shadow
        // worked out from the video's own pixels was redrawn on every frame while it moved, and
        // while lists scrolled underneath it.)
        MiniPlayerShadow()
          .frame(width: video.width, height: video.height)
          .offset(x: video.minX, y: video.minY)
          .opacity(Double(progress))
          .allowsHitTesting(false)

        PlayerVideoArea(
          model: model, landscape: layout.fullScreen, chatOpen: chatOpen, controlInsets: layout.controls,
          chromeVisible: progress == 0, minimized: app.playerMinimized, chatOnLeft: layout.chatOnLeft,
          viewersShownElsewhere: layout.details != nil,
          layoutToggle: layoutToggle,
          setLayoutToggle: { on in
            withAnimation(Self.spring) {
              if large { theater = on } else { chatOverVideo = on }
            }
          },
          toggleChat: {
            withAnimation(Self.spring) {
              if large { largeFullScreen.toggle() } else { landscapeChat.toggle() }
            }
          },
          minimize: minimize,
          enterFullScreen: {
            if large {
              dismissKeyboard()
              withAnimation(Self.spring) { largeFullScreen = true }
            } else {
              OrientationLock.force(.landscape)
            }
          },
          exitFullScreen: {
            if large {
              withAnimation(Self.spring) { largeFullScreen = false }
            } else {
              OrientationLock.force(.portrait)
            }
          },
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
        .offset(x: video.minX, y: video.minY)

        if layout.landscape && layout.panelVisible && progress == 0 {
          resizeHandle(layout, screenWidth: screenWidth).zIndex(2)
        }

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
      // A large window held sideways hides the status bar too (as an iPhone does in landscape):
      // on iPhone Duo's inner display it runs down one side of the video.
      .statusBarHidden((layout.fullScreen || (layout.large && layout.landscape)) && progress == 0)
      .persistentSystemOverlays(layout.fullScreen && progress == 0 ? .hidden : .automatic)
    }
    .ignoresSafeArea(.keyboard)
    .preferredColorScheme(.dark)
    .animation(Self.spring, value: landscapeChat)
    .background(ChatFollower(model: model, chat: chat))
    .task {
      orientation.start()
      OrientationLock.playerVisible(true)
      chat.start()
      await model.start()
    }
    .onChange(of: app.playerMinimized) { minimized in
      // The app is portrait; only the full-screen player turns.
      OrientationLock.playerVisible(!minimized)
      if minimized {
        dismissKeyboard()
        largeFullScreen = false
      }
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

  /// Distances from the safe area to the window's edges (the window, not the screen: iPhone Duo
  /// has two screens, and the window can be smaller than either). Each side on its own: they're
  /// often uneven, e.g. iPhone Duo's status bar runs down one side.
  private static func insets(_ geometry: GeometryProxy) -> EdgeInsets {
    let frame = geometry.frame(in: .global)
    var window = AppWindow.bounds.size
    // Mid-rotation the window can still report the old orientation: trust the safe area's shape.
    if (window.width > window.height) != (geometry.size.width > geometry.size.height) {
      window = CGSize(width: window.height, height: window.width)
    }
    return EdgeInsets(
      top: max(0, frame.minY), leading: max(0, frame.minX),
      bottom: max(0, window.height - frame.maxY), trailing: max(0, window.width - frame.maxX))
  }

  private func sidePanel(_ layout: PlayerLayout) -> some View {
    ChatPanel(
      chat: chat, bottomInset: layout.panelPadding.bottom, compact: layout.landscape && !layout.large,
      active: !app.playerMinimized)
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
            resizedWidth = layout.large
              ? min(max(width, 280), screenWidth * 0.45) : min(max(width, PlayerLayout.minPhoneChat), screenWidth * 0.5)
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

/// A soft shadow from a rounded outline (cheap to draw, unlike a shadow of the content itself).
struct MiniPlayerShadow: UIViewRepresentable {
  func makeUIView(context: Context) -> ShadowView { ShadowView() }
  func updateUIView(_ view: ShadowView, context: Context) {}

  final class ShadowView: UIView {
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      backgroundColor = .clear
      layer.shadowColor = UIColor.black.cgColor
      layer.shadowOpacity = 0.5
      layer.shadowRadius = 14
      layer.shadowOffset = CGSize(width: 0, height: 5)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
      super.layoutSubviews()
      layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 12).cgPath
    }
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
