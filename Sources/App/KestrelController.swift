// Kestrel's own live player in the iPhone app (Settings › Playback › Player): KestrelEngine on the
// same ad-free session the low-latency player uses (LowLatencySession hands out the playlists,
// with ads swapped for ad-free copies), wired into PlayerModel like the other players.

import AVFoundation
import AVKit
import SwiftUI
import UIKit

@MainActor
final class KestrelController {
  let login: String
  private weak var model: PlayerModel?
  private var session: LowLatencySession?
  private(set) var engine: KestrelEngine?
  /// The renditions the session offers (video ones, best first: what the quality menu lists).
  private var videoIndices: [Int] = []
  private var variants: [HLSVariant] = []
  private var adTimeline = AdTimeline()
  private var stopped = false
  private var loadTask: Task<Void, Never>?
  private(set) var isPaused = false
  private var userMuted = false
  private var volume: Float = 1

  init(login: String, model: PlayerModel) {
    self.login = login.lowercased()
    self.model = model
  }

  func start() {
    loadTask = Task { [weak self] in await self?.load() }
  }

  private func load() async {
    var config = LowLatencyConfig()
    // H.264, HEVC and AV1 (AV1 in fragmented MP4), as the device decodes them: Twitch only lists
    // its 1440p renditions when the request says HEVC or AV1, and many are AV1.
    config.codecs = AppSettings.shared.codecs
    config.backupStreams = AppSettings.shared.backupStreams
    config.allowLowQualityBackup = AppSettings.shared.allowLowQualityBackup
    config.adFreeProxies = model?.adFreeProxies ?? AppSettings.shared.adFreeProxyHosts
    config.checkAccountFirst = TwitchAuth.shared.session != nil
    config.nearbyServers = AppSettings.shared.nearbyServers
    let session = LowLatencySession(
      login: login, config: config, http: AppSettings.shared.sharedPlaybackClient(), tokens: TwitchAPI.shared
    ) { [weak self] update in
      Task { @MainActor in self?.apply(update) }
    }
    do {
      let found = try await session.start()
      guard !stopped else { return }
      self.session = session
      variants = found
      videoIndices = found.indices.filter { !found[$0].isAudioOnly }.sorted {
        (found[$0].height, found[$0].frameRate, found[$0].bandwidth) > (found[$1].height, found[$1].frameRate, found[$1].bandwidth)
      }
      guard let best = videoIndices.first else {
        model?.phase = .failed("No playable qualities were found.")
        return
      }
      let preferred = model?.takePreferredQualityLabel().flatMap { label in videoIndices.first { found[$0].label == label } }
      let start = preferred ?? best
      model?.route = await session.route
      model?.qualities = videoIndices.map { PlayerModel.Quality(id: $0, label: found[$0].label) } + [PlayerModel.Quality(id: nil, label: "Auto")]
      model?.selectedQuality = start
      let margin = ChannelMargins.margin(for: login, network: NetworkWatch.shared.memoryKey).map { min($0, LiveCatchUp.startBuffer) }
      // The best quality, stepped down while the connection can't carry it (a quality picked by
      // hand, or the one handed over, stays).
      let engine = KestrelEngine(rendition: start, renditions: videoIndices, auto: preferred == nil, startMargin: margin) {
        [session] index in
        let result = await session.mediaPlaylist(index)
        return result.status == 200 ? result.body : nil
      }
      engine.onState = { [weak self] state in self?.engineState(state) }
      engine.setMuted(userMuted)
      engine.setVolume(volume)
      self.engine = engine
      // (Picture in Picture first: its copy of the picture goes in with the player's view.)
      setUpPictureInPicture(engine)
      model?.kestrelEngineReady()
      engine.start()
      ActivityLog.shared.add("Kestrel player: \(login) at \(found[start].label)")
    } catch StreamSession.StartError.offline {
      model?.phase = .offline
    } catch {
      model?.phase = .failed(error.localizedDescription)
    }
  }

  private func engineState(_ state: KestrelEngine.State) {
    guard let model else { return }
    switch state {
    case .starting:
      model.isBuffering = true
    case .playing:
      model.isBuffering = false
      if model.phase != .playing { model.phase = .playing }
    case .stalled:
      model.isBuffering = true
    case .failed(let message):
      model.phase = .failed(message)
    }
  }

  private func apply(_ update: LowLatencyUpdate) {
    adTimeline = update.ads
    model?.adState = update.state
  }

  func stop() {
    stopped = true
    pip?.stopPictureInPicture()
    pipObservation = nil
    pip = nil
    pipDelegate = nil
    loadTask?.cancel()
    if let engine { ChannelMargins.remember(engine.catchUp.targetBuffer, for: login, network: NetworkWatch.shared.memoryKey) }
    engine?.stop()
    engine = nil
    session = nil
  }

