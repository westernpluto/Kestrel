// Lock screen and Control Center: what's playing (title, channel, picture, progress for VODs) and
// the play/pause buttons, for whichever player is open. Works for both players (the low-latency
// one isn't an AVPlayer, so nothing fills this in by itself).

import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class NowPlaying {
  static let shared = NowPlaying()

  private weak var model: PlayerModel?
  /// Multi-view, when it's what's playing (its streams don't speak for themselves here).
  private weak var multiview: MultiviewModel?
  private var registered = false
  private var artworkURL: URL?
  private var artwork: MPMediaItemArtwork?
  /// What was last handed to the system, to only update it when something changed.
  private var lastSignature = ""
  private var lastElapsed: Double = 0
  private var lastPush = Date.distantPast
  private var lastPaused = true

  private init() {}

  func attach(_ model: PlayerModel) {
    self.model = model
    multiview = nil
    artworkURL = nil
    artwork = nil
    lastSignature = ""
    // (Opened for chat while offline: nothing plays yet, other apps' audio carries on. It's
    // claimed once the stream plays: see `update`.)
    if !model.expectsOffline { claimSession() }
    registerCommands()
    update(model)
  }

  func detach(_ model: PlayerModel) {
    guard self.model === model else { return }
    self.model = nil
    clear()
  }

  /// Multi-view: the streams' names, play and pause for all of them (see MultiviewModel.setPaused).
  func attach(multiview: MultiviewModel) {
    model = nil
    self.multiview = multiview
    artworkURL = nil
    artwork = nil
    lastSignature = ""
    claimSession()
    registerCommands()
    update(multiview: multiview)
  }

  func detach(multiview: MultiviewModel) {
    guard self.multiview === multiview else { return }
    self.multiview = nil
    clear()
  }

  /// Makes Kestrel the app iOS treats as playing: the playback category, not mixed with other
  /// apps, and active. Only that app is tied to the lock screen's Now Playing card, so tapping the
  /// card opens it. Running in the background with nothing playing (go-live alerts, recordings)
  /// mixes with other apps so music isn't interrupted (see BackgroundKeepAlive). Multi-view
  /// never switched that back: the card showed the streams, but tapping it didn't open Kestrel,
  /// and its buttons could go to the music app instead.
  func claimSession() {
    let session = AVAudioSession.sharedInstance()
    let mixing = session.categoryOptions.contains(.mixWithOthers)
    if mixing || session.category != .playback {
      do {
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
        if mixing { ActivityLog.shared.add("Now Playing: sound no longer mixed with other apps (the lock screen opens Kestrel)") }
      } catch {
        ActivityLog.shared.add("Now Playing: couldn't set the sound up for playback (\(error.localizedDescription))")
      }
    }
    try? session.setActive(true)
  }

  private func clear() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    let center = MPRemoteCommandCenter.shared()
    for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand] { command.isEnabled = false }
    center.changePlaybackPositionCommand.isEnabled = false
    center.skipForwardCommand.isEnabled = false
    center.skipBackwardCommand.isEnabled = false
  }

  private func registerCommands() {
    let center = MPRemoteCommandCenter.shared()
    for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand] { command.isEnabled = true }
    guard !registered else { return }
    registered = true
    center.playCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.setPaused(false) }
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.setPaused(true) }
      return .success
    }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        if let multiview = self.multiview {
          multiview.setPaused(!multiview.paused)
        } else {
          self.model?.togglePause()
        }
      }
      return .success
    }
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      let seconds = event.positionTime
      Task { @MainActor in self?.model?.seekFromRemote(to: seconds) }
      return .success
    }
    center.skipForwardCommand.preferredIntervals = [10]
    center.skipBackwardCommand.preferredIntervals = [10]
    center.skipForwardCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.model?.skip(by: 10) }
      return .success
    }
    center.skipBackwardCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.model?.skip(by: -10) }
      return .success
    }
  }

  /// Headphones taken out (or Bluetooth gone): paused, as iOS apps do, rather than carrying on
  /// out of the speaker.
  func pauseForLostRoute() {
    setPaused(true)
    ActivityLog.shared.add("Headphones disconnected: paused")
  }

  private func setPaused(_ paused: Bool) {
    if let multiview {
      multiview.setPaused(paused)
    } else {
      model?.setPaused(paused)
    }
  }

  /// Multi-view: who's heard (or everyone), how many streams, and paused or not.
  func update(multiview: MultiviewModel) {
    guard self.multiview === multiview else { return }
    let tiles = multiview.tiles
    let heard = tiles.filter { multiview.heardIDs.contains($0.id) }
    let title = (heard.isEmpty ? tiles : heard).map(\.channel.name).joined(separator: " + ")
    let artist = "Multi-view · \(tiles.count) stream\(tiles.count == 1 ? "" : "s")"
    if let pictureURL = (heard.first ?? tiles.first)?.channel.profileImageURL.flatMap(URL.init(string:)),
      pictureURL != artworkURL
    {
      loadArtwork(pictureURL)
    }
    let paused = multiview.paused
    let signature = [title, artist, "multiview", artwork == nil ? "" : "art"].joined(separator: "|")
    guard signature != lastSignature || paused != lastPaused else { return }
    lastSignature = signature
    lastPaused = paused
    lastPush = Date()
    if !paused, AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers) { claimSession() }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: artist,
      MPNowPlayingInfoPropertyIsLiveStream: true,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
      MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
    ]
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    let center = MPRemoteCommandCenter.shared()
    center.changePlaybackPositionCommand.isEnabled = false
    center.skipForwardCommand.isEnabled = false
    center.skipBackwardCommand.isEnabled = false
  }

  /// Called by the player as it ticks; only talks to the system when something changed.
  func update(_ model: PlayerModel) {
    guard self.model === model else { return }
    let title: String
    let artist: String
    var pictureURL: URL?
    switch model.target {
    case .live(let channel):
      let owner = model.channel ?? channel
      title = model.stream?.title ?? owner.name
      artist = owner.name
      pictureURL = TwitchAPI.image(model.stream?.previewImageURL, width: 640, height: 360)
        ?? owner.profileImageURL.flatMap(URL.init(string:))
    case .video(let video):
      title = video.title
      artist = video.owner?.name ?? model.channel?.name ?? ""
      pictureURL = TwitchAPI.image(video.previewURL, width: 640, height: 360)
        ?? (video.owner ?? model.channel)?.profileImageURL.flatMap(URL.init(string:))
    }
    if let pictureURL, pictureURL != artworkURL { loadArtwork(pictureURL) }

    let live = model.isLive && !model.isRewinding
    let elapsed = model.isRewinding ? model.rewindPosition : model.position
    let duration = model.isRewinding ? model.broadcastElapsed : model.duration
    let paused = model.isPaused
    let signature = [title, artist, live ? "live" : "vod", String(Int(duration / 5)), artwork == nil ? "" : "art"]
      .joined(separator: "|")
    // Where the system thinks playback is (it advances the clock by itself while playing).
    let expected = lastElapsed + (lastPaused ? 0 : Date().timeIntervalSince(lastPush))
    let drifted = !live && abs(expected - elapsed) > 2
    guard signature != lastSignature || paused != lastPaused || drifted || Date().timeIntervalSince(lastPush) > 30 else {
      return
    }
    lastSignature = signature
    lastPaused = paused
    lastElapsed = elapsed
    lastPush = Date()
    if !paused, model.phase == .playing, AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers) { claimSession() }

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: artist,
      MPNowPlayingInfoPropertyIsLiveStream: live,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
      MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
    ]
    if !live {
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
      if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    }
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info

    // Seeking from the lock screen: VODs, and live streams that can be rewound.
    let seekable = !model.isLive || model.rewind != nil
    let center = MPRemoteCommandCenter.shared()
    center.changePlaybackPositionCommand.isEnabled = seekable && duration > 0
    center.skipForwardCommand.isEnabled = !live
    center.skipBackwardCommand.isEnabled = seekable
  }

  private func loadArtwork(_ url: URL) {
    artworkURL = url
    ImagePipeline.shared.load(url, maxPixels: 640) { [weak self] image in
      guard let image else { return }
      Task { @MainActor in
        guard let self, self.artworkURL == url else { return }
        self.artwork = Self.makeArtwork(image.images?.first ?? image)
        if let model = self.model {
          self.update(model)
        } else if let multiview = self.multiview {
          self.update(multiview: multiview)
        }
      }
    }
  }

  /// Outside the main actor: the system asks for the picture from a background thread.
  nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  }
}

