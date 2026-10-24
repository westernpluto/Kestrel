package app.kestrel.core

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Credentials
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

object Browser {
    /** Twitch's GQL rejects some requests that don't look like a browser, and the website (sign-in,
     *  follows) is only the full one for a desktop browser. */
    const val USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
}

/** An HTTP(S) proxy, e.g. one in a country where Twitch doesn't run ads. */
data class HttpProxy(val host: String, val port: Int, val username: String?, val password: String?) {
    val description: String get() = "$host:$port"
}

/** A finished request: status, body text and the final address (after redirects). */
data class HttpResult(val code: Int, val body: String, val url: String)

object Http {
    private val base: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    /** API requests. */
    val client: OkHttpClient = base.newBuilder().callTimeout(15, TimeUnit.SECONDS).build()

    /** Video segments: Twitch's low-latency segments arrive in real time, so reads can be slow. */
    val media: OkHttpClient = base.newBuilder().readTimeout(20, TimeUnit.SECONDS).build()

    fun withTimeout(seconds: Long): OkHttpClient = base.newBuilder().callTimeout(seconds, TimeUnit.SECONDS).build()

    /** Playback requests (tokens, playlists), through the user's own proxy when one is set. */
    fun playback(proxy: HttpProxy?, timeoutSeconds: Long = 8): OkHttpClient {
        val builder = base.newBuilder().callTimeout(timeoutSeconds, TimeUnit.SECONDS)
        if (proxy != null) {
            builder.proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(proxy.host, proxy.port)))
            val username = proxy.username
            if (!username.isNullOrEmpty()) {
                val credential = Credentials.basic(username, proxy.password ?: "")
                builder.proxyAuthenticator(object : Authenticator {
                    override fun authenticate(route: okhttp3.Route?, response: Response): Request? {
                        if (response.request.header("Proxy-Authorization") != null) return null
                        return response.request.newBuilder().header("Proxy-Authorization", credential).build()
                    }
                })
            }
        }
        return builder.build()
    }

    fun get(url: String, headers: Map<String, String> = emptyMap()): Request {
        val builder = Request.Builder().url(url).header("User-Agent", Browser.USER_AGENT)
        for ((name, value) in headers) builder.header(name, value)
        return builder.build()
    }

    /** Twitch's playlist servers expect the player's origin. */
    fun playlist(url: String): Request = get(
        url,
        mapOf("Referer" to "https://player.twitch.tv", "Origin" to "https://player.twitch.tv"),
    )
}

class HttpStatusException(val code: Int) : IOException("HTTP $code")

/** Runs the request without blocking; the body is read on OkHttp's thread. */
suspend fun OkHttpClient.fetch(request: Request): HttpResult = suspendCancellableCoroutine { continuation ->
    val call = newCall(request)
    continuation.invokeOnCancellation { runCatching { call.cancel() } }
    call.enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (continuation.isActive) continuation.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            val result = try {
                response.use { HttpResult(it.code, it.body?.string() ?: "", it.request.url.toString()) }
            } catch (e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
                return
            }
            if (continuation.isActive) continuation.resume(result)
        }
    })
}

/** Resolves `uri` against `base` (Twitch's newer playlists use relative addresses). */
fun resolveUrl(uri: String, base: String?): String {
    val trimmed = uri.trim()
    if (trimmed.startsWith("https://") || trimmed.startsWith("http://")) return trimmed
    if (base == null) return trimmed
    return base.toHttpUrlOrNull()?.resolve(trimmed)?.toString() ?: trimmed
}
