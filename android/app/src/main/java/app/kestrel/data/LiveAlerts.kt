package app.kestrel.data

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.graphics.drawable.toBitmap
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ListenableWorker
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import app.kestrel.MainActivity
import app.kestrel.R
import app.kestrel.core.ActivityLog
import app.kestrel.core.Kestrel
import app.kestrel.core.LiveStream
import app.kestrel.core.Prefs
import app.kestrel.core.TwitchApi
import app.kestrel.core.strings
import coil.imageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Go-live alerts for the channels you follow. A sideloaded app has no push server, so Kestrel
 * checks by itself: every minute while it's open or playing, and every 15 minutes or so in the
 * background (Android decides exactly when). Tapping an alert opens the stream.
 */
object LiveNotifier {
    const val CHANNEL_ID = "live"
    private const val WORK_NAME = "kestrel.live-check"
    const val EXTRA_CHANNEL_ID = "kestrel.channelID"
    const val EXTRA_LOGIN = "kestrel.login"
    const val EXTRA_DISPLAY_NAME = "kestrel.displayName"
    const val EXTRA_AVATAR = "kestrel.avatar"

    var enabled by mutableStateOf(Prefs.bool("liveAlerts.enabled"))
        private set

    private var knownLive: Set<String> =
        Prefs.string("liveAlerts.known")?.let { runCatching { JSONArray(it).strings().toSet() }.getOrNull() } ?: emptySet()
    private val announced: MutableMap<String, Long> = HashMap<String, Long>().apply {
        Prefs.json("liveAlerts.announced")?.let { json -> for (key in json.keys()) put(key, json.optLong(key)) }
    }
    private var seeded = Prefs.bool("liveAlerts.seeded")
    private var polling: Job? = null
    private var lastCheck = 0L

    fun createChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(CHANNEL_ID, "Go-live alerts", NotificationManager.IMPORTANCE_DEFAULT)
        channel.description = "A channel you follow started streaming"
        manager.createNotificationChannel(channel)
    }

    fun updateEnabled(on: Boolean) {
        val context = Kestrel.app
        enabled = on
        Prefs.setBool("liveAlerts.enabled", on)
        if (on) {
            // Whoever's live right now isn't news: only streams that start from here on are announced.
            seeded = false
            Prefs.setBool("liveAlerts.seeded", false)
            ActivityLog.add("Go-live alerts on")
            schedule(context)
            startPolling()
            Kestrel.scope.launch { FollowingStore.refresh(force = true) }
        } else {
            polling?.cancel()
            polling = null
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            ActivityLog.add("Go-live alerts off")
        }
    }

    /** Background checks (Android runs them about every 15 minutes, when there's a connection). */
    fun schedule(context: Context) {
        if (!enabled) return
        val request = PeriodicWorkRequestBuilder<LiveCheckWorker>(15, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    /** While the app runs: a check a minute. */
    fun startPolling() {
        if (!enabled || polling?.isActive == true) return
        polling = Kestrel.scope.launch {
            while (isActive) {
                if (System.currentTimeMillis() - lastCheck > 50_000) checkNow()
                delay(60_000)
            }
        }
    }

    fun stopPolling() {
        polling?.cancel()
        polling = null
    }

    suspend fun checkNow() {
        if (!enabled) return
        lastCheck = System.currentTimeMillis()
        // The follows list does the fetching; it reports back to `observe`.
        FollowingStore.refresh(force = true)
    }

    /** Every refresh of the follows list ends here. `complete`: it loaded without errors. */
    fun observe(live: List<LiveStream>, complete: Boolean) {
        if (!enabled || !complete) return
        val now = System.currentTimeMillis()
        val ids = live.map { it.channel.id }.toSet()
        announced.entries.removeAll { now - it.value > 24 * 3600_000L }
        if (seeded) {
            val watching = app.kestrel.ui.App.watchingChannelId
            for (stream in live) {
                if (stream.channel.id in knownLive || announced.containsKey(stream.id)) continue
                if (stream.channel.id == watching) continue
                // Seen late (e.g. the phone was off): still worth a heads-up, but not for streams on for hours.
                val started = stream.startedAt
                if (started != null && now - started > 3 * 3600_000L) continue
                announced[stream.id] = now
                post(stream)
            }
        } else {
            seeded = true
            Prefs.setBool("liveAlerts.seeded", true)
            for (stream in live) announced[stream.id] = now
        }
        knownLive = ids
        Prefs.setString("liveAlerts.known", JSONArray(ids.toList()).toString())
        val json = JSONObject()
        for ((key, value) in announced) json.put(key, value)
        Prefs.setJson("liveAlerts.announced", json)
    }

    private fun post(stream: LiveStream) {
        val context = Kestrel.app
        ActivityLog.add("Go-live alert: ${stream.channel.name}")
        Kestrel.scope.launch {
            val avatar = avatar(context, TwitchApi.image(stream.channel.profileImageURL, 150, 150))
            val intent = Intent(context, MainActivity::class.java).apply {
                action = "app.kestrel.OPEN_LIVE"
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(EXTRA_CHANNEL_ID, stream.channel.id)
                putExtra(EXTRA_LOGIN, stream.channel.login)
                putExtra(EXTRA_DISPLAY_NAME, stream.channel.displayName)
                putExtra(EXTRA_AVATAR, stream.channel.profileImageURL ?: "")
            }
            val pending = PendingIntent.getActivity(
                context, stream.channel.id.hashCode(), intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            var body = stream.title.ifEmpty { "Started streaming" }
            stream.category?.name?.takeIf { it.isNotEmpty() }?.let { body += "\n$it" }
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("${stream.channel.name} is live")
                .setContentText(stream.title.ifEmpty { "Started streaming" })
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(pending)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_SOCIAL)
                .setGroup("live")
            if (avatar != null) builder.setLargeIcon(avatar)
            try {
                val manager = NotificationManagerCompat.from(context)
                if (manager.areNotificationsEnabled()) manager.notify("live", stream.channel.id.hashCode(), builder.build())
            } catch (e: SecurityException) {
                ActivityLog.add("Notifications aren't allowed for Kestrel")
            }
        }
    }

    private suspend fun avatar(context: Context, url: String?): Bitmap? {
        if (url == null) return null
        val request = ImageRequest.Builder(context).data(url).allowHardware(false).size(150).build()
        val result = context.imageLoader.execute(request)
        return (result as? SuccessResult)?.drawable?.toBitmap()
    }
}

/** The background check for go-live alerts. */
class LiveCheckWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): ListenableWorker.Result {
        if (!LiveNotifier.enabled) return ListenableWorker.Result.success()
        LiveNotifier.checkNow()
        // Give the notifications (and their pictures) a moment to be handed over.
        delay(2000)
        return ListenableWorker.Result.success()
    }
}
