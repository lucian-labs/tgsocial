# tgsocial public reader — v1

How a tgsocial page renders for someone with no account: it reads Telegram's
own public preview, `https://t.me/s/<channel>`, which Telegram serves to
anonymous browsers.

This exists because **TDLib cannot help here**. Every chat read —
`searchPublicChat`, `getChat`, `getChatHistory` — returns `401 Unauthorized`
before authorization; only `getOption`-class calls answer. That was measured
twice against live Telegram and `web/test/smoke.mjs` asserts it so nobody
re-assumes otherwise. The preview is a different door onto the same public
data, and it is the door browsers are allowed through.

## 1. The proxy

`t.me` sends no `Access-Control-Allow-Origin`, so a browser cannot fetch it
directly. nginx proxies it under our own origin and caches it:

```
location /tg/s/ {
    proxy_pass https://t.me/s/;
    proxy_set_header Host t.me;
    proxy_set_header User-Agent "tgsocial/1.0 (+https://tgsocial.lucianlabs.ca)";
    proxy_cache tgpreview;
    proxy_cache_valid 200 60s;          # a page is a lens, not an archive
    proxy_cache_use_stale error timeout updating;
    proxy_cache_lock on;                # one upstream fetch per key, not a stampede
    add_header Access-Control-Allow-Origin "*";
    add_header X-Cache $upstream_cache_status;
}
```

Rules this proxy obeys, and why:

- **Only `/s/`.** It proxies the preview path and nothing else — not `t.me/`
  join pages, not the API. A path that is not a bare channel (optionally with
  `?before=`) is refused.
- **60 seconds.** Long enough that a busy page costs Telegram one fetch,
  short enough that a deleted post disappears quickly. `proxy_cache_lock`
  means a hundred simultaneous readers still produce one upstream request.
- **No storage beyond the cache.** Nothing is written to a database. The page
  is a lens: delete the post on Telegram and it is gone here on the next
  fetch.
- **Identifies itself.** A real User-Agent with a contact URL, because
  scraping anonymously and lying about it is how you get blocked, and
  deservedly.

## 2. What the preview carries

Verified against `t.me/s/tastycrow` and `t.me/s/tgs_dankcoin`:

| Need | Where it is |
| --- | --- |
| Post id + channel | `data-post="tastycrow/3"` → `{ channel, messageId }`, and the `t.me` deep link |
| Text | `.tgme_widget_message_text` (inner HTML: `<br>` for newlines, `<a>` for links, `<b>/<i>/<code>` for entities) |
| Time | `<time datetime="2026-08-23T23:09:48+00:00">` |
| Views | `.tgme_widget_message_views` (e.g. `1`, `1.2K`) |
| Photo | `.tgme_widget_message_photo_wrap` with `background-image:url('…')` |
| Video / doc / voice | `.tgme_widget_message_video`, `_document`, `_voice` (+ duration, name, size) |
| Channel title / avatar / description | `og:title`, `og:image`, `og:description` and the page header |
| The **card** | the pinned/first message whose text starts `tgsocial v1` — parsed by the existing `parseCard` |
| The **backlink** | the channel description containing `tgsocial: @<node>` |
| Older posts | `?before=<messageId>` |

Service messages (`Channel created`, `Channel photo updated`) are skipped,
as they are in the app.

## 3. The parser

One module, `web/js/public/preview.js`, used by every public surface (the
tgsocial site and any domain front-end). Pure: HTML string in, tgsocial
model out — the same `Post` shape §2.3 renders, so the public page and the
signed-in page share every component.

```js
parsePreview(html, channel) // → { channel: {username,title,photo,description,verifiedFor}, posts: [Post], nextBefore }
```

It must be defensive by construction: Telegram's markup is not a contract,
so an unrecognised block becomes a post with the text it could find rather
than a thrown error, and a page that parses to zero posts is reported as
`unavailable`, never as an empty channel. Fixtures of real HTML live in
`web/test/fixtures/` so a markup change fails a test instead of a page.

**Sanitisation is not optional.** Every string out of the preview is
untrusted third-party HTML. The parser returns *text and structured
entities*, never HTML, and the renderer builds nodes — no `innerHTML` of
preview content anywhere. Links are rendered with `rel="noopener nofollow
ugc"`, and any `javascript:`/`data:` URL is dropped.

## 4. Resolving `/u/<name>`

1. Fetch `/tg/s/<name>`. If its card parses (`tgsocial v1`), `<name>` is the
   node.
2. Otherwise, if its description carries `tgsocial: @<node>`, fetch
   `/tg/s/<node>` and use that.
3. Otherwise the name is not a tgsocial person → the §2.6 empty card.

Then read the node's card `feeds:`, fetch each, and merge newest-first with
the same k-way merge as `PROTOCOL §4.8`. `?before=` per source drives
"load more", so the endless scroll is real rather than a fixed page.

A node whose card says `public: no` is not served on a public page at all —
that flag is the owner saying "not in directories", and a public URL is a
directory of one.

## 5. Limits, honestly

- **Recent history only.** The preview pages back through `?before=` but
  Telegram does not serve unlimited history this way. Deep archives need the
  app.
- **No comments.** Comments are network-scoped (`PROTOCOL §6.3`) and a
  visitor has no network, so public pages show none.
- **Markup can change.** Telegram owes us nothing here. The fixtures make
  that a failing test rather than a silent blank page, and the app itself is
  unaffected — it uses TDLib.
- **Not a mirror.** No archive, no index, no reposting. If a channel goes
  private or a post is deleted, the page follows within the cache window.
