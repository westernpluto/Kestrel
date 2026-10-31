// Full screen with chat put away: chat over the video, read-only, like Twitch's chat overlay.
//
// Where it goes follows the picture, not the screen. When the picture leaves a good band of black
// beside it (iPhone Duo's inner display held upright, or a wide screen around a 16:9 picture),
// chat fills that band and covers none of the video. Otherwise it's a see-through box in a corner
// of the picture itself, a small margin from its edges, stepping clear of the controls only while
// they're showing (so most of the time it sits right in the corner). Drag it to another corner;
// drag the grip on its inner corner (shown with the controls) to resize it; hold it for how
// see-through it is.

import SwiftUI

struct ChatOverlay: View {
  let chat: ChatController
  /// The controls' insets from the video area's edges (the camera, the bars).
  var clearance: EdgeInsets
  /// Where the picture sits in the area (iPhone Duo's outer screen keeps it clear of the camera).
  var pictureInsets = EdgeInsets()
  /// The picture fills the whole area (zoomed).
  var fill = false
  /// The controls are on screen: keep clear of their bars.
  var controlsShown = true
  /// A tap on the overlay counts as a tap on the video (shows or hides the controls).
  var tap: () -> Void
  /// 0 top left, 1 top right, 2 bottom left, 3 bottom right.
  @AppStorage("chatOverlay.corner") private var corner = 2
  @AppStorage("chatOverlay.opacity") private var opacity = 0.4
  /// Its size, as shares of the room it can have (so it fits whichever screen it's on).
  @AppStorage("chatOverlay.width.v2") private var widthShare = 0.36
  @AppStorage("chatOverlay.height.v2") private var heightShare = 0.55
  @State private var drag: CGSize = .zero
  /// The grip being dragged: the size it started at.
  @State private var resizingFrom: CGSize?
  @State private var resized: CGSize?

  private static let margin: CGFloat = 10
  /// Room the controls' top bar and bottom row (with a seek bar) take from the area's edges.
  private static let barRoom: (top: CGFloat, bottom: CGFloat) = (46, 74)
  private static let minimum = CGSize(width: 170, height: 90)
  private static let defaults = (width: 0.36, height: 0.55)
  /// A band of black this deep beside the picture is room enough for chat of its own.
  private static let band: (vertical: CGFloat, horizontal: CGFloat) = (140, 220)

