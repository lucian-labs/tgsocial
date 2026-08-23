package ca.lucianlabs.tgsocial.repo

import ca.lucianlabs.tgsocial.model.FeedCandidate
import ca.lucianlabs.tgsocial.model.MyNode
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.protocol.Backlink
import ca.lucianlabs.tgsocial.protocol.Card
import ca.lucianlabs.tgsocial.protocol.CardFormat
import ca.lucianlabs.tgsocial.protocol.CardParse
import ca.lucianlabs.tgsocial.protocol.Username
import ca.lucianlabs.tgsocial.td.TdError
import ca.lucianlabs.tgsocial.td.TelegramClient
import ca.lucianlabs.tgsocial.td.orNull
import ca.lucianlabs.tgsocial.td.orThrow
import dev.g000sha256.tdl.TdlResult
import dev.g000sha256.tdl.dto.ChatListMain
import dev.g000sha256.tdl.dto.ChatMemberStatusAdministrator
import dev.g000sha256.tdl.dto.ChatMemberStatusCreator
import dev.g000sha256.tdl.dto.CheckChatUsernameResultOk
import dev.g000sha256.tdl.dto.CheckChatUsernameResultPublicChatsTooMany
import dev.g000sha256.tdl.dto.CheckChatUsernameResultUsernameInvalid
import dev.g000sha256.tdl.dto.CheckChatUsernameResultUsernameOccupied
import dev.g000sha256.tdl.dto.CheckChatUsernameResultUsernamePurchasable
import dev.g000sha256.tdl.dto.FormattedText
import dev.g000sha256.tdl.dto.InputChatPhotoStatic
import dev.g000sha256.tdl.dto.InputFileId
import dev.g000sha256.tdl.dto.InputMessageText
import dev.g000sha256.tdl.dto.LinkPreviewOptions
import dev.g000sha256.tdl.dto.MessageSendOptions
import dev.g000sha256.tdl.dto.MessageText
import dev.g000sha256.tdl.dto.PublicChatTypeHasUsername
import dev.g000sha256.tdl.dto.User
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

class CardFullException : Exception("Card is full.")

/** PROTOCOL §4.2–§4.4, §4.7, §5.3 — my node: find, create, write, feeds, backlink, announce. */
class MyNodeRepo(private val tg: TelegramClient, private val store: LocalStore, private val nodes: NodeRepo) {
    companion object {
        const val INDEX_GROUP = "tgsocial_index"
        private val LINK_PREVIEW_OFF = LinkPreviewOptions(isDisabled = true, url = "", forceSmallMedia = false, forceLargeMedia = false, showAboveText = false)
        private val QUIET = MessageSendOptions(
            suggestedPostInfo = null, disableNotification = true, fromBackground = false, protectContent = false,
            allowPaidBroadcast = false, paidMessageStarCount = 0L, updateOrderOfInstalledStickerSets = false,
            schedulingState = null, effectId = 0L, sendingId = 0, onlyPreview = false,
        )
    }

    suspend fun me(): User? = tg.client.getMe().orNull()

    /** Suggested default node name: `tgs_<telegram username>` or `tgs_<firstname><4 digits>`. */
    suspend fun suggestedUsername(): String {
        val me = me()
        val handle = me?.usernames?.editableUsername?.takeIf { it.isNotBlank() } ?: me?.usernames?.activeUsernames?.firstOrNull()
        if (!handle.isNullOrBlank()) return "tgs_${handle.lowercase()}".take(32)
        val first = me?.firstName?.lowercase()?.filter { it in 'a'..'z' || it in '0'..'9' }?.ifEmpty { null } ?: "node"
        val digits = (1000..9999).random()
        return "tgs_${first.take(23)}$digits"
    }

    /**
     * §4.2 — the first of my public channels whose pinned message starts with the marker. A card of a newer version
     * (§8) is still my node: the pointer is stored and the snapshot carries `newerVersion` with no card, so the app
     * says "Newer card. Update the app." instead of offering to make a second node.
     */
    suspend fun find(): Pair<MyNode, NodeSnapshot>? {
        val chats = tg.call { getCreatedPublicChats(type = PublicChatTypeHasUsername()) }
        for (chatId in chats.chatIds) {
            val chat = tg.client.getChat(chatId = chatId).orNull() ?: continue
            if (!chat.isChannel) continue
            val pinned = tg.client.getChatPinnedMessage(chatId = chatId).orNull() ?: continue
            val text = (pinned.content as? MessageText)?.text?.text ?: continue
            if (CardFormat.parse(text) is CardParse.NotACard) continue
            val snapshot = nodes.read(chat)
            if (snapshot.username.isBlank()) continue
            val node = MyNode(chatId = chatId, supergroupId = chat.supergroupId, username = snapshot.username, pinnedMessageId = pinned.id)
            store.saveMyNode(node)
            nodes.put(snapshot)
            return node to snapshot
        }
        return null
    }

