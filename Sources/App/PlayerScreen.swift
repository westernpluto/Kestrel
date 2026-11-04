// The watch screen, laid out like Twitch's app: video on top with controls that fade in on a
// tap (settings behind a gear: quality, low latency, video stats), chat below in portrait and
// beside the video in landscape.
//
// One layout for both orientations: the video, info bar and chat keep their identity and only
// move, so rotating, opening chat or bringing up the keyboard animates instead of rebuilding
// the player and chat. Safe areas and the keyboard are handled here (not by SwiftUI's keyboard
// avoidance, which left the message box under the keyboard in a full-screen cover).

import AVKit
import Combine
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
  /// Off for multi-view tiles (one picture can't speak for several).
  var pictureInPicture = true

  private var player: AVPlayer { role == .main ? model.player : model.rewindPlayer }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.backgroundColor = .black
    // A picture only: touches go to the controls and gestures over it.
    view.isUserInteractionEnabled = false
    view.playerLayer.player = player
    view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    context.coordinator.view = view
    context.coordinator.player = player
    if pictureInPicture, AVPictureInPictureController.isPictureInPictureSupported(),
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
  /// The keyboard's height the last time it was up (the emote picker takes its place).
  private(set) static var lastHeight: CGFloat?
  private var tokens: [NSObjectProtocol] = []

  /// The keyboard's own motion: UIKit runs it on a stiff spring squeezed into the notification's
  /// duration, which comes out as a sharp ease-out. (The same spring at its natural pace, used
  /// before, took over a second to settle: the message box trailed far behind the keyboard.)
  static func animation(duration: Double) -> Animation {
    .timingCurve(0.16, 1, 0.3, 1, duration: max(0.25, duration) * 1.6)
  }

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
    let value = hiding ? 0 : min(bounds.height * 0.62, max(0, bounds.maxY - frame.minY))
    if value > 40 { Self.lastHeight = value }
    let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    guard abs(value - overlap) > 0.5 else { return }
    // "Did" notifications only correct a missed "will"; a zero duration means the keyboard itself
    // isn't animating (moving with it is the point).
    if note.name == UIResponder.keyboardDidChangeFrameNotification || duration <= 0.01 {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { overlap = value }
    } else {
      withAnimation(Self.animation(duration: duration)) { overlap = value }
    }
  }
}

// MARK: - Layout

/// The window's size and insets from the last time the app was in front (see PlayerScreen).
final class LayoutHold {
  private var size: CGSize?
  private var insets = EdgeInsets()
  private var logged: String?