  var body: some View {
    GeometryReader { geometry in
      let picture = pictureRect(in: geometry.size)
      if let band = band(in: geometry.size, picture: picture) {
        messages
          .padding(.horizontal, 4)
          .frame(width: band.width, height: band.height)
          .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .contentShape(Rectangle())
          .onTapGesture(perform: tap)
          .offset(x: band.minX, y: band.minY)
          .animation(.spring(response: 0.35, dampingFraction: 0.88), value: band)
      } else {
        floating(in: geometry.size, picture: picture)
      }
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

  // MARK: Where the picture is

  /// The picture: the area less its insets, then a 16:9 frame fitted inside (or all of it, zoomed).
  private func pictureRect(in area: CGSize) -> CGRect {
    let full = CGRect(origin: .zero, size: area)
    guard !fill else { return full }
    let inner = CGRect(
      x: pictureInsets.leading, y: pictureInsets.top,
      width: max(0, area.width - pictureInsets.leading - pictureInsets.trailing),
      height: max(0, area.height - pictureInsets.top - pictureInsets.bottom))
    guard inner.width > 0, inner.height > 0 else { return full }
    let width = min(inner.width, inner.height * 16 / 9)
    let height = width * 9 / 16
    return CGRect(x: inner.midX - width / 2, y: inner.midY - height / 2, width: width, height: height).integral
  }

  /// A band of black beside the picture deep enough for chat (below it first): chat fills it,
  /// clear of the controls' bars while they show.
  private func band(in area: CGSize, picture: CGRect) -> CGRect? {
    let m = Self.margin
    let below = area.height - picture.maxY
    let above = picture.minY
    let left = picture.minX
    let right = area.width - picture.maxX
    let leading = max(clearance.leading, m)
    let trailing = max(clearance.trailing, m)
    let topLimit = controlsShown ? clearance.top + Self.barRoom.top : max(clearance.top, m)
    let bottomLimit = area.height - (controlsShown ? clearance.bottom + Self.barRoom.bottom : max(clearance.bottom, m))
    if below >= Self.band.vertical {
      let top = picture.maxY + m
      guard bottomLimit - top >= Self.minimum.height else { return nil }
      return CGRect(x: leading, y: top, width: area.width - leading - trailing, height: bottomLimit - top)
    }
    if above >= Self.band.vertical {
      let bottom = picture.minY - m
      guard bottom - topLimit >= Self.minimum.height else { return nil }
      return CGRect(x: leading, y: topLimit, width: area.width - leading - trailing, height: bottom - topLimit)
    }
    if max(left, right) >= Self.band.horizontal {
      let onRight = right >= left
      let x = onRight ? picture.maxX + m : leading
      let width = onRight ? area.width - trailing - x : picture.minX - m - x
      guard width >= Self.minimum.width, bottomLimit - topLimit >= Self.minimum.height else { return nil }
      return CGRect(x: x, y: topLimit, width: width, height: bottomLimit - topLimit)
    }
    return nil
  }

  // MARK: Over the picture

  @ViewBuilder
  private func floating(in area: CGSize, picture: CGRect) -> some View {
    let room = room(in: area, picture: picture)
    let box = resized ?? boxSize(in: room.size)
    let origin = position(of: box, in: room)
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
            let newCorner = (x > room.midX ? 1 : 0) + (y > room.midY ? 2 : 0)
            let landing = position(of: box, in: room, corner: newCorner)
            // Keep it where the finger left it, then let it glide into the corner.
            drag = CGSize(width: origin.x + value.translation.width - landing.x, height: origin.y + value.translation.height - landing.y)
            corner = newCorner
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { drag = .zero }
          }
      )
      .overlay(alignment: gripAlignment) {
        grip(box: box, room: room.size)
          .opacity(controlsShown || resizingFrom != nil ? 1 : 0)
          .allowsHitTesting(controlsShown)
      }
      .contextMenu { menu }
      .offset(x: origin.x + drag.width, y: origin.y + drag.height)
      .animation(.spring(response: 0.35, dampingFraction: 0.88), value: room)
  }

  /// The most the box can take: the picture (less a margin), and only while the controls show,
  /// out from under their bars.
  private func room(in area: CGSize, picture: CGRect) -> CGRect {
    let m = Self.margin
    var top = picture.minY + m
    var bottom = picture.maxY - m
    if controlsShown {
      top = max(top, clearance.top + Self.barRoom.top)
      bottom = min(bottom, area.height - clearance.bottom - Self.barRoom.bottom)
    }
    let left = max(picture.minX + m, clearance.leading)
    let right = min(picture.maxX - m, area.width - clearance.trailing)
    return CGRect(x: left, y: top, width: max(Self.minimum.width, right - left), height: max(Self.minimum.height, bottom - top))
  }

  private func boxSize(in room: CGSize) -> CGSize {
    CGSize(
      width: min(max(room.width * widthShare, Self.minimum.width), room.width).rounded(),
      height: min(max(room.height * heightShare, Self.minimum.height), room.height).rounded())
  }

  private func position(of box: CGSize, in room: CGRect, corner: Int? = nil) -> CGPoint {
    let corner = corner ?? self.corner
    let left = room.minX
    let right = room.maxX - box.width
    let top = room.minY
    let bottom = room.maxY - box.height
    return CGPoint(x: corner % 2 == 0 ? left : right, y: corner < 2 ? top : max(top, bottom))
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
}
