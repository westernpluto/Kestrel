package app.kestrel.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.kestrel.core.Category
import app.kestrel.core.Channel
import app.kestrel.core.Format
import app.kestrel.core.LiveStream
import app.kestrel.core.TwitchApi
import app.kestrel.data.FavoritesStore
import app.kestrel.data.FollowingStore
import app.kestrel.data.TwitchAccount
import app.kestrel.player.PlaybackTarget
import coil.compose.AsyncImage
import kotlinx.coroutines.launch

/** A picture from the web, with a dark placeholder while it loads. */
@Composable
fun RemoteImage(url: String?, modifier: Modifier = Modifier, contentScale: ContentScale = ContentScale.Crop) {
    Box(modifier.background(Surface2)) {
        if (url != null) {
            AsyncImage(model = url, contentDescription = null, contentScale = contentScale, modifier = Modifier.fillMaxSize())
        }
    }
}

@Composable
fun Avatar(url: String?, size: Dp) {
    RemoteImage(TwitchApi.image(url, 150, 150) ?: url, Modifier.size(size).clip(CircleShape))
}

/** A title bar: the back arrow on pages, actions on the right. */
@Composable
fun TopBar(title: String, onBack: (() -> Unit)? = null, actions: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().background(Color.Black).statusBarsPadding().height(56.dp).padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onBack != null) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
        } else {
            Spacer(Modifier.width(12.dp))
        }
        Text(
            title, fontSize = if (onBack == null) 24.sp else 18.sp, fontWeight = FontWeight.Bold,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
        )
        actions()
    }
}

/** A light press effect. */
@Composable
fun Modifier.pressable(
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    scaleTo: Float = 0.97f,
): Modifier {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) scaleTo else 1f, spring(stiffness = 600f), label = "press")
    return this
        .graphicsLayer {
            scaleX = scale
            scaleY = scale
            alpha = if (pressed) 0.85f else 1f
        }
        .combinedClickable(interactionSource = interaction, indication = null, onClick = onClick, onLongClick = onLongClick)
}

@Composable
fun ViewerPill(viewers: Int) {
    Row(
        Modifier.background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(3.dp)).padding(horizontal = 5.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(6.dp).background(LiveRed, CircleShape))
        Spacer(Modifier.width(3.dp))
        Text(Format.viewers(viewers), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
    }
}

@Composable
fun LiveBadge(viewers: Int?) {
    Row(
        Modifier.background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(7.dp).background(LiveRed, CircleShape))
        Spacer(Modifier.width(4.dp))
        Text(viewers?.let { Format.viewers(it) } ?: "LIVE", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color.White)
    }
}

