package app.kestrel.core

import java.util.Locale

// The live playlist the player sees is put together here rather than passed through.
//
// Every segment the player is given becomes a "slot" with Kestrel's own, ever-increasing sequence
// number. Slots are filled from whichever source is ad-free at the time (the main stream, or a
// backup copy of the same stream requested with a different player type) and merged by
// program-date-time, so switching sources mid-stream never confuses the player: it just sees a
// discontinuity. Slots are shared by every quality level, so adaptive quality keeps working.

sealed class SlotSource {
    object Main : SlotSource() {
        override fun toString() = "main"
    }

    data class Backup(val type: String) : SlotSource() {
        override fun toString() = type
    }
}

data class Slot(
    val seq: Int,
    /** Epoch milliseconds. */
    val pdt: Long,
    /** Seconds. */
    val duration: Double,
    val source: SlotSource,
    val isAd: Boolean,
    val discontinuity: Boolean,
    /** Discontinuity sequence number of this slot. */
    val dseq: Int,
    val isPrefetch: Boolean,
) {
    val end: Long get() = pdt + (duration * 1000).toLong()
}

/** Segments seen in one playlist (one quality of one source), kept a few minutes so slots stay resolvable. */
class SegmentStore {
    data class Entry(
        val uri: String,
        var pdt: Long,
        var estimatedPdt: Long?,
        var duration: Double,
        val map: String?,
        var isAd: Boolean,
        var isPrefetch: Boolean,
    )

    private val entries = ArrayList<Entry>()
    private val index = HashMap<String, Int>()

    fun record(segments: List<HlsSegment>) {
        for (segment in segments) {
            val pdt = segment.pdt ?: continue
            val existing = index[segment.uri]
            if (existing != null) {
                val entry = entries[existing]
                if (entry.isPrefetch && !segment.isPrefetch) {
                    // Prefetch promoted to a regular segment: keep the estimate so slots built from it still match.
                    entry.estimatedPdt = entry.pdt
                    entry.pdt = pdt
                    entry.duration = segment.duration
                    entry.isPrefetch = false
                }
                entry.isAd = entry.isAd || segment.isAd
            } else {
                index[segment.uri] = entries.size
                entries.add(Entry(segment.uri, pdt, null, segment.duration, segment.map, segment.isAd, segment.isPrefetch))
            }
        }
        if (entries.size > 240) {
            val keep = ArrayList(entries.subList(entries.size - 180, entries.size))
            entries.clear()
            entries.addAll(keep)
            index.clear()
            entries.forEachIndexed { i, entry -> index[entry.uri] = i }
        }
    }

    fun lookup(slot: Slot): Entry? {
        val tolerance = maxOf(0.3, minOf(slot.duration, 4.0) * 0.4) * 1000
        var best: Entry? = null
        var bestDistance = Double.MAX_VALUE
        for (i in entries.indices.reversed()) {
            val entry = entries[i]
            var distance = Math.abs(entry.pdt - slot.pdt).toDouble()
            entry.estimatedPdt?.let { distance = minOf(distance, Math.abs(it - slot.pdt).toDouble()) }
            if (distance < bestDistance) {
                bestDistance = distance
                best = entry
            }
            if (entry.pdt < slot.pdt - 60_000) break
        }
        return if (bestDistance <= tolerance) best else null
    }

    fun contains(slot: Slot): Boolean = lookup(slot) != null
}

class SlotTimeline {
    val slots = ArrayList<Slot>()
    private var discontinuityCount = 0
    private var nextSeq: Int? = null
    private val slotted = HashSet<String>()
    private val slottedOrder = ArrayDeque<String>()

    val isEmpty: Boolean get() = slots.isEmpty()

    fun setInitialSequence(sequence: Int) {
        if (nextSeq == null) nextSeq = maxOf(0, sequence)
    }

