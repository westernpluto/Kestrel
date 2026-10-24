package app.kestrel.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.kestrel.core.Category
import app.kestrel.core.Channel
import app.kestrel.core.ChannelPage
import app.kestrel.core.ChannelSearchResult
import app.kestrel.core.Format
import app.kestrel.core.Kestrel
import app.kestrel.core.LiveStream
import app.kestrel.core.TwitchApi
import app.kestrel.core.Video
import app.kestrel.data.FavoritesStore
import app.kestrel.data.FollowingStore
import app.kestrel.data.SearchHistory
import app.kestrel.data.TwitchAccount
import app.kestrel.data.WatchHistory
import app.kestrel.player.PlaybackTarget
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Pull to refresh around a list; the spinner stays until the refresh is done. */
@Composable
fun Refreshable(onRefresh: suspend () -> Unit, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = {
            refreshing = true
            scope.launch {
                val started = System.currentTimeMillis()
                try {
                    onRefresh()
                } finally {
                    // A quick refresh still shows the spinner for a moment.
                    val elapsed = System.currentTimeMillis() - started
                    if (elapsed < 450) delay(450 - elapsed)
                    refreshing = false
                }
            }
        },
        modifier = modifier,
    ) { content() }
}

// MARK: Following

@Composable
fun FollowingScreen(padding: PaddingValues, miniPlayerSpace: Dp) {
    val store = FollowingStore
    val session = TwitchAccount.session
    var showOffline by remember { mutableStateOf(true) }
    val refreshKey = (session?.login ?: "-") + "|" + FavoritesStore.channels.joinToString(",") { it.id }
    LaunchedEffect(refreshKey) { store.refresh() }
    LaunchedEffect(App.resumeCount) { store.refreshIfStale() }
    Column(Modifier.fillMaxSize()) {
        TopBar("Following")
        Refreshable(onRefresh = { store.refresh(force = true) }, modifier = Modifier.weight(1f)) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = padding.calculateBottomPadding() + miniPlayerSpace)) {
                if (session == null) item { SignInCard() }
                store.error?.let { error -> item { ErrorBanner(error) { Kestrel.scope.launch { store.refresh() } } } }
                if (store.loaded && store.live.isEmpty() && store.offline.isEmpty() && store.error == null) {
                    item {
                        EmptyState(
                            "Nobody here yet",
                            if (session == null) "Sign in to see who you follow on Twitch, or tap the heart under a stream." else "Channels you follow on Twitch show up here.",
                            Icons.Filled.Person,
                        )
                    }
                }
                if (store.live.isNotEmpty()) {
                    item { ListHeader("Live", store.live.size) }
                    items(store.live, key = { "live-" + it.channel.id }) { stream -> StreamRow(stream) }
                }
                if (store.offline.isNotEmpty()) {
                    item {
                        val rotation by animateFloatAsState(if (showOffline) 0f else -90f, label = "chevron")
                        Row(
                            Modifier.fillMaxWidth().clickable { showOffline = !showOffline }.padding(end = 16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(Modifier.weight(1f)) { ListHeader("Offline", store.offline.size) }
                            Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = Secondary, modifier = Modifier.rotate(rotation))
                        }
                    }
                    if (showOffline) {
                        items(store.offline, key = { "offline-" + it.channel.id }) { entry ->
                            ChannelRow(
                                entry.channel,
                                subtitle = entry.lastLive?.let { "Last live ${Format.relative(it)}" },
                                modifier = Modifier.pressable(onClick = { App.push(Route.ChannelPage(entry.channel)) }),
                            )
                        }
                    }
                }
                if (store.isLoading && !store.loaded) item { LoadingRow() }
            }
        }
    }
}

@Composable
private fun ListHeader(title: String, count: Int) {
    Row(Modifier.padding(start = 16.dp, top = 14.dp, bottom = 4.dp), verticalAlignment = Alignment.Bottom) {
        Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.width(6.dp))
        Text(count.toString(), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Secondary, modifier = Modifier.padding(bottom = 2.dp))
    }
}

@Composable
private fun SignInCard() {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).clip(RoundedCornerShape(12.dp)).background(Surface2)
            .clickable { App.showSignIn = true }.padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Person, contentDescription = null, tint = AccentTeal, modifier = Modifier.size(28.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text("Sign in with Twitch", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text("See who you follow and chat as yourself", fontSize = 13.sp, color = Secondary)
        }
    }
}

// MARK: Browse

class BrowseModel {
    val streams = Paginator<LiveStream>({ it.channel.id }) { TwitchApi.topStreams(it) }
    val categories = Paginator<Category>({ it.id }) { TwitchApi.topCategories(it) }
}

