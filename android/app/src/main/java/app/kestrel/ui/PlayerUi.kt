package app.kestrel.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.res.Configuration
import android.util.LruCache
import android.view.ViewGroup
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.graphics.drawable.toBitmap
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import app.kestrel.chat.ChatController
import app.kestrel.core.AdState
import app.kestrel.core.Format
import app.kestrel.core.Storyboard
import app.kestrel.data.AppSettings
import app.kestrel.player.KestrelPlayer
import app.kestrel.player.PlaybackTarget
import app.kestrel.player.PlayerController
import coil.imageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

fun Context.findActivity(): Activity? {
    var context: Context? = this
    while (context is ContextWrapper) {
        if (context is Activity) return context
        context = context.baseContext
    }
    return null
}

/** The mini player's size for a screen of this width. */
fun miniPlayerSize(screenWidth: Dp, landscape: Boolean): DpSize {
    val width = if (landscape) min(screenWidth.value * 0.3f, 260f) else min(screenWidth.value * 0.52f, 240f)
    return DpSize(width.dp, (width * 9f / 16f).dp)
}

/** Room the screens keep free at the bottom for the mini player. */
@Composable
fun miniPlayerSpace(): Dp {
    if (App.player == null || !App.minimized) return 0.dp
    val configuration = LocalConfiguration.current
    val landscape = configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
    return miniPlayerSize(configuration.screenWidthDp.dp, landscape).height + 24.dp
}

/** Hides the status and navigation bars (full screen), showing them again afterwards. */
@Composable
private fun SystemBarsEffect(hidden: Boolean) {
    val view = LocalView.current
    DisposableEffect(hidden) {
        val window = view.context.findActivity()?.window
        if (window != null) {
            val controller = WindowCompat.getInsetsController(window, view)
            if (hidden) {
                controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsetsCompat.Type.systemBars())
            } else {
                controller.show(WindowInsetsCompat.Type.systemBars())
            }
        }
        onDispose {
            if (window != null) WindowCompat.getInsetsController(window, view).show(WindowInsetsCompat.Type.systemBars())
        }
    }
}

/** Chat follows playback: VOD replay, and what was said at that point while rewinding a live stream. */
@Composable
private fun ChatSync(controller: PlayerController, chat: ChatController?) {
    if (chat == null) return
    LaunchedEffect(controller, chat) {
        snapshotFlow { Triple(controller.isRewinding, controller.rewindPosition, controller.position) }.collect { (rewinding, rewindPosition, position) ->
            when {
                chat.isReplay -> chat.replay(position)
                rewinding -> {
                    val videoId = controller.rewind?.videoID ?: return@collect
                    if (!chat.rewindReplay) chat.startRewindReplay(videoId, rewindPosition) else chat.replay(rewindPosition)
                }
                chat.rewindReplay -> chat.endRewindReplay()
            }
        }
    }
}

private data class Frame(val x: Float, val y: Float, val w: Float, val h: Float) {
    fun lerp(to: Frame, t: Float) = Frame(x + (to.x - x) * t, y + (to.y - y) * t, w + (to.w - w) * t, h + (to.h - h) * t)
}

/**
 * The player: full screen (portrait: video, details and chat; landscape: video with chat beside
 * it), or the mini player above the tab bar. One video view for both, moved and resized between
 * them, so shrinking and opening never restart the picture.
 */
