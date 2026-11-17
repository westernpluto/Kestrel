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
  /// The audio-only rendition, when Twitch offers one (not for multi-view's tiles).
  private var audioIndex: Int?
  private var variants: [HLSVariant] = []
  private var adTimeline = AdTimeline()
  /// Straight from Twitch, with an ad-free server's copy only during an ad (Automatic).
  private var adFreeForAdsOnly = false
  private var stopped = false
  private var loadTask: Task<Void, Never>?
  private(set) var isPaused = false
  private var userMuted = false
  private var volume: Float = 1
  private var networkToken: NSObjectProtocol?

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
    // Straight from Twitch, from its servers near the viewer, with an ad-free server's copy only
    // during a stitched ad (a server picked by hand is used throughout). Through an ad-free server
    // from the start, Twitch's server near a viewer in America turned the stream away (403) and the
    // video came from Europe: latency up to 5 s, a quality lower, stalls (in the background most).
    // Straight from Twitch it's steady at about a second and a half, and the breaks Twitch
    // announces leave the stream itself clean (low latency kept through them: see below).
    if case .automatic = AppSettings.shared.adBlocking { config.adFreeServersForAdsOnly = true }
    adFreeForAdsOnly = config.adFreeServersForAdsOnly
    // Low latency through ad breaks: this player hides any ad video it's handed (see apply), so
    // the newest segment isn't held back (that stalled it at every break).
    config.lowLatencyThroughAds = true
    config.proxyPlaylistsDuringAds = AppSettings.shared.proxyPlaylistsDuringAds
    config.checkAccountFirst = TwitchAuth.shared.session != nil
    config.nearbyServers = AppSettings.shared.nearbyServers
    let session = LowLatencySession(
      login: login, config: config, http: AppSettings.shared.sharedPlaybackClient(), mediaHTTP: AppSettings.shared.mediaClient(),
      tokens: TwitchAPI.shared
    ) { [weak self] update in
      Task { @MainActor in self?.apply(update) }
    }
    do {
      let found = try await session.start()
      guard !stopped else { return }
      self.session = session
      variants = found
      model?.broadcastStart = await session.broadcastStarted
      // Best first; one per name (the same size in two codecs: the better one).
      var named = Set<String>()
      videoIndices = found.indices.filter { !found[$0].isAudioOnly }.sorted {
        (found[$0].height, found[$0].frameRate, found[$0].codecRank, found[$0].bandwidth)
          > (found[$1].height, found[$1].frameRate, found[$1].codecRank, found[$1].bandwidth)
      }.filter { named.insert(found[$0].label).inserted }
      guard let best = videoIndices.first else {
        model?.phase = .failed("No playable qualities were found.")
        return
      }
      let preferred = model?.takePreferredQualityLabel().flatMap { label in videoIndices.first { found[$0].label == label } }
      let start = preferred ?? best
      model?.route = await session.route
      audioIndex = model?.isTile == true ? nil : found.firstIndex { $0.isAudioOnly }
      // (A fresh start plays the picture.)
      if model?.audioOnly != nil { model?.audioOnly = nil }
      // Through an ad-free server: a better quality only Twitch itself offers (1440p, say) is in
      // the quality menu, to play straight from Twitch at the viewer's choice.
      model?.checkDirectQualities(served: found)
      model?.qualities = videoIndices.map { PlayerModel.Quality(id: $0, label: found[$0].label) }
        + (audioIndex.map { [PlayerModel.Quality(id: $0, label: "Audio only")] } ?? [])
        + [PlayerModel.Quality(id: nil, label: "Auto")]
      // Auto unless a quality was picked (it moves between them: showing the best as picked was
      // wrong whenever it had stepped down).
      model?.selectedQuality = preferred == nil ? nil : start
      // From what this channel needed last time (on this kind of connection, lately), so it
      // doesn't have to stall again to learn it: always starting from the least, most streams
      // stalled in their first minute. It comes back down within a minute or two if it isn't needed.
      let margin = ChannelMargins.margin(for: login, network: NetworkWatch.shared.memoryKey)
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
      // Cellular: a little more in hand from the start, and (Auto) a lower quality first, 720p
      // (480p in Low Data Mode), trying better once it's played smoothly a while: on a weak
      // signal the best one stalled before Auto could step down.
      let network = NetworkWatch.shared
      engine.setMarginFloor(network.floor)
      // (Not multi-view's tiles: their quality follows their size on screen, and six of them
      // each trying better at the same moment flooded the connection.)
      if preferred == nil, model?.isTile != true, network.kind == .cellular || network.constrained {
        let cap = network.constrained ? 480 : 720
        if let lower = videoIndices.firstIndex(where: { min(found[$0].width, found[$0].height) <= cap }), lower > 0 {
          engine.startLower(steps: lower)
        }
      }
      networkToken = NotificationCenter.default.addObserver(forName: NetworkWatch.changed, object: nil, queue: .main) {
        [weak engine] _ in
        MainActor.assumeIsolated {
          guard let engine else { return }
          engine.setMarginFloor(NetworkWatch.shared.floor)
          // Back on a connection (out of a tunnel, onto another network) while stuck: the
          // downloads in flight went with the old one, so straight back to live (it waited up
          // to 12 s for them before).
          if NetworkWatch.shared.kind != .none, case .stalled = engine.state {
            ActivityLog.shared.add("Kestrel player: connection back while stalled; starting again at live")
            engine.restart()
          }
        }
      }
      self.engine = engine
      // With controls: iOS takes the screen's own layer into the window (no copy). Without: the
      // picture's view moves into the window and back, as multi-view's does.
      // (None for multi-view's tiles: multi-view has its own window.)
      if model?.isTile == true {
      } else if AppSettings.shared.pipControls {
        setUpPictureInPicture(engine)
      } else {
        engine.onScreenView = { [weak self] view in self?.setUpCallPictureInPicture(on: view) }
      }
      if let cap = pendingMaxHeight { setMaxHeight(cap) }
      model?.kestrelEngineReady()
      engine.start()
      ActivityLog.shared.add("Kestrel player: \(login) at \(found.indices.contains(engine.rendition) ? found[engine.rendition].label : found[start].label)")
      if RecordingStore.shared.isRecording(login) {
        ActivityLog.shared.add("Kestrel player: \(login) is being recorded too (that download gives way to this one)")
      }
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
      watchForEnd()
    case .playing:
      model.isBuffering = false
      endWatch?.cancel()
      endWatch = nil
      if model.phase != .playing { model.phase = .playing }
    case .stalled:
      model.isBuffering = true
      watchForEnd()
    case .failed(let message):
      model.phase = .failed(message)
    }
  }

  /// While nothing plays: asks Twitch now and then whether the channel is still live (a stream that
  /// ended just stops sending, and the player waited for it in black forever).
  private var endWatch: Task<Void, Never>?

  private func watchForEnd() {
    guard endWatch == nil, !stopped else { return }
    let login = self.login
    endWatch = Task { [weak self] in
      // A hiccup is usually over in a moment; after that, every few seconds.
      var wait: UInt64 = 4_000_000_000
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: wait)
        guard !Task.isCancelled else { return }
        wait = 6_000_000_000
        guard let page = try? await TwitchAPI.shared.channelPage(login: login) else { continue }
        guard !Task.isCancelled, let self, !self.stopped else { return }
        if page.stream == nil {
          self.endWatch = nil
          self.model?.kestrelOffline()
          return
        }
      }
    }
  }

  private func apply(_ update: LowLatencyUpdate) {
    adTimeline = update.ads
    // The video now comes from somewhere else (an ad-free copy standing in for an ad, or back from
    // it): a gap at the switch isn't the connection's, so it doesn't lower the quality or raise
    // the margin.
    if Self.source(of: update.state) != Self.source(of: model?.adState ?? .none) { engine?.sourceChanged() }
    model?.adState = update.state
    // Any ad break: replaced, looked for or covered (an ad-free copy, or hidden), and also one
    // Twitch sends only to its own player ("skipped": its prefetch hints are held back meanwhile,
    // so the video comes in whole segments).
    switch update.state {
    case .replaced, .searching, .covering, .skipped: engine?.setAdBreak(true)
    case .none: engine?.setAdBreak(false)
    }
  }

  /// Which stream the video comes from in this state: Twitch's own, or an ad-free copy.
  private static func source(of state: AdState) -> Int {
    if case .replaced = state { return 1 }
    return 0
  }

  func stop() {
    stopped = true
    if let networkToken { NotificationCenter.default.removeObserver(networkToken) }
    networkToken = nil
    endWatch?.cancel()
    endWatch = nil
    pip?.stopPictureInPicture()
    pipObservation = nil
    pip = nil
    pipDelegate = nil
    callDelegate = nil
    loadTask?.cancel()
    if let engine { ChannelMargins.remember(engine.catchUp.targetBuffer, for: login, network: NetworkWatch.shared.memoryKey) }
    engine?.stop()
    // Its downloads' session holds it (a URLSession keeps its delegate): let go of it for good.
    engine?.shutDown()
    // The sound engine too: left running, it held the audio session (switching that off then
    // waited for it).
    engine?.audio.shutDown()
    engine = nil
    session = nil
  }

  /// PlayerModel's twice-a-second tick: the latency shown, ads covered, the stats.
  func tick() {
    guard let model, let engine else { return }
    model.setLatency(engine.latency)
    // (Ad times are on the stream's own clock: uncorrected.)
    let latency = engine.rawLatency
    // Only when no ad-free copy was found does the player get ad video: hidden and muted then.
    let playing = latency.map { Date().addingTimeInterval(-$0) }
    let inAd = playing.map { adTimeline.covers($0) } ?? adTimeline.isActive
    if !inAd { engine.noteCleanPicture() }
    if inAd != model.coveringAd {
      // The cover goes up over the stream's last frame, and says how long the break has left.
      if inAd { model.adStill = engine.cleanStill() }
      withAnimation(.easeInOut(duration: 0.35)) { model.coveringAd = inAd }
      if !inAd { model.adBreak = nil }
      // Into or out of a covered ad: the switch between the stream and the ad (and back) isn't
      // the connection's, so a hiccup there doesn't lower the quality or raise the margin (the
      // stream came back with a stall and a restart after ads).
      engine.sourceChanged()
    }
    if inAd, let at = playing, let end = adTimeline.plannedEnd(for: at), let start = adTimeline.plannedStart(for: at) {
      // (On the playing clock: the countdown runs with what's shown.)
      let shown = start.addingTimeInterval(latency ?? 0)...end.addingTimeInterval(latency ?? 0)
      if model.adBreak.map({ abs($0.upperBound.timeIntervalSince(shown.upperBound)) > 0.5 }) ?? true { model.adBreak = shown }
    }
    engine.setMuted(inAd || userMuted)
    // Auto says what it's playing now ("Auto · 720p60"), in the menu and on its button.
    if engine.autoQuality, variants.indices.contains(engine.rendition), let last = model.qualities.last, last.id == nil {
      let label = "Auto · \(variants[engine.rendition].label)"
      if last.label != label {
        model.qualities[model.qualities.count - 1] = PlayerModel.Quality(id: nil, label: label)
      }
    }
  }

  private var pendingMaxHeight: Int?

  /// Multi-view sizes each tile's quality to its picture (and lower while it's out of sight): the
  /// best that's no taller than this; nil, the best that plays smoothly again.
  func setMaxHeight(_ height: Int?) {
    pendingMaxHeight = height
    guard let engine else { return }
    guard let height else {
      engine.setCap(nil)
      return
    }
    // (Auto within the cap: it still steps down when the connection can't carry even that.)
    let pick = videoIndices.first { min(variants[$0].width, variants[$0].height) <= height } ?? videoIndices.last
    engine.setCap(pick)
  }

  func select(_ id: Int?) {
    guard let engine else { return }
    if let id, id == audioIndex {
      engine.playAudioOnly(rendition: id)
      model?.audioOnly = .chosen
      updateAutomaticPictureInPicture()
      ActivityLog.shared.add("Kestrel player: audio only")
      return
    }
    if engine.audioOnly {
      // Back to the picture, at the quality picked (or Auto).
      engine.leaveAudioOnly(rendition: id)
      model?.audioOnly = nil
      updateAutomaticPictureInPicture()
      ActivityLog.shared.add("Kestrel player: back to \(id.flatMap { variants.indices.contains($0) ? variants[$0].label : nil } ?? "Auto") from audio only")
      return
    }
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

  /// Leaving the app opens Picture in Picture by itself, except with audio only: a still picture
  /// in a window is no use, the sound just carries on in the background (and the button's hidden).
  private var startsPictureInPictureByItself: Bool { model?.audioOnly != .chosen }

  /// With audio only, there's no Picture in Picture controller at all: turning off its "start by
  /// itself" wasn't enough, the window still opened with a still picture when the app was swiped
  /// away. It's made again when the picture comes back.
  private func updateAutomaticPictureInPicture() {
    if startsPictureInPictureByItself {
      if pip == nil { rebuildPictureInPicture() } else { pip?.canStartPictureInPictureAutomaticallyFromInline = true }
    } else if pip?.isPictureInPictureActive == true {
      pip?.canStartPictureInPictureAutomaticallyFromInline = false
    } else {
      dropPictureInPicture()
    }
  }

  private func dropPictureInPicture() {
    guard pip != nil else { return }
    pipObservation = nil
    pip = nil
    pipDelegate = nil
    callDelegate = nil
    callSource = nil
    pictureInPictureActive = false
  }

  private func rebuildPictureInPicture() {
    guard pip == nil, let engine, model?.isTile != true else { return }
    if AppSettings.shared.pipControls {
      setUpPictureInPicture(engine)
    } else if let view = lastCallView {
      setUpCallPictureInPicture(on: view)
    }
  }

  /// The window closed after audio only was picked while it was up: the controller goes now.
  private func windowClosedMaybeDrop() {
    guard !startsPictureInPictureByItself else { return }
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.pip?.isPictureInPictureActive != true else { return }
        self.dropPictureInPicture()
      }
    }
  }

  /// The window with controls: iOS takes the screen's own layer into it (one picture, decoded
  /// once). It used to get a copy of the picture behind the screen's, decoded a second time while
  /// the window could open. iOS blacks out the picture's spot for 3 frames as the window goes
  /// either way (the copy didn't prevent it), so it's gone.
  private func setUpPictureInPicture(_ engine: KestrelEngine) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    let delegate = KestrelPictureInPicture(controller: self)
    let controller = AVPictureInPictureController(
      contentSource: .init(sampleBufferDisplayLayer: engine.displayLayer, playbackDelegate: delegate))
    controller.canStartPictureInPictureAutomaticallyFromInline = startsPictureInPictureByItself
    controller.delegate = delegate
    pipObservation = controller.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] pip, _ in
      let active = pip.isPictureInPictureActive
      Task { @MainActor in
        self?.pictureInPictureActive = active
        self?.engine?.screenNote(active ? "window up" : "window gone")
        self?.engine?.windowUp = active
        if !active { self?.windowClosedMaybeDrop() }
      }
    }
    pip = controller
    pipDelegate = delegate
    pipLayer = engine.displayLayer
    // The screen's layer is replaced coming back from the background (see
    // `KestrelEngine.catchUpScreen`): the controller is made again on the new one.
    engine.onScreenLayerReplaced = { [weak self] in self?.pictureInPictureLayerChanged() }
  }

  /// The layer the window with controls was made on.
  private weak var pipLayer: AVSampleBufferDisplayLayer?

  private func pictureInPictureLayerChanged() {
    guard let engine, pipDelegate != nil, pipLayer !== engine.displayLayer, pip?.isPictureInPictureActive != true else { return }
    dropPictureInPicture()
    setUpPictureInPicture(engine)
    engine.screenNote("Picture in Picture made again on the new layer")
  }

  // The kind without controls: the screen's own layers move into the window.
  private let callContent = AVPictureInPictureVideoCallViewController()
  private var callDelegate: KestrelCallPictureInPicture?
  private weak var callSource: UIView?
  /// The screen's view, for making the window's controller again (see `rebuildPictureInPicture`).
  private weak var lastCallView: UIView?

  private func setUpCallPictureInPicture(on view: UIView) {
    lastCallView = view
    // (Audio only: none, see `updateAutomaticPictureInPicture`.)
    guard startsPictureInPictureByItself else { return }
    guard AVPictureInPictureController.isPictureInPictureSupported(), view !== callSource, pip?.isPictureInPictureActive != true else { return }
    callSource = view
    callContent.preferredContentSize = CGSize(width: 1920, height: 1080)
    callContent.view.backgroundColor = .black
    let delegate = KestrelCallPictureInPicture(controller: self)
    let controller = AVPictureInPictureController(contentSource: .init(activeVideoCallSourceView: view, contentViewController: callContent))
    controller.canStartPictureInPictureAutomaticallyFromInline = startsPictureInPictureByItself
    controller.delegate = delegate
    pipObservation = controller.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] pip, _ in
      let active = pip.isPictureInPictureActive
      Task { @MainActor in
        self?.pictureInPictureActive = active
        if !active { self?.windowClosedMaybeDrop() }
      }
    }
    pip = controller
    callDelegate = delegate
  }

  /// Right as the window opens: the picture moves into it.
  func callWindowOpening() {
    guard let view = callSource as? KestrelVideoView.LayerView else { return }
    engine?.screenInWindow = true
    view.lendScreen(to: callContent.view)
  }

  /// The window has gone: the picture is back in the app.
  func callWindowClosed() {
    guard let view = callSource as? KestrelVideoView.LayerView else { return }
    view.takeScreenBack()
    engine?.screenInWindow = false
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
    lines.append(
      StatLine(
        label: "Margin",
        value: String(format: "%.1f s", engine.catchUp.targetBuffer)
          + (engine.wholeSegments ? " (channel not on low latency: video in 2 s pieces)" : "")))
    lines.append(StatLine(label: "Stalls", value: "\(engine.stalls)"))
    lines.append(
      StatLine(
        label: "Sound",
        value: "\(engine.audioAutoFlushes) system restarts, \(engine.audioResyncs) re-synced, \(engine.lateAudio) late, \(engine.audioGaps) skips"
          + (engine.audioGaps > 0 ? String(format: " (largest %.0f ms)", engine.largestAudioGap) : "")
          + ", \(engine.audioOverlaps) overlaps, "
          + String(format: "%.2f s queued", engine.audio.queuedAhead)))
    lines.append(
      StatLine(
        label: "Arrival",
        value: String(format: "longest gap %.2f s, segment handoff %.2f s (last minute)", engine.longestArrivalGap, engine.longestHandoffWait)
          + String(format: ", %.1f s late, playlists up to %.1f s", engine.arrivalDelay, engine.slowestPlaylist)
          + (engine.reconnects > 0 ? ", \(engine.reconnects) reconnects" : "")))
    // The main thread (this player's network, unpacking and timing run on it) held up by the app.
    lines.append(StatLine(label: "Main thread", value: String(format: "longest hold-up %.2f s (last minute)", engine.longestHoldUp)))
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
    // Where the video comes from (not just the ad-blocking setting), and what's happening during
    // an ad break.
    var source = model?.route.map { $0.source(adFreeForAdsOnly: adFreeForAdsOnly) } ?? AppSettings.shared.adBlockingSummary
    // (Your own proxy: Twitch's playback requests go through it; the video doesn't.)
    if case .customProxy = AppSettings.shared.adBlocking {
      source += AppSettings.shared.playbackProxy.map { "; playback requests through your proxy \($0.description)" } ?? "; your proxy isn't filled in"
    }
    lines.append(StatLine(label: "Source", value: source))
    switch model?.adState ?? .none {
    case .none: break
    case .skipped: lines.append(StatLine(label: "Ads", value: "break for Twitch's own player only (stream clean)"))
    case .searching: lines.append(StatLine(label: "Ads", value: "ad break: finding an ad-free copy"))
    case .replaced(let copy): lines.append(StatLine(label: "Ads", value: "ad break: ad-free copy (\(copy))"))
    case .covering: lines.append(StatLine(label: "Ads", value: "ad break: covered"))
    }
    return lines
  }
}

