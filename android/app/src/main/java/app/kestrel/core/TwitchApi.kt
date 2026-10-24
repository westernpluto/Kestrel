package app.kestrel.core

import app.kestrel.chat.CommentPage
import app.kestrel.chat.VodComments
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs
import kotlin.random.Random

/**
 * Twitch's GraphQL API (the endpoint the website uses). Query shapes follow Xtra
 * (github.com/crackededed/Xtra). Queries are written with `@name` for GraphQL variables (Kotlin
 * reserves `$` in strings); `gql()` turns them back into `$name`.
 */
object TwitchApi {
    const val CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private const val PLAYBACK_TOKEN_HASH = "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"
    private const val FOLLOW_HASH = "800e7346bdf7e5278a3c1d3f21b2b56e2639928f86815677a7126b093b2fdd08"
    private const val UNFOLLOW_HASH = "f7dae976ebf41c755ae2d758546bfd176b4eeb856656098bb40e0a672ca0d880"
    private const val AVAILABLE_EMOTES_HASH = "6c45e0ecaa823cc7db3ecdd1502af2223c775bdcfb0f18a3a0ce9a0b7db8ef6c"
    private const val VIDEO_COMMENTS_HASH = "b70a3591ff0f4e0313d126c6a1502d79a1c02baebb288227c582044aa76adf6a"
    private const val SEEKBAR_PREVIEW_HASH = "07e99e4d56c5a7c67117a154777b0baf85a5ffefa393b213f4bc712ccaf85dd6"

    private val JSON = "application/json".toMediaType()

    /** Used for playback tokens instead of the usual client (e.g. through a proxy in an ad-free country). */
    @Volatile
    var playbackClient: OkHttpClient? = null

    /** Set when a signed-in token request failed and an anonymous one was used instead. */
    @Volatile
    var lastAuthFallback: String? = null

    /** A device ID for anonymous requests, kept for this install. */
    val deviceId: String by lazy {
        Prefs.string("kestrel.deviceID")?.takeIf { it.length == 32 } ?: run {
            val generated = (0 until 32).map { "0123456789abcdef"[Random.nextInt(16)] }.joinToString("")
            Prefs.setString("kestrel.deviceID", generated)
            generated
        }
    }

    /** The device ID that goes with the signed-in account (the website's `unique_id`). */
    val accountDeviceId: String get() = TwitchAuth.session?.deviceID ?: deviceId

    @Volatile
    private var tagsSupported = true
    private const val TAG_FIELDS = "freeformTags { name }"

    private fun gql(text: String) = text.replace('@', '$')

    private fun request(body: JSONObject, anonymous: Boolean, headers: Map<String, String> = emptyMap()): Request {
        val session = if (anonymous) null else TwitchAuth.session
        val builder = Request.Builder()
            .url("https://gql.twitch.tv/gql")
            .header("Client-ID", CLIENT_ID)
            .header("X-Device-Id", session?.deviceID ?: deviceId)
            .header("User-Agent", Browser.USER_AGENT)
            .post(body.toString().toRequestBody(JSON))
        if (session != null) builder.header("Authorization", "OAuth ${session.token}")
        for ((name, value) in headers) builder.header(name, value)
        return builder.build()
    }

    private suspend fun perform(request: Request, via: OkHttpClient? = null): JSONObject {
        val result = (via ?: Http.client).fetch(request)
        val json = runCatching { JSONObject(result.body) }.getOrNull()
            ?: throw TwitchException(
                if (result.code == 200) "Unexpected response from Twitch." else "Twitch returned HTTP ${result.code}.",
            )
        val data = json.obj("data")
        if (data == null) {
            val message = json.arr("errors")?.optJSONObject(0)?.str("message") ?: json.str("message")
            if (message != null) throw GqlException(message)
            throw TwitchException("Twitch returned HTTP ${result.code}.")
        }
        return data
    }