@Composable
fun PlayerHost(controller: PlayerController, chat: ChatController?) {
    val configuration = LocalConfiguration.current
    val landscape = configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
    val pip = App.inPictureInPicture
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current

    ChatSync(controller, chat)

    val progress = remember { Animatable(if (App.minimized) 1f else 0f) }
    LaunchedEffect(App.minimized) {
        if (App.minimized) {
            focusManager.clearFocus()
            keyboard?.hide()
        }
        progress.animateTo(if (App.minimized) 1f else 0f, spring(dampingRatio = 0.86f, stiffness = 420f))
    }
    var chatOpen by remember { mutableStateOf(true) }
    var chatFraction by remember { mutableFloatStateOf(0.32f) }
    var controlsVisible by remember { mutableStateOf(true) }
    var controlsUntil by remember { mutableLongStateOf(System.currentTimeMillis() + 3500) }
    var menuOpen by remember { mutableStateOf(false) }
    var scrubbing by remember { mutableStateOf(false) }
    var miniDragX by remember { mutableFloatStateOf(0f) }

    fun showControls(seconds: Long = 3500) {
        controlsVisible = true
        controlsUntil = System.currentTimeMillis() + seconds
    }
    LaunchedEffect(controlsVisible, controlsUntil, scrubbing, menuOpen, controller.isPaused) {
        if (!controlsVisible || scrubbing || menuOpen || controller.isPaused) return@LaunchedEffect
        delay(max(0L, controlsUntil - System.currentTimeMillis()))
        controlsVisible = false
    }

    SystemBarsEffect(hidden = landscape && !App.minimized && !pip)
    BackHandler(enabled = !App.minimized && !pip) {
        if (landscape) App.requestOrientation(false) else App.minimized = true
    }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = constraints.maxWidth.toFloat()
        val height = constraints.maxHeight.toFloat()
        val statusTop = WindowInsets.statusBars.getTop(density).toFloat()
        val navBottom = WindowInsets.navigationBars.getBottom(density).toFloat()
        val cutoutLeft = WindowInsets.displayCutout.getLeft(density, LayoutDirection.Ltr).toFloat()
        val cutoutRight = WindowInsets.displayCutout.getRight(density, LayoutDirection.Ltr).toFloat()
        val chatOnLeft = landscape && cutoutRight > cutoutLeft
        val sideChat = landscape && chatOpen && chat != null && !pip
        val chatWidth = if (sideChat) width * chatFraction else 0f

        val expanded: Frame = when {
            pip -> Frame(0f, 0f, width, height)
            landscape -> {
                var x = if (chatOnLeft) chatWidth else 0f
                var w = width - chatWidth
                // Keep the video clear of the camera cutout.
                if (!chatOnLeft && cutoutLeft > 0) {
                    x += cutoutLeft
                    w -= cutoutLeft
                }
                if (chatOnLeft && cutoutRight > 0) w -= cutoutRight
                Frame(x, 0f, w, height)
            }
            else -> Frame(0f, statusTop, width, width * 9f / 16f)
        }
        val miniSize = miniPlayerSize(with(density) { width.toDp() }, landscape)
        val miniW = with(density) { miniSize.width.toPx() }
        val miniH = with(density) { miniSize.height.toPx() }
        val margin = with(density) { 12.dp.toPx() }
        val navArea = with(density) { 80.dp.toPx() } + navBottom
        val mini = Frame(width - miniW - margin - cutoutRight, height - navArea - miniH - margin, miniW, miniH)
        val travel = max(1f, mini.y - expanded.y)
        val p = if (pip) 0f else progress.value.coerceIn(0f, 1f)
        val frame = expanded.lerp(mini, p)
        val minimizedNow = App.minimized && !pip

        // Behind the video: details and chat (full screen only).
        if (p < 0.999f && !pip) {
            Box(
                Modifier.fillMaxSize()
                    .graphicsLayer { alpha = 1f - p }
                    .background(Color.Black)
                    .pointerInput(Unit) { detectTapGestures { focusManager.clearFocus() } },
            ) {
                if (landscape) {
                    if (sideChat && chat != null) {
                        val chatWidthDp = with(density) { chatWidth.toDp() }
                        Row(Modifier.fillMaxHeight().width(chatWidthDp).align(if (chatOnLeft) Alignment.CenterStart else Alignment.CenterEnd)) {
                            if (!chatOnLeft) ResizeHandle { delta -> chatFraction = (chatFraction - delta / width).coerceIn(0.22f, 0.5f) }
                            ChatPanel(
                                chat, active = !App.minimized, compact = true,
                                modifier = Modifier.weight(1f).fillMaxHeight().background(Color(0xFF0B0B0D)).imePadding()
                                    .padding(top = with(density) { statusTop.toDp() }),
                            )
                            if (chatOnLeft) ResizeHandle { delta -> chatFraction = (chatFraction + delta / width).coerceIn(0.22f, 0.5f) }
                        }
                    }
                } else {
                    Column(Modifier.fillMaxSize().navigationBarsPadding().imePadding()) {
                        Spacer(Modifier.height(with(density) { (statusTop + width * 9f / 16f).toDp() }))
                        StreamInfoBar(controller)
                        if (chat != null) {
                            ChatPanel(chat, active = !App.minimized, compact = false, modifier = Modifier.weight(1f).fillMaxWidth())
                        } else {
                            Spacer(Modifier.weight(1f))
                        }
                    }
                }
            }
        }

        // The video.
        val frameWidth = with(density) { frame.w.toDp() }
        val frameHeight = with(density) { frame.h.toDp() }
        val currentMinimized by rememberUpdatedState(minimizedNow)
        Box(
            Modifier
                .offset { IntOffset((frame.x + if (minimizedNow) miniDragX else 0f).roundToInt(), frame.y.roundToInt()) }
                .size(frameWidth, frameHeight)
                .graphicsLayer { alpha = if (minimizedNow) (1f - abs(miniDragX) / (miniW * 1.5f)).coerceIn(0.2f, 1f) else 1f }
                .clip(RoundedCornerShape(if (p > 0.05f) (10 * p).dp else 0.dp))
                .background(Color.Black)
                .pointerInput(minimizedNow, landscape, travel, chatOnLeft) {
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        var axis = 0 // 1 vertical, 2 horizontal, 3 pinch, -1 handled by a control
                        var total = Offset.Zero
                        var zoom = 1f
                        val start = progress.value
                        while (true) {
                            val event = awaitPointerEvent()
                            val pressed = event.changes.filter { it.pressed }
                            if (pressed.isEmpty()) break
                            if (axis == -1) continue
                            if (pressed.size >= 2 && (axis == 0 || axis == 3) && !minimizedNow && !pip) {
                                axis = 3
                                zoom *= event.calculateZoom()
                                event.changes.forEach { it.consume() }
                                continue
                            }
                            if (axis == 3) continue
                            val change = pressed.first()
                            if (axis == 0 && change.isConsumed) {
                                axis = -1
                                continue
                            }
                            total += change.positionChange()
                            if (axis == 0 && total.getDistance() > viewConfiguration.touchSlop) {
                                axis = if (abs(total.y) >= abs(total.x)) 1 else 2
                            }
                            if (axis == 1 || axis == 2) {
                                change.consume()
                                if (pip) continue
                                if (minimizedNow) {
                                    if (axis == 1) {
                                        val value = (start + total.y / travel).coerceIn(0f, 1f)
                                        scope.launch { progress.snapTo(value) }
                                    } else {
                                        miniDragX = total.x
                                    }
                                } else if (!landscape && axis == 1 && total.y > 0) {
                                    val value = (start + total.y / travel).coerceIn(0f, 1f)
                                    scope.launch { progress.snapTo(value) }
                                }
                            }
                        }
                        if (pip) return@awaitEachGesture
                        val threshold = 60.dp.toPx()
                        when (axis) {
                            3 -> if (zoom > 1.15f) controller.fillsScreen = true else if (zoom < 0.87f) controller.fillsScreen = false
                            1 -> if (minimizedNow) {
                                val value = progress.value
                                if (value < 0.75f) {
                                    App.minimized = false
                                } else {
                                    scope.launch { progress.animateTo(1f, spring(dampingRatio = 0.86f, stiffness = 420f)) }
                                }
                            } else if (landscape) {
                                if (total.y > threshold) App.requestOrientation(false)
                            } else if (total.y < -threshold) {
                                // Swipe up: full screen.
                                App.requestOrientation(true)
                            } else {
                                val value = progress.value
                                if (value > 0.22f) {
                                    App.minimized = true
                                } else {
                                    scope.launch { progress.animateTo(0f, spring(dampingRatio = 0.86f, stiffness = 420f)) }
                                }
                            }
                            2 -> if (minimizedNow) {
                                // Thrown aside: close.
                                if (abs(total.x) > miniW * 0.45f) App.closePlayer() else miniDragX = 0f
                            } else if (landscape && chat != null) {
                                val towardChat = if (chatOnLeft) total.x > threshold else total.x < -threshold
                                val awayFromChat = if (chatOnLeft) total.x < -threshold else total.x > threshold
                                if (towardChat) chatOpen = true else if (awayFromChat) chatOpen = false
                            }
                            else -> Unit
                        }
                    }
                }
                .pointerInput(minimizedNow, landscape, pip) {
                    detectTapGestures(
                        onTap = {
                            if (pip) return@detectTapGestures
                            if (currentMinimized) {
                                App.minimized = false
                            } else {
                                focusManager.clearFocus()
                                if (controlsVisible) controlsVisible = false else showControls()
                            }
                        },
                        onDoubleTap = if (minimizedNow || pip) {
                            null
                        } else {
                            {
                                if (landscape) controller.fillsScreen = !controller.fillsScreen else App.requestOrientation(true)
                            }
                        },
                    )
                },
        ) {
            VideoSurface(controller.fillsScreen)
            if (controller.coveringAd) AdCover()
            PlaybackStatus(controller, compact = minimizedNow || pip)
            if (!minimizedNow && !pip) {
                if (AppSettings.showVideoStats && controller.stats.isNotEmpty() && !scrubbing) StatsOverlay(controller.stats)
                val visible = controlsVisible || controller.phase != PlayerController.Phase.Playing
                AnimatedVisibility(visible && p < 0.5f, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.fillMaxSize()) {
                    PlayerControls(
                        controller = controller,
                        landscape = landscape,
                        chatOpen = chatOpen,
                        hasChat = chat != null,
                        scrubbing = scrubbing,
                        onScrubbing = {
                            scrubbing = it
                            showControls(if (it) 60_000 else 4000)
                        },
                        onInteract = { showControls() },
                        onToggleChat = { chatOpen = !chatOpen },
                        onMenu = {
                            menuOpen = true
                            showControls(12_000)
                        },
                    )
                }
                ResumeBanner(controller)
            }
            if (minimizedNow && p > 0.6f) MiniControls(controller)
        }

        if (menuOpen) PlayerMenu(controller) { menuOpen = false }
    }
}

