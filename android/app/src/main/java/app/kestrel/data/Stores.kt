package app.kestrel.data

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.kestrel.core.ActivityLog
import app.kestrel.core.Channel
import app.kestrel.core.GqlException
import app.kestrel.core.Kestrel
import app.kestrel.core.LiveStream
import app.kestrel.core.Prefs
import app.kestrel.core.TwitchApi
import app.kestrel.core.TwitchAuth
import app.kestrel.core.TwitchDeviceLogin
import app.kestrel.core.Video
import app.kestrel.core.objects
import app.kestrel.core.strings
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Channels hearted in Kestrel itself (signed out, or when Twitch refused a follow). */
object FavoritesStore {
    private const val KEY = "favorites.v1"
    val channels = mutableStateListOf<Channel>()

    init {
        Prefs.string(KEY)?.let { text ->
            runCatching { JSONArray(text).objects().mapNotNull { Channel.fromJson(it) } }.getOrNull()?.let { channels.addAll(it) }
        }
    }

    fun contains(channel: Channel): Boolean = channels.any { it.id == channel.id }

    fun toggle(channel: Channel) {
        val index = channels.indexOfFirst { it.id == channel.id }
        if (index >= 0) channels.removeAt(index) else channels.add(channel)
        save()
    }

    /** Keeps names and pictures fresh when newer data comes in. */
    fun refresh(updated: List<Channel>) {
        var changed = false
        for (channel in updated) {
            val index = channels.indexOfFirst { it.id == channel.id }
            if (index >= 0 && channels[index] != channel) {
                channels[index] = channel
                changed = true
            }
        }
        if (changed) save()
    }

    private fun save() {
        Prefs.setString(KEY, JSONArray(channels.map { it.toJson() }).toString())
    }
}

/** Who you follow: your Twitch follows when signed in, plus channels hearted in Kestrel. */
object FollowingStore {
    data class OfflineChannel(val channel: Channel, val lastLive: Long?)

    var live by mutableStateOf<List<LiveStream>>(emptyList())
        private set
    var offline by mutableStateOf<List<OfflineChannel>>(emptyList())
        private set

    /** Channels followed on Twitch (their hearts show filled). */
    var twitchFollowIds by mutableStateOf<Set<String>>(emptySet())
        private set
    var isLoading by mutableStateOf(false)
        private set
    var loaded by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    /** Something to tell the user about a follow that didn't go through. */
    var notice by mutableStateOf<String?>(null)

    private var lastRefresh = 0L

    /** Follows changed here recently: Twitch's list can take a moment to catch up. */
    private val recentChanges = HashMap<String, Pair<Boolean, Long>>()
    private var current: Deferred<Unit>? = null

    suspend fun refreshIfStale() {
        if (System.currentTimeMillis() - lastRefresh > 60_000) refresh()
    }

    /** One refresh at a time; a pull to refresh waits for the one already running. */
    suspend fun refresh(force: Boolean = false) {
        withContext(Dispatchers.Main) {
            current?.let {
                it.await()
                if (!force) return@withContext
            }
            val job = Kestrel.scope.async { load() }
            current = job
            try {
                job.await()
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                ActivityLog.add("Couldn't refresh your follows: ${e.message}")
            } finally {
                if (current === job) current = null
            }
        }
    }

    fun isFollowed(channel: Channel): Boolean = twitchFollowIds.contains(channel.id)

    /** Follows or unfollows on Twitch, showing the change at once. If Twitch won't take a follow, it goes in Kestrel's own list. */
    suspend fun setFollowed(channel: Channel, follow: Boolean): Unit = withContext(Dispatchers.Main) {
        twitchFollowIds = if (follow) twitchFollowIds + channel.id else twitchFollowIds - channel.id
        recentChanges[channel.id] = follow to System.currentTimeMillis()
        try {
            try {
                // Signed in with a code (as Twitch's TV app): the website's integrity token doesn't
                // apply to that client, so the follow goes without one first.
                val viaCode = TwitchAuth.session?.clientID == TwitchDeviceLogin.CLIENT_ID
                TwitchApi.setFollow(follow, channel.id, if (viaCode) emptyMap() else TwitchIntegrity.headers())
            } catch (e: GqlException) {
                if (!e.gqlMessage.contains("integrity", ignoreCase = true)) throw e
                // The token ran out or wasn't accepted: get a fresh one and try once more.
                TwitchApi.setFollow(follow, channel.id, TwitchIntegrity.headers(refresh = true))
            }
            ActivityLog.add(if (follow) "Followed ${channel.name} on Twitch" else "Unfollowed ${channel.name} on Twitch")
            if (!follow && FavoritesStore.contains(channel)) FavoritesStore.toggle(channel)
            Kestrel.scope.launch {
                delay(1500)
                refresh(force = true)
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            recentChanges.remove(channel.id)
            twitchFollowIds = if (follow) twitchFollowIds - channel.id else twitchFollowIds + channel.id
            val reason = e.message ?: "error"
            ActivityLog.add("Couldn't ${if (follow) "follow" else "unfollow"} ${channel.name} on Twitch: $reason")
            notice = if (follow) {
                if (!FavoritesStore.contains(channel)) FavoritesStore.toggle(channel)
                "Twitch didn't accept the follow ($reason), so ${channel.name} was added to Kestrel's Following list instead."
            } else {
                "Twitch didn't accept the unfollow ($reason)."
            }
        }
        Unit
    }

    private suspend fun load() {
        isLoading = true
        lastRefresh = System.currentTimeMillis()
        val liveById = HashMap<String, LiveStream>()
        val offlineById = HashMap<String, OfflineChannel>()
        var problem: String? = null
        try {
            if (TwitchAccount.session != null) {
                try {
                    val follows = TwitchApi.followedChannels()
                    val ids = follows.map { it.channel.id }.toMutableSet()
                    val now = System.currentTimeMillis()
                    recentChanges.entries.removeAll { now - it.value.second > 120_000 }
                    for ((id, change) in recentChanges) if (change.first) ids.add(id) else ids.remove(id)
                    twitchFollowIds = ids
                    for (follow in follows) {
                        val stream = follow.stream
                        if (stream != null) {
                            liveById[follow.channel.id] = stream
                        } else {
                            offlineById[follow.channel.id] = OfflineChannel(follow.channel, follow.lastLive)
                        }
                    }
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    problem = "Couldn't load your Twitch follows (${e.message})."
                }
            } else {
                twitchFollowIds = emptySet()
            }

            val hearted = FavoritesStore.channels.filter { liveById[it.id] == null && offlineById[it.id] == null }
            if (hearted.isNotEmpty()) {
                try {
                    val results = TwitchApi.users(hearted.map { it.login })
                    FavoritesStore.refresh(results.map { it.first })
                    for ((channel, stream) in results) {
                        if (stream != null) liveById[channel.id] = stream else offlineById[channel.id] = OfflineChannel(channel, null)
                    }
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    problem = problem ?: e.message
                }
                for (channel in hearted) {
                    if (liveById[channel.id] == null && offlineById[channel.id] == null) offlineById[channel.id] = OfflineChannel(channel, null)
                }
            }

            live = liveById.values.sortedByDescending { it.viewers }
            offline = offlineById.values.sortedWith { a, b ->
                val x = a.lastLive
                val y = b.lastLive
                when {
                    x != null && y != null -> y.compareTo(x)
                    x != null -> -1
                    y != null -> 1
                    else -> a.channel.name.lowercase().compareTo(b.channel.name.lowercase())
                }
            }
            error = problem
            loaded = true
            LiveNotifier.observe(live, complete = problem == null)
        } finally {
            isLoading = false
        }
    }
}

/**
 * Where you left off in each VOD: kept on the phone and, signed in, synced with your Twitch
 * account the way Twitch's own player does (so the website and apps agree).
 */
object WatchHistory {
    data class Entry(val position: Double, val length: Double, val updated: Long)

