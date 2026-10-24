package app.kestrel.data

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.webkit.CookieManager
import android.webkit.WebStorage
import androidx.core.app.NotificationManagerCompat
import androidx.work.WorkManager
import app.kestrel.player.KestrelPlayer
import coil.imageLoader
import kotlin.system.exitProcess

/**
 * Starting from a blank slate. Uninstalling removes everything Kestrel stored (backups are off,
 * so a reinstall starts signed out). Settings → Reset Kestrel erases it all at any time.
 */
object AppReset {
    fun eraseEverything(activity: Activity) {
        KestrelPlayer.release()
        val context = activity.applicationContext
        runCatching { WorkManager.getInstance(context).cancelAllWork() }
        runCatching { NotificationManagerCompat.from(context).cancelAll() }
        // Android's own "Clear storage": settings, login, website data, caches. It closes the app.
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        if (manager?.clearApplicationUserData() == true) return
        // If that wasn't allowed, erase by hand.
        runCatching {
            CookieManager.getInstance().removeAllCookies(null)
            CookieManager.getInstance().flush()
            WebStorage.getInstance().deleteAllData()
        }
        runCatching { context.imageLoader.memoryCache?.clear() }
        val prefsDir = java.io.File(context.applicationInfo.dataDir, "shared_prefs")
        prefsDir.listFiles()?.forEach { file ->
            context.getSharedPreferences(file.nameWithoutExtension, Context.MODE_PRIVATE).edit().clear().commit()
            file.delete()
        }
        context.cacheDir.deleteRecursively()
        context.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        activity.finishAndRemoveTask()
        exitProcess(0)
    }
}
