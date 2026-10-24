package app.kestrel.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import app.kestrel.MainActivity
import app.kestrel.data.AppSettings
import app.kestrel.data.FollowingStore

private val Tab.icon: ImageVector
    get() = when (this) {
        Tab.Following -> Icons.Filled.Favorite
        Tab.Browse -> KIcons.Explore
        Tab.Search -> Icons.Filled.Search
        Tab.Settings -> Icons.Filled.Settings
    }

@Composable
fun KestrelRoot() {
    val player = App.player
    val chat = App.chat
    val pip = App.inPictureInPicture
    val activity = LocalContext.current.findActivity() as? MainActivity

    // Leaving the app while something plays: picture in picture (when it's on).
    LaunchedEffect(player?.isPlaying, AppSettings.pictureInPicture, player?.videoAspect) {
        activity?.updatePictureInPicture(AppSettings.pictureInPicture && player?.isPlaying == true, player?.videoAspect ?: (16f / 9f))
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (!pip) MainScaffold()
        if (player != null) PlayerHost(player, chat)
        if (App.showSignIn) SignInDialog { App.showSignIn = false }
        FollowingStore.notice?.let { notice ->
            AlertDialog(
                onDismissRequest = { FollowingStore.notice = null },
                text = { Text(notice) },
                confirmButton = { TextButton(onClick = { FollowingStore.notice = null }) { Text("OK") } },
            )
        }
    }
}

@Composable
private fun MainScaffold() {
    val holder = rememberSaveableStateHolder()
    BackHandler(enabled = App.canGoBack) { App.back() }
    Scaffold(
        containerColor = Color.Black,
        contentWindowInsets = WindowInsets(0),
        bottomBar = {
            NavigationBar(containerColor = Surface1) {
                Tab.entries.forEach { tab ->
                    NavigationBarItem(
                        selected = App.tab == tab,
                        onClick = { App.selectTab(tab) },
                        icon = { Icon(tab.icon, contentDescription = tab.title) },
                        label = { Text(tab.title) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = AccentTeal,
                            selectedTextColor = AccentTeal,
                            indicatorColor = AccentTeal.copy(alpha = 0.16f),
                            unselectedIconColor = Secondary,
                            unselectedTextColor = Secondary,
                        ),
                    )
                }
            }
        },
    ) { padding ->
        val stack = App.stacks.getValue(App.tab)
        val route = stack.lastOrNull()
        val key = App.tab.name + "/" + (route?.key ?: "root")
        val space = miniPlayerSpace()
        AnimatedContent(
            targetState = Triple(key, App.tab, route),
            transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(120)) },
            contentKey = { it.first },
            label = "pages",
            modifier = Modifier.fillMaxSize(),
        ) { (pageKey, tab, page) ->
            holder.SaveableStateProvider(pageKey) {
                Box(Modifier.fillMaxSize().background(Color.Black)) {
                    Page(tab, page, padding, space)
                }
            }
        }
    }
}

@Composable
private fun Page(tab: Tab, route: Route?, padding: PaddingValues, space: Dp) {
    when (route) {
        null -> when (tab) {
            Tab.Following -> FollowingScreen(padding, space)
            Tab.Browse -> BrowseScreen(padding, space)
            Tab.Search -> SearchScreen(padding, space)
            Tab.Settings -> SettingsScreen(padding, space)
        }
        is Route.ChannelPage -> ChannelScreen(route.channel, padding, space)
        is Route.CategoryPage -> CategoryScreen(route.category, padding, space)
        Route.AdBlocking -> AdBlockingScreen(padding, space)
        Route.ActivityLog -> ActivityLogScreen(padding, space)
    }
}
