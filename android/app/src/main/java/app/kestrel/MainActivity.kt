package app.kestrel

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Rational
import android.view.OrientationEventListener
import android.view.ViewGroup
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.Lifecycle
import app.kestrel.core.Channel
import app.kestrel.data.AppSettings
import app.kestrel.data.LiveNotifier
import app.kestrel.data.TwitchIntegrity
import app.kestrel.player.PlaybackTarget
import app.kestrel.ui.App
import app.kestrel.ui.KestrelRoot
import app.kestrel.ui.KestrelTheme
import kotlin.math.roundToInt

class MainActivity : ComponentActivity() {
    private lateinit var orientation: OrientationController
    private var pipEnabled = false
    private var pipAspect = 16f / 9f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        if (Build.VERSION.SDK_INT >= 28) {
            val attributes = window.attributes
            attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            window.attributes = attributes
        }
        orientation = OrientationController(this)
        App.requestOrientation = { landscape -> orientation.force(landscape) }
        App.requestPictureInPicture = { enterPip() }
        setContent { KestrelTheme { KestrelRoot() } }
        TwitchIntegrity.host = findViewById<ViewGroup>(android.R.id.content)
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** A go-live alert was tapped: open the stream. */
    private fun handle(intent: Intent?) {
        val id = intent?.getStringExtra(LiveNotifier.EXTRA_CHANNEL_ID) ?: return
        val login = intent.getStringExtra(LiveNotifier.EXTRA_LOGIN) ?: return
        val name = intent.getStringExtra(LiveNotifier.EXTRA_DISPLAY_NAME) ?: login
        val avatar = intent.getStringExtra(LiveNotifier.EXTRA_AVATAR)?.ifEmpty { null }
        intent.removeExtra(LiveNotifier.EXTRA_CHANNEL_ID)
        App.play(PlaybackTarget.Live(Channel(id, login, name, avatar)))
    }

    override fun onStart() {
        super.onStart()
        App.resumeCount++
        LiveNotifier.startPolling()
    }

    override fun onStop() {
        super.onStop()
        val player = App.player
        if (player != null && !isInPictureInPictureMode && !AppSettings.backgroundAudio) player.pause()
        if (player == null || player.isPaused) LiveNotifier.stopPolling()
        LiveNotifier.schedule(this)
    }

    override fun onDestroy() {
        TwitchIntegrity.host = null
        orientation.disable()
        super.onDestroy()
    }

    // MARK: Picture in picture

    fun updatePictureInPicture(enabled: Boolean, aspect: Float) {
        pipEnabled = enabled
        pipAspect = aspect
        runCatching { setPictureInPictureParams(pipParams()) }
    }

    private fun pipParams(): PictureInPictureParams {
        // Android allows 1:2.39 to 2.39:1.
        val ratio = (pipAspect * 1000).roundToInt().coerceIn(420, 2380)
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(ratio, 1000))
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setAutoEnterEnabled(pipEnabled)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    private fun enterPip() {
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return
        runCatching { enterPictureInPictureMode(pipParams()) }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < 31 && pipEnabled) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        App.inPictureInPicture = isInPictureInPictureMode
        // The floating window was closed: stop playing.
        if (!isInPictureInPictureMode && !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) App.player?.pause()
    }
}

/**
 * The full-screen button turns the screen and holds it there until the phone is turned that way;
 * from then on the phone's own rotation takes over again (when auto-rotate is on).
 */
class OrientationController(private val activity: Activity) {
    private var holding: Boolean? = null

    private val listener = object : OrientationEventListener(activity) {
        override fun onOrientationChanged(orientation: Int) {
            val hold = holding ?: return
            if (orientation == ORIENTATION_UNKNOWN) return
            val landscape = orientation in 60..120 || orientation in 240..300
            val portrait = orientation <= 30 || orientation >= 330
            if ((hold && landscape) || (!hold && portrait)) release()
        }
    }

    fun force(landscape: Boolean) {
        holding = landscape
        activity.requestedOrientation =
            if (landscape) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        if (autoRotate() && listener.canDetectOrientation()) listener.enable() else listener.disable()
    }

    private fun release() {
        holding = null
        listener.disable()
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }

    private fun autoRotate(): Boolean =
        Settings.System.getInt(activity.contentResolver, Settings.System.ACCELEROMETER_ROTATION, 0) == 1

    fun disable() {
        listener.disable()
    }
}
