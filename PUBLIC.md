# tgsocial public reader — v1

How a tgsocial page renders for someone with no account: it reads Telegram's
own public preview, `https://t.me/s/<channel>`, which Telegram serves to
anonymous browsers.

**This is a spec for what you deploy, not a description of something we run.**
There is no hosted tgsocial. If you want URLs like `/u/<name>` that a person
with no Telegram client can open, you stand up the web bundle on an origin you
control and add the one nginx location in §1 — that is the entire server side
of it, and everything below is written from where you are standing. Skip it
and the apps still work; share actions just hand out `t.me` links instead
(`PRODUCT §2.13`), which cost nobody a host.

This exists because **TDLib cannot help here**. Every chat read —
`searchPublicChat`, `getChat`, `getChatHistory` — returns `401 Unauthorized`
before authorization; only `getOption`-class calls answer. That was measured
twice against live Telegram and `web/test/smoke.mjs` asserts it so nobody
re-assumes otherwise. The preview is a different door onto the same public
data, and it is the door browsers are allowed through.

## 1. The proxy

`t.me` sends no `Access-Control-Allow-Origin`, so a browser cannot fetch it
directly. nginx proxies it under your own origin and caches it — the deployable
form, with the reasoning, is `web/nginx-public.conf`:

```
location /tg/s/ {
    if ($args !~ "^(before=[0-9]+)?$") { return 404; }

    proxy_pass https://t.me/s/;
    proxy_set_header Host t.me;
    proxy_set_header User-Agent "tgsocial/1.0 (+https://github.com/lucian-labs/tgsocial)";

    proxy_ignore_headers Set-Cookie Cache-Control Expires;
    proxy_hide_header Set-Cookie;

    proxy_cache tgpreview;
    proxy_cache_valid 200 60s;          # a page is a lens, not an archive
    proxy_cache_use_stale error timeout updating;
    proxy_cache_lock on;                # one upstream fetch per key, not a stampede

    proxy_hide_header Content-Type;
    proxy_hide_header Content-Security-Policy;
    proxy_hide_header X-Frame-Options;
    add_header Content-Type "text/plain; charset=utf-8" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Content-Security-Policy "sandbox; default-src 'none'" always;

    add_header Access-Control-Allow-Origin "*" always;
    add_header X-Cache $upstream_cache_status always;
}
```

Rules this proxy obeys, and why:

- **Only `/s/`, only a bare channel.** It proxies the preview path and nothing
  else — not `t.me/` join pages, not the API. A path that is not a bare
  channel is refused by the regex location beside this one; a query string
  that is not `?before=<digits>` is refused by the `if` above, because nginx
  matches locations against the URI with the arguments stripped and a location
  regex therefore cannot see the query at all.
- **The body is data, not a document.** What comes back is Telegram's HTML,
  scripts and all. The parser reads it as a *string*, so it is relabelled
  `text/plain` and sandboxed on the way out: opening `/tg/s/<channel>` in a
  tab yields characters, never Telegram's page executing on the origin that
  holds the reader's TDLib session. `sandbox` applies to documents, so the
  `fetch()` in `js/public/source.js` is unaffected.
- **60 seconds.** Long enough that a busy page costs Telegram one fetch,
  short enough that a deleted post disappears quickly. `proxy_cache_lock`
  means a hundred simultaneous readers still produce one upstream request.
  This only works because of `proxy_ignore_headers`: t.me sends `Set-Cookie`
  and `Cache-Control: no-store` on every response, and nginx stores neither
  kind — without those two lines the whole cache is decoration. The cookie is
  hidden as well as ignored; a Telegram session cookie does not belong on your
  origin.
- **No storage beyond the cache.** Nothing is written to a database. The page
  is a lens: delete the post on Telegram and it is gone here on the next
  fetch.
- **Identifies itself.** A real User-Agent with a contact URL, because
  scraping anonymously and lying about it is how you get blocked, and
  deservedly. It points at the repo, since that is the thing that exists no
  matter whose origin is serving; put your own contact there if you would
  rather field the mail yourself.

The site itself carries a second wall — a `Content-Security-Policy` in
`web/index.html` pinning scripts, frames and objects to its own origin — so
that "nothing from the preview is adopted into the live page" (§3) is enforced
by the browser and not only by the parser's discipline.

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

One module, `web/js/public/preview.js`, used by every public surface (a
tgsocial deployment and any domain front-end). Pure: HTML string in, tgsocial
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

A **document row** is held to a stricter rule than the rest, because it is the
only media kind whose action hands the reader a URL to *go to*. Its `href` must
be on Telegram's own file hosts; every other host — including `t.me` itself —
degrades to §2.11's muted one-line summary. Otherwise a channel writes
`href="https://evil.example/pwn.exe"` on a row captioned `invoice.pdf` and the
`Download` button is a phishing link with no address bar: `download` is ignored
cross-origin, so the browser follows it and takes the tab along. For the same
reason nothing hands a foreign URL to a plain click — a file that really is on
Telegram's CDN opens in its own tab, `noopener`, so the page being read
survives either way.

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
directory of one. The routes are not the only door, so the refusal lives with
the *source* rather than the URL: an unlisted node is skipped as a merge
source when someone else's card names it in `feeds:`, and a row for one on
another node's page keeps the bare `@handle` instead of filling in their name,
face and feed count. Nobody's consent is needed to follow them or to list
their channel, so both of those are ordinary use, not a hostile card.

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

## 6. Blocked, muted and reported content

**A public page does nothing about a blocked node, and that is the design
rather than a gap in it.**

The reader's block, mute and hidden lists (`PRODUCT §2.15`–`§2.18`,
`PROTOCOL §7.1`) live in one record on one device, are keyed to one Telegram
account, and are never written to a card, never sent to Telegram and never
sent anywhere else. A visitor opening `/u/<name>` arrives with no account, and
almost always with no record at all — so there is nothing to filter with, and
a node somebody else blocked renders for them in full.

That follows from the same fact that makes blocking safe to offer at all. A
tgsocial block is one reader's private judgement about what reaches *them*; it
is not a sanction on the person, and there is no server it could be reported
to. Applying it to other people's page loads would mean publishing the list —
to every visitor, on every request — which is precisely what `§2.16` promises
never to do. A blocked node is not silenced here; they are unread, by one
reader, on one device.

What the public routes *do* honour is the lists of the device actually asking:

- The filter is the same code as the app's, so a browser that has blocked,
  muted or reported something sees it filtered on these routes too — that is
  the reader who signed in here and then opened one of their own links.
- `Report` and `Mute` are on the public post sheet and write the same record,
  because a reader who wants to stop seeing something should not have to sign
  in first (`PRODUCT §2.15`). `Block` needs an attributed node (`§2.3`), so it
  appears on `/u/` and `/n/` and not on a bare channel.
- The record is the one `tgs.` key that does not count as "this browser has a
  session": hiding one post must not turn the next public link into a 14 MB
  TDLib boot.

And the plain consequence, which is worth stating because it is a privacy
property and not an oversight: **a public page can never reveal who anyone
blocked**, because it does not know and has no way to ask.
