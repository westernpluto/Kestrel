package app.kestrel.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import java.util.UUID
import java.util.concurrent.Executors

/** What's happening with ads on the stream being watched. */
sealed class AdState {
    object None : AdState()

    /** Client-side ad break: Twitch would play an ad in its own player; the stream itself is clean. */
    object Skipped : AdState()
    object Searching : AdState()
    data class Replaced(val description: String) : AdState()
    object Covering : AdState()

    val statsText: String
        get() = when (this) {
            None -> "none"
            Skipped -> "break skipped (client-side ad)"
            Searching -> "stitched ad: looking for an ad-free copy"
            is Replaced -> "stitched ad: ad-free copy ($description)"
            Covering -> "stitched ad: hidden"
        }
}

data class StreamSessionConfig(
    /** Hand the player the segment Twitch is still producing (a couple of seconds less delay). */
    val lowLatency: Boolean = true,
    /** Ask Twitch for its low-latency playlist (`fast_bread`). */
    val fastBread: Boolean = true,
    val backupStreams: Boolean = true,
    val allowLowQualityBackup: Boolean = true,
    val codecs: String = "h264",
    val mainPlayerType: String = "popout",
    val backupPlayerTypes: List<String> = listOf("site", "popout", "mobile_web", "embed"),
    /** How long the first playlist of an ad break may wait for an ad-free copy (ms). */
    val firstPollWaitMs: Long = 1200,
    /** After this long without an ad-free copy, show the ad muted and covered (ms). */
    val fallbackGraceMs: Long = 3000,
    val searchDeadlineMs: Long = 4000,
    val backupTokenLifetimeMs: Long = 8 * 60 * 1000L,
    /** Ad-free playlist servers to try first (AdFreeProxy). */
    val adFreeProxies: List<String> = emptyList(),
    /** Signed in: ask Twitch first and play straight from it when it shows this account no ads. */
    val checkAccountFirst: Boolean = false,
)

/**
 * One live playback. Serves the master and media playlists the player asks for and keeps ads out
 * of them (backup access tokens with other player types, ad markers), following
 * TwitchAdSolutions/vaft and streamlink. All state lives on one thread; network calls suspend.
 */