/// The Kestrel player's picture: its display layer, filling the view.
struct KestrelVideoView: UIViewRepresentable {
  let engine: KestrelEngine
  var fill: Bool

  /// Keeps its layers the size of itself (wherever it is: in the player, or in the Picture in
  /// Picture window, whose size isn't known yet when the picture moves in: left at the size they
  /// went in with, zero, the window was black).
  final class LayerHost: UIView {
    override func layoutSubviews() {
      super.layoutSubviews()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for sublayer in layer.sublayers ?? [] { sublayer.frame = bounds }
      CATransaction.commit()
    }
  }

  final class LayerView: UIView {
    /// The screen's layers, bottom to top: a retiring layer, a still of its last frame, the
    /// screen's layer, and a still of the Picture in Picture window's last frame on its way back.
    private let screenHost = LayerHost()
    private var shown: [CALayer] = []

    override init(frame: CGRect) {
      super.init(frame: frame)
      // Only a picture: touches go to what's over it (the mini player's buttons, the gestures).
      // Left on, this UIKit view under the mini player's buttons took some of their taps (only
      // Kestrel's player uses it, so only live streams had it).
      isUserInteractionEnabled = false
      screenHost.isUserInteractionEnabled = false
      screenHost.backgroundColor = .black
      addSubview(screenHost)
    }

