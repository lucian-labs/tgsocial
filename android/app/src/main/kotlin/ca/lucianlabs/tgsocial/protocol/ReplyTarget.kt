package ca.lucianlabs.tgsocial.protocol

import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.Post

/** What a comment points at (PROTOCOL §6.2): a post, or another comment. Feeds the composer's quote line. */
data class CommentTarget(
    val link: String,
    val title: String,
    val excerpt: String,
    /** True when the target is another comment — the quote reads `Reply to <name>.`, not the post's title. */
    val isComment: Boolean = false,
)

/**
 * PRODUCT §2.12 / PROTOCOL §6.2 — **what a reply points at**, and nothing else.
 *
 * "Tapping any comment selects it as the reply target… Tapping it again, or the quote's `×`, clears the
 * target and the reply goes to the post instead. This is the `re:` chain of PROTOCOL §6.2 made direct — the
 * target is whatever you tapped."
 *
 * The whole chain is that one sentence turned into a link: a tap picks a target, [resolve] says which target
 * a send actually uses, and [firstLine] is the line the message carries. Pure, because the thing worth
 * asserting — that the `re:` line names the *comment* when one is selected and the *post* when none is — is
 * arithmetic on strings, not a screen.
 */
object ReplyTarget {

    /** The post itself: what a reply goes to when nothing is selected. */
    fun forPost(post: Post): CommentTarget = CommentTarget(
        link = DeepLink.post(post.sourceUsername, post.messageId),
        title = post.sourceTitle,
        excerpt = post.text?.text.orEmpty(),
        isComment = false,
    )

    /** One comment: its own `t.me` link, so the reply hangs off it rather than off the post (§6.2). */
    fun forComment(comment: Comment): CommentTarget = CommentTarget(
        link = comment.link,
        title = comment.authorName,
        excerpt = comment.post.text?.text.orEmpty(),
        isComment = true,
    )

    /**
     * A tap on a comment row: select it, or clear the selection when it is already the target. Tapping the
     * selected comment again is one of the two ways §2.12 gives to get back to replying to the post; the
     * quote's `×` is the other, and it is simply `null`.
     */
    fun toggle(current: CommentTarget?, tapped: CommentTarget): CommentTarget? =
        if (current?.link == tapped.link) null else tapped

    /** Which target a send uses: the selected comment, else the post. */
    fun resolve(selected: CommentTarget?, post: Post): CommentTarget = selected ?: forPost(post)

    /** The comment's first line (PROTOCOL §6.2): `re: ` + the target's own link. */
    fun firstLine(target: CommentTarget): String = CommentFormat.serialise(target.link, "")

    /** §2.12's composer placeholder: `Reply to <name>.` against a comment, `Say it.` against a post. */
    fun placeholder(target: CommentTarget?): String =
        if (target != null && target.isComment) "Reply to ${target.title}." else "Say it."

    /** §2.12's quote line: `re: <title> — 'excerpt…'`, one line, muted. */
    fun quote(target: CommentTarget, limit: Int = EXCERPT_LIMIT): String {
        val excerpt = target.excerpt.replace('\n', ' ').trim()
        if (excerpt.isEmpty()) return "re: ${target.title}"
        val cut = if (excerpt.length > limit) excerpt.take(limit) + "…" else excerpt
        return "re: ${target.title} — '$cut'"
    }

    /** Enough of the target to recognise it, short enough to stay on two lines in the composer. */
    const val EXCERPT_LIMIT = 60
}
