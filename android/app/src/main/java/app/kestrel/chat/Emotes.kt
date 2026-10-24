package app.kestrel.chat

import app.kestrel.core.Http
import app.kestrel.core.Prefs
import app.kestrel.core.arr
import app.kestrel.core.fetch
import app.kestrel.core.obj
import app.kestrel.core.objects
import app.kestrel.core.str
import app.kestrel.core.strings
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import org.json.JSONArray
import org.json.JSONObject

/** An emote you can type: its name and picture. */
data class NamedEmote(val name: String, val url: String)

/** 7TV, BTTV and FFZ emotes for a channel, by provider (for the picker) and merged by name (for messages). */
data class ThirdPartyEmoteSets(
    val channel: List<Section> = emptyList(),
    val global: List<Section> = emptyList(),
    val byName: Map<String, String> = emptyMap(),
) {
    data class Section(val title: String, val emotes: List<NamedEmote>)
}

object ThirdPartyEmotes {
    suspend fun load(channelID: String?): ThirdPartyEmoteSets = coroutineScope {
        val seventvGlobal = async<Map<String, String>> { fetchObject("https://7tv.io/v3/emote-sets/global")?.let { parse7TV(it.arr("emotes")) } ?: emptyMap() }
        val bttvGlobal = async<Map<String, String>> { fetchArray("https://api.betterttv.net/3/cached/emotes/global")?.let { parseBTTV(it.objects()) } ?: emptyMap() }
        val ffzGlobal = async<Map<String, String>> { fetchObject("https://api.frankerfacez.com/v1/set/global")?.let { parseFFZ(it.obj("sets")) } ?: emptyMap() }
        val channel7TV = async<Map<String, String>> {
            if (channelID == null) emptyMap() else fetchObject("https://7tv.io/v3/users/twitch/$channelID")
                ?.let { parse7TV(it.obj("emote_set")?.arr("emotes")) } ?: emptyMap()
        }
        val channelBTTV = async<Map<String, String>> {
            if (channelID == null) emptyMap() else fetchObject("https://api.betterttv.net/3/cached/users/twitch/$channelID")
                ?.let { parseBTTV(it.arr("channelEmotes").objects() + it.arr("sharedEmotes").objects()) } ?: emptyMap()
        }
        val channelFFZ = async<Map<String, String>> {
            if (channelID == null) emptyMap() else fetchObject("https://api.frankerfacez.com/v1/room/id/$channelID")
                ?.let { parseFFZ(it.obj("sets")) } ?: emptyMap()
        }
        val g7 = seventvGlobal.await()
        val gb = bttvGlobal.await()
        val gf = ffzGlobal.await()
        val c7 = channel7TV.await()
        val cb = channelBTTV.await()
        val cf = channelFFZ.await()
        // Lowest priority first; the channel's 7TV emotes win on name clashes.
        val byName = HashMap<String, String>()
        for (map in listOf(gf, gb, g7, cf, cb, c7)) byName.putAll(map)
        fun section(title: String, map: Map<String, String>): ThirdPartyEmoteSets.Section? {
            if (map.isEmpty()) return null
            return ThirdPartyEmoteSets.Section(
                title,
                map.map { NamedEmote(it.key, it.value) }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name }),
            )
        }
        ThirdPartyEmoteSets(
            channel = listOfNotNull(section("7TV", c7), section("BTTV", cb), section("FFZ", cf)),
            global = listOfNotNull(section("7TV global", g7), section("BTTV global", gb), section("FFZ global", gf)),
            byName = byName,
        )
    }

    private suspend fun fetchText(url: String, timeoutSeconds: Long = 10): String? = runCatching {
        val result = Http.withTimeout(timeoutSeconds).fetch(Http.get(url))
        if (result.code == 200) result.body else null
    }.getOrNull()

    private suspend fun fetchObject(url: String): JSONObject? = fetchText(url)?.let { runCatching { JSONObject(it) }.getOrNull() }
    private suspend fun fetchArray(url: String): JSONArray? = fetchText(url)?.let { runCatching { JSONArray(it) }.getOrNull() }

    fun parse7TV(emotes: JSONArray?): Map<String, String> {
        val result = HashMap<String, String>()
        for (emote in emotes.objects()) {
            val name = emote.str("name") ?: continue
            val host = emote.obj("data")?.obj("host") ?: continue
            val hostUrl = host.str("url") ?: continue
            val base = if (hostUrl.startsWith("//")) "https:$hostUrl" else hostUrl
            val files = host.arr("files").objects().mapNotNull { it.str("name") }
            val file = files.firstOrNull { it == "2x.webp" } ?: files.firstOrNull { it.endsWith(".webp") } ?: "2x.webp"
            result[name] = "$base/$file"
        }
        return result
    }

    fun parseBTTV(emotes: List<JSONObject>): Map<String, String> {
        val result = HashMap<String, String>()
        for (emote in emotes) {
            val id = emote.str("id") ?: continue
            val code = emote.str("code") ?: continue
            result[code] = "https://cdn.betterttv.net/emote/$id/2x.webp"
        }
        return result
    }

    fun parseFFZ(sets: JSONObject?): Map<String, String> {
        val result = HashMap<String, String>()
        if (sets == null) return result
        for (key in sets.keys()) {
            val set = sets.optJSONObject(key) ?: continue
            for (emote in set.arr("emoticons").objects()) {
                val name = emote.str("name") ?: continue
                val urls = emote.obj("urls") ?: continue
                var link = urls.str("2") ?: urls.str("1") ?: continue
                if (link.startsWith("//")) link = "https:$link"
                result[name] = link
            }
        }
        return result
    }

    /** Last messages from before you joined (recent-messages.robotty.de). */
    suspend fun recentMessages(login: String): List<IrcMessage> {
        val json = fetchObject("https://recent-messages.robotty.de/api/v2/recent-messages/${login.lowercase()}?limit=100")
            ?: return emptyList()
        return json.arr("messages").strings().mapNotNull { IrcMessage.parse(it) }
    }
}

/** Emotes you used lately, across channels. */
object RecentEmotes {
    private const val KEY = "recentEmotes"

    val names: List<String>
        get() = Prefs.string(KEY)?.let { runCatching { JSONArray(it).strings() }.getOrNull() } ?: emptyList()

    fun add(used: List<String>) {
        val list = (used + names.filter { it !in used }).take(36)
        Prefs.setString(KEY, JSONArray(list).toString())
    }
}
