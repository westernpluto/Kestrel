package app.kestrel.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import app.kestrel.chat.ChatController
import app.kestrel.core.Category
import app.kestrel.core.Channel
import app.kestrel.core.Kestrel
import app.kestrel.core.Page
import app.kestrel.player.KestrelPlayer
import app.kestrel.player.PlaybackTarget
import app.kestrel.player.PlayerController
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** The app's sections. */
enum class Tab(val title: String) { Following("Following"), Browse("Browse"), Search("Search"), Settings("Settings") }

/** A page in a section's stack. */
sealed class Route {
    abstract val key: String

    data class ChannelPage(val channel: Channel) : Route() {
        override val key: String get() = "channel-${channel.id}"
    }

    data class CategoryPage(val category: Category) : Route() {
        override val key: String get() = "category-${category.id}"
    }

    object AdBlocking : Route() {
        override val key: String get() = "adblocking"
    }

    object ActivityLog : Route() {
        override val key: String get() = "log"
    }
}

/** What's on screen: the section, its pages, and what's playing. */
object App {
    var tab by mutableStateOf(Tab.Following)
    val stacks: Map<Tab, SnapshotStateList<Route>> = Tab.entries.associateWith { mutableStateListOf<Route>() }

    var player by mutableStateOf<PlayerController?>(null)
        private set
    var chat by mutableStateOf<ChatController?>(null)
        private set

    /** The player is shrunk into the mini player above the tab bar. */
    var minimized by mutableStateOf(false)
    var showSignIn by mutableStateOf(false)
    var inPictureInPicture by mutableStateOf(false)

    /** Bumped every time the app comes to the foreground (screens refresh stale data). */
    var resumeCount by mutableStateOf(0)

    /** Turns the screen (set by MainActivity): true = landscape (full screen), false = portrait. */
    var requestOrientation: (Boolean) -> Unit = {}

    /** Shrinks the app into a picture-in-picture window (set by MainActivity). */
    var requestPictureInPicture: () -> Unit = {}

    /** Screen models that live as long as their page is in a stack. */
    private val models = HashMap<String, Any>()

    val watchingChannelId: String? get() = (player?.target as? PlaybackTarget.Live)?.channel?.id

    fun play(target: PlaybackTarget) {
        val current = player
        if (current != null && current.target.key == target.key &&
            current.phase != PlayerController.Phase.Offline && current.phase !is PlayerController.Phase.Failed
        ) {
            minimized = false
            return
        }
        closePlayer()
        val controller = PlayerController(target)
        val owner = when (target) {
            is PlaybackTarget.Live -> target.channel
            is PlaybackTarget.Vod -> target.video.owner
        }
        val chatController = owner?.let { ChatController(it, (target as? PlaybackTarget.Vod)?.video?.id) }
        player = controller
        chat = chatController
        minimized = false
        controller.start()
        chatController?.start()
    }

    fun closePlayer() {
        player?.stop()
        chat?.stop()
        player = null
        chat = null
        minimized = false
        KestrelPlayer.disconnectService()
    }

    /** Shrinks the player and opens the channel's page in the current section. */
    fun openChannel(channel: Channel) {
        if (player != null) minimized = true
        if (tab == Tab.Settings) tab = Tab.Following
        push(Route.ChannelPage(channel))
    }

    /** Opens a page in the current section. A page that's already open there is gone back to, never stacked twice. */
    fun push(route: Route) {
        val stack = stacks.getValue(tab)
        val index = stack.indexOfFirst { it.key == route.key }
        if (index >= 0) {
            while (stack.size > index + 1) pop(stack)
        } else {
            stack.add(route)
        }
    }

    fun selectTab(selected: Tab) {
        if (tab == selected) {
            val stack = stacks.getValue(selected)
            while (stack.isNotEmpty()) pop(stack)
        } else {
            tab = selected
        }
    }

    val canGoBack: Boolean get() = stacks.getValue(tab).isNotEmpty() || tab != Tab.Following

    fun back(): Boolean {
        val stack = stacks.getValue(tab)
        if (stack.isNotEmpty()) {
            pop(stack)
            return true
        }
        if (tab != Tab.Following) {
            tab = Tab.Following
            return true
        }
        return false
    }

    private fun pop(stack: SnapshotStateList<Route>) {
        val removed = stack.removeAt(stack.size - 1)
        if (stacks.values.none { other -> other.any { it.key == removed.key } }) models.remove(removed.key)
    }

    @Suppress("UNCHECKED_CAST")
    fun <T : Any> model(key: String, create: () -> T): T = models.getOrPut(key, create) as T
}

/** Loads pages of a list on demand. */
class Paginator<T>(private val idOf: (T) -> String, private val fetch: suspend (String?) -> Page<T>) {
    val items = mutableStateListOf<T>()
    var isLoading by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var loaded by mutableStateOf(false)
        private set
    private var cursor: String? = null
    private var hasMore = true
    private val seen = HashSet<String>()

    suspend fun refresh() {
        load(reset = true)
    }

    fun loadMoreIfNeeded(index: Int) {
        if (index < items.size - 6 || isLoading || !hasMore || !loaded) return
        Kestrel.scope.launch { load(reset = false) }
    }

    private suspend fun load(reset: Boolean) {
        if (isLoading) return
        if (!reset && !hasMore) return
        isLoading = true
        try {
            val page = fetch(if (reset) null else cursor)
            if (reset) {
                seen.clear()
                items.clear()
            }
            items.addAll(page.items.filter { seen.add(idOf(it)) })
            cursor = page.cursor
            hasMore = page.hasNextPage && page.cursor != null && page.items.isNotEmpty()
            error = null
            loaded = true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message ?: "Something went wrong."
            if (reset) items.clear()
        } finally {
            isLoading = false
        }
    }
}