/// Keeps the screen on while anything plays in front of you (a stream, multi-view, a recording):
/// each asks for it under its own name, and it goes off when none does.
@MainActor
enum ScreenAwake {
  private static var reasons: Set<String> = []

  static func set(_ reason: String, _ on: Bool) {
    let changed = on ? reasons.insert(reason).inserted : reasons.remove(reason) != nil
    guard changed else { return }
    let awake = !reasons.isEmpty
    if UIApplication.shared.isIdleTimerDisabled != awake { UIApplication.shared.isIdleTimerDisabled = awake }
  }
}

/// Light taps for the moments other iOS apps mark with one.
@MainActor
enum Haptics {
  private static let light = UIImpactFeedbackGenerator(style: .light)
  static func tap() { light.impactOccurred() }
}

/// Watches the audio route (see `NowPlaying.pauseForLostRoute`).
enum AudioRouteWatch {
  nonisolated(unsafe) private static var token: NSObjectProtocol?

  static func start() {
    guard token == nil else { return }
    token = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
      let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
      guard raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable else { return }
      let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
      MainActor.assumeIsolated { lostRoute(previous: previous) }
    }
  }

  @MainActor private static var lastPause = Date.distantPast

  /// Only when the sound would now come out of the phone itself, from headphones, a headset, a
  /// car or AirPlay: Bluetooth headphones switching profiles (or flickering in and out) also say
  /// "old device unavailable", and paused playback again and again while they stayed on.
  @MainActor private static func lostRoute(previous: AVAudioSessionRouteDescription?) {
    let personal: Set<AVAudioSession.Port> = [
      .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .carAudio, .usbAudio, .lineOut,
    ]
    let wasPersonal = previous?.outputs.contains { personal.contains($0.portType) } ?? true
    let now = AVAudioSession.sharedInstance().currentRoute.outputs
    let outLoud = now.isEmpty || now.contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
    guard wasPersonal, outLoud else { return }
    // One pause for one disconnect.
    guard Date().timeIntervalSince(lastPause) > 3 else { return }
    lastPause = Date()
    NowPlaying.shared.pauseForLostRoute()
  }
}
