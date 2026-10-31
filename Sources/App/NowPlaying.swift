// Lock screen and Control Center: what's playing (title, channel, picture, progress for VODs) and
// the play/pause buttons, for whichever player is open. Works for both players (the low-latency
// one isn't an AVPlayer, so nothing fills this in by itself).

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
    registerCommands()
    update(multiview: multiview)
  }

  func detach(multiview: MultiviewModel) {
    guard self.multiview === multiview else { return }
    self.multiview = nil
    clear()
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
