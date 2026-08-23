package ca.lucianlabs.tgsocial.protocol

/** PROTOCOL §2 — Telegram username rules: 5–32 chars, [A-Za-z0-9_], no leading digit. */
object Username {
    private val VALID = Regex("^[A-Za-z_][A-Za-z0-9_]{4,31}$")

    /** Accepts `@name`, `name`, `https://t.me/name`, `t.me/name/`. Returns the username without `@` (casing kept) or null. */
    fun normalise(input: String): String? {
        var s = input.trim()
        s = s.removePrefix("https://").removePrefix("http://")
        s = s.removePrefix("www.")
        s = s.removePrefix("t.me/").removePrefix("telegram.me/")
        s = s.removePrefix("@")
        s = s.trimEnd('/')
        if (s.contains('/')) s = s.substringBefore('/')
        if (s.contains('?')) s = s.substringBefore('?')
        return if (VALID.matches(s)) s else null
    }

    fun key(username: String): String = username.lowercase()

    fun same(a: String, b: String): Boolean = a.equals(b, ignoreCase = true)

    /** A card token must carry its `@` (or be a t.me link); bare names are not usernames inside a card. */
    fun isCardToken(token: String): Boolean = token.startsWith("@") || token.contains("t.me/")

    /** Parses a whitespace-separated card token list, dropping invalid tokens and collapsing duplicates to the first. */
    fun list(value: String): List<String> {
        val out = ArrayList<String>()
        val seen = HashSet<String>()
        for (token in value.split(Regex("\\s+"))) {
            if (token.isBlank() || !isCardToken(token)) continue
            val u = normalise(token) ?: continue
            if (seen.add(key(u))) out += u
        }
        return out
    }
}
