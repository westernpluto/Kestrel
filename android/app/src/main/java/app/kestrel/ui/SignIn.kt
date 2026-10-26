package app.kestrel.ui

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
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
import app.kestrel.core.TwitchDeviceLogin
import app.kestrel.data.TwitchAccount
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicReference

private enum class SignInWay(val label: String) {
    Code("With a code"),
    Page("Login page"),
    Token("Paste token"),
}

/**
 * Signing in to Twitch, three ways:
 * - With a code (the default): you approve Kestrel at twitch.tv/activate in any browser, the way
 *   TV apps sign in. Nothing of Twitch's website runs inside Kestrel, so it works on any phone.
 * - Twitch's login page inside Kestrel (Kestrel takes the token once the page is signed in).
 * - Pasting the website's auth-token.
 */
@Composable
fun SignInDialog(onDismiss: () -> Unit) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        var way by remember { mutableStateOf(SignInWay.Code) }
        var mobileSite by remember { mutableStateOf(false) }
        var error by remember { mutableStateOf<String?>(null) }
        var working by remember { mutableStateOf(false) }
        var pasted by remember { mutableStateOf("") }
        val scope = rememberCoroutineScope()
        val clipboard = LocalClipboardManager.current

        fun submit(token: String, deviceId: String?, viaTwitch: Boolean, refreshToken: String? = null) {
            if (working) return
            working = true
            error = null
            scope.launch {
                try {
                    TwitchAccount.signIn(token, deviceId, viaTwitch, refreshToken)
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
                    Spacer(Modifier.width(72.dp))
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
                ) {
                    for (option in SignInWay.values()) {
                        val selected = option == way
                        Text(
                            option.label,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (selected) Color.Black else Color.White,
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(if (selected) AccentTeal else Color.White.copy(alpha = 0.08f))
                                .clickable {
                                    error = null
                                    way = option
                                }
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                        )
                    }
                }
                error?.let { Text(it, color = Color(0xFFFF9F0A), fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) }
                when (way) {
                    SignInWay.Code -> Box(Modifier.fillMaxWidth().weight(1f)) {
                        CodeSignIn { grant -> submit(grant.accessToken, null, viaTwitch = true, refreshToken = grant.refreshToken) }
                        if (working) BusyOverlay("Signing in…")
                    }
                    SignInWay.Page -> {
                        Box(Modifier.fillMaxWidth().weight(1f)) {
                            // A new page (and its own browser identity) when switching sites.
                            key(mobileSite) {
                                LoginWebView(
                                    mobileSite = mobileSite,
                                    onProblem = { error = it },
                                    found = { token, deviceId -> submit(token, deviceId, viaTwitch = true) },
                                )
                            }
                            if (working) BusyOverlay("Signing in…")
                        }
                        Row(
                            Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                if (mobileSite) "On Twitch's mobile site." else "Page blank or not going through?",
                                fontSize = 12.sp, color = Secondary, modifier = Modifier.weight(1f),
                            )
                            TextButton(onClick = {
                                error = null
                                mobileSite = !mobileSite
                            }) { Text(if (mobileSite) "Use the full site" else "Try the mobile site", fontSize = 13.sp) }
                        }
                    }
                    SignInWay.Token -> Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(16.dp)) {
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
                            onClick = { submit(pasted, null, viaTwitch = false) },
                            enabled = pasted.isNotBlank() && !working,
                            colors = ButtonDefaults.buttonColors(containerColor = AccentTeal, contentColor = Color.Black),
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text(if (working) "Checking…" else "Sign in") }
                    }
                }
            }
        }
    }
}

/**
 * Shows a code from Twitch and waits for it to be approved at twitch.tv/activate (Kestrel asks
 * Twitch every few seconds, so it carries on by itself once you have). A code lasts about half an
 * hour; a new one appears after that.
 */
