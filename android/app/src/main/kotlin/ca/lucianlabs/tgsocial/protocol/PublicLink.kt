package ca.lucianlabs.tgsocial.protocol

/**
 * PRODUCT §2.13 — the public web address of a feed.
 *
 * There is no canonical host: the public reader is something a self-hoster runs
 * (`PUBLIC.md`, `web/nginx-public.conf`), so its origin is optional configuration —
 * `TGS_PUBLIC_ORIGIN` in `android/secrets.properties`, reaching the app as
 * `BuildConfig.PUBLIC_ORIGIN` and empty unless someone sets it.
 *
 * Unset — the state of every fresh clone — a link is the t.me link (PROTOCOL §4.8).
 * That one needs nobody's server and points at where the post actually lives, which is
 * the honest default for a network whose storage layer is Telegram.
 *
 * The origin arrives as an argument rather than being read here, so `protocol/` stays
 * free of the app's generated `BuildConfig` (README) and both branches are testable
 * without a second build variant. `ui/components/Links.kt` resolves it once.
 */
object PublicLink {
    /**
     * Scheme and host, nothing else — the shape `origin` accepts. Deliberately the same
     * expression as `setPublicOrigin` in `web/js/protocol.js`, so one `TGS_PUBLIC_ORIGIN`
     * value means one thing across the clients a self-hoster points at their reader.
     */
    private val ORIGIN = Regex("^https?://[^/?#\\s]+$")

    /**
     * The configured origin, or null — both when nothing is set and when what is set is
     * not an origin this can build a reachable link from. Blank counts as unset: an empty
     * `TGS_PUBLIC_ORIGIN=` line means "no reader of my own", not an origin of `""`.
     *
     * The check earns its keep because every refused shape mints a broken `Copy Link`
     * rather than an obvious failure. A bare `tgs.example.org` stops being a link the
     * moment it is pasted into a chat; a path-carrying origin mints `<origin>/tgs/f/x`,
     * which neither the reader's root-anchored routes (`parsePublicPath` in
     * `web/js/protocol.js`) nor `web/nginx-public.conf` serve; `javascript:` is not an
     * origin at all. Refusing is not fatal — `Copy Link` falls back to the t.me link,
     * which always works — so the caller logs it rather than this failing the build.
     *
     * A trailing `/` is dropped before the check, so `https://tgs.example.org` and
     * `.../` are the same origin and build the same path.
     */
    fun origin(configured: String?): String? =
        configured?.trim()?.trimEnd('/')?.takeIf { ORIGIN.matches(it) }

    /**
     * `<origin>/f/<channel>` — the link `Copy Link` copies — or `https://t.me/<channel>`
     * when no origin is configured. Casing is the caller's; Telegram usernames are
     * case-insensitive and the one the user is looking at is the one they get.
     */
    fun feed(username: String, origin: String?): String =
        if (origin == null) DeepLink.channel(username) else "$origin/f/$username"
}