  func take(_ measured: (size: CGSize, insets: EdgeInsets), active: Bool) -> (size: CGSize, insets: EdgeInsets) {
    if active || size == nil {
      size = measured.size
      insets = measured.insets
      return measured
    }
    if let size, size != measured.size {
      let note = "\(Int(measured.size.width))x\(Int(measured.size.height))"
      if note != logged {
        logged = note
        ActivityLog.shared.add("Player: window \(note) while away (kept \(Int(size.width))x\(Int(size.height)))")
      }
    }
    return (size ?? measured.size, insets)
  }
}

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
  /// Where the picture goes inside `video` (unless zoomed to fill): iPhone Duo's outer screen keeps
  /// it clear of the camera, and phone landscape keeps it above the keyboard while typing.
  var pictureInsets = EdgeInsets()
  /// Extra room the top bar, or the controls' bottom row, keeps from a camera beside it (only ever
  /// when that still leaves it plenty of width; otherwise it goes over the picture instead).
  var topBarExtra = EdgeInsets()
  var bottomRowExtra = EdgeInsets()
  /// Laid out around iPhone Duo's fold (see `aroundFold`): chat's width is the fold's to set.
  var foldAligned = false

  static let infoHeight: CGFloat = 62
  /// iPhone Duo's outer screen: iOS keeps a status strip this wide (84 pt) clear along its right
  /// edge (held upright), but only the camera (at its top) and the clock and signal under it are
  /// in it. Wider than any iPhone's landscape inset for the Dynamic Island (59–62 pt).
  static let cornerStripWidth: CGFloat = 70
  /// The camera's corner, from the corner: along the strip's edge × away from it (pill plus air).
  static let cornerCamera = CGSize(width: 140, height: 74)
  /// Held upright: how far down the strip its clock and signal reach (below that it's empty).
  static let stripContentBottom: CGFloat = 250
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
    // Without it, the message box sits just above the home indicator (the indicator's whole
    // inset under it left a band of nothing under chat).
    let bottomPad = keyboard > 0 ? keyboard + 14 : max(0, insets.bottom - 20)
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
      // A large window (iPhone Duo's inner display) hides the status bar while the player is up,
      // and the video takes its band at the top (its controls stay below it).
      let videoTop: CGFloat = large ? windowTop : 0
      var videoHeight = fullHeight
      var showInfo = true
      if keyboard > 0 {
        // Typing: the message box and some chat have to fit above the keyboard. The info bar goes
        // first, then the video shrinks (iPhone Duo's inner display has a tall keyboard, and on
        // its own it left no room at all).
        let room = windowBottom - bottomPad - videoTop
        let minChat: CGFloat = large ? 200 : 150
        if room - fullHeight - Self.infoHeight < minChat {
          showInfo = false
          videoHeight = min(fullHeight, max(min(110, fullHeight), room - minChat)).rounded()
        }
      }
      let videoWidth = videoHeight < fullHeight ? (videoHeight * 16 / 9).rounded() : videoSpan
      // Shrunk for the keyboard: within the safe area when it fits (clear of iPhone Duo's camera).
      let videoX =
        videoWidth < videoSpan && videoWidth <= width
        ? ((width - videoWidth) / 2).rounded() : videoLeft + ((videoSpan - videoWidth) / 2).rounded()
      video = CGRect(x: videoX, y: videoTop, width: videoWidth, height: videoHeight)
      controls = EdgeInsets(
        top: max(0, -videoTop) + 2, leading: max(0, -video.minX) + 6, bottom: 2, trailing: max(0, video.maxX - width) + 6)
      // iPhone Duo's outer screen: below the status strip's clock and signal, the strip is empty,
      // so the info bar and chat run the window's whole width (iOS keeps all of it clear).
      let sideStrip = !large && max(insets.leading, insets.trailing) > Self.cornerStripWidth
      let fullWidthFrom = Self.stripContentBottom - insets.top
      let rowLeft: (CGFloat) -> CGFloat = { y in sideStrip && y >= fullWidthFrom ? windowLeft : 0 }
      let rowWidth: (CGFloat) -> CGFloat = { y in sideStrip && y >= fullWidthFrom ? windowRight - windowLeft : width }
      let videoBottom = videoTop + videoHeight
      info = showInfo ? CGRect(x: rowLeft(videoBottom), y: videoBottom, width: rowWidth(videoBottom), height: Self.infoHeight) : nil
      let top = videoBottom + (showInfo ? Self.infoHeight : 0)
      panel = CGRect(x: rowLeft(top), y: top, width: rowWidth(top), height: max(0, windowBottom - top))
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
    // (iPhone Duo's status strip) is kept clear in full unless its camera's corner is known.
    let sideInset = max(insets.leading, insets.trailing)
    let clearance = sideInset > 62 ? sideInset : min(Self.cameraClearance, sideInset)
    // iPhone Duo's outer screen: its camera (top right, held upright) ends up in a corner along
    // the top or bottom edge, not down a side: the top left with the phone's top turned left, the
    // bottom right with it turned right. iOS keeps a whole side clear for it; only that corner needs
    // to be.
    let cornerCameraTop: Bool? =
      sideInset > Self.cornerStripWidth
      ? (cameraOnLeft ?? (insets.leading > insets.trailing + 1 ? true : insets.trailing > insets.leading + 1 ? false : nil))
      : nil
    // Typing: the keyboard's top edge (the picture moves up above it, so the stream stays in view).
    let keyboardTop: CGFloat? = keyboard > 0 ? top + height - keyboard : nil
    if let cameraTop = cornerCameraTop {
      chatOnLeft = !cameraTop
      // How much of the video's sides chat lies over (the controls keep clear of it).
      var covered: (leading: CGFloat, trailing: CGFloat) = (0, 0)
      if chatOpen && !chatOverVideo {
        // Chat beside the video, on the side away from the camera's corner.
        if chatOnLeft {
          panel = CGRect(x: left, y: top, width: chat, height: height)
          panelPadding = EdgeInsets(top: insets.top + 6, leading: 12, bottom: bottomPad, trailing: 0)
          video = CGRect(x: panel.maxX, y: top, width: right - panel.maxX, height: height)
        } else {
          panel = CGRect(x: right - chat, y: top, width: chat, height: height)
          panelPadding = EdgeInsets(top: insets.top + 6, leading: 0, bottom: bottomPad, trailing: 12)
          video = CGRect(x: left, y: top, width: panel.minX - left, height: height)
        }
        panelVisible = true
      } else {
        video = CGRect(x: left, y: top, width: screenWidth, height: height)
        if chatOpen {
          chatOverlay = true
          panel = chatOnLeft
            ? CGRect(x: left, y: top, width: chat, height: height) : CGRect(x: right - chat, y: top, width: chat, height: height)
          covered = chatOnLeft ? (chat, 0) : (0, chat)
          panelVisible = true
        } else {
          panel = chatOnLeft
            ? CGRect(x: left - chat - 1, y: top, width: chat, height: height) : CGRect(x: right + 1, y: top, width: chat, height: height)
          panelVisible = false
        }
        panelPadding = EdgeInsets(
          top: insets.top + 6, leading: chatOnLeft ? 12 : 0, bottom: bottomPad, trailing: chatOnLeft ? 0 : 12)
      }
      // The picture goes in the part of the video the camera's corner can't reach, and the bars
      // into the room left beside it where they fit (none of the picture covered by either).
      let camera =
        cameraTop
        ? CGRect(x: left, y: top, width: Self.cornerCamera.width, height: Self.cornerCamera.height)
        : CGRect(
          x: right - Self.cornerCamera.width, y: top + height - Self.cornerCamera.height, width: Self.cornerCamera.width,
          height: Self.cornerCamera.height)
      let placed = Self.place(in: video, camera: camera, keyboardTop: keyboardTop, covered: covered, safeBottom: safe.height)
      controls = placed.controls
      pictureInsets = placed.picture
      topBarExtra = placed.topBar
      bottomRowExtra = placed.bottomRow
      return
    }
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
    if let keyboardTop, panelVisible {
      // Typing in chat: the keyboard would cover most of the picture, so the picture shrinks into
      // the room above it (clear of the chat lying over the video, and of the Dynamic Island).
      let island = cameraOnLeft.map { onLeft in
        CGRect(
          x: onLeft ? left : right - Self.cameraClearance, y: top + ((height - Self.islandLength) / 2).rounded(),
          width: Self.cameraClearance, height: Self.islandLength)
      }
      let covered: (leading: CGFloat, trailing: CGFloat) = chatOverlay ? (chatOnLeft ? (chat, 0) : (0, chat)) : (0, 0)
      let placed = Self.place(in: video, camera: island, keyboardTop: keyboardTop, covered: covered, safeBottom: safe.height)
      controls = placed.controls
      pictureInsets = placed.picture
      topBarExtra = placed.topBar
      bottomRowExtra = placed.bottomRow
    }
  }

  // MARK: Picture and bars around a camera

  /// Where the picture and the controls' two bars go in an area (all as insets from its edges).
  struct Placement: Equatable {
    var picture = EdgeInsets()
    var controls = EdgeInsets()
    /// Beyond `controls`: the top bar's, or the bottom row's, own room (kept from the camera).
    var topBar = EdgeInsets()
    var bottomRow = EdgeInsets()
  }

  /// The controls' bars: height, the gap to the screen's edge, the gap to the picture, and the
  /// room from the picture's sides.
  private static let bar: CGFloat = 40
  private static let barEdge: CGFloat = 8
  private static let barGap: CGFloat = 2
  private static let barSide: CGFloat = 12
  /// The narrowest a bar may be beside the camera; any narrower and it goes over the picture.
  private static let minTopBar: CGFloat = 360
  private static let minBottomRow: CGFloat = 400
  /// The Dynamic Island's length in landscape, plus air.
  static let islandLength: CGFloat = 140

  /// Fits a 16:9 picture into `area` (safe-area coordinates) as big as it goes without the camera
  /// covering any of it, against the side away from the camera; then puts the top bar and the
  /// bottom row in the room left above and below it when they fit there clear of the camera (so
  /// they cover none of the picture), or over the picture's edges when they don't.
  /// - Parameters:
  ///   - camera: the camera's corner (iPhone Duo's outer screen) or the Dynamic Island, if known.
  ///   - keyboardTop: typing: where the keyboard starts; the picture and bars stay above it.
  ///   - covered: how far chat lies over the area's sides (the bars keep clear; while typing, the
  ///     picture too).
  ///   - safeBottom: the safe area's bottom (the bottom row keeps above the home indicator).
  static func place(
    in area: CGRect, camera: CGRect?, keyboardTop: CGFloat?, covered: (leading: CGFloat, trailing: CGFloat),
    safeBottom: CGFloat
  ) -> Placement {
    let bottom = keyboardTop.map { min(area.maxY, $0 - 6) } ?? area.maxY
    let typing = bottom < area.maxY
    let open = CGRect(
      x: area.minX + covered.leading, y: area.minY, width: max(0, area.width - covered.leading - covered.trailing),
      height: max(0, bottom - area.minY))
    // Chat lying over the video covers the picture's side by choice, but not while typing (the
    // picture is small then: it moves into the open part).
    let room = typing ? open : CGRect(x: area.minX, y: area.minY, width: area.width, height: open.height)
    let cam = camera.flatMap { $0.intersects(room) ? $0 : nil }
    let cameraTop = cam.map { $0.midY < room.midY } ?? false
    let cameraLeft = cam.map { $0.midX < room.midX } ?? false
    var width = min(room.width, room.height * 16 / 9)
    if let cam {
      // As big as it goes, in the corner away from the camera: if the camera still reaches it,
      // smaller, beside the camera or beyond it (whichever leaves the bigger picture).
      let far = CGRect(
        x: cameraLeft ? room.maxX - width : room.minX, y: cameraTop ? room.maxY - width * 9 / 16 : room.minY,
        width: width, height: width * 9 / 16)
      if far.intersects(cam) {
        let beyond = cameraTop ? room.maxY - cam.maxY : cam.minY - room.minY
        let beside = cameraLeft ? room.maxX - cam.maxX : cam.minX - room.minX
        width = max(min(room.width, beyond * 16 / 9), min(beside, room.height * 16 / 9))
      }
    }
    width = max(0, width.rounded(.down))
    let height = (width * 9 / 16).rounded(.down)
    let topLimit = max(room.minY, 0)
    let rowLimit = typing ? bottom : min(bottom, safeBottom)
    // Room a bar needs above or below the picture.
    let above = (topLimit - room.minY) + barEdge + bar + barGap
    let below = barGap + bar + barEdge + (room.maxY - rowLimit)
    let free = room.height - height
    var y: CGFloat
    if free >= above + below {
      // Both bars beside the picture: the picture as far from the camera as that allows.
      y = cam == nil ? room.minY + above + (free - above - below) / 2 : cameraTop ? room.maxY - below - height : room.minY + above
    } else {
      y = cam == nil ? room.minY + free / 2 : cameraTop ? room.maxY - height : room.minY
    }
    y = y.rounded()
    var x = (room.minX + (room.width - width) / 2).rounded()
    if let cam, CGRect(x: x, y: y, width: width, height: height).intersects(cam) {
      x = cameraLeft ? room.maxX - width : room.minX
    }
    let picture = CGRect(x: x, y: y, width: width, height: height)
    // The bars span the picture (clear of chat over the video).
    let low = max(picture.minX, open.minX) + barSide
    let high = max(low, min(picture.maxX, open.maxX) - barSide)
    /// A bar beside the picture, kept clear of the camera; nil when that leaves it too narrow.
    func beside(_ y: CGFloat, minWidth: CGFloat) -> CGRect? {
      let span = CGRect(x: low, y: y, width: high - low, height: bar)
      guard let cam, span.intersects(cam) else { return span }
      let start = cameraLeft ? max(span.minX, cam.maxX + 6) : span.minX
      let end = cameraLeft ? span.maxX : min(span.maxX, cam.minX - 6)
      return end - start >= minWidth ? CGRect(x: start, y: y, width: end - start, height: bar) : nil
    }
    var topBar = CGRect(x: low, y: max(picture.minY, topLimit) + barEdge, width: high - low, height: bar)
    if picture.minY - (topLimit + barEdge) >= bar + barGap, let outside = beside(picture.minY - barGap - bar, minWidth: minTopBar) {
      topBar = outside
    }
    var row = CGRect(x: low, y: min(picture.maxY, rowLimit) - barEdge - bar, width: high - low, height: bar)
    if rowLimit - barEdge - picture.maxY >= bar + barGap, let outside = beside(picture.maxY + barGap, minWidth: minBottomRow) {
      row = outside
    }
    return Placement(
      picture: EdgeInsets(
        top: picture.minY - area.minY, leading: picture.minX - area.minX, bottom: area.maxY - picture.maxY,
        trailing: area.maxX - picture.maxX),
      controls: EdgeInsets(top: topBar.minY - area.minY, leading: low - area.minX, bottom: area.maxY - row.maxY, trailing: area.maxX - high),
      topBar: EdgeInsets(top: 0, leading: topBar.minX - low, bottom: 0, trailing: high - topBar.maxX),
      bottomRow: EdgeInsets(top: 0, leading: row.minX - low, bottom: 0, trailing: high - row.maxX))
  }

  /// The offline banner's strip (see `folded`).
  static let foldedStrip: CGFloat = 54

  /// The channel is offline: chat only. The video's place folds into a strip (the offline banner)
  /// and what's under it moves up; once the stream starts it opens back up, animated, so the video
  /// slides into view beside chat. Phone landscape: chat across the whole screen under the strip.
  func folded(safe: CGSize, insets: EdgeInsets) -> PlayerLayout {
    var out = self
    let strip = Self.foldedStrip
    out.chatOverlay = false
    out.panelVisible = true
    out.pictureInsets = EdgeInsets()
    out.topBarExtra = EdgeInsets()
    out.bottomRowExtra = EdgeInsets()
    if landscape {
      // Sideways: chat across the whole window under the strip (a large window's info bar between
      // them), nothing beside it, until the stream starts.
      let left = -insets.leading
      let width = safe.width + insets.leading + insets.trailing
      let top = -insets.top
      out.video = CGRect(x: left, y: top, width: width, height: insets.top + strip)
      var chatTop = out.video.maxY
      out.details = nil
      if large, info != nil {
        out.info = CGRect(x: 0, y: chatTop, width: safe.width, height: Self.infoHeight)
        chatTop += Self.infoHeight
      } else {
        out.info = nil
      }
      out.foldAligned = false
      out.panel = CGRect(x: left, y: chatTop, width: width, height: safe.height + insets.bottom - chatTop)
      out.panelPadding = EdgeInsets(
        top: 2, leading: insets.leading + 8, bottom: panelPadding.bottom, trailing: insets.trailing + 8)
      out.controls = EdgeInsets(top: insets.top, leading: insets.leading + 6, bottom: 0, trailing: insets.trailing + 6)
      return out
    }
    // Portrait, or a large window: the strip at the top of the video's place.
    // (Under a hidden status bar's band, the strip grows by it.)
    let band = strip + max(0, -video.minY)
    let lost = video.height - band
    out.video = CGRect(x: video.minX, y: video.minY, width: video.width, height: band)
    out.info = info?.offsetBy(dx: 0, dy: -lost)
    out.details = details.map { CGRect(x: $0.minX, y: $0.minY - lost, width: $0.width, height: $0.height + lost) }
    if !landscape {
      // Chat is under the video here (beside it in a large window held sideways).
      out.panel = CGRect(x: panel.minX, y: panel.minY - lost, width: panel.width, height: panel.height + lost)
    }
    out.controls = EdgeInsets(top: max(0, -video.minY), leading: controls.leading, bottom: 0, trailing: controls.trailing)
    return out
  }

  func foldedIf(_ fold: Bool, safe: CGSize, insets: EdgeInsets) -> PlayerLayout {
    fold ? folded(safe: safe, insets: insets) : self
  }

  /// iPhone Duo partly folded (the fold, `crease`, in safe-area coordinates): nothing sits across
  /// it. Folded like a book, the video (with its info bar and details) takes one side and chat the
  /// other; folded like a laptop, the video takes the top half and the info bar and chat the
  /// bottom. Only with chat beside the video in a large window, not typing: full screen, the
  /// keyboard and the mini player keep their layouts (small adjustments, not rearranging, as
  /// Apple's guidelines for iPhone Duo put it).
  func aroundFold(_ crease: CGRect?, safe: CGSize, insets: EdgeInsets, keyboard: CGFloat) -> PlayerLayout {
    guard let crease, large, !fullScreen, panelVisible, keyboard == 0, crease.width > 0, crease.height > 0 else { return self }
    var out = self
    let windowLeft = -insets.leading
    let windowRight = safe.width + insets.trailing
    let windowTop = -insets.top
    let windowBottom = safe.height + insets.bottom
    out.foldAligned = true
    out.chatOverlay = false
    if crease.height > crease.width {
      // Like a book: a side each. Chat goes on the side away from a status strip, as in landscape.
      guard crease.minX > windowLeft + 200, crease.maxX < windowRight - 200 else { return self }
      let chatOnLeft = insets.trailing > insets.leading + 1
      let columnLeft = chatOnLeft ? crease.maxX : windowLeft
      let columnRight = chatOnLeft ? windowRight : crease.minX
      let column = columnRight - columnLeft
      let height = windowBottom - windowTop
      let videoHeight = min((column * 9 / 16).rounded(), max(0, height - Self.infoHeight))
      out.video = CGRect(x: columnLeft, y: windowTop, width: column, height: videoHeight)
      let textLeft = max(columnLeft, 0)
      let textWidth = min(columnRight, safe.width) - textLeft
      out.info = CGRect(x: textLeft, y: out.video.maxY, width: textWidth, height: Self.infoHeight)
      let detailsTop = out.video.maxY + Self.infoHeight
      out.details = windowBottom - detailsTop >= 80 ? CGRect(x: textLeft, y: detailsTop, width: textWidth, height: windowBottom - detailsTop) : nil
      out.panel = chatOnLeft
        ? CGRect(x: windowLeft, y: windowTop, width: crease.minX - windowLeft, height: height)
        : CGRect(x: crease.maxX, y: windowTop, width: windowRight - crease.maxX, height: height)
      out.panelPadding = EdgeInsets(
        top: insets.top + 6, leading: chatOnLeft ? insets.leading : 0, bottom: max(0, insets.bottom - 20), trailing: chatOnLeft ? 0 : insets.trailing)
      out.chatOnLeft = chatOnLeft
      out.landscape = true
      out.controls = EdgeInsets(
        top: max(0, -out.video.minY) + 2, leading: max(0, -columnLeft) + 6, bottom: 2,
        trailing: max(0, columnRight - safe.width) + 6)
    } else {
      // Like a laptop: the video above the fold, the info bar and chat below it.
      guard crease.minY > windowTop + 160, crease.maxY < windowBottom - 200 else { return self }
      let top = crease.minY - windowTop
      let span = windowRight - windowLeft
      let width = min(span, (top * 16 / 9).rounded())
      let height = min(top, (width * 9 / 16).rounded())
      out.video = CGRect(
        x: windowLeft + ((span - width) / 2).rounded(), y: windowTop + ((top - height) / 2).rounded(), width: width, height: height)
      out.info = CGRect(x: 0, y: crease.maxY, width: safe.width, height: Self.infoHeight)
      out.details = nil
      let chatTop = crease.maxY + Self.infoHeight
      out.panel = CGRect(x: 0, y: chatTop, width: safe.width, height: max(0, windowBottom - chatTop))
      out.panelPadding = EdgeInsets(top: 0, leading: 0, bottom: max(0, insets.bottom - 20), trailing: 0)
      out.landscape = false
      out.controls = EdgeInsets(
        top: max(0, -out.video.minY) + 2, leading: max(0, -out.video.minX) + 6, bottom: 2,
        trailing: max(0, out.video.maxX - safe.width) + 6)
    }
    return out
  }

  /// The same layout moved by (dx, dy) (into another safe area's coordinates).
  func shifted(dx: CGFloat, dy: CGFloat) -> PlayerLayout {
    guard dx != 0 || dy != 0 else { return self }
    var moved = self
    moved.video = video.offsetBy(dx: dx, dy: dy)
    moved.info = info?.offsetBy(dx: dx, dy: dy)
    moved.panel = panel.offsetBy(dx: dx, dy: dy)
    moved.details = details?.offsetBy(dx: dx, dy: dy)
    return moved
  }

  /// Room to leave under scrolling content for the mini player.
  static var miniInset: CGFloat {
    let width = min(AppWindow.bounds.width, 520) * 0.5
    return (width * 9 / 16).rounded() + 20
  }
}