@Composable
fun BrowseScreen(padding: PaddingValues, miniPlayerSpace: Dp) {
    val model = App.model("browse") { BrowseModel() }
    val pager = rememberPagerState { 2 }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { if (!model.streams.loaded) model.streams.refresh() }
    LaunchedEffect(pager.currentPage) { if (pager.currentPage == 1 && !model.categories.loaded) model.categories.refresh() }
    val bottom = padding.calculateBottomPadding() + miniPlayerSpace
    Column(Modifier.fillMaxSize()) {
        TopBar("Browse")
        TabRow(selectedTabIndex = pager.currentPage, containerColor = Color.Black, contentColor = AccentTeal) {
            listOf("Live", "Categories").forEachIndexed { index, title ->
                Tab(
                    selected = pager.currentPage == index,
                    onClick = { scope.launch { pager.animateScrollToPage(index) } },
                    text = { Text(title, fontWeight = FontWeight.SemiBold) },
                    selectedContentColor = Color.White,
                    unselectedContentColor = Secondary,
                )
            }
        }
        HorizontalPager(state = pager, modifier = Modifier.weight(1f)) { page ->
            if (page == 0) {
                Refreshable(onRefresh = { model.streams.refresh() }) {
                    StreamList(model.streams, bottom, showCategory = true)
                }
            } else {
                Refreshable(onRefresh = { model.categories.refresh() }) {
                    CategoryGrid(model.categories, bottom)
                }
            }
        }
    }
}

@Composable
fun StreamList(paginator: Paginator<LiveStream>, bottom: Dp, showCategory: Boolean, header: (@Composable () -> Unit)? = null) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 4.dp, bottom = bottom)) {
        if (header != null) item { header() }
        itemsIndexed(paginator.items, key = { _, stream -> stream.channel.id }) { index, stream ->
            LaunchedEffect(index, paginator.items.size) { paginator.loadMoreIfNeeded(index) }
            StreamRow(stream, showCategory)
        }
        if (paginator.isLoading) item { LoadingRow() }
        val error = paginator.error
        if (error != null && paginator.items.isEmpty()) item { ErrorBanner(error) { Kestrel.scope.launch { paginator.refresh() } } }
    }
}

@Composable
private fun CategoryGrid(paginator: Paginator<Category>, bottom: Dp) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(3),
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 10.dp, bottom = bottom),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        itemsIndexed(paginator.items, key = { _, category -> category.id }) { index, category ->
            LaunchedEffect(index, paginator.items.size) { paginator.loadMoreIfNeeded(index) }
            CategoryTile(category, Modifier.pressable(onClick = { App.push(Route.CategoryPage(category)) }, scaleTo = 0.96f))
        }
        if (paginator.isLoading) item(span = { GridItemSpan(maxLineSpan) }) { LoadingRow() }
        val error = paginator.error
        if (error != null && paginator.items.isEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) { ErrorBanner(error) { Kestrel.scope.launch { paginator.refresh() } } }
        }
    }
}

@Composable
fun CategoryScreen(category: Category, padding: PaddingValues, miniPlayerSpace: Dp) {
    val model = App.model("category-${category.id}") {
        Paginator<LiveStream>({ it.channel.id }) { TwitchApi.categoryStreams(category.id, it) }
    }
    LaunchedEffect(Unit) { if (!model.loaded) model.refresh() }
    Column(Modifier.fillMaxSize()) {
        TopBar(category.name, onBack = { App.back() })
        Refreshable(onRefresh = { model.refresh() }, modifier = Modifier.weight(1f)) {
            StreamList(model, padding.calculateBottomPadding() + miniPlayerSpace, showCategory = false) {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    RemoteImage(TwitchApi.image(category.boxArtURL, 285, 380), Modifier.width(72.dp).height(96.dp).clip(RoundedCornerShape(6.dp)))
                    Spacer(Modifier.width(14.dp))
                    Column {
                        Text(category.name, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                        if (category.viewers > 0) Text("${Format.viewers(category.viewers)} watching", fontSize = 14.sp, color = Secondary)
                    }
                }
            }
        }
    }
}

// MARK: Search

class SearchModel {
    var text by mutableStateOf("")
    var channels by mutableStateOf<List<ChannelSearchResult>>(emptyList())
        private set
    var categories by mutableStateOf<List<Category>>(emptyList())
        private set
    var isLoading by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    private var job: Job? = null
    private var searchedAt = 0L