    private suspend fun send(
        body: JSONObject,
        anonymous: Boolean,
        via: OkHttpClient? = null,
        headers: Map<String, String> = emptyMap(),
    ): JSONObject {
        if (!tagsSupported) body.str("query")?.let { body.put("query", it.replace(TAG_FIELDS, "")) }
        return try {
            perform(request(body, anonymous, headers), via)
        } catch (e: GqlException) {
            // Twitch stopped knowing the tags field: browse without tags rather than not at all.
            val text = body.str("query")
            if (!e.gqlMessage.contains("freeformTags") || text == null) throw e
            tagsSupported = false
            body.put("query", text.replace(TAG_FIELDS, ""))
            perform(request(body, anonymous, headers), via)
        }
    }

    /** A raw query (named `null`, like Xtra). Browsing goes out anonymously; only account features send the token. */
    suspend fun query(text: String, variables: JSONObject = JSONObject(), authenticated: Boolean = false): JSONObject =
        send(JSONObject().put("query", gql(text)).put("variables", variables), anonymous = !authenticated)

    private fun persisted(operation: String, hash: String, variables: JSONObject): JSONObject = JSONObject()
        .put("operationName", operation)
        .put("variables", variables)
        .put("extensions", JSONObject().put("persistedQuery", JSONObject().put("version", 1).put("sha256Hash", hash)))

    private fun vars(vararg pairs: Pair<String, Any?>): JSONObject {
        val json = JSONObject()
        for ((key, value) in pairs) {
            when (value) {
                null -> Unit
                is List<*> -> json.put(key, JSONArray(value))
                else -> json.put(key, value)
            }
        }
        return json
    }

    // MARK: Parsing

    fun channel(j: JSONObject?): Channel? {
        if (j == null) return null
        val id = j.str("id") ?: return null
        val login = j.str("login") ?: return null
        return Channel(id, login, j.str("displayName") ?: login, j.str("profileImageURL"))
    }

    fun category(j: JSONObject?): Category? {
        if (j == null) return null
        val id = j.str("id") ?: return null
        return Category(id, j.str("displayName") ?: j.str("name") ?: "", j.str("slug"), j.str("boxArtURL"), j.int("viewersCount") ?: 0)
    }

    fun stream(j: JSONObject?, fallback: Channel? = null): LiveStream? {
        if (j == null) return null
        val channel = channel(j.obj("broadcaster")) ?: fallback ?: return null
        val title = j.at("broadcaster", "broadcastSettings")?.str("title") ?: j.str("title") ?: ""
        return LiveStream(
            id = j.str("id") ?: channel.id,
            title = title,
            viewers = j.int("viewersCount") ?: 0,
            previewImageURL = j.str("previewImageURL"),
            startedAt = parseDate(j.str("createdAt")),
            category = category(j.obj("game")),
            channel = channel,
            tags = j.arr("freeformTags").objects().mapNotNull { it.str("name") },
        )
    }

    fun video(j: JSONObject?, owner: Channel? = null): Video? {
        if (j == null) return null
        val id = j.str("id") ?: return null
        val history = j.at("self", "viewingHistory")
        return Video(
            id = id,
            title = j.str("title") ?: "",
            lengthSeconds = j.int("lengthSeconds") ?: 0,
            previewURL = j.str("previewThumbnailURL"),
            createdAt = parseDate(j.str("createdAt")),
            viewCount = j.int("viewCount") ?: 0,
            categoryName = j.obj("game")?.str("displayName"),
            owner = channel(j.obj("owner")) ?: owner,
            watchedPosition = history?.int("position")?.toDouble(),
            watchedAt = parseDate(history?.str("updatedAt")),
        )
    }

    private fun <T> page(connection: JSONObject?, map: (JSONObject) -> T?): Page<T> {
        val edges = connection?.arr("edges").objects()
        return Page(
            items = edges.mapNotNull { edge -> edge.obj("node")?.let(map) },
            cursor = edges.lastOrNull()?.str("cursor"),
            hasNextPage = connection?.obj("pageInfo")?.bool("hasNextPage") ?: edges.isNotEmpty(),
        )
    }

    private const val STREAM_FIELDS =
        "broadcaster { broadcastSettings { title } displayName id login profileImageURL(width: 300) } " +
            "createdAt game { displayName id slug } id previewImageURL viewersCount freeformTags { name }"

    // MARK: Browse

