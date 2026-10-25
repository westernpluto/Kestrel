package app.kestrel.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.kestrel.chat.ChatController
import app.kestrel.chat.ChatFragment
import app.kestrel.chat.ChatMessage
import app.kestrel.chat.EmoteSection
import app.kestrel.chat.NamedEmote
import app.kestrel.data.AppSettings
import app.kestrel.data.TwitchAccount
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Width ÷ height of emote and badge pictures, learned as they load (wide 7TV emotes). */
object EmoteAspects {
    private val ratios = mutableStateMapOf<String, Float>()
    var version by mutableIntStateOf(0)
        private set

    fun ratio(url: String): Float = ratios[url] ?: 1f

    fun learn(url: String, width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        val ratio = (width.toFloat() / height).coerceIn(0.25f, 4f)
        val known = ratios[url]
        if (known == null || Math.abs(known - ratio) > 0.05f) {
            ratios[url] = ratio
            if (Math.abs(ratio - 1f) > 0.05f || known != null) version++
        }
    }
}

private val palette = listOf(
    Color(0xFFFF453A), Color(0xFFFF9F0A), Color(0xFFFFD60A), Color(0xFF32D74B),
    Color(0xFF64D2FF), Color(0xFF0A84FF), Color(0xFFBF5AF2), Color(0xFFFF375F),
)

private val chatAccent = Color(0xFF9161FF)

/** A chatter's color, lightened if it's too dark for the black background. */
fun nameColor(hex: String?, seed: String): Color {
    if (hex != null && hex.startsWith("#") && hex.length == 7) {
        val value = hex.substring(1).toLongOrNull(16)
        if (value != null) {
            var r = ((value shr 16) and 0xFF) / 255f
            var g = ((value shr 8) and 0xFF) / 255f
            var b = (value and 0xFF) / 255f
            val luminance = 0.299f * r + 0.587f * g + 0.114f * b
            if (luminance < 0.45f) {
                val boost = 0.45f - luminance
                r = minOf(1f, r + boost)
                g = minOf(1f, g + boost)
                b = minOf(1f, b + boost)
            }
            return Color(r, g, b)
        }
    }
    var hash = 7
    for (c in seed) hash = hash * 31 + c.code
    return palette[Math.floorMod(hash, palette.size)]
}

/**
 * Fades its content in and out. A function of its own, so inside a Box that's inside a Column it
 * uses the plain fade (not the Column's version, which Compose only allows directly in a Column).
 */
@Composable
private fun Fading(visible: Boolean, modifier: Modifier, content: @Composable () -> Unit) {
    AnimatedVisibility(visible, modifier = modifier, enter = fadeIn(), exit = fadeOut()) { content() }
}

private data class RenderedMessage(val text: AnnotatedString, val inline: Map<String, InlineTextContent>, val highlighted: Boolean)

private fun render(message: ChatMessage, chat: ChatController, fontSize: Float, me: String?): RenderedMessage {
    val inline = HashMap<String, InlineTextContent>()
    fun picture(builder: AnnotatedString.Builder, url: String, height: Float, alternate: String) {
        val id = "img:$height:$url"
        if (!inline.containsKey(id)) {
            val ratio = EmoteAspects.ratio(url)
            inline[id] = InlineTextContent(Placeholder((height * ratio).sp, height.sp, PlaceholderVerticalAlign.Center)) {
                AsyncImage(
                    model = url,
                    contentDescription = alternate,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize(),
                    onSuccess = { state ->
                        val drawable = state.result.drawable
                        EmoteAspects.learn(url, drawable.intrinsicWidth, drawable.intrinsicHeight)
                    },
                )
            }
        }
        builder.appendInlineContent(id, alternate)
    }

    if (message.kind == ChatMessage.Kind.Notice) {
        return RenderedMessage(AnnotatedString(message.text, SpanStyle(color = Secondary)), emptyMap(), false)
    }
    val text = buildAnnotatedString {
        message.systemText?.let { system ->
            withStyle(SpanStyle(color = chatAccent, fontWeight = FontWeight.Bold)) { append(system) }
            if (message.text.isNotEmpty()) append("\n")
        }
        if (message.systemText != null && message.text.isEmpty()) return@buildAnnotatedString
        for (badge in message.badges) {
            val info = chat.badges[badge] ?: continue
            picture(this, info.imageURL, fontSize + 3f, info.title)
            append(" ")
        }
        val color = nameColor(message.color, message.login)
        withStyle(SpanStyle(color = color, fontWeight = FontWeight.Bold)) { append(message.displayName) }
        if (message.isDeleted) {
            withStyle(SpanStyle(color = Tertiary)) { append(": <message deleted>") }
            return@buildAnnotatedString
        }
        append(if (message.kind == ChatMessage.Kind.Action) " " else ": ")
        val bodyStyle = if (message.kind == ChatMessage.Kind.Action) SpanStyle(color = color) else SpanStyle(color = Color.White)
        for (fragment in message.fragments(chat.thirdParty)) {
            when (fragment) {
                is ChatFragment.Text -> withStyle(bodyStyle) { append(fragment.text) }
                is ChatFragment.Emote -> picture(this, fragment.url, fontSize * 1.75f, fragment.name)
            }
        }
    }
    val highlighted = message.systemText != null || (me != null && message.mentions(me))
    return RenderedMessage(text, inline, highlighted)
}

