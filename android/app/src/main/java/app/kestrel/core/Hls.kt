package app.kestrel.core

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

// HLS playlist parsing tuned for Twitch's usher / weaver playlists.
// Ad markers follow streamlink's Twitch plugin and TwitchAdSolutions (vaft).

object HlsDate {
    private val formatter: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

    fun format(millis: Long): String = formatter.format(Instant.ofEpochMilli(millis))
}

object Hls {
    fun lines(text: String): List<String> = text.split("\r\n", "\n", "\r")

    /** Parses `KEY=VALUE,KEY="quoted, value"` attribute lists (everything after the first ':'). */
    fun attributes(line: String): Map<String, String> {
        val result = HashMap<String, String>()
        val colon = line.indexOf(':')
        val list = if (colon >= 0) line.substring(colon + 1) else line
        var i = 0
        val n = list.length
        while (i < n) {
            val keyStart = i
            while (i < n && list[i] != '=' && list[i] != ',') i++
            val key = list.substring(keyStart, i).trim()
            if (i >= n || list[i] == ',') {
                i++
                continue
            }
            i++ // '='
            val value: String
            if (i < n && list[i] == '"') {
                i++
                val valueStart = i
                while (i < n && list[i] != '"') i++
                value = list.substring(valueStart, minOf(i, n))
                while (i < n && list[i] != ',') i++
            } else {
                val valueStart = i
                while (i < n && list[i] != ',') i++
                value = list.substring(valueStart, i).trim()
            }
            if (key.isNotEmpty()) result[key] = value
            i++
        }
        return result
    }

    fun codecFamily(codecs: String?): String {
        if (codecs == null) return "unknown"
        for (part in codecs.lowercase().split(',')) {
            val c = part.trim()
            if (c.startsWith("avc")) return "avc"
            if (c.startsWith("hev") || c.startsWith("hvc")) return "hevc"
            if (c.startsWith("av01")) return "av1"
        }
        return "unknown"
    }

    fun looksLikePlaylist(text: String): Boolean = text.trimStart('﻿', ' ', '\t', '\r', '\n').startsWith("#EXTM3U")

    val adSegmentPatterns = listOf("/adsquared/", "/_404/", "/processing")

    /** Tags that announce, describe or track ads. */
    fun isAdTag(line: String): Boolean {
        if (line.startsWith("#EXT-X-CUE") || line.startsWith("#EXT-X-SCTE35") || line.startsWith("#EXT-OATCLS-SCTE35") ||
            line.startsWith("#EXT-X-ASSET")
        ) {
            return true
        }
        if (!line.startsWith("#EXT-X-DATERANGE")) return false
        val lower = line.lowercase()
        if (lower.contains("stitched") || lower.contains("twitch-maf-ad") || lower.contains("x-tv-twitch-ad") ||
            lower.contains("twitch-ad") || lower.contains("scte35")
        ) {
            return true
        }
        // IVS-style source switches to an ad ("live" is the broadcast itself).
        return lower.contains("live-video-net-stream-source") && !lower.contains("stream-source=\"live\"")
    }

    /** `URI="…"` attributes made absolute. */
    fun absolutizeTag(line: String, base: String?): String {
        val start = line.indexOf("URI=\"")
        if (start < 0) return line
        val valueStart = start + 5
        val end = line.indexOf('"', valueStart)
        if (end < 0) return line
        return line.substring(0, valueStart) + resolveUrl(line.substring(valueStart, end), base) + line.substring(end)
    }
}

