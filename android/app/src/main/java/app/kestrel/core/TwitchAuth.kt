package app.kestrel.core

import org.json.JSONObject
import java.io.IOException

/** The signed-in Twitch account (in memory; TwitchAccount saves it). */
object TwitchAuth {
    data class Session(
        /** The website's `auth-token` cookie (an OAuth token for Twitch's web client). */
        val token: String,
        val login: String,
        val userID: String,
        /** The website's `unique_id` cookie; Twitch expects it with the token. */
        val deviceID: String?,
        /**
         * The Twitch client the token was issued to, when it isn't the desktop website's (signing
         * in on Twitch's mobile site): Twitch only takes the token together with that client's ID.
         */
        val clientID: String? = null,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("token", token)
            .put("login", login)
            .put("userID", userID)
            .put("deviceID", deviceID ?: JSONObject.NULL)
            .put("clientID", clientID ?: JSONObject.NULL)

        companion object {
            fun fromJson(json: JSONObject): Session? {
                val token = json.str("token") ?: return null
                val login = json.str("login") ?: return null
                val userID = json.str("userID") ?: return null
                return Session(token, login, userID, json.str("deviceID"), json.str("clientID"))
            }
        }
    }

    /** Who a token belongs to, and which Twitch client it was issued to. */
    data class TokenOwner(val login: String, val userID: String, val clientID: String?)

    @Volatile
    var session: Session? = null

    /** The Client-ID that goes with the signed-in account's token. */
    val clientID: String get() = session?.clientID ?: TwitchApi.CLIENT_ID

    class ValidationException(message: String) : Exception(message)

    /** Checks a token with Twitch and returns who it belongs to. */
    suspend fun validate(token: String): TokenOwner {
        val request = Http.get("https://id.twitch.tv/oauth2/validate", mapOf("Authorization" to "OAuth $token"))
        val result = try {
            Http.client.fetch(request)
        } catch (e: IOException) {
            throw ValidationException("Couldn't reach Twitch to check the sign-in (${e.message ?: "no connection"}). Try again.")
        }
        val json = if (result.code == 200) runCatching { JSONObject(result.body) }.getOrNull() else null
        val login = json?.str("login")
        val userId = json?.str("user_id")
        if (json == null || login == null || userId == null) {
            throw ValidationException("Twitch didn't accept this token (HTTP ${result.code}). Sign in again.")
        }
        return TokenOwner(login, userId, json.str("client_id"))
    }
}