    sealed class Availability { data object Available : Availability(); data class Taken(val reason: String) : Availability() }

    /** Live availability check for the Setup field. Uses a throwaway check against my own (future) channel: TDLib needs a chat id, so we check via the first created public chat or 0. */
    suspend fun checkUsername(username: String, chatId: Long): Availability {
        if (Username.normalise(username) == null || Username.normalise(username) != username) return Availability.Taken("Invalid")
        return when (val r = tg.client.checkChatUsername(chatId = chatId, username = username)) {
            is TdlResult.Success -> when (r.result) {
                is CheckChatUsernameResultOk -> Availability.Available
                is CheckChatUsernameResultUsernameOccupied -> Availability.Taken("Taken")
                is CheckChatUsernameResultUsernameInvalid -> Availability.Taken("Invalid")
                is CheckChatUsernameResultUsernamePurchasable -> Availability.Taken("Taken")
                is CheckChatUsernameResultPublicChatsTooMany -> Availability.Taken("Too many public channels.")
                else -> Availability.Taken("Taken")
            }
            is TdlResult.Failure -> if (r.code == 429) Availability.Taken("Wait") else Availability.Taken(r.message)
        }
    }

    /** §4.3 — check the name, create the channel, claim the username, send + pin the card, copy my profile photo. */
    suspend fun create(username: String, card: Card): Pair<MyNode, NodeSnapshot> {
        when (val check = tg.call { checkChatUsername(chatId = 0L, username = username) }) {
            is CheckChatUsernameResultOk -> Unit
            is CheckChatUsernameResultUsernameOccupied -> throw TdError(400, "That name is taken.")
            is CheckChatUsernameResultPublicChatsTooMany -> throw TdError(400, "Too many public channels.")
            is CheckChatUsernameResultUsernameInvalid -> throw TdError(400, "That name isn't allowed.")
            is CheckChatUsernameResultUsernamePurchasable -> throw TdError(400, "That name is taken.")
            else -> throw TdError(400, check.toString())
        }
        val me = me()
        val title = card.name?.takeIf { it.isNotBlank() } ?: listOfNotNull(me?.firstName, me?.lastName).joinToString(" ").ifBlank { username }
        val chat = tg.call {
            createNewSupergroupChat(
                title = title, isForum = false, isChannel = true, description = CardFormat.description(card.bio),
                location = null, messageAutoDeleteTime = 0, forImport = false,
            )
        }
        val sgId = chat.supergroupId
        val text = card.serialise()
        if (text.length > Card.MAX_LENGTH) throw CardFullException()
        val message: Long
        try {
            tg.call { setSupergroupUsername(supergroupId = sgId, username = username) }
            message = sendAndAwait(chat.id, text)
            tg.call { pinChatMessage(chatId = chat.id, messageId = message, disableNotification = true, onlyForSelf = false) }
        } catch (e: Exception) {
            // Don't leave a half-made channel behind.
            runCatching { tg.client.deleteChat(chatId = chat.id) }
            throw e
        }
        me?.profilePhoto?.big?.let { photo ->
            runCatching { tg.client.setChatPhoto(chatId = chat.id, photo = InputChatPhotoStatic(photo = InputFileId(id = photo.id))) }
        }
        val node = MyNode(chatId = chat.id, supergroupId = sgId, username = username, pinnedMessageId = message)
        store.saveMyNode(node)
        val snapshot = NodeSnapshot(
            username = username, chatId = chat.id, supergroupId = sgId, title = title,
            description = CardFormat.description(card.bio), card = card, pinnedMessageId = message, fetchedAt = System.currentTimeMillis(),
        )
        nodes.put(snapshot)
        return node to snapshot
    }

    /**
     * sendMessage returns a message with a temporary id; the server id arrives in updateMessageSendSucceeded.
     * The collector is attached before the send so the ack cannot be missed.
     */
    private suspend fun sendAndAwait(chatId: Long, text: String): Long {
        val acks = java.util.concurrent.ConcurrentHashMap<Long, Long>()
        val job = tg.scope.launch {
            tg.sendSucceeded.collect { if (it.message.chatId == chatId) acks[it.oldMessageId] = it.message.id }
        }
        try {
            val sent = tg.call {
                sendMessage(chatId = chatId, options = QUIET, inputMessageContent = InputMessageText(text = FormattedText(text = text, entities = emptyArray()), linkPreviewOptions = LINK_PREVIEW_OFF, clearDraft = true))
            }
            if (sent.sendingState == null) return sent.id
            val acked = withTimeoutOrNull(12_000L) {
                while (acks[sent.id] == null) delay(40)
                acks.getValue(sent.id)
            }
            if (acked != null) return acked
            val last = tg.client.getChatHistory(chatId = chatId, fromMessageId = 0L, offset = 0, limit = 1, onlyLocal = false).orNull()?.messages?.firstOrNull()
            return last?.id ?: sent.id
        } finally {
            job.cancel()
        }
    }