@Composable
private fun ChatLine(
    message: ChatMessage,
    chat: ChatController,
    fontSize: Float,
    me: String?,
    onReply: ((String) -> Unit)?,
    onTap: () -> Unit,
    onMenu: (Boolean) -> Unit,
) {
    val rendered = remember(message, chat.decorationsVersion, fontSize, EmoteAspects.version, me) { render(message, chat, fontSize, me) }
    var menu by remember { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    // Chat holds still while this message's menu is open (so the menu stays by its message).
    val reportMenu by rememberUpdatedState(onMenu)
    val holding = remember { booleanArrayOf(false) }
    LaunchedEffect(menu) {
        if (menu != holding[0]) {
            holding[0] = menu
            reportMenu(menu)
        }
    }
    DisposableEffect(Unit) { onDispose { if (holding[0]) reportMenu(false) } }
    Box {
        Text(
            rendered.text,
            inlineContent = rendered.inline,
            fontSize = fontSize.sp,
            lineHeight = (fontSize * 1.5f).sp,
            modifier = Modifier.fillMaxWidth()
                .background(if (rendered.highlighted) chatAccent.copy(alpha = 0.16f) else Color.Transparent)
                .combinedClickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onTap,
                    onLongClick = { if (message.kind != ChatMessage.Kind.Notice) menu = true },
                )
                .padding(horizontal = 10.dp, vertical = 2.dp),
        )
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text("Copy") },
                leadingIcon = { Icon(KIcons.Copy, contentDescription = null) },
                onClick = {
                    menu = false
                    clipboard.setText(AnnotatedString(message.text))
                },
            )
            if (onReply != null && message.login.isNotEmpty()) {
                DropdownMenuItem(
                    text = { Text("Reply to ${message.displayName}") },
                    leadingIcon = { Icon(KIcons.Reply, contentDescription = null) },
                    onClick = {
                        menu = false
                        onReply(message.login)
                    },
                )
            }
        }
    }
}

private sealed class Suggestion {
    data class Emote(val emote: NamedEmote) : Suggestion()
    data class Chatter(val name: String) : Suggestion()
}

/**
 * Chat: messages, the message box (signed in), autocomplete for `:emotes` and `@people`, and the
 * emote picker. `active`: false while the player is shrunk (the box can't take focus).
 */