@Composable
fun TagChip(text: String) {
    Text(
        text, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFFD1D1D6), maxLines = 1,
        modifier = Modifier.background(Color(0xFF2B2B30), RoundedCornerShape(50)).padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

/** One line of chips: as many as fit, the rest left out (never a chip cut in half). */
@Composable
fun ChipRow(spacing: Dp = 4.dp, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Layout(content = content, modifier = modifier) { measurables, constraints ->
        val gap = spacing.roundToPx()
        val placeables = measurables.map { it.measure(Constraints()) }
        val placed = mutableListOf<Pair<Placeable, Int>>()
        var x = 0
        for (placeable in placeables) {
            if (x + placeable.width > constraints.maxWidth) break
            placed.add(placeable to x)
            x += placeable.width + gap
        }
        val width = if (placed.isEmpty()) 0 else (x - gap).coerceIn(constraints.minWidth, constraints.maxWidth)
        val height = placed.maxOfOrNull { it.first.height } ?: 0
        layout(width, height) { placed.forEach { (placeable, px) -> placeable.placeRelative(px, 0) } }
    }
}

/**
 * A live stream as a compact row, like Twitch's lists: the picture on the left, who and what on the
 * right, with tags. The whole row is one tile that opens the stream (hold it for the channel or category).
 */
@Composable
fun StreamRow(stream: LiveStream, showCategory: Boolean = true, modifier: Modifier = Modifier) {
    var menu by remember { mutableStateOf(false) }
    Box(modifier) {
        Row(
            Modifier.fillMaxWidth()
                .pressable(onClick = { App.play(PlaybackTarget.Live(stream.channel, stream)) }, onLongClick = { menu = true })
                .padding(horizontal = 16.dp, vertical = 7.dp),
        ) {
            Box(Modifier.width(156.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(8.dp))) {
                RemoteImage(TwitchApi.image(stream.previewImageURL, 440, 248), Modifier.fillMaxSize())
                Box(Modifier.align(Alignment.BottomStart).padding(5.dp)) { ViewerPill(stream.viewers) }
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Avatar(stream.channel.profileImageURL, 20.dp)
                    Spacer(Modifier.width(6.dp))
                    Text(stream.channel.name, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Text(
                    stream.title.ifEmpty { stream.channel.name }, fontSize = 13.sp, color = Secondary, maxLines = 2,
                    overflow = TextOverflow.Ellipsis, lineHeight = 17.sp,
                )
                val category = stream.category
                if (showCategory && category != null) {
                    Text(category.name, fontSize = 13.sp, color = AccentTeal, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (stream.tags.isNotEmpty()) {
                    ChipRow(modifier = Modifier.padding(top = 2.dp)) { stream.tags.forEach { TagChip(it) } }
                }
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Watch") }, onClick = {
                menu = false
                App.play(PlaybackTarget.Live(stream.channel, stream))
            })
            DropdownMenuItem(text = { Text("Open channel") }, onClick = {
                menu = false
                App.push(Route.ChannelPage(stream.channel))
            })
            stream.category?.let { category ->
                DropdownMenuItem(text = { Text(category.name) }, onClick = {
                    menu = false
                    App.push(Route.CategoryPage(category))
                })
            }
        }
    }
}

/** The channel page's "Live now": one tile (picture and text) that opens the stream. */
@Composable
fun StreamCard(stream: LiveStream) {
    Column(Modifier.fillMaxWidth().pressable(onClick = { App.play(PlaybackTarget.Live(stream.channel, stream)) }, scaleTo = 0.98f)) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(10.dp))) {
            RemoteImage(TwitchApi.image(stream.previewImageURL, 640, 360), Modifier.fillMaxSize())
            Box(Modifier.align(Alignment.TopStart).padding(8.dp)) { LiveBadge(stream.viewers) }
            Format.uptime(stream.startedAt)?.let { uptime ->
                Text(
                    uptime, fontSize = 11.sp, color = Color.White,
                    modifier = Modifier.align(Alignment.BottomEnd).padding(8.dp)
                        .background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(4.dp)).padding(horizontal = 5.dp, vertical = 2.dp),
                )
            }
            Icon(Icons.Filled.PlayArrow, contentDescription = "Watch", tint = Color.White, modifier = Modifier.align(Alignment.Center).size(48.dp))
        }
        Spacer(Modifier.height(8.dp))
        Text(stream.title.ifEmpty { stream.channel.name }, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
        stream.category?.let { Text(it.name, fontSize = 13.sp, color = AccentTeal) }
        if (stream.tags.isNotEmpty()) ChipRow(modifier = Modifier.padding(top = 4.dp)) { stream.tags.forEach { TagChip(it) } }
    }
}