    /** `debounce`: wait a moment first (while typing). */
    fun search(debounce: Boolean = true) {
        job?.cancel()
        val query = text.trim()
        if (query.length < 2) {
            channels = emptyList()
            categories = emptyList()
            error = null
            isLoading = false
            return
        }
        job = Kestrel.scope.launch {
            if (debounce) delay(300)
            isLoading = true
            try {
                coroutineScope {
                    val foundChannels = async { TwitchApi.searchChannels(query) }
                    val foundCategories = async { TwitchApi.searchCategories(query, 10) }
                    // Live channels first, then by followers.
                    channels = foundChannels.await().sortedWith(
                        compareByDescending<ChannelSearchResult> { it.liveViewers != null }.thenByDescending { it.followers ?: 0 },
                    )
                    categories = foundCategories.await()
                }
                error = null
                searchedAt = System.currentTimeMillis()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message ?: "Search failed."
            } finally {
                isLoading = false
            }
        }
    }

    /** Back on the search after a while: fetch the results again (who's live changes). */
    fun refreshIfStale() {
        if (text.trim().length >= 2 && System.currentTimeMillis() - searchedAt > 20_000) search(debounce = false)
    }

    suspend fun refresh() {
        search(debounce = false)
        job?.join()
    }
}

@Composable
fun SearchScreen(padding: PaddingValues, miniPlayerSpace: Dp) {
    val model = App.model("search") { SearchModel() }
    val focus = LocalFocusManager.current
    LaunchedEffect(App.resumeCount) { model.refreshIfStale() }
    fun open(action: () -> Unit) {
        SearchHistory.remember(model.text)
        focus.clearFocus()
        action()
    }
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxWidth().background(Color.Black).statusBarsPadding()) {
            Text("Search", fontSize = 24.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 8.dp))
            TextField(
                value = model.text,
                onValueChange = {
                    model.text = it
                    model.search()
                },
                placeholder = { Text("Channels and categories") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                trailingIcon = {
                    if (model.text.isNotEmpty()) {
                        IconButton(onClick = {
                            model.text = ""
                            model.search()
                        }) { Icon(Icons.Filled.Clear, contentDescription = "Clear") }
                    }
                },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = {
                    model.search(debounce = false)
                    SearchHistory.remember(model.text)
                    focus.clearFocus()
                }),
                shape = RoundedCornerShape(12.dp),
                colors = TextFieldDefaults.colors(
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    focusedContainerColor = Surface2,
                    unfocusedContainerColor = Surface2,
                ),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        Refreshable(onRefresh = { model.refresh() }, modifier = Modifier.weight(1f)) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 6.dp, bottom = padding.calculateBottomPadding() + miniPlayerSpace)) {
                if (model.text.isBlank() && SearchHistory.entries.isNotEmpty()) {
                    item {
                        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text("Recent searches", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Secondary, modifier = Modifier.weight(1f))
                            TextButton(onClick = { SearchHistory.clear() }) { Text("Clear") }
                        }
                    }
                    items(SearchHistory.entries.toList(), key = { "history-$it" }) { entry ->
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                model.text = entry
                                model.search(debounce = false)
                                SearchHistory.remember(entry)
                            }.padding(start = 16.dp, end = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(KIcons.History, contentDescription = null, tint = Secondary, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(12.dp))
                            Text(entry, fontSize = 16.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            IconButton(onClick = { SearchHistory.forget(entry) }) {
                                Icon(Icons.Filled.Clear, contentDescription = "Remove", tint = Tertiary, modifier = Modifier.size(18.dp))
                            }
                        }
                    }
                }
                if (model.categories.isNotEmpty()) {
                    item { SearchSectionTitle("Categories") }
                    item {
                        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            items(model.categories, key = { it.id }) { category ->
                                CategoryTile(
                                    category,
                                    Modifier.width(96.dp).pressable(onClick = { open { App.push(Route.CategoryPage(category)) } }, scaleTo = 0.96f),
                                )
                            }
                        }
                    }
                }
                if (model.channels.isNotEmpty()) {
                    item { SearchSectionTitle("Channels") }
                    items(model.channels, key = { "channel-" + it.channel.id }) { result ->
                        ChannelRow(
                            result.channel,
                            subtitle = result.followers?.let { "${Format.viewers(it)} followers" },
                            liveViewers = result.liveViewers,
                            modifier = Modifier.pressable(
                                onClick = { open { App.push(Route.ChannelPage(result.channel)) } },
                                onLongClick = if (result.liveViewers != null) ({ open { App.play(PlaybackTarget.Live(result.channel)) } }) else null,
                            ),
                        )
                    }
                }
                model.error?.let { error -> item { ErrorBanner(error) { model.search(debounce = false) } } }
                if (model.text.trim().length >= 2 && !model.isLoading && model.channels.isEmpty() && model.categories.isEmpty() && model.error == null) {
                    item { EmptyState("No results", "Try a different name.", Icons.Filled.Search) }
                }
                if (model.isLoading && model.channels.isEmpty()) item { LoadingRow() }
            }
        }
    }
}