    private const val KEY = "watchHistory.v1"
    val entries = mutableStateMapOf<String, Entry>()
    private var syncFailureLogged = false

    init {
        Prefs.json(KEY)?.let { json ->
            for (id in json.keys()) {
                val entry = json.optJSONObject(id) ?: continue
                entries[id] = Entry(entry.optDouble("position", 0.0), entry.optDouble("length", 0.0), entry.optLong("updated", 0))
            }
        }
    }

    fun save(videoId: String, position: Double, length: Double, syncToTwitch: Boolean) {
        if (!position.isFinite() || position < 0) return
        entries[videoId] = Entry(position, length, System.currentTimeMillis())
        if (entries.size > 500) {
            entries.entries.sortedBy { it.value.updated }.take(entries.size - 500).map { it.key }.forEach { entries.remove(it) }
        }
        val json = JSONObject()
        for ((id, entry) in entries) {
            json.put(id, JSONObject().put("position", entry.position).put("length", entry.length).put("updated", entry.updated))
        }
        Prefs.setJson(KEY, json)
        if (!syncToTwitch || TwitchAccount.session == null) return
        Kestrel.scope.launch {
            try {
                TwitchApi.saveViewingPosition(videoId, position)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                if (!syncFailureLogged) {
                    syncFailureLogged = true
                    ActivityLog.add("Couldn't save your place in the VOD to Twitch (${e.message}); it's kept on this phone")
                }
            }
        }
    }

    /** The newest of: Twitch's saved position for your account, the one in the video list, and this phone's. */
    suspend fun resumePosition(video: Video): Double? {
        val candidates = mutableListOf<Pair<Double, Long>>()
        entries[video.id]?.let { candidates.add(it.position to it.updated) }
        val remote = TwitchApi.viewingPosition(video.id)
        if (remote != null) {
            candidates.add(remote.first to (remote.second ?: 0L))
        } else {
            video.watchedPosition?.let { candidates.add(it to (video.watchedAt ?: 0L)) }
        }
        return candidates.maxByOrNull { it.second }?.first
    }

    /** How far you got (0…1), for the line under a thumbnail. */
    fun progress(video: Video): Double? {
        var best: Pair<Double, Long>? = entries[video.id]?.let { it.position to it.updated }
        val position = video.watchedPosition
        if (position != null) {
            val updated = video.watchedAt ?: 0L
            if (best == null || updated > best.second) best = position to updated
        }
        val found = best ?: return null
        if (video.lengthSeconds <= 0 || found.first <= 5) return null
        return minOf(1.0, found.first / video.lengthSeconds)
    }
}

/** Earlier searches, newest first. */
object SearchHistory {
    private const val KEY = "searchHistory.v1"
    val entries = mutableStateListOf<String>()

    init {
        Prefs.string(KEY)?.let { text -> runCatching { JSONArray(text).strings() }.getOrNull()?.let { entries.addAll(it) } }
    }

    fun remember(query: String) {
        val trimmed = query.trim()
        if (trimmed.length < 2) return
        entries.removeAll { it.equals(trimmed, ignoreCase = true) }
        entries.add(0, trimmed)
        while (entries.size > 25) entries.removeAt(entries.size - 1)
        save()
    }

    fun forget(entry: String) {
        entries.remove(entry)
        save()
    }

    fun clear() {
        entries.clear()
        save()
    }

    private fun save() = Prefs.setString(KEY, JSONArray(entries.toList()).toString())
}
