package app.kestrel.chat

import app.kestrel.core.arr
import app.kestrel.core.bool
import app.kestrel.core.int
import app.kestrel.core.obj
import app.kestrel.core.objects
import app.kestrel.core.parseDate
import app.kestrel.core.str
import app.kestrel.core.twitchEmoteUrl
import org.json.JSONObject
import java.util.UUID

// Twitch chat (IRC over WebSocket) parsing, messages and VOD chat replay.

data class IrcMessage(
    val tags: Map<String, String>,
    val prefix: String?,
    val command: String,
    val params: List<String>,
) {
    val trailing: String? get() = params.lastOrNull()
    val nick: String? get() = prefix?.substringBefore('!')

    companion object {
        fun unescapeTag(value: String): String {
            if (!value.contains('\\')) return value
            val result = StringBuilder()
            var escaping = false
            for (c in value) {
                if (escaping) {
                    when (c) {
                        ':' -> result.append(';')
                        's' -> result.append(' ')
                        'r' -> result.append('\r')
                        'n' -> result.append('\n')
                        else -> result.append(c)
                    }
                    escaping = false
                } else if (c == '\\') {
                    escaping = true
                } else {
                    result.append(c)
                }
            }
            return result.toString()
        }

        fun parse(raw: String): IrcMessage? {
            var rest = raw.trim('\r', '\n')
            if (rest.isEmpty()) return null
            val tags = HashMap<String, String>()
            if (rest.startsWith("@")) {
                val space = rest.indexOf(' ')
                if (space < 0) return null
                for (pair in rest.substring(1, space).split(';')) {
                    if (pair.isEmpty()) continue
                    val eq = pair.indexOf('=')
                    if (eq >= 0) tags[pair.substring(0, eq)] = unescapeTag(pair.substring(eq + 1)) else tags[pair] = ""
                }
                rest = rest.substring(space + 1).trimStart(' ')
            }
            var prefix: String? = null
            if (rest.startsWith(":")) {
                val space = rest.indexOf(' ')
                if (space < 0) return null
                prefix = rest.substring(1, space)
                rest = rest.substring(space + 1).trimStart(' ')
            }
            val params = mutableListOf<String>()
            var command = ""
            while (rest.isNotEmpty()) {
                if (rest.startsWith(":") && command.isNotEmpty()) {
                    params.add(rest.substring(1))
                    break
                }
                val end = rest.indexOf(' ').let { if (it < 0) rest.length else it }
                val token = rest.substring(0, end)
                if (command.isEmpty()) command = token else params.add(token)
                rest = if (end >= rest.length) "" else rest.substring(end + 1).trimStart(' ')
            }
            if (command.isEmpty()) return null
            return IrcMessage(tags, prefix, command, params)
        }
    }
}

sealed class ChatFragment {
    data class Text(val text: String) : ChatFragment()
    data class Emote(val name: String, val url: String) : ChatFragment()
}

/** A Twitch emote in a message: code point positions (inclusive), like the IRC `emotes` tag. */
data class EmoteRange(val id: String, val start: Int, val end: Int)

