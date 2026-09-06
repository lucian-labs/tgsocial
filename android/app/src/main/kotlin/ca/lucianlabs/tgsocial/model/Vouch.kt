package ca.lucianlabs.tgsocial.model

import ca.lucianlabs.tgsocial.protocol.Username

/**
 * PROTOCOL §10.4 — one vouch, read from a comments channel of my network. It lives in the **voucher's** own
 * channel and points at the subject's node, which is what makes it unforgeable: the subject cannot write it,
 * edit it, or take it down (PRODUCT §2.25 says so to the person it costs).
 *
 * [subjectUsername] is who it is about; every other name here is the voucher's.
 */
data class Vouch(
    val chatId: Long,
    val messageId: Long,
    val date: Int,
    /** The comments channel it lives in — the voucher's `replies:`. */
    val channelUsername: String,
    val voucherUsername: String,
    val voucherName: String,
    val voucherPhoto: FileRef? = null,
    val subjectUsername: String,
    /** Exactly one capability tag, §10.2-normalised. One vouch, one tag, one message. */
    val tag: String,
    val body: String,
    /** Reached through the +1 network rather than a direct follow (PRODUCT §2.25 shows the `+1` pill). */
    val plusOne: Boolean = false,
    val own: Boolean = false,
) {
    val key: String get() = "$chatId:$messageId"

    /** Index key: the subject, lowercased — Telegram usernames are case-insensitive. */
    val subjectKey: String get() = Username.key(subjectUsername)
}
