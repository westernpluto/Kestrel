// Full screen with chat put away: a small, see-through chat over the video (read-only), like
// Twitch's chat overlay. Drag it to any corner; hold it for size and how see-through it is.

import SwiftUI

struct ChatOverlay: View {
  let chat: ChatController
  /// Room to keep clear at the edges (the camera, the controls' bars).
  var clearance: EdgeInsets
  /// A tap on the overlay counts as a tap on the video (shows or hides the controls).
  var tap: () -> Void
  /// 0 top left, 1 top right, 2 bottom left, 3 bottom right.
  @AppStorage("chatOverlay.corner") private var corner = 2
  @AppStorage("chatOverlay.opacity") private var opacity = 0.4
  /// 0 small, 1 medium, 2 large.
  @AppStorage("chatOverlay.size") private var size = 1
  @State private var drag: CGSize = .zero

  /// Above the seek bar and below the top bar, so the controls never cover it.
  private static let barRoom: (top: CGFloat, bottom: CGFloat) = (50, 76)

  var body: some View {
    GeometryReader { geometry in
      let box = boxSize(in: geometry.size)
      let origin = position(of: box, in: geometry.size)
      messages
        .frame(width: box.width, height: box.height)
        .background(Color.black.opacity(opacity), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .offset(x: origin.x + drag.width, y: origin.y + drag.height)
        .onTapGesture(perform: tap)
        .gesture(
          DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { drag = $0.translation }
            .onEnded { value in
              // To the corner it was thrown toward.
              let x = origin.x + box.width / 2 + value.predictedEndTranslation.width
              let y = origin.y + box.height / 2 + value.predictedEndTranslation.height
              let newCorner = (x > geometry.size.width / 2 ? 1 : 0) + (y > geometry.size.height / 2 ? 2 : 0)
              let landing = position(of: box, in: geometry.size, corner: newCorner)
              // Keep it where the finger left it, then let it glide into the corner.
              drag = CGSize(width: origin.x + value.translation.width - landing.x, height: origin.y + value.translation.height - landing.y)
              corner = newCorner
              withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { drag = .zero }
            }
        )
        .contextMenu { menu }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: size)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Chat overlay")
  }

  /// The newest messages, fading out toward the top.
  private var messages: some View {
    ChatMessagesView(chat: chat, style: .overlay)
      .padding(.vertical, 4)
      .mask(
        LinearGradient(
          stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18), .init(color: .black, location: 1)],
          startPoint: .top, endPoint: .bottom)
      )
      .allowsHitTesting(false)
  }

  @ViewBuilder
  private var menu: some View {
    Picker("Size", selection: $size) {
      Text("Small").tag(0)
      Text("Medium").tag(1)
      Text("Large").tag(2)
    }
    Picker("Background", selection: $opacity) {
      Text("Clear").tag(0.15)
      Text("See-through").tag(0.4)
      Text("Dark").tag(0.65)
    }
  }

  private func boxSize(in area: CGSize) -> CGSize {
    let shares: [(CGFloat, CGFloat)] = [(0.24, 0.34), (0.3, 0.46), (0.38, 0.6)]
    let share = shares[min(max(size, 0), shares.count - 1)]
    let usableHeight = area.height - clearance.top - clearance.bottom - Self.barRoom.top - Self.barRoom.bottom
    let width = min(max(area.width * share.0, 200), 420, area.width - clearance.leading - clearance.trailing - 16)
    let height = min(max(area.height * share.1, 120), max(80, usableHeight))
    return CGSize(width: width.rounded(), height: height.rounded())
  }

  private func position(of box: CGSize, in area: CGSize, corner: Int? = nil) -> CGPoint {
    let corner = corner ?? self.corner
    let left = clearance.leading + 8
    let right = area.width - clearance.trailing - 8 - box.width
    let top = clearance.top + Self.barRoom.top
    let bottom = area.height - clearance.bottom - Self.barRoom.bottom - box.height
    return CGPoint(x: corner % 2 == 0 ? left : right, y: corner < 2 ? top : max(top, bottom))
  }
}