@Composable
private fun VideoSurface(fill: Boolean) {
    AndroidView(
        factory = { context ->
            PlayerView(context).apply {
                useController = false
                setKeepContentOnPlayerReset(true)
                setShutterBackgroundColor(android.graphics.Color.BLACK)
                setBackgroundColor(android.graphics.Color.BLACK)
                resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                player = KestrelPlayer.player
            }
        },
        update = { view ->
            view.resizeMode = if (fill) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
            if (view.player !== KestrelPlayer.player) view.player = KestrelPlayer.player
        },
        onRelease = { view -> view.player = null },
        modifier = Modifier.fillMaxSize(),
    )
}

@Composable
private fun ResizeHandle(onDrag: (Float) -> Unit) {
    Box(
        Modifier.fillMaxHeight().width(14.dp).pointerInput(Unit) {
            detectHorizontalDragGestures { change, dragAmount ->
                change.consume()
                onDrag(dragAmount)
            }
        },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.width(3.dp).height(36.dp).background(Color.White.copy(alpha = 0.25f), RoundedCornerShape(2.dp)))
    }
}

@Composable
private fun AdCover() {
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(KIcons.Shield, contentDescription = null, tint = AccentTeal, modifier = Modifier.size(28.dp))
            Spacer(Modifier.height(6.dp))
            Text("Ad hidden", fontWeight = FontWeight.SemiBold)
            Text("The stream comes back after the break", fontSize = 12.sp, color = Secondary)
        }
    }
}

