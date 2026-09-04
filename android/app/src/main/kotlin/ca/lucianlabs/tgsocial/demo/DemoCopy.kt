package ca.lucianlabs.tgsocial.demo

import ca.lucianlabs.tgsocial.protocol.ReportMail

/**
 * PRODUCT §2.22 — every string the demo puts on screen, in one place.
 *
 * PRODUCT §3 makes copy shared across the three builds: the same control says the same words on iOS, Android
 * and web. Spelling them here rather than at the call sites is what makes that assertable — `DemoCopyTest`
 * reads these constants, so a reworded button fails the build instead of quietly making Android the odd one
 * out. §3's word list also settles the noun: this is the `demo`, never a sandbox, a sample, a test mode or a
 * fake.
 */
object DemoCopy {

    // ---- entry (PRODUCT §2.1, step 1 only)

    const val ENTER = "Look Around First"
    const val ENTER_NOTE = "Invented people, invented posts. Nothing is sent to Telegram."

    // ---- the three persistent indicators (PRODUCT §2.22 item 2)

    /** The status pill's label. Neutral, never gold — gold there means a live Telegram connection (§1). */
    const val PILL = "Demo"

    /** The strip docked under the topbar, sticky with it, and drawn over the full-screen viewers too. */
    const val STRIP = "Demo. Everyone here is invented. Nothing leaves this device."

    // ---- refusals (PRODUCT §2.22.3) — three strings, because each names a different truth

    const val NO_WRITE = "The demo doesn't write to Telegram."
    const val NOT_ON_TELEGRAM = "Nothing here is on Telegram."
    const val NO_LINKS = "Links don't open in the demo."

    // ---- the demo sheet (PRODUCT §2.22.5), which replaces the §2.10 status sheet

    const val SHEET_MARK = "Demo"
    const val SHEET_TITLE = "You're in the demo."
    const val SHEET_BODY =
        "Everyone here is invented. Nothing is sent to Telegram and nothing is saved on this device. " +
            "Report, block and mute are real and work on these fixtures."
    const val ROW_TELEGRAM = "Telegram"
    const val ROW_TELEGRAM_VALUE = "Not connected"
    const val LEAVE = "Leave Demo"
    const val CLOSE = "Close"

    // ---- exits

    const val LEFT = "Left the demo."

    /** PRODUCT §2.22.2 — the one deviation from §2.21's outcome: a demo has no session to survive. */
    const val NODE_GONE = "Your node is gone. The demo is over."

    /**
     * PRODUCT §2.22.2 — the one deviation from §2.15, which otherwise says the app adds nothing to the report
     * body. Without this line the operator opens their inbox and goes looking for a channel that does not exist.
     */
    const val REPORT_PREFIX = "Demo: this report is from the demo and the link is invented."

    /**
     * §2.15's mail, with that one line on top when the demo is running and byte-for-byte untouched when it is
     * not. Both halves of the rule live in one function so a test can hold the app to both: the demo adds
     * exactly one line, and a real report still carries nothing the app put there.
     */
    fun report(mail: ReportMail, inDemo: Boolean): ReportMail =
        if (inDemo) mail.copy(body = "$REPORT_PREFIX\n${mail.body}") else mail
}
