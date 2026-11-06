// One broadcast recorded in several pieces (the app was stopped, a connection dropped, the
// recording was started again): played as one video, the pieces back to back, with the stretches
// that weren't recorded skipped (and said so).

import Foundation

enum RecordingJoin {
  /// The pieces' playlists (each as the recorder writes it, its files named relative to it) joined
  /// into one: each piece's files point back into its own folder (`/rec/<id>/<file>`), a
  /// discontinuity between pieces, one header, and the end only once the last piece has ended.
  static func playlist(_ pieces: [(id: String, text: String)]) -> String {
    var body: [String] = []
    var longest = 1
    var allEnded = !pieces.isEmpty
    var first = true
    for piece in pieces {
      let lines = piece.text.split(whereSeparator: \.isNewline).map(String.init)
      let ended = lines.contains("#EXT-X-ENDLIST")
      allEnded = ended
      var pieceBody: [String] = []
      for line in lines {
        if line.hasPrefix("#EXT-X-TARGETDURATION:") {
          longest = max(longest, Int(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 1)
          continue
        }
        if line == "#EXTM3U" || line.hasPrefix("#EXT-X-VERSION") || line.hasPrefix("#EXT-X-PLAYLIST-TYPE")
          || line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") || line.hasPrefix("#EXT-X-START") || line == "#EXT-X-ENDLIST"
        {
          continue
        }
        if line.hasPrefix("#EXT-X-MAP:") {
          pieceBody.append(rewriteMap(line, id: piece.id))
        } else if line.hasPrefix("#") {
          pieceBody.append(line)
        } else if !line.isEmpty {
          pieceBody.append(line.hasPrefix("/") || line.contains("://") ? line : "/rec/\(piece.id)/\(line)")
        }
      }
      guard pieceBody.contains(where: { !$0.hasPrefix("#") }) else { continue }
      if !first, pieceBody.first != "#EXT-X-DISCONTINUITY" { body.append("#EXT-X-DISCONTINUITY") }
      first = false
      body += pieceBody
    }
    // The same header while the last piece is recorded and after (see StreamRecorder.playlistText):
    // a player watching it reloads it, and stalls if its target duration or type changes.
    var lines = [
      "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(StreamRecorder.stableTargetDuration, longest))",
      "#EXT-X-PLAYLIST-TYPE:EVENT", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-START:TIME-OFFSET=0",
    ]
    lines += body
    if allEnded { lines.append("#EXT-X-ENDLIST") }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func rewriteMap(_ line: String, id: String) -> String {
    guard let start = line.range(of: "URI=\""), let end = line[start.upperBound...].firstIndex(of: "\"") else { return line }
    let uri = String(line[start.upperBound..<end])
    guard !uri.hasPrefix("/"), !uri.contains("://") else { return line }
    return line.replacingCharacters(in: start.upperBound..<end, with: "/rec/\(id)/\(uri)")
  }

  /// Where the joins fall in the joined video (seconds from its start) and how much of the
  /// broadcast went unrecorded at each: `pieces` in order, each with when its first moment was
  /// broadcast and how long it is.
  static func gaps(_ pieces: [(start: Date, duration: Double)]) -> [(at: Double, missing: Double)] {
    var result: [(at: Double, missing: Double)] = []
    var position = 0.0
    for (index, piece) in pieces.enumerated() {
      if index > 0 {
        let previous = pieces[index - 1]
        let missing = piece.start.timeIntervalSince(previous.start.addingTimeInterval(previous.duration))
        result.append((position, max(0, missing)))
      }
      position += piece.duration
    }
    return result
  }
}
