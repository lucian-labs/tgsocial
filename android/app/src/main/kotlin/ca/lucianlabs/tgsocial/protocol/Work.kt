package ca.lucianlabs.tgsocial.protocol

import kotlinx.serialization.Serializable
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.format.ResolverStyle
import java.time.temporal.ChronoUnit
import java.util.Locale

/**
 * PROTOCOL §10.3 — expiring intent. [intent] is one of [WorkFormat.INTENTS]; [until] is `YYYY-MM-DD`, UTC.
 * Nothing here records when it was written: both reader rules are arithmetic on this date alone.
 */
@Serializable
data class WorkOpen(val intent: String, val until: String)

/**
 * PROTOCOL §10.2 — the work card: four optional keys, all self-claims, none of them checkable by anyone
 * (§10.8). It hangs off [Card] rather than replacing anything on it, which is what makes §10 an extension
 * instead of a version.
 */
@Serializable
data class WorkCard(
    val role: String? = null,
    val does: List<String> = emptyList(),
    val open: WorkOpen? = null,
    /** Feeds of mine that are work. Every entry also appears in the card's own `feeds:` (§10.2). */
    val feeds: List<String> = emptyList(),
) {
    val isEmpty: Boolean get() = role == null && does.isEmpty() && open == null && feeds.isEmpty()

    fun marks(feed: String): Boolean = feeds.any { Username.same(it, feed) }
}

/**
 * PROTOCOL §10 — the work extension, read as a SECOND pass over the same bytes [CardFormat] already read.
 *
 * [CardFormat] knows nothing about any of this and is not touched by it: `work.role` carries a `.`, which
 * §2's key filter already rejects, so a card with these lines parses into exactly the card it parsed before
 * this file existed. Delete this file and the network still works — that is §10's whole claim, and
 * `docs/card-vectors.json` runs it as a test through the §2 loop every client already has.
 *
 * The two meet in one place: [CardFormat.serialise] emits these lines when, and only when, it is handed a
 * [WorkCard]. That is §10.6 — a client that read the keys has to write them back, or the next follow
 * silently deletes somebody's work card.
 */
object WorkFormat {
    const val ROLE_MAX = 80
    const val DOES_MAX = 12

    /**
     * §10.3 — a date further out than this is not a statement about now. Without it `until 2099-01-01` is an
     * expiry nobody ever has to renew, which is the same as no expiry, which is what the key exists to avoid.
     */
    const val OPEN_HORIZON_DAYS = 180L

    /** §10.3 — closed set. A client cannot render a word it has no copy for, so an unknown intent is absent. */
    val INTENTS: List<String> = listOf("work", "contract", "hiring", "collab")

    /** §10.2 — lowercase, 2–24, and the punctuation real trades carry: `c++`, `c#`, `node.js`, `front of house`. */
    private val TAG = Regex("^[a-z0-9][a-z0-9 +#.-]{0,22}[a-z0-9+#]$")
    private val WORK_KEYS = setOf("work.role", "work.does", "work.open", "work.feeds")
    private val OPEN = Regex("^([A-Za-z]+)\\s+until\\s+(\\S+)$")
    private val WHITESPACE = Regex("\\s+")
    /**
     * §10.2 — STRICT, so `2026-02-30` is not a day. The lenient resolver quietly folds it back to the 28th,
     * which would make a card carrying an impossible date render an intent that expires on a date nobody
     * wrote — the value is malformed and the key is absent, which is what the vector asserts.
     */
    private val DAY = DateTimeFormatter.ofPattern("uuuu-MM-dd", Locale.ROOT).withResolverStyle(ResolverStyle.STRICT)

    // ---------------------------------------------------------------- tags

    /** One capability tag, normalised: trimmed, inner whitespace collapsed, lowercased. Invalid → null. */
    fun tag(input: String?): String? {
        val s = input?.trim()?.replace(WHITESPACE, " ")?.lowercase() ?: return null
        return if (TAG.matches(s)) s else null
    }

    /** `a, b, c` → up to [DOES_MAX] tags. An invalid tag is dropped and the rest of the line stands (§10.2). */
    fun does(value: String?): List<String> {
        if (value.isNullOrBlank()) return emptyList()
        val out = ArrayList<String>(DOES_MAX)
        val seen = HashSet<String>()
        for (part in value.split(',')) {
            val tag = tag(part) ?: continue
            if (!seen.add(tag)) continue
            out += tag
            if (out.size == DOES_MAX) break
        }
        return out
    }