    suspend fun topStreams(after: String? = null, first: Int = 30): Page<LiveStream> {
        val data = query(
            """
            query null(@sort: StreamSort, @first: Int, @after: Cursor) {
              streams(first: @first, after: @after, options: { sort: @sort }) {
                edges { cursor node { $STREAM_FIELDS } }
                pageInfo { hasNextPage }
              }
            }
            """,
            vars("sort" to "VIEWER_COUNT", "first" to first, "after" to after),
        )
        return page(data.obj("streams")) { stream(it) }
    }

    suspend fun topCategories(after: String? = null, first: Int = 40): Page<Category> {
        val data = query(
            """
            query null(@first: Int, @after: Cursor) {
              games(first: @first, after: @after) {
                edges { cursor node { boxArtURL displayName id slug viewersCount } }
                pageInfo { hasNextPage }
              }
            }
            """,
            vars("first" to first, "after" to after),
        )
        return page(data.obj("games")) { category(it) }
    }

    suspend fun categoryStreams(id: String, after: String? = null, first: Int = 30): Page<LiveStream> {
        val data = query(
            """
            query null(@id: ID, @sort: StreamSort, @first: Int, @after: Cursor) {
              game(id: @id) {
                streams(first: @first, after: @after, options: { sort: @sort }) {
                  edges { cursor node { $STREAM_FIELDS } }
                  pageInfo { hasNextPage }
                }
              }
            }
            """,
            vars("id" to id, "sort" to "VIEWER_COUNT", "first" to first, "after" to after),
        )
        return page(data.at("game", "streams")) { stream(it) }
    }

    // MARK: Search

    suspend fun searchChannels(text: String, first: Int = 25): List<ChannelSearchResult> {
        val data = query(
            """
            query null(@query: String!, @first: Int) {
              searchUsers(userQuery: @query, first: @first) {
                edges { node { displayName followers { totalCount } id login profileImageURL(width: 300) stream { viewersCount } } }
              }
            }
            """,
            vars("query" to text, "first" to first),
        )
        return data.obj("searchUsers")?.arr("edges").objects().mapNotNull { edge ->
            val node = edge.obj("node") ?: return@mapNotNull null
            val channel = channel(node) ?: return@mapNotNull null
            val stream = node.obj("stream")
            ChannelSearchResult(channel, node.obj("followers")?.int("totalCount"), stream?.let { it.int("viewersCount") ?: 0 })
        }
    }

    suspend fun searchCategories(text: String, first: Int = 25): List<Category> {
        val data = query(
            """
            query null(@query: String!, @first: Int) {
              searchCategories(query: @query, first: @first) {
                edges { node { boxArtURL displayName id slug viewersCount } }
              }
            }
            """,
            vars("query" to text, "first" to first),
        )
        return data.obj("searchCategories")?.arr("edges").objects().mapNotNull { category(it.obj("node")) }
    }

    // MARK: Channels

    /** Live status for a list of channels (the Following tab, go-live alerts). */
    suspend fun users(logins: List<String>): List<Pair<Channel, LiveStream?>> {
        if (logins.isEmpty()) return emptyList()
        val result = mutableListOf<Pair<Channel, LiveStream?>>()
        for (chunk in logins.chunked(50)) {
            val data = query(
                """
                query null(@logins: [String!]) {
                  users(logins: @logins) {
                    displayName id login profileImageURL(width: 300)
                    stream { broadcaster { broadcastSettings { title } } createdAt game { displayName id slug } id previewImageURL viewersCount freeformTags { name } }
                  }
                }
                """,
                vars("logins" to chunk),
            )
            for (user in data.arr("users").objects()) {
                val channel = channel(user) ?: continue
                result.add(channel to stream(user.obj("stream"), channel))
            }
        }
        return result
    }

    suspend fun channelPage(login: String): ChannelPage? {
        val data = query(
            """
            query null(@login: String) {
              user(login: @login, lookupType: ALL) {
                bannerImageURL description displayName followers { totalCount } id login profileImageURL(width: 300)
                lastBroadcast { startedAt }
                stream { createdAt game { displayName id slug } id previewImageURL title viewersCount freeformTags { name } }
              }
            }
            """,
            vars("login" to login.lowercase()),
        )
        val user = data.obj("user")
        val channel = channel(user) ?: return null
        return ChannelPage(
            channel = channel,
            description = user?.str("description"),
            followers = user?.obj("followers")?.int("totalCount"),
            bannerURL = user?.str("bannerImageURL"),
            lastBroadcast = parseDate(user?.obj("lastBroadcast")?.str("startedAt")),
            stream = stream(user?.obj("stream"), channel),
        )
    }

