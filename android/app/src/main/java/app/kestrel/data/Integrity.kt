package app.kestrel.data

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import app.kestrel.core.ActivityLog
import app.kestrel.core.Browser
import app.kestrel.core.Kestrel
import app.kestrel.core.TwitchApi
import app.kestrel.core.TwitchAuth
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Following and unfollowing on Twitch: Twitch only accepts those from its own website, which
 * proves itself with an "integrity" token (the site's bot protection gets it). Like Xtra, Kestrel
 * opens twitch.tv invisibly, lets the site get a token, and uses it for the follow request. Tokens
 * last several hours, so this only happens once in a while.
 */
object TwitchIntegrity {
    private data class Grant(val headers: Map<String, String>, val userId: String, val expires: Long)

    class Failure(message: String) : Exception(message)

    /** Where the invisible page sits (the activity's content view), set by MainActivity. */
    var host: ViewGroup? = null

    private val main = Handler(Looper.getMainLooper())
    private var grant: Grant? = null
    private var webView: WebView? = null
    private val waiting = mutableListOf<CancellableContinuation<Map<String, String>>>()
    private var askedManually = 0
    private var lastError: String? = null
    private var hookedAtStart = false
    private val timeout = Runnable { finish(null, Failure(lastError?.let { "twitch.tv refused ($it)" } ?: "twitch.tv didn't hand out a token in time")) }

    /** Headers that make a GQL request look like it came from twitch.tv itself. */
    suspend fun headers(refresh: Boolean = false): Map<String, String> = withContext(Dispatchers.Main) {
        val session = TwitchAuth.session ?: throw Failure("Not signed in")
        val current = grant
        if (!refresh && current != null && current.userId == session.userID && current.expires > System.currentTimeMillis()) {
            return@withContext current.headers
        }
        if (refresh) grant = null
        suspendCancellableCoroutine { continuation ->
            waiting.add(continuation)
            continuation.invokeOnCancellation { main.post { waiting.remove(continuation) } }
            if (webView == null) start()
        }
    }

    fun invalidate() {
        grant = null
    }

    private const val HOOK = """
(function () {
  if (window.__kestrelHooked) return;
  window.__kestrelHooked = true;
  var wanted = ['client-integrity', 'x-device-id', 'client-id', 'client-session-id', 'client-version', 'authorization'];
  function post(message) {
    try { KestrelIntegrity.post(JSON.stringify(message)); } catch (e) {}
  }
  function collect(headers, out) {
    if (!headers) return out;
    try {
      if (typeof Headers !== 'undefined' && headers instanceof Headers) {
        headers.forEach(function (value, key) { if (wanted.indexOf(key.toLowerCase()) >= 0) out[key.toLowerCase()] = String(value); });
      } else if (Array.isArray(headers)) {
        headers.forEach(function (pair) { var key = String(pair[0]).toLowerCase(); if (wanted.indexOf(key) >= 0) out[key] = String(pair[1]); });
      } else {
        Object.keys(headers).forEach(function (key) { if (wanted.indexOf(key.toLowerCase()) >= 0) out[key.toLowerCase()] = String(headers[key]); });
      }
    } catch (e) {}
    return out;
  }
  var originalFetch = window.fetch;
  window.fetch = function (input, init) {
    try {
      var url = typeof input === 'string' ? input : (input && input.url) || '';
      if (url.indexOf('gql.twitch.tv') >= 0) {
        var headers = {};
        if (typeof Request !== 'undefined' && input instanceof Request) collect(input.headers, headers);
        collect(init && init.headers, headers);
        if (url.indexOf('/integrity') >= 0) {
          return originalFetch.apply(this, arguments).then(function (response) {
            try {
              response.clone().json().then(function (json) {
                if (json && json.token) post({ kind: 'token', token: json.token, expiration: json.expiration || 0, headers: headers });
                else post({ kind: 'error', message: JSON.stringify(json).slice(0, 160) });
              }).catch(function () {});
            } catch (e) {}
            return response;
          });
        }
        if (headers['client-integrity']) post({ kind: 'headers', headers: headers });
      }
    } catch (e) {}
    return originalFetch.apply(this, arguments);
  };
  var open = XMLHttpRequest.prototype.open;
  var setHeader = XMLHttpRequest.prototype.setRequestHeader;
  var send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__kestrelURL = String(url);
    this.__kestrelHeaders = {};
    return open.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function (key, value) {
    try {
      if (this.__kestrelHeaders && wanted.indexOf(String(key).toLowerCase()) >= 0) this.__kestrelHeaders[String(key).toLowerCase()] = String(value);
    } catch (e) {}
    return setHeader.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    try {
      if (this.__kestrelURL && this.__kestrelURL.indexOf('gql.twitch.tv') >= 0 && this.__kestrelHeaders['client-integrity']) {
        post({ kind: 'headers', headers: this.__kestrelHeaders });
      }
    } catch (e) {}
    return send.apply(this, arguments);
  };
})();
"""

    /** Asks for a token from inside the page, the way the site does (its bot protection adds what it needs). */
    private fun askScript(clientId: String, token: String, device: String): String = """
(function () {
  function post(message) { try { KestrelIntegrity.post(JSON.stringify(message)); } catch (e) {} }
  fetch('https://gql.twitch.tv/integrity', {
    method: 'POST',
    headers: { 'Client-Id': ${JSONObject.quote(clientId)}, 'Authorization': 'OAuth ' + ${JSONObject.quote(token)}, 'X-Device-Id': ${JSONObject.quote(device)} }
  }).then(function (r) { return r.json(); }).then(function (json) {
    if (json && json.token) post({ kind: 'token', token: json.token, expiration: json.expiration || 0, mine: true });
    else post({ kind: 'error', message: JSON.stringify(json).slice(0, 160) });
  }).catch(function (e) { post({ kind: 'error', message: String(e) }); });
})();
"""

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    private fun start() {
        val view = WebView(host?.context ?: Kestrel.app)
        view.settings.javaScriptEnabled = true
        view.settings.domStorageEnabled = true
        view.settings.userAgentString = Browser.USER_AGENT
        view.settings.mediaPlaybackRequiresUserGesture = true
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, true)
        view.addJavascriptInterface(Bridge(), "KestrelIntegrity")
        hookedAtStart = runCatching {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                WebViewCompat.addDocumentStartJavaScript(view, HOOK, setOf("https://www.twitch.tv"))
                true
            } else {
                false
            }
        }.getOrDefault(false)
        view.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                if (!hookedAtStart) view?.evaluateJavascript(HOOK, null)
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                if (!hookedAtStart) view?.evaluateJavascript(HOOK, null)
                // The site usually fetches a token by itself; if it hasn't after a moment, ask for one.
                main.postDelayed({ askManually() }, 3000)
            }
        }
        view.alpha = 0.01f
        view.isFocusable = false
        // Pages that aren't on screen at all get throttled; this one sits invisibly in a corner.
        host?.addView(view, FrameLayout.LayoutParams(8, 8))
        webView = view
        askedManually = 0
        lastError = null
        view.loadUrl("https://www.twitch.tv/")
        main.postDelayed(timeout, 25_000)
    }

    private fun askManually() {
        val view = webView ?: return
        val session = TwitchAuth.session ?: return
        if (askedManually >= 2) return
        askedManually++
        view.evaluateJavascript(askScript(TwitchApi.CLIENT_ID, session.token, TwitchApi.accountDeviceId), null)
    }

    private class Bridge {
        @JavascriptInterface
        fun post(json: String) {
            TwitchIntegrity.main.post { TwitchIntegrity.received(json) }
        }
    }

    private fun received(text: String) {
        val message = runCatching { JSONObject(text) }.getOrNull() ?: return
        val session = TwitchAuth.session ?: return
        val kind = message.optString("kind")
        val captured = HashMap<String, String>()
        message.optJSONObject("headers")?.let { headers ->
            for (key in headers.keys()) headers.optString(key).takeIf { it.isNotEmpty() }?.let { captured[key] = it }
        }
        // Only what belongs to this account (a signed-out page gets tokens for nobody).
        val ours = message.optBoolean("mine", false) || captured["authorization"] == "OAuth ${session.token}"
        when (kind) {
            "token" -> {
                val token = message.optString("token").takeIf { it.isNotEmpty() } ?: return
                if (!ours) return
                val headers = mutableMapOf(
                    "Client-Integrity" to token,
                    "X-Device-Id" to (captured["x-device-id"] ?: TwitchApi.accountDeviceId),
                )
                captured["client-session-id"]?.let { headers["Client-Session-Id"] = it }
                captured["client-version"]?.let { headers["Client-Version"] = it }
                val expiration = message.optDouble("expiration", 0.0).toLong()
                val now = System.currentTimeMillis()
                val expires = (if (expiration > 0) expiration else now + 8 * 3600_000L).coerceAtMost(now + 15 * 3600_000L) - 300_000
                finish(Grant(headers, session.userID, expires), null)
            }
            "headers" -> {
                val token = captured["client-integrity"] ?: return
                if (!ours) return
                val headers = mutableMapOf("Client-Integrity" to token)
                captured["x-device-id"]?.let { headers["X-Device-Id"] = it }
                captured["client-session-id"]?.let { headers["Client-Session-Id"] = it }
                captured["client-version"]?.let { headers["Client-Version"] = it }
                finish(Grant(headers, session.userID, System.currentTimeMillis() + 4 * 3600_000L), null)
            }
            "error" -> {
                lastError = message.optString("message")
                // Try once more a bit later (the site's protection may still have been loading).
                main.postDelayed({ askManually() }, 4000)
            }
        }
    }

    private fun finish(result: Grant?, error: Exception?) {
        if (webView == null && waiting.isEmpty()) return
        main.removeCallbacks(timeout)
        webView?.let { view ->
            view.stopLoading()
            (view.parent as? ViewGroup)?.removeView(view)
            view.destroy()
        }
        webView = null
        val continuations = waiting.toList()
        waiting.clear()
        if (result != null) {
            grant = result
            ActivityLog.add("Twitch integrity token received (for following)")
            continuations.forEach { if (it.isActive) it.resume(result.headers) }
        } else {
            val failure = error ?: Failure("twitch.tv didn't hand out a token")
            ActivityLog.add("Couldn't get a Twitch integrity token: ${failure.message}")
            continuations.forEach { if (it.isActive) it.resumeWithException(failure) }
        }
    }
}