@Composable
private fun PlaybackStatus(controller: PlayerController, compact: Boolean) {
    when (val phase = controller.phase) {
        PlayerController.Phase.Offline -> Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(KIcons.Moon, contentDescription = null, tint = Secondary, modifier = Modifier.size(if (compact) 22.dp else 32.dp))
                Spacer(Modifier.height(6.dp))
                Text("This channel is offline", fontSize = if (compact) 12.sp else 15.sp, fontWeight = FontWeight.SemiBold)
                if (!compact) {
                    Spacer(Modifier.height(10.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        controller.channel?.let { channel -> OutlinedButton(onClick = { App.openChannel(channel) }) { Text("Channel") } }
                        OutlinedButton(onClick = { App.closePlayer() }) { Text("Close") }
                    }
                }
            }
        }
        is PlayerController.Phase.Failed -> Box(Modifier.fillMaxSize().background(Color.Black).padding(16.dp), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(phase.message, fontSize = if (compact) 11.sp else 14.sp, color = Secondary, maxLines = if (compact) 2 else 4, overflow = TextOverflow.Ellipsis)
                if (!compact) {
                    Spacer(Modifier.height(10.dp))
                    OutlinedButton(onClick = { controller.retry() }) { Text("Try again") }
                }
            }
        }
        else -> if (controller.isBuffering && !controller.coveringAd) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Color.White, strokeWidth = 2.5.dp, modifier = Modifier.size(if (compact) 24.dp else 40.dp))
            }
        }
    }
}

