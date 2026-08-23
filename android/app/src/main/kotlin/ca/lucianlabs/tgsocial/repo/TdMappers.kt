package ca.lucianlabs.tgsocial.repo

import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.model.LinkPreviewInfo
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
import dev.g000sha256.tdl.dto.LinkPreview
import dev.g000sha256.tdl.dto.LinkPreviewTypeAnimation
import dev.g000sha256.tdl.dto.LinkPreviewTypeArticle
import dev.g000sha256.tdl.dto.LinkPreviewTypePhoto
import dev.g000sha256.tdl.dto.LinkPreviewTypeVideo
import dev.g000sha256.tdl.dto.MessageAnimation
import dev.g000sha256.tdl.dto.MessageAudio
import dev.g000sha256.tdl.dto.MessageContact
import dev.g000sha256.tdl.dto.MessageDocument
import dev.g000sha256.tdl.dto.MessageLocation
import dev.g000sha256.tdl.dto.MessageOrigin
import dev.g000sha256.tdl.dto.MessageOriginHiddenUser
import dev.g000sha256.tdl.dto.MessagePhoto
import dev.g000sha256.tdl.dto.MessagePoll
import dev.g000sha256.tdl.dto.MessageSticker
import dev.g000sha256.tdl.dto.MessageText
import dev.g000sha256.tdl.dto.MessageVenue
import dev.g000sha256.tdl.dto.MessageVideo
import dev.g000sha256.tdl.dto.MessageVideoNote
import dev.g000sha256.tdl.dto.MessageVoiceNote
import dev.g000sha256.tdl.dto.Minithumbnail
import dev.g000sha256.tdl.dto.Photo
import dev.g000sha256.tdl.dto.ReactionTypeEmoji
import dev.g000sha256.tdl.dto.StickerFormatWebp
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
    FileRef(
        id = id,
        uniqueId = remote.uniqueId,
        localPath = local.path.takeIf { local.isDownloadingCompleted && it.isNotEmpty() },
        width = width,
        height = height,
        size = if (size > 0) size else expectedSize,
    )

private fun Minithumbnail?.b64(): String? = this?.data?.takeIf { it.isNotEmpty() }?.let { java.util.Base64.getEncoder().encodeToString(it) }

private fun LinkPreview?.toInfo(): LinkPreviewInfo? {
    if (this == null || url.isBlank()) return null
    val photo = when (val t = type) {
        is LinkPreviewTypeArticle -> t.photo
        is LinkPreviewTypePhoto -> t.photo
        is LinkPreviewTypeVideo -> t.cover
        else -> null
    }
    val thumb = photo?.sizes?.minByOrNull { it.width }?.photo?.ref()
        ?: (type as? LinkPreviewTypeAnimation)?.animation?.thumbnail?.file?.ref()
    return LinkPreviewInfo(
        url = url,
        siteName = siteName,
        title = title,
        description = description.text,
        thumb = thumb,
    )
}

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
 * PROTOCOL §4.8 / PRODUCT §2.11 — every content type a post can carry, each with its caption. Service messages
 * and the card itself yield null. Album members come back as single-item posts sharing `albumId`; the repository
 * merges them.
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
    var linkPreview: LinkPreviewInfo? = null
    when (c) {
        is MessageText -> {
            if (CardFormat.isCardText(c.text.text)) return null
            text = c.text.toPostText(); media = null
            linkPreview = c.linkPreview.toInfo()
        }
        is MessagePhoto -> {
            val size = c.photo.sizeFor(displayWidthPx)
            text = c.caption.toPostText()
            media = size?.let { PostMedia.Photo(it.photo.ref(it.width, it.height), it.width, it.height, c.photo.minithumbnail.b64()) }
        }
        is MessageVideo -> {
            text = c.caption.toPostText()
            media = PostMedia.Video(
                file = c.video.video.ref(c.video.width, c.video.height),
                thumb = c.video.thumbnail.ref(),
                width = c.video.width,
                height = c.video.height,
                durationSeconds = c.video.duration,
                mini = c.video.minithumbnail.b64(),
                mimeType = c.video.mimeType,
                supportsStreaming = c.video.supportsStreaming,
            )
        }
        is MessageAnimation -> {
            text = c.caption.toPostText()
            media = PostMedia.Animation(
                file = c.animation.animation.ref(c.animation.width, c.animation.height),
                thumb = c.animation.thumbnail.ref(),
                width = c.animation.width,
                height = c.animation.height,
                mini = c.animation.minithumbnail.b64(),
                mimeType = c.animation.mimeType,
            )
        }
        is MessageDocument -> {
            text = c.caption.toPostText()
            media = PostMedia.Document(
                file = c.document.document.ref(),
                fileName = c.document.fileName,
                mimeType = c.document.mimeType,
                size = c.document.document.let { if (it.size > 0) it.size else it.expectedSize },
                thumb = c.document.thumbnail.ref(),
            )
        }
        is MessageAudio -> {
            text = c.caption.toPostText()
            media = PostMedia.Audio(
                file = c.audio.audio.ref(),
                title = c.audio.title,
                performer = c.audio.performer,
                fileName = c.audio.fileName,
                durationSeconds = c.audio.duration,
                mimeType = c.audio.mimeType,
            )
        }
        is MessageVoiceNote -> {
            text = c.caption.toPostText()
            media = PostMedia.Voice(
                file = c.voiceNote.voice.ref(),
                durationSeconds = c.voiceNote.duration,
                waveform = c.voiceNote.waveform.takeIf { it.isNotEmpty() }?.let { java.util.Base64.getEncoder().encodeToString(it) },
                mimeType = c.voiceNote.mimeType,
            )
        }
        is MessageVideoNote -> {
            text = null
            media = PostMedia.VideoNote(
                file = c.videoNote.video.ref(c.videoNote.length, c.videoNote.length),
                thumb = c.videoNote.thumbnail.ref(),
                durationSeconds = c.videoNote.duration,
                mini = c.videoNote.minithumbnail.b64(),
            )
        }
        is MessageSticker -> {
            text = null
            media = PostMedia.Sticker(
                file = c.sticker.sticker.ref(c.sticker.width, c.sticker.height),
                thumb = c.sticker.thumbnail.ref(),
                width = c.sticker.width,
                height = c.sticker.height,
                animated = c.sticker.format !is StickerFormatWebp,
            )
        }
        is MessagePoll -> {
            text = null
            val n = c.poll.options.size
            media = PostMedia.Summary(if (n == 1) "Poll · 1 option" else "Poll · $n options")
        }
        is MessageLocation -> {
            text = null
            media = PostMedia.Summary("Location")
        }
        is MessageVenue -> {
            text = null
            media = PostMedia.Summary("Location")
        }
        is MessageContact -> {
            text = null
            val name = listOf(c.contact.firstName, c.contact.lastName).filter { it.isNotBlank() }.joinToString(" ")
            media = PostMedia.Summary(if (name.isBlank()) "Contact" else "Contact · $name")
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
        media = listOfNotNull(media),
        linkPreview = linkPreview,
        forwardedFrom = forwardInfo?.let { fwd ->
            when (val o = fwd.origin) {
                is MessageOriginHiddenUser -> o.senderName
                else -> resolveOrigin(o)
            }
        },
        views = interactionInfo?.viewCount ?: 0,
        reactions = reactions,
        albumId = mediaAlbumId,
    )
}
