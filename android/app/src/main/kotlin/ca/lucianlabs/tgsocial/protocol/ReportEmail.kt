package ca.lucianlabs.tgsocial.protocol

import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.Post

/** What is being reported (PRODUCT §2.15): a post, or a comment. [ReportEmail] turns one into the mail. */
data class ReportSubject(
    /** The channel it lives in: the feed channel for a post, the commenter's comments channel for a comment. */
    val channel: String,
    /** TDLib's message id; the link and the `Message:` line carry the server id (PROTOCOL §4.8). */
    val messageId: Long,
    /** The attributed node (§2.3), or the commenter's node. Null reports as `unattributed`. */
    val node: String?,
    val isComment: Boolean,
) {
    val link: String get() = DeepLink.post(channel, messageId)
    val serverMessageId: Long get() = DeepLink.serverMessageId(messageId)

    /** PROTOCOL §7.1 — the hidden-list key, so a hidden post and a hidden comment are the same kind of key. */
    val key: String get() = CommentFormat.postKey(channel, messageId)

    companion object {
        fun forPost(post: Post): ReportSubject = ReportSubject(
            channel = post.sourceUsername,
            messageId = post.messageId,
            node = post.nodeUsername,
            isComment = false,
        )

        fun forComment(comment: Comment): ReportSubject = ReportSubject(
            channel = comment.channelUsername,
            messageId = comment.messageId,
            node = comment.authorUsername,
            isComment = true,
        )
    }
}

/** A prefilled mail, ready for the platform's composer. Nothing here identifies the reporter. */
data class ReportMail(val to: String, val subject: String, val body: String)

/**
 * PRODUCT §2.15 — the report, which with no server of ours to report to is an email the reader's own mail client
 * sends, and which they can edit or delete every line of before sending.
 *
 * The seven [REASONS] are the whole list on every platform and are the subject line verbatim: one fixed
 * vocabulary stops per-build rewording and gives the address a sortable inbox.
 */
object ReportEmail {
    const val ADDRESS = "elijah@lucianlabs.ca"

    val REASONS: List<String> = listOf(
        "Spam",
        "Nudity or sexual content",
        "Violence or threats",
        "Hate or harassment",
        "Child safety",
        "Illegal content",
        "Something else",
    )

    fun subject(reason: String): String = "tgsocial report — $reason"

    /**
     * The body, and **only** this: a reason, a link, what it points at, and the build. No phone number, no node
     * of the reporter's, no device id — the reporter's address is whatever their own mail client sends.
     *
     * [app] is the You footer's version string plus the platform. The body ends on a blank line so the composer's
     * cursor lands under the prompt.
     */
    fun body(subject: ReportSubject, reason: String, app: String): String = buildString {
        append("Reason: ").append(reason).append('\n')
        append("Link: ").append(subject.link).append('\n')
        append("Channel: @").append(subject.channel).append('\n')
        append("Message: ").append(subject.serverMessageId).append('\n')
        append("Node: ").append(subject.node?.let { "@$it" } ?: "unattributed").append('\n')
        append("Kind: ").append(if (subject.isComment) "comment" else "post").append('\n')
        append("App: ").append(app).append('\n')
        append('\n')
        append("Anything you want to add:\n\n")
    }

    fun compose(subject: ReportSubject, reason: String, app: String): ReportMail =
        ReportMail(to = ADDRESS, subject = subject(reason), body = body(subject, reason, app))
}
