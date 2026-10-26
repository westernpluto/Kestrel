package app.kestrel.core

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.net.URLEncoder

/**
 * Signing in with a code, the way Twitch's TV apps do: Kestrel gets a short code from Twitch, you
 * enter it at twitch.tv/activate in any browser where you're signed in (this phone's, a computer's,
 * another phone's), and Twitch hands Kestrel a token. Nothing of Twitch's website has to run inside
 * Kestrel, so it works where the login page won't.
 */
object TwitchDeviceLogin {
    /** Twitch's own TV app (its tokens go with this Client-ID). */
    const val CLIENT_ID = "ue6666qo983tsx6so1t0vnawi233wa"

    /** Asked for first; if Twitch won't take the list, the smaller one (what Xtra asks for). */
    private val SCOPE_SETS = listOf(
        "channel_read chat:read chat:edit user_blocks_edit user_blocks_read user_follows_edit user_read",
        "channel_read chat:read user_blocks_edit user_blocks_read user_follows_edit user_read",
    )

    private val FORM = "application/x-www-form-urlencoded".toMediaType()

    data class Code(
        val deviceCode: String,
        val userCode: String,
        /** Opens Twitch's activation page with the code filled in. */
        val verificationUri: String,
        val intervalSeconds: Int,
        val expiresAt: Long,
        val scopes: String,
    )

    data class Grant(val accessToken: String, val refreshToken: String?, val expiresIn: Int?)

    sealed class Poll {
        object Pending : Poll()
        object SlowDown : Poll()
        object Expired : Poll()
        data class Refused(val message: String) : Poll()
        data class Done(val grant: Grant) : Poll()
    }

    class Failure(message: String) : Exception(message)

    private fun encode(value: String) = URLEncoder.encode(value, "UTF-8")

    private fun post(url: String, fields: List<Pair<String, String>>): Request {
        val body = fields.joinToString("&") { (key, value) -> "${encode(key)}=${encode(value)}" }
        return Request.Builder()
            .url(url)
            .header("User-Agent", Browser.USER_AGENT)
            .post(body.toRequestBody(FORM))
            .build()
    }

    private fun message(body: String): String? = runCatching { JSONObject(body) }.getOrNull()?.str("message")

    /** A fresh code to enter at twitch.tv/activate. */
    suspend fun start(): Code {
        var lastError = "no answer"
        for (scopes in SCOPE_SETS) {
            val result = try {
                Http.client.fetch(post("https://id.twitch.tv/oauth2/device", listOf("client_id" to CLIENT_ID, "scopes" to scopes)))
            } catch (e: IOException) {
                throw Failure("Couldn't reach Twitch (${e.message ?: "no connection"}).")
            }
            val json = runCatching { JSONObject(result.body) }.getOrNull()
            val deviceCode = json?.str("device_code")
            val userCode = json?.str("user_code")
            if (result.code == 200 && deviceCode != null && userCode != null) {
                val expiresIn = json.int("expires_in") ?: 1800
                return Code(
                    deviceCode = deviceCode,
                    userCode = userCode,
                    verificationUri = json.str("verification_uri") ?: "https://www.twitch.tv/activate?device-code=$userCode",
                    intervalSeconds = (json.int("interval") ?: 5).coerceIn(2, 30),
                    expiresAt = System.currentTimeMillis() + expiresIn * 1000L,
                    scopes = scopes,
                )
            }
            lastError = message(result.body) ?: "HTTP ${result.code}"
        }
        throw Failure("Twitch didn't give a code ($lastError).")
    }

    /** Whether the code has been approved yet. */
    suspend fun poll(code: Code): Poll {
        val result = try {
            Http.client.fetch(
                post(
                    "https://id.twitch.tv/oauth2/token",
                    listOf(
                        "client_id" to CLIENT_ID,
                        "scopes" to code.scopes,
                        "device_code" to code.deviceCode,
                        "grant_type" to "urn:ietf:params:oauth:grant-type:device_code",
                    ),
                ),
            )
        } catch (e: IOException) {
            return Poll.Pending  // try again at the next turn
        }
        val json = runCatching { JSONObject(result.body) }.getOrNull()
        val token = json?.str("access_token")
        if (result.code == 200 && token != null) {
            return Poll.Done(Grant(token, json.str("refresh_token"), json.int("expires_in")))
        }
        val text = json?.str("message") ?: json?.str("error") ?: "HTTP ${result.code}"
        return when {
            text.contains("pending", ignoreCase = true) -> Poll.Pending
            text.contains("slow", ignoreCase = true) -> Poll.SlowDown
            text.contains("invalid device code", ignoreCase = true) || text.contains("expired", ignoreCase = true) -> Poll.Expired
            result.code >= 500 -> Poll.Pending
            else -> Poll.Refused(text)
        }
    }

    /**
     * A new token for one about to run out. null if Twitch no longer accepts the refresh token
     * (sign in again); throws IOException when Twitch can't be reached.
     */
    suspend fun refresh(refreshToken: String, clientId: String): Grant? {
        val result = Http.client.fetch(
            post(
                "https://id.twitch.tv/oauth2/token",
                listOf("client_id" to clientId, "grant_type" to "refresh_token", "refresh_token" to refreshToken),
            ),
        )
        val json = runCatching { JSONObject(result.body) }.getOrNull()
        val token = json?.str("access_token")
        if (result.code == 200 && token != null) return Grant(token, json.str("refresh_token") ?: refreshToken, json.int("expires_in"))
        if (result.code >= 500) throw IOException("Twitch answered HTTP ${result.code}")
        return null
    }
}
