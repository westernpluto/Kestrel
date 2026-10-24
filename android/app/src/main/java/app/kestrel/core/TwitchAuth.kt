package app.kestrel.core

import org.json.JSONObject

/** The signed-in Twitch account (in memory; TwitchAccount saves it). */
object TwitchAuth {
    data class Session(
        /** The website's `auth-token` cookie (an OAuth token for Twitch's web client). */
        val token: String,
        val login: String,
        val userID: String,
        /** The website's `unique_id` cookie; Twitch expects it with the token. */
        val deviceID: String?,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("token", token)
            .put("login", login)
            .put("userID", userID)
            .put("deviceID", deviceID ?: JSONObject.NULL)

        companion object {
            fun fromJson(json: JSONObject): Session? {
                val token = json.str("token") ?: return null
                val login = json.str("login") ?: return null
                val userID = json.str("userID") ?: return null
                return Session(token, login, userID, json.str("deviceID"))
            }
        }
    }

    @Volatile
    var session: Session? = null

    class ValidationException(message: String) : Exception(message)

    /** Checks a token with Twitch and returns who it belongs to (login, user ID). */
    suspend fun validate(token: String): Pair<String, String> {
        val request = Http.get("https://id.twitch.tv/oauth2/validate", mapOf("Authorization" to "OAuth $token"))
        val result = Http.client.fetch(request)
        val json = if (result.code == 200) runCatching { JSONObject(result.body) }.getOrNull() else null
        val login = json?.str("login")
        val userId = json?.str("user_id")
        if (json == null || login == null || userId == null) {
            throw ValidationException("Twitch didn't accept this token. Sign in again.")
        }
        val client = json.str("client_id")
        if (client != null && client != TwitchApi.CLIENT_ID) {
            throw ValidationException("This token belongs to another app. Use the website's auth-token.")
        }
        return login to userId
    }
}
