package ca.lucianlabs.tgsocial.protocol

/**
 * PROTOCOL §6.1 — a node's comments channel: how it is named, how it says whose it is, and which one a
 * `delete my node` (§4.11) has to take with the node.
 *
 * [Declared] is the card's own word; [Guessed] is the convention, reached only when the card cannot be read.
 * The distinction is the whole point of the type: a declared channel is the node's by the node's own record,
 * and a guessed one is not the app's to delete until Telegram says it is.
 */
sealed class RepliesTarget {
    abstract val username: String?

    /** The card was read and names no comments channel: nothing to delete, and §2.21 skips step one silently. */
    data object None : RepliesTarget() {
        override val username: String? = null
    }

    /** The card names it (`replies: @x`). It is the node's comments channel by declaration. */
    data class Declared(override val username: String) : RepliesTarget()

    /**
     * The card could not be read, so §6.1's `<node>_r` convention is the only lead there is. A guess is not a
     * licence to delete a public channel: the caller acts on it only once Telegram agrees the channel is this
     * node's — mine to delete, and describing itself as `@<node>`'s replies channel (§6.4's backlink).
     */
    data class Guessed(override val username: String) : RepliesTarget()
}

object Replies {
    /** §6.1 — the convention: `<node>_r`, inside Telegram's 32-character username limit. */
    fun convention(nodeUsername: String): String = "${nodeUsername}_r".take(32)

    /** §6.4 — the description a comments channel is created with, and the backlink that says whose it is. */
    fun description(nodeUsername: String): String = "${CardFormat.MARKER} replies · @$nodeUsername"

    /**
     * §6.4 — "the reply channel's description backlink lets readers verify it belongs to the node". Written
     * by [description]; matched loosely enough to survive an owner who appended their own words to it, and
     * strictly enough that a channel merely *named* `<node>_r` does not pass.
     */
    fun describesRepliesFor(description: String, nodeUsername: String): Boolean {
        val text = description.trim()
        if (!CardFormat.descriptionLooksLikeNode(text)) return false
        if (!text.contains("replies", ignoreCase = true)) return false
        return NODE_REF.findAll(text).any { it.groupValues[1].equals(nodeUsername, ignoreCase = true) }
    }

    /**
     * PROTOCOL §4.11 / PRODUCT §2.21 — what step one of a delete aims at.
     *
     * The card is the record (§6.1), so when it parses it decides. When it does **not** parse the app is not
     * entitled to read that as "no comments channel": a card can be absent while the node is plainly there —
     * a `tgsocial v2` card this build refuses to parse (§9) keeps the node and drops the card, and so does a
     * pinned-message read that failed on a bad network. Settings still offers `Delete My Node` in both
     * states, and taking `card?.replies == null` at face value there is how `@<node>_r` is left public,
     * backlinking to a node that no longer exists — the exact outcome §4.11's fixed order exists to prevent.
     */
    fun target(card: Card?, nodeUsername: String): RepliesTarget = when {
        card != null -> card.replies?.let { RepliesTarget.Declared(it) } ?: RepliesTarget.None
        nodeUsername.isBlank() -> RepliesTarget.None
        else -> RepliesTarget.Guessed(convention(nodeUsername))
    }

    private val NODE_REF = Regex("@([A-Za-z0-9_]+)")
}
