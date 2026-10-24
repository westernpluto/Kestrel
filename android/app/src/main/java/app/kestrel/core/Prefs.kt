package app.kestrel.core

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.json.JSONObject
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/** The application, for code that runs outside any screen. Set first thing at launch. */
object Kestrel {
    lateinit var app: Application

    /** An unexpected error in background work goes to the activity log instead of closing the app. */
    val errors = CoroutineExceptionHandler { _, error ->
        ActivityLog.add("Unexpected error: ${error.message ?: error.javaClass.simpleName}")
    }

    /** Work that outlives a screen (on the main thread unless it switches). */
    val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate + errors)
}

/** Kestrel's settings and saved data (private to the app; removed with it). */
object Prefs {
    val prefs: SharedPreferences by lazy { Kestrel.app.getSharedPreferences("kestrel", Context.MODE_PRIVATE) }

    fun string(key: String): String? = prefs.getString(key, null)
    fun setString(key: String, value: String?) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }

    fun json(key: String): JSONObject? = string(key)?.let { runCatching { JSONObject(it) }.getOrNull() }
    fun setJson(key: String, value: JSONObject?) = setString(key, value?.toString())

    fun bool(key: String, default: Boolean = false): Boolean = prefs.getBoolean(key, default)
    fun setBool(key: String, value: Boolean) = prefs.edit().putBoolean(key, value).apply()
}

/** A saved setting that Compose screens redraw for. */
class BoolPref(private val key: String, private val default: Boolean) : ReadWriteProperty<Any?, Boolean> {
    private val state by lazy { mutableStateOf(Prefs.prefs.getBoolean(key, default)) }
    override fun getValue(thisRef: Any?, property: KProperty<*>): Boolean = state.value
    override fun setValue(thisRef: Any?, property: KProperty<*>, value: Boolean) {
        state.value = value
        Prefs.prefs.edit().putBoolean(key, value).apply()
    }
}

class StringPref(private val key: String, private val default: String) : ReadWriteProperty<Any?, String> {
    private val state by lazy { mutableStateOf(Prefs.prefs.getString(key, default) ?: default) }
    override fun getValue(thisRef: Any?, property: KProperty<*>): String = state.value
    override fun setValue(thisRef: Any?, property: KProperty<*>, value: String) {
        state.value = value
        Prefs.prefs.edit().putString(key, value).apply()
    }
}

class FloatPref(private val key: String, private val default: Float) : ReadWriteProperty<Any?, Float> {
    private val state by lazy { mutableStateOf(Prefs.prefs.getFloat(key, default)) }
    override fun getValue(thisRef: Any?, property: KProperty<*>): Float = state.value
    override fun setValue(thisRef: Any?, property: KProperty<*>, value: Float) {
        state.value = value
        Prefs.prefs.edit().putFloat(key, value).apply()
    }
}
