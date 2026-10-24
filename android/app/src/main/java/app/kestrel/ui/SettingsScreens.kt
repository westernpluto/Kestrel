package app.kestrel.ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import app.kestrel.BuildConfig
import app.kestrel.core.ActivityLog
import app.kestrel.core.AdFreeProxy
import app.kestrel.core.DeviceCodecs
import app.kestrel.data.AdBlocking
import app.kestrel.data.AppReset
import app.kestrel.data.AppSettings
import app.kestrel.data.LiveNotifier
import app.kestrel.data.TwitchAccount
import coil.imageLoader
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
private fun Toggle(checked: Boolean, onChange: (Boolean) -> Unit) {
    Switch(
        checked = checked, onCheckedChange = onChange,
        colors = SwitchDefaults.colors(checkedTrackColor = AccentTeal, checkedThumbColor = Color.White),
    )
}

@Composable
private fun Divider() = HorizontalDivider(color = Color(0xFF26262B), thickness = 0.5.dp, modifier = Modifier.padding(start = 16.dp))

@Composable
fun SettingsScreen(padding: PaddingValues, miniPlayerSpace: Dp) {
    val context = LocalContext.current
    val session = TwitchAccount.session
    var confirmSignOut by remember { mutableStateOf(false) }
    var confirmReset by remember { mutableStateOf(false) }
    var cacheCleared by remember { mutableStateOf(false) }
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        LiveNotifier.updateEnabled(granted)
    }

    Column(Modifier.fillMaxSize()) {
        TopBar("Settings")
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = padding.calculateBottomPadding() + miniPlayerSpace + 24.dp)) {
            item {
                SectionHeader("Twitch account")
                if (session != null) {
                    Row(Modifier.fillMaxWidth().background(Surface1).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.AccountCircle, contentDescription = null, tint = AccentTeal, modifier = Modifier.size(36.dp))
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text(session.login, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                            Text(
                                when (TwitchAccount.hasTurbo) {
                                    true -> "Turbo: Twitch sends you no ads"
                                    false -> "Signed in"
                                    null -> "Checking…"
                                },
                                fontSize = 13.sp, color = Secondary,
                            )
                        }
                    }
                    Divider()
                    SettingRow("Sign out", titleColor = LiveRed, onClick = { confirmSignOut = true })
                } else {
                    SettingRow("Sign in with Twitch", titleColor = AccentTeal, onClick = { App.showSignIn = true })
                    SectionFooter("Sign in to chat as yourself and see who you follow. Your login stays on this phone and only goes to Twitch.")
                }
            }
            item {
                SectionHeader("Playback")
                SettingRow("Low latency", subtitle = "Plays the newest video Twitch is still sending (a few seconds behind live)") {
                    Toggle(AppSettings.lowLatency) { AppSettings.lowLatency = it }
                }
                Divider()
                SettingRow("Ad blocking", value = AppSettings.adBlocking.shortTitle, onClick = { App.push(Route.AdBlocking) }) {
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Tertiary)
                }
                Divider()
                SettingRow("Background audio", subtitle = "Keeps playing when you leave Kestrel or lock the phone") {
                    Toggle(AppSettings.backgroundAudio) { AppSettings.backgroundAudio = it }
                }
                Divider()
                SettingRow("Picture in picture", subtitle = "Leaving Kestrel while a stream plays shrinks it into a floating window") {
                    Toggle(AppSettings.pictureInPicture) { AppSettings.pictureInPicture = it }
                }
                SectionFooter(
                    "Streams always start at the highest quality (this phone decodes ${DeviceCodecs.summary}). " +
                        "Quality and video stats are in the player's gear menu.",
                )
            }
            item {
                SectionHeader("Notifications")
                SettingRow("Go-live alerts") {
                    Toggle(LiveNotifier.enabled) { on ->
                        if (on && Build.VERSION.SDK_INT >= 33 &&
                            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                        } else {
                            LiveNotifier.updateEnabled(on)
                        }
                    }
                }
                Divider()
                SettingRow("Notification settings", onClick = {
                    val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                    runCatching { context.startActivity(intent) }
                }) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Tertiary) }
                SectionFooter(
                    "A notification when a channel you follow goes live (your Twitch follows and the channels you heart); tap it to watch. " +
                        "Kestrel checks every minute while it's open or playing, and about every 15 minutes in the background " +
                        "(Android decides exactly when; battery savers can delay it).",
                )
            }
            item {
                SectionHeader("Chat")
                SettingRow("Text size", value = "${AppSettings.chatFontSize.toInt()} sp") {
                    Row {
                        TextButton(onClick = { AppSettings.chatFontSize = (AppSettings.chatFontSize - 1).coerceAtLeast(11f) }) { Text("−", fontSize = 20.sp) }
                        TextButton(onClick = { AppSettings.chatFontSize = (AppSettings.chatFontSize + 1).coerceAtMost(22f) }) { Text("+", fontSize = 20.sp) }
                    }
                }
            }
            item {
                SectionHeader("Troubleshooting")
                SettingRow("Activity log", onClick = { App.push(Route.ActivityLog) }) {
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Tertiary)
                }
                Divider()
                SettingRow(if (cacheCleared) "Image cache cleared" else "Clear image cache", titleColor = if (cacheCleared) Secondary else AccentTeal, onClick = {
                    if (!cacheCleared) {
                        context.imageLoader.memoryCache?.clear()
                        runCatching { java.io.File(context.cacheDir, "image_cache").deleteRecursively() }
                        cacheCleared = true
                    }
                })
                SectionFooter("Kestrel ${BuildConfig.VERSION_NAME}")
            }
            item {
                SectionHeader("Start fresh")
                SettingRow("Reset Kestrel", titleColor = LiveRed, onClick = { confirmReset = true })
                SectionFooter(
                    "Erases everything Kestrel has stored on this phone: your Twitch login, follows added in Kestrel, watch progress, " +
                        "search history, settings and caches. Kestrel closes when it's done; open it again to start fresh.",
                )
            }
        }
    }

    if (confirmSignOut) {
        AlertDialog(
            onDismissRequest = { confirmSignOut = false },
            title = { Text("Sign out of Twitch?") },
            confirmButton = {
                TextButton(onClick = {
                    confirmSignOut = false
                    TwitchAccount.signOut()
                    App.chat?.reconnect()
                }) { Text("Sign out", color = LiveRed) }
            },
            dismissButton = { TextButton(onClick = { confirmSignOut = false }) { Text("Cancel") } },
        )
    }
    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            title = { Text("Erase everything and start fresh?") },
            text = { Text("Your Twitch login, follows added in Kestrel, watch progress, search history and settings are deleted. Your Twitch account itself isn't changed.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmReset = false
                    App.closePlayer()
                    (context as? Activity)?.let { AppReset.eraseEverything(it) }
                }) { Text("Erase and close Kestrel", color = LiveRed) }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Cancel") } },
        )
    }
}

