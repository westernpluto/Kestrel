package app.kestrel.core

import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import org.json.JSONArray
import java.net.URLEncoder
import java.util.UUID
import kotlin.random.Random

/** Something the player loads playlists from (a live stream session, a VOD). */
interface PlaylistSource {
    val id: String

    /** The master playlist: just rendition `only`, or every rendition (null). */
    suspend fun masterPlaylist(only: Int?): String

    /** A rendition's media playlist: HTTP-style status and body. */
    suspend fun mediaPlaylist(index: Int): Pair<Int, String>
}

sealed class StreamStartException(message: String) : Exception(message) {
    class Offline : StreamStartException("This channel is offline.")
    class Usher(val status: Int) : StreamStartException("Twitch refused the stream (HTTP $status).")
    class NoVariants : StreamStartException("No playable qualities were found.")
}

// MARK: Usher (Twitch's playlist server)

object Usher {
    private fun encode(value: String): String = URLEncoder.encode(value, "UTF-8").replace("+", "%20")

    private fun build(path: String, params: List<Pair<String, String>>): String =
        "https://usher.ttvnw.net$path?" + params.joinToString("&") { "${it.first}=${encode(it.second)}" }

    private fun common(codecs: String): MutableList<Pair<String, String>> = mutableListOf(
        "allow_source" to "true",
        "allow_audio_only" to "true",
        "playlist_include_framerate" to "true",
        "platform" to "web",
        "supported_codecs" to codecs,
        "p" to Random.nextInt(9_999_999).toString(),
    )

    fun live(login: String, token: PlaybackToken, codecs: String, lowLatency: Boolean): String {
        val params = common(codecs)
        if (lowLatency) params.add("fast_bread" to "true")
        // Enhanced Broadcasting channels list extra renditions (e.g. 1440p HEVC) per group.
        params.add("multigroup_video" to "true")
        params.add("sig" to token.signature)
        params.add("token" to token.value)
        return build("/api/v2/channel/hls/${login.lowercase()}.m3u8", params)
    }

    fun vod(id: String, token: PlaybackToken, codecs: String): String {
        val params = common(codecs)
        params.add("nauthsig" to token.signature)
        params.add("nauth" to token.value)
        params.add("sig" to token.signature)
        params.add("token" to token.value)
        return build("/vod/v2/$id.m3u8", params)
    }
}

// MARK: Ad-free playlist servers

/**
 * The "v1" servers listed by TTV LOL PRO (running luminous-ttv): they ask Twitch for the stream
 * from a country where Twitch doesn't run ads and return that master playlist. Kestrel then loads
 * the playlists and video from Twitch directly.
 */
data class AdFreeProxy(val host: String, val country: String) {
    companion object {
        /** From https://wiki.cdn-perfprod.com/v1/must-read/proxies (operators: PerfProd, Luminous). */
        val all = listOf(
            AdFreeProxy("lb-eu3.cdn-perfprod.com", "Russia"),
            AdFreeProxy("eu.luminous.dev", "Russia"),
            AdFreeProxy("eu2.luminous.dev", "Ukraine"),
            AdFreeProxy("eu3.luminous.dev", "Bulgaria"),
            AdFreeProxy("as.luminous.dev", "Kazakhstan"),
            AdFreeProxy("lb-eu.cdn-perfprod.com", "various"),
            AdFreeProxy("lb-eu2.cdn-perfprod.com", "various"),
            AdFreeProxy("lb-eu4.cdn-perfprod.com", "various"),
            AdFreeProxy("lb-eu5.cdn-perfprod.com", "various"),
            AdFreeProxy("lb-as.cdn-perfprod.com", "various"),
            AdFreeProxy("lb-na.cdn-perfprod.com", "US (Phoenix)"),
            AdFreeProxy("lb-sa.cdn-perfprod.com", "US (New York)"),
        )

        fun masterUrl(host: String, login: String, codecs: String, lowLatency: Boolean): String {
            val builder = HttpUrl.Builder().scheme("https").host(host).addPathSegment("live").addPathSegment(login.lowercase())
                .addQueryParameter("allow_source", "true")
                .addQueryParameter("allow_audio_only", "true")
                .addQueryParameter("playlist_include_framerate", "true")
                .addQueryParameter("platform", "web")
                .addQueryParameter("supported_codecs", codecs)
                .addQueryParameter("player_backend", "mediaplayer")
            if (lowLatency) builder.addQueryParameter("fast_bread", "true")
            return builder.build().toString()
        }

        /** `USER-COUNTRY` from `#EXT-X-TWITCH-INFO` (where Twitch thinks you are). */
        fun userCountry(master: String): String? {
            for (line in Hls.lines(master)) {
                if (!line.startsWith("#EXT-X-TWITCH-INFO")) continue
                Hls.attributes(line)["USER-COUNTRY"]?.takeIf { it.isNotEmpty() }?.let { return it }
            }
            return null
        }

        data class Fetched(val text: String, val url: String, val host: String)

        /** Tries the hosts in order; the first master playlist one of them delivers. */
        suspend fun fetchMaster(login: String, codecs: String, lowLatency: Boolean, hosts: List<String>, http: OkHttpClient): Fetched? {
            for (host in hosts.take(4)) {
                val url = masterUrl(host, login, codecs, lowLatency)
                try {
                    val result = http.fetch(Http.get(url))
                    if (result.code == 200 && Hls.looksLikePlaylist(result.body) && result.body.contains("#EXT-X-STREAM-INF")) {
                        val country = userCountry(result.body)?.let { ", Twitch sees $it" } ?: ""
                        ActivityLog.add("Ad-free proxy $host delivered the stream$country")
                        lastWorkingHost = host
                        return Fetched(result.body, result.url, host)
                    }
                    if (result.code == 404) {
                        // The channel is offline (or doesn't exist): no point asking the others.
                        ActivityLog.add("Ad-free proxy $host: channel not live")
                        return null
                    }
                    ActivityLog.add("Ad-free proxy $host answered HTTP ${result.code}, trying the next")
                } catch (e: Exception) {
                    if (e is kotlinx.coroutines.CancellationException) throw e
                    ActivityLog.add("Ad-free proxy $host didn't answer (${e.message ?: e.javaClass.simpleName}), trying the next")
                }
            }
            return null
        }

        /** Remembered across streams so the next one starts with the server that worked. */
        var lastWorkingHost: String?
            get() = Prefs.string("kestrel.lastProxyHost")
            set(value) = Prefs.setString("kestrel.lastProxyHost", value)

        /** "Automatic" order, starting with the server that worked last time. */
        val automaticHosts: List<String>
            get() {
                val hosts = all.map { it.host }.toMutableList()
                val last = lastWorkingHost
                if (last != null && hosts.remove(last)) hosts.add(0, last)
                return hosts
            }
    }
}