  /// PlayerModel's twice-a-second tick: the latency shown, ads covered, the stats.
  func tick() {
    guard let model, let engine else { return }
    model.setLatency(engine.latency)
    let latency = engine.latency
    // Only when no ad-free copy was found does the player get ad video: hidden and muted then.
    let inAd = latency.map { adTimeline.covers(Date().addingTimeInterval(-$0)) } ?? adTimeline.isActive
    if inAd != model.coveringAd { model.coveringAd = inAd }
    engine.setMuted(inAd || userMuted)
  }

  func select(_ id: Int?) {
    guard let engine else { return }
    guard let id else {
      engine.setAuto()
      ActivityLog.shared.add("Kestrel player: Auto quality (the best that plays smoothly)")
      return
    }
    engine.setRendition(id)
    ActivityLog.shared.add("Kestrel player: switching to \(variants.indices.contains(id) ? variants[id].label : "?") from the next segment")
  }

  // MARK: Picture in Picture

  /// The system's window for a sample buffer display layer: play and pause in the window, and
  /// the picture never leaves the layer, so there's nothing to hand back (no black on return).
  private var pip: AVPictureInPictureController?
  private var pipDelegate: KestrelPictureInPicture?
  private(set) var pictureInPictureActive = false
  private var pipObservation: NSKeyValueObservation?
  private var pipWanted = false

  private func setUpPictureInPicture(_ engine: KestrelEngine) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    let delegate = KestrelPictureInPicture(controller: self)
    let controller = AVPictureInPictureController(
      contentSource: .init(sampleBufferDisplayLayer: engine.makeMirror(), playbackDelegate: delegate))
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    pipObservation = controller.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] pip, _ in
      let active = pip.isPictureInPictureActive
      Task { @MainActor in self?.pictureInPictureActive = active }
    }
    pip = controller
    pipDelegate = delegate
  }

  func togglePictureInPicture() {
    guard let pip else { return }
    if pip.isPictureInPictureActive {
      pip.stopPictureInPicture()
    } else if pip.isPictureInPicturePossible {
      pip.startPictureInPicture()
    } else {
      pipWanted = true
      Task { [weak self] in
        for _ in 0..<10 {
          try? await Task.sleep(nanoseconds: 250_000_000)
          guard let self, self.pipWanted, let pip = self.pip else { return }
          if pip.isPictureInPicturePossible {
            self.pipWanted = false
            pip.startPictureInPicture()
            return
          }
        }
        self?.pipWanted = false
      }
    }
  }

  func setPaused(_ paused: Bool) {
    isPaused = paused
    engine?.setPaused(paused)
    pip?.invalidatePlaybackState()
  }

  /// Play or pause pressed in the PiP window: the player screen follows.
  func setPausedFromPictureInPicture(_ paused: Bool) {
    if let model { model.setPaused(paused) } else { setPaused(paused) }
  }

  func goLive() {
    isPaused = false
    engine?.restart()
  }

  func setMuted(_ muted: Bool) {
    userMuted = muted
    engine?.setMuted(muted || (model?.coveringAd ?? false))
  }

  func setVolume(_ value: Float) {
    volume = value
    engine?.setVolume(value)
  }

  func setFill(_ fill: Bool) {
    engine?.displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    engine?.mirrorLayer?.videoGravity = fill ? .resizeAspectFill : .resizeAspect
  }

  func stats() -> [StatLine] {
    guard let engine else { return [StatLine(label: "Player", value: "Kestrel (starting)")] }
    var lines = [StatLine(label: "Player", value: "Kestrel (own low-latency player)")]
    if variants.indices.contains(engine.rendition) {
      let variant = variants[engine.rendition]
      lines.append(StatLine(label: "Quality", value: variant.label))
      lines.append(StatLine(label: "Codecs", value: variant.codecs.isEmpty ? "–" : variant.codecs))
    }
    lines.append(StatLine(label: "Buffer", value: engine.bufferAhead.map { String(format: "%.2f s", $0) } ?? "–"))
    lines.append(StatLine(label: "Latency", value: engine.latency.map { String(format: "%.2f s", $0) } ?? "–"))
    let rate = engine.rate
    lines.append(
      StatLine(
        label: "Speed",
        value: rate > 1.001 ? String(format: "%.2f× (catching up)", rate) : rate < 0.999 && rate > 0 ? String(format: "%.2f× (building margin)", rate) : "1.00×"))
    lines.append(StatLine(label: "Margin", value: String(format: "%.1f s", engine.catchUp.targetBuffer)))
    lines.append(StatLine(label: "Stalls", value: "\(engine.stalls)"))
    lines.append(
      StatLine(
        label: "Sound",
        value: "\(engine.audioAutoFlushes) system restarts, \(engine.audioResyncs) re-synced, \(engine.lateAudio) late, \(engine.audioGaps) gaps, "
          + String(format: "%.2f s queued", engine.audio.queuedAhead)
          + (engine.audioGaps > 0 ? String(format: " (largest %.0f ms)", engine.largestAudioGap) : "")))
    lines.append(
      StatLine(
        label: "Arrival",
        value: String(format: "longest gap %.2f s, segment handoff %.2f s (last minute)", engine.longestArrivalGap, engine.longestHandoffWait)))
    lines.append(StatLine(label: "Quality mode", value: engine.autoQuality ? "best that plays smoothly" : "picked"))
    lines.append(StatLine(label: "Segments", value: "\(engine.segmentsLoaded) (\(engine.container))"))
    // What to look at when a stream won't show: frames handed to the decoder (and how many only
    // decoded ahead of the start), its state, its last error.
    lines.append(
      StatLine(
        label: "Frames",
        value: "video \(engine.videoFramesQueued) (\(engine.videoFramesHidden) ahead), audio \(engine.audioFramesQueued)"))
    let decoder: String
    switch engine.displayLayer.status {
    case .rendering: decoder = "rendering"
    case .failed: decoder = "failed"
    default: decoder = "waiting"
    }
    lines.append(
      StatLine(
        label: "Decoded",
        value: "\(engine.framesDecoded) pictures, \(engine.framesShown) shown, \(engine.decodeErrors) errors"
          + (engine.decodeErrors > 0 ? " (last \(engine.lastDecodeStatus))" : "")))
    lines.append(
      StatLine(
        label: "Display",
        value: (engine.decoderFailures > 0 ? "\(decoder), \(engine.decoderFailures) failures" : decoder)
          + (engine.decodeInLayer ? " (decodes)" : " (pictures from VideoToolbox)")))
    if let error = engine.lastDecoderError { lines.append(StatLine(label: "Decoder error", value: error)) }
    if let behind = engine.startedBehind { lines.append(StatLine(label: "Started", value: String(format: "%.2f s behind newest", behind))) }
    lines.append(StatLine(label: "Ads", value: AppSettings.shared.adBlockingSummary))
    return lines
  }
}