    /// Where the picture is now, for the Activity log: the video view's rectangle in the window.
    var screenDescription: String {
      func r(_ rect: CGRect) -> String { String(format: "%.0f,%.0f %.0fx%.0f", rect.minX, rect.minY, rect.width, rect.height) }
      guard let window else { return "view not in a window" }
      return "view \(r(convert(bounds, to: window))) in window \(r(window.bounds))"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Lends the screen's layers (their view) to the Picture in Picture window: the picture itself
    /// goes into the window and comes back, nothing handed over (the kind without controls).
    func lendScreen(to container: UIView) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      container.addSubview(screenHost)
      screenHost.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        screenHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        screenHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        screenHost.topAnchor.constraint(equalTo: container.topAnchor),
        screenHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ])
      for layer in shown { layer.frame = screenHost.bounds }
      CATransaction.commit()
      screenHost.setNeedsLayout()
    }

    func takeScreenBack() {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      screenHost.removeFromSuperview()
      screenHost.translatesAutoresizingMaskIntoConstraints = true
      addSubview(screenHost)
      screenHost.frame = bounds
      for layer in shown { layer.frame = bounds }
      CATransaction.commit()
    }

    /// The screen's layers are out in the window.
    var screenLent: Bool { screenHost.superview !== self }

    func show(_ video: AVSampleBufferDisplayLayer, retiring: AVSampleBufferDisplayLayer?, cover: CALayer? = nil, over: CALayer? = nil) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      placeStill(over)
      let wanted: [CALayer] = [retiring, cover, video].compactMap { $0 }
      if wanted.map(ObjectIdentifier.init) != shown.map(ObjectIdentifier.init) {
        for layer in shown where !wanted.contains(where: { $0 === layer }) { layer.removeFromSuperlayer() }
        // Only new ones are put in, each above the one before it.
        var below: CALayer?
        for layer in wanted {
          if layer.superlayer !== screenHost.layer {
            layer.frame = screenHost.bounds
            if let below {
              screenHost.layer.insertSublayer(layer, above: below)
            } else {
              screenHost.layer.insertSublayer(layer, at: 0)
            }
          }
          below = layer
        }
        shown = wanted
      }
      CATransaction.commit()
    }

    /// The still on the way back from Picture in Picture, in a view of its own on top of the whole
    /// window, over this view's spot. In this view, it went black with the picture: as the window
    /// goes, iOS blanks the part of the app holding the picture's layer for a few frames (chat
    /// beside it stayed), still and all.
    private let stillView: UIView = {
      let view = UIView()
      view.isUserInteractionEnabled = false
      view.backgroundColor = .black
      view.clipsToBounds = true
      return view
    }()
    private weak var still: CALayer?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      // (The player closed with the still up: it goes with it.)
      if window == nil, still != nil { placeStill(nil) }
    }

    private func placeStill(_ layer: CALayer?) {
      guard let layer, let window else {
        still?.removeFromSuperlayer()
        still = nil
        stillView.removeFromSuperview()
        return
      }
      if stillView.superview !== window { window.addSubview(stillView) }
      window.bringSubviewToFront(stillView)
      stillView.frame = convert(bounds, to: window)
      if layer !== still {
        still?.removeFromSuperlayer()
        stillView.layer.addSublayer(layer)
        still = layer
      }
      layer.frame = stillView.bounds
    }

    /// The screen's layers at this view's size now (see `KestrelEngine.refitScreen`).
    func refit() {
      if let still, let window, stillView.superview === window {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stillView.frame = convert(bounds, to: window)
        still.frame = stillView.bounds
        CATransaction.commit()
      }
      guard !screenLent else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      screenHost.frame = bounds
      for layer in shown where layer.frame != screenHost.bounds { layer.frame = screenHost.bounds }
      CATransaction.commit()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      guard !screenLent else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      screenHost.frame = bounds
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
    view.show(engine.displayLayer, retiring: engine.retiringLayer, cover: engine.coverLayer, over: engine.handbackCover)
    engine.describeScreen = { [weak view] in view?.screenDescription ?? "no video view" }
    engine.refitScreen = { [weak view] in view?.refit() }
    engine.screenView = view
    engine.onScreenLayers = { [weak view, weak engine] in
      guard let view, let engine else { return }
      view.show(engine.displayLayer, retiring: engine.retiringLayer, cover: engine.coverLayer, over: engine.handbackCover)
    }
    let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
    for layer in [engine.displayLayer, engine.retiringLayer].compactMap({ $0 }) where layer.videoGravity != gravity {
      layer.videoGravity = gravity
    }
  }
}