@Composable
private fun SearchSectionTitle(title: String) {
    Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Secondary, modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 6.dp))
}

// MARK: Channel

class ChannelModel(val login: String) {
    var page by mutableStateOf<ChannelPage?>(null)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var loadedAt = 0L
        private set
    val videos = Paginator<Video>({ it.id }) { TwitchApi.videos(login, it) }

    suspend fun load() {
        loadedAt = System.currentTimeMillis()
        try {
            page = TwitchApi.channelPage(login)
            error = if (page == null) "Channel not found." else null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message ?: "Couldn't load the channel."
        }
        videos.refresh()
    }
}

@Composable
fun ChannelScreen(channel: Channel, padding: PaddingValues, miniPlayerSpace: Dp) {
    val model = App.model("channel-${channel.id}") { ChannelModel(channel.login) }
    LaunchedEffect(App.resumeCount) {
        // Back on the page after a while: whether they're live may have changed.
        if (model.page == null || System.currentTimeMillis() - model.loadedAt > 60_000) model.load()
    }
    val current = model.page?.channel ?: channel
    Column(Modifier.fillMaxSize()) {
        TopBar(current.name, onBack = { App.back() })
        Refreshable(onRefresh = { model.load() }, modifier = Modifier.weight(1f)) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = padding.calculateBottomPadding() + miniPlayerSpace)) {
                item {
                    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Avatar(current.profileImageURL, 64.dp)
                        Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text(current.name, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                            model.page?.followers?.let { Text("${Format.viewers(it)} followers", fontSize = 14.sp, color = Secondary) }
                        }
                        FollowButton(current, size = 28.dp)
                    }
                }
                val page = model.page
                val stream = page?.stream
                if (stream != null) {
                    item {
                        Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
                            Text("Live now", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                            Spacer(Modifier.height(6.dp))
                            StreamCard(stream)
                        }
                    }
                } else if (page != null) {
                    item {
                        Row(Modifier.padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(KIcons.Moon, contentDescription = null, tint = Secondary, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(page.lastBroadcast?.let { "Offline · last live ${Format.relative(it)}" } ?: "Offline", fontSize = 14.sp, color = Secondary)
                        }
                    }
                }
                page?.description?.takeIf { it.isNotBlank() }?.let { description ->
                    item { Text(description, fontSize = 13.sp, color = Secondary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) }
                }
                model.error?.let { error -> item { ErrorBanner(error) { Kestrel.scope.launch { model.load() } } } }
                if (model.videos.items.isNotEmpty()) {
                    item { Text("Videos", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 4.dp)) }
                }
                itemsIndexed(model.videos.items, key = { _, video -> video.id }) { index, video ->
                    LaunchedEffect(index, model.videos.items.size) { model.videos.loadMoreIfNeeded(index) }
                    VideoRow(video)
                }
                if (model.videos.isLoading) item { LoadingRow() }
            }
        }
    }
}

@Composable
private fun VideoRow(video: Video) {
    Row(Modifier.fillMaxWidth().pressable(onClick = { App.play(PlaybackTarget.Vod(video)) }).padding(horizontal = 16.dp, vertical = 7.dp)) {
        Box(Modifier.width(156.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(8.dp))) {
            RemoteImage(TwitchApi.image(video.previewURL, 320, 180), Modifier.fillMaxSize())
            Text(
                Format.duration(video.lengthSeconds.toLong()), fontSize = 11.sp, color = Color.White,
                modifier = Modifier.align(Alignment.BottomEnd).padding(start = 4.dp, end = 4.dp, bottom = 7.dp)
                    .background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape(3.dp)).padding(horizontal = 4.dp, vertical = 1.dp),
            )
            WatchHistory.progress(video)?.let { progress ->
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color.White.copy(alpha = 0.25f))) {
                    Box(Modifier.fillMaxWidth(progress.toFloat()).height(3.dp).background(AccentTeal))
                }
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(video.title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis, lineHeight = 18.sp)
            Text(
                listOfNotNull(video.categoryName, Format.relative(video.createdAt).ifEmpty { null }).joinToString(" · "),
                fontSize = 12.sp, color = Secondary, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Text("${Format.viewers(video.viewCount)} views", fontSize = 12.sp, color = Secondary)
        }
    }
}
