// Full screen with chat put away: a small, see-through chat over the video (read-only), like
// Twitch's chat overlay. Drag it to any corner; drag the grip on its inner corner to make it taller
// or shorter, wider or narrower; hold it for how see-through it is.

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
  /// Its size, as shares of the room it can have (so it fits whichever screen it's on).
  @AppStorage("chatOverlay.width") private var widthShare = 0.42
  @AppStorage("chatOverlay.height") private var heightShare = 0.62
  @State private var drag: CGSize = .zero
  /// The grip being dragged: the size it started at.
  @State private var resizingFrom: CGSize?
  @State private var resized: CGSize?

  /// Above the seek bar and below the top bar, so the controls never cover it.
  private static let barRoom: (top: CGFloat, bottom: CGFloat) = (50, 76)
  private static let minimum = CGSize(width: 170, height: 90)
  private static let defaults = (width: 0.42, height: 0.62)

  var body: some View {
    GeometryReader { geometry in
      let room = room(in: geometry.size)
      let box = resized ?? boxSize(in: room)
      let origin = position(of: box, in: geometry.size)
      messages
        .frame(width: box.width, height: box.height)
        .background(Color.black.opacity(opacity), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(resizingFrom == nil ? 0.08 : 0.35), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .overlay(alignment: gripAlignment) { grip(box: box, room: room) }
        .contextMenu { menu }
        .offset(x: origin.x + drag.width, y: origin.y + drag.height)
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
          stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14), .init(color: .black, location: 1)],
          startPoint: .top, endPoint: .bottom)
      )
      .allowsHitTesting(false)
  }

  // MARK: Resizing

  /// On the corner away from the one it's pinned to (pinned bottom left: top right).
  private var gripAlignment: Alignment {
    switch corner {
    case 0: return .bottomTrailing
    case 1: return .bottomLeading
    case 2: return .topTrailing
    default: return .topLeading
    }
  }

  /// Drag to resize: the pinned corner stays put, the box follows the finger.
  private func grip(box: CGSize, room: CGSize) -> some View {
    Image(systemName: "arrow.up.left.and.arrow.down.right")
      .font(.system(size: 10, weight: .bold))
      .foregroundColor(.white.opacity(resizingFrom == nil ? 0.75 : 1))
      .frame(width: 22, height: 22)
      .background(Color.black.opacity(0.55), in: Circle())
      .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .offset(x: corner % 2 == 0 ? 14 : -14, y: corner < 2 ? 14 : -14)
      .highPriorityGesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { value in
            let start = resizingFrom ?? box
            if resizingFrom == nil { resizingFrom = box }
            // Pinned on the left: dragging right widens it; pinned at the bottom: dragging up heightens it.
            let dx = corner % 2 == 0 ? value.translation.width : -value.translation.width
            let dy = corner < 2 ? value.translation.height : -value.translation.height
            resized = CGSize(
              width: min(max(start.width + dx, Self.minimum.width), room.width).rounded(),
              height: min(max(start.height + dy, Self.minimum.height), room.height).rounded())
          }
          .onEnded { _ in
            if let resized, room.width > 0, room.height > 0 {
              widthShare = Double(resized.width / room.width)
              heightShare = Double(resized.height / room.height)
            }
            resizingFrom = nil
            resized = nil
          }
      )
      .accessibilityLabel("Resize chat overlay")
  }

  @ViewBuilder
  private var menu: some View {
    Picker("Background", selection: $opacity) {
      Text("Clear").tag(0.15)
      Text("See-through").tag(0.4)
      Text("Dark").tag(0.65)
    }
    Button {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
        widthShare = Self.defaults.width
        heightShare = Self.defaults.height
      }
    } label: {
      Label("Reset size", systemImage: "arrow.counterclockwise")
    }
    Button {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { heightShare = 1 }
    } label: {
      Label("Full height", systemImage: "arrow.up.and.down")
    }
  }

  // MARK: Layout

  /// The most it can take: between the bars, clear of the edges.
  private func room(in area: CGSize) -> CGSize {
    CGSize(
      width: max(Self.minimum.width, area.width - clearance.leading - clearance.trailing - 16),
      height: max(Self.minimum.height, area.height - clearance.top - clearance.bottom - Self.barRoom.top - Self.barRoom.bottom))
  }

  private func boxSize(in room: CGSize) -> CGSize {
    CGSize(
      width: min(max(room.width * widthShare, Self.minimum.width), room.width).rounded(),
      height: min(max(room.height * heightShare, Self.minimum.height), room.height).rounded())
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
