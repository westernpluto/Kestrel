// Experimental: every multi-view stream in one Picture in Picture window.
//
// A regular PiP window shows one player. iOS's video-call style of PiP (iOS 15) shows a view of
// the app's own instead, so each stream's own picture goes into it, side by side. The low-latency
// player keeps playing each stream, so they stay as close to live as they were. Whether that
// player keeps drawing in the window while Kestrel is in the background isn't something Amazon
// documents: Settings › Playback turns this off (back to PiP of the picked stream).

#if canImport(AmazonIVSPlayer)
  import AmazonIVSPlayer
  import AVKit
  import UIKit

  @MainActor
  final class MultiviewPictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    private weak var model: MultiviewModel?
    private let content = AVPictureInPictureVideoCallViewController()
    private let grid = PictureGridView()
    private var controller: AVPictureInPictureController?
    /// The multi-view screen's pictures: where the window grows from and goes back to.
    private weak var source: UIView?
    private var enabled = false
    private(set) var isActive = false
    /// Started with the button: show it as soon as iOS can.
    private var wanted = false
    private var possibleObservation: NSKeyValueObservation?

    init(model: MultiviewModel) {
      self.model = model
      super.init()
      content.view.backgroundColor = .black
      grid.frame = content.view.bounds
      grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      content.view.addSubview(grid)
    }

    /// On while multi-view is on screen with streams to show together (and the setting's on).
    func setEnabled(_ on: Bool, source: UIView?) {
      let changed = on != enabled || source !== self.source
      enabled = on
      self.source = source
      guard changed, !isActive else { return }
      possibleObservation = nil
      controller?.delegate = nil
      controller = nil
      guard on, let source, AVPictureInPictureController.isPictureInPictureSupported() else { return }
      let pip = AVPictureInPictureController(
        contentSource: .init(activeVideoCallSourceView: source, contentViewController: content))
      pip.canStartPictureInPictureAutomaticallyFromInline = true
      pip.delegate = self
      possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] pip, _ in
        guard pip.isPictureInPicturePossible, let owner = self else { return }
        Task { @MainActor in
          guard owner.wanted, let current = owner.controller, !current.isPictureInPictureActive else { return }
          owner.wanted = false
          current.startPictureInPicture()
        }
      }
      controller = pip
    }

    /// The window's shape for this many streams (each picture 16:9).
    func fit(count: Int) {
      let size = PictureGridView.contentSize(count)
      if content.preferredContentSize != size { content.preferredContentSize = size }
    }

    func toggle() {
      guard let controller else { return }
      if controller.isPictureInPictureActive {
        controller.stopPictureInPicture()
      } else if controller.isPictureInPicturePossible {
        controller.startPictureInPicture()
      } else {
        wanted = true
        Task { [weak self] in
          try? await Task.sleep(nanoseconds: 2_500_000_000)
          self?.wanted = false
        }
      }
    }

    func stop() {
      controller?.stopPictureInPicture()
    }

    /// Streams added or removed while the window is up.
    func sync() {
      guard isActive, let model else { return }
      fit(count: model.tiles.count)
      let views = grid.show(model.tiles.map { (id: $0.id, heard: model.heardIDs.contains($0.id)) })
      for tile in model.tiles { tile.player.showPicture(in: views[tile.id]) }
    }

    // MARK: Window opening and closing

    private func began() {
      guard !isActive, let model else { return }
      isActive = true
      sync()
      model.pictureInPictureChanged(true)
      ActivityLog.shared.add("Multi-view in Picture in Picture: \(model.tiles.count) streams together")
    }

    private func ended() {
      guard isActive else { return }
      isActive = false
      for tile in model?.tiles ?? [] { tile.player.showPicture(in: nil) }
      grid.show([])
      model?.pictureInPictureChanged(false)
      // Set up again for next time, now that it's free to change.
      let on = enabled
      let source = self.source
      enabled = !on
      setEnabled(on, source: source)
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
      Task { @MainActor in self.began() }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
      Task { @MainActor in self.ended() }
    }

    nonisolated func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
    ) {
      let message = error.localizedDescription
      Task { @MainActor in
        ActivityLog.shared.add("Multi-view couldn't go into Picture in Picture: \(message)")
        self.ended()
      }
    }

    nonisolated func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
      completionHandler(true)
    }
  }

  /// The streams' pictures in the PiP window: two stacked, three or four in a 2×2 grid (a third
  /// centred under the first two), with a speaker on the ones heard. The window takes no touches.
  final class PictureGridView: UIView {
    private struct Cell {
      let id: String
      let video: IVSPlayerView
      let speaker: UIImageView
    }

    private var cells: [Cell] = []
    private static let gap: CGFloat = 1

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 16:9 pictures, laid out as `layoutSubviews` does.
    static func contentSize(_ count: Int) -> CGSize {
      count == 2 ? CGSize(width: 1600, height: 1800) : CGSize(width: 1920, height: 1080)
    }

    /// Shows these streams (in order), keeping the views of ones already shown. Returns each
    /// stream's view.
    @discardableResult
    func show(_ items: [(id: String, heard: Bool)]) -> [String: IVSPlayerView] {
      let wanted = Set(items.map(\.id))
      for cell in cells where !wanted.contains(cell.id) {
        cell.video.player = nil
        cell.video.removeFromSuperview()
        cell.speaker.removeFromSuperview()
      }
      var kept = Dictionary(uniqueKeysWithValues: cells.filter { wanted.contains($0.id) }.map { ($0.id, $0) })
      var next: [Cell] = []
      for item in items {
        let cell: Cell
        if let existing = kept.removeValue(forKey: item.id) {
          cell = existing
        } else {
          let video = IVSPlayerView()
          video.backgroundColor = .black
          video.videoGravity = .resizeAspect
          let speaker = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
          speaker.tintColor = .white
          speaker.contentMode = .scaleAspectFit
          speaker.layer.shadowColor = UIColor.black.cgColor
          speaker.layer.shadowOpacity = 0.7
          speaker.layer.shadowRadius = 2
          speaker.layer.shadowOffset = .zero
          addSubview(video)
          addSubview(speaker)
          cell = Cell(id: item.id, video: video, speaker: speaker)
        }
        cell.speaker.isHidden = !item.heard
        next.append(cell)
      }
      cells = next
      setNeedsLayout()
      return Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.video) })
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      let frames = Self.frames(count: cells.count, in: bounds)
      for (cell, frame) in zip(cells, frames) {
        cell.video.frame = frame
        let side = max(10, min(18, frame.width * 0.07))
        cell.speaker.frame = CGRect(x: frame.minX + 6, y: frame.minY + 6, width: side, height: side)
      }
    }

    private static func frames(count: Int, in bounds: CGRect) -> [CGRect] {
      switch count {
      case 0: return []
      case 1: return [bounds]
      case 2:
        let height = (bounds.height - gap) / 2
        return [
          CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height),
          CGRect(x: bounds.minX, y: bounds.minY + height + gap, width: bounds.width, height: height),
        ]
      default:
        let width = (bounds.width - gap) / 2
        let height = (bounds.height - gap) / 2
        var out: [CGRect] = []
        for index in 0..<min(count, 4) {
          let row = index / 2
          let column = index % 2
          // A third picture on its own goes in the middle of the bottom row.
          let x = count == 3 && index == 2 ? bounds.minX + (bounds.width - width) / 2 : bounds.minX + CGFloat(column) * (width + gap)
          out.append(CGRect(x: x, y: bounds.minY + CGFloat(row) * (height + gap), width: width, height: height))
        }
        return out
      }
    }
  }
#endif