/// The mini player's corner (the multi-view dock's too): bottom trailing, above a bottom tab bar,
/// beside a side rail.
enum MiniCorner {
  private static var widest: [String: UIEdgeInsets] = [:]

  /// Keeps the widest safe area seen for this window shape and turn: the one with the status bar
  /// showing. The open player hides the bar (on iPhone Duo's inner screen, a strip down the side),
  /// so while the player shrank the safe area was still the wider one: the mini player aimed into
  /// the strip, over the tab rail, and jumped back once the bar returned.
  static func note(_ insets: UIEdgeInsets, size: CGSize) {
    let key = key(size)
    let seen = widest[key] ?? insets
    widest[key] = UIEdgeInsets(
      top: max(seen.top, insets.top), left: max(seen.left, insets.left),
      bottom: max(seen.bottom, insets.bottom), right: max(seen.right, insets.right))
  }

  /// The mini player's frame in window coordinates.
  static func frame(window: CGSize, insets: UIEdgeInsets, tabBar: CGFloat, rail: CGRect) -> CGRect {
    note(insets, size: window)
    let steady = widest[key(window)] ?? insets
    let width = (min(window.width - steady.left - steady.right, 520) * 0.5).rounded()
    let height = (width * 9 / 16).rounded()
    // No bottom bar: just clear of the home indicator.
    let covered = tabBar > 0 ? max(tabBar, 49 + steady.bottom) : steady.bottom
    let maxY = window.height - covered - 10
    var maxX = window.width - steady.right - 10
    if !rail.isNull, rail.midX > window.width / 2, rail.maxY > maxY - height, rail.minY < maxY {
      maxX = min(maxX, rail.minX - 10)
    }
    return CGRect(x: maxX - width, y: maxY - height, width: width, height: height)
  }

