package ca.lucianlabs.tgsocial.model

import ca.lucianlabs.tgsocial.protocol.Card
import kotlinx.serialization.Serializable

/** PROTOCOL §4.2 — the local pointer to my node. */
@Serializable
data class MyNode(
    val chatId: Long,
    val supergroupId: Long,
    val username: String,
    val pinnedMessageId: Long,
)

/** A TDLib file reference small enough to cache. */
@Serializable
data class FileRef(val id: Int, val uniqueId: String, val localPath: String? = null, val width: Int = 0, val height: Int = 0)

/** PROTOCOL §4.5 — a node as read from Telegram, cached with `fetchedAt`. */
@Serializable
data class NodeSnapshot(
    val username: String,
    val chatId: Long,
    val supergroupId: Long,
    val title: String,
    val description: String = "",
    val photo: FileRef? = null,
    val card: Card? = null,
    val newerVersion: Boolean = false,
    val pinnedMessageId: Long = 0,
    val fetchedAt: Long = 0,
) {
    val isNode: Boolean get() = card != null
    val displayName: String get() = card?.name?.takeIf { it.isNotBlank() } ?: title.ifBlank { "@$username" }
    val initial: String get() = displayName.firstOrNull { it.isLetterOrDigit() }?.toString() ?: "·"
}

/** A feed channel as a source (my own or a followed node's). */
@Serializable
data class FeedSource(
    val username: String,
    val chatId: Long,
    val supergroupId: Long = 0,
    val title: String,
    val description: String = "",
    val photo: FileRef? = null,
    /** Usernames of nodes listing this feed (for the Verified pill). */
    val listedBy: List<String> = emptyList(),
    val verifiedFor: List<String> = emptyList(),
) {
    val initial: String get() = title.firstOrNull { it.isLetterOrDigit() }?.toString() ?: "·"
}

/** A candidate feed of mine (PROTOCOL §4.7). */
data class FeedCandidate(
    val chatId: Long,
    val supergroupId: Long,
    val title: String,
    val username: String?,
    val description: String,
    val canPost: Boolean,
) {
    val isPublic: Boolean get() = !username.isNullOrBlank()
}

@Serializable
sealed class PostMedia {
    @Serializable
    data class Photo(val file: FileRef, val width: Int, val height: Int) : PostMedia()

    @Serializable
    data class Video(val thumb: FileRef?, val width: Int, val height: Int, val durationSeconds: Int) : PostMedia()

    @Serializable
    data class Animation(val thumb: FileRef?, val width: Int, val height: Int) : PostMedia()

    @Serializable
    data class Document(val fileName: String) : PostMedia()

    @Serializable
    data class Audio(val title: String, val performer: String, val fileName: String, val durationSeconds: Int) : PostMedia()
}

@Serializable
data class TextRun(val start: Int, val end: Int, val kind: String, val url: String? = null)

@Serializable
data class PostText(val text: String, val runs: List<TextRun> = emptyList())

@Serializable
data class Reaction(val emoji: String, val count: Int)

/** One post card. Serialisable so the last page of the feed can be shown cold (PRODUCT §4). */
@Serializable
data class Post(
    val chatId: Long,
    val messageId: Long,
    val date: Int,
    val sourceUsername: String,
    val sourceTitle: String,
    val sourcePhoto: FileRef? = null,
    val text: PostText? = null,
    val media: PostMedia? = null,
    val forwardedFrom: String? = null,
    val views: Int = 0,
    val reactions: List<Reaction> = emptyList(),
) {
    val key: String get() = "$chatId:$messageId"
}

/** A directory / nearby / graph row. */
data class NodeEntry(
    val username: String,
    val name: String,
    val feedCount: Int,
    val mutualCount: Int = 0,
    val photo: FileRef? = null,
    val initial: String = name.firstOrNull { it.isLetterOrDigit() }?.toString() ?: "·",
)

enum class SyncStatus(val label: String) { SYNCED("Synced"), SYNCING("Syncing"), OFFLINE("Offline"), SIGNED_OUT("Signed out") }
