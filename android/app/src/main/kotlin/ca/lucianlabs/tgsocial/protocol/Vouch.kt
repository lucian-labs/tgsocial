package ca.lucianlabs.tgsocial.protocol

/** PROTOCOL §10.4 — a parsed vouch: who it is about, the one capability it names, and the body under it. */
data class VouchPointer(val node: String, val does: String, val body: String)

/**
 * PROTOCOL §10.4 — the vouch format, byte-compatible across clients. An ordinary message in the voucher's own
 * comments channel (§6.1, the one `replies:` already names), so one pass over one channel builds both indexes.
 *
 * Both lines are mandatory. A `vouch:` with no `does:` asserts "I vouch for this person", which nobody can
 * weigh and which decays into a like button inside a week — the claim is specific or it is nothing.
 */
object VouchFormat {
    /** §10.4 — the NODE channel's link: no message id, no trailing slash. A link with an id is a §6.2 comment. */
    private val TARGET = Regex("^vouch: https://t\\.me/([A-Za-z0-9_]+)\\s*$")
    private val DOES = Regex("^does: (.+)$")

    fun parse(text: String): VouchPointer? {
        val lines = text.split("\n")
        val m = TARGET.find(lines.getOrNull(0)?.trimEnd('\r').orEmpty()) ?: return null
        val node = Username.normalise(m.groupValues[1]) ?: return null
        val d = DOES.find(lines.getOrNull(1)?.trimEnd('\r').orEmpty()) ?: return null
        val does = WorkFormat.tag(d.groupValues[1]) ?: return null
        return VouchPointer(node = node, does = does, body = lines.drop(2).joinToString("\n"))
    }

    /**
     * §10.4, exact bytes. Throws on a tag §10.2 would drop rather than writing a message readers will skip —
     * PRODUCT §2.25's `Pick one thing.` is the refusal the writer sees.
     */
    fun serialise(node: String, does: String, body: String): String {
        val tag = WorkFormat.tag(does) ?: throw IllegalArgumentException("Pick one thing.")
        val target = Username.normalise(node) ?: throw IllegalArgumentException("Pick one thing.")
        val head = "vouch: ${DeepLink.channel(target)}\ndoes: $tag"
        return if (body.isEmpty()) head else "$head\n$body"
    }

    /**
     * §10.4 — a vouch for the channel's own owner is not a vouch. Unforgeable-by-construction is the whole
     * value of the format, and it holds only because the one channel a person can write is the one that
     * cannot speak about them; a client that renders a self-vouch has given that away.
     */
    fun keeps(vouch: VouchPointer?, voucherNode: String?): Boolean =
        vouch != null && !voucherNode.isNullOrEmpty() && !Username.same(vouch.node, voucherNode)
}
