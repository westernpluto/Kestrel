package app.kestrel.core

import org.json.JSONObject

data class Channel(
    val id: String,
    val login: String,
    val displayName: String,
    val profileImageURL: String?,
) {
    val name: String get() = displayName.ifEmpty { login }

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("login", login)
        .put("displayName", displayName)
        .put("profileImageURL", profileImageURL ?: JSONObject.NULL)

    companion object {
        fun fromJson(json: JSONObject): Channel? {
            val id = json.str("id") ?: return null
            val login = json.str("login") ?: return null
            return Channel(id, login, json.str("displayName") ?: login, json.str("profileImageURL"))
        }
    }
}

data class Category(
    val id: String,
    val name: String,
    val slug: String?,
    val boxArtURL: String?,
    val viewers: Int,
)

data class LiveStream(
    val id: String,
    val title: String,
    val viewers: Int,
    val previewImageURL: String?,
    /** Epoch milliseconds. */
    val startedAt: Long?,
    val category: Category?,
    val channel: Channel,
    /** The streamer's tags ("English", "Chill", …). */
    val tags: List<String> = emptyList(),
)

data class Video(
    val id: String,
    val title: String,
    val lengthSeconds: Int,
    val previewURL: String?,
    val createdAt: Long?,
    val viewCount: Int,
    val categoryName: String?,
    val owner: Channel?,
    /** Where you left off on Twitch (seconds), when signed in. */
    val watchedPosition: Double?,
    val watchedAt: Long?,
)

data class ChannelPage(
    val channel: Channel,
    val description: String?,
    val followers: Int?,
    val bannerURL: String?,
    val lastBroadcast: Long?,
    val stream: LiveStream?,
)

data class Page<T>(val items: List<T>, val cursor: String?, val hasNextPage: Boolean)

data class ChannelSearchResult(val channel: Channel, val followers: Int?, val liveViewers: Int?)

data class TwitchEmote(
    val id: String,
    val token: String,
    val setID: String?,
    val ownerID: String?,
    val type: String?,
) {
    val url: String get() = twitchEmoteUrl(id)
}

fun twitchEmoteUrl(id: String): String = "https://static-cdn.jtvnw.net/emoticons/v2/$id/default/dark/2.0"

data class TwitchEmoteGroup(
    val ownerID: String?,
    val ownerName: String?,
    val ownerImage: String?,
    val emotes: List<TwitchEmote>,
)

data class LiveArchive(
    val videoID: String,
    /** When the recording (and the broadcast) started, epoch milliseconds. */
    val startedAt: Long,
    val seekPreviewsURL: String?,
)

data class Badge(val setID: String, val version: String, val title: String, val imageURL: String)

data class FollowedChannel(val channel: Channel, val stream: LiveStream?, val lastLive: Long?)

open class TwitchException(message: String) : Exception(message)

/** An error message from Twitch's GraphQL API. */
class GqlException(val gqlMessage: String) : TwitchException("Twitch: $gqlMessage")

/** What Twitch handed out for one playback session. */
data class PlaybackToken(val value: String, val signature: String) {
    data class Info(
        val showAds: Boolean?,
        val hideAds: Boolean?,
        val turbo: Boolean?,
        val subscriber: Boolean?,
        val signedIn: Boolean,
        val restrictedBitrates: List<String>,
    )

    /** The token value is JSON describing what Twitch decided. */
    val info: Info?
        get() {
            val json = runCatching { JSONObject(value) }.getOrNull() ?: return null
            fun flag(key: String): Boolean? = json.opt(key) as? Boolean
            val userId = json.opt("user_id")
            val signedIn = !(userId == null || userId == JSONObject.NULL || (userId is String && userId.isEmpty()))
            val restricted = json.optJSONObject("chansub")?.optJSONArray("restricted_bitrates").strings()
            return Info(flag("show_ads"), flag("hide_ads"), flag("turbo"), flag("subscriber"), signedIn, restricted)
        }

    /** One line for the activity log. */
    val summary: String
        get() {
            val info = info ?: return "Twitch session details unavailable"
            val parts = mutableListOf(if (info.signedIn) "signed in" else "not signed in")
            if (info.turbo == true) parts.add("Turbo")
            if (info.subscriber == true) parts.add("subscriber")
            val ads = if (info.hideAds == true || info.showAds == false) "no ads" else "ads possible"
            var line = "Twitch session: $ads (${parts.joinToString(", ")})"
            if (info.restrictedBitrates.isNotEmpty()) {
                line += "; subscriber-only qualities: ${info.restrictedBitrates.joinToString(", ")}"
            }
            return line
        }

    /** Why Twitch won't show this signed-in session ads, or null if it may. */
    val adFreeReason: String?
        get() {
            val info = info ?: return null
            if (!info.signedIn || !(info.hideAds == true || info.showAds == false)) return null
            if (info.turbo == true) return "Turbo"
            if (info.subscriber == true) return "subscribed"
            return "no ads for your account"
        }
}
