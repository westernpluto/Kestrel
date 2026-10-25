package app.kestrel.ui

import android.annotation.SuppressLint
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.kestrel.core.ActivityLog
import app.kestrel.core.Browser
import app.kestrel.data.TwitchAccount
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicReference

/**
 * Sign in on twitch.tv's own login page; once the page is signed in, Kestrel takes its token (from
 * the `auth-token` cookie, or from the page's own requests to Twitch). If the full site's login
 * won't go through, Twitch's mobile site is one tap away; pasting the token is the last resort.
 */
@Composable
fun SignInDialog(onDismiss: () -> Unit) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        var pasting by remember { mutableStateOf(false) }
        var mobileSite by remember { mutableStateOf(false) }
        var error by remember { mutableStateOf<String?>(null) }
        var working by remember { mutableStateOf(false) }
        var pasted by remember { mutableStateOf("") }
        val scope = rememberCoroutineScope()
        val clipboard = LocalClipboardManager.current

        fun submit(token: String, deviceId: String?, fromWebsite: Boolean) {
            if (working) return
            working = true
            error = null
            scope.launch {
                try {
                    TwitchAccount.signIn(token, deviceId, fromWebsite)
                    App.chat?.reconnect()
                    onDismiss()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    val message = e.message ?: "Couldn't sign in."
                    ActivityLog.add("Sign-in failed: $message")
                    error = message
                } finally {
                    working = false
                }
            }
        }

        Surface(Modifier.fillMaxSize(), color = Color.Black) {
            Column(Modifier.fillMaxSize().systemBarsPadding().imePadding()) {
                Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = onDismiss) { Text("Cancel") }
                    Text("Sign in to Twitch", fontWeight = FontWeight.SemiBold, fontSize = 17.sp, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
                    TextButton(onClick = {
                        error = null
                        pasting = !pasting
                    }) { Text(if (pasting) "Login page" else "Paste token") }
                }
                error?.let { Text(it, color = Color(0xFFFF9F0A), fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) }
                if (pasting) {
                    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp)) {
                        OutlinedTextField(
                            value = pasted,
                            onValueChange = { pasted = it },
                            label = { Text("auth-token") },
                            singleLine = true,
                            visualTransformation = PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                            textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Spacer(Modifier.height(8.dp))
                        OutlinedButton(onClick = { pasted = clipboard.getText()?.text ?: "" }) { Text("Paste from clipboard") }
                        Spacer(Modifier.height(12.dp))
                        Text(
                            "On a computer: sign in on twitch.tv, open the browser's developer tools, and copy the value of the auth-token " +
                                "cookie (Application → Cookies). It gives full access to your account, so only paste it here.",
                            fontSize = 13.sp, color = Secondary,
                        )
                        Spacer(Modifier.height(16.dp))
                        Button(
                            onClick = { submit(pasted, null, fromWebsite = false) },
                            enabled = pasted.isNotBlank() && !working,
                            colors = ButtonDefaults.buttonColors(containerColor = AccentTeal, contentColor = Color.Black),
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text(if (working) "Checking…" else "Sign in") }
                    }
                } else {
                    Box(Modifier.fillMaxWidth().weight(1f)) {
                        // A new page (and its own browser identity) when switching sites.
                        key(mobileSite) {
                            LoginWebView(
                                mobileSite = mobileSite,
                                onProblem = { error = it },
                                found = { token, deviceId -> submit(token, deviceId, fromWebsite = true) },
                            )
                        }
                        if (working) BusyOverlay("Signing in…")
                    }
                    Row(
                        Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            if (mobileSite) "On Twitch's mobile site." else "Login not going through?",
                            fontSize = 12.sp, color = Secondary, modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = {
                            error = null
                            mobileSite = !mobileSite
                        }) { Text(if (mobileSite) "Use the full site" else "Try the mobile site", fontSize = 13.sp) }
                    }
                }
            }
        }
    }
}

private fun parseCookies(header: String): Map<String, String> = header.split(';').mapNotNull { pair ->
    val parts = pair.trim().split('=', limit = 2)
    if (parts.size == 2) parts[0] to parts[1] else null
}.toMap()

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun LoginWebView(mobileSite: Boolean, onProblem: (String) -> Unit, found: (String, String?) -> Unit) {
    val onFound by rememberUpdatedState(found)
    val reportProblem by rememberUpdatedState(onProblem)
    // The token as the page itself sends it to Twitch once signed in (seen on WebView's network thread).
    val sent = remember { AtomicReference<String?>(null) }
    AndroidView(
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.javaScriptCanOpenWindowsAutomatically = true
                // The full website (or the mobile one), introducing itself as the Chrome version the
                // page really runs on.
                settings.userAgentString = if (mobileSite) Browser.mobileUserAgent(context) else Browser.webUserAgent(context)
                CookieManager.getInstance().setAcceptCookie(true)
                CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                webChromeClient = WebChromeClient()
                webViewClient = object : WebViewClient() {
                    override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                        val host = request?.url?.host.orEmpty()
                        if (host.endsWith("twitch.tv")) {
                            val authorization = request?.requestHeaders?.entries
                                ?.firstOrNull { it.key.equals("Authorization", ignoreCase = true) }?.value
                            val token = authorization?.trim()?.takeIf { it.startsWith("OAuth ", ignoreCase = true) }
                                ?.substring(6)?.trim()
                            if (!token.isNullOrEmpty() && !token.equals("undefined", ignoreCase = true) && !token.equals("null", ignoreCase = true)) {
                                sent.set(token)
                            }
                        }
                        return null
                    }

                    override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                        if (request?.isForMainFrame != true) return
                        val message = "The login page didn't load (${error?.description ?: "error ${error?.errorCode}"})."
                        ActivityLog.add("Sign-in: $message")
                        reportProblem(message)
                    }

                    override fun onReceivedHttpError(view: WebView?, request: WebResourceRequest?, errorResponse: WebResourceResponse?) {
                        if (request?.isForMainFrame != true) return
                        ActivityLog.add("Sign-in: ${request.url} answered HTTP ${errorResponse?.statusCode}")
                    }
                }
                // Not signed in to Kestrel: start from a clean slate, so an old (expired) website login
                // isn't picked up instead of the one you're about to make.
                if (TwitchAccount.session == null) {
                    CookieManager.getInstance().removeAllCookies { loadUrl("https://www.twitch.tv/login") }
                } else {
                    loadUrl("https://www.twitch.tv/login")
                }
            }
        },
        onRelease = {
            it.stopLoading()
            it.destroy()
        },
        modifier = Modifier.fillMaxSize(),
    )
    LaunchedEffect(Unit) {
        var reported: String? = null
        while (true) {
            delay(700)
            val cookies = CookieManager.getInstance().getCookie("https://www.twitch.tv")?.let(::parseCookies).orEmpty()
            val token = cookies["auth-token"]?.takeIf { it.isNotEmpty() } ?: sent.get() ?: continue
            // Each token once (if Twitch turns one down, the error shows and the page stays).
            if (token == reported) continue
            reported = token
            onFound(token, cookies["unique_id"])
        }
    }
}