@Composable
private fun RoundIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, size: Dp = 40.dp, onClick: () -> Unit) {
    IconButton(onClick = onClick, modifier = Modifier.size(size)) {
        Icon(icon, contentDescription = description, tint = Color.White, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun PlayerControls(
    controller: PlayerController,
    landscape: Boolean,
    chatOpen: Boolean,
    hasChat: Boolean,
    scrubbing: Boolean,
    onScrubbing: (Boolean) -> Unit,
    onInteract: () -> Unit,
    onToggleChat: () -> Unit,
    onMenu: () -> Unit,
) {
    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0f to Color.Black.copy(alpha = 0.6f), 0.35f to Color.Transparent, 0.6f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.72f),
                ),
            ),
        )
        // Top bar.
        AnimatedVisibility(!scrubbing, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.align(Alignment.TopStart).fillMaxWidth()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                RoundIcon(Icons.Filled.KeyboardArrowDown, if (landscape) "Exit full screen" else "Minimize") {
                    if (landscape) App.requestOrientation(false) else App.minimized = true
                }
                if (landscape) {
                    Column(Modifier.weight(1f).padding(start = 4.dp)) {
                        Text(controller.channel?.name ?: "", fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                        val title = titleOf(controller)
                        if (title.isNotEmpty()) Text(title, fontSize = 12.sp, color = Color.White.copy(alpha = 0.75f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                } else {
                    Spacer(Modifier.weight(1f))
                }
                RoundIcon(KIcons.PictureInPicture, "Picture in picture") {
                    (App.requestPictureInPicture)()
                }
                RoundIcon(KIcons.Gear, "Settings", onClick = onMenu)
            }
        }
        // Play / pause, with ten-second skips beside it in VODs and while rewinding.
        if (controller.phase == PlayerController.Phase.Playing && !controller.coveringAd && !scrubbing) {
            val skips = controller.canSkipBack || controller.canSkipForward
            Row(
                Modifier.align(Alignment.Center),
                horizontalArrangement = Arrangement.spacedBy(if (landscape) 40.dp else 26.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (skips) {
                    SkipButton(back = true, enabled = controller.canSkipBack) {
                        controller.skip(-10.0)
                        onInteract()
                    }
                }
                Box(
                    Modifier.size(64.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.35f))
                        .clickable {
                            controller.togglePause()
                            onInteract()
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (controller.isPaused) Icons.Filled.PlayArrow else KIcons.Pause,
                        contentDescription = if (controller.isPaused) "Play" else "Pause",
                        tint = Color.White,
                        modifier = Modifier.size(if (landscape) 38.dp else 32.dp),
                    )
                }
                if (skips) {
                    // Kept in place (invisible) when there's nowhere to go, so pause stays centred.
                    SkipButton(back = false, enabled = controller.canSkipForward) {
                        controller.skip(10.0)
                        onInteract()
                    }
                }
            }
        }
        // Bottom bar.
        Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(horizontal = 8.dp)) {
            SeekArea(controller, onScrubbing, onInteract)
            Row(Modifier.fillMaxWidth().height(40.dp), verticalAlignment = Alignment.CenterVertically) {
                if (controller.isLive) {
                    LiveButton(controller) {
                        controller.goLive()
                        onInteract()
                    }
                    controller.stream?.viewers?.let { viewers ->
                        Spacer(Modifier.width(10.dp))
                        Box(Modifier.size(6.dp).background(LiveRed, CircleShape))
                        Spacer(Modifier.width(4.dp))
                        Text(Format.viewers(viewers), fontSize = 12.sp, color = Color.White.copy(alpha = 0.85f))
                    }
                    AdBadge(controller.adState)
                } else if (controller.duration > 0) {
                    Text(
                        "${Format.duration(controller.position.toLong())} / ${Format.duration(controller.duration.toLong())}",
                        fontSize = 12.sp, fontFamily = FontFamily.Monospace,
                    )
                    if (controller.vodIsRecording) {
                        Spacer(Modifier.width(8.dp))
                        Text(
                            "RECORDING", fontSize = 10.sp, fontWeight = FontWeight.Black,
                            modifier = Modifier.background(LiveRed.copy(alpha = 0.85f), RoundedCornerShape(4.dp)).padding(horizontal = 5.dp, vertical = 2.dp),
                        )
                    }
                }
                Spacer(Modifier.weight(1f))
                if (landscape && hasChat) {
                    RoundIcon(if (chatOpen) KIcons.Chat else KIcons.ChatOutline, if (chatOpen) "Hide chat" else "Show chat") {
                        onToggleChat()
                        onInteract()
                    }
                }
                RoundIcon(if (landscape) KIcons.FullscreenExit else KIcons.Fullscreen, if (landscape) "Exit full screen" else "Full screen") {
                    App.requestOrientation(!landscape)
                    onInteract()
                }
            }
        }
    }
}

