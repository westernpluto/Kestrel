import Foundation
import SwiftUI

/// Where you left off in each VOD: kept on this iPhone and, when signed in, synced with your
/// Twitch account the way Twitch's own player does (so the website and apps agree).
@MainActor
final class WatchHistory: ObservableObject {
  static let shared = WatchHistory()

  struct Entry: Codable {
    var position: Double
    var length: Double
    var updated: Date
  }

  @Published private(set) var entries: [String: Entry] = [:]
  private let key = "watchHistory.v1"
  private var syncFailureLogged = false

  private init() {
    if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
      entries = saved
    }
  }

  func save(videoID: String, position: Double, length: Double, syncToTwitch: Bool) {
    guard position.isFinite, position >= 0 else { return }
    entries[videoID] = Entry(position: position, length: length, updated: Date())
    if entries.count > 500 {
      for old in entries.sorted(by: { $0.value.updated < $1.value.updated }).prefix(entries.count - 500) {
        entries.removeValue(forKey: old.key)
      }
    }
    if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    guard syncToTwitch, TwitchAuth.shared.session != nil else { return }
    Task {
      do {
        try await TwitchAPI.shared.saveViewingPosition(videoID: videoID, position: position)
      } catch {
        if !syncFailureLogged {
          syncFailureLogged = true
          ActivityLog.shared.add("Couldn't save your place in the VOD to Twitch (\(error.localizedDescription)); it's kept on this iPhone")
        }
      }
    }
  }

  /// The newest of: Twitch's saved position for your account, the one in the video list, and
  /// this iPhone's.
  func resumePosition(for video: Video) async -> Double? {
    var candidates: [(position: Double, updated: Date)] = []
    if let local = entries[video.id] { candidates.append((local.position, local.updated)) }
    if let remote = await TwitchAPI.shared.viewingPosition(videoID: video.id) {
      candidates.append((remote.position, remote.updated ?? .distantPast))
    } else if let position = video.watchedPosition {
      candidates.append((position, video.watchedAt ?? .distantPast))
    }
    return candidates.max { $0.updated < $1.updated }?.position
  }

  /// How far you got (0…1), for the line under a thumbnail.
  func progress(for video: Video) -> Double? {
    var best: (position: Double, updated: Date)?
    if let local = entries[video.id] { best = (local.position, local.updated) }
    if let position = video.watchedPosition {
      let updated = video.watchedAt ?? .distantPast
      if best == nil || updated > best!.updated { best = (position, updated) }
    }
    guard let best, video.lengthSeconds > 0, best.position > 5 else { return nil }
    return min(1, best.position / Double(video.lengthSeconds))
  }
}

/// The thin line under a VOD thumbnail showing how much you've watched.
struct WatchProgressBar: View {
  var progress: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Rectangle().fill(Color.white.opacity(0.25))
        Rectangle().fill(Color.accentTeal).frame(width: geometry.size.width * progress)
      }
    }
    .frame(height: 3)
  }
}
