package ca.lucianlabs.tgsocial.repo

import ca.lucianlabs.tgsocial.audio.AudioStrip
import ca.lucianlabs.tgsocial.model.FileRef

/**
 * What [AudioStripRepo] needs from [MediaRepo]: the byte-bounded strip cache, and the bytes on disk.
 *
 * A seam, not an abstraction layer. The part of the audio path worth asserting is its **policy** —
 * PRODUCT §2.11.1's caps and refusals, and §2.11.2's "playing a clip must never trigger a second analysis" —
 * and asserting policy should not require TDLib, a `MediaCodec` or a `Bitmap`. [MediaRepo] is the only
 * implementation that ships; the other lives in `MiniWaveEnvelopeTest` and counts what was asked of it.
 */
interface StripSource {
    fun strip(key: String): AudioStrip?

    fun putStrip(key: String, strip: AudioStrip)

    suspend fun localPath(ref: FileRef): String?

    suspend fun download(
        ref: FileRef,
        priority: Int = MediaRepo.PRIORITY_VISIBLE,
        label: String = "Downloading file",
        timeoutMs: Long = MediaRepo.DOWNLOAD_TIMEOUT_MS,
    ): String?
}