private fun titleOf(controller: PlayerController): String = when (val target = controller.target) {
    is PlaybackTarget.Live -> controller.stream?.title ?: target.stream?.title ?: ""
    is PlaybackTarget.Vod -> target.video.title
}

@Composable
private fun LiveButton(controller: PlayerController, onClick: () -> Unit) {
    val atLiveEdge = !controller.isRewinding && (controller.latency ?: 0.0) < (if (AppSettings.lowLatency) 7.0 else 15.0)
    Row(Modifier.clip(RoundedCornerShape(6.dp)).clickable(onClick = onClick).padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(
            "LIVE", fontSize = 12.sp, fontWeight = FontWeight.Black,
            modifier = Modifier.background(if (atLiveEdge) LiveRed else Color.Gray, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 2.dp),
        )
        Spacer(Modifier.width(6.dp))
        if (controller.isRewinding) {
            // Where you are in the broadcast.
            Text(
                "${Format.duration(controller.rewindPosition.toLong())} / ${Format.duration(controller.broadcastElapsed.toLong())}",
                fontSize = 12.sp, fontFamily = FontFamily.Monospace, color = Color.White.copy(alpha = 0.85f),
            )
        } else {
            controller.latency?.let { latency ->
                Text(String.format(Locale.US, "%.1fs", latency), fontSize = 12.sp, fontFamily = FontFamily.Monospace, color = Color.White.copy(alpha = 0.85f))
            }
        }
    }
}

@Composable
private fun AdBadge(state: AdState) {
    val (text, color) = when (state) {
        AdState.Skipped, is AdState.Replaced -> "Ad blocked" to AccentTeal
        AdState.Searching, AdState.Covering -> "Ad" to Color(0xFFFF9F0A)
        AdState.None -> return
    }
    Spacer(Modifier.width(10.dp))
    Icon(KIcons.Shield, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
    Spacer(Modifier.width(3.dp))
    Text(text, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = color)
}

/** VODs: the whole video. Live: from the start of the broadcast to now, when it can be rewound. */
@Composable
private fun SeekArea(controller: PlayerController, onScrubbing: (Boolean) -> Unit, onInteract: () -> Unit) {
    val rewind = controller.rewind
    if (controller.isLive && rewind != null && controller.broadcastElapsed > 60) {
        SeekBar(
            position = if (controller.isRewinding) controller.rewindPosition else controller.broadcastElapsed,
            duration = controller.broadcastElapsed,
            storyboard = controller.storyboard,
            label = { time -> if (controller.broadcastElapsed - time < 20) "Live" else Format.duration(time.toLong()) },
            onStart = {
                onScrubbing(true)
                controller.refreshStoryboardIfStale()
            },
            onScrub = { onInteract() },
            onCommit = {
                onScrubbing(false)
                controller.seekBroadcast(it)
            },
        )
    } else if (!controller.isLive && controller.duration > 0) {
        SeekBar(
            position = controller.position,
            duration = controller.duration,
            storyboard = controller.storyboard,
            label = { Format.duration(it.toLong()) },
            onStart = {
                onScrubbing(true)
                controller.refreshStoryboardIfStale()
            },
            onScrub = { onInteract() },
            onCommit = {
                onScrubbing(false)
                controller.seek(it)
            },
        )
    }
}

/** A Twitch-style seek bar: thin until touched, with a thumbnail of where you'd land. */
@Composable
private fun SeekBar(
    position: Double,
    duration: Double,
    storyboard: Storyboard?,
    label: (Double) -> String,
    onStart: () -> Unit,
    onScrub: (Double) -> Unit,
    onCommit: (Double) -> Unit,
) {
    var dragTime by remember { mutableStateOf<Double?>(null) }
    // Where the thumb was let go, held until playback gets there (so it doesn't jump back).
    var landedTime by remember { mutableStateOf<Double?>(null) }
    val start by rememberUpdatedState(onStart)
    val scrub by rememberUpdatedState(onScrub)
    val commit by rememberUpdatedState(onCommit)
    val currentDuration by rememberUpdatedState(duration)
    LaunchedEffect(position) {
        val landed = landedTime
        if (landed != null && abs(position - landed) < 3) landedTime = null
    }
    LaunchedEffect(landedTime) {
        if (landedTime != null) {
            delay(2500)
            landedTime = null
        }
    }
    val shown = dragTime ?: landedTime ?: position
    val fraction = if (duration > 0) (shown / duration).coerceIn(0.0, 1.0).toFloat() else 0f
    val active = dragTime != null
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxWidth().height(36.dp)) {
        val widthPx = constraints.maxWidth.toFloat()
        Canvas(
            Modifier.fillMaxSize().pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    down.consume()
                    fun timeAt(x: Float): Double = (x / size.width).coerceIn(0f, 1f) * currentDuration
                    start()
                    var time = timeAt(down.position.x)
                    dragTime = time
                    scrub(time)
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) {
                            change.consume()
                            break
                        }
                        change.consume()
                        time = timeAt(change.position.x)
                        dragTime = time
                        scrub(time)
                    }
                    landedTime = time
                    dragTime = null
                    commit(time)
                }
            },
        ) {
            val track = if (active) 6.dp.toPx() else 3.dp.toPx()
            val y = size.height / 2
            drawRoundRect(Color.White.copy(alpha = 0.28f), Offset(0f, y - track / 2), Size(size.width, track), CornerRadius(track / 2))
            drawRoundRect(AccentTeal, Offset(0f, y - track / 2), Size(size.width * fraction, track), CornerRadius(track / 2))
            drawCircle(Color.White, radius = if (active) 8.dp.toPx() else 5.5.dp.toPx(), center = Offset(size.width * fraction, y))
        }
        val time = dragTime
        if (time != null) {
            val bubbleWidth = 168.dp
            val bubblePx = with(density) { bubbleWidth.toPx() }
            val x = (widthPx * fraction - bubblePx / 2).coerceIn(0f, max(0f, widthPx - bubblePx))
            val lift = with(density) { (if (storyboard != null) 120.dp else 30.dp).toPx() }
            Box(Modifier.offset { IntOffset(x.roundToInt(), -lift.roundToInt()) }.width(bubbleWidth)) {
                SeekPreview(storyboard, time, label(time))
            }
        }
    }
}

