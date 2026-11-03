// The playlist AVPlayer sees is synthesized here rather than passed through.
//
// Every segment the player is given becomes a "slot" with our own, ever-increasing sequence
// number. Slots are filled from whichever source is ad-free at the time (the main stream, or a
// backup copy of the same stream requested with a different player type) and merged by
// program-date-time, so switching sources mid-stream never confuses the player: it just sees a
// discontinuity. Because slots are shared by every quality level, adaptive bitrate switching
// keeps working.

import Foundation

enum SlotSource: Hashable, CustomStringConvertible {
  case main
  case backup(String)

  var description: String {
    switch self {
    case .main: return "main"
    case .backup(let type): return type
    }
  }
}

struct Slot: Equatable {
  var seq: Int
  var pdt: Date
  var duration: Double
  var source: SlotSource
  var isAd: Bool
  var discontinuity: Bool
  /// Discontinuity sequence number of this slot (number of discontinuities up to and including it).
  var dseq: Int
  var isPrefetch: Bool
  var end: Date { pdt.addingTimeInterval(duration) }
}

/// Segments seen in one playlist (one quality level of one source), kept for a few minutes so
/// slots stay resolvable after Twitch drops them from its own window.
struct SegmentStore {
  struct Entry {
    var uri: String
    var pdt: Date
    var estimatedPDT: Date?
    var duration: Double
    var map: String?
    var isAd: Bool
    var isPrefetch: Bool
  }

  private(set) var entries: [Entry] = []
  private var index: [String: Int] = [:]

  mutating func record(_ segments: [HLSSegment]) {
    for segment in segments {
      guard let pdt = segment.pdt else { continue }
      if let i = index[segment.uri] {
        var entry = entries[i]
        if entry.isPrefetch && !segment.isPrefetch {
          // Prefetch promoted to a regular segment: keep the estimate so slots built from it still match.
          entry.estimatedPDT = entry.pdt
          entry.pdt = pdt
          entry.duration = segment.duration
          entry.isPrefetch = false
        }
        entry.isAd = entry.isAd || segment.isAd
        entries[i] = entry
      } else {
        index[segment.uri] = entries.count
        entries.append(
          Entry(
            uri: segment.uri, pdt: pdt, estimatedPDT: nil, duration: segment.duration, map: segment.map,
            isAd: segment.isAd, isPrefetch: segment.isPrefetch))
      }
    }
    if entries.count > 240 {
      entries.removeFirst(entries.count - 180)
      index = [:]
      for (i, entry) in entries.enumerated() { index[entry.uri] = i }
    }
  }

  func lookup(_ slot: Slot) -> Entry? {
    let tolerance = max(0.3, min(slot.duration, 4) * 0.4)
    var best: Entry?
    var bestDistance = Double.infinity
    for entry in entries.reversed() {
      var distance = abs(entry.pdt.timeIntervalSince(slot.pdt))
      if let estimate = entry.estimatedPDT { distance = min(distance, abs(estimate.timeIntervalSince(slot.pdt))) }
      if distance < bestDistance {
        bestDistance = distance
        best = entry
      }
      if entry.pdt < slot.pdt.addingTimeInterval(-60) { break }
    }
    return bestDistance <= tolerance ? best : nil
  }

  func contains(_ slot: Slot) -> Bool { lookup(slot) != nil }
}

struct SlotTimeline {
  private(set) var slots: [Slot] = []
  private(set) var discontinuityCount = 0
  private var nextSeq: Int?
  private var slotted: Set<String> = []
  private var slottedOrder: [String] = []

  var last: Slot? { slots.last }
  var isEmpty: Bool { slots.isEmpty }

  mutating func setInitialSequence(_ sequence: Int) {
    if nextSeq == nil { nextSeq = max(0, sequence) }
  }

  /// Appends segments newer than the last slot. Returns how many were added.
  @discardableResult
  mutating func append(_ candidates: [HLSSegment], source: SlotSource) -> Int {
    var added = 0
    let sorted = candidates.filter { $0.pdt != nil }.sorted { $0.pdt! < $1.pdt! }
    for candidate in sorted {
      guard let pdt = candidate.pdt, !slotted.contains(candidate.uri) else { continue }
      var discontinuity = false
      if let last = slots.last {
        let minimumNext = last.pdt.addingTimeInterval(max(0.3, last.duration * 0.5))
        if pdt < minimumNext { continue }
        let gap = pdt.timeIntervalSince(last.end)
        if last.source != source || last.isAd != candidate.isAd {
          discontinuity = true
        } else if candidate.discontinuity && !candidate.isPrefetch {
          discontinuity = true
        } else if gap > max(1.0, last.duration * 0.6) {
          discontinuity = true
        }
      }
      if discontinuity { discontinuityCount += 1 }
      let seq = nextSeq ?? 0
      nextSeq = seq + 1
      slots.append(
        Slot(
          seq: seq, pdt: pdt, duration: candidate.duration, source: source, isAd: candidate.isAd,
          discontinuity: discontinuity, dseq: discontinuityCount, isPrefetch: candidate.isPrefetch))
      slotted.insert(candidate.uri)
      slottedOrder.append(candidate.uri)
      added += 1
    }
    if slots.count > 120 { slots.removeFirst(slots.count - 90) }
    if slottedOrder.count > 600 {
      let drop = slottedOrder.prefix(slottedOrder.count - 400)
      for uri in drop { slotted.remove(uri) }
      slottedOrder.removeFirst(drop.count)
    }
    return added
  }

