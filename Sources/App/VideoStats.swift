import SwiftUI

/// One row of the video stats overlay.
struct StatLine: Identifiable, Equatable {
  var label: String
  var value: String
  var id: String { label }
}

enum StatFormat {
  static func mbps(_ bitsPerSecond: Double) -> String {
    bitsPerSecond > 0 ? String(format: "%.2f Mbps", bitsPerSecond / 1_000_000) : "–"
  }

  static func seconds(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "–" }
    return String(format: "%.2f s", value)
  }

  static func proxy() -> String {
    AppSettings.shared.playbackProxy.map { "on (\($0.description))" } ?? "off"
  }
}

extension AdState {
  var statsText: String {
    switch self {
    case .none: return "none"
    case .skipped: return "client-side break, skipped"
    case .searching: return "stitched ad, looking for an ad-free copy"
    case .replaced(let copy): return "ad-free copy (\(copy))"
    case .covering: return "stitched ad, hidden and muted"
    }
  }
}

/// Twitch-style stats in the corner of the video.
struct StatsOverlay: View {
  var lines: [StatLine]

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(lines) { line in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(line.label).foregroundColor(.white.opacity(0.65))
          Text(line.value).foregroundColor(.white)
        }
      }
    }
    .font(.system(size: 10, design: .monospaced))
    .lineLimit(1)
    .padding(6)
    .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(6)
    .allowsHitTesting(false)
  }
}