data class HlsVariant(
    val uri: String,
    val bandwidth: Int,
    val width: Int,
    val height: Int,
    val frameRate: Double,
    val codecs: String,
    val name: String,
    val isAudioOnly: Boolean,
    val isPortrait: Boolean,
) {
    val codecFamily: String get() = Hls.codecFamily(codecs)
    val resolution: String? get() = if (width > 0) "${width}x$height" else null

    /** "1080p60", "720p", "1440p60 HEVC", "Audio only" */
    val label: String
        get() {
            if (isAudioOnly) return "Audio only"
            val lines = minOf(width, height)
            val fps = if (frameRate > 31) Math.round(frameRate).toString() else ""
            return when (codecFamily) {
                "hevc" -> "${lines}p$fps HEVC"
                "av1" -> "${lines}p$fps AV1"
                else -> "${lines}p$fps"
            }
        }

    /** Among variants with the same resolution and frame rate, newer codecs look better at the same bitrate. */
    val codecRank: Int
        get() = when (codecFamily) {
            "hevc" -> 2
            "av1" -> 1
            else -> 0
        }

    /** The `#EXT-X-STREAM-INF` line for a master playlist Kestrel serves. */
    fun streamInf(): String {
        val attributes = mutableListOf("BANDWIDTH=${maxOf(bandwidth, 1)}")
        resolution?.let { attributes.add("RESOLUTION=$it") }
        if (codecs.isNotEmpty()) attributes.add("CODECS=\"$codecs\"")
        if (frameRate > 0) attributes.add("FRAME-RATE=" + String.format(java.util.Locale.US, "%.3f", frameRate))
        return "#EXT-X-STREAM-INF:" + attributes.joinToString(",")
    }
}

class HlsMaster(val variants: List<HlsVariant>) {
    /** Landscape video variants, best first. */
    val videoVariants: List<HlsVariant>
        get() = variants.filter { !it.isAudioOnly && !it.isPortrait }.sortedWith(
            compareByDescending<HlsVariant> { it.height }
                .thenByDescending { it.frameRate }
                .thenByDescending { it.codecRank }
                .thenByDescending { it.bandwidth },
        )

    val audioVariant: HlsVariant? get() = variants.firstOrNull { it.isAudioOnly }

    /** Picks the variant closest to `target`: same codec family, then resolution, then frame rate. */
    fun bestMatch(target: HlsVariant): HlsVariant? {
        val pool = if (target.isAudioOnly) variants.filter { it.isAudioOnly } else variants.filter { !it.isAudioOnly && !it.isPortrait }
        val candidates = pool.ifEmpty { variants }
        return candidates.minByOrNull { score(it, target) }
    }

    private fun score(v: HlsVariant, t: HlsVariant): Double {
        val sameCodec = v.codecFamily == t.codecFamily || v.codecFamily == "unknown" || t.codecFamily == "unknown"
        val pixels = Math.abs(v.width.toDouble() * v.height - t.width.toDouble() * t.height)
        return (if (sameCodec) 0.0 else 1e15) +
            (if (v.resolution == t.resolution) 0.0 else 1e12 + pixels) +
            (if (Math.abs(v.frameRate - t.frameRate) < 0.5) 0.0 else 1e9)
    }

    companion object {
        fun parse(text: String, base: String?): HlsMaster {
            val lines = Hls.lines(text)
            val mediaNames = HashMap<String, String>() // GROUP-ID -> NAME
            for (line in lines) {
                if (!line.startsWith("#EXT-X-MEDIA:")) continue
                val a = Hls.attributes(line)
                val group = a["GROUP-ID"]
                val name = a["NAME"]
                if (group != null && name != null) mediaNames[group] = name
            }
            val variants = mutableListOf<HlsVariant>()
            var i = 0
            while (i < lines.size) {
                val line = lines[i]
                if (line.startsWith("#EXT-X-STREAM-INF")) {
                    val a = Hls.attributes(line)
                    var j = i + 1
                    while (j < lines.size && (lines[j].isBlank() || lines[j].startsWith("#"))) {
                        if (lines[j].startsWith("#EXT-X-STREAM-INF")) break
                        j++
                    }
                    if (j < lines.size && !lines[j].startsWith("#")) {
                        var width = 0
                        var height = 0
                        a["RESOLUTION"]?.lowercase()?.split('x')?.let { parts ->
                            if (parts.size == 2) {
                                width = parts[0].toIntOrNull() ?: 0
                                height = parts[1].toIntOrNull() ?: 0
                            }
                        }
                        val stable = a["STABLE-VARIANT-ID"]?.lowercase() ?: ""
                        val group = a["VIDEO"] ?: ""
                        val codecs = a["CODECS"] ?: ""
                        val audioOnly = width == 0 &&
                            (stable.startsWith("audio") || group.startsWith("audio") || Hls.codecFamily(codecs) == "unknown")
                        val portrait = a["IVS-GROUPS"]?.lowercase() == "portrait" || stable.endsWith("portrait") ||
                            (height > width && width > 0)
                        val name = a["IVS-NAME"] ?: mediaNames[group] ?: a["STABLE-VARIANT-ID"] ?: ""
                        variants.add(
                            HlsVariant(
                                uri = resolveUrl(lines[j], base),
                                bandwidth = a["BANDWIDTH"]?.toIntOrNull() ?: 0,
                                width = width,
                                height = height,
                                frameRate = a["FRAME-RATE"]?.toDoubleOrNull() ?: 0.0,
                                codecs = codecs,
                                name = name,
                                isAudioOnly = audioOnly,
                                isPortrait = portrait,
                            ),
                        )
                        i = j
                    }
                }
                i++
            }
            return HlsMaster(variants)
        }
    }
}

