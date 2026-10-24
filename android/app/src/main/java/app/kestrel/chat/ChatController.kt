package app.kestrel.chat

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.kestrel.core.ActivityLog
import app.kestrel.core.Badge
import app.kestrel.core.Channel
import app.kestrel.core.Http
import app.kestrel.core.Kestrel
import app.kestrel.core.TwitchApi
import app.kestrel.core.TwitchAuth
import app.kestrel.core.TwitchEmoteGroup
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.random.Random

data class EmoteSection(val id: String, val title: String, val icon: String?, val emotes: List<NamedEmote>)

/** Twitch chat over WebSocket IRC: as yourself when signed in (so you can send), else read-only. Main thread only. */
class ChatController(val channel: Channel, val replayVideoId: String? = null) {
    sealed class Status {
        object Connecting : Status()
        object Connected : Status()
        data class Disconnected(val reason: String) : Status()
    }

    /** A message that didn't go out (the room's rules, or Twitch refused it): back into the box. */
    data class Bounced(val id: String = UUID.randomUUID().toString(), val text: String, val reason: String)

    var status by mutableStateOf<Status>(Status.Connecting)
        private set

    /** Signed in and in the room: messages can be sent. */
    var canSend by mutableStateOf(false)
        private set

    /** Room rules worth showing (slow mode, followers-only, …). */
    var roomRules by mutableStateOf<String?>(null)
        private set
    var emoteOnly by mutableStateOf(false)
        private set
    var bounced by mutableStateOf<Bounced?>(null)
        private set

    /** Rewinding a live stream: chat replays what was said at that point of the broadcast. */
    var rewindReplay by mutableStateOf(false)
        private set

    val messages = mutableStateListOf<ChatMessage>()

    /** Bumped when emotes or badges arrive (messages are drawn again). */
    var decorationsVersion by mutableStateOf(0)
        private set
    var thirdParty: Map<String, String> = emptyMap()
        private set
    var badges: Map<String, Badge> = emptyMap()
        private set

    /** Emotes you can use here, for the picker (Recent first). */
    var emoteSections by mutableStateOf<List<EmoteSection>>(emptyList())
        private set

    /** Every emote you can type here, by name (autocomplete). */
    private var usableEmotes: List<NamedEmote> = emptyList()
    private var emoteUrls: Map<String, String> = emptyMap()

    /** Your Twitch emotes: name → ID (to show them in your own messages). */
    private var twitchEmoteIds: Map<String, String> = emptyMap()
    private var thirdPartySets = ThirdPartyEmoteSets()
    private var twitchGroups: List<TwitchEmoteGroup> = emptyList()

    /** Recent chatters, newest first (for @ autocomplete). */
    private val recentChatters = ArrayList<String>()