@Composable
fun ChannelRow(channel: Channel, subtitle: String? = null, liveViewers: Int? = null, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Box {
            Avatar(channel.profileImageURL, 44.dp)
            if (liveViewers != null) {
                Box(
                    Modifier.align(Alignment.BottomEnd).size(13.dp).background(Color.Black, CircleShape).padding(2.dp)
                        .background(LiveRed, CircleShape),
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(channel.name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (subtitle != null) Text(subtitle, fontSize = 13.sp, color = Secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (liveViewers != null) LiveBadge(liveViewers)
    }
}

@Composable
fun CategoryTile(category: Category, modifier: Modifier = Modifier) {
    Column(modifier) {
        RemoteImage(
            TwitchApi.image(category.boxArtURL, 285, 380),
            Modifier.fillMaxWidth().aspectRatio(285f / 380f).clip(RoundedCornerShape(8.dp)),
        )
        Spacer(Modifier.height(4.dp))
        Text(category.name, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (category.viewers > 0) Text("${Format.viewers(category.viewers)} watching", fontSize = 11.sp, color = Secondary, maxLines = 1)
    }
}

@Composable
fun ErrorBanner(message: String, retry: (() -> Unit)? = null) {
    Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(Icons.Filled.Warning, contentDescription = null, tint = Color(0xFFFF9F0A), modifier = Modifier.size(28.dp))
        Spacer(Modifier.height(10.dp))
        Text(message, fontSize = 13.sp, color = Secondary, textAlign = TextAlign.Center)
        if (retry != null) {
            Spacer(Modifier.height(10.dp))
            OutlinedButton(onClick = retry) { Text("Try again") }
        }
    }
}

@Composable
fun EmptyState(title: String, message: String, icon: androidx.compose.ui.graphics.vector.ImageVector? = null) {
    Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = Secondary, modifier = Modifier.size(40.dp))
            Spacer(Modifier.height(10.dp))
        }
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(message, fontSize = 14.sp, color = Secondary, textAlign = TextAlign.Center)
    }
}

@Composable
fun LoadingRow() {
    Box(Modifier.fillMaxWidth().padding(20.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.5.dp)
    }
}

/** Room at the bottom of lists for the mini player. */
fun listPadding(base: PaddingValues, bottomExtra: Dp): PaddingValues =
    PaddingValues(top = 0.dp, bottom = base.calculateBottomPadding() + bottomExtra)

/**
 * The heart: follows on Twitch when signed in (kept in sync with the account), otherwise adds the
 * channel to Kestrel's own Following list.
 */
@Composable
fun FollowButton(channel: Channel, tint: Color = Color.White, size: Dp = 26.dp) {
    val scope = rememberCoroutineScope()
    var confirming by remember { mutableStateOf(false) }
    val onTwitch = FollowingStore.twitchFollowIds.contains(channel.id)
    val hearted = onTwitch || FavoritesStore.channels.any { it.id == channel.id }
    val scale by animateFloatAsState(if (hearted) 1.1f else 1f, spring(dampingRatio = 0.5f), label = "heart")
    IconButton(onClick = {
        when {
            TwitchAccount.session == null -> FavoritesStore.toggle(channel)
            hearted -> confirming = true
            else -> scope.launch { FollowingStore.setFollowed(channel, true) }
        }
    }) {
        Icon(
            if (hearted) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
            contentDescription = if (hearted) "Unfollow" else "Follow",
            tint = if (hearted) LiveRed else tint,
            modifier = Modifier.size(size).scale(scale),
        )
    }
    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text("Unfollow ${channel.name}?") },
            confirmButton = {
                TextButton(onClick = {
                    confirming = false
                    if (onTwitch) {
                        scope.launch { FollowingStore.setFollowed(channel, false) }
                    } else if (FavoritesStore.contains(channel)) {
                        FavoritesStore.toggle(channel)
                    }
                }) { Text("Unfollow", color = LiveRed) }
            },
            dismissButton = { TextButton(onClick = { confirming = false }) { Text("Cancel") } },
        )
    }
}

/** A tappable row for settings-style lists. */
@Composable
fun SectionHeader(text: String) {
    Text(
        text.uppercase(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Secondary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 6.dp),
    )
}

@Composable
fun SectionFooter(text: String) {
    Text(text, fontSize = 12.sp, color = Tertiary, lineHeight = 16.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
}

@Composable
fun SettingRow(
    title: String,
    subtitle: String? = null,
    value: String? = null,
    titleColor: Color = Color.White,
    onClick: (() -> Unit)? = null,
    trailing: @Composable (() -> Unit)? = null,
) {
    Row(
        Modifier.fillMaxWidth().background(Surface1)
            .let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 16.sp, color = titleColor)
            if (subtitle != null) Text(subtitle, fontSize = 12.sp, color = Secondary, lineHeight = 16.sp)
        }
        if (value != null) Text(value, fontSize = 15.sp, color = Secondary)
        if (trailing != null) {
            Spacer(Modifier.width(8.dp))
            trailing()
        }
    }
}