// MARK: Where a live stream's master playlist comes from

sealed class StreamRoute {
    /** Signed in and Twitch sends this account no ads here (the reason: "subscribed", "Turbo"). */
    data class TwitchAdFree(val reason: String) : StreamRoute()
    data class AdFreeServer(val host: String) : StreamRoute()
    object Twitch : StreamRoute()

    /** Twitch may stitch ads into this stream (the playlist came straight from Twitch). */
    val adsPossible: Boolean get() = this is Twitch

    val summary: String
        get() = when (this) {
            is TwitchAdFree -> "none needed ($reason)"
            is AdFreeServer -> "ad-free server $host"
            Twitch -> "Kestrel filter"
        }
}

object MasterPlaylistFetch {
    data class Result(val text: String, val url: String, val route: StreamRoute)

    /**
     * Straight from Twitch when it won't show you ads (signed in with a sub, or Turbo), else
     * through an ad-free server, else straight from Twitch with Kestrel's ad handling.
     */
    suspend fun fetch(
        login: String,
        codecs: String,
        lowLatency: Boolean,
        proxies: List<String>,
        checkAccountFirst: Boolean,
        playerType: String,
        http: OkHttpClient,
    ): Result {
        var token: PlaybackToken? = null
        if (checkAccountFirst) {
            token = runCatching { TwitchApi.streamToken(login, playerType, "web") }.getOrNull()
            val reason = token?.adFreeReason
            if (token != null && reason != null) {
                ActivityLog.add("Twitch shows you no ads on this channel ($reason): playing straight from Twitch")
                val (text, url) = usher(login, token, codecs, lowLatency, http)
                return Result(text, url, StreamRoute.TwitchAdFree(reason))
            }
        }
        if (proxies.isNotEmpty()) {
            AdFreeProxy.fetchMaster(login, codecs, lowLatency, proxies, http)?.let {
                return Result(it.text, it.url, StreamRoute.AdFreeServer(it.host))
            }
        }
        val direct = token ?: TwitchApi.streamToken(login, playerType, "web")
        ActivityLog.add(direct.summary)
        val (text, url) = usher(login, direct, codecs, lowLatency, http)
        return Result(text, url, StreamRoute.Twitch)
    }

    private suspend fun usher(login: String, token: PlaybackToken, codecs: String, lowLatency: Boolean, http: OkHttpClient): Pair<String, String> {
        val url = Usher.live(login, token, codecs, lowLatency)
        val result = http.fetch(Http.playlist(url))
        if (result.code != 200 || !Hls.looksLikePlaylist(result.body)) {
            throw if (result.code == 404) StreamStartException.Offline() else StreamStartException.Usher(result.code)
        }
        return result.body to result.url
    }
}

// MARK: VOD seek previews

