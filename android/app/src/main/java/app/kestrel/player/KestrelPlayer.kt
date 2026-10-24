package app.kestrel.player

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import app.kestrel.core.Browser
import app.kestrel.core.Http
import app.kestrel.core.Kestrel
import app.kestrel.core.PlaylistSource
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.runBlocking
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

/** The one video player (shared with the lock screen / notification through PlaybackService). */
object KestrelPlayer {
    private var created: ExoPlayer? = null
    private var controllerFuture: ListenableFuture<MediaController>? = null

    val bandwidthMeter: DefaultBandwidthMeter by lazy { DefaultBandwidthMeter.getSingletonInstance(Kestrel.app) }

    /** Playlists come from Kestrel (PlaylistServer); video segments straight from Twitch. */
    val hls: HlsMediaSource.Factory by lazy {
        val upstream = OkHttpDataSource.Factory(Http.media).setUserAgent(Browser.USER_AGENT)
        val factory = DataSource.Factory { KestrelDataSource(upstream.createDataSource()) }
        HlsMediaSource.Factory(factory)
            .setAllowChunklessPreparation(true)
            .setLoadErrorHandlingPolicy(DefaultLoadErrorHandlingPolicy(6))
    }

    val player: ExoPlayer
        get() = created ?: create().also { created = it }

    val exists: Boolean get() = created != null

    private fun create(): ExoPlayer {
        val context = Kestrel.app
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(15_000, 50_000, 1_000, 2_000)
            .build()
        val renderers = DefaultRenderersFactory(context).setEnableDecoderFallback(true)
        val audio = AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build()
        return ExoPlayer.Builder(context, renderers)
            .setLoadControl(loadControl)
            .setBandwidthMeter(bandwidthMeter)
            .setAudioAttributes(audio, true)
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .setSeekBackIncrementMs(10_000)
            .setSeekForwardIncrementMs(10_000)
            .build()
    }

    /** Binds PlaybackService, so playback can go on in the background with lock screen controls. */
    fun connectService(context: Context) {
        if (controllerFuture != null) return
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        controllerFuture = MediaController.Builder(context, token).buildAsync()
    }

    fun disconnectService() {
        controllerFuture?.let { MediaController.releaseFuture(it) }
        controllerFuture = null
    }

    fun release() {
        disconnectService()
        created?.release()
        created = null
    }
}

/** What the player loads playlists from: `https://kestrel.invalid/s/<source>/…`. */
object PlaylistServer {
    const val HOST = "kestrel.invalid"
    private val sources = ConcurrentHashMap<String, PlaylistSource>()

    fun register(source: PlaylistSource) {
        sources[source.id] = source
    }

    fun remove(id: String) {
        sources.remove(id)
    }

    fun masterUrl(id: String, only: Int?): Uri = Uri.parse("https://$HOST/s/$id/master.m3u8?v=${only ?: "all"}")

    fun mediaUrl(id: String, index: Int): Uri = Uri.parse("https://$HOST/s/$id/v/$index.m3u8")

    /** Called on the player's loading threads (blocking is fine there). */
    fun serve(uri: Uri): ByteArray {
        val segments = uri.pathSegments
        val source = segments.getOrNull(1)?.let { sources[it] } ?: throw PlaylistHttpException(404)
        return runBlocking {
            when (segments.getOrNull(2)) {
                "master.m3u8" -> source.masterPlaylist(uri.getQueryParameter("v")?.toIntOrNull()).toByteArray()
                "v" -> {
                    val index = segments.getOrNull(3)?.removeSuffix(".m3u8")?.toIntOrNull() ?: -1
                    val (status, body) = source.mediaPlaylist(index)
                    if (status != 200) throw PlaylistHttpException(status)
                    body.toByteArray()
                }
                else -> throw PlaylistHttpException(404)
            }
        }
    }
}

/** A playlist request Kestrel couldn't answer (404/403: the stream or its token is gone). */
class PlaylistHttpException(val status: Int) : IOException("Playlist unavailable (HTTP $status)")

/** Answers Kestrel's playlist addresses from memory and passes everything else to the network. */
class KestrelDataSource(private val upstream: DataSource) : DataSource {
    private var memory: ByteArray? = null
    private var readPosition = 0
    private var remaining = 0L
    private var uri: Uri? = null
    private var upstreamOpen = false

    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        uri = dataSpec.uri
        if (dataSpec.uri.host == PlaylistServer.HOST) {
            val bytes = PlaylistServer.serve(dataSpec.uri)
            val start = dataSpec.position.coerceIn(0L, bytes.size.toLong()).toInt()
            memory = bytes
            readPosition = start
            val available = (bytes.size - start).toLong()
            remaining = if (dataSpec.length != C.LENGTH_UNSET.toLong()) minOf(dataSpec.length, available) else available
            return remaining
        }
        upstreamOpen = true
        return upstream.open(dataSpec)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val bytes = memory
        if (bytes != null) {
            if (length == 0) return 0
            if (remaining <= 0) return C.RESULT_END_OF_INPUT
            val count = minOf(length.toLong(), remaining).toInt()
            System.arraycopy(bytes, readPosition, buffer, offset, count)
            readPosition += count
            remaining -= count
            return count
        }
        return upstream.read(buffer, offset, length)
    }

    override fun getUri(): Uri? = if (memory != null) uri else upstream.uri ?: uri

    override fun getResponseHeaders(): Map<String, List<String>> = if (memory != null) emptyMap() else upstream.responseHeaders

    override fun close() {
        memory = null
        if (upstreamOpen) {
            upstreamOpen = false
            upstream.close()
        }
    }
}