    suspend fun videos(login: String, after: String? = null, first: Int = 20): Page<Video> {
        // Signed in: also where you left off in each one (Twitch's watch history).
        if (TwitchAuth.session != null) {
            runCatching { return videos(login, after, first, withHistory = true) }
        }
        return videos(login, after, first, withHistory = false)
    }

    private suspend fun videos(login: String, after: String?, first: Int, withHistory: Boolean): Page<Video> {
        val history = if (withHistory) " self { viewingHistory { position updatedAt } }" else ""
        val data = query(
            """
            query null(@login: String, @sort: VideoSort, @types: [BroadcastType!], @first: Int, @after: Cursor) {
              user(login: @login, lookupType: ALL) {
                displayName id login profileImageURL(width: 300)
                videos(first: @first, after: @after, types: @types, sort: @sort) {
                  edges { cursor node { broadcastType createdAt game { displayName id slug } id lengthSeconds previewThumbnailURL title viewCount$history } }
                  pageInfo { hasNextPage }
                }
              }
            }
            """,
            vars(
                "login" to login.lowercase(), "sort" to "TIME", "types" to listOf("ARCHIVE", "HIGHLIGHT", "UPLOAD"),
                "first" to first, "after" to after,
            ),
            authenticated = withHistory,
        )
        val owner = channel(data.obj("user"))
        return page(data.at("user", "videos")) { video(it, owner) }
    }

    // MARK: Chat badges

    suspend fun badges(channelID: String?): Map<String, Badge> {
        val result = mutableMapOf<String, Badge>()
        fun add(list: JSONArray?) {
            for (b in list.objects()) {
                val set = b.str("setID") ?: continue
                val version = b.str("version") ?: continue
                val url = b.str("imageURL") ?: continue
                result["$set/$version"] = Badge(set, version, b.str("title") ?: set, url)
            }
        }
        runCatching { query("query null { badges { imageURL(size: DOUBLE) setID title version } }") }
            .getOrNull()?.let { add(it.arr("badges")) }
        if (channelID != null) {
            runCatching {
                query(
                    "query null(@id: ID) { user(id: @id, lookupType: ALL) { broadcastBadges { imageURL(size: DOUBLE) setID title version } } }",
                    vars("id" to channelID),
                )
            }.getOrNull()?.let { add(it.obj("user")?.arr("broadcastBadges")) }
        }
        return result
    }

    // MARK: Playback tokens

    suspend fun streamToken(login: String, playerType: String, platform: String): PlaybackToken =
        playbackToken(login, null, playerType, platform)

    suspend fun videoToken(id: String): PlaybackToken = playbackToken(null, id, "site", "web")

    private suspend fun playbackToken(login: String?, vodID: String?, playerType: String, platform: String): PlaybackToken {
        if (TwitchAuth.session == null) return playbackToken(login, vodID, playerType, platform, anonymous = true)
        return try {
            playbackToken(login, vodID, playerType, platform, anonymous = false)
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            // Twitch sometimes demands an integrity check for signed-in requests: watch anonymously.
            val token = playbackToken(login, vodID, playerType, platform, anonymous = true)
            lastAuthFallback = e.message
            token
        }
    }

