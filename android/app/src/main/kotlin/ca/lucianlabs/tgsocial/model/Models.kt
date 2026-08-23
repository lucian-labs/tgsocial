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
data class FileRef(
    val id: Int,
    val uniqueId: String,
    val localPath: String? = null,
    val width: Int = 0,
    val height: Int = 0,
    val size: Long = 0,
)

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

/**
 * PRODUCT §2.11 — everything a post can carry. `mini` is TDLib's minithumbnail JPEG (base64) for the blur-up.
 * Every variant that opens or plays keeps its TDLib [FileRef] so the app never hands off to Telegram for media.
 */
@Serializable
sealed class PostMedia {
    @Serializable
    data class Photo(val file: FileRef, val width: Int, val height: Int, val mini: String? = null) : PostMedia()

    @Serializable
    data class Video(
        val file: FileRef,
        val thumb: FileRef?,
        val width: Int,
        val height: Int,
        val durationSeconds: Int,
        val mini: String? = null,
        val mimeType: String = "",
        val supportsStreaming: Boolean = false,
    ) : PostMedia()

    @Serializable
    data class Animation(
        val file: FileRef,
        val thumb: FileRef?,
        val width: Int,
        val height: Int,
        val mini: String? = null,
        val mimeType: String = "",
    ) : PostMedia()

    @Serializable
    data class Audio(
        val file: FileRef,
        val title: String,
        val performer: String,
        val fileName: String,
        val durationSeconds: Int,
        val mimeType: String = "",
    ) : PostMedia()

    @Serializable
    data class Voice(
        val file: FileRef,
        val durationSeconds: Int,
        /** TDLib's 5-bit packed waveform, base64. */
        val waveform: String? = null,
        val mimeType: String = "",
    ) : PostMedia()

    @Serializable
    data class VideoNote(
        val file: FileRef,
        val thumb: FileRef?,
        val durationSeconds: Int,
        val mini: String? = null,
    ) : PostMedia()

    @Serializable
    data class Document(
        val file: FileRef,
        val fileName: String,
        val mimeType: String = "",
        val size: Long = 0,
        val thumb: FileRef? = null,
    ) : PostMedia()

    @Serializable
    data class Sticker(
        val file: FileRef,
        val thumb: FileRef?,
        val width: Int,
        val height: Int,
        /** Animated stickers (tgs/webm) render their thumbnail instead (PRODUCT §2.11). */
        val animated: Boolean = false,
    ) : PostMedia()

    /** Poll, location, contact, and everything else: a muted one-line summary. */
    @Serializable
    data class Summary(val text: String) : PostMedia()
}

/** PRODUCT §2.11 — `linkPreview` rendered as a bordered row; the link opens in the system browser. */
@Serializable
data class LinkPreviewInfo(
    val url: String,
    val siteName: String = "",
    val title: String = "",
    val description: String = "",
    val thumb: FileRef? = null,
)

@Serializable
data class TextRun(val start: Int, val end: Int, val kind: String, val url: String? = null)

@Serializable
data class PostText(val text: String, val runs: List<TextRun> = emptyList())

@Serializable
data class Reaction(val emoji: String, val count: Int)

/**
 * One post card. Serialisable so the last page of the feed can be shown cold (PRODUCT §4).
 * An album (shared `mediaAlbumId`) collapses into one post whose [media] lists every item, newest last.
 */
@Serializable
data class Post(
    val chatId: Long,
    val messageId: Long,
    val date: Int,
    val sourceUsername: String,
    val sourceTitle: String,
    val sourcePhoto: FileRef? = null,
    val text: PostText? = null,
    val media: List<PostMedia> = emptyList(),
    val linkPreview: LinkPreviewInfo? = null,
    val forwardedFrom: String? = null,
    val views: Int = 0,
    val reactions: List<Reaction> = emptyList(),
    val albumId: Long = 0,
) {
    val key: String get() = "$chatId:$messageId"
}

/**
 * PROTOCOL §6 — one comment, read from a comments channel of my network. [post] carries the body and any media
 * so the thread renders it exactly like a post; its text has the `re:` pointer line already stripped.
 * [link] is this comment's own `t.me` deep link (comments channels are public, so every comment has one) and
 * [targetKey] is the normalised key of what it points at — a feed post or another comment (a reply).
 */
data class Comment(
    val chatId: Long,
    val messageId: Long,
    val date: Int,
    /** The comments channel this lives in. */
    val channelUsername: String,
    /** The node that owns the channel. */
    val authorUsername: String,
    val authorName: String,
    val authorPhoto: FileRef? = null,
    val targetKey: String,
    val link: String,
    val post: Post,
    /** Found through the +1 network rather than a direct follow (PRODUCT §2.12: shows the `+1` pill). */
    val plusOne: Boolean = false,
    val own: Boolean = false,
    /** Optimistic send in flight (PRODUCT §2.12: faint `Posting…` tag). */
    val pending: Boolean = false,
) {
    val key: String get() = "$chatId:$messageId"
}

/** A comment with its replies resolved (`re:` chains), depth capped by the UI at 5. */
data class CommentNode(val comment: Comment, val replies: List<CommentNode>) {
    val count: Int get() = 1 + replies.sumOf { it.count }
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
