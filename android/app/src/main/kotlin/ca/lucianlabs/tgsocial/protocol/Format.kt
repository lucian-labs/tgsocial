package ca.lucianlabs.tgsocial.protocol

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

    /** `HH:mm` today, `Mon d` this year, `yyyy-MM-dd` otherwise. */
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

    /** Video duration `m:ss` / `h:mm:ss`. */
    fun duration(seconds: Int): String {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, s) else String.format(Locale.ROOT, "%d:%02d", m, s)
    }
}
