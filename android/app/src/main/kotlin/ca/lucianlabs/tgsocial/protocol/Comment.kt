package ca.lucianlabs.tgsocial.protocol

/** PROTOCOL §6.2 — a parsed comment: the `re:` target link and the body after the first newline. */
data class CommentPointer(val target: String, val body: String)

/**
 * PROTOCOL §6.2 / §6.5 — the comment format, byte-compatible across clients: `re: ` prefix, one space, a full
 * `https://t.me/...` post link, newline, body. A message without that first line is not a comment.
 */
object CommentFormat {
    private const val PREFIX = "re: "

    /** `https://t.me/<username>/<serverMessageId>` — the deep-link form of PROTOCOL §4.8. */
    private val LINK = Regex("^https://t\\.me/([A-Za-z_][A-Za-z0-9_]{4,31})/(\\d+)$")

    fun parse(text: String): CommentPointer? {
        val firstLine = text.substringBefore('\n').trimEnd('\r')
        if (!firstLine.startsWith(PREFIX)) return null
        val target = firstLine.removePrefix(PREFIX).trim()
        if (!LINK.matches(target)) return null
        val body = if ('\n' in text) text.substringAfter('\n') else ""
        return CommentPointer(target = target, body = body)
    }

    fun serialise(target: String, body: String): String =
        if (body.isEmpty()) "$PREFIX$target" else "$PREFIX$target\n$body"

    /** Case-insensitive key for indexing by target: `username/serverId`, username lowercased. */
    fun targetKey(link: String): String? {
        val m = LINK.find(link.trim()) ?: return null
        return "${m.groupValues[1].lowercase()}/${m.groupValues[2]}"
    }

    /** The key of a post's own deep link — what its comments carry as their target. */
    fun postKey(username: String, messageId: Long): String =
        "${username.lowercase()}/${DeepLink.serverMessageId(messageId)}"
}