/** Twitch's VOD storyboards: sprite sheets of thumbnails (`seekPreviewsURL` points at the JSON). */
data class Storyboard(
    val images: List<String>,
    val columns: Int,
    val rows: Int,
    val count: Int,
    /** Pixel size of one thumbnail. */
    val width: Int,
    val height: Int,
    /** Seconds between thumbnails. */
    val interval: Double,
) {
    data class Frame(val image: String, val column: Int, val row: Int)

    fun frame(seconds: Double): Frame? {
        if (!seconds.isFinite() || interval <= 0) return null
        val index = minOf(count - 1, maxOf(0, (seconds / interval).toInt()))
        val perImage = columns * rows
        val sheet = index / perImage
        if (sheet >= images.size) return null
        val cell = index % perImage
        return Frame(images[sheet], cell % columns, cell / columns)
    }

    companion object {
        /** Picks the sharpest storyboard in the JSON. `duration` is needed when the JSON has no interval. */
        fun parse(text: String, base: String, duration: Double?): Storyboard? {
            val list = runCatching { JSONArray(text) }.getOrNull() ?: return null
            val boards = list.objects().mapNotNull { entry ->
                val names = entry.arr("images").strings()
                val columns = entry.int("cols") ?: 0
                val rows = entry.int("rows") ?: 0
                val count = entry.int("count") ?: 0
                if (names.isEmpty() || columns <= 0 || rows <= 0 || count <= 0) return@mapNotNull null
                val images = names.map { resolveUrl(it, base) }
                var interval = entry.double("interval") ?: 0.0
                if (interval <= 0 && duration != null && duration > 0) interval = duration / count
                if (interval <= 0) return@mapNotNull null
                Storyboard(images, columns, rows, count, entry.int("width") ?: 0, entry.int("height") ?: 0, interval)
            }
            return boards.maxByOrNull { it.width }
        }
    }
}

// MARK: VODs

/**
 * A VOD (or a live broadcast's VOD while it's recorded, for rewinding) served through Kestrel so
 * its playlists can be fixed on the way: Twitch lists muted parts as "N-unmuted.ts", which only
 * exist as "N-muted.ts", and a VOD still being recorded is served as a finished VOD of what's been
 * recorded so far (reloaded for more as playback nears the end).
 */
class VodPlaylists(val variants: List<HlsVariant>, private val http: OkHttpClient) : PlaylistSource {
    override val id: String = UUID.randomUUID().toString()
    private val cache = HashMap<Int, Pair<String, Long>>()

    @Volatile
    var isRecording = false
        private set

    @Volatile
    var recordedSeconds = 0.0
        private set

    override suspend fun masterPlaylist(only: Int?): String {
        val out = StringBuilder("#EXTM3U\n#EXT-X-INDEPENDENT-SEGMENTS\n")
        variants.forEachIndexed { index, variant ->
            if (only == null || only == index) out.append(variant.streamInf()).append('\n').append("v/$index.m3u8\n")
        }
        return out.toString()
    }

    override suspend fun mediaPlaylist(index: Int): Pair<Int, String> {
        val variant = variants.getOrNull(index) ?: return 404 to ""
        synchronized(cache) {
            cache[index]?.let { (body, at) -> if (System.currentTimeMillis() - at < 15_000) return 200 to body }
        }
        val result = try {
            http.fetch(Http.get(variant.uri))
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            return 502 to ""
        }
        if (result.code != 200 || !Hls.looksLikePlaylist(result.body)) return (if (result.code == 200) 502 else result.code) to ""
        val growing = isGrowing(result.body)
        val rewritten = rewrite(result.body, result.url, finish = true)
        isRecording = growing
        recordedSeconds = totalDuration(rewritten)
        synchronized(cache) { cache[index] = rewritten to System.currentTimeMillis() }
        return 200 to rewritten
    }

    /** Fetches a rendition's playlist ahead of time. */
    suspend fun prefetch(index: Int) {
        mediaPlaylist(index)
    }

    companion object {
        fun rewrite(text: String, base: String, finish: Boolean): String {
            val out = mutableListOf<String>()
            var sawType = false
            for (raw in Hls.lines(text)) {
                val line = raw.trimEnd('\r')
                when {
                    line.startsWith("#EXT-X-PLAYLIST-TYPE") -> {
                        sawType = true
                        out.add(if (finish) "#EXT-X-PLAYLIST-TYPE:VOD" else line)
                    }
                    line.startsWith("#") -> out.add(Hls.absolutizeTag(line, base))
                    line.isBlank() -> out.add(line)
                    else -> out.add(resolveUrl(line, base).replace("-unmuted.", "-muted."))
                }
            }
            if (finish) {
                while (out.isNotEmpty() && out.last().isBlank()) out.removeAt(out.size - 1)
                if (!sawType) {
                    val header = out.indexOfFirst { it.startsWith("#EXTM3U") }
                    if (header >= 0) out.add(header + 1, "#EXT-X-PLAYLIST-TYPE:VOD")
                }
                if (isGrowing(text)) out.add("#EXT-X-ENDLIST")
            }
            return out.joinToString("\n") + "\n"
        }

        fun totalDuration(text: String): Double {
            var total = 0.0
            for (line in Hls.lines(text)) {
                if (!line.startsWith("#EXTINF:")) continue
                val value = line.substring(8).substringBefore(',').trim()
                total += value.toDoubleOrNull() ?: 0.0
            }
            return total
        }

        fun isGrowing(text: String): Boolean = !text.contains("#EXT-X-ENDLIST")
    }
}