    /** Appends segments newer than the last slot. Returns how many were added. */
    fun append(candidates: List<HlsSegment>, source: SlotSource): Int {
        var added = 0
        val sorted = candidates.filter { it.pdt != null }.sortedBy { it.pdt }
        for (candidate in sorted) {
            val pdt = candidate.pdt ?: continue
            if (slotted.contains(candidate.uri)) continue
            var discontinuity = false
            val last = slots.lastOrNull()
            if (last != null) {
                val minimumNext = last.pdt + (maxOf(0.3, last.duration * 0.5) * 1000).toLong()
                if (pdt < minimumNext) continue
                val gap = (pdt - last.end) / 1000.0
                discontinuity = when {
                    last.source != source || last.isAd != candidate.isAd -> true
                    candidate.discontinuity && !candidate.isPrefetch -> true
                    gap > maxOf(1.0, last.duration * 0.6) -> true
                    else -> false
                }
            }
            if (discontinuity) discontinuityCount++
            val seq = nextSeq ?: 0
            nextSeq = seq + 1
            slots.add(Slot(seq, pdt, candidate.duration, source, candidate.isAd, discontinuity, discontinuityCount, candidate.isPrefetch))
            slotted.add(candidate.uri)
            slottedOrder.addLast(candidate.uri)
            added++
        }
        if (slots.size > 120) {
            val keep = ArrayList(slots.subList(slots.size - 90, slots.size))
            slots.clear()
            slots.addAll(keep)
        }
        if (slottedOrder.size > 600) {
            while (slottedOrder.size > 400) slotted.remove(slottedOrder.removeFirst())
        }
        return added
    }

    /** Contiguous ranges of slots that are ads shown as a last resort (the player mutes and covers them). */
    val adRanges: List<LongRange>
        get() {
            val ranges = mutableListOf<LongRange>()
            var start: Long? = null
            var end: Long? = null
            for (slot in slots) {
                if (slot.isAd) {
                    if (start == null) start = slot.pdt
                    end = slot.end
                } else if (start != null && end != null) {
                    ranges.add(start..end)
                    start = null
                    end = null
                }
            }
            if (start != null && end != null) ranges.add(start..end)
            return ranges
        }

    /** A media playlist for one quality. `resolve` maps a slot to that quality's segment (null if unknown). */
    fun render(window: Int, targetDuration: Int, resolve: (Slot) -> SegmentStore.Entry?): String? {
        if (slots.isEmpty()) return null
        val start = maxOf(0, slots.size - window)
        val rendered = mutableListOf<Pair<Slot, SegmentStore.Entry>>()
        for (k in start until slots.size) {
            val slot = slots[k]
            val entry = resolve(slot)
            if (entry == null) {
                if (rendered.isEmpty()) continue // leading gap: just start later
                break // never skip a slot in the middle: the sequence numbers would lie
            }
            val previous = rendered.lastOrNull()
            if (previous != null && previous.second.map != null && entry.map == null) break
            rendered.add(slot to entry)
        }
        val first = rendered.firstOrNull() ?: return null
        val usesMap = rendered.any { it.second.map != null }
        val out = StringBuilder()
        out.append("#EXTM3U\n")
        out.append("#EXT-X-VERSION:").append(if (usesMap) 6 else 3).append('\n')
        out.append("#EXT-X-TARGETDURATION:").append(targetDuration).append('\n')
        out.append("#EXT-X-MEDIA-SEQUENCE:").append(first.first.seq).append('\n')
        out.append("#EXT-X-DISCONTINUITY-SEQUENCE:").append(first.first.dseq).append('\n')
        var previousMap: String? = null
        rendered.forEachIndexed { i, (slot, entry) ->
            val discontinuity = i > 0 && slot.discontinuity
            if (discontinuity) out.append("#EXT-X-DISCONTINUITY\n")
            val map = entry.map
            if (map != null && (map != previousMap || discontinuity)) out.append("#EXT-X-MAP:URI=\"").append(map).append("\"\n")
            previousMap = map
            out.append("#EXT-X-PROGRAM-DATE-TIME:").append(HlsDate.format(slot.pdt)).append('\n')
            out.append("#EXTINF:").append(String.format(Locale.US, "%.3f", slot.duration)).append(',')
                .append(if (slot.isAd) "ad" else "live").append('\n')
            out.append(entry.uri).append('\n')
        }
        return out.toString()
    }
}