@Composable
fun AdBlockingScreen(padding: PaddingValues, miniPlayerSpace: Dp) {
    val current = AppSettings.adBlocking
    Column(Modifier.fillMaxSize()) {
        TopBar("Ad blocking", onBack = { App.back() })
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = padding.calculateBottomPadding() + miniPlayerSpace + 24.dp)) {
            if (TwitchAccount.session != null) {
                item {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.Top) {
                        Icon(KIcons.Shield, contentDescription = null, tint = AccentTeal, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(10.dp))
                        Text(
                            if (TwitchAccount.hasTurbo == true) {
                                "You have Turbo, so Twitch shows you no ads anywhere: Kestrel plays straight from Twitch."
                            } else {
                                "On channels you're subscribed to, Twitch shows you no ads, so Kestrel plays those straight from Twitch (every quality, Twitch's own low latency). The setting below is for everything else."
                            },
                            fontSize = 13.sp, color = Secondary,
                        )
                    }
                }
            }
            item {
                SectionHeader("Mode")
                Choice("Automatic", "The ad-free server that answers first (recommended)", current == AdBlocking.Automatic) {
                    AppSettings.adBlocking = AdBlocking.Automatic
                }
                Divider()
                Choice("My own proxy", "An HTTP proxy in a country without Twitch ads", current == AdBlocking.CustomProxy) {
                    AppSettings.adBlocking = AdBlocking.CustomProxy
                }
                Divider()
                Choice("Basic", "No server: skip ad breaks Kestrel can see, hide the rest", current == AdBlocking.Basic) {
                    AppSettings.adBlocking = AdBlocking.Basic
                }
                SectionFooter(
                    "Ad-free servers ask Twitch for the stream from a country where Twitch doesn't run ads (the TTV LOL PRO v1 servers). " +
                        "Only the playlist request goes through them; the video comes straight from Twitch at full quality. Applies to the next stream you open.",
                )
            }
            if (current == AdBlocking.CustomProxy) {
                item {
                    SectionHeader("Your proxy")
                    Column(Modifier.fillMaxWidth().background(Surface1).padding(16.dp)) {
                        ProxyField("Host", AppSettings.proxyHost, KeyboardType.Uri) { AppSettings.proxyHost = it }
                        ProxyField("Port", AppSettings.proxyPort, KeyboardType.Number) { AppSettings.proxyPort = it }
                        ProxyField("Username (optional)", AppSettings.proxyUsername, KeyboardType.Text) { AppSettings.proxyUsername = it }
                        ProxyField("Password (optional)", AppSettings.proxyPassword, KeyboardType.Password, secret = true) { AppSettings.proxyPassword = it }
                    }
                    SectionFooter("Twitch's playback requests go through it; video still comes straight from Twitch.")
                }
            }
            item { SectionHeader("Or pick a server") }
            items(AdFreeProxy.all, key = { it.host }) { server ->
                val detail = buildString {
                    append("Twitch sees: ${server.country}")
                    if (server.host == AdFreeProxy.lastWorkingHost) append(" · last used")
                }
                Choice(server.host, detail, current == AdBlocking.Server(server.host)) { AppSettings.adBlocking = AdBlocking.Server(server.host) }
                Divider()
            }
            item { SectionFooter("If the chosen server is down, Kestrel tries the others.") }
        }
    }
}

