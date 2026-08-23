package ca.lucianlabs.tgsocial.ui.components

import android.content.Context
import android.content.Intent
import android.net.Uri

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
