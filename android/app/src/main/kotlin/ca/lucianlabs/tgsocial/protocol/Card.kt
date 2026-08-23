package ca.lucianlabs.tgsocial.protocol

import kotlinx.serialization.Serializable

/** PROTOCOL §2 — the pinned message of a node channel. */
@Serializable
data class Card(
    val name: String? = null,
    val bio: String? = null,
    val link: String? = null,
    val public: Boolean = true,
    val feeds: List<String> = emptyList(),
    val follows: List<String> = emptyList(),
) {
    fun follows(username: String): Boolean = follows.any { Username.same(it, username) }
    fun hasFeed(username: String): Boolean = feeds.any { Username.same(it, username) }

    fun withFollow(username: String): Card =
        if (follows(username)) this else copy(follows = follows + username)

    fun withoutFollow(username: String): Card =
        copy(follows = follows.filterNot { Username.same(it, username) })

    fun serialise(): String = CardFormat.serialise(this)

    companion object {
        const val MAX_LENGTH = 4096
    }
}

/** Outcome of reading a pinned message. */
sealed class CardParse {
    data class Parsed(val card: Card) : CardParse()
    /** Marker is `tgsocial vN` with N > 1 — "Newer card. Update the app." */
    data object Newer : CardParse()
    /** Not a tgsocial card at all. */
    data object NotACard : CardParse()

    val cardOrNull: Card? get() = (this as? Parsed)?.card
}

object CardFormat {
    const val MARKER = "tgsocial v1"
    private val MARKER_ANY = Regex("^tgsocial v(\\d+)$")
    private val KEY_ORDER = listOf("name", "bio", "link", "public", "feeds", "follows")

    fun parse(text: String): CardParse {
        val lines = text.split("\n").map { it.trimEnd('\r') }
        val first = lines.firstOrNull()?.trim() ?: return CardParse.NotACard
        if (first != MARKER) {
            val m = MARKER_ANY.find(first) ?: return CardParse.NotACard
            val v = m.groupValues[1].toIntOrNull() ?: return CardParse.NotACard
            return if (v > 1) CardParse.Newer else CardParse.NotACard
        }
        val values = LinkedHashMap<String, StringBuilder>()
        for (line in lines.drop(1)) {
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            val key = line.substring(0, colon).trim().lowercase()
            if (key.isEmpty() || key.any { !(it in 'a'..'z' || it in '0'..'9' || it == '_') }) continue
            val value = line.substring(colon + 1).trim()
            val sb = values.getOrPut(key) { StringBuilder() }
            if (sb.isNotEmpty() && value.isNotEmpty()) sb.append(' ')
            sb.append(value)
        }
        fun str(key: String): String? = values[key]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        val public = str("public")?.let { !it.equals("no", ignoreCase = true) } ?: true
        return CardParse.Parsed(
            Card(
                name = str("name"),
                bio = str("bio"),
                link = str("link"),
                public = public,
                feeds = str("feeds")?.let { Username.list(it) } ?: emptyList(),
                follows = str("follows")?.let { Username.list(it) } ?: emptyList(),
            )
        )
    }

    fun serialise(card: Card): String {
        val sb = StringBuilder(MARKER)
        fun line(key: String, value: String?) {
            val v = value?.trim().orEmpty()
            if (v.isEmpty()) return
            sb.append('\n').append(key).append(": ").append(v)
        }
        for (key in KEY_ORDER) {
            when (key) {
                "name" -> line(key, card.name)
                "bio" -> line(key, card.bio)
                "link" -> line(key, card.link)
                "public" -> line(key, if (card.public) "yes" else "no")
                "feeds" -> line(key, card.feeds.joinToString(" ") { "@$it" })
                "follows" -> line(key, card.follows.joinToString(" ") { "@$it" })
            }
        }
        return sb.toString()
    }

    /** True when the serialised card would not fit in a Telegram message. */
    fun isFull(card: Card): Boolean = serialise(card).length > Card.MAX_LENGTH

    /** The node channel description SHOULD begin with the marker (PROTOCOL §2). */
    fun description(bio: String?): String {
        val b = bio?.trim().orEmpty()
        val s = if (b.isEmpty()) MARKER else "$MARKER · $b"
        return if (s.length > 255) s.substring(0, 255) else s
    }

    fun descriptionLooksLikeNode(description: String): Boolean = description.trimStart().startsWith("tgsocial v")

    /** Is this message text the card itself (any version)? Used to skip it in feeds. */
    fun isCardText(text: String): Boolean = MARKER_ANY.containsMatchIn(text.lineSequence().firstOrNull()?.trim().orEmpty())
}