@Composable
private fun CodeSignIn(approved: (TwitchDeviceLogin.Grant) -> Unit) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val onApproved by rememberUpdatedState(approved)
    var code by remember { mutableStateOf<TwitchDeviceLogin.Code?>(null) }
    var problem by remember { mutableStateOf<String?>(null) }
    var round by remember { mutableIntStateOf(0) }
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(round) {
        code = null
        problem = null
        copied = false
        val current = try {
            TwitchDeviceLogin.start()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val message = e.message ?: "Couldn't get a code from Twitch."
            ActivityLog.add("Sign-in with a code: $message")
            problem = message
            return@LaunchedEffect
        }
        code = current
        var interval = current.intervalSeconds
        while (true) {
            delay(interval * 1000L)
            if (System.currentTimeMillis() >= current.expiresAt) {
                round++
                return@LaunchedEffect
            }
            when (val result = TwitchDeviceLogin.poll(current)) {
                is TwitchDeviceLogin.Poll.Pending -> Unit
                is TwitchDeviceLogin.Poll.SlowDown -> interval += 5
                is TwitchDeviceLogin.Poll.Expired -> {
                    round++
                    return@LaunchedEffect
                }
                is TwitchDeviceLogin.Poll.Refused -> {
                    val message = "Twitch didn't accept the code (${result.message})."
                    ActivityLog.add("Sign-in with a code: $message")
                    problem = message
                    return@LaunchedEffect
                }
                is TwitchDeviceLogin.Poll.Done -> {
                    onApproved(result.grant)
                    return@LaunchedEffect
                }
            }
        }
    }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(Modifier.widthIn(max = 520.dp).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Approve Kestrel on Twitch", fontSize = 20.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
            Spacer(Modifier.height(8.dp))
            Text(
                "Open twitch.tv/activate in a browser where you're signed in to Twitch (on this phone or any other device), " +
                    "enter this code and approve it. Kestrel signs in by itself once you do.",
                fontSize = 14.sp, color = Secondary, textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(24.dp))
            Box(
                Modifier.fillMaxWidth().height(84.dp).clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.08f)),
                contentAlignment = Alignment.Center,
            ) {
                val shown = code
                when {
                    shown != null -> Text(
                        shown.userCode,
                        fontSize = 36.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace, letterSpacing = 4.sp,
                    )
                    problem == null -> CircularProgressIndicator(Modifier.size(28.dp), color = AccentTeal, strokeWidth = 3.dp)
                    else -> Text("No code", color = Secondary)
                }
            }
            Spacer(Modifier.height(16.dp))
            val shown = code
            Button(
                onClick = {
                    val target = shown?.verificationUri ?: "https://www.twitch.tv/activate"
                    runCatching {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(target)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }.onFailure { problem = "No browser to open twitch.tv/activate in: open it on another device." }
                },
                enabled = shown != null,
                colors = ButtonDefaults.buttonColors(containerColor = AccentTeal, contentColor = Color.Black),
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Open twitch.tv/activate") }
            Spacer(Modifier.height(8.dp))
            OutlinedButton(
                onClick = {
                    shown?.let {
                        clipboard.setText(AnnotatedString(it.userCode))
                        copied = true
                    }
                },
                enabled = shown != null,
                modifier = Modifier.fillMaxWidth(),
            ) { Text(if (copied) "Copied" else "Copy code") }
            Spacer(Modifier.height(20.dp))
            if (shown != null && problem == null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(14.dp), color = Secondary, strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Text("Waiting for you to approve it…", fontSize = 13.sp, color = Secondary)
                }
            }
            problem?.let {
                Text(it, fontSize = 13.sp, color = Color(0xFFFF9F0A), textAlign = TextAlign.Center)
            }
            TextButton(onClick = { round++ }) { Text("Get a new code") }
            Spacer(Modifier.height(12.dp))
            Text(
                "Twitch lists this as its TV app signing in: Kestrel signs in the same way TV apps do. " +
                    "The code works for about 30 minutes.",
                fontSize = 12.sp, color = Tertiary, textAlign = TextAlign.Center,
            )
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
                webChromeClient = object : WebChromeClient() {
                    private var logged = 0

                    // A blank page is usually the site's script failing: what it said goes to the log.
                    override fun onConsoleMessage(message: ConsoleMessage?): Boolean {
                        if (message != null && message.messageLevel() == ConsoleMessage.MessageLevel.ERROR && logged < 5) {
                            logged++
                            ActivityLog.add("Sign-in page error: ${message.message().take(200)}")
                        }
                        return super.onConsoleMessage(message)
                    }
                }
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
