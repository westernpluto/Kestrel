package app.kestrel.data

import android.webkit.CookieManager
import android.webkit.WebStorage
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.kestrel.core.ActivityLog
import app.kestrel.core.Kestrel
import app.kestrel.core.Prefs
import app.kestrel.core.TwitchApi
import app.kestrel.core.TwitchAuth
import kotlinx.coroutines.launch

/** The Twitch login, kept in Kestrel's private storage (removed with the app). */
object TwitchAccount {
    private const val KEY = "twitch.session"

    var session by mutableStateOf<TwitchAuth.Session?>(null)
        private set

    /** null while unknown. */
    var hasTurbo by mutableStateOf<Boolean?>(null)
        private set

    fun load() {
        val saved = Prefs.json(KEY)?.let { TwitchAuth.Session.fromJson(it) } ?: return
        session = saved
        TwitchAuth.session = saved
        Kestrel.scope.launch { refreshTurbo() }
    }

    /**
     * @param fromWebsite the token came from Twitch's own login page, so whichever Twitch client the
     *   page used is fine (the mobile site has its own); a pasted token has to be the desktop site's.
     */
    suspend fun signIn(rawToken: String, deviceId: String?, fromWebsite: Boolean = false) {
        val token = rawToken.trim(' ', '\n', '\t', '"', '\'').replace("OAuth ", "").replace("oauth:", "")
        if (token.isEmpty()) throw TwitchAuth.ValidationException("That's not a token.")
        val owner = TwitchAuth.validate(token)
        val client = owner.clientID?.takeIf { it.isNotEmpty() && it != TwitchApi.CLIENT_ID }
        if (client != null && !fromWebsite) {
            throw TwitchAuth.ValidationException("This token belongs to another app. Use the website's auth-token.")
        }
        val newSession = TwitchAuth.Session(token, owner.login, owner.userID, deviceId, client)
        Prefs.setJson(KEY, newSession.toJson())
        TwitchAuth.session = newSession
        session = newSession
        ActivityLog.add(
            if (client == null) "Signed in to Twitch as ${owner.login}"
            else "Signed in to Twitch as ${owner.login} (through Twitch's mobile site)",
        )
        TwitchIntegrity.invalidate()
        // Not waited for: the sign-in screen closes as soon as the login itself is in.
        Kestrel.scope.launch {
            refreshTurbo()
            FollowingStore.refresh(force = true)
        }
    }

    suspend fun refreshTurbo() {
        hasTurbo = TwitchApi.currentUserHasTurbo()
    }

    fun signOut() {
        Prefs.setJson(KEY, null)
        TwitchAuth.session = null
        session = null
        hasTurbo = null
        TwitchIntegrity.invalidate()
        // Forget the website login too, so the next sign-in starts fresh.
        runCatching {
            CookieManager.getInstance().removeAllCookies(null)
            CookieManager.getInstance().flush()
            WebStorage.getInstance().deleteAllData()
        }
        ActivityLog.add("Signed out of Twitch")
        Kestrel.scope.launch { FollowingStore.refresh(force = true) }
    }
}