/// The Picture in Picture window's controls for the Kestrel player (a live stream: play and pause,
/// no seeking).
/// The window without controls: the screen's own layers move in as it opens and back once it's
/// gone (on the main thread, in the calls themselves: a hop later the window grew empty).
final class KestrelCallPictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
  private weak var controller: KestrelController?

  init(controller: KestrelController) {
    self.controller = controller
  }

  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    MainActor.assumeIsolated { controller?.callWindowOpening() }
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    MainActor.assumeIsolated { controller?.callWindowClosed() }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
  ) {
    MainActor.assumeIsolated { controller?.callWindowClosed() }
  }
}

final class KestrelPictureInPicture: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
  // iOS takes the screen's own layer: it goes on being fed in the background while it's in the
  // window, and is caught up where it is (not replaced: the window holds that layer).
  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    MainActor.assumeIsolated {
      controller?.engine?.screenInPictureInPicture = true
      controller?.engine?.screenNote("opens from: \(controller?.engine?.describeScreen?() ?? "?")\(AppModel.shared.playerMinimized ? " (mini player)" : "")")
    }
  }

  func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    MainActor.assumeIsolated {
      ignorePausesUntil = Date().addingTimeInterval(2)
    }
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    MainActor.assumeIsolated {
      ignorePausesUntil = Date().addingTimeInterval(1.5)
      guard let engine = controller?.engine else { return }
      engine.screenNote("window gone: picture back in the app")
      engine.pictureInPictureEnded()
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
  ) {
    MainActor.assumeIsolated {
      controller?.engine?.screenInPictureInPicture = false
      ActivityLog.shared.add("Picture in Picture didn't start: \(error.localizedDescription)")
    }
  }

  // On the way back into the app: the picture as it is. (A still of the window's last frame over
  // it didn't help: iOS blacks out the picture's spot for 3 frames as the window goes, over
  // anything the app shows there, and the still only froze the picture for half a second.)
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    MainActor.assumeIsolated {
      ignorePausesUntil = Date().addingTimeInterval(3)
      if let engine = controller?.engine {
        engine.screenNote("window asks for the picture")
        engine.screenNote("lands on: \(engine.describeScreen?() ?? "?")\(AppModel.shared.playerMinimized ? " (mini player)" : "")")
      }
      completionHandler(true)
    }
  }

  private weak var controller: KestrelController?

  init(controller: KestrelController) {
    self.controller = controller
  }

  /// While the window goes back into the app, the system can ask for a pause it wasn't asked for
  /// (seen coming back from the mini player on iPhone Duo): for a live stream that stopped it,
  /// black until Play was pressed. Pauses then are ignored.
  private var ignorePausesUntil = Date.distantPast

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    MainActor.assumeIsolated {
      if !playing, Date() < ignorePausesUntil {
        ActivityLog.shared.add("Picture in Picture asked to pause while handing back: ignored")
        pictureInPictureController.invalidatePlaybackState()
        return
      }
      ActivityLog.shared.add(playing ? "Picture in Picture: play" : "Picture in Picture: pause")
      controller?.setPausedFromPictureInPicture(!playing)
    }
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
