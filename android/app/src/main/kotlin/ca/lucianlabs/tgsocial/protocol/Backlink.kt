package ca.lucianlabs.tgsocial.protocol

/** PROTOCOL §3 — a feed whose description contains `tgsocial: @node` is verified for that node. */
object Backlink {
    private val PATTERN = Regex("tgsocial:\\s*@([A-Za-z0-9_]+)", RegexOption.IGNORE_CASE)

    fun isVerified(description: String, node: String): Boolean =
        PATTERN.findAll(description).any { it.groupValues[1].equals(node, ignoreCase = true) }

    fun line(node: String): String = "tgsocial: @$node"

    /**
     * The description with the backlink appended (no-op when already present), or null when it would not fit
     * Telegram's 255 chars. Never replaces the owner's text: the caller surfaces "Description is full." instead.
     */
    fun append(description: String, node: String): String? {
        if (isVerified(description, node)) return description
        val base = description.trimEnd()
        val joined = if (base.isEmpty()) line(node) else "$base · ${line(node)}"
        return if (joined.length <= 255) joined else null
    }
}
