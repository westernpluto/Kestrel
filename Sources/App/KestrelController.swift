// Kestrel's own live player in the iPhone app (Settings › Playback › Player): KestrelEngine on the
// same ad-free session the low-latency player uses (LowLatencySession hands out the playlists,
// with ads swapped for ad-free copies), wired into PlayerModel like the other players.

import AVFoundation
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
    // Twitch's H.264 renditions come as MPEG-TS, which this player unpacks; its HEVC and AV1
    // ones come in fragmented MP4, which it doesn't (yet).
    config.codecs = "h264"
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
      model?.qualities = videoIndices.map { PlayerModel.Quality(id: $0, label: found[$0].label) }
      model?.selectedQuality = start
      let margin = ChannelMargins.margin(for: login, network: NetworkWatch.shared.memoryKey).map { min($0, LiveCatchUp.startBuffer) }
      let engine = KestrelEngine(rendition: start, startMargin: margin) { [session] index in
        let result = await session.mediaPlaylist(index)
        return result.status == 200 ? result.body : nil
      }
      engine.onState = { [weak self] state in self?.engineState(state) }
      engine.setMuted(userMuted)
      engine.setVolume(volume)
      self.engine = engine
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
    guard let id, let engine else { return }
    engine.setRendition(id)
    ActivityLog.shared.add("Kestrel player: switching to \(variants.indices.contains(id) ? variants[id].label : "?") from the next segment")
  }

  func setPaused(_ paused: Bool) {
    isPaused = paused
    engine?.setPaused(paused)
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
      StatLine(label: "Display", value: engine.decoderFailures > 0 ? "\(decoder), \(engine.decoderFailures) failures" : decoder))
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

  final class LayerView: UIView {
    var videoLayer: AVSampleBufferDisplayLayer? {
      didSet {
        oldValue?.removeFromSuperlayer()
        if let videoLayer { layer.addSublayer(videoLayer) }
        setNeedsLayout()
      }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      videoLayer?.frame = bounds
      CATransaction.commit()
    }
  }

  func makeUIView(context: Context) -> LayerView {
    let view = LayerView()
    view.backgroundColor = .black
    view.videoLayer = engine.displayLayer
    engine.displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    return view
  }

  func updateUIView(_ view: LayerView, context: Context) {
    if view.videoLayer !== engine.displayLayer { view.videoLayer = engine.displayLayer }
    let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
    if engine.displayLayer.videoGravity != gravity { engine.displayLayer.videoGravity = gravity }
  }
}