data class ChatMessage(
    val id: String,
    val kind: Kind,
    val login: String,
    val displayName: String,
    val color: String?,
    /** "subscriber/12" */
    val badges: List<String>,
    val text: String,
    val systemText: String?,
    val emotes: List<EmoteRange>,
    val timestamp: Long,
    val isDeleted: Boolean = false,
) {
    enum class Kind { Message, Action, System, Notice }

    /** Whether the message mentions `login` (for highlighting). */
    fun mentions(login: String): Boolean = login.isNotEmpty() && text.contains("@$login", ignoreCase = true)

    /** The text split into plain text and emotes (Twitch emotes by position, third-party ones by word). */
    fun fragments(thirdParty: Map<String, String>): List<ChatFragment> {
        val points = text.codePoints().toArray()
        val pieces = mutableListOf<ChatFragment>()
        var cursor = 0
        fun appendText(from: Int, to: Int) {
            if (from >= to) return
            pieces.addAll(splitThirdParty(String(points, from, to - from), thirdParty))
        }
        for (emote in emotes) {
            val start = emote.start
            val end = emote.end + 1
            if (start < cursor || end > points.size) continue
            appendText(cursor, start)
            pieces.add(ChatFragment.Emote(String(points, start, end - start), twitchEmoteUrl(emote.id)))
            cursor = end
        }
        appendText(cursor, points.size)
        // Merge neighbouring text pieces.
        val merged = mutableListOf<ChatFragment>()
        for (piece in pieces) {
            val last = merged.lastOrNull()
            if (piece is ChatFragment.Text && last is ChatFragment.Text) {
                merged[merged.size - 1] = ChatFragment.Text(last.text + piece.text)
            } else {
                merged.add(piece)
            }
        }
        return merged
    }

    companion object {
        fun fromIrc(irc: IrcMessage): ChatMessage? {
            val tags = irc.tags
            return when (irc.command) {
                "PRIVMSG", "USERNOTICE" -> {
                    var text = if (irc.params.size > 1) irc.trailing ?: "" else ""
                    var kind = if (irc.command == "USERNOTICE") Kind.System else Kind.Message
                    if (text.startsWith("\u0001ACTION ") && text.endsWith("\u0001")) {
                        text = text.substring(8, text.length - 1)
                        kind = Kind.Action
                    }
                    val login = tags["login"] ?: irc.nick ?: ""
                    val systemText = if (irc.command == "USERNOTICE") tags["system-msg"] else null
                    if (kind == Kind.System && systemText == null && text.isEmpty()) return null
                    ChatMessage(
                        id = tags["id"] ?: UUID.randomUUID().toString(),
                        kind = kind,
                        login = login,
                        displayName = tags["display-name"]?.takeIf { it.isNotEmpty() } ?: login,
                        color = tags["color"]?.takeIf { it.isNotEmpty() },
                        badges = (tags["badges"] ?: "").split(',').filter { it.isNotEmpty() },
                        text = text,
                        systemText = systemText,
                        emotes = parseEmotes(tags["emotes"] ?: ""),
                        timestamp = tags["tmi-sent-ts"]?.toLongOrNull() ?: System.currentTimeMillis(),
                    )
                }
                "NOTICE" -> ChatMessage(
                    id = tags["msg-id"]?.let { "$it-${UUID.randomUUID()}" } ?: UUID.randomUUID().toString(),
                    kind = Kind.Notice,
                    login = "",
                    displayName = "",
                    color = null,
                    badges = emptyList(),
                    text = irc.trailing ?: "",
                    systemText = null,
                    emotes = emptyList(),
                    timestamp = System.currentTimeMillis(),
                )
                else -> null
            }
        }

        /** A message you sent: Twitch doesn't echo your own, so it's shown from your USERSTATE. */
        fun sent(raw: String, userState: Map<String, String>, login: String, emoteIds: Map<String, String>): ChatMessage {
            var body = raw
            var kind = Kind.Message
            if (body.startsWith("/me ")) {
                body = body.substring(4)
                kind = Kind.Action
            }
            return ChatMessage(
                id = "local-${UUID.randomUUID()}",
                kind = kind,
                login = login,
                displayName = userState["display-name"]?.takeIf { it.isNotEmpty() } ?: login,
                color = userState["color"]?.takeIf { it.isNotEmpty() },
                badges = (userState["badges"] ?: "").split(',').filter { it.isNotEmpty() },
                text = body,
                systemText = null,
                emotes = emoteRanges(body, emoteIds),
                timestamp = System.currentTimeMillis(),
            )
        }

        /** A line from Kestrel itself (connection state, chat rules). */
        fun notice(text: String): ChatMessage = ChatMessage(
            id = "notice-${UUID.randomUUID()}",
            kind = Kind.Notice,
            login = "",
            displayName = "",
            color = null,
            badges = emptyList(),
            text = text,
            systemText = null,
            emotes = emptyList(),
            timestamp = System.currentTimeMillis(),
        )

        /** A message from Twitch's VOD comments (`video.comments` nodes). */
        fun fromComment(node: JSONObject): ChatMessage? {
            val id = node.str("id") ?: return null
            val message = node.obj("message")
            val text = StringBuilder()
            val emotes = mutableListOf<EmoteRange>()
            var offset = 0
            for (fragment in message?.arr("fragments").objects()) {
                val piece = fragment.str("text") ?: ""
                val length = piece.codePointCount(0, piece.length)
                val emote = fragment.obj("emote")
                val emoteId = emote?.str("emoteID") ?: emote?.str("id")
                if (emoteId != null && length > 0) emotes.add(EmoteRange(emoteId, offset, offset + length - 1))
                text.append(piece)
                offset += length
            }
            if (text.isEmpty()) return null
            val commenter = node.obj("commenter")
            val login = commenter?.str("login") ?: ""
            return ChatMessage(
                id = id,
                kind = Kind.Message,
                login = login,
                displayName = commenter?.str("displayName") ?: login,
                color = message?.str("userColor")?.takeIf { it.isNotEmpty() },
                badges = message?.arr("userBadges").objects().mapNotNull { badge ->
                    val set = badge.str("setID")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                    val version = badge.str("version") ?: return@mapNotNull null
                    "$set/$version"
                },
                text = text.toString(),
                systemText = null,
                emotes = emotes,
                timestamp = parseDate(node.str("createdAt")) ?: System.currentTimeMillis(),
            )
        }

        fun parseEmotes(tag: String): List<EmoteRange> {
            val result = mutableListOf<EmoteRange>()
            for (entry in tag.split('/')) {
                val colon = entry.indexOf(':')
                if (colon < 0) continue
                val id = entry.substring(0, colon)
                for (span in entry.substring(colon + 1).split(',')) {
                    val bounds = span.split('-')
                    if (bounds.size != 2) continue
                    val a = bounds[0].toIntOrNull() ?: continue
                    val b = bounds[1].toIntOrNull() ?: continue
                    if (a <= b) result.add(EmoteRange(id, a, b))
                }
            }
            return result.sortedBy { it.start }
        }

        /** Twitch emotes in your own text (Twitch doesn't send them back): whole words matching one you have. */
        fun emoteRanges(text: String, ids: Map<String, String>): List<EmoteRange> {
            if (ids.isEmpty()) return emptyList()
            val result = mutableListOf<EmoteRange>()
            val points = text.codePoints().toArray()
            var start = 0
            var i = 0
            while (i <= points.size) {
                if (i == points.size || points[i] == ' '.code) {
                    if (i > start) {
                        val word = String(points, start, i - start)
                        ids[word]?.let { result.add(EmoteRange(it, start, i - 1)) }
                    }
                    start = i + 1
                }
                i++
            }
            return result
        }

        private fun splitThirdParty(text: String, emotes: Map<String, String>): List<ChatFragment> {
            if (emotes.isEmpty()) return listOf(ChatFragment.Text(text))
            val result = mutableListOf<ChatFragment>()
            val buffer = StringBuilder()
            val word = StringBuilder()
            fun flushWord() {
                val url = emotes[word.toString()]
                if (url != null) {
                    if (buffer.isNotEmpty()) result.add(ChatFragment.Text(buffer.toString()))
                    buffer.setLength(0)
                    result.add(ChatFragment.Emote(word.toString(), url))
                } else {
                    buffer.append(word)
                }
                word.setLength(0)
            }
            for (c in text) {
                if (c == ' ') {
                    flushWord()
                    buffer.append(c)
                } else {
                    word.append(c)
                }
            }
            flushWord()
            if (buffer.isNotEmpty()) result.add(ChatFragment.Text(buffer.toString()))
            return result
        }
    }
}

