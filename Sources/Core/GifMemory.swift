// What each channel's GIF keyboard has learned. Twitch turns some GIFs away with a bare "ERROR"
// and no reason, and which ones can't be told from GIPHY's results beforehand, so it's learned as
// it goes: GIFs that went through in a channel are offered first there ("Sent here before", sure to
// send), and ones Twitch turned away there aren't offered again.

import Foundation

struct GifMemory: Codable, Equatable, Sendable {
  struct Sent: Codable, Equatable, Sendable {
    var id: String
    /// GIPHY's address for it, as Twitch was sent it.
    var url: String
    var preview: String
    var aspect: Double
    var title: String
    /// What it was found with (sent again with the same).
    var term: String
  }

  /// Per channel ID, newest first.
  private(set) var sent: [String: [Sent]] = [:]
  /// Per channel ID, GIPHY IDs Twitch turned away there.
  private(set) var refused: [String: [String]] = [:]

  static let keepSent = 30
  static let keepRefused = 500

  mutating func noteSent(_ gif: Sent, channel: String) {
    var list = sent[channel] ?? []
    list.removeAll { $0.id == gif.id }
    list.insert(gif, at: 0)
    sent[channel] = Array(list.prefix(Self.keepSent))
    refused[channel]?.removeAll { $0 == gif.id }
  }

  /// Turned away: not offered in this channel again. (One that went through here before stays: a
  /// single refusal of it was Twitch having a moment, not the GIF.)
  mutating func noteRefused(_ id: String, channel: String) {
    guard !sentHere(channel).contains(where: { $0.id == id }) else { return }
    var list = refused[channel] ?? []
    guard !list.contains(id) else { return }
    list.append(id)
    refused[channel] = Array(list.suffix(Self.keepRefused))
  }

  func sentHere(_ channel: String) -> [Sent] { sent[channel] ?? [] }

  func isRefused(_ id: String, channel: String) -> Bool { refused[channel]?.contains(id) ?? false }
}
