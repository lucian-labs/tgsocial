package ca.lucianlabs.tgsocial.ui.components

import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.model.Post

/**
 * PRODUCT §2.3 — everything the post header shows, resolved from the post alone so the rule can be checked
 * without a composition.
 *
 * The **name is the node** the post reaches me through (the person) and the subheading is the channel, but the
 * **avatar is the source channel**: a node is an aggregate of a person's channels, so the avatar's job is to
 * say which channel this post came from — it is the only thing telling two posts by the same person from
 * different feeds apart.
 *
 * Photo fallback chain, since any of these can be missing:
 * 1. the source channel's photo;
 * 2. else the node's own photo;
 * 3. else null, and the card draws [initial] in the display serif.
 *
 * Telegram serves a **generated letter avatar** for a channel with no photo. That is not a photo, and it never
 * reaches this class: the letter is painted by Telegram's own clients (on the web page it is a
 * `data:image/svg+xml` image sitting on a `bgcolorN` element), while TDLib reports the chat as `chat.photo ==
 * null`. `FeedSource.photo` is `chat.photo?.small?.ref()`, so an unphotographed channel arrives here as a null
 * [Post.sourcePhoto] and falls through to the node — never as Telegram's letter in place of ours.
 */
data class PostHeading(
    val name: String,
    /** The channel subheading, or null when the channel itself is the attribution (§2.3) and carries no subheading. */
    val channelTitle: String?,
    val photo: FileRef?,
    val initial: String,
    val nodeUsername: String?,
) {
    companion object {
        fun of(post: Post): PostHeading {
            val node = post.nodeUsername
            val name = if (node != null) post.nodeName ?: "@$node" else post.sourceTitle
            return PostHeading(
                name = name,
                channelTitle = if (node != null) post.sourceTitle else null,
                photo = post.sourcePhoto ?: post.nodePhoto,
                initial = name.firstOrNull { it.isLetterOrDigit() }?.toString() ?: "·",
                nodeUsername = node,
            )
        }
    }
}