    private val client: OkHttpClient = Http.client.newBuilder()
        .callTimeout(0, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .pingInterval(60, TimeUnit.SECONDS)
        .build()
    private var socket: WebSocket? = null
    private val pending = ArrayList<ChatMessage>()
    private var flushScheduled = false
    private var running = false
    private var attempt = 0
    private val maxMessages = 250
    private var userState: Map<String, String> = emptyMap()
    private val room = HashMap<String, String>()
    var ownLogin: String? = null
        private set
    private var authRefused = false
    private var lastSent: Triple<String, String, Long>? = null

    private var replay = ChatReplayBuffer()
    private var rewindVideoId: String? = null
    private val liveStash = ArrayList<ChatMessage>()

    /** Bumped whenever replaying starts or stops, so late answers for the old replay are dropped. */
    private var replayEpoch = 0
    private val replaySourceId: String? get() = replayVideoId ?: rewindVideoId
    private var loadJob: Job? = null

    val isReplay: Boolean get() = replayVideoId != null

    fun start() {
        if (running) return
        running = true
        loadJob = Kestrel.scope.launch {
            val loaded = withContext(Dispatchers.Default) {
                val history = async { if (isReplay) emptyList() else runCatching { ThirdPartyEmotes.recentMessages(channel.login) }.getOrDefault(emptyList()) }
                val badgeMap = async { runCatching { TwitchApi.badges(channel.id.ifEmpty { null }) }.getOrDefault(emptyMap()) }
                val emotes = runCatching { ThirdPartyEmotes.load(channel.id.ifEmpty { null }) }.getOrDefault(ThirdPartyEmoteSets())
                Triple(history.await(), badgeMap.await(), emotes)
            }
            if (!running) return@launch
            val (recent, loadedBadges, emotes) = loaded
            thirdPartySets = emotes
            thirdParty = emotes.byName
            badges = loadedBadges
            val old = recent.mapNotNull { ChatMessage.fromIrc(it) }.filter { it.kind != ChatMessage.Kind.Notice }
            if (old.isNotEmpty() && rewindVideoId == null) {
                val combined = (old + messages).takeLast(maxMessages)
                messages.clear()
                messages.addAll(combined)
            }
            for (message in old.reversed()) noteChatter(message.displayName)
            rebuildEmoteSections()
            decorationsVersion++
        }
        if (isReplay) {
            status = Status.Connected
            return
        }
        loadTwitchEmotes()
        connect()
    }

    fun stop() {
        running = false
        loadJob?.cancel()
        socket?.close(1000, null)
        socket = null
    }

    // MARK: VOD chat replay

    /** Shows what was said up to `position` (seconds into the VOD), fetching ahead as it plays. */
    fun replay(position: Double) {
        val videoId = replaySourceId ?: return
        if (!running || !position.isFinite()) return
        if (replay.move(position)) {
            // A seek: start over from a little before the new position.
            pending.clear()
            messages.clear()
        }
        releaseReplay()
        fetchReplayIfNeeded(videoId)
    }

    /** Rewinding a live stream: show chat as it was at `position` (seconds into the broadcast). */
    fun startRewindReplay(videoId: String, position: Double) {
        if (replayVideoId != null || !running || rewindVideoId != null) return
        rewindVideoId = videoId
        rewindReplay = true
        replayEpoch++
        liveStash.clear()
        liveStash.addAll((messages + pending).takeLast(maxMessages))
        pending.clear()
        messages.clear()
        replay = ChatReplayBuffer()
        replay(position)
    }

    /** Back to live: live chat again, including what arrived meanwhile. */
    fun endRewindReplay() {
        if (rewindVideoId == null) return
        rewindVideoId = null
        rewindReplay = false
        replayEpoch++
        replay = ChatReplayBuffer()
        pending.clear()
        messages.clear()
        messages.addAll(liveStash.takeLast(maxMessages))
        liveStash.clear()
    }

    private fun releaseReplay() {
        for (message in replay.due()) enqueue(message, live = false)
    }

    private fun fetchReplayIfNeeded(videoId: String) {
        val offset = replay.fetchNeeded() ?: return
        val generation = replay.generation
        val epoch = replayEpoch
        Kestrel.scope.launch {
            try {
                val page = TwitchApi.videoComments(videoId, offset, null)
                if (epoch != replayEpoch) return@launch
                replay.received(page.comments, offset, generation)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                if (epoch != replayEpoch) return@launch
                replay.failed(generation)
                if (generation == replay.generation) {
                    ActivityLog.add("Chat replay: ${e.message}")
                    if (messages.isEmpty() && pending.isEmpty()) {
                        val text = if (rewindReplay) "Chat from this part of the stream isn't available yet." else "Chat replay isn't available for this video right now."
                        enqueue(ChatMessage.notice(text), live = false)
                    }
                }
            }
            if (epoch != replayEpoch || generation != replay.generation) return@launch
            releaseReplay()
            // Keep reading until there's chat ahead of the video (or there's none yet).
            fetchReplayIfNeeded(videoId)
        }
    }

    // MARK: Emotes

    /** Your Twitch emotes for this channel (needs sign-in). */
    fun loadTwitchEmotes() {
        val channelId = channel.id.ifEmpty { null }
        Kestrel.scope.launch {
            twitchGroups = runCatching { TwitchApi.availableEmotes(channelId) }.getOrDefault(emptyList())
            rebuildEmoteSections()
        }
    }

    /** The picture for an emote name you can use here. */
    fun emoteUrl(name: String): String? = emoteUrls[name]

    private fun rebuildEmoteSections() {
        val sections = mutableListOf<EmoteSection>()
        val ids = HashMap<String, String>()
        // Your Twitch emotes by owner: this channel first, then other channels, then Twitch's own.
        class Owner(var name: String?, var image: String?, val emotes: MutableList<app.kestrel.core.TwitchEmote>)
        val byOwner = LinkedHashMap<String, Owner>()
        for (group in twitchGroups) {
            val key = group.ownerID?.takeIf { it.isNotEmpty() && it != "0" } ?: "twitch"
            val entry = byOwner.getOrPut(key) { Owner(group.ownerName, group.ownerImage, mutableListOf()) }
            entry.emotes.addAll(group.emotes)
            if (entry.name == null) entry.name = group.ownerName
            if (entry.image == null) entry.image = group.ownerImage
        }
        fun twitchSection(key: String, title: String): EmoteSection? {
            val entry = byOwner[key] ?: return null
            val seen = HashSet<String>()
            val emotes = entry.emotes.mapNotNull { emote ->
                if (!seen.add(emote.token)) return@mapNotNull null
                ids[emote.token] = emote.id
                NamedEmote(emote.token, emote.url)
            }
            if (emotes.isEmpty()) return null
            return EmoteSection("twitch-$key", title, entry.image, emotes)
        }
        twitchSection(channel.id, channel.name)?.let { sections.add(it) }
        for (section in thirdPartySets.channel) {
            sections.add(EmoteSection("channel-${section.title}", "${section.title} · ${channel.name}", null, section.emotes))
        }
        val others = byOwner.keys.filter { it != channel.id && it != "twitch" }
            .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { byOwner[it]?.name ?: "~" })
        for (key in others) twitchSection(key, byOwner[key]?.name ?: "Subscriptions")?.let { sections.add(it) }
        twitchSection("twitch", "Twitch")?.let { sections.add(it) }
        for (section in thirdPartySets.global) {
            sections.add(EmoteSection("global-${section.title}", section.title, null, section.emotes))
        }
        twitchEmoteIds = ids

        // Everything usable by name (Twitch emotes win over third-party ones with the same name).
        val byName = HashMap<String, NamedEmote>()
        for (section in sections.reversed()) for (emote in section.emotes) byName[emote.name] = emote
        usableEmotes = byName.values.sortedBy { it.name.length }
        emoteUrls = byName.mapValues { it.value.url }
        val recent = RecentEmotes.names.mapNotNull { byName[it] }
        if (recent.isNotEmpty()) sections.add(0, EmoteSection("recent", "Recent", null, recent))
        emoteSections = sections
    }

