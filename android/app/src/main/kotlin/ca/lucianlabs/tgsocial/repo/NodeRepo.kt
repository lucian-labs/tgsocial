package ca.lucianlabs.tgsocial.repo

import ca.lucianlabs.tgsocial.model.FeedSource
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.protocol.Backlink
import ca.lucianlabs.tgsocial.protocol.CardFormat
import ca.lucianlabs.tgsocial.protocol.CardParse
import ca.lucianlabs.tgsocial.protocol.Username
import ca.lucianlabs.tgsocial.td.TdError
import ca.lucianlabs.tgsocial.td.TelegramClient
import ca.lucianlabs.tgsocial.td.orNull
import dev.g000sha256.tdl.dto.Chat
import dev.g000sha256.tdl.dto.MessageOrigin
import dev.g000sha256.tdl.dto.MessageOriginChannel
import dev.g000sha256.tdl.dto.MessageOriginChat
import dev.g000sha256.tdl.dto.MessageOriginUser
import dev.g000sha256.tdl.dto.MessageText
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** PROTOCOL §4.5 — read any node; cache parsed cards by username with `fetchedAt`. */
class NodeRepo(private val tg: TelegramClient, private val store: LocalStore, private val activity: ActivityRegistry) {
    private val _cards = MutableStateFlow<Map<String, NodeSnapshot>>(emptyMap())
    val cards: StateFlow<Map<String, NodeSnapshot>> = _cards.asStateFlow()

    private val feedSources = HashMap<String, FeedSource>()
    private val originNames = HashMap<String, String>()
    private val lock = Mutex()

    suspend fun restore() {
        _cards.value = store.loadCards()
    }

    fun cached(username: String): NodeSnapshot? = _cards.value[Username.key(username)]

    fun put(snapshot: NodeSnapshot) {
        _cards.value = _cards.value + (Username.key(snapshot.username) to snapshot)
    }

    suspend fun persist() = store.saveCards(_cards.value.values)

    fun clear() {
        _cards.value = emptyMap()
        feedSources.clear()
        originNames.clear()
    }

    /** Cached copy if fresh enough, otherwise fetched. Throws [TdError] when offline and nothing is cached. */
    suspend fun node(username: String, maxAgeMs: Long = 10 * 60 * 1000L): NodeSnapshot {
        val c = cached(username)
        if (c != null && System.currentTimeMillis() - c.fetchedAt < maxAgeMs) return c
        if (c != null && tg.isOffline) return c
        return try {
            fetch(username)
        } catch (e: TdError) {
            if (c != null && e.code != 400 && e.code != 404) c else throw e
        }
    }

    /** Always hits Telegram. */
    suspend fun fetch(username: String): NodeSnapshot = activity.track("Reading card @$username") {
        val chat = tg.call { searchPublicChat(username = username) }
        val snapshot = read(chat, username)
        put(snapshot)
        snapshot
    }

    /** Read a chat as a node: pinned card (authoritative) + description + photo. */
    suspend fun read(chat: Chat, usernameHint: String? = null): NodeSnapshot {
        val sgId = chat.supergroupId
        val sg = if (sgId != 0L) tg.callOrNull { getSupergroup(supergroupId = sgId) } else null
        val username = sg?.username ?: usernameHint ?: ""
        val full = if (sgId != 0L) tg.callOrNull { getSupergroupFullInfo(supergroupId = sgId) } else null
        val pinned = if (chat.isChannel) tg.callOrNull { getChatPinnedMessage(chatId = chat.id) } else null
        val text = (pinned?.content as? MessageText)?.text?.text
        val parse = text?.let { CardFormat.parse(it) } ?: CardParse.NotACard
        return NodeSnapshot(
            username = username,
            chatId = chat.id,
            supergroupId = sgId,
            title = chat.title,
            description = full?.description.orEmpty(),
            photo = chat.photo?.small?.ref(),
            card = parse.cardOrNull,
            newerVersion = parse is CardParse.Newer,
            pinnedMessageId = pinned?.id ?: 0L,
            fetchedAt = System.currentTimeMillis(),
        )
    }

    /**
     * A feed channel resolved by username; cached for the session. `listedBy` accumulates across calls — a refresh
     * re-reads the channel but keeps every node known to list it, so the Verified pill survives a refetch.
     * Offline, or when Telegram does not answer, the cached source is served.
     */
    suspend fun feedSource(username: String, listedBy: List<String> = emptyList(), refresh: Boolean = false): FeedSource? {
        val key = Username.key(username)
        val existing = lock.withLock { feedSources[key] }
        val listing = (existing?.listedBy.orEmpty() + listedBy).distinct()
        val served = existing?.let { merge(it, listing) }
        if (served != null && (!refresh || tg.isOffline)) {
            lock.withLock { feedSources[key] = served }
            return served
        }
        val chat = try {
            tg.call { searchPublicChat(username = username) }
        } catch (e: TdError) {
            return if (e.code == 400 || e.code == 404) null else served
        } catch (e: TimeoutCancellationException) {
            return served
        }
        if (!chat.isChannel) return null
        val sgId = chat.supergroupId
        val sg = tg.callOrNull { getSupergroup(supergroupId = sgId) }
        val full = tg.callOrNull { getSupergroupFullInfo(supergroupId = sgId) }
        val description = full?.description.orEmpty()
        val source = FeedSource(
            username = sg?.username ?: username,
            chatId = chat.id,
            supergroupId = sgId,
            title = chat.title,
            description = description,
            photo = chat.photo?.small?.ref(),
            listedBy = listing,
            verifiedFor = verifiedFor(description, listing),
        )
        lock.withLock { feedSources[key] = source }
        originNames["chat:${chat.id}"] = chat.title
        return source
    }

    private fun merge(source: FeedSource, listedBy: List<String>): FeedSource =
        source.copy(listedBy = listedBy, verifiedFor = verifiedFor(source.description, listedBy))

    fun cachedFeedSource(username: String): FeedSource? = feedSources[Username.key(username)]

    private fun verifiedFor(description: String, nodes: List<String>): List<String> = nodes.filter { Backlink.isVerified(description, it) }

    /** "Forwarded from <origin>" — resolved lazily and memoised. */
    suspend fun originName(origin: MessageOrigin): String? {
        val key = when (origin) {
            is MessageOriginChannel -> "chat:${origin.chatId}"
            is MessageOriginChat -> "chat:${origin.senderChatId}"
            is MessageOriginUser -> "user:${origin.senderUserId}"
            else -> return null
        }
        originNames[key]?.let { return it }
        val name = when (origin) {
            is MessageOriginChannel -> tg.callOrNull { getChat(chatId = origin.chatId) }?.title
            is MessageOriginChat -> tg.callOrNull { getChat(chatId = origin.senderChatId) }?.title
            is MessageOriginUser -> tg.callOrNull { getUser(userId = origin.senderUserId) }?.let { "${it.firstName} ${it.lastName}".trim() }
            else -> null
        } ?: return null
        originNames[key] = name
        return name
    }
}