  private static func key(_ size: CGSize) -> String {
    let turn = AppWindow.current?.windowScene?.effectiveGeometry.interfaceOrientation.rawValue ?? 0
    return "\(Int(size.width))x\(Int(size.height))/\(turn)"
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
  /// Raids by the channel being watched (live only).
  let raids: RaidWatcher

  init(target: PlaybackTarget) {
    model = PlayerModel(target: target)
    raids = RaidWatcher()
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
  /// This opening of the player (see `AppModel.playerKey`).
  let key: String
  /// The player and chat are owned here but not watched: this screen's layout doesn't depend on
  /// their state, so it isn't rebuilt every time the player ticks (the views that show player
  /// state watch it themselves). Rebuilding all of it twice a second cost animations frames.
  @StateObject private var session: PlayerSession
  private var model: PlayerModel { session.model }
  private var chat: ChatController { session.chat }
  private var raids: RaidWatcher { session.raids }
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
  /// The channel is offline: just chat, the video folded into a strip until they're live again.
  @State private var folded: Bool

  static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)
  @Environment(\.scenePhase) private var scenePhase
  @State private var hold = LayoutHold()

  init(target: PlaybackTarget, key: String) {
    self.target = target
    self.key = key
    _session = StateObject(wrappedValue: PlayerSession(target: target))
    var offline = false
    if case .live(let channel) = target { offline = PlayerModel.openedOffline.contains(channel.login.lowercased()) }
    _folded = State(initialValue: offline)
  }

  var body: some View {
    GeometryReader { geometry in
      // Laid out by the window as it was while the app was in front until it's in front again:
      // coming back from Picture in Picture, iOS hands the app passing sizes, and the video
      // jumped to full screen and bounced back beside chat.
      let measured = (size: geometry.size, insets: Self.insets(geometry))
      let held = hold.take(measured, active: scenePhase == .active)
      let insets = held.insets
      let landscape = held.size.width > held.size.height
      let screenWidth = held.size.width + insets.leading + insets.trailing
      let screenHeight = held.size.height + insets.top + insets.bottom
      let large = OrientationLock.isLarge(CGSize(width: screenWidth, height: screenHeight))
      let chatOpen = folded || (large ? !largeFullScreen : landscape && landscapeChat)
      // A large window held sideways hides the status bar while the player is open, and iPhone
      // Duo's status strip goes with it. Shrinking the player brings them back: laid out by the
      // insets of that moment, chat jumped to the other side of the strip mid-shrink. So the
      // layout keeps to the window as it is with the player open (no strip), shifted to where
      // the safe area is right now.
      let layoutInsets = large && landscape ? EdgeInsets(top: 0, leading: 0, bottom: insets.bottom, trailing: 0) : insets
      let layoutSafe = CGSize(
        width: screenWidth - layoutInsets.leading - layoutInsets.trailing,
        height: screenHeight - layoutInsets.top - layoutInsets.bottom)
      let layout = PlayerLayout(
        safe: layoutSafe, insets: layoutInsets, keyboard: keyboard.overlap, chatOpen: chatOpen,
        chatWidth: resizedWidth ?? screenWidth * chatShare,
        cameraOnLeft: landscape && !large ? (InterfaceOrientationObserver.cameraOnLeftNow ?? orientation.cameraOnLeft) : nil,
        large: large, theater: theater && !folded, chatOverVideo: chatOverVideo && !folded
      )
      .aroundFold(
        crease(geometry, large: large)?.offsetBy(dx: insets.leading - layoutInsets.leading, dy: insets.top - layoutInsets.top),
        safe: layoutSafe, insets: layoutInsets, keyboard: keyboard.overlap)
      .foldedIf(folded, safe: layoutSafe, insets: layoutInsets)
      .shifted(dx: layoutInsets.leading - insets.leading, dy: layoutInsets.top - insets.top)
      // The layout choice offered on the video, if any.
      let layoutToggle: LayoutToggle? =
        landscape && chatOpen
        ? (large
          ? LayoutToggle(title: "Theater mode", systemImage: "theatermasks", onImage: "theatermasks.fill", isOn: theater)
          : LayoutToggle(
            title: "Chat over video", systemImage: "rectangle.righthalf.inset.filled",
            onImage: "rectangle.righthalf.inset.filled", isOn: chatOverVideo, chatOverVideo: true))
        : nil
      // (Phone landscape can't shrink; a large window's full screen can, under the finger.)
      let progress = layout.fullScreen && !layout.large ? 0 : (dragProgress ?? (app.playerMinimized ? 1 : 0))
      // In window coordinates, moved into the safe area's.
      let mini = MiniCorner.frame(
        window: CGSize(width: screenWidth, height: screenHeight),
        insets: AppWindow.current?.safeAreaInsets
          ?? UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing),
        tabBar: app.tabBarHeight, rail: app.tabRail
      ).offsetBy(dx: miniOffset.width - insets.leading, dy: miniOffset.height - insets.top)
      let video = lerp(layout.video, mini, progress)
      let pullDistance = max(240, mini.minY - layout.video.minY)
      let expandedOpacity = Double(max(0, 1 - progress * 2.2))

      ZStack(alignment: .topLeading) {
        // Backdrop: fades away as the player shrinks, revealing the app.
        Color.black
          .frame(width: screenWidth, height: screenHeight)
          .contentShape(Rectangle())
          // The black around the video (theater mode's bars) pulls the player down too.
          .gesture(
            DragGesture(minimumDistance: 14, coordinateSpace: .global)
              .onChanged { value in
                let dx = value.translation.width, dy = value.translation.height
                guard dragProgress != nil || (dy > 8 && dy > abs(dx) * 1.2) else { return }
                if dragProgress == nil { dismissKeyboard() }
                dragProgress = min(1, max(0, dy / pullDistance))
              }
              .onEnded { value in
                guard dragProgress != nil else { return }
                let finish = (dragProgress ?? 0) > 0.5 || value.predictedEndTranslation.height / pullDistance > 0.55
                if finish { Haptics.tap() }
                withAnimation(Self.spring) {
                  app.playerMinimized = finish
                  dragProgress = nil
                }
              }
          )
          .offset(x: -insets.leading, y: -insets.top)
          .opacity(Double(1 - progress))
          .allowsHitTesting(progress < 0.01 || dragProgress != nil)

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

        sidePanel(layout, keyboardUp: keyboard.overlap > 0, safeBottom: layoutInsets.bottom)
          .frame(width: layout.panel.width, height: layout.panel.height)
          .background(layout.chatOverlay ? Color.black.opacity(0.55) : landscape ? Color(white: 0.07) : Color.black)
          .overlay(alignment: .top) {
            if !landscape { Divider().overlay(Color.white.opacity(0.08)) }
          }
          // Chat beside the video: swiped toward its edge, it goes and the video takes the window.
          .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .global).onEnded { value in
              guard large, layout.landscape, layout.panelVisible, keyboard.overlap == 0 else { return }
              let dx = value.translation.width, dy = value.translation.height
              guard abs(dx) > abs(dy) * 1.5 else { return }
              let towardEdge = layout.chatOnLeft ? dx < -80 : dx > 80
              if towardEdge {
                Haptics.tap()
                withAnimation(Self.spring) { largeFullScreen = true }
              }
            }
          )
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
          model: model, landscape: layout.fullScreen, chatOpen: chatOpen, controlInsets: progress == 0 ? layout.controls : EdgeInsets(),
          pictureInsets: progress == 0 ? layout.pictureInsets : EdgeInsets(),
          topBarExtra: layout.topBarExtra, bottomRowExtra: layout.bottomRowExtra,
          chromeVisible: progress == 0, minimized: app.playerMinimized, chatOnLeft: layout.chatOnLeft,
          sideChat: layout.large && layout.landscape,
          largeWindow: layout.large,
          viewersShownElsewhere: layout.details != nil,
          showsStreamer: layout.large && layout.landscape && !layout.fullScreen && layout.info == nil,
          chat: chat,
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
          keyboardUp: keyboard.overlap > 0,
          onPull: { dy in
            if dragProgress == nil { dismissKeyboard() }
            dragProgress = min(1, max(0, dy / pullDistance))
          },
          onPullEnd: { dy, predicted in
            let finish = (dragProgress ?? 0) > 0.5 || predicted / pullDistance > 0.55
            if finish { Haptics.tap() }
            withAnimation(Self.spring) {
              app.playerMinimized = finish
              dragProgress = nil
            }
          }
        )
        .frame(width: video.width, height: video.height)
        .clipShape(RoundedRectangle(cornerRadius: 12 * progress, style: .continuous))
        .offset(x: video.minX, y: video.minY)
        // Folded away while offline (it still shows as the mini player).
        .opacity(folded ? Double(progress) : 1)
        .allowsHitTesting(!folded || progress > 0)