@Composable
private fun SeekPreview(storyboard: Storyboard?, time: Double, label: String) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        val frame = storyboard?.frame(time)
        if (storyboard != null && frame != null) {
            StoryboardThumbnail(
                storyboard, frame,
                Modifier.width(160.dp).height(90.dp).clip(RoundedCornerShape(6.dp)).border(1.dp, Color.White.copy(alpha = 0.6f), RoundedCornerShape(6.dp)),
            )
            Spacer(Modifier.height(4.dp))
        }
        Text(
            label, fontSize = 12.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace,
            modifier = Modifier.background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

private val spriteCache = LruCache<String, ImageBitmap>(8)

private suspend fun loadSprite(context: Context, url: String): ImageBitmap? {
    spriteCache.get(url)?.let { return it }
    val request = ImageRequest.Builder(context).data(url).allowHardware(false).build()
    val bitmap = (context.imageLoader.execute(request) as? SuccessResult)?.drawable?.toBitmap()?.asImageBitmap() ?: return null
    spriteCache.put(url, bitmap)
    return bitmap
}

@Composable
private fun StoryboardThumbnail(storyboard: Storyboard, frame: Storyboard.Frame, modifier: Modifier) {
    val context = LocalContext.current
    val image by produceState<ImageBitmap?>(spriteCache.get(frame.image), frame.image) { value = loadSprite(context, frame.image) }
    Canvas(modifier.background(Color.Black)) {
        val sprite = image ?: return@Canvas
        val cellWidth = sprite.width / storyboard.columns
        val cellHeight = sprite.height / storyboard.rows
        if (cellWidth <= 0 || cellHeight <= 0) return@Canvas
        drawImage(
            sprite,
            srcOffset = IntOffset(frame.column * cellWidth, frame.row * cellHeight),
            srcSize = IntSize(cellWidth, cellHeight),
            dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt()),
        )
    }
}

