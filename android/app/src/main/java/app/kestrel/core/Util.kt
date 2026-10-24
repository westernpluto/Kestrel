package app.kestrel.core

import android.text.format.DateUtils
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.OffsetDateTime
import java.util.Locale

/** What Kestrel did and why (Settings → Activity log). */
object ActivityLog {
    data class Entry(val time: Long, val message: String)

    private val _entries = MutableStateFlow<List<Entry>>(emptyList())
    val entries: StateFlow<List<Entry>> = _entries

    fun add(message: String) {
        _entries.update { (it + Entry(System.currentTimeMillis(), message)).takeLast(400) }
        android.util.Log.i("Kestrel", message)
    }

    fun clear() {
        _entries.value = emptyList()
    }
}

// MARK: JSON (org.json, which treats missing and null alike here)

fun JSONObject.str(key: String): String? {
    if (!has(key) || isNull(key)) return null
    val value = opt(key)
    return when (value) {
        is String -> value
        is Number, is Boolean -> value.toString()
        else -> null
    }
}

fun JSONObject.int(key: String): Int? {
    if (!has(key) || isNull(key)) return null
    return when (val value = opt(key)) {
        is Number -> value.toInt()
        is String -> value.toIntOrNull()
        else -> null
    }
}

fun JSONObject.double(key: String): Double? {
    if (!has(key) || isNull(key)) return null
    return when (val value = opt(key)) {
        is Number -> value.toDouble()
        is String -> value.toDoubleOrNull()
        else -> null
    }
}

fun JSONObject.bool(key: String): Boolean? {
    if (!has(key) || isNull(key)) return null
    return when (val value = opt(key)) {
        is Boolean -> value
        is Number -> value.toInt() != 0
        is String -> value.equals("true", ignoreCase = true)
        else -> null
    }
}

fun JSONObject.obj(key: String): JSONObject? = if (!has(key) || isNull(key)) null else optJSONObject(key)

fun JSONObject.arr(key: String): JSONArray? = if (!has(key) || isNull(key)) null else optJSONArray(key)

/** Follows a path of object keys ("data", "user", …). */
fun JSONObject.at(vararg keys: String): JSONObject? {
    var current: JSONObject? = this
    for (key in keys) current = current?.obj(key)
    return current
}

fun JSONArray?.objects(): List<JSONObject> {
    if (this == null) return emptyList()
    val result = ArrayList<JSONObject>(length())
    for (i in 0 until length()) optJSONObject(i)?.let { result.add(it) }
    return result
}

fun JSONArray?.strings(): List<String> {
    if (this == null) return emptyList()
    val result = ArrayList<String>(length())
    for (i in 0 until length()) {
        val value = opt(i)
        if (value is String) result.add(value)
    }
    return result
}

// MARK: Dates (epoch milliseconds)

fun parseDate(text: String?): Long? {
    if (text.isNullOrBlank()) return null
    val trimmed = text.trim()
    return runCatching { OffsetDateTime.parse(trimmed).toInstant().toEpochMilli() }.getOrNull()
        ?: runCatching { Instant.parse(trimmed).toEpochMilli() }.getOrNull()
}

// MARK: Formatting

object Format {
    fun viewers(n: Int): String = when {
        n >= 1_000_000 -> String.format(Locale.US, "%.1fM", n / 1_000_000.0)
        n >= 10_000 -> "${n / 1000}K"
        n >= 1000 -> String.format(Locale.US, "%.1fK", n / 1000.0)
        else -> n.toString()
    }

    fun duration(totalSeconds: Long): String {
        val s = totalSeconds.coerceAtLeast(0)
        val h = s / 3600
        val m = s % 3600 / 60
        val sec = s % 60
        return if (h > 0) String.format(Locale.US, "%d:%02d:%02d", h, m, sec) else String.format(Locale.US, "%d:%02d", m, sec)
    }

    fun uptime(since: Long?): String? {
        if (since == null) return null
        val seconds = ((System.currentTimeMillis() - since) / 1000).coerceAtLeast(0)
        return String.format(Locale.US, "%d:%02d", seconds / 3600, seconds % 3600 / 60)
    }

    fun relative(time: Long?): String {
        if (time == null) return ""
        return DateUtils.getRelativeTimeSpanString(time, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
    }

    fun mbps(bitsPerSecond: Long): String =
        if (bitsPerSecond <= 0) "–" else String.format(Locale.US, "%.2f Mbps", bitsPerSecond / 1_000_000.0)

    fun seconds(value: Double?): String = if (value == null) "–" else String.format(Locale.US, "%.2f s", value)
}