        if folded {
          OfflineBanner(model: model, minimize: minimize, close: close)
            .padding(.leading, layout.controls.leading)
            .padding(.trailing, layout.controls.trailing)
            .padding(.top, layout.controls.top)
            .frame(width: layout.video.width, height: layout.video.height)
            .offset(x: layout.video.minX, y: layout.video.minY + progress * 140)
            .opacity(expandedOpacity)
            .allowsHitTesting(progress == 0)
            .transition(.opacity)
        }

        // A raid by this channel: counting down, or offered (over the video, or the offline strip).
        RaidBanner(raids: raids)
          .padding(.horizontal, 12)
          .padding(.bottom, folded ? 0 : 52)
          .frame(width: layout.video.width, height: layout.video.height, alignment: folded ? .center : .bottom)
          .offset(x: layout.video.minX, y: layout.video.minY)
          .opacity(expandedOpacity)
          .allowsHitTesting(progress == 0)
          .zIndex(3)

        if layout.landscape && layout.panelVisible && progress == 0 && !folded && !layout.foldAligned {
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
      // on iPhone Duo's inner display it runs down one side of the video. It comes back once the
      // player is actually shrinking (not while a finger is still deciding): bringing it back
      // re-lays out the window, which cut the keyboard's slide short when a swipe put it away.
      .statusBarHidden((layout.fullScreen || layout.large) && !app.playerMinimized)
      .persistentSystemOverlays(layout.fullScreen && !app.playerMinimized ? .hidden : .automatic)
    }
    .ignoresSafeArea(.keyboard)
    .preferredColorScheme(.dark)
    .animation(Self.spring, value: landscapeChat)
    .background(ChatFollower(model: model, chat: chat))
    .task {
      orientation.start()
      // (Opened straight into the mini player when following a raid from it.)
      OrientationLock.playerVisible(!app.playerMinimized)
      if app.playerMinimized { model.setMaxHeight(480) }
      // A screen that's already been replaced by another stream must not start.
      guard app.playerKey == key else { return }
      let id = key
      let player = model, chatRoom = chat, raidWatcher = raids
      app.registerPlayer(id) {
        player.stop()
        chatRoom.stop()
        raidWatcher.stop()
      }
      chat.start()
      if case .live(let channel) = target {
        raids.follow = { next in
          let app = AppModel.shared
          guard app.playerKey == id else { return }
          // In the mini player, the raided stream carries on in the mini player.
          let minimized = app.playerMinimized
          app.playing = .live(next)
          if minimized { app.playerMinimized = true }
        }
        raids.start(channel: channel)
      }
      await model.start()
    }
    // Offline: fold the video away to chat; live again (and Watch tapped): it slides back open.
    .onReceive(model.$phase.combineLatest(model.$expectsOffline).removeDuplicates { $0 == $1 }) { value in
      let (phase, expects) = value
      let fold = model.isLive && (phase == .offline || (phase == .loading && expects))
      guard fold != folded else { return }
      withAnimation(.spring(response: 0.55, dampingFraction: 0.88)) { folded = fold }
    }
    .onChange(of: app.playerMinimized) { minimized in
      // The app is portrait; only the full-screen player turns.
      OrientationLock.playerVisible(!minimized)
      // The mini player is small: on Auto, nothing sharper than it shows is fetched or decoded
      // (less data and battery); full size again on the way back.
      model.setMaxHeight(minimized ? 480 : nil)
      if minimized {
        // (Full screen stays as it was: back from the mini player, chat stays away if it was.)
        dismissKeyboard()
      }
    }
    .onDisappear {
      app.unregisterPlayer(key)
      model.stop()
      chat.stop()
      raids.stop()
      // (Multi-view taking over keeps the phone free to turn.)
      if app.multiview == nil || app.multiviewMinimized { OrientationLock.playerVisible(false) }
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
    raids.stop()
    OrientationLock.playerVisible(false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      // Let other apps' audio carry on (fails harmlessly if something else is still playing).
      // (Off the main thread: it waits for the sound to stop, and froze taps for a second or two.)
      if !app.playsMedia {
        DispatchQueue.global(qos: .userInitiated).async {
          try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
      }
    }
    withAnimation(.easeIn(duration: 0.2)) { closing = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
      if app.playerKey == key { app.playing = nil }
    }
  }

  private func dismissKeyboard() {
    Keyboard.dismiss()
  }

  /// iPhone Duo partly folded: where the fold runs through the player's area (in its safe area's
  /// coordinates), while the player is open in a large window.
  private func crease(_ geometry: GeometryProxy, large: Bool) -> CGRect? {
    guard large, !app.playerMinimized else { return nil }
    if #available(iOS 27.1, *) {
      return geometry.reservedRegions(kind: .division).first?.frame
    }
    return nil
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

  private func sidePanel(_ layout: PlayerLayout, keyboardUp: Bool, safeBottom: CGFloat) -> some View {
    ChatPanel(
      chat: chat, bottomInset: layout.panelPadding.bottom, keyboardUp: keyboardUp, safeBottom: safeBottom,
      compact: layout.landscape && !layout.large, active: !app.playerMinimized)
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
            .frame(width: 46, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.85))
        .accessibilityLabel(model.isPaused ? "Play" : "Pause")
        Spacer()
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.system(size: 16, weight: .bold))
            .frame(width: 46, height: 44)
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

/// The channel is offline: the player is folded down to chat, with this strip where the video
/// was. When they go live it says so, and Watch opens the video back up beside chat.
struct OfflineBanner: View {
  @ObservedObject var model: PlayerModel
  var minimize: () -> Void
  var close: () -> Void
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 10) {
      button("chevron.down", label: "Minimize", action: minimize)
      if let live = model.liveAgain {
        Circle()
          .fill(Color.red)
          .frame(width: 9, height: 9)
          .scaleEffect(pulse ? 1.2 : 0.8)
          .opacity(pulse ? 1 : 0.55)
          .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
          .onAppear { pulse = true }
        VStack(alignment: .leading, spacing: 1) {
          Text("Live now").font(.subheadline.weight(.bold))
          let detail = live.title.isEmpty ? live.category?.name ?? "" : live.title
          if !detail.isEmpty { Text(detail).font(.caption).foregroundColor(.white.opacity(0.7)) }
        }
        .lineLimit(1)
        Spacer(minLength: 6)
        Button {
          withAnimation(.spring(response: 0.55, dampingFraction: 0.88)) { model.watchLive() }
        } label: {
          Label("Watch", systemImage: "play.fill")
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.accentTeal, in: Capsule())
            .foregroundColor(.black)
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .transition(.scale.combined(with: .opacity))
      } else {
        Image(systemName: "moon.zzz.fill").foregroundColor(.white.opacity(0.55))
        VStack(alignment: .leading, spacing: 1) {
          Text("Offline").font(.subheadline.weight(.bold))
          Text("Chat's open. This lights up when they go live.")
            .font(.caption).foregroundColor(.white.opacity(0.65))
            .minimumScaleFactor(0.85)
        }
        .lineLimit(1)
        Spacer(minLength: 6)
      }
      button("xmark", label: "Close", action: close)
    }
    .foregroundColor(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.liveAgain?.id)
  }

  private func button(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 16, weight: .semibold))
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle(scale: 0.9))
    .accessibilityLabel(label)
  }
}
