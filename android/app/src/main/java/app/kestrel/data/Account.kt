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
import app.kestrel.core.TwitchDeviceLogin
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.IOException

/** The Twitch login, kept in Kestrel's private storage (removed with the app). */
object TwitchAccount {
    private const val KEY = "twitch.session"

    var session by mutableStateOf<TwitchAuth.Session?>(null)
        private set

    /** null while unknown. */
    var hasTurbo by mutableStateOf<Boolean?>(null)
        private set

    private var renewal: Job? = null

    fun load() {
        val saved = Prefs.json(KEY)?.let { TwitchAuth.Session.fromJson(it) } ?: return
        session = saved
        TwitchAuth.session = saved
        Kestrel.scope.launch { refreshTurbo() }
        keepRenewed()
    }

    /**
     * @param viaTwitch the token came from Twitch's own sign-in (the login page, or a code), so
     *   whichever Twitch client it was issued to is fine; a pasted token has to be the desktop site's.
     * @param refreshToken comes with tokens from signing in with a code (they run out; it renews them).
     */
    suspend fun signIn(rawToken: String, deviceId: String?, viaTwitch: Boolean = false, refreshToken: String? = null) {
        val token = rawToken.trim(' ', '\n', '\t', '"', '\'').replace("OAuth ", "").replace("oauth:", "")
        if (token.isEmpty()) throw TwitchAuth.ValidationException("That's not a token.")
        val owner = TwitchAuth.validate(token)
        val client = owner.clientID?.takeIf { it.isNotEmpty() && it != TwitchApi.CLIENT_ID }
        if (client != null && !viaTwitch) {
            throw TwitchAuth.ValidationException("This token belongs to another app. Use the website's auth-token.")
        }
        val newSession = TwitchAuth.Session(token, owner.login, owner.userID, deviceId, client, refreshToken)
        save(newSession)
        ActivityLog.add(
            when {
                client == null -> "Signed in to Twitch as ${owner.login}"
                client == TwitchDeviceLogin.CLIENT_ID -> "Signed in to Twitch as ${owner.login} (with a code)"
                else -> "Signed in to Twitch as ${owner.login} (through Twitch's mobile site)"
            },
        )
        TwitchIntegrity.invalidate()
        keepRenewed()
        // Not waited for: the sign-in screen closes as soon as the login itself is in.
        Kestrel.scope.launch {
            refreshTurbo()
            FollowingStore.refresh(force = true)
        }
    }

    private fun save(newSession: TwitchAuth.Session) {
        Prefs.setJson(KEY, newSession.toJson())
        TwitchAuth.session = newSession
        session = newSession
    }

    /**
     * Tokens from signing in with a code last a few hours: Twitch is asked how long this one has
     * left (it wants apps to check hourly anyway), and it's renewed shortly before it runs out.
     */
    private fun keepRenewed() {
        renewal?.cancel()
        if (session?.refreshToken == null) return
        renewal = Kestrel.scope.launch {
            while (true) {
                val current = session ?: return@launch
                val refreshToken = current.refreshToken ?: return@launch
                val secondsLeft: Int? = try {
                    TwitchAuth.validate(current.token).expiresIn ?: 3600
                } catch (e: TwitchAuth.ValidationException) {
                    if (e.offline) null else 0
                }
                when {
                    secondsLeft == null -> delay(5 * 60_000L)  // offline: look again in a while
                    secondsLeft > 15 * 60 -> delay(minOf(secondsLeft - 10 * 60, 3600) * 1000L)
                    else -> {
                        val grant = try {
                            TwitchDeviceLogin.refresh(refreshToken, current.clientID ?: TwitchDeviceLogin.CLIENT_ID)
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: IOException) {
                            delay(60_000L)
                            continue
                        }
                        if (grant == null) {
                            ActivityLog.add("Your Twitch sign-in ran out and couldn't be renewed: sign in again in Settings")
                            return@launch
                        }
                        if (session?.userID != current.userID) return@launch
                        save(current.copy(token = grant.accessToken, refreshToken = grant.refreshToken ?: refreshToken))
                        TwitchIntegrity.invalidate()
                        ActivityLog.add("Renewed the Twitch sign-in")
                    }
                }
            }
        }
    }

    suspend fun refreshTurbo() {
        hasTurbo = TwitchApi.currentUserHasTurbo()
    }

    fun signOut() {
        renewal?.cancel()
        renewal = null
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