    private suspend fun playbackToken(
        login: String?,
        vodID: String?,
        playerType: String,
        platform: String,
        anonymous: Boolean,
    ): PlaybackToken {
        val isLive = login != null
        val client = playbackClient
        val key = if (isLive) "streamPlaybackAccessToken" else "videoPlaybackAccessToken"
        fun parse(data: JSONObject): PlaybackToken? {
            val t = data.obj(key) ?: return null
            val value = t.str("value") ?: return null
            val signature = t.str("signature") ?: return null
            return PlaybackToken(value, signature)
        }
        var lastError: Exception = TwitchException("Twitch didn't return a playback token (the channel may be offline).")
        // 1. The persisted query the website uses (and streamlink / Xtra).
        try {
            val variables = JSONObject()
                .put("isLive", isLive).put("login", login ?: "").put("isVod", !isLive).put("vodID", vodID ?: "")
                .put("playerType", playerType).put("platform", platform)
            parse(send(persisted("PlaybackAccessToken", PLAYBACK_TOKEN_HASH, variables), anonymous, client))?.let { return it }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            lastError = e
        }
        // 2. Written out, in case the persisted hash rotates.
        try {
            val body = if (isLive) {
                JSONObject()
                    .put(
                        "query",
                        gql(
                            "query null(@login: String!, @platform: String!, @playerType: String!) { " +
                                "streamPlaybackAccessToken(channelName: @login, params: { platform: @platform, playerType: @playerType }) { signature value } }",
                        ),
                    )
                    .put("variables", vars("login" to (login ?: ""), "platform" to platform, "playerType" to playerType))
            } else {
                JSONObject()
                    .put(
                        "query",
                        gql(
                            "query null(@id: ID!, @platform: String!, @playerType: String!) { " +
                                "videoPlaybackAccessToken(id: @id, params: { platform: @platform, playerType: @playerType }) { signature value } }",
                        ),
                    )
                    .put("variables", vars("id" to (vodID ?: ""), "platform" to platform, "playerType" to playerType))
            }
            parse(send(body, anonymous, client))?.let { return it }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            lastError = e
        }
        throw lastError
    }

    // MARK: Account

    /** Whether the signed-in account has Turbo (null if unknown). */
    suspend fun currentUserHasTurbo(): Boolean? {
        if (TwitchAuth.session == null) return null
        val data = runCatching { query("query null { currentUser { login hasTurbo } }", authenticated = true) }.getOrNull()
        return data?.obj("currentUser")?.bool("hasTurbo")
    }

    /**
     * Follows or unfollows a channel on the signed-in account. Twitch only accepts these from its
     * website, with an integrity token (`headers`: Client-Integrity and the matching device ID).
     */
    suspend fun setFollow(follow: Boolean, channelID: String, headers: Map<String, String>) {
        if (TwitchAuth.session == null) throw GqlException("Not signed in")
        val input = JSONObject().put("targetID", channelID)
        if (follow) input.put("disableNotifications", false)
        val allHeaders = headers + mapOf("Origin" to "https://www.twitch.tv", "Referer" to "https://www.twitch.tv/")
        val data = try {
            send(
                persisted(
                    if (follow) "FollowButton_FollowUser" else "FollowButton_UnfollowUser",
                    if (follow) FOLLOW_HASH else UNFOLLOW_HASH,
                    JSONObject().put("input", input),
                ),
                anonymous = false,
                headers = allHeaders,
            )
        } catch (e: GqlException) {
            if (!e.gqlMessage.contains("PersistedQuery", ignoreCase = true)) throw e
            // Twitch renamed its stored mutation: send it written out instead.
            val field = if (follow) "followUser" else "unfollowUser"
            val type = if (follow) "FollowUserInput" else "UnfollowUserInput"
            send(
                JSONObject()
                    .put("query", gql("mutation(@input: $type!) { $field(input: @input) { follow { user { id } } error { code } } }"))
                    .put("variables", JSONObject().put("input", input)),
                anonymous = false,
                headers = allHeaders,
            )
        }
        val result = data.obj(if (follow) "followUser" else "unfollowUser")
        result?.obj("error")?.str("code")?.let { throw GqlException(describeFollowError(it)) }
        if (follow && result?.obj("follow") == null) throw GqlException("Twitch didn't confirm the follow")
    }

    private fun describeFollowError(code: String): String = when (code) {
        "TOO_MANY_FOLLOWS" -> "You follow the most channels Twitch allows"
        "FORBIDDEN" -> "Twitch didn't allow it"
        else -> code.lowercase().replace('_', ' ')
    }