@Composable
private fun Choice(title: String, detail: String, selected: Boolean, onClick: () -> Unit) {
    SettingRow(title, subtitle = detail, onClick = onClick) {
        Box(Modifier.size(24.dp)) {
            if (selected) Icon(Icons.Filled.Check, contentDescription = "Selected", tint = AccentTeal)
        }
    }
}

@Composable
private fun ProxyField(label: String, value: String, type: KeyboardType, secret: Boolean = false, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        visualTransformation = if (secret) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = type),
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    )
}

@Composable
fun ActivityLogScreen(padding: PaddingValues, miniPlayerSpace: Dp) {
    val entries by ActivityLog.entries.collectAsState()
    val clipboard = LocalClipboardManager.current
    val formatter = remember { SimpleDateFormat("HH:mm:ss", Locale.getDefault()) }
    Column(Modifier.fillMaxSize()) {
        TopBar("Activity log", onBack = { App.back() }) {
            IconButton(onClick = {
                clipboard.setText(AnnotatedString(entries.joinToString("\n") { "${formatter.format(Date(it.time))}  ${it.message}" }))
            }) { Icon(KIcons.Copy, contentDescription = "Copy") }
            TextButton(onClick = { ActivityLog.clear() }) { Text("Clear") }
        }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = padding.calculateBottomPadding() + miniPlayerSpace)) {
            if (entries.isEmpty()) {
                item {
                    Text(
                        "Nothing yet. Open a stream: ad breaks and how they were handled show up here.",
                        color = Secondary, modifier = Modifier.padding(16.dp),
                    )
                }
            }
            items(entries.asReversed()) { entry ->
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
                    Text(formatter.format(Date(entry.time)), fontSize = 12.sp, color = Secondary, fontFamily = FontFamily.Monospace)
                    Text(entry.message, fontSize = 13.sp)
                }
            }
        }
    }
}

@Composable
fun BusyOverlay(text: String) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.5f)).clickable(enabled = true) {}, contentAlignment = Alignment.Center) {
        Column(
            Modifier.background(Surface2, androidx.compose.foundation.shape.RoundedCornerShape(12.dp)).padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            CircularProgressIndicator(color = AccentTeal)
            Spacer(Modifier.height(10.dp))
            Text(text)
        }
    }
}
