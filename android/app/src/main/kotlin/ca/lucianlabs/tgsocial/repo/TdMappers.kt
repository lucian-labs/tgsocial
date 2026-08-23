package ca.lucianlabs.tgsocial.repo

import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.PostMedia
import ca.lucianlabs.tgsocial.model.PostText
import ca.lucianlabs.tgsocial.model.Reaction
import ca.lucianlabs.tgsocial.model.TextRun
import ca.lucianlabs.tgsocial.protocol.CardFormat
import dev.g000sha256.tdl.dto.Chat
import dev.g000sha256.tdl.dto.ChatTypeSupergroup
import dev.g000sha256.tdl.dto.File
import dev.g000sha256.tdl.dto.FormattedText
import dev.g000sha256.tdl.dto.Message
import dev.g000sha256.tdl.dto.MessageAnimation
import dev.g000sha256.tdl.dto.MessageAudio
import dev.g000sha256.tdl.dto.MessageDocument
import dev.g000sha256.tdl.dto.MessageOrigin
import dev.g000sha256.tdl.dto.MessageOriginHiddenUser
import dev.g000sha256.tdl.dto.MessagePhoto
import dev.g000sha256.tdl.dto.MessageText
import dev.g000sha256.tdl.dto.MessageVideo
import dev.g000sha256.tdl.dto.Photo
import dev.g000sha256.tdl.dto.ReactionTypeEmoji
import dev.g000sha256.tdl.dto.Supergroup
import dev.g000sha256.tdl.dto.TextEntityTypeBold
import dev.g000sha256.tdl.dto.TextEntityTypeCode
import dev.g000sha256.tdl.dto.TextEntityTypeEmailAddress
import dev.g000sha256.tdl.dto.TextEntityTypeItalic
import dev.g000sha256.tdl.dto.TextEntityTypeMention
import dev.g000sha256.tdl.dto.TextEntityTypePre
import dev.g000sha256.tdl.dto.TextEntityTypePreCode
import dev.g000sha256.tdl.dto.TextEntityTypeTextUrl
import dev.g000sha256.tdl.dto.TextEntityTypeUrl
import dev.g000sha256.tdl.dto.Thumbnail

fun File.ref(width: Int = 0, height: Int = 0): FileRef =
    FileRef(id = id, uniqueId = remote.uniqueId, localPath = local.path.takeIf { local.isDownloadingCompleted && it.isNotEmpty() }, width = width, height = height)

fun Thumbnail?.ref(): FileRef? = this?.file?.ref(width, height)

val Chat.supergroupId: Long get() = (type as? ChatTypeSupergroup)?.supergroupId ?: 0L
val Chat.isChannel: Boolean get() = (type as? ChatTypeSupergroup)?.isChannel == true
val Supergroup.username: String? get() = usernames?.activeUsernames?.firstOrNull()?.takeIf { it.isNotBlank() } ?: usernames?.editableUsername?.takeIf { it.isNotBlank() }

/** Smallest photo size whose width is ≥ the display width (PROTOCOL §4.10); falls back to the largest. */
fun Photo.sizeFor(displayWidthPx: Int): dev.g000sha256.tdl.dto.PhotoSize? {
    val sorted = sizes.sortedBy { it.width }
    return sorted.firstOrNull { it.width >= displayWidthPx } ?: sorted.lastOrNull()
}

fun FormattedText.toPostText(): PostText? {
    if (text.isBlank()) return null
    val runs = entities.mapNotNull { e ->
        val kind = when (val t = e.type) {
            is TextEntityTypeBold -> "bold"
            is TextEntityTypeItalic -> "italic"
            is TextEntityTypeCode, is TextEntityTypePre, is TextEntityTypePreCode -> "code"
            is TextEntityTypeUrl -> "url"
            is TextEntityTypeTextUrl -> return@mapNotNull TextRun(e.offset, e.offset + e.length, "link", t.url)
            is TextEntityTypeMention -> "mention"
            is TextEntityTypeEmailAddress -> "email"
            else -> return@mapNotNull null
        }
        TextRun(e.offset, e.offset + e.length, kind)
    }
    return PostText(text, runs)
}

/**
 * PROTOCOL §4.8 — text, photo, video (thumbnail + duration), animation, document (file name), audio, each with caption.
 * Service messages and the card itself yield null.
 */
suspend fun Message.toPost(
    sourceUsername: String,
    sourceTitle: String,
    sourcePhoto: FileRef?,
    displayWidthPx: Int,
    resolveOrigin: suspend (MessageOrigin) -> String?,
): Post? {
    val c = content
    val text: PostText?
    val media: PostMedia?
    when (c) {
        is MessageText -> {
            if (CardFormat.isCardText(c.text.text)) return null
            text = c.text.toPostText(); media = null
        }
        is MessagePhoto -> {
            val size = c.photo.sizeFor(displayWidthPx)
            text = c.caption.toPostText()
            media = size?.let { PostMedia.Photo(it.photo.ref(it.width, it.height), it.width, it.height) }
        }
        is MessageVideo -> {
            text = c.caption.toPostText()
            media = PostMedia.Video(c.video.thumbnail.ref(), c.video.width, c.video.height, c.video.duration)
        }
        is MessageAnimation -> {
            text = c.caption.toPostText()
            media = PostMedia.Animation(c.animation.thumbnail.ref(), c.animation.width, c.animation.height)
        }
        is MessageDocument -> {
            text = c.caption.toPostText()
            media = PostMedia.Document(c.document.fileName)
        }
        is MessageAudio -> {
            text = c.caption.toPostText()
            media = PostMedia.Audio(c.audio.title, c.audio.performer, c.audio.fileName, c.audio.duration)
        }
        else -> return null
    }
    val reactions = interactionInfo?.reactions?.reactions?.mapNotNull { r ->
        (r.type as? ReactionTypeEmoji)?.let { Reaction(it.emoji, r.totalCount) }
    } ?: emptyList()
    return Post(
        chatId = chatId,
        messageId = id,
        date = date,
        sourceUsername = sourceUsername,
        sourceTitle = sourceTitle,
        sourcePhoto = sourcePhoto,
        text = text,
        media = media,
        forwardedFrom = forwardInfo?.let { fwd ->
            when (val o = fwd.origin) {
                is MessageOriginHiddenUser -> o.senderName
                else -> resolveOrigin(o)
            }
        },
        views = interactionInfo?.viewCount ?: 0,
        reactions = reactions,
    )
}