/// The Kestrel player's picture: its display layer, filling the view.
struct KestrelVideoView: UIViewRepresentable {
  let engine: KestrelEngine
  var fill: Bool

  /// The screen's layer on top, the Picture in Picture copy right behind it (see
  /// `KestrelEngine.makeMirror`).
  final class LayerView: UIView {
    private var shown: [AVSampleBufferDisplayLayer] = []

    /// Bottom to top: the Picture in Picture copy, a retiring screen layer, the screen's layer.
    func show(_ video: AVSampleBufferDisplayLayer, retiring: AVSampleBufferDisplayLayer?, mirror: AVSampleBufferDisplayLayer?) {
      let wanted = [mirror, retiring, video].compactMap { $0 }
      guard wanted.map(ObjectIdentifier.init) != shown.map(ObjectIdentifier.init) else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for layer in shown where !wanted.contains(where: { $0 === layer }) { layer.removeFromSuperlayer() }
      // Only new ones are put in (each above the one before it); the others are left where they
      // are: taking the Picture in Picture copy out and back could upset a window that's open.
      var below: CALayer?
      for layer in wanted {
        if layer.superlayer !== self.layer {
          layer.frame = bounds
          if let below {
            self.layer.insertSublayer(layer, above: below)
          } else {
            self.layer.insertSublayer(layer, at: 0)
          }
        }
        below = layer
      }
      CATransaction.commit()
      shown = wanted
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for layer in shown { layer.frame = bounds }
      CATransaction.commit()
    }
  }

  func makeUIView(context: Context) -> LayerView {
    let view = LayerView()
    view.backgroundColor = .black
    updateUIView(view, context: context)
    return view
  }

  func updateUIView(_ view: LayerView, context: Context) {
    let engine = self.engine
    view.show(engine.displayLayer, retiring: engine.retiringLayer, mirror: engine.mirrorLayer)
    engine.onScreenLayers = { [weak view, weak engine] in
      guard let view, let engine else { return }
      view.show(engine.displayLayer, retiring: engine.retiringLayer, mirror: engine.mirrorLayer)
    }
    let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
    for layer in [engine.displayLayer, engine.retiringLayer, engine.mirrorLayer].compactMap({ $0 }) where layer.videoGravity != gravity {
      layer.videoGravity = gravity
    }
  }
}

/// The Picture in Picture window's controls for the Kestrel player (a live stream: play and pause,
/// no seeking).
final class KestrelPictureInPicture: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
  private weak var controller: KestrelController?

  init(controller: KestrelController) {
    self.controller = controller
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    MainActor.assumeIsolated { controller?.setPausedFromPictureInPicture(!playing) }
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    // Live: an unbounded range shows the window's live controls.
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
    MainActor.assumeIsolated { controller?.isPaused ?? false }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }
}
