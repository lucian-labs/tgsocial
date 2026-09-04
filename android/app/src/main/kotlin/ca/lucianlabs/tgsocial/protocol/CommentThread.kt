package ca.lucianlabs.tgsocial.protocol

import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.CommentNode

/**
 * PRODUCT §2.12 / PROTOCOL §6.2 — the `re:` chain resolved into a thread, and the number under a post.
 *
 * Pure, over the index alone: roots are the comments targeting the post, and a comment's replies are the
 * comments targeting *its* link. That is also why the safety filter (§2.18) filters the index rather than the
 * rendered tree — a comment that is not in the map has no children to find, so a blocked commenter takes the
 * replies under them with them, and the count derived here follows without being told.
 */
object CommentThread {

    /** Oldest first within a level so a thread reads top-down; a cycle cannot recurse (each comment once). */
    fun of(postTargetKey: String, index: Map<String, List<Comment>>): List<CommentNode> {
        val visited = HashSet<String>()
        fun nodesFor(key: String): List<CommentNode> {
            val here = index[key] ?: return emptyList()
            return here
                .filter { visited.add(it.key) }
                .sortedWith(compareBy<Comment> { it.date }.thenBy { it.messageId })
                .map { c -> CommentNode(c, CommentFormat.targetKey(c.link)?.let { nodesFor(it) } ?: emptyList()) }
        }
        return nodesFor(postTargetKey)
    }

    /** The post footer's honest number: every comment in the post's thread, from my network (§6.3). */
    fun count(postTargetKey: String, index: Map<String, List<Comment>>): Int =
        of(postTargetKey, index).sumOf { it.count }
}
