package app.kestrel.player

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import app.kestrel.MainActivity
import app.kestrel.ui.App

/**
 * Keeps playback going in the background, with the media notification and lock screen controls
 * (title, channel, play/pause and, for VODs, the progress bar and skips).
 */
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        session = MediaSession.Builder(this, KestrelPlayer.player)
            .setSessionActivity(pending)
            .build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    /** Swiped away from recent apps: stop, like closing the player. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        App.closePlayer()
        stopSelf()
    }

    override fun onDestroy() {
        session?.release()
        session = null
        super.onDestroy()
    }
}