    // ---------------------------------------------------------------- dates

    /** A real calendar day in `YYYY-MM-DD`. `2026-02-30` matches the shape and is not one. */
    fun isCalendarDay(s: String?): Boolean = day(s) != null

    private fun day(s: String?): LocalDate? {
        if (s == null || s.length != 10) return null
        return try {
            LocalDate.parse(s, DAY)
        } catch (_: DateTimeParseException) {
            null
        }
    }

    /** Whole days from [a] to [b], both `YYYY-MM-DD`. Negative when [b] is behind [a]. */
    fun daysBetween(a: String, b: String): Long {
        val from = day(a) ?: return 0
        val to = day(b) ?: return 0
        return ChronoUnit.DAYS.between(from, to)
    }

    /** §10.3 — today, UTC, in the form the card writes. */
    fun today(): String = LocalDate.now(ZoneOffset.UTC).format(DAY)

    /** `<intent> until <YYYY-MM-DD>` → [WorkOpen]; anything else, including an unknown intent, → null. */
    fun parseOpen(value: String?): WorkOpen? {
        val m = OPEN.find(value?.trim().orEmpty()) ?: return null
        val intent = m.groupValues[1].lowercase()
        if (intent !in INTENTS) return null
        val until = m.groupValues[2]
        if (!isCalendarDay(until)) return null
        return WorkOpen(intent, until)
    }

    fun serialiseOpen(open: WorkOpen?): String = open?.let { "${it.intent} until ${it.until}" }.orEmpty()

    /**
     * §10.3 — is this intent a statement about *now*? Expired is the obvious half; the horizon is the other,
     * and it is the one that makes the first mean anything. Pure arithmetic on the card text: no write date
     * exists to compare against, and none is needed.
     */
    fun openIsCurrent(open: WorkOpen?, today: String = today()): Boolean {
        if (open == null || !isCalendarDay(open.until) || !isCalendarDay(today)) return false
        val days = daysBetween(today, open.until)
        return days >= 0 && days <= OPEN_HORIZON_DAYS
    }

    /** Days from today until [open] ends — negative once it has. Null when there is no readable date. */
    fun daysLeft(open: WorkOpen?, today: String = today()): Long? {
        if (open == null || !isCalendarDay(open.until)) return null
        return daysBetween(today, open.until)
    }

    // ---------------------------------------------------------------- the card

    /**
     * The §10 pass over a card's text. Null when the text is not a v1 card, or carries nothing §10 can use —
     * so "has a work card" is one null check, and a card whose every work line is malformed is the same as a
     * card with none (§10.2).
     *
     * `work.feeds` is intersected with `feeds:` here rather than trusted: `feeds:` is the ownership claim
     * (§3 requires post rights for it), so a marking line has no business introducing a channel the owner
     * never claimed.
     */
    fun parse(text: String): WorkCard? {
        val card = (CardFormat.parse(text) as? CardParse.Parsed)?.card ?: return null
        val raw = LinkedHashMap<String, StringBuilder>()
        val lines = text.split("\n").map { it.trimEnd('\r') }
        for (line in lines.drop(1)) {
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            val key = line.substring(0, colon).trim().lowercase()
            if (key !in WORK_KEYS) continue
            val value = line.substring(colon + 1).trim()
            // §10.2 — repetition follows §2: a repeated key concatenates with a space.
            val sb = raw.getOrPut(key) { StringBuilder() }
            if (sb.isNotEmpty() && value.isNotEmpty()) sb.append(' ')
            sb.append(value)
        }
        val role = raw["work.role"]?.toString()?.replace(WHITESPACE, " ")?.trim().orEmpty()
        val work = WorkCard(
            role = role.takeIf { it.isNotEmpty() }?.take(ROLE_MAX),
            does = does(raw["work.does"]?.toString()),
            open = parseOpen(raw["work.open"]?.toString()),
            feeds = Username.list(raw["work.feeds"]?.toString().orEmpty()).filter { card.hasFeed(it) },
        )
        return work.takeIf { !it.isEmpty }
    }

    /**
     * The §10 pass attached to a card the caller already parsed with §2's own parser — the one call site that
     * joins the two passes on the read side, so §10.6's "write back what you read" holds for every card that
     * enters the app rather than for the ones somebody remembered.
     */
    fun attach(card: Card?, text: String?): Card? {
        if (card == null) return null
        return card.copy(work = text?.let { parse(it) })
    }