data class HlsDateRange(val id: String, val cls: String, val start: Long?, val duration: Double?) {
    val isAd: Boolean
        get() = cls == "twitch-stitched-ad" || id.startsWith("stitched-ad") || cls == "twitch-maf-ad" ||
            cls == "live-video-net-stitched-ad"
}

data class HlsSegment(
    val uri: String,
    /** Seconds. */
    val duration: Double,
    val title: String,
    /** Program date-time, epoch milliseconds. */
    val pdt: Long?,
    val discontinuity: Boolean,
    val map: String?,
    val isPrefetch: Boolean,
    val isAd: Boolean,
) {
    val end: Long? get() = pdt?.let { it + (duration * 1000).toLong() }
}

class HlsMediaPlaylist {
    var targetDuration = 6.0
    var mediaSequence = 0
    val segments = mutableListOf<HlsSegment>()
    val dateRanges = mutableListOf<HlsDateRange>()
    var hasAdSignifier = false
    var isEnded = false

    val regularSegments: List<HlsSegment> get() = segments.filter { !it.isPrefetch }
    val adDateRanges: List<HlsDateRange> get() = dateRanges.filter { it.isAd }

    /** End of the newest complete (non-prefetch) segment. */
    val liveEdge: Long? get() = regularSegments.lastOrNull()?.end

    /** An ad is stitched into the video itself at the live edge. */
    val adBreakActive: Boolean get() = regularSegments.lastOrNull()?.isAd ?: false

    /** Twitch has marked an ad break (DATERANGE) at the live edge (usually a client-side ad). */
    val adMarkerActive: Boolean
        get() {
            val edge = liveEdge ?: return false
            return adDateRanges.any { range ->
                val start = range.start ?: return@any false
                val end = start + ((range.duration ?: 30.0) * 1000).toLong()
                start <= edge + 4000 && end > edge - 500
            }
        }

    /** No stitched ad segments (used to decide whether a backup copy is usable). */
    val isClean: Boolean get() = segments.none { it.isAd }

