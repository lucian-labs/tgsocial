package ca.lucianlabs.tgsocial.ui.components

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import ca.lucianlabs.tgsocial.BuildConfig
import ca.lucianlabs.tgsocial.demo.DemoCopy
import ca.lucianlabs.tgsocial.demo.DemoGate
import ca.lucianlabs.tgsocial.protocol.PublicLink

/**
 * PRODUCT §2.13 — the origin `Copy Link` builds public URLs against: `TGS_PUBLIC_ORIGIN` from
 * `android/secrets.properties`, null unless a self-hoster runs a reader of their own. Resolved once
 * here so the protocol layer stays free of the generated `BuildConfig`; null is the path that copies
 * the t.me link instead.
 *
 * A value that is set but refused (see `PublicLink.origin`) is worth a line in logcat: sharing still
 * works, but it is silently not the sharing the operator configured, and a build setting nobody sees
 * fail is one they will assume took. Same treatment web gives a bad `config.json` publicOrigin
 * (`js/app.js` boot) — a warning, not a crash.
 */
val publicOrigin: String? = PublicLink.origin(BuildConfig.PUBLIC_ORIGIN).also {
    if (it == null && BuildConfig.PUBLIC_ORIGIN.isNotBlank()) {
        Log.w("tgsocial", "TGS_PUBLIC_ORIGIN is not an http(s) origin, ignoring: ${BuildConfig.PUBLIC_ORIGIN}")
    }
}

/**
 * PRODUCT §4 — links open in the system browser; t.me / tg:// land in Telegram when installed (Android app links).
 *
 * PRODUCT §2.22.3 — in the demo a link opens nothing and says why: a link in fixture text points at
 * `example.com`, and a link preview's target is invented, so both are `Links don't open in the demo.`
 * `Open in Telegram` takes the same road out of the app but is a different sentence — see [openInTelegram].
 */
fun openLink(context: Context, url: String) {
    if (DemoGate.refused(DemoCopy.NO_LINKS)) return
    view(context, url)
}

/**
 * PRODUCT §2.6 / §2.13 — `Open in Telegram`: the same system intent, from the six controls that offer it.
 *
 * PRODUCT §2.22.3 refuses this one with its own line. The refusals are split deliberately — "three strings,
 * because each names a different truth" — and the truth about `Open in Telegram` in the demo is not that
 * links are off, it is that the post, the channel or the comment being opened is not on Telegram at all. It
 * is a separate function rather than an argument to [openLink] so the call site cannot pick the wrong one by
 * omission: a control that opens a t.me link calls this, a control that opens someone's link calls that.
 */
fun openInTelegram(context: Context, url: String) {
    if (DemoGate.refused(DemoCopy.NOT_ON_TELEGRAM)) return
    view(context, url)
}

private fun view(context: Context, url: String) {
    val uri = runCatching { Uri.parse(if (url.startsWith("http") || url.startsWith("tg:")) url else "https://$url") }.getOrNull() ?: return
    val intent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    runCatching { context.startActivity(intent) }
}

/** PRODUCT §2.3 — Share: the system share sheet (the one sanctioned system chrome) with the post's t.me link. */
fun shareLink(context: Context, url: String) {
    // PRODUCT §2.22.3 — sharing a t.me link for a post that is not on Telegram is the one thing this control
    // must not do, so the demo answers with the sentence that says why.
    if (DemoGate.refused(DemoCopy.NOT_ON_TELEGRAM)) return
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, url)
    }
    runCatching { context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}

/**
 * PRODUCT §2.15 / §2.19 — the mail composer, `ACTION_SENDTO` on a `mailto:` URI so only mail apps answer.
 *
 * Returns whether one did. That is the whole of what the app can know about a report: the composer is the
 * user's, and nothing after this point tells us whether they pressed send — which is why hiding does not wait
 * for it (§2.15). A device with no mail app returns false and the toast names the address instead.
 */
fun openMail(context: Context, to: String, subject: String = "", body: String = ""): Boolean {
    val query = buildList {
        if (subject.isNotEmpty()) add("subject=${Uri.encode(subject)}")
        if (body.isNotEmpty()) add("body=${Uri.encode(body)}")
    }.joinToString("&")
    val uri = runCatching { Uri.parse("mailto:$to" + if (query.isEmpty()) "" else "?$query") }.getOrNull() ?: return false
    val intent = Intent(Intent.ACTION_SENDTO, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    return runCatching { context.startActivity(intent) }.isSuccess
}

/** PRODUCT §2.6 / §2.13 — `Copy Link` puts the public URL on the clipboard (the t.me one when no origin is set). */
fun copyToClipboard(context: Context, text: String): Boolean {
    if (DemoGate.refused(DemoCopy.NOT_ON_TELEGRAM)) return false
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return false
    return runCatching { clipboard.setPrimaryClip(ClipData.newPlainText(text, text)) }.isSuccess
}