    /** The §10 lines, in §10.2 order, for [CardFormat.serialise] to append after `replies`. */
    /**
     * [feeds] is the card's own `feeds:`. §10.2 says `work.feeds` is a marking on channels the card
     * already claims, so the intersection is enforced on the write side here exactly as [parse] enforces
     * it on the read side: no caller can put an entry on the wire the card does not list. A stale marking
     * is latent rather than harmless — readers ignore it today and it re-marks the channel as work the
     * moment the owner lists it again, with nobody touching the toggle.
     */
    fun lines(work: WorkCard?, feeds: List<String> = emptyList()): List<String> {
        if (work == null) return emptyList()
        val out = ArrayList<String>(4)
        val role = work.role?.replace(WHITESPACE, " ")?.trim()?.take(ROLE_MAX).orEmpty()
        if (role.isNotEmpty()) out += "work.role: $role"
        val does = does(work.does.joinToString(","))
        if (does.isNotEmpty()) out += "work.does: ${does.joinToString(", ")}"
        val open = parseOpen(serialiseOpen(work.open))
        if (open != null) out += "work.open: ${serialiseOpen(open)}"
        val marked = Username.list(work.feeds.joinToString(" ") { "@${it.removePrefix("@")}" })
            .filter { m -> feeds.any { Username.same(it, m) } }
        if (marked.isNotEmpty()) out += "work.feeds: ${marked.joinToString(" ") { "@$it" }}"
        return out
    }

    // ---------------------------------------------------------------- display (PRODUCT §2.23)

    /** The four intent strings, verbatim (PRODUCT §2.23). An intent outside the set has no copy and no pill. */
    fun intentLabel(intent: String?): String? = when (intent) {
        "work" -> "Open to work"
        "contract" -> "Open to contract"
        "hiring" -> "Hiring"
        "collab" -> "Open to collaborate"
        else -> null
    }

    /**
     * PRODUCT §2.23 — `until 1 Dec`: day and month, derived, the year appended only when it is not this one.
     * Derived rather than recalled, like every other date this app prints.
     */
    fun untilLabel(until: String, today: String = today(), locale: Locale = Locale.getDefault()): String? {
        val end = day(until) ?: return null
        val now = day(today) ?: return null
        val pattern = if (end.year == now.year) "d MMM" else "d MMM yyyy"
        return "until " + DateTimeFormatter.ofPattern(pattern, locale).format(end)
    }

    /**
     * PRODUCT §2.25 — a vouch's date is a month and a year. Everywhere else time is relative because a post's
     * recency is what matters; here `2y ago` buries the thing the reader is weighing.
     */
    fun monthYear(epochSeconds: Long, locale: Locale = Locale.getDefault()): String =
        DateTimeFormatter.ofPattern("MMM yyyy", locale)
            .format(java.time.LocalDateTime.ofInstant(java.time.Instant.ofEpochSecond(epochSeconds), java.time.ZoneId.systemDefault()))

    /** PRODUCT §2.23 — the writer's three horizons, as day counts. */
    val HORIZONS: List<Int> = listOf(30, 60, 90)

    /**
     * Which `FOR` tab the Edit Card modal opens on for a card that already carries intent: the shortest
     * horizon that still covers what is left of it.
     *
     * Seeded, not defaulted, because the tabs are also what Save writes. A modal that opens on `30 days`
     * over a card reading `until <today+90>` reports a horizon the card does not have, contradicts the pill
     * on the profile next to it, and then makes itself true on the next Save — shortening published intent
     * (§10.3) with no refusal and no note, triggered by editing the bio.
     */
    fun horizonFor(open: WorkOpen?, today: String = today()): Int {
        val left = daysLeft(open, today) ?: return HORIZONS.first()
        return HORIZONS.firstOrNull { it >= left } ?: HORIZONS.last()
    }

    /** `today + days`, in card form — what the FOR tabs write and what `Ends 5 Dec 2026.` is derived from. */
    fun horizonDate(days: Int, today: String = today()): String {
        val now = day(today) ?: LocalDate.now(ZoneOffset.UTC)
        return now.plusDays(days.toLong()).format(DAY)
    }

    /** `Ends 5 Dec 2026.` — the faint line under FOR (PRODUCT §2.23); the date is derived, never typed. */
    fun endsLabel(until: String, locale: Locale = Locale.getDefault()): String? {
        val end = day(until) ?: return null
        return "Ends " + DateTimeFormatter.ofPattern("d MMM yyyy", locale).format(end) + ". After that it stops showing."
    }
}