@Composable
private fun StatsOverlay(lines: List<Pair<String, String>>) {
    Column(
        Modifier.padding(start = 8.dp, top = 48.dp).background(Color.Black.copy(alpha = 0.65f), RoundedCornerShape(6.dp)).padding(8.dp),
    ) {
        for ((label, value) in lines) {
            Row {
                Text(label, fontSize = 10.sp, color = Secondary, fontFamily = FontFamily.Monospace, modifier = Modifier.width(96.dp))
                Text(value, fontSize = 10.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun ResumeBanner(controller: PlayerController) {
    val resumed = controller.resumedAt
    AnimatedVisibility(resumed != null, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.padding(start = 10.dp, top = 52.dp)) {
        Row(
            Modifier.background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape(50)).padding(start = 12.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Resumed at ${Format.duration((resumed ?: 0.0).toLong())}", fontSize = 12.sp)
            Text(
                "Start over", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = AccentTeal,
                modifier = Modifier.clip(RoundedCornerShape(50)).clickable { controller.startOver() }.padding(horizontal = 8.dp, vertical = 8.dp),
            )
        }
    }
}

/** Ten seconds back or forward: a circular arrow with "10" in it. */
@Composable
private fun SkipButton(back: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(50.dp).alpha(if (enabled) 1f else 0f).clip(CircleShape).background(Color.Black.copy(alpha = 0.3f))
            .clickable(enabled = enabled, onClick = onClick)
            .semantics { contentDescription = if (back) "Back 10 seconds" else "Forward 10 seconds" },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Filled.Refresh, contentDescription = null, tint = Color.White,
            modifier = Modifier.size(32.dp).graphicsLayer { scaleX = if (back) -1f else 1f },
        )
        Text("10", color = Color.White, fontSize = 9.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun MiniControls(controller: PlayerController) {
    Row(
        Modifier.fillMaxSize().background(Brush.horizontalGradient(0.45f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.55f))),
        horizontalArrangement = Arrangement.End,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (controller.phase == PlayerController.Phase.Playing) {
            RoundIcon(if (controller.isPaused) Icons.Filled.PlayArrow else KIcons.Pause, if (controller.isPaused) "Play" else "Pause", 36.dp) {
                controller.togglePause()
            }
        }
        RoundIcon(Icons.Filled.Close, "Close", 36.dp) { App.closePlayer() }
    }
}

/** Under the video: who's streaming and what. Tap the picture or name to open the channel. */
@Composable
private fun StreamInfoBar(controller: PlayerController) {
    val channel = controller.channel
    Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.clip(CircleShape).clickable(enabled = channel != null) { channel?.let { App.openChannel(it) } }) {
            Avatar(channel?.profileImageURL, 40.dp)
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                channel?.name ?: "", fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1,
                modifier = Modifier.clickable(enabled = channel != null) { channel?.let { App.openChannel(it) } },
            )
            val title = titleOf(controller)
            if (title.isNotEmpty()) Text(title, fontSize = 13.sp, color = Secondary, maxLines = 2, overflow = TextOverflow.Ellipsis, lineHeight = 17.sp)
            val details = when (val target = controller.target) {
                is PlaybackTarget.Live -> listOfNotNull(
                    (controller.stream ?: target.stream)?.category?.name,
                    Format.uptime((controller.stream ?: target.stream)?.startedAt),
                )
                is PlaybackTarget.Vod -> listOfNotNull(target.video.categoryName, Format.relative(target.video.createdAt).ifEmpty { null })
            }
            if (details.isNotEmpty()) Text(details.joinToString(" · "), fontSize = 12.sp, color = AccentTeal, maxLines = 1)
        }
        if (channel != null) FollowButton(channel)
    }
}

/** The gear: quality, low latency, video stats. */
@Composable
private fun PlayerMenu(controller: PlayerController, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Surface1) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 12.dp)) {
            Text("Quality", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Secondary, modifier = Modifier.padding(start = 20.dp, bottom = 4.dp))
            for (quality in controller.menuQualities) {
                Row(
                    Modifier.fillMaxWidth().clickable {
                        controller.selectQuality(quality)
                        onDismiss()
                    }.padding(horizontal = 20.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(quality.label, fontSize = 16.sp, modifier = Modifier.weight(1f))
                    if (quality.id == controller.menuSelectedQuality) Icon(Icons.Filled.Check, contentDescription = "Selected", tint = AccentTeal)
                }
            }
            if (controller.isLive && !controller.isRewinding) {
                MenuSwitch("Low latency", AppSettings.lowLatency) { controller.setLowLatency(it) }
            }
            MenuSwitch("Video stats", AppSettings.showVideoStats) { AppSettings.showVideoStats = it }
        }
    }
}

@Composable
private fun MenuSwitch(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, fontSize = 16.sp, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange, colors = SwitchDefaults.colors(checkedTrackColor = AccentTeal, checkedThumbColor = Color.White))
    }
}