// MARK: VOD chat (replay)

/** A VOD chat message and when it was sent, in seconds into the video. */
data class ReplayComment(val offset: Double, val message: ChatMessage)

data class CommentPage(val comments: List<ReplayComment>, val cursor: String?, val hasMore: Boolean)

object VodComments {
    fun parsePage(data: JSONObject): CommentPage {
        val connection = data.obj("video")?.obj("comments")
        val edges = connection?.arr("edges").objects()
        val comments = edges.mapNotNull { edge ->
            val node = edge.obj("node") ?: return@mapNotNull null
            val message = ChatMessage.fromComment(node) ?: return@mapNotNull null
            ReplayComment((node.int("contentOffsetSeconds") ?: 0).toDouble(), message)
        }
        val more = connection?.obj("pageInfo")?.bool("hasNextPage") ?: edges.isNotEmpty()
        return CommentPage(comments, edges.lastOrNull()?.str("cursor"), more)
    }
}

/**
 * The VOD chat replay's bookkeeping: what's been fetched, what's been shown, and where the next
 * page starts. Twitch only lets other apps page VOD chat by time, so pages are asked for by offset.
 */
class ChatReplayBuffer {
    var position = -1.0
        private set
    private var nextOffset = 0
    private var exhaustedAt: Long? = null
    private var loading = false
    private var queue = listOf<ReplayComment>()
    private val seen = HashSet<String>()

    /** Bumped on every seek, so pages that arrive late for an old position are ignored. */
    var generation = 0
        private set

    /** Moves to `position`. Returns true when that's a seek (chat should start over). */
    fun move(to: Double): Boolean {
        val jumped = position < 0 || to < position - 3 || to > position + 25
        position = to
        if (!jumped) return false
        generation++
        queue = emptyList()
        seen.clear()
        nextOffset = maxOf(0, to.toInt() - 20)
        exhaustedAt = null
        loading = false
        return true
    }

    /** The offset to fetch now, if chat is running low (about half a minute is kept ready). */
    fun fetchNeeded(now: Long = System.currentTimeMillis()): Int? {
        if (loading) return null
        exhaustedAt?.let { if (now - it < 20_000) return null }
        val readyUntil = queue.lastOrNull()?.offset ?: nextOffset.toDouble()
        if (!(readyUntil < position + 30 || (queue.isEmpty() && nextOffset <= position + 30))) return null
        loading = true
        return nextOffset
    }

    /** A page arrived for `offset` (ignored if it's for an old position). */
    fun received(comments: List<ReplayComment>, offset: Int, generation: Int, now: Long = System.currentTimeMillis()) {
        if (generation != this.generation) return
        loading = false
        val fresh = comments.filter { seen.add(it.message.id) }
        val last = comments.lastOrNull()
        if (last != null) {
            // Next page from the last second seen; a page with nothing new moves a second on.
            val lastSecond = last.offset.toInt()
            nextOffset = if (fresh.isEmpty() || lastSecond <= offset) maxOf(offset, lastSecond) + 1 else lastSecond
            exhaustedAt = null
        } else {
            exhaustedAt = now
        }
        queue = (queue + fresh).sortedBy { it.offset }
    }

    fun failed(generation: Int, now: Long = System.currentTimeMillis()) {
        if (generation != this.generation) return
        loading = false
        exhaustedAt = now
    }

    /** Messages due by now. */
    fun due(): List<ChatMessage> {
        var count = 0
        while (count < queue.size && queue[count].offset <= position) count++
        if (count == 0) return emptyList()
        val messages = queue.take(count).map { it.message }
        queue = queue.drop(count)
        return messages
    }
}
