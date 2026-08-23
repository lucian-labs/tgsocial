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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File

private val Context.prefs: DataStore<Preferences> by preferencesDataStore(name = "tgsocial")

/**
 * PROTOCOL §6 — the only local state besides TDLib's own database: the myNode pointer, the card cache,
 * the last feed page (cold start), UI prefs. Sign-out wipes all of it.
 */
class LocalStore(private val context: Context) {
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
            else json.decodeFromString(ListSerializer(NodeSnapshot.serializer()), cardCacheFile.readText()).associateBy { it.username.lowercase() }
        }.getOrDefault(emptyMap())
    }

    suspend fun saveCards(cards: Collection<NodeSnapshot>) = withContext(Dispatchers.IO) {
        runCatching { cardCacheFile.writeText(json.encodeToString(ListSerializer(NodeSnapshot.serializer()), cards.take(400))) }
    }

    suspend fun loadFeed(): List<Post> = withContext(Dispatchers.IO) {
        runCatching {
            if (!feedCacheFile.exists()) emptyList()
            else json.decodeFromString(ListSerializer(Post.serializer()), feedCacheFile.readText())
        }.getOrDefault(emptyList())
    }

    suspend fun saveFeed(posts: List<Post>) = withContext(Dispatchers.IO) {
        runCatching { feedCacheFile.writeText(json.encodeToString(ListSerializer(Post.serializer()), posts.take(40))) }
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
