package ca.lucianlabs.tgsocial.protocol

import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** PRODUCT §2.3 — derived, never hand-formatted. */
object Format {
    private val HHMM = DateTimeFormatter.ofPattern("HH:mm")
    private val ISO_DAY = DateTimeFormatter.ISO_LOCAL_DATE
    private val EXACT = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

    /**
     * PRODUCT §2.3 — the post card's relative age (vectored in docs/card-vectors.json `timeFormat`): largest
     * unit only, floor rounding. `now` (<60 s), `Nm ago`, `Nh ago`, `Nd ago` (<7 d), `Nw ago` (<8 w),
     * `Nmo ago` (30-day months), `Ny ago` (365-day years).
     */
    fun relative(date: LocalDateTime, now: LocalDateTime): String =
        relativeSeconds(Duration.between(date, now).seconds)

    fun relative(epochSeconds: Long, nowEpochSeconds: Long = System.currentTimeMillis() / 1000): String =
        relativeSeconds(nowEpochSeconds - epochSeconds)

    private fun relativeSeconds(diff: Long): String {
        val s = diff.coerceAtLeast(0)
        val d = s / 86_400
        return when {
            s < 60 -> "now"
            s < 3_600 -> "${s / 60}m ago"
            s < 86_400 -> "${s / 3_600}h ago"
            d < 7 -> "${d}d ago"
            d < 7 * 8 -> "${d / 7}w ago"
            d < 365 -> "${d / 30}mo ago"
            else -> "${d / 365}y ago"
        }
    }

    /** PRODUCT §2.3 — the long-press sheet's exact timestamp, `yyyy-MM-dd HH:mm` (also vectored). */
    fun exact(date: LocalDateTime): String = EXACT.format(date)

    fun exact(epochSeconds: Long, zone: ZoneId = ZoneId.systemDefault()): String =
        exact(LocalDateTime.ofInstant(Instant.ofEpochSecond(epochSeconds), zone))

    /** `HH:mm` today, `Mon d` this year, `yyyy-MM-dd` otherwise — comment rows (§2.12) and the Status sheet. */
    fun time(date: LocalDateTime, now: LocalDateTime, locale: Locale = Locale.getDefault()): String {
        val d: LocalDate = date.toLocalDate()
        val n: LocalDate = now.toLocalDate()
        return when {
            d == n -> HHMM.format(date)
            d.year == n.year -> DateTimeFormatter.ofPattern("MMM d", locale).format(date)
            else -> ISO_DAY.format(date)
        }
    }

    fun time(epochSeconds: Long, nowEpochSeconds: Long = System.currentTimeMillis() / 1000, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
        time(
            LocalDateTime.ofInstant(Instant.ofEpochSecond(epochSeconds), zone),
            LocalDateTime.ofInstant(Instant.ofEpochSecond(nowEpochSeconds), zone),
            locale,
        )

    /** Figure-compact: 999 → `999`, 1200 → `1.2k`, 15000 → `15k`, 2400000 → `2.4m`. */
    fun compact(n: Long): String {
        if (n < 1000) return n.toString()
        val suffixes = listOf("k", "m", "b")
        var value = n.toDouble()
        var idx = -1
        while (value >= 999.5 && idx < suffixes.lastIndex) {
            value /= 1000.0
            idx++
        }
        val text = if (value < 9.95) {
            val rounded = Math.round(value * 10) / 10.0
            if (rounded == Math.floor(rounded)) rounded.toLong().toString() else String.format(Locale.ROOT, "%.1f", rounded)
        } else {
            Math.round(value).toString()
        }
        return text + suffixes[idx]
    }

    fun compact(n: Int): String = compact(n.toLong())

    /** File size: `640 B`, `2.4 KB`, `2.4 MB`, `1.1 GB`. */
    fun size(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val units = listOf("KB", "MB", "GB")
        var value = bytes.toDouble()
        var idx = -1
        while (value >= 1024 && idx < units.lastIndex) {
            value /= 1024.0
            idx++
        }
        val text = if (value < 10) String.format(Locale.ROOT, "%.1f", value) else Math.round(value).toString()
        return "$text ${units[idx]}"
    }

    /** Relative age for the Status sheet: `just now`, `n min ago`, `n h ago`, else the dated form. */
    fun ago(epochMs: Long, nowMs: Long = System.currentTimeMillis()): String {
        val s = ((nowMs - epochMs) / 1000).coerceAtLeast(0)
        return when {
            s < 60 -> "just now"
            s < 3600 -> "${s / 60} min ago"
            s < 86_400 -> "${s / 3600} h ago"
            else -> time(epochMs / 1000, nowMs / 1000)
        }
    }

    /**
     * PRODUCT §2.10 — masked phone for the Status sheet: `+1 604 ••• 0199`. The three digits before the last
     * four are masked; the country code and area stay readable.
     */
    fun maskPhone(phone: String): String {
        val digits = phone.filter { it.isDigit() }
        if (digits.length <= 7) return "•••"
        val last4 = digits.takeLast(4)
        val prefix = digits.dropLast(7)
        val ccLen = (prefix.length - 3).coerceAtLeast(1).coerceAtMost(prefix.length)
        val cc = prefix.take(ccLen)
        val area = prefix.drop(ccLen)
        return listOf("+$cc", area, "•••", last4).filter { it.isNotBlank() }.joinToString(" ")
    }

    /** Video duration `m:ss` / `h:mm:ss`. */
    fun duration(seconds: Int): String {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, s) else String.format(Locale.ROOT, "%d:%02d", m, s)
    }
}