    /** Emotes for `query` (typed after ":"): prefix matches first, then the rest containing it. */
    fun emoteSuggestions(query: String, limit: Int = 40): List<NamedEmote> {
        if (query.isEmpty()) return emptyList()
        val prefix = mutableListOf<NamedEmote>()
        val contains = mutableListOf<NamedEmote>()
        for (emote in usableEmotes) {
            if (emote.name.startsWith(query, ignoreCase = true)) prefix.add(emote)
            else if (emote.name.contains(query, ignoreCase = true)) contains.add(emote)
            if (prefix.size >= limit) break
        }
        return (prefix + contains).take(limit)
    }

    fun chatterSuggestions(query: String, limit: Int = 20): List<String> =
        recentChatters.filter { query.isEmpty() || it.startsWith(query, ignoreCase = true) }.take(limit)

    private fun noteChatter(name: String) {
        if (name.isEmpty()) return
        recentChatters.remove(name)
        recentChatters.add(0, name)
        if (recentChatters.size > 300) recentChatters.removeAt(recentChatters.size - 1)
    }

    // MARK: Sending

    /** After signing in or out. */
    fun reconnect() {
        if (!running || isReplay) return
        authRefused = false
        loadTwitchEmotes()
        socket?.close(1000, null)
        socket = null
        connect()
    }

    fun send(raw: String) {
        val text = raw.trim()
        val socket = socket
        val login = ownLogin
        if (!canSend || text.isEmpty() || socket == null || login == null) return
        // Emote-only: Twitch would refuse anything but Twitch emotes, so don't send it at all.
        if (emoteOnly && twitchEmoteIds.isNotEmpty() && !onlyEmotes(text, twitchEmoteIds)) {
            bounced = Bounced(text = raw, reason = "Emote-only chat: only Twitch emotes you have can be sent")
            return
        }
        val target = "#${channel.login.lowercase()}"
        val line = if (text.startsWith("/me ")) "PRIVMSG $target :\u0001ACTION ${text.substring(4)}\u0001" else "PRIVMSG $target :$text"
        if (!socket.send(line)) {
            enqueue(ChatMessage.notice("Couldn't send: chat isn't connected"))
            return
        }
        val echo = ChatMessage.sent(text, userState, login, twitchEmoteIds)
        lastSent = Triple(echo.id, raw, System.currentTimeMillis())
        enqueue(echo)
        val used = text.split(' ').filter { emoteUrls.containsKey(it) }.distinct()
        if (used.isNotEmpty()) {
            RecentEmotes.add(used)
            rebuildEmoteSections()
        }
    }

    private fun onlyEmotes(text: String, emotes: Map<String, String>): Boolean {
        val words = text.split(' ').filter { it.isNotEmpty() }
        return words.isNotEmpty() && words.all { emotes.containsKey(it) }
    }

    /** Twitch refused the message just sent: take the echo back out and return the text. */
    private fun refused(reason: String) {
        val sent = lastSent ?: return
        if (System.currentTimeMillis() - sent.third > 10_000) return
        lastSent = null
        pending.removeAll { it.id == sent.first }
        messages.removeAll { it.id == sent.first }
        bounced = Bounced(text = sent.second, reason = reason)
    }

    // MARK: Connection