    /** The signed-in account's followed channels (up to 600), with who's live. */
    suspend fun followedChannels(): List<FollowedChannel> {
        if (TwitchAuth.session == null) return emptyList()
        val result = mutableListOf<FollowedChannel>()
        var cursor: String? = null
        repeat(6) {
            val data = query(
                """
                query null(@after: Cursor) {
                  currentUser {
                    follows(first: 100, after: @after) {
                      edges {
                        cursor
                        node {
                          displayName id login profileImageURL(width: 300)
                          lastBroadcast { startedAt }
                          stream { createdAt game { boxArtURL displayName id slug } id previewImageURL title viewersCount freeformTags { name } }
                        }
                      }
                      pageInfo { hasNextPage }
                    }
                  }
                }
                """,
                vars("after" to cursor),
                authenticated = true,
            )
            val follows = data.at("currentUser", "follows")
            val edges = follows?.arr("edges").objects()
            for (edge in edges) {
                val node = edge.obj("node") ?: continue
                val channel = channel(node) ?: continue
                result.add(FollowedChannel(channel, stream(node.obj("stream"), channel), parseDate(node.obj("lastBroadcast")?.str("startedAt"))))
            }
            val last = edges.lastOrNull()?.str("cursor")
            if (follows?.obj("pageInfo")?.bool("hasNextPage") != true || last == null) return result
            cursor = last
        }
        return result
    }

    // MARK: Emotes you can use

    /** The signed-in account's emotes that work in `channelID`'s chat, grouped by owner. */
    suspend fun availableEmotes(channelID: String?): List<TwitchEmoteGroup> {
        if (TwitchAuth.session == null) return emptyList()
        val groups = mutableListOf<TwitchEmoteGroup>()
        // 1. What the website's emote picker uses.
        if (channelID != null) {
            var cursor: String? = null
            for (attempt in 0 until 4) {
                val variables = JSONObject().put("channelID", channelID).put("pageLimit", 350).put("withOwner", true)
                if (cursor != null) variables.put("cursor", cursor)
                val data = runCatching {
                    send(persisted("AvailableEmotesForChannelPaginated", AVAILABLE_EMOTES_HASH, variables), anonymous = false)
                }.getOrNull() ?: break
                val sets = data.at("channel", "self", "availableEmoteSetsPaginated")
                val edges = sets?.arr("edges").objects()
                for (edge in edges) {
                    val node = edge.obj("node") ?: continue
                    val emotes = node.arr("emotes").objects().mapNotNull { twitchEmote(it) }
                    if (emotes.isEmpty()) continue
                    val owner = node.obj("owner")
                    groups.add(
                        TwitchEmoteGroup(
                            owner?.str("id") ?: emotes.first().ownerID,
                            owner?.str("displayName") ?: owner?.str("login"),
                            owner?.str("profileImageURL"),
                            emotes,
                        ),
                    )
                }
                val next = edges.lastOrNull()?.str("cursor")
                if (sets?.obj("pageInfo")?.bool("hasNextPage") != true || next == null) break
                cursor = next
            }
        }
        // 2. Fallback: every emote set the account owns.
        if (groups.isEmpty()) {
            val data = runCatching {
                query("query null { user { emoteSets { emotes { id owner { id } setID token type } } } }", authenticated = true)
            }.getOrNull()
            if (data != null) {
                val byOwner = linkedMapOf<String, MutableList<TwitchEmote>>()
                for (set in data.obj("user")?.arr("emoteSets").objects()) {
                    for (emote in set.arr("emotes").objects().mapNotNull { twitchEmote(it) }) {
                        // Follower emotes only work in their own channel.
                        if (emote.type?.uppercase() == "FOLLOWER" && emote.ownerID != null && emote.ownerID != channelID) continue
                        byOwner.getOrPut(emote.ownerID ?: "0") { mutableListOf() }.add(emote)
                    }
                }
                for ((owner, emotes) in byOwner) groups.add(TwitchEmoteGroup(owner, null, null, emotes))
            }
        }
        // Names and pictures for owners the response didn't describe.
        val unnamed = groups.filter { it.ownerName == null }.mapNotNull { it.ownerID }.filter { it != "0" && it.isNotEmpty() }.distinct()
        if (unnamed.isNotEmpty()) {
            val data = runCatching {
                query(
                    "query null(@ids: [ID!]) { users(ids: @ids) { id displayName login profileImageURL(width: 70) } }",
                    vars("ids" to unnamed.take(100)),
                )
            }.getOrNull()
            if (data != null) {
                val names = mutableMapOf<String, Pair<String, String?>>()
                for (user in data.arr("users").objects()) {
                    val id = user.str("id") ?: continue
                    names[id] = (user.str("displayName") ?: user.str("login") ?: id) to user.str("profileImageURL")
                }
                for (i in groups.indices) {
                    val group = groups[i]
                    val found = group.ownerID?.let { names[it] }
                    if (group.ownerName == null && found != null) groups[i] = group.copy(ownerName = found.first, ownerImage = found.second)
                }
            }
        }
        return groups
    }