@Composable
fun ChatPanel(chat: ChatController, active: Boolean, compact: Boolean, modifier: Modifier = Modifier) {
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val scope = rememberCoroutineScope()
    val session = TwitchAccount.session
    val fontSize = AppSettings.chatFontSize
    var draft by remember { mutableStateOf(TextFieldValue("")) }
    var pickerOpen by remember { mutableStateOf(false) }
    var focused by remember { mutableStateOf(false) }
    var warning by remember { mutableStateOf<String?>(null) }
    val focusRequester = remember { FocusRequester() }
    val listState = rememberLazyListState()
    var following by remember { mutableStateOf(true) }
    /** A message's menu is open: new messages don't scroll chat until it closes. */
    var menuOpen by remember { mutableStateOf(false) }
    val messages = chat.messages

    LaunchedEffect(active) {
        if (!active) {
            focusManager.clearFocus()
            pickerOpen = false
        }
    }
    LaunchedEffect(chat.bounced) {
        val bounced = chat.bounced ?: return@LaunchedEffect
        draft = TextFieldValue(bounced.text, TextRange(bounced.text.length))
        warning = bounced.reason
        delay(5000)
        if (warning == bounced.reason) warning = null
    }

    // Follow new messages unless you've scrolled up to read.
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            if (!scrolling) following = listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset < 60
        }
    }
    val newest = messages.lastOrNull()?.id
    LaunchedEffect(newest, messages.size, menuOpen) {
        if (following && !menuOpen && messages.isNotEmpty()) listState.animateScrollToItem(0)
    }

    fun insertAtEnd(text: String) {
        var current = draft.text
        if (current.isNotEmpty() && !current.endsWith(" ")) current += " "
        current += "$text "
        draft = TextFieldValue(current, TextRange(current.length))
    }

    val currentWord: String? = run {
        val last = draft.text.split(' ').lastOrNull() ?: return@run null
        if (last.length >= 2 && (last.startsWith(":") || last.startsWith("@"))) last else null
    }
    val suggestions: List<Suggestion> = remember(currentWord, chat.emoteSections, session) {
        val word = currentWord
        if (session == null || chat.isReplay || word == null) {
            emptyList()
        } else if (word.startsWith(":")) {
            chat.emoteSuggestions(word.substring(1)).map { Suggestion.Emote(it) }
        } else {
            chat.chatterSuggestions(word.substring(1)).map { Suggestion.Chatter(it) }
        }
    }

    fun complete(text: String) {
        val word = currentWord ?: return
        val updated = draft.text.dropLast(word.length) + text + " "
        draft = TextFieldValue(updated, TextRange(updated.length))
    }

    val reply: ((String) -> Unit)? = if (session != null && !chat.isReplay) {
        { login: String ->
            val prefix = "@$login "
            draft = TextFieldValue(prefix + draft.text, TextRange(prefix.length + draft.text.length))
            if (active) runCatching { focusRequester.requestFocus() }
        }
    } else {
        null
    }

    fun send() {
        val text = draft.text
        if (text.isBlank()) return
        chat.send(text)
        draft = TextFieldValue("")
    }

    Column(modifier) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(
                state = listState,
                reverseLayout = true,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(vertical = 6.dp),
            ) {
                val ordered = messages.asReversed()
                items(ordered, key = { it.id }) { message ->
                    ChatLine(
                        message, chat, fontSize, chat.ownLogin,
                        onReply = reply,
                        onTap = { focusManager.clearFocus() },
                        onMenu = { open -> menuOpen = open },
                    )
                }
            }
            val pill = when {
                chat.rewindReplay -> "Chat from this point of the stream"
                chat.status is ChatController.Status.Disconnected -> (chat.status as ChatController.Status.Disconnected).reason
                chat.status == ChatController.Status.Connecting && !chat.isReplay -> "Connecting to chat…"
                else -> null
            }
            Fading(pill != null, Modifier.align(Alignment.TopCenter).padding(top = 8.dp)) {
                Row(
                    Modifier.background(Color(0xE6202024), RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (chat.rewindReplay) {
                        Icon(KIcons.History, contentDescription = null, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(5.dp))
                    }
                    Text(pill ?: "", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            Fading(!following, Modifier.align(Alignment.BottomCenter).padding(bottom = 8.dp)) {
                Row(
                    Modifier.clip(RoundedCornerShape(50)).background(AccentTeal).clickable {
                        following = true
                        scope.launch { listState.animateScrollToItem(0) }
                    }.padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = Color.Black, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Newest messages", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color.Black)
                }
            }
        }
        HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
        if (suggestions.isNotEmpty()) {
            LazyRow(contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(suggestions, key = { if (it is Suggestion.Emote) "e-" + it.emote.name else "c-" + (it as Suggestion.Chatter).name }) { suggestion ->
                    when (suggestion) {
                        is Suggestion.Emote -> Row(
                            Modifier.clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.08f))
                                .clickable { complete(suggestion.emote.name) }.padding(horizontal = 8.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            AsyncImage(model = suggestion.emote.url, contentDescription = null, modifier = Modifier.size(26.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(suggestion.emote.name, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                        }
                        is Suggestion.Chatter -> Text(
                            "@" + suggestion.name, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.08f))
                                .clickable { complete("@" + suggestion.name) }.padding(horizontal = 10.dp, vertical = 8.dp),
                        )
                    }
                }
            }
        }
        when {
            chat.isReplay -> Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Icon(KIcons.History, contentDescription = null, tint = Secondary, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(6.dp))
                Text("Chat replay", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Secondary)
            }
            session != null -> Column(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp)) {
                val note = warning ?: chat.roomRules
                if (note != null) {
                    Text(
                        note, fontSize = 11.sp, color = if (warning != null) Color(0xFFFF9F0A) else Secondary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 4.dp, bottom = 4.dp),
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Row(
                        Modifier.weight(1f).clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.08f)).padding(start = 12.dp, end = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        BasicTextField(
                            value = draft,
                            onValueChange = { draft = it },
                            enabled = chat.canSend && active,
                            textStyle = TextStyle(color = Color.White, fontSize = 15.sp),
                            cursorBrush = SolidColor(AccentTeal),
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Send),
                            keyboardActions = KeyboardActions(onSend = { send() }),
                            maxLines = 4,
                            modifier = Modifier.weight(1f).heightIn(min = 36.dp).padding(vertical = 8.dp)
                                .focusRequester(focusRequester)
                                .onFocusChanged {
                                    focused = it.isFocused
                                    if (it.isFocused) pickerOpen = false
                                },
                            decorationBox = { inner ->
                                Box(contentAlignment = Alignment.CenterStart) {
                                    if (draft.text.isEmpty()) {
                                        Text(
                                            when {
                                                !chat.canSend -> "Joining chat…"
                                                chat.emoteOnly -> "Emotes only"
                                                else -> "Send a message"
                                            },
                                            color = Tertiary, fontSize = 15.sp,
                                        )
                                    }
                                    inner()
                                }
                            },
                        )
                        IconButton(onClick = {
                            if (pickerOpen) {
                                pickerOpen = false
                                runCatching { focusRequester.requestFocus() }
                                keyboard?.show()
                            } else {
                                focusManager.clearFocus()
                                keyboard?.hide()
                                pickerOpen = true
                            }
                        }, modifier = Modifier.size(36.dp)) {
                            Icon(
                                if (pickerOpen) KIcons.Keyboard else KIcons.Emoji,
                                contentDescription = if (pickerOpen) "Keyboard" else "Emotes",
                                tint = if (pickerOpen) AccentTeal else Color.White.copy(alpha = 0.75f),
                                modifier = Modifier.size(22.dp),
                            )
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                    val empty = draft.text.isBlank()
                    Box(
                        Modifier.size(38.dp).clip(CircleShape).background(if (empty) Color.White.copy(alpha = 0.08f) else AccentTeal)
                            .clickable(enabled = chat.canSend && !empty) { send() },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send", tint = Color.White, modifier = Modifier.size(18.dp))
                    }
                }
            }
            else -> Box(
                Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp).clip(RoundedCornerShape(10.dp))
                    .clickable { App.showSignIn = true }.padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(KIcons.ChatOutline, contentDescription = null, tint = AccentTeal, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Sign in with Twitch to chat", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = AccentTeal)
                }
            }
        }
        if (pickerOpen) {
            EmotePicker(chat.emoteSections, Modifier.fillMaxWidth().height(if (compact) 190.dp else 280.dp)) { insertAtEnd(it.name) }
        }
    }
}

