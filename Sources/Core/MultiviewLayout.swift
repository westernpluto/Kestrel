// Where each picture goes in multi-view, the way multi-stream sites (MultiTwitch, Twitch Theater,
// multistre.am) arrange them: every picture 16:9 and as big as the space allows.

import Foundation

#if canImport(CoreGraphics)
  import CoreGraphics
#endif

enum MultiviewLayout {
  /// Equal pictures in whichever grid makes them biggest (two side by side when wide, stacked when
  /// tall, 2×2 for four…), centred; a last row that isn't full is centred too.
  static func grid(count: Int, in size: CGSize, spacing: CGFloat = 2) -> [CGRect] {
    guard count > 0, size.width > 1, size.height > 1 else { return [] }
    var best = (columns: 1, rows: count, width: CGFloat(0))
    for columns in 1...count {
      let rows = (count + columns - 1) / columns
      let width = min(
        (size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns),
        (size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows) * 16 / 9)
      if width > best.width + 0.5 { best = (columns, rows, width) }
    }
    let width = best.width.rounded(.down)
    let height = (width * 9 / 16).rounded(.down)
    let total = CGFloat(best.rows) * height + spacing * CGFloat(best.rows - 1)
    let top = ((size.height - total) / 2).rounded()
    var rects: [CGRect] = []
    for row in 0..<best.rows {
      let first = row * best.columns
      let inRow = min(best.columns, count - first)
      let rowWidth = CGFloat(inRow) * width + spacing * CGFloat(inRow - 1)
      let left = ((size.width - rowWidth) / 2).rounded()
      for column in 0..<inRow {
        rects.append(
          CGRect(
            x: left + CGFloat(column) * (width + spacing), y: top + CGFloat(row) * (height + spacing), width: width,
            height: height))
      }
    }
    return rects
  }

  /// One big picture (`main`) with the others in a strip beside it or under it (whichever leaves
  /// the big one bigger), all centred. Same order as given.
  static func focus(count: Int, main: Int, in size: CGSize, spacing: CGFloat = 2) -> [CGRect] {
    guard count > 1, main >= 0, main < count, size.width > 1, size.height > 1 else {
      return grid(count: count, in: size, spacing: spacing)
    }
    let others = CGFloat(count - 1)
    let gaps = spacing * (others - 1)
    // A column of small pictures on the right.
    let columnWidth = min(size.width * 0.3, (size.height - gaps) / others * 16 / 9).rounded(.down)
    let besideWidth = min(size.width - columnWidth - spacing, size.height * 16 / 9).rounded(.down)
    // A row of small pictures underneath.
    let rowHeight = min(size.height * 0.3, (size.width - gaps) / others * 9 / 16).rounded(.down)
    let aboveWidth = min(size.width, (size.height - rowHeight - spacing) * 16 / 9).rounded(.down)
    var big: CGRect
    var small: [CGRect] = []
    if besideWidth >= aboveWidth {
      let bigHeight = (besideWidth * 9 / 16).rounded(.down)
      let smallHeight = (columnWidth * 9 / 16).rounded(.down)
      let left = ((size.width - besideWidth - spacing - columnWidth) / 2).rounded()
      big = CGRect(x: left, y: ((size.height - bigHeight) / 2).rounded(), width: besideWidth, height: bigHeight)
      let column = smallHeight * others + gaps
      let top = ((size.height - column) / 2).rounded()
      for index in 0..<(count - 1) {
        small.append(
          CGRect(
            x: big.maxX + spacing, y: top + CGFloat(index) * (smallHeight + spacing), width: columnWidth, height: smallHeight))
      }
    } else {
      let bigHeight = (aboveWidth * 9 / 16).rounded(.down)
      let smallWidth = (rowHeight * 16 / 9).rounded(.down)
      let top = ((size.height - bigHeight - spacing - rowHeight) / 2).rounded()
      big = CGRect(x: ((size.width - aboveWidth) / 2).rounded(), y: top, width: aboveWidth, height: bigHeight)
      let row = smallWidth * others + gaps
      let left = ((size.width - row) / 2).rounded()
      for index in 0..<(count - 1) {
        small.append(
          CGRect(x: left + CGFloat(index) * (smallWidth + spacing), y: big.maxY + spacing, width: smallWidth, height: rowHeight))
      }
    }
    var rects: [CGRect] = []
    var next = small.makeIterator()
    for index in 0..<count {
      rects.append(index == main ? big : (next.next() ?? .zero))
    }
    return rects
  }

  /// The smallest of Twitch's usual picture heights that still looks sharp in a picture `points`
  /// tall (nil: any); a picture that isn't being listened to settles for a little less.
  static func heightCap(points: CGFloat, scale: CGFloat, heard: Bool) -> Int? {
    let pixels = points * scale * (heard ? 1 : 0.75)
    for height in [360, 480, 720] where CGFloat(height) >= pixels { return height }
    return nil
  }
}