    private fun connect() {
        if (!running) return
        status = Status.Connecting
        canSend = false
        val lines = mutableListOf("CAP REQ :twitch.tv/tags twitch.tv/commands")
        val session = TwitchAuth.session
        if (!authRefused && session != null) {
            ownLogin = session.login.lowercase()
            lines.add("PASS oauth:${session.token}")
            lines.add("NICK ${session.login.lowercase()}")
        } else {
            ownLogin = null
            lines.add("PASS SCHMOOPIIE")
            lines.add("NICK justinfan${Random.nextInt(10000, 99999)}")
        }
        lines.add("JOIN #${channel.login.lowercase()}")
        val request = Request.Builder().url("wss://irc-ws.chat.twitch.tv:443").build()
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                for (line in lines) webSocket.send(line)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                Kestrel.scope.launch { if (socket === webSocket) handle(text) }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Kestrel.scope.launch { if (socket === webSocket) dropped() }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Kestrel.scope.launch { if (socket === webSocket) dropped() }
            }
        }
        socket = client.newWebSocket(request, listener)
    }

    private fun dropped() {
        socket = null
        canSend = false
        if (!running) return
        attempt++
        status = Status.Disconnected("Reconnecting…")
        val delayMs = minOf(15_000L, 1000L shl minOf(attempt, 4))
        Kestrel.scope.launch {
            delay(delayMs)
            if (running && socket == null) connect()
        }
    }

    private fun handle(text: String) {
        for (line in text.split("\r\n", "\n")) {
            val irc = IrcMessage.parse(line) ?: continue
            when (irc.command) {
                "PING" -> socket?.send("PONG :${irc.trailing ?: "tmi.twitch.tv"}")
                "001" -> attempt = 0
                "366" -> status = Status.Connected
                "ROOMSTATE" -> {
                    status = Status.Connected
                    room.putAll(irc.tags)
                    roomRules = describe(room)
                    emoteOnly = room["emote-only"] == "1"
                }
                "USERSTATE" -> {
                    userState = irc.tags
                    canSend = ownLogin != null
                }
                "CLEARMSG" -> irc.tags["target-msg-id"]?.let { id -> markDeleted { it.id == id } }
                "CLEARCHAT" -> {
                    val login = irc.trailing?.lowercase()
                    if (irc.params.size > 1 && login != null) markDeleted { it.login.lowercase() == login }
                }
                "RECONNECT" -> socket?.close(1000, null)
                "NOTICE" -> {
                    val message = irc.trailing ?: ""
                    if (message.contains("authentication failed", ignoreCase = true) ||
                        message.contains("improperly formatted auth", ignoreCase = true)
                    ) {
                        // The token doesn't work for chat: read as a guest instead of not at all.
                        authRefused = true
                        enqueue(ChatMessage.notice("Twitch didn't accept your sign-in for chat, so it's read-only. Sign in again in Settings."))
                        socket?.close(1000, null)
                        socket = null
                        connect()
                        return
                    }
                    // msg_emoteonly, msg_followersonly, msg_slowmode, msg_duplicate, …: your message didn't go out.
                    val id = irc.tags["msg-id"]
                    if (id != null && id.startsWith("msg_")) refused(message)
                    ChatMessage.fromIrc(irc)?.let { enqueue(it) }
                }
                else -> ChatMessage.fromIrc(irc)?.let { message ->
                    if (message.kind == ChatMessage.Kind.Message || message.kind == ChatMessage.Kind.Action) noteChatter(message.displayName)
                    enqueue(message)
                }
            }
        }
    }

    private fun describe(room: Map<String, String>): String? {
        val rules = mutableListOf<String>()
        room["slow"]?.toIntOrNull()?.let { if (it > 0) rules.add("Slow mode ${it}s") }
        room["followers-only"]?.toIntOrNull()?.let { if (it >= 0) rules.add(if (it == 0) "Followers-only" else "Followers-only ($it min)") }
        if (room["subs-only"] == "1") rules.add("Subscribers-only")
        if (room["emote-only"] == "1") rules.add("Emote-only")
        return if (rules.isEmpty()) null else rules.joinToString(" · ")
    }

    private fun markDeleted(predicate: (ChatMessage) -> Boolean) {
        for (i in messages.indices) {
            val message = messages[i]
            if (predicate(message) && !message.isDeleted) messages[i] = message.copy(isDeleted = true)
        }
    }

    /** `live`: from live chat (held back while rewinding), or the replay's. */
    private fun enqueue(message: ChatMessage, live: Boolean = true) {
        if (live && rewindVideoId != null) {
            liveStash.add(message)
            if (liveStash.size > maxMessages + 50) liveStash.subList(0, liveStash.size - maxMessages).clear()
            return
        }
        pending.add(message)
        if (flushScheduled) return
        flushScheduled = true
        Kestrel.scope.launch {
            delay(150)
            flush()
        }
    }

    private fun flush() {
        flushScheduled = false
        if (pending.isEmpty()) return
        messages.addAll(pending)
        pending.clear()
        if (messages.size > maxMessages) messages.removeRange(0, messages.size - maxMessages)
    }
}