/** Twitch-style emote picker: every emote you can use here, by channel, with a strip to jump. */
@Composable
private fun EmotePicker(sections: List<EmoteSection>, modifier: Modifier, onPick: (NamedEmote) -> Unit) {
    val gridState = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    // Where each section's header sits in the grid.
    val headerIndices = remember(sections) {
        var index = 0
        sections.map { section ->
            val at = index
            index += 1 + section.emotes.size
            at
        }
    }
    Column(modifier.background(Color(0xFF17171A))) {
        if (sections.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Loading emotes…", fontSize = 13.sp, color = Secondary) }
            return@Column
        }
        LazyVerticalGrid(
            columns = GridCells.Adaptive(46.dp),
            state = gridState,
            modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
        ) {
            sections.forEach { section ->
                item(key = "header-${section.id}", span = { GridItemSpan(maxLineSpan) }) {
                    Text(
                        section.title, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Secondary,
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
                    )
                }
                section.emotes.forEachIndexed { i, emote ->
                    item(key = "${section.id}-$i-${emote.name}") {
                        Box(
                            Modifier.height(44.dp).clip(RoundedCornerShape(6.dp)).clickable { onPick(emote) },
                            contentAlignment = Alignment.Center,
                        ) {
                            AsyncImage(model = emote.url, contentDescription = emote.name, modifier = Modifier.size(32.dp))
                        }
                    }
                }
            }
        }
        HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
        LazyRow(Modifier.fillMaxWidth().height(40.dp), contentPadding = PaddingValues(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            itemsIndexed(sections, key = { _, section -> section.id }) { i, section ->
                Box(
                    Modifier.size(width = 40.dp, height = 36.dp).clip(RoundedCornerShape(6.dp))
                        .clickable { scope.launch { gridState.animateScrollToItem(headerIndices[i]) } },
                    contentAlignment = Alignment.Center,
                ) {
                    when {
                        section.id == "recent" -> Icon(KIcons.History, contentDescription = section.title, tint = Secondary, modifier = Modifier.size(18.dp))
                        section.icon != null -> AsyncImage(
                            model = section.icon, contentDescription = section.title, contentScale = ContentScale.Crop,
                            modifier = Modifier.size(22.dp).clip(CircleShape),
                        )
                        else -> AsyncImage(model = section.emotes.firstOrNull()?.url, contentDescription = section.title, modifier = Modifier.size(22.dp))
                    }
                }
            }
        }
    }
}
