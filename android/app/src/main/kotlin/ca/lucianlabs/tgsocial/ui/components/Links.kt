package ca.lucianlabs.tgsocial.ui.components

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import ca.lucianlabs.tgsocial.BuildConfig
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

/** PRODUCT §4 — links open in the system browser; t.me / tg:// land in Telegram when installed (Android app links). */
fun openLink(context: Context, url: String) {
    val uri = runCatching { Uri.parse(if (url.startsWith("http") || url.startsWith("tg:")) url else "https://$url") }.getOrNull() ?: return
    val intent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    runCatching { context.startActivity(intent) }
}

/** PRODUCT §2.3 — Share: the system share sheet (the one sanctioned system chrome) with the post's t.me link. */
fun shareLink(context: Context, url: String) {
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, url)
    }
    runCatching { context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}

/** PRODUCT §2.6 / §2.13 — `Copy Link` puts the public URL on the clipboard (the t.me one when no origin is set). */
fun copyToClipboard(context: Context, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
    runCatching { clipboard.setPrimaryClip(ClipData.newPlainText(text, text)) }
}
