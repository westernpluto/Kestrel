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

/// Twitch-style stats in the corner of the video. On a small video it switches to columns and
/// smaller type so it never covers the controls (on iPhone Duo's outer screen, a single column was
/// taller than the video and pushed the gear, where it's turned off, out of reach).
struct StatsOverlay: View {
  var lines: [StatLine]
  /// Shows a close button.
  var close: (() -> Void)? = nil

  var body: some View {
    ViewThatFits {
      panel(columns: 1, size: 10)
      panel(columns: 2, size: 9)
      panel(columns: 2, size: 7.5)
      panel(columns: 3, size: 7)
    }
  }

  private func panel(columns: Int, size: CGFloat) -> some View {
    let perColumn = max(1, Int((Double(lines.count) / Double(columns)).rounded(.up)))
    let groups = stride(from: 0, to: lines.count, by: perColumn).map { Array(lines[$0..<min($0 + perColumn, lines.count)]) }
    return HStack(alignment: .top, spacing: 12) {
      ForEach(groups.indices, id: \.self) { index in
        VStack(alignment: .leading, spacing: 1) {
          ForEach(groups[index]) { line in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(line.label).foregroundColor(.white.opacity(0.65))
              Text(line.value).foregroundColor(.white)
            }
          }
        }
      }
    }
    .font(.system(size: size, design: .monospaced))
    .lineLimit(1)
    .fixedSize()
    .allowsHitTesting(false)
    .padding(6)
    .padding(.trailing, close == nil ? 0 : 26)
    .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
    .overlay(alignment: .topTrailing) {
      if let close {
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white.opacity(0.85))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Hide video stats")
      }
    }
    .padding(6)
  }
}