    fun twitchEmote(j: JSONObject): TwitchEmote? {
        val id = j.str("id") ?: return null
        var token = j.str("token")?.takeIf { it.isNotEmpty() } ?: return null
        val type = j.str("type")
        if (type?.uppercase() == "SMILIES") {
            // Classic smileys are stored as regexes (e.g. "\\:-?\\)"): show the plain form.
            token = token.replace("\\", "").replace("?", "").replace("&lt;", "<").replace("&gt;", ">")
            token = Regex("""\((.)\|.\)""").replace(token, "\$1")
            token = Regex("""\[(.).*?]""").replace(token, "\$1")
        }
        return TwitchEmote(id, token, j.str("setID"), j.obj("owner")?.str("id"), type)
    }

    // MARK: Rewinding a live stream

    /** The VOD being recorded for the live broadcast, if the channel saves VODs. */
    suspend fun liveArchive(login: String): LiveArchive? {
        val withStatus = runCatching {
            query(
                """
                query null(@login: String) {
                  user(login: @login, lookupType: ALL) {
                    stream { createdAt id }
                    videos(first: 1, types: [ARCHIVE], sort: TIME) { edges { node { createdAt id status seekPreviewsURL } } }
                  }
                }
                """,
                vars("login" to login.lowercase()),
            )
        }.getOrNull()
        val data = withStatus ?: runCatching {
            query(
                """
                query null(@login: String) {
                  user(login: @login, lookupType: ALL) {
                    stream { createdAt id }
                    videos(first: 1, types: [ARCHIVE], sort: TIME) { edges { node { createdAt id } } }
                  }
                }
                """,
                vars("login" to login.lowercase()),
            )
        }.getOrNull() ?: return null
        val user = data.obj("user") ?: return null
        val streamStart = parseDate(user.obj("stream")?.str("createdAt")) ?: return null
        val node = user.obj("videos")?.arr("edges").objects().firstOrNull()?.obj("node") ?: return null
        val id = node.str("id") ?: return null
        val created = parseDate(node.str("createdAt")) ?: return null
        val status = node.str("status")
        if (status != null && status.uppercase() != "RECORDING") return null
        // The archive of this broadcast starts when the broadcast did.
        if (abs(created - streamStart) >= 15 * 60 * 1000L) return null
        return LiveArchive(id, created, node.str("seekPreviewsURL"))
    }

    /** Where a VOD's storyboard (seek preview thumbnails) is described. */
    suspend fun seekPreviewsURL(videoID: String): String? {
        runCatching { query("query null(@id: ID) { video(id: @id) { seekPreviewsURL } }", vars("id" to videoID)) }
            .getOrNull()?.obj("video")?.str("seekPreviewsURL")?.let { return it }
        val data = runCatching {
            send(
                persisted(
                    "VideoPlayer_VODSeekbarPreviewVideo", SEEKBAR_PREVIEW_HASH,
                    JSONObject().put("includePrivate", false).put("videoID", videoID),
                ),
                anonymous = true,
            )
        }.getOrNull()
        return data?.obj("video")?.str("seekPreviewsURL")
    }

    suspend fun storyboard(url: String, duration: Double?): Storyboard? {
        val result = runCatching { Http.client.fetch(Http.get(url)) }.getOrNull() ?: return null
        if (result.code != 200) return null
        return Storyboard.parse(result.body, result.url, duration)
    }

