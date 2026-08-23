package ca.lucianlabs.tgsocial.repo

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import ca.lucianlabs.tgsocial.td.TelegramClient
import dev.g000sha256.tdl.dto.FormattedText
import dev.g000sha256.tdl.dto.InputFileLocal
import dev.g000sha256.tdl.dto.InputMessagePhoto
import dev.g000sha256.tdl.dto.InputMessageText
import dev.g000sha256.tdl.dto.InputPhoto
import dev.g000sha256.tdl.dto.Message
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** PROTOCOL §4.9 — post text or a photo into one of my feeds. Channels post as the channel. */
class PostingRepo(private val context: Context, private val tg: TelegramClient) {
    suspend fun postText(chatId: Long, text: String): Message = tg.call {
        sendMessage(chatId = chatId, inputMessageContent = InputMessageText(text = FormattedText(text = text, entities = emptyArray()), linkPreviewOptions = null, clearDraft = true))
    }

    suspend fun postPhoto(chatId: Long, uri: Uri, caption: String): Message {
        val (path, w, h) = withContext(Dispatchers.IO) {
            val dir = File(context.cacheDir, "upload").apply { mkdirs() }
            val file = File(dir, "photo-${System.currentTimeMillis()}.jpg")
            context.contentResolver.openInputStream(uri)?.use { input -> file.outputStream().use { input.copyTo(it) } }
                ?: throw IllegalStateException("Couldn't read that photo.")
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, opts)
            Triple(file.absolutePath, opts.outWidth.coerceAtLeast(0), opts.outHeight.coerceAtLeast(0))
        }
        return tg.call {
            sendMessage(
                chatId = chatId,
                inputMessageContent = InputMessagePhoto(
                    photo = InputPhoto(photo = InputFileLocal(path = path), thumbnail = null, video = null, addedStickerFileIds = IntArray(0), width = w, height = h),
                    caption = if (caption.isBlank()) null else FormattedText(text = caption, entities = emptyArray()),
                    showCaptionAboveMedia = false,
                    selfDestructType = null,
                    hasSpoiler = false,
                ),
            )
        }
    }
}
