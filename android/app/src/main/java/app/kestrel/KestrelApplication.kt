package app.kestrel

import android.app.Application
import android.os.Build
import app.kestrel.core.Kestrel
import app.kestrel.data.AppSettings
import app.kestrel.data.LiveNotifier
import app.kestrel.data.TwitchAccount
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder

class KestrelApplication : Application(), ImageLoaderFactory {
    override fun onCreate() {
        super.onCreate()
        Kestrel.app = this
        AppSettings.applyProxy()
        TwitchAccount.load()
        LiveNotifier.createChannel(this)
        if (LiveNotifier.enabled) LiveNotifier.schedule(this)
    }

    /** Animated emotes (GIF and animated WebP). */
    override fun newImageLoader(): ImageLoader = ImageLoader.Builder(this)
        .components {
            if (Build.VERSION.SDK_INT >= 28) add(ImageDecoderDecoder.Factory()) else add(GifDecoder.Factory())
        }
        .crossfade(true)
        .respectCacheHeaders(false)
        .build()
}