    /** §4.4 — edit the pinned card in place; re-pin if the pin was lost. Refuses when the card would not fit. */
    suspend fun writeCard(node: MyNode, card: Card): MyNode {
        val text = card.serialise()
        if (text.length > Card.MAX_LENGTH) throw CardFullException()
        var messageId = node.pinnedMessageId
        val pinned = tg.client.getChatPinnedMessage(chatId = node.chatId).orNull()
        if (pinned != null && (pinned.content as? MessageText)?.text?.text?.let { CardFormat.parse(it) is CardParse.Parsed } == true) {
            messageId = pinned.id
        } else if (messageId != 0L) {
            // Pin lost: re-pin the existing card message.
            tg.client.pinChatMessage(chatId = node.chatId, messageId = messageId, disableNotification = true, onlyForSelf = false)
        }
        tg.call {
            editMessageText(chatId = node.chatId, messageId = messageId, inputMessageContent = InputMessageText(text = FormattedText(text = text, entities = emptyArray()), linkPreviewOptions = LINK_PREVIEW_OFF, clearDraft = false))
        }
        // Keep the description's bio in step (PROTOCOL §2: SHOULD begin with the marker · bio).
        runCatching { tg.client.setChatDescription(chatId = node.chatId, description = CardFormat.description(card.bio)) }
        val updated = node.copy(pinnedMessageId = messageId)
        store.saveMyNode(updated)
        nodes.cached(node.username)?.let { nodes.put(it.copy(card = card, fetchedAt = System.currentTimeMillis())) }
        return updated
    }

    /** §4.7 — channels I can post to. Private ones are listed disabled ("Needs a public link."). */
    suspend fun feedCandidates(excludeChatId: Long): List<FeedCandidate> {
        val ids = LinkedHashSet<Long>()
        tg.client.getCreatedPublicChats(type = PublicChatTypeHasUsername()).orNull()?.chatIds?.forEach { ids += it }
        // loadChats until 404 (all loaded), then getChats.
        var guard = 0
        while (guard++ < 20) {
            val r = tg.client.loadChats(chatList = ChatListMain(), limit = 100)
            if (r is TdlResult.Failure) break
        }
        tg.client.getChats(chatList = ChatListMain(), limit = 200).orNull()?.chatIds?.forEach { ids += it }
        val out = ArrayList<FeedCandidate>()
        for (id in ids) {
            if (id == excludeChatId) continue
            val chat = tg.client.getChat(chatId = id).orNull() ?: continue
            if (!chat.isChannel) continue
            val sg = tg.client.getSupergroup(supergroupId = chat.supergroupId).orNull() ?: continue
            val canPost = when (val s = sg.status) {
                is ChatMemberStatusCreator -> true
                is ChatMemberStatusAdministrator -> s.rights.canPostMessages
                else -> false
            }
            if (!canPost) continue
            val full = tg.client.getSupergroupFullInfo(supergroupId = chat.supergroupId).orNull()
            out += FeedCandidate(chatId = id, supergroupId = chat.supergroupId, title = chat.title, username = sg.username, description = full?.description.orEmpty(), canPost = true)
        }
        return out.sortedWith(compareByDescending<FeedCandidate> { it.isPublic }.thenBy { it.title.lowercase() })
    }

    /** §3 — append `tgsocial: @node` to a feed's description. */
    suspend fun verifyFeed(feedChatId: Long, currentDescription: String, node: String) {
        val next = Backlink.append(currentDescription, node) ?: throw TdError(400, "Description is full.")
        if (next == currentDescription) return
        tg.call { setChatDescription(chatId = feedChatId, description = next) }
    }

    /** §5.3 — post `node: @me` to @tgsocial_index. Explicit, never automatic; refused when `public: no`. */
    suspend fun announce(node: MyNode, card: Card) {
        if (!card.public) throw TdError(400, "Your node is unlisted.")
        val group = tg.call { searchPublicChat(username = INDEX_GROUP) }
        val joined = tg.client.joinChat(chatId = group.id)
        if (joined is TdlResult.Failure && joined.code != 400) joined.orThrow()
        sendAndAwait(group.id, "node: @${node.username}")
    }
}