    // MARK: VOD chat

    /** A page of a VOD's chat, starting at `offset` seconds or after `cursor`. */
    suspend fun videoComments(videoID: String, offset: Int?, cursor: String?): CommentPage {
        val variables = JSONObject().put("id", videoID)
        if (cursor != null) variables.put("after", cursor) else variables.put("offset", offset ?: 0)
        // Only the argument in use (Twitch can reject an offset and a cursor together).
        val arguments = if (cursor == null) "contentOffsetSeconds: @offset" else "after: @after"
        val declarations = if (cursor == null) "@offset: Int" else "@after: Cursor"
        return try {
            val data = query(
                """
                query null(@id: ID, $declarations) {
                  video(id: @id) {
                    comments($arguments) {
                      edges {
                        cursor
                        node {
                          commenter { displayName id login }
                          contentOffsetSeconds createdAt id
                          message { fragments { emote { emoteID } text } userBadges { setID version } userColor }
                        }
                      }
                      pageInfo { hasNextPage }
                    }
                  }
                }
                """,
                variables,
            )
            VodComments.parsePage(data)
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            // The website's own query (may need Twitch's integrity check).
            val persistedVariables = JSONObject().put("videoID", videoID)
            if (cursor != null) persistedVariables.put("cursor", cursor) else persistedVariables.put("contentOffsetSeconds", offset ?: 0)
            VodComments.parsePage(send(persisted("VideoCommentsByOffsetOrCursor", VIDEO_COMMENTS_HASH, persistedVariables), anonymous = true))
        }
    }

    // MARK: Where you left off (synced with Twitch)

    /** Your saved position in a VOD on Twitch: seconds, and when it was saved. */
    suspend fun viewingPosition(videoID: String): Pair<Double, Long?>? {
        if (TwitchAuth.session == null) return null
        val data = runCatching {
            query(
                "query null(@id: ID) { video(id: @id) { self { viewingHistory { position updatedAt } } } }",
                vars("id" to videoID),
                authenticated = true,
            )
        }.getOrNull() ?: return null
        val history = data.at("video", "self", "viewingHistory") ?: return null
        val position = history.int("position") ?: return null
        return position.toDouble() to parseDate(history.str("updatedAt"))
    }

    /** Saves your position the way Twitch's player does, so the website and apps resume there. */
    suspend fun saveViewingPosition(videoID: String, position: Double, live: Boolean = false) {
        val session = TwitchAuth.session ?: return
        val input = JSONObject()
            .put("userID", session.userID).put("videoID", videoID).put("position", position.toInt())
            .put("videoType", if (live) "LIVE" else "VOD")
        val body = JSONObject()
            .put("operationName", "updateUserViewedVideo")
            .put(
                "query",
                gql(
                    "mutation updateUserViewedVideo(@input: UpdateUserViewedVideoInput!) { " +
                        "updateUserViewedVideo(input: @input) { __typename } }",
                ),
            )
            .put("variables", JSONObject().put("input", input))
        val data = send(body, anonymous = false)
        if (data.isNull("updateUserViewedVideo")) throw GqlException("Twitch didn't save the position")
    }

    /** A VOD's length so far (it grows while the broadcast is recorded) and its seek previews. */
    suspend fun videoProgress(videoID: String): Pair<Double?, String?> {
        val data = runCatching {
            query("query null(@id: ID) { video(id: @id) { lengthSeconds seekPreviewsURL } }", vars("id" to videoID))
        }.getOrNull() ?: return null to null
        val video = data.obj("video")
        return video?.int("lengthSeconds")?.toDouble() to video?.str("seekPreviewsURL")
    }

    // MARK: Image addresses

    fun image(template: String?, width: Int, height: Int): String? {
        var s = template?.takeIf { it.isNotEmpty() } ?: return null
        if (s.contains("{width}")) {
            s = s.replace("%{width}", width.toString()).replace("%{height}", height.toString())
            s = s.replace("{width}", width.toString()).replace("{height}", height.toString())
        } else {
            s = Regex("""-\d+x\d+\.""").replaceFirst(s, "-${width}x$height.")
        }
        return s
    }
}
