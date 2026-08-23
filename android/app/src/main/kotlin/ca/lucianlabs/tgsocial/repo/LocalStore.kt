package ca.lucianlabs.tgsocial.repo

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import ca.lucianlabs.tgsocial.model.MyNode
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.protocol.FeedOrder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

private val Context.prefs: DataStore<Preferences> by preferencesDataStore(name = "tgsocial")

/** PRODUCT §2.3 — the persisted feed cache carries a schema version; a mismatch discards it. */
@Serializable
private data class FeedCache(val schemaVersion: Int = 0, val posts: List<Post> = emptyList())

/** Same versioning for the card cache. */
@Serializable
private data class CardCache(val schemaVersion: Int = 0, val cards: List<NodeSnapshot> = emptyList())

/**
 * PROTOCOL §6 — the only local state besides TDLib's own database: the myNode pointer, the card cache,
 * the last feed page (cold start), UI prefs. Sign-out wipes all of it.
 */
class LocalStore(private val context: Context) {
    companion object {
        /**
         * Bump whenever the shape or the ordering contract of a persisted payload changes. A cache written by
         * an earlier build (a different version, or the unversioned bare-list format) is discarded on load —
         * a feed cached by an older build MUST NOT paint in old order (PRODUCT §2.3). v2: versioned envelope
         * + post attribution fields.
         */
        const val SCHEMA_VERSION = 2
    }

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val myNodeKey = stringPreferencesKey("myNode")
    private val lastTabKey = stringPreferencesKey("lastTab")
    private val setupSkippedKey = stringPreferencesKey("setupSkipped")

    private val cardCacheFile get() = File(context.filesDir, "cards.json")
    private val feedCacheFile get() = File(context.filesDir, "feed.json")

    suspend fun myNode(): MyNode? = runCatching {
        context.prefs.data.first()[myNodeKey]?.let { json.decodeFromString(MyNode.serializer(), it) }
    }.getOrNull()

    suspend fun saveMyNode(node: MyNode?) {
        context.prefs.edit { p -> if (node == null) p.remove(myNodeKey) else p[myNodeKey] = json.encodeToString(MyNode.serializer(), node) }
    }

    suspend fun lastTab(): Int = context.prefs.data.first()[lastTabKey]?.toIntOrNull() ?: 0
    suspend fun saveLastTab(i: Int) { context.prefs.edit { it[lastTabKey] = i.toString() } }

    suspend fun setupSkipped(): Boolean = context.prefs.data.first()[setupSkippedKey] == "1"
    suspend fun saveSetupSkipped(v: Boolean) { context.prefs.edit { it[setupSkippedKey] = if (v) "1" else "0" } }

    suspend fun loadCards(): Map<String, NodeSnapshot> = withContext(Dispatchers.IO) {
        runCatching {
            if (!cardCacheFile.exists()) emptyMap()
            else {
                // An unversioned (bare list) or differently-versioned payload fails to decode or mismatches — discarded.
                val cache = json.decodeFromString(CardCache.serializer(), cardCacheFile.readText())
                if (cache.schemaVersion != SCHEMA_VERSION) emptyMap()
                else cache.cards.associateBy { it.username.lowercase() }
            }
        }.getOrDefault(emptyMap())
    }

    suspend fun saveCards(cards: Collection<NodeSnapshot>) = withContext(Dispatchers.IO) {
        runCatching { cardCacheFile.writeText(json.encodeToString(CardCache.serializer(), CardCache(SCHEMA_VERSION, cards.take(400)))) }
    }

    suspend fun loadFeed(): List<Post> = withContext(Dispatchers.IO) {
        runCatching {
            if (!feedCacheFile.exists()) emptyList()
            else {
                val cache = json.decodeFromString(FeedCache.serializer(), feedCacheFile.readText())
                // Version mismatch discards; a matching page is still re-sorted newest first defensively (PRODUCT §2.3).
                if (cache.schemaVersion != SCHEMA_VERSION) emptyList() else FeedOrder.sort(cache.posts)
            }
        }.getOrDefault(emptyList())
    }

    suspend fun saveFeed(posts: List<Post>) = withContext(Dispatchers.IO) {
        runCatching { feedCacheFile.writeText(json.encodeToString(FeedCache.serializer(), FeedCache(SCHEMA_VERSION, posts.take(40)))) }
    }

    /** Sign out: everything goes. */
    suspend fun wipe() {
        context.prefs.edit { it.clear() }
        withContext(Dispatchers.IO) {
            cardCacheFile.delete()
            feedCacheFile.delete()
            File(context.cacheDir, "images").deleteRecursively()
            File(context.cacheDir, "upload").deleteRecursively()
        }
    }
}
