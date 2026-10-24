package app.kestrel.data

import app.kestrel.core.AdFreeProxy
import app.kestrel.core.BoolPref
import app.kestrel.core.DeviceCodecs
import app.kestrel.core.FloatPref
import app.kestrel.core.Http
import app.kestrel.core.HttpProxy
import app.kestrel.core.StreamSessionConfig
import app.kestrel.core.StringPref
import app.kestrel.core.TwitchApi
import okhttp3.OkHttpClient

/** How Kestrel keeps ads out. */
sealed class AdBlocking {
    /** Ad-free proxy servers, the best available one picked automatically. */
    object Automatic : AdBlocking()

    /** One specific ad-free proxy server. */
    data class Server(val host: String) : AdBlocking()

    /** The user's own HTTP proxy (in a country without Twitch ads). */
    object CustomProxy : AdBlocking()

    /** No proxy: switch to an ad-free copy of the stream, else hide the ad. */
    object Basic : AdBlocking()

    val stored: String
        get() = when (this) {
            Automatic -> "auto"
            is Server -> "server:$host"
            CustomProxy -> "custom"
            Basic -> "off"
        }

    val shortTitle: String
        get() = when (this) {
            Automatic -> "Automatic"
            is Server -> "Ad-free server"
            CustomProxy -> "Own proxy"
            Basic -> "Basic"
        }

    companion object {
        fun fromStored(value: String?): AdBlocking = when {
            value == null || value == "auto" -> Automatic
            value == "custom" -> CustomProxy
            value == "off" -> Basic
            value.startsWith("server:") -> Server(value.removePrefix("server:"))
            else -> Automatic
        }
    }
}

object AppSettings {
    var lowLatency by BoolPref("lowLatency", true)
    var backgroundAudio by BoolPref("backgroundAudio", true)
    var pictureInPicture by BoolPref("pictureInPicture", true)
    var showVideoStats by BoolPref("showVideoStats", false)
    var chatFontSize by FloatPref("chatFontSize", 14f)

    private var adBlockingStored by StringPref("adBlocking", "auto")
    var adBlocking: AdBlocking
        get() = AdBlocking.fromStored(adBlockingStored)
        set(value) {
            adBlockingStored = value.stored
            applyProxy()
        }

    // The user's own HTTP proxy (AdBlocking.CustomProxy).
    private var storedProxyHost by StringPref("proxyHost", "")
    private var storedProxyPort by StringPref("proxyPort", "")
    private var storedProxyUsername by StringPref("proxyUsername", "")
    private var storedProxyPassword by StringPref("proxyPassword", "")

    var proxyHost: String
        get() = storedProxyHost
        set(value) {
            storedProxyHost = value
            applyProxy()
        }
    var proxyPort: String
        get() = storedProxyPort
        set(value) {
            storedProxyPort = value
            applyProxy()
        }
    var proxyUsername: String
        get() = storedProxyUsername
        set(value) {
            storedProxyUsername = value
            applyProxy()
        }
    var proxyPassword: String
        get() = storedProxyPassword
        set(value) {
            storedProxyPassword = value
            applyProxy()
        }

    /** Ad-free servers to try for a stream, in order (none when they're off). */
    val adFreeProxyHosts: List<String>
        get() = when (val mode = adBlocking) {
            AdBlocking.Automatic -> AdFreeProxy.automaticHosts
            is AdBlocking.Server -> listOf(mode.host) + AdFreeProxy.automaticHosts.filter { it != mode.host }
            AdBlocking.CustomProxy, AdBlocking.Basic -> emptyList()
        }

    /** The user's own proxy for playback requests, when chosen and filled in. */
    val playbackProxy: HttpProxy?
        get() {
            val host = proxyHost.trim()
            val port = proxyPort.trim().toIntOrNull() ?: return null
            if (adBlocking != AdBlocking.CustomProxy || host.isEmpty() || port <= 0) return null
            return HttpProxy(host, port, proxyUsername.ifEmpty { null }, proxyPassword.ifEmpty { null })
        }

    /** HTTP client for Twitch tokens and playlists (through the user's proxy when one is set). */
    fun playbackClient(timeoutSeconds: Long = 8): OkHttpClient = Http.playback(playbackProxy, timeoutSeconds)

    /** Playback tokens go through the user's proxy too: Twitch decides about ads by where the token request comes from. */
    fun applyProxy() {
        TwitchApi.playbackClient = playbackProxy?.let { Http.playback(it, 12) }
    }

    /** Twitch's `supported_codecs`: everything this device decodes in hardware. */
    val codecs: String get() = DeviceCodecs.enhanced

    /** What the stats overlay shows as the ad route. */
    val adBlockingSummary: String
        get() = when (adBlocking) {
            AdBlocking.Automatic, is AdBlocking.Server -> "ad-free server"
            AdBlocking.CustomProxy -> playbackProxy?.let { "own proxy ${it.description}" } ?: "own proxy (not set up)"
            AdBlocking.Basic -> "basic"
        }

    fun sessionConfig(codecs: String, proxies: List<String>, checkAccountFirst: Boolean): StreamSessionConfig = StreamSessionConfig(
        lowLatency = lowLatency,
        fastBread = true,
        backupStreams = true,
        allowLowQualityBackup = true,
        codecs = codecs,
        adFreeProxies = proxies,
        checkAccountFirst = checkAccountFirst,
    )
}