class StreamSession(
    login: String,
    private val config: StreamSessionConfig,
    private val http: OkHttpClient,
    private val onAdState: (AdState, List<LongRange>) -> Unit,
) : PlaylistSource {
    override val id: String = UUID.randomUUID().toString()
    val login: String = login.lowercase()

    private val scope = CoroutineScope(SupervisorJob() + SessionThread + Kestrel.errors)

    var served: List<HlsVariant> = emptyList()
        private set

    /** Where the master playlist came from. */
    @Volatile
    var route: StreamRoute = StreamRoute.Twitch
        private set

    private val timeline = SlotTimeline()
    private val mainStores = HashMap<Int, SegmentStore>()
    private val backupStores = HashMap<Int, HashMap<String, SegmentStore>>()
    private var targetDuration: Int? = null

    // Ad break state
    private var inBreak = false
    private var breakId = 0
    private var breakStart = 0L
    private var committed: BackupMaster? = null
    private val contaminated = HashSet<String>()
    private var pinnedType: String? = null
    private var searchJob: Job? = null
    private var searchSignal = CompletableDeferred<Unit>()
    private var lastSearchEnd = 0L
    private val backupMasters = HashMap<String, BackupMaster>()
    private var breakSummary = ""
    private var adState: AdState = AdState.None
    private var markerBreak = false
    private var markerStart = 0L
    private var lastPublishedAdRanges: List<LongRange> = emptyList()

    data class BackupMaster(val type: String, val master: HlsMaster, val fetchedAt: Long)

    private data class Probe(
        val type: String,
        val master: BackupMaster?,
        val media: HlsMediaPlaylist?,
        val clean: Boolean,
        val failure: String?,
    )

    companion object {
        /** The thread every session's state lives on. */
        private val SessionThread = Executors.newSingleThreadExecutor { runnable ->
            java.lang.Thread(runnable, "kestrel-session").apply { isDaemon = true }
        }.asCoroutineDispatcher()
    }

    fun close() {
        scope.cancel()
    }

    // MARK: Start

    suspend fun start(): List<HlsVariant> = withContext(SessionThread) {
        val fetched = MasterPlaylistFetch.fetch(
            login, config.codecs, config.fastBread, config.adFreeProxies, config.checkAccountFirst,
            config.mainPlayerType, http,
        )
        route = fetched.route
        val master = HlsMaster.parse(fetched.text, fetched.url)
        val variants = master.videoVariants.toMutableList()
        master.audioVariant?.let { variants.add(it) }
        if (variants.none { !it.isAudioOnly }) throw StreamStartException.NoVariants()
        served = variants
        ActivityLog.add("Playing $login (${variants.joinToString(", ") { it.label }})")
        variants
    }

    // MARK: Playlists served to the player

    override suspend fun masterPlaylist(only: Int?): String = withContext(SessionThread) {
        val out = StringBuilder("#EXTM3U\n#EXT-X-INDEPENDENT-SEGMENTS\n")
        served.forEachIndexed { index, variant ->
            val include = if (only != null) index == only else !variant.isAudioOnly
            if (include) out.append(variant.streamInf()).append('\n').append("v/$index.m3u8\n")
        }
        out.toString()
    }

    override suspend fun mediaPlaylist(index: Int): Pair<Int, String> = withContext(SessionThread) {
        val variant = served.getOrNull(index) ?: return@withContext 404 to ""
        val fetched = fetchMedia(variant.uri)
        val main = fetched.first ?: run {
            // A hiccup upstream: hand the player what it already has. (404/403: the stream or token is gone.)
            val status = fetched.second
            val body = if (status != 404 && status != 403) render(index) else null
            return@withContext if (body != null) 200 to body else status to ""
        }

        mainStores.getOrPut(index) { SegmentStore() }.record(main.segments)
        timeline.setInitialSequence(main.mediaSequence)
        // The real segment length (Twitch says 6 but cuts 2 s segments): the player reloads every
        // target duration, so an inflated value only adds delay. It may grow, never shrink.
        val longest = Math.ceil((main.regularSegments.maxOfOrNull { it.duration } ?: 2.0) - 0.01).toInt()
        targetDuration = maxOf(targetDuration ?: 2, longest, 2)

        var candidates: List<HlsSegment> = emptyList()
        var source: SlotSource = SlotSource.Main

        if (!main.adBreakActive) {
            if (inBreak) endBreak()
            noteMarkers(main.adMarkerActive)
            candidates = playable(main)
        } else {
            val firstPoll = !inBreak
            if (firstPoll) beginBreak()
            if (config.backupStreams) {
                if (committed == null) startSearchIfNeeded(index)
                if (committed == null && firstPoll) {
                    val signal = searchSignal
                    withTimeoutOrNull(config.firstPollWaitMs) { signal.await() }
                }
                val backup = committed
                if (backup != null) {
                    val playlist = fetchBackupMedia(backup, index)
                    if (playlist != null) {
                        if (playlist.isClean) {
                            candidates = playable(playlist)
                            source = SlotSource.Backup(backup.type)
                        } else if (committed?.type == backup.type) {
                            committed = null
                            contaminated.add(backup.type)
                            ActivityLog.add("Backup stream (${backup.type}) started showing ads, looking for another")
                            startSearchIfNeeded(index)
                        }
                    } else if (committed?.type == backup.type) {
                        committed = null
                        ActivityLog.add("Backup stream (${backup.type}) stopped responding, looking for another")
                        startSearchIfNeeded(index)
                    }
                }
            }
            if (candidates.isEmpty()) {
                source = SlotSource.Main
                candidates = main.regularSegments.filter { !it.isAd }
                val waitedLongEnough = System.currentTimeMillis() - breakStart >= config.fallbackGraceMs
                val nothingToShow = timeline.isEmpty && candidates.isEmpty()
                if (nothingToShow || (waitedLongEnough && searchJob == null)) {
                    candidates = main.regularSegments
                    if (main.regularSegments.any { it.isAd }) setAdState(AdState.Covering)
                }
            }
        }

        timeline.append(candidates, source)
        ensureBackupStores(index)
        publishAdRangesIfNeeded()
        val body = render(index) ?: return@withContext 503 to ""
        200 to body
    }

    private fun render(index: Int): String? {
        val window = if (config.lowLatency) 10 else 15
        return timeline.render(window, targetDuration ?: 2) { slot ->
            when (val source = slot.source) {
                SlotSource.Main -> mainStores[index]?.lookup(slot)
                is SlotSource.Backup -> backupStores[index]?.get(source.type)?.lookup(slot)
            }
        }
    }

    /** Regular segments plus, for low latency, the one Twitch is producing right now. */
    private fun playable(playlist: HlsMediaPlaylist): List<HlsSegment> {
        val result = playlist.regularSegments.filter { !it.isAd }.toMutableList()
        if (config.lowLatency) {
            val next = playlist.segments.firstOrNull { it.isPrefetch }
            if (next != null && !next.isAd) result.add(next)
        }
        return result
    }

    // MARK: Ad breaks

    private fun beginBreak() {
        inBreak = true
        breakId++
        breakStart = System.currentTimeMillis()
        breakSummary = ""
        contaminated.clear()
        committed = null
        lastSearchEnd = 0
        setAdState(if (config.backupStreams) AdState.Searching else AdState.Covering)
        ActivityLog.add("Ad break started on $login")
    }

    private fun noteMarkers(active: Boolean) {
        if (active && !markerBreak) {
            markerBreak = true
            markerStart = System.currentTimeMillis()
            ActivityLog.add("Ad break on $login: Twitch sends this ad to its own player, so it's skipped (stream stays at full quality)")
            setAdState(AdState.Skipped)
        } else if (!active && markerBreak) {
            markerBreak = false
            ActivityLog.add("Ad break over after ${(System.currentTimeMillis() - markerStart + 500) / 1000}s (skipped)")
            setAdState(AdState.None)
        }
    }

    private fun endBreak() {
        inBreak = false
        breakId++
        ActivityLog.add("Ad break over after ${(System.currentTimeMillis() - breakStart + 500) / 1000}s$breakSummary")
        committed = null
        contaminated.clear()
        searchJob?.cancel()
        searchJob = null
        setAdState(AdState.None)
    }

    private fun setAdState(state: AdState) {
        if (state == adState) return
        adState = state
        onAdState(state, timeline.adRanges)
    }

    private fun publishAdRangesIfNeeded() {
        val ranges = timeline.adRanges
        if (ranges != lastPublishedAdRanges) {
            lastPublishedAdRanges = ranges
            onAdState(adState, ranges)
        }
    }

    private fun playerTypes(): List<String> {
        val types = config.backupPlayerTypes.toMutableList()
        val pinned = pinnedType
        if (pinned != null && types.remove(pinned)) types.add(0, pinned)
        if (config.allowLowQualityBackup) types.add("autoplay")
        val usable = types.filter { it !in contaminated }
        return usable.ifEmpty { types }
    }

    private fun startSearchIfNeeded(index: Int) {
        if (searchJob != null || !inBreak || committed != null) return
        // Don't hammer Twitch: a failed search is retried at most every 6 seconds.
        if (System.currentTimeMillis() - lastSearchEnd < 6000) return
        val types = playerTypes()
        val target = served[index]
        val breakId = this.breakId
        val cached = HashMap(backupMasters)
        val signal = CompletableDeferred<Unit>()
        searchSignal = signal
        searchJob = scope.launch {
            val started = System.currentTimeMillis()
            val probes = runProbes(types, target, cached)
            finishSearch(probes, types, index, breakId, started)
            signal.complete(Unit)
        }
    }

    private fun finishSearch(probes: Map<Int, Probe>, types: List<String>, index: Int, breakId: Int, started: Long) {
        searchJob = null
        lastSearchEnd = System.currentTimeMillis()
        for (probe in probes.values) probe.master?.let { backupMasters[probe.type] = it }
        if (breakId != this.breakId || !inBreak) return
        val winner = types.indices.mapNotNull { probes[it] }.firstOrNull { it.clean }
        val master = winner?.master
        val media = winner?.media
        if (winner != null && master != null && media != null) {
            committed = master
            backupStores.getOrPut(index) { HashMap() }.getOrPut(winner.type) { SegmentStore() }.record(media.segments)
            if (winner.type != "autoplay") pinnedType = winner.type
            val label = master.master.bestMatch(served[index])?.label ?: "?"
            breakSummary = " (ad-free copy: ${winner.type})"
            ActivityLog.add("Switched to ad-free copy (${winner.type}, $label) in ${System.currentTimeMillis() - started} ms")
            setAdState(AdState.Replaced("${winner.type} · $label"))
        } else {
            for (probe in probes.values) if (!probe.clean && probe.failure == null) contaminated.add(probe.type)
            val tried = types.indices.map { i ->
                val p = probes[i] ?: return@map "${types[i]} (timeout)"
                if (p.clean) p.type else "${p.type} (${p.failure ?: "ads"})"
            }
            breakSummary = " (no ad-free copy)"
            ActivityLog.add("No ad-free copy found (tried ${tried.joinToString(", ")})")
            setAdState(AdState.Covering)
        }
    }

    /** Asks every player type at once; the first clean copy in priority order wins once everything ahead of it answered. */
    private suspend fun runProbes(types: List<String>, target: HlsVariant, cached: Map<String, BackupMaster>): Map<Int, Probe> =
        coroutineScope {
            val results = HashMap<Int, Probe>()
            val answers = Channel<Pair<Int, Probe>>(Channel.UNLIMITED)
            val jobs = types.mapIndexed { i, type -> launch { answers.send(i to probe(type, target, cached[type])) } }
            withTimeoutOrNull(config.searchDeadlineMs) {
                while (results.size < types.size) {
                    val (i, probe) = answers.receive()
                    results[i] = probe
                    var decided = false
                    for (j in types.indices) {
                        val r = results[j] ?: break
                        if (r.clean) {
                            decided = true
                            break
                        }
                    }
                    if (decided) break
                }
            }
            jobs.forEach { it.cancel() }
            results
        }

    private suspend fun probe(type: String, target: HlsVariant, cached: BackupMaster?): Probe {
        if (cached != null && System.currentTimeMillis() - cached.fetchedAt < config.backupTokenLifetimeMs) {
            val probe = probeMedia(cached, target)
            if (probe.clean) return probe
        }
        return try {
            val token = TwitchApi.streamToken(login, type, if (type == "autoplay") "android" else "web")
            val url = Usher.live(login, token, config.codecs, config.fastBread)
            val result = http.fetch(Http.playlist(url))
            if (result.code != 200 || !Hls.looksLikePlaylist(result.body)) {
                Probe(type, null, null, false, "HTTP ${result.code}")
            } else {
                probeMedia(BackupMaster(type, HlsMaster.parse(result.body, result.url), System.currentTimeMillis()), target)
            }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            Probe(type, null, null, false, "failed")
        }
    }

    private suspend fun probeMedia(master: BackupMaster, target: HlsVariant): Probe {
        val match = master.master.bestMatch(target) ?: return Probe(master.type, master, null, false, "no match")
        val (playlist, status) = fetchMedia(match.uri)
        if (playlist == null) return Probe(master.type, master, null, false, "HTTP $status")
        return Probe(master.type, master, playlist, playlist.isClean && playlist.regularSegments.isNotEmpty(), null)
    }

    private suspend fun fetchBackupMedia(backup: BackupMaster, variantIndex: Int): HlsMediaPlaylist? {
        val match = backup.master.bestMatch(served[variantIndex]) ?: return null
        val playlist = fetchMedia(match.uri).first ?: return null
        backupStores.getOrPut(variantIndex) { HashMap() }.getOrPut(backup.type) { SegmentStore() }.record(playlist.segments)
        return playlist
    }

    /** Every backup slot in the render window must be resolvable for this quality (after a quality change). */
    private suspend fun ensureBackupStores(index: Int) {
        val recent = timeline.slots.takeLast(16)
        val needed = HashSet<String>()
        for (slot in recent) {
            val source = slot.source
            if (source is SlotSource.Backup && backupStores[index]?.get(source.type)?.contains(slot) != true) needed.add(source.type)
        }
        for (type in needed) {
            val master = backupMasters[type] ?: committed?.takeIf { it.type == type } ?: continue
            fetchBackupMedia(master, index)
        }
    }

    // MARK: Networking

    /** The parsed playlist, or null and the status. */
    private suspend fun fetchMedia(url: String): Pair<HlsMediaPlaylist?, Int> {
        return try {
            val result = http.fetch(Http.playlist(url))
            when {
                result.code != 200 -> null to result.code
                !Hls.looksLikePlaylist(result.body) -> null to 502
                else -> HlsMediaPlaylist.parse(result.body, result.url) to 200
            }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            null to 504
        }
    }
}
