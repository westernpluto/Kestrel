package app.kestrel.core

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build

/** Which video codecs this device decodes in hardware, in Twitch's `supported_codecs` format. */
object DeviceCodecs {
    val hevc: Boolean by lazy { hardwareDecoder("video/hevc") }
    val av1: Boolean by lazy { hardwareDecoder("video/av01") }

    private fun hardwareDecoder(mime: String): Boolean = runCatching {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) } && isHardware(info) &&
                (info.getCapabilitiesForType(mime).videoCapabilities?.isSizeSupported(2560, 1440) ?: false)
        }
    }.getOrDefault(false)

    private fun isHardware(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return info.isHardwareAccelerated
        val name = info.name.lowercase()
        return !(name.startsWith("omx.google.") || name.startsWith("c2.android.") || name.contains(".sw."))
    }

    /**
     * e.g. "h265,av1,h264". Twitch only lists 1440p (Enhanced Broadcasting) renditions when the
     * request says the player can decode HEVC or AV1. HEVC first: more players handle it.
     */
    val enhanced: String
        get() {
            val codecs = mutableListOf<String>()
            if (hevc) codecs.add("h265")
            if (av1) codecs.add("av1")
            codecs.add("h264")
            return codecs.joinToString(",")
        }

    /** What the Settings screen shows. */
    val summary: String
        get() = when {
            hevc && av1 -> "AV1 + HEVC"
            hevc -> "HEVC"
            av1 -> "AV1"
            else -> "H.264 only"
        }

    /** The next, more conservative codec list to try after `codecs` failed to play. */
    fun fallback(after: String): String? {
        val list = after.split(',')
        if (list.size <= 1) return null
        return list.drop(1).joinToString(",")
    }
}