    companion object {
        fun parse(text: String, base: String?): HlsMediaPlaylist {
            val playlist = HlsMediaPlaylist()
            var pendingDuration: Double? = null
            var pendingTitle = ""
            var pendingPdt: Long? = null
            var pendingDiscontinuity = false
            var currentMap: String? = null
            var anyLiveTitle = false

            for (raw in Hls.lines(text)) {
                val line = raw.trim()
                if (line.isEmpty()) continue
                if (line.startsWith("#")) {
                    when {
                        line.startsWith("#EXTINF:") -> {
                            val value = line.substring("#EXTINF:".length)
                            val comma = value.indexOf(',')
                            val durationText = if (comma >= 0) value.substring(0, comma) else value
                            pendingDuration = durationText.trim().toDoubleOrNull() ?: 2.0
                            pendingTitle = if (comma >= 0) value.substring(comma + 1) else ""
                            if (pendingTitle.startsWith("live")) anyLiveTitle = true
                        }
                        line.startsWith("#EXT-X-PROGRAM-DATE-TIME:") ->
                            pendingPdt = parseDate(line.substring("#EXT-X-PROGRAM-DATE-TIME:".length))
                        line.startsWith("#EXT-X-DISCONTINUITY-SEQUENCE") -> Unit
                        line.startsWith("#EXT-X-DISCONTINUITY") -> pendingDiscontinuity = true
                        line.startsWith("#EXT-X-TARGETDURATION:") ->
                            playlist.targetDuration = line.substring("#EXT-X-TARGETDURATION:".length).trim().toDoubleOrNull() ?: 6.0
                        line.startsWith("#EXT-X-MEDIA-SEQUENCE:") ->
                            playlist.mediaSequence = line.substring("#EXT-X-MEDIA-SEQUENCE:".length).trim().toIntOrNull() ?: 0
                        line.startsWith("#EXT-X-MAP:") ->
                            Hls.attributes(line)["URI"]?.let { currentMap = resolveUrl(it, base) }
                        line.startsWith("#EXT-X-DATERANGE:") -> {
                            val a = Hls.attributes(line)
                            playlist.dateRanges.add(
                                HlsDateRange(
                                    id = a["ID"] ?: "",
                                    cls = a["CLASS"] ?: "",
                                    start = parseDate(a["START-DATE"]),
                                    duration = a["DURATION"]?.toDoubleOrNull() ?: a["PLANNED-DURATION"]?.toDoubleOrNull(),
                                ),
                            )
                        }
                        line.startsWith("#EXT-X-TWITCH-PREFETCH:") -> {
                            val uri = resolveUrl(line.substring("#EXT-X-TWITCH-PREFETCH:".length), base)
                            val last = playlist.segments.lastOrNull()
                            if (last != null) {
                                val regular = playlist.segments.filter { !it.isPrefetch }
                                val average = if (regular.isEmpty()) last.duration else regular.sumOf { it.duration } / regular.size
                                val duration = if (last.isPrefetch) last.duration else average
                                playlist.segments.add(
                                    HlsSegment(uri, duration, "", last.end, false, currentMap, isPrefetch = true, isAd = false),
                                )
                            }
                        }
                        line.startsWith("#EXT-X-ENDLIST") -> playlist.isEnded = true
                    }
                    if (line.contains("stitched-ad") || line.contains("EXT-X-CUE-OUT") || line.contains("twitch-stitched") ||
                        line.contains("live-video-net-stitched") || line.contains("twitch-maf-ad") ||
                        line.contains("twitch-trigger")
                    ) {
                        playlist.hasAdSignifier = true
                    }
                    continue
                }
                // A segment's address.
                val duration = pendingDuration ?: continue
                var pdt = pendingPdt
                if (pdt == null) pdt = playlist.segments.lastOrNull()?.end
                playlist.segments.add(
                    HlsSegment(resolveUrl(line, base), duration, pendingTitle, pdt, pendingDiscontinuity, currentMap, false, false),
                )
                pendingDuration = null
                pendingTitle = ""
                pendingPdt = null
                pendingDiscontinuity = false
            }

            // Ad classification: only segments that really contain ad video count. Live video is
            // titled "live"; stitched ads get another title and come with an ad marker. A DATERANGE
            // over "live" segments is a client-side break, not an ad segment.
            for (index in playlist.segments.indices) {
                val segment = playlist.segments[index]
                val title = segment.title.trim()
                val byTitle = title.contains("Amazon")
                val byUrl = Hls.adSegmentPatterns.any { segment.uri.contains(it) }
                val byLiveTitle = !segment.isPrefetch && playlist.hasAdSignifier && !title.startsWith("live") &&
                    (anyLiveTitle || title.isNotEmpty())
                var isAd = byTitle || byUrl || byLiveTitle
                if (segment.isPrefetch && index > 0 && playlist.segments[index - 1].isAd) isAd = true
                if (isAd != segment.isAd) playlist.segments[index] = segment.copy(isAd = isAd)
            }
            return playlist
        }
    }
}

/** Rewriting Twitch's media playlists. */
object PlaylistFilter {
    /** Removes ad markers (and optionally the prefetch hints) and makes every address absolute. */
    fun filter(text: String, base: String?, dropPrefetch: Boolean): String {
        val output = StringBuilder()
        for (raw in Hls.lines(text)) {
            val line = raw.trimEnd('\r')
            when {
                line.startsWith("#") -> {
                    if (Hls.isAdTag(line)) continue
                    if (line.startsWith("#EXT-X-TWITCH-PREFETCH:")) {
                        if (dropPrefetch) continue
                        output.append("#EXT-X-TWITCH-PREFETCH:")
                            .append(resolveUrl(line.substring("#EXT-X-TWITCH-PREFETCH:".length), base)).append('\n')
                        continue
                    }
                    output.append(Hls.absolutizeTag(line, base)).append('\n')
                }
                line.isBlank() -> output.append(line).append('\n')
                else -> output.append(resolveUrl(line, base)).append('\n')
            }
        }
        return output.toString()
    }
}
