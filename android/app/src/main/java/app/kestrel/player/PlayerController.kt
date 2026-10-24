package app.kestrel.player

import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import app.kestrel.core.ActivityLog
import app.kestrel.core.AdState
import app.kestrel.core.Channel
import app.kestrel.core.DeviceCodecs
import app.kestrel.core.Format
import app.kestrel.core.Hls
import app.kestrel.core.HlsMaster
import app.kestrel.core.HlsVariant
import app.kestrel.core.Http
import app.kestrel.core.Kestrel
import app.kestrel.core.LiveArchive
import app.kestrel.core.LiveStream
import app.kestrel.core.Storyboard
import app.kestrel.core.StreamRoute
import app.kestrel.core.StreamSession
import app.kestrel.core.StreamStartException
import app.kestrel.core.TwitchApi
import app.kestrel.core.TwitchAuth
import app.kestrel.core.Usher
import app.kestrel.core.Video
import app.kestrel.core.VodPlaylists
import app.kestrel.core.fetch
import app.kestrel.data.AppSettings
import app.kestrel.data.WatchHistory
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/** What's playing. */
sealed class PlaybackTarget {
    /** `stream`: what the list showed (for the notification until fresher details arrive). */
    data class Live(val channel: Channel, val stream: LiveStream? = null) : PlaybackTarget()
    data class Vod(val video: Video) : PlaybackTarget()

    val key: String
        get() = when (this) {
            is Live -> "live-${channel.id}"
            is Vod -> "vod-${video.id}"
        }
}

/** One playback: a live stream (with rewinding through the broadcast's VOD) or a VOD. Main thread only. */
class PlayerController(val target: PlaybackTarget) {
    sealed class Phase {
        object Loading : Phase()
        object Playing : Phase()
        object Offline : Phase()
        data class Failed(val message: String) : Phase()
    }

    /** `id` null = Auto. */
    data class Quality(val id: Int?, val label: String)

    private enum class Loaded { Nothing, Live, Vod, Rewind }