  /// Contiguous ranges of slots that are ads shown as a last resort (the UI mutes/covers them).
  var adRanges: [ClosedRange<Date>] {
    var ranges: [ClosedRange<Date>] = []
    var start: Date?
    var end: Date?
    for slot in slots {
      if slot.isAd {
        if start == nil { start = slot.pdt }
        end = slot.end
      } else if let s = start, let e = end {
        ranges.append(s...e)
        start = nil
        end = nil
      }
    }
    if let s = start, let e = end { ranges.append(s...e) }
    return ranges
  }

  /// Renders a media playlist for one quality level.
  /// - Parameter resolve: maps a slot to the concrete segment of this quality level (nil if unknown).
  func render(window: Int, targetDuration: Int, resolve: (Slot) -> SegmentStore.Entry?) -> String? {
    guard !slots.isEmpty else { return nil }
    let start = max(0, slots.count - window)
    var rendered: [(Slot, SegmentStore.Entry)] = []
    for slot in slots[start...] {
      guard let entry = resolve(slot) else {
        if rendered.isEmpty { continue }  // leading gap: just start later
        break  // never skip a slot in the middle: the sequence numbers would lie
      }
      if let previous = rendered.last, previous.1.map != nil, entry.map == nil {
        break  // fMP4 -> TS without a new init segment isn't representable
      }
      rendered.append((slot, entry))
    }
    guard let first = rendered.first else { return nil }

    let usesMap = rendered.contains { $0.1.map != nil }
    var lines = [
      "#EXTM3U",
      "#EXT-X-VERSION:\(usesMap ? 6 : 3)",
      "#EXT-X-TARGETDURATION:\(targetDuration)",
      "#EXT-X-MEDIA-SEQUENCE:\(first.0.seq)",
      "#EXT-X-DISCONTINUITY-SEQUENCE:\(first.0.dseq)",
    ]
    var previousMap: String?
    for (index, (slot, entry)) in rendered.enumerated() {
      let discontinuity = index > 0 && slot.discontinuity
      if discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
      if let map = entry.map, map != previousMap || discontinuity {
        lines.append("#EXT-X-MAP:URI=\"\(map)\"")
      }
      previousMap = entry.map
      lines.append("#EXT-X-PROGRAM-DATE-TIME:\(HLSDate.format(slot.pdt))")
      lines.append("#EXTINF:\(String(format: "%.3f", slot.duration)),\(slot.isAd ? "ad" : "live")")
      lines.append(entry.uri)
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

/// Where stitched-in ad segments sit in time, for a player that loads Twitch's playlists itself
/// (the low-latency player). Kestrel polls the same playlist and hides the picture while the
/// playhead is inside one of these ranges.
struct AdTimeline {
  private(set) var ranges: [ClosedRange<Date>] = []
  /// Start of a stitched break that is still running at the live edge.
  private(set) var openStart: Date?
  /// Twitch marked an ad break (usually delivered client-side, so nothing to hide).
  private(set) var markerActive = false
  private var lastAdEnd: Date?

  mutating func update(with playlist: HLSMediaPlaylist, now: Date = Date()) {
    markerActive = playlist.adMarkerActive
    // (Prefetch ones too: the player is fetching those already.)
    for segment in playlist.segments where segment.isAd {
      guard let start = segment.pdt, let end = segment.end else { continue }
      insert(start...end)
      lastAdEnd = max(lastAdEnd ?? end, end)
    }
    if playlist.adBreakActive {
      // Start of the trailing run of ad segments.
      var start: Date?
      for segment in playlist.regularSegments.reversed() {
        guard segment.isAd else { break }
        start = segment.pdt ?? start
      }
      openStart = start ?? openStart ?? now
    } else {
      openStart = nil
    }
    ranges.removeAll { $0.upperBound < now.addingTimeInterval(-180) }
  }

  /// Whether the frame stamped `date` belongs to an ad.
  func covers(_ date: Date, margin: TimeInterval = 0.5) -> Bool {
    if let openStart, date >= openStart.addingTimeInterval(-margin) { return true }
    return ranges.contains { date >= $0.lowerBound.addingTimeInterval(-margin) && date <= $0.upperBound.addingTimeInterval(margin) }
  }

  var isActive: Bool { openStart != nil }

  /// Hides these ad segments (the ones the player got before it switched to an ad-free copy).
  mutating func cover(_ segments: [HLSSegment]) {
    for segment in segments {
      guard let start = segment.pdt, let end = segment.end else { continue }
      insert(start...end)
    }
  }

  /// The player switched to an ad-free copy: only what it already got from the ad needs hiding.
  mutating func closeOpenBreak() {
    guard let start = openStart else { return }
    openStart = nil
    if let end = lastAdEnd, end > start { insert(start...end) }
  }

  private mutating func insert(_ range: ClosedRange<Date>) {
    var merged = range
    ranges.removeAll { other in
      let touches = other.lowerBound <= merged.upperBound.addingTimeInterval(0.5)
        && other.upperBound >= merged.lowerBound.addingTimeInterval(-0.5)
      if touches {
        merged = min(other.lowerBound, merged.lowerBound)...max(other.upperBound, merged.upperBound)
      }
      return touches
    }
    ranges.append(merged)
    ranges.sort { $0.lowerBound < $1.lowerBound }
  }
}
