package app.kestrel.ui

import android.annotation.SuppressLint
import android.webkit.CookieManager
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
import app.kestrel.core.Browser
import app.kestrel.data.TwitchAccount
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Sign in on twitch.tv's own login page; once it sets the `auth-token` cookie, Kestrel takes it. */
@Composable
fun SignInDialog(onDismiss: () -> Unit) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        var pasting by remember { mutableStateOf(false) }
        var error by remember { mutableStateOf<String?>(null) }
        var working by remember { mutableStateOf(false) }
        var pasted by remember { mutableStateOf("") }
        val scope = rememberCoroutineScope()
        val clipboard = LocalClipboardManager.current

        fun submit(token: String, deviceId: String?) {
            if (working) return
            working = true
            error = null
            scope.launch {
                try {
                    TwitchAccount.signIn(token, deviceId)
                    App.chat?.reconnect()
                    onDismiss()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    error = e.message ?: "Couldn't sign in."
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
                    TextButton(onClick = { pasting = !pasting }) { Text(if (pasting) "Login page" else "Paste token") }
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
                            onClick = { submit(pasted, null) },
                            enabled = pasted.isNotBlank() && !working,
                            colors = ButtonDefaults.buttonColors(containerColor = AccentTeal, contentColor = Color.Black),
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text(if (working) "Checking…" else "Sign in") }
                    }
                } else {
                    Box(Modifier.fillMaxWidth().weight(1f)) {
                        LoginWebView { token, deviceId -> submit(token, deviceId) }
                        if (working) BusyOverlay("Signing in…")
                    }
                }
            }
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun LoginWebView(found: (String, String?) -> Unit) {
    val onFound by rememberUpdatedState(found)
    AndroidView(
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                // The full website, not "open the app".
                settings.userAgentString = Browser.USER_AGENT
                CookieManager.getInstance().setAcceptCookie(true)
                CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                webViewClient = WebViewClient()
                loadUrl("https://www.twitch.tv/login")
            }
        },
        onRelease = { it.destroy() },
        modifier = Modifier.fillMaxSize(),
    )
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            val cookies = CookieManager.getInstance().getCookie("https://www.twitch.tv") ?: continue
            val values = cookies.split(';').mapNotNull { pair ->
                val parts = pair.trim().split('=', limit = 2)
                if (parts.size == 2) parts[0] to parts[1] else null
            }.toMap()
            val token = values["auth-token"]?.takeIf { it.isNotEmpty() } ?: continue
            onFound(token, values["unique_id"])
            break
        }
    }
}