    private val player: ExoPlayer get() = KestrelPlayer.player
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate + Kestrel.errors)

    var phase by mutableStateOf<Phase>(Phase.Loading)
        private set
    var qualities by mutableStateOf<List<Quality>>(emptyList())
        private set
    var selectedQuality by mutableStateOf<Int?>(null)
        private set
    var adState by mutableStateOf<AdState>(AdState.None)
        private set
    var coveringAd by mutableStateOf(false)
        private set
    var latency by mutableStateOf<Double?>(null)
        private set
    var stream by mutableStateOf<LiveStream?>(null)
        private set
    var channel by mutableStateOf<Channel?>(null)
        private set
    var isBuffering by mutableStateOf(true)
        private set
    var isPlaying by mutableStateOf(false)
        private set
    var stats by mutableStateOf<List<Pair<String, String>>>(emptyList())
        private set
    var isPaused by mutableStateOf(false)
        private set

    /** Zoomed to fill the screen (crops the sides) instead of fitting. */
    var fillsScreen by mutableStateOf(false)
    var videoAspect by mutableStateOf(16f / 9f)
        private set

    // VOD position, for the seek bar (seconds).
    var position by mutableStateOf(0.0)
        private set
    var duration by mutableStateOf(0.0)
        private set

    /** Where the live stream's playlist came from (stats overlay). */
    var route by mutableStateOf<StreamRoute?>(null)
        private set

    // Rewinding a live stream: the broadcast's VOD while it's being recorded.
    var rewind by mutableStateOf<LiveArchive?>(null)
        private set
    var isRewinding by mutableStateOf(false)
        private set

    /** Seconds into the broadcast being watched while rewinding. */
    var rewindPosition by mutableStateOf(0.0)
        private set

    /** Seconds since the broadcast started (the live edge on the seek bar). */
    var broadcastElapsed by mutableStateOf(0.0)
        private set

    /** VOD seek previews (VODs, and live streams that can be rewound). */
    var storyboard by mutableStateOf<Storyboard?>(null)
        private set
    var vodIsRecording by mutableStateOf(false)
        private set

    /** Shown for a few seconds after resuming where you left off. */
    var resumedAt by mutableStateOf<Double?>(null)
        private set

    /** Better renditions Twitch itself offers than the ad-free server's copy has. */
    var directOnly by mutableStateOf<List<HlsVariant>>(emptyList())
        private set

    val isLive: Boolean get() = target is PlaybackTarget.Live

    private var session: StreamSession? = null
    private var vodSource: VodPlaylists? = null
    private var rewindSource: VodPlaylists? = null
    private var loaded = Loaded.Nothing
    private var liveVariants: List<HlsVariant> = emptyList()
    private var vodVariants: List<HlsVariant> = emptyList()
    private var rewindVariants: List<HlsVariant> = emptyList()
    private var rewindQuality = 0
    private var adRanges: List<LongRange> = emptyList()
    private var mutedForAd = false
    private var started = false
    private var stopped = false
    private var tickJob: Job? = null

    /** Twitch `supported_codecs` for this playback; steps down to H.264 if a codec won't play. */
    private var codecs = AppSettings.codecs
    private var preferredQualityLabel: String? = null

    /** Playing straight from Twitch for a quality only it has (ads possible), for this stream only. */
    private var forceDirect = false
    private var checkedDirect = false
    private var adFreeBestHeight = 0
    private var directOffer: List<HlsVariant> = emptyList()

    private val recentFailures = mutableListOf<Long>()
    private var lastInfoRefresh = 0L
    private var lastArchiveCheck = 0L
    private var checkingArchive = false
    private var lastCatchUp = 0L
    private var lastSaved = 0L
    private var lastSynced = 0L
    private var lastExtended = 0L
    private var lastRewindReload = 0L
    private var rewindEndSince: Long? = null
    private var stall: Pair<Double, Long>? = null
    private var noVideoSince: Long? = null
    private var storyboardSource: Triple<String, String, Double?>? = null
    private var storyboardLoaded = 0L
    private val window = Timeline.Window()

    companion object {
        const val DIRECT_QUALITY_BASE = 2000
    }

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            updatePlaybackState()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            updatePlaybackState()
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (phase == Phase.Playing) isPaused = !playWhenReady
        }

        override fun onPlayerError(error: PlaybackException) {
            handleError(error)
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width > 0 && videoSize.height > 0) {
                videoAspect = videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height
            }
        }
    }

    private fun updatePlaybackState() {
        val state = player.playbackState
        isBuffering = phase == Phase.Loading || state == Player.STATE_BUFFERING
        isPlaying = player.isPlaying
    }

    // MARK: Start and stop

    fun start() {
        if (started || stopped) return
        started = true
        player.addListener(listener)
        player.volume = 1f
        KestrelPlayer.connectService(Kestrel.app)
        when (val t = target) {
            is PlaybackTarget.Live -> {
                channel = t.channel
                stream = t.stream
                lastInfoRefresh = System.currentTimeMillis()
                scope.launch { refreshInfo() }
                scope.launch { startLive(t.channel) }
            }
            is PlaybackTarget.Vod -> {
                channel = t.video.owner
                scope.launch { startVideo(t.video) }
            }
        }
        tickJob = scope.launch {
            while (isActive) {
                tick()
                delay(500)
            }
        }
    }

    fun stop() {
        if (stopped) return
        val t = target
        if (t is PlaybackTarget.Vod && position > 0 && phase == Phase.Playing) {
            WatchHistory.save(t.video.id, position, duration, syncToTwitch = true)
        }
        stopped = true
        tickJob?.cancel()
        teardownPlayback()
        rewindSource?.let { PlaylistServer.remove(it.id) }
        rewindSource = null
        player.removeListener(listener)
        player.volume = 1f
        scope.cancel()
    }

    private fun relaunch() {
        when (val t = target) {
            is PlaybackTarget.Live -> scope.launch { startLive(t.channel) }
            is PlaybackTarget.Vod -> scope.launch { startVideo(t.video) }
        }
    }

    /** Stops the player and this playback's playlists, keeping the controller usable. */
    private fun teardownPlayback() {
        isRewinding = false
        rewindEndSince = null
        player.stop()
        player.clearMediaItems()
        loaded = Loaded.Nothing
        session?.let {
            PlaylistServer.remove(it.id)
            it.close()
        }
        session = null
        vodSource?.let { PlaylistServer.remove(it.id) }
        vodSource = null
        qualities = emptyList()
        selectedQuality = null
        latency = null
        adState = AdState.None
        adRanges = emptyList()
        coveringAd = false
        if (mutedForAd) {
            player.volume = 1f
            mutedForAd = false
        }
        isBuffering = true
        noVideoSince = null
    }

    private fun restartPlayback() {
        teardownPlayback()
        phase = Phase.Loading
        relaunch()
    }

    fun retry() {
        recentFailures.clear()
        codecs = AppSettings.codecs
        restartPlayback()
    }

    // MARK: Live

    /** The ad-free servers to use (none once a quality only Twitch itself offers was picked). */
    private val adFreeProxies: List<String> get() = if (forceDirect) emptyList() else AppSettings.adFreeProxyHosts

    private suspend fun startLive(channel: Channel) {
        val config = AppSettings.sessionConfig(codecs, adFreeProxies, TwitchAuth.session != null)
        val newSession = StreamSession(channel.login, config, AppSettings.playbackClient(8)) { state, ranges ->
            scope.launch {
                if (!stopped) {
                    adState = state
                    adRanges = ranges
                }
            }
        }
        try {
            val variants = newSession.start()
            if (stopped) {
                newSession.close()
                return
            }
            route = newSession.route
            session = newSession
            PlaylistServer.register(newSession)
            liveVariants = variants
            qualities = variants.mapIndexed { i, v -> Quality(i, v.label) } + Quality(null, "Auto")
            // Always the highest quality: the player is given only that rendition, so it can't drop
            // to a lower one on its own. (Another one picked in the menu applies to this stream only.)
            val preferred = preferredQualityLabel?.let { label -> variants.indexOfFirst { it.label == label }.takeIf { it >= 0 } }
            selectedQuality = preferred ?: 0
            preferredQualityLabel = null
            playLive()
            phase = Phase.Playing
            checkDirectQualities(variants)
        } catch (e: StreamStartException.Offline) {
            newSession.close()
            phase = Phase.Offline
        } catch (e: Exception) {
            newSession.close()
            if (e is CancellationException) throw e
            phase = Phase.Failed(e.message ?: "Couldn't start the stream.")
        }
        updatePlaybackState()
    }

    private fun liveTargetOffsetMs(): Long = if (AppSettings.lowLatency) 3500 else 7000

    private fun playLive() {
        val session = session ?: return
        val item = MediaItem.Builder()
            .setUri(PlaylistServer.masterUrl(session.id, selectedQuality))
            .setMimeType(MimeTypes.APPLICATION_M3U8)
            .setLiveConfiguration(
                MediaItem.LiveConfiguration.Builder()
                    .setTargetOffsetMs(liveTargetOffsetMs())
                    .setMinPlaybackSpeed(0.97f)
                    .setMaxPlaybackSpeed(1.03f)
                    .build(),
            )
            .setMediaMetadata(metadata())
            .build()
        player.setMediaSource(KestrelPlayer.hls.createMediaSource(item))
        player.prepare()
        player.playWhenReady = true
        loaded = Loaded.Live
        isPaused = false
    }

    /** Jumps to the live edge (or back from rewinding). */
    fun goLive() {
        if (isRewinding) {
            returnToLive()
            return
        }
        if (!isLive || session == null) return
        lastCatchUp = System.currentTimeMillis()
        if (player.playbackState == Player.STATE_IDLE) player.prepare()
        player.seekToDefaultPosition()
        player.play()
        isPaused = false
    }

    /** Played through an ad-free server: does Twitch itself offer a better quality? Then it's in the menu. */
    private fun checkDirectQualities(served: List<HlsVariant>) {
        val live = target as? PlaybackTarget.Live ?: return
        if (forceDirect || checkedDirect || route !is StreamRoute.AdFreeServer) return
        checkedDirect = true
        val codecs = this.codecs
        scope.launch {
            val token = runCatching { TwitchApi.streamToken(live.channel.login, "site", "web") }.getOrNull() ?: return@launch
            val url = Usher.live(live.channel.login, token, codecs, false)
            val result = runCatching { Http.withTimeout(8).fetch(Http.playlist(url)) }.getOrNull() ?: return@launch
            if (result.code != 200 || !Hls.looksLikePlaylist(result.body)) return@launch
            val best = served.filter { !it.isAudioOnly }.maxOfOrNull { it.height } ?: 0
            val better = HlsMaster.parse(result.body, result.url).videoVariants.filter { it.height > best }
            if (stopped || better.isEmpty()) return@launch
            adFreeBestHeight = best
            directOffer = better
            directOnly = better
            ActivityLog.add(
                "Twitch itself offers ${better.joinToString(", ") { it.label }}, which the ad-free server's copy doesn't: " +
                    "it's in the quality menu (plays without the ad-free server)",
            )
        }
    }

    /** Restarts this stream straight from Twitch on a rendition the ad-free server didn't have. */
    private fun playDirect(variant: HlsVariant) {
        if (!isLive || stopped) return
        ActivityLog.add("Playing ${variant.label} straight from Twitch for this stream (no ad-free server; ads possible)")
        forceDirect = true
        directOnly = emptyList()
        preferredQualityLabel = variant.label
        restartPlayback()
    }

    /** Whether the ad-free server's copy has this quality ("1080p60", "Audio only"). */
    private fun adFreeHas(label: String): Boolean {
        val height = label.takeWhile { it.isDigit() }.toIntOrNull() ?: return true
        return height <= adFreeBestHeight
    }

    /** Back from playing straight from Twitch to the ad-free server (no ads), at `label`. */
    private fun returnToAdFree(label: String?) {
        if (!isLive || stopped) return
        ActivityLog.add("Back to the ad-free server" + (label?.let { " at $it" } ?: ""))
        forceDirect = false
        directOnly = directOffer
        preferredQualityLabel = label
        restartPlayback()
    }

    // MARK: VODs

    private class VodException(message: String) : Exception(message)

    /** A VOD's renditions, best first (then audio only). */
    private suspend fun vodRenditions(id: String): List<HlsVariant> {
        val token = TwitchApi.videoToken(id)
        val url = Usher.vod(id, token, codecs)
        val result = Http.withTimeout(10).fetch(Http.playlist(url))
        if (result.code != 200 || !Hls.looksLikePlaylist(result.body)) {
            throw VodException(
                if (result.code == 403) "This video is restricted (subscribers only or region locked)." else "Twitch returned HTTP ${result.code}.",
            )
        }
        val master = HlsMaster.parse(result.body, result.url)
        val variants = master.videoVariants + listOfNotNull(master.audioVariant)
        if (variants.isEmpty()) throw VodException("No playable qualities were found.")
        return variants
    }

    private suspend fun startVideo(video: Video) {
        try {
            val renditions = scope.async { vodRenditions(video.id) }
            val saved = scope.async { runCatching { WatchHistory.resumePosition(video) }.getOrNull() }
            vodVariants = renditions.await()
            val resume = saved.await()
            if (stopped) return
            val source = VodPlaylists(vodVariants, Http.withTimeout(10))
            PlaylistServer.register(source)
            vodSource = source
            qualities = vodVariants.mapIndexed { i, v -> Quality(i, v.label) }
            selectedQuality = 0
            // VODs start at the beginning (a VOD that's still recording would otherwise start at its
            // end), or where you left off.
            val length = video.lengthSeconds.toDouble()
            var start = 0.0
            if (resume != null && resume > 15 && (length <= 0 || resume < length - 20)) {
                start = resume
                resumedAt = resume
                scope.launch {
                    delay(6000)
                    resumedAt = null
                }
            }
            position = start
            if (length > 0) duration = length
            playVod(0, start)
            phase = Phase.Playing
            loadStoryboard(video.id, null, if (length > 0) length else null)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            phase = Phase.Failed(e.message ?: "Couldn't play this video.")
        }
        updatePlaybackState()
    }

    private fun playVod(index: Int, startSeconds: Double) {
        val source = vodSource ?: return
        val item = MediaItem.Builder()
            .setUri(PlaylistServer.mediaUrl(source.id, index))
            .setMimeType(MimeTypes.APPLICATION_M3U8)
            .setMediaMetadata(metadata())
            .build()
        player.setMediaSource(KestrelPlayer.hls.createMediaSource(item), (startSeconds * 1000).toLong())
        player.prepare()
        player.playWhenReady = !isPaused
        loaded = Loaded.Vod
    }

    /** "Start over" after resuming. */
    fun startOver() {
        resumedAt = null
        seek(0.0)
    }

    fun seek(seconds: Double) {
        position = seconds
        resumedAt = null
        stall = null
        player.seekTo((seconds * 1000).toLong())
        if (!isPaused) player.play()
        val t = target
        if (t is PlaybackTarget.Vod) WatchHistory.save(t.video.id, seconds, duration, syncToTwitch = false)
    }

    // MARK: Controls

    fun togglePause() {
        if (isPaused) resume() else pause()
    }

    fun pause() {
        player.pause()
        isPaused = true
        val t = target
        if (t is PlaybackTarget.Vod) WatchHistory.save(t.video.id, position, duration, syncToTwitch = true)
    }

    fun resume() {
        isPaused = false
        if (isLive && !isRewinding) {
            goLive()
        } else {
            if (player.playbackState == Player.STATE_IDLE) player.prepare()
            player.play()
        }
    }

    /** The quality menu: the live stream's, or the VOD's while rewinding. */
    val menuQualities: List<Quality>
        get() {
            if (isRewinding) return rewindVariants.mapIndexed { i, v -> Quality(i, v.label) }
            if (forceDirect) {
                // Playing straight from Twitch for a better quality: the ones the ad-free server also
                // has say so, and picking one goes back to it.
                return qualities.map { q -> if (q.id == null || adFreeHas(q.label)) Quality(q.id, "${q.label} · ad-free") else q }
            }
            if (directOnly.isEmpty()) return qualities
            val list = qualities.toMutableList()
            val extra = directOnly.mapIndexed { i, v -> Quality(DIRECT_QUALITY_BASE + i, "${v.label} · no ad-free server") }
            val autoIndex = list.indexOfFirst { it.id == null }.let { if (it < 0) list.size else it }
            list.addAll(autoIndex, extra)
            return list
        }

    val menuSelectedQuality: Int? get() = if (isRewinding) rewindQuality else selectedQuality

    fun selectQuality(quality: Quality) {
        if (isRewinding) {
            val index = quality.id ?: return
            if (index == rewindQuality || index >= rewindVariants.size) return
            rewindQuality = index
            startRewindItem(rewindPosition)
            return
        }
        val id = quality.id
        if (id != null && id >= DIRECT_QUALITY_BASE) {
            directOnly.getOrNull(id - DIRECT_QUALITY_BASE)?.let { playDirect(it) }
            return
        }
        if (forceDirect && id != selectedQuality) {
            val label = qualities.firstOrNull { it.id == id }?.label
            if (id == null || (label != null && adFreeHas(label))) {
                returnToAdFree(if (id == null) null else label)
                return
            }
        }
        if (id == selectedQuality) return
        selectedQuality = id
        if (session != null) {
            playLive()
        } else if (vodSource != null && id != null) {
            playVod(id, player.currentPosition / 1000.0)
        }
    }

    /** Twitch's low-latency mode (the segment still being made is played as it arrives). */
    fun setLowLatency(enabled: Boolean) {
        if (AppSettings.lowLatency == enabled) return
        AppSettings.lowLatency = enabled
        if (isLive && !isRewinding) {
            preferredQualityLabel = currentVariant?.label
            restartPlayback()
        }
    }

    /** The rendition the player is on (null = Auto). */
    private val currentVariant: HlsVariant?
        get() {
            val variants = when {
                isRewinding -> rewindVariants
                isLive -> liveVariants
                else -> vodVariants
            }
            val index = if (isRewinding) rewindQuality else selectedQuality ?: return null
            return variants.getOrNull(index)
        }

    // MARK: Errors

    private fun handleError(error: PlaybackException) {
        if (stopped) return
        if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
            player.seekToDefaultPosition()
            player.prepare()
            return
        }
        val message = error.cause?.message ?: error.message ?: "Playback failed."
        if (isRewinding) {
            ActivityLog.add("The VOD stopped playing ($message); back to live")
            returnToLive()
            return
        }
        // A 1440p HEVC/AV1 rendition the decoder rejected: ask Twitch again without that codec.
        val variant = currentVariant
        if (variant != null && variant.codecFamily != "avc" && error.errorCode in 4000..4999) {
            val fallback = DeviceCodecs.fallback(codecs)
            if (fallback != null) {
                ActivityLog.add("${variant.label} didn't play ($message); retrying with $fallback")
                codecs = fallback
                preferredQualityLabel = null
                restartPlayback()
                return
            }
        }
        val now = System.currentTimeMillis()
        recentFailures.removeAll { now - it > 90_000 }
        recentFailures.add(now)
        val live = target as? PlaybackTarget.Live
        if (live == null || recentFailures.size > 3) {
            ActivityLog.add("Playback error: $message")
            phase = Phase.Failed(message)
            return
        }
        // The stream may have ended, or its token expired.
        scope.launch {
            val page = runCatching { TwitchApi.channelPage(live.channel.login) }.getOrNull()
            if (page != null && page.stream == null) {
                teardownPlayback()
                phase = Phase.Offline
                return@launch
            }
            ActivityLog.add("Playback error ($message), reconnecting")
            preferredQualityLabel = currentVariant?.label
            teardownPlayback()
            phase = Phase.Loading
            startLive(live.channel)
        }
    }

    // MARK: Ticking: position, latency, ad cover, stats

    private fun tick() {
        val now = System.currentTimeMillis()
        if (isLive && now - lastInfoRefresh > 60_000) {
            lastInfoRefresh = now
            scope.launch { refreshInfo() }
        }
        if (isLive && phase == Phase.Playing) checkForArchive()
        rewind?.let { broadcastElapsed = max(0.0, (now - it.startedAt) / 1000.0) }
        updatePlaybackState()
        val wantsStats = AppSettings.showVideoStats
        if (isRewinding) {
            tickRewind(now)
        } else if (isLive) {
            tickLive(now)
        } else {
            tickVod(now)
        }
        if (wantsStats) stats = playerStats() else if (stats.isNotEmpty()) stats = emptyList()
    }

    private fun tickLive(now: Long) {
        if (loaded != Loaded.Live) return
        val offset = player.currentLiveOffset
        latency = if (offset != C.TIME_UNSET && offset >= 0) offset / 1000.0 else null

        val pdt = currentProgramDateTime()
        val inAd = pdt != null && adRanges.any { pdt >= it.first - 500 && pdt <= it.last + 500 }
        if (inAd != coveringAd) coveringAd = inAd
        if (inAd && player.volume > 0f) {
            player.volume = 0f
            mutedForAd = true
        } else if (!inAd && mutedForAd) {
            player.volume = 1f
            mutedForAd = false
        }

        // A rendition that plays without picture (the decoder can't do it): step down a codec.
        val variant = currentVariant
        if (player.isPlaying && variant != null && variant.codecFamily != "avc" && player.videoFormat == null) {
            val since = noVideoSince ?: now.also { noVideoSince = it }
            if (now - since > 5000) {
                noVideoSince = null
                val fallback = DeviceCodecs.fallback(codecs)
                if (fallback != null) {
                    ActivityLog.add("${variant.label} plays without picture on this phone; retrying with $fallback")
                    codecs = fallback
                    restartPlayback()
                    return
                }
            }
        } else {
            noVideoSince = null
        }

        // No speed-up tricks. Only if stalls have left playback far behind, jump ahead once in a while.
        val current = latency
        if (current != null && current > 30 && player.isPlaying && !inAd && now - lastCatchUp > 60_000) {
            ActivityLog.add("${current.roundToInt()} s behind live, jumping ahead")
            goLive()
        }
    }

    private fun currentProgramDateTime(): Long? {
        val timeline = player.currentTimeline
        if (timeline.isEmpty) return null
        timeline.getWindow(player.currentMediaItemIndex, window)
        if (window.windowStartTimeMs == C.TIME_UNSET) return null
        return window.windowStartTimeMs + player.currentPosition
    }

    private fun tickVod(now: Long) {
        if (loaded != Loaded.Vod) return
        val length = player.duration
        if (length != C.TIME_UNSET && length > 0) {
            val seconds = length / 1000.0
            if (abs(seconds - duration) > 0.5) duration = seconds
        }
        position = player.currentPosition / 1000.0
        vodSource?.let { if (it.isRecording != vodIsRecording) vodIsRecording = it.isRecording }
        // Still recording: it was loaded as what's been recorded so far; near the end, load it
        // again to get what's been recorded since.
        if (vodIsRecording && duration > 0 && position > duration - 30 && now - lastExtended > 45_000) {
            lastExtended = now
            ActivityLog.add("The VOD is still recording: loading what's been recorded since")
            playVod(selectedQuality ?: 0, position)
        }
        watchForStall(position, now)
        val t = target
        if (t is PlaybackTarget.Vod && player.isPlaying && position > 0 && now - lastSaved > 15_000) {
            lastSaved = now
            val sync = now - lastSynced > 60_000
            if (sync) lastSynced = now
            WatchHistory.save(t.video.id, position, duration, sync)
        }
    }

    /** Stuck loading at the same spot for a while (a broken part of a VOD): skip ahead a little instead of freezing. */
    private fun watchForStall(position: Double, now: Long) {
        if (player.playbackState != Player.STATE_BUFFERING || !player.playWhenReady) {
            stall = null
            return
        }
        val current = stall
        if (current == null || abs(current.first - position) >= 0.5) {
            stall = position to now
            return
        }
        if (now - current.second <= 7000) return
        stall = null
        ActivityLog.add("Playback stuck at ${Format.duration(position.toLong())}; skipping ahead a few seconds")
        player.seekTo(((position + 8) * 1000).toLong())
    }

    private fun playerStats(): List<Pair<String, String>> {
        val lines = mutableListOf<Pair<String, String>>()
        lines.add(
            "Player" to when {
                isRewinding -> "ExoPlayer, rewinding the VOD"
                isLive -> "ExoPlayer (Media3)"
                else -> "ExoPlayer, video"
            },
        )
        val variant = currentVariant
        if (variant != null) {
            lines.add("Quality" to variant.label)
            lines.add("Codecs" to variant.codecs.ifEmpty { "–" })
        } else {
            lines.add("Quality" to "Auto")
        }
        player.videoFormat?.let { f ->
            if (f.width > 0) lines.add("Resolution" to "${f.width}×${f.height}")
            if (f.frameRate > 0) lines.add("Frame rate" to "${f.frameRate.roundToInt()} fps")
            if (f.bitrate > 0) lines.add("Bitrate" to Format.mbps(f.bitrate.toLong()))
        }
        lines.add("Bandwidth" to Format.mbps(KestrelPlayer.bandwidthMeter.bitrateEstimate))
        lines.add("Buffer" to Format.seconds(player.totalBufferedDuration / 1000.0))
        if (isLive) lines.add((if (isRewinding) "Behind live" else "Latency") to Format.seconds(latency))
        player.videoDecoderCounters?.let { lines.add("Dropped frames" to it.droppedBufferCount.toString()) }
        if (isLive && !isRewinding) {
            lines.add("Ads" to adState.statsText)
            lines.add("Playlists" to "Kestrel filter")
            lines.add("Ad blocking" to (route?.summary ?: AppSettings.adBlockingSummary))
            lines.add("Account" to (TwitchAuth.session?.login ?: "not signed in"))
        }
        return lines
    }

    // MARK: Rewind (the broadcast's VOD while it's recorded)

    private fun checkForArchive() {
        val live = target as? PlaybackTarget.Live ?: return
        val now = System.currentTimeMillis()
        if (rewind != null || checkingArchive || now - lastArchiveCheck < 180_000) return
        checkingArchive = true
        lastArchiveCheck = now
        scope.launch {
            try {
                val archive = TwitchApi.liveArchive(live.channel.login) ?: return@launch
                if (stopped) return@launch
                // Only offered when the VOD actually plays for this account (sub-only VODs may not).
                val variants = try {
                    vodRenditions(archive.videoID)
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    ActivityLog.add("This broadcast's VOD exists but doesn't play for you, so rewinding is off")
                    return@launch
                }
                if (stopped) return@launch
                rewindVariants = variants.filter { !it.isAudioOnly }
                if (rewindVariants.isEmpty()) return@launch
                val source = VodPlaylists(rewindVariants, Http.withTimeout(10))
                PlaylistServer.register(source)
                rewindSource = source
                launch { source.prefetch(0) }
                broadcastElapsed = max(0.0, (System.currentTimeMillis() - archive.startedAt) / 1000.0)
                rewind = archive
                ActivityLog.add("Rewind available: the VOD of this broadcast is being recorded")
                loadStoryboard(archive.videoID, archive.seekPreviewsURL, null)
            } finally {
                checkingArchive = false
            }
        }
    }

    /** Seeks within the broadcast: the VOD while behind, the live stream at the end. */
    fun seekBroadcast(seconds: Double) {
        if (rewind == null) return
        if (seconds >= broadcastElapsed - 20) {
            returnToLive()
            return
        }
        val target = max(0.0, seconds)
        rewindPosition = target
        stall = null
        val recorded = rewindSource?.recordedSeconds ?: 0.0
        if (isRewinding && loaded == Loaded.Rewind && target < recorded - 10) {
            player.seekTo((target * 1000).toLong())
            if (!isPaused) player.play()
            return
        }
        if (!isRewinding) enterRewind()
        startRewindItem(target)
    }

    private fun enterRewind() {
        isRewinding = true
        isPaused = false
        coveringAd = false
        if (mutedForAd) {
            player.volume = 1f
            mutedForAd = false
        }
        ActivityLog.add("Rewinding: playing this broadcast's VOD")
    }

    private fun startRewindItem(seconds: Double) {
        val source = rewindSource ?: return
        if (rewindQuality >= rewindVariants.size) rewindQuality = 0
        rewindEndSince = null
        val item = MediaItem.Builder()
            .setUri(PlaylistServer.mediaUrl(source.id, rewindQuality))
            .setMimeType(MimeTypes.APPLICATION_M3U8)
            .setMediaMetadata(metadata())
            .build()
        player.setMediaSource(KestrelPlayer.hls.createMediaSource(item), (seconds * 1000).toLong())
        player.prepare()
        player.playWhenReady = !isPaused
        loaded = Loaded.Rewind
    }

    /** Back to the live stream at the live edge (the same session: no new token). */
    fun returnToLive() {
        if (!isRewinding) return
        isRewinding = false
        rewindEndSince = null
        isPaused = false
        latency = null
        playLive()
    }

    private fun tickRewind(now: Long) {
        if (loaded != Loaded.Rewind) return
        val current = player.currentPosition / 1000.0
        rewindPosition = current
        latency = max(0.0, broadcastElapsed - rewindPosition)
        val length = player.duration
        val atEnd = player.playbackState == Player.STATE_ENDED ||
            (player.playWhenReady && length != C.TIME_UNSET && length > 0 && current >= length / 1000.0 - 1.5)
        if (atEnd) {
            val since = rewindEndSince ?: now.also { rewindEndSince = it }
            if (now - since > 1000) {
                rewindEndSince = null
                // The end of what was recorded when it was loaded: more has been recorded since.
                if (broadcastElapsed - current > 90 && now - lastRewindReload > 20_000) {
                    lastRewindReload = now
                    startRewindItem(current)
                } else {
                    ActivityLog.add("Caught up with the recording: back to live")
                    returnToLive()
                    return
                }
            }
        } else {
            rewindEndSince = null
        }
        watchForStall(current, now)
    }

    // MARK: Seek previews

    private fun loadStoryboard(videoId: String, known: String?, duration: Double?) {
        scope.launch {
            val url = known ?: TwitchApi.seekPreviewsURL(videoId) ?: return@launch
            if (stopped) return@launch
            storyboardSource = Triple(url, videoId, duration)
            reloadStoryboard()
        }
    }

    private suspend fun reloadStoryboard() {
        val source = storyboardSource ?: return
        storyboardLoaded = System.currentTimeMillis()
        // A VOD that's still recording: its storyboard covers its current length.
        var duration = source.third
        if (duration == null || vodIsRecording || isLive) duration = TwitchApi.videoProgress(source.second).first ?: duration
        val board = TwitchApi.storyboard(source.first, duration)
        if (board != null && !stopped) storyboard = board
    }

    /** While scrubbing a recording: the storyboard grows with it. */
    fun refreshStoryboardIfStale() {
        if (!(isLive || vodIsRecording || storyboard == null)) return
        if (System.currentTimeMillis() - storyboardLoaded < 60_000) return
        scope.launch { reloadStoryboard() }
    }

    // MARK: Details

    private suspend fun refreshInfo() {
        val live = target as? PlaybackTarget.Live ?: return
        val page = runCatching { TwitchApi.channelPage(live.channel.login) }.getOrNull() ?: return
        if (stopped) return
        channel = page.channel
        stream = page.stream
    }

    /** For the notification and lock screen. */
    private fun metadata(): MediaMetadata {
        val builder = MediaMetadata.Builder()
        val ch = channel
        when (val t = target) {
            is PlaybackTarget.Live -> builder
                .setTitle(ch?.name ?: t.channel.name)
                .setArtist(stream?.title?.takeIf { it.isNotEmpty() } ?: "Live on Twitch")
            is PlaybackTarget.Vod -> builder
                .setTitle(t.video.title)
                .setArtist(ch?.name ?: t.video.owner?.name ?: "Twitch")
        }
        TwitchApi.image(ch?.profileImageURL, 300, 300)?.let { builder.setArtworkUri(Uri.parse(it)) }
        return builder.build()
    }
}
