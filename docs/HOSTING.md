# Running an instance

An instance of tgsocial holds nothing. Not "holds little" — a host has no
database, no object store, no accounts and no moderation queue, because there is
nowhere in the design for user content to land on it.

An instance is a client you host for other people — the same reader, running in
a visitor's browser instead of on their phone. Everything true of a client you
write for yourself ([`docs/CLIENTS.md`](./CLIENTS.md)) is true of one you put a
domain on: you decide what it looks like and how it orders things, nobody
approves it, and it reads the same graph. Hosting adds §2, not data.

This is the document for putting one up, and for understanding exactly what you
become responsible for when you do. Short version: a static bundle and one nginx
location block.

## 1. Why there is no data

Four things people expect a social host to store, and where each actually lives:

| Expected on the server | Actually lives |
| --- | --- |
| Posts, media, profiles | The poster's own Telegram channel |
| Sessions and passwords | The visitor's browser (`web/js/td.js` — TDLib runs in the page, session in IndexedDB) |
| The directory of who exists | Telegram: a graph walk over cards, Telegram's own username search, and the public `@tgsocial_index` supergroup (`PROTOCOL §5`) |
| Blocks, mutes, hidden posts | The reader's own device (`PROTOCOL §7.1`) |

The signed-in app never talks to your server about Telegram at all. Your server
sends it a `.js`, a `.wasm` and a `config.json`; from there the browser speaks
MTProto to Telegram directly. You cannot read a visitor's session because it is
never sent to you.

The public reader is the one thing that proxies, and it is a cache with a
sixty-second memory (`PUBLIC.md §1`). It stores a response, serves it for a
minute, and forgets. Mount the cache on tmpfs if you want the "nothing touches
disk" property to be literal:

```nginx
# /etc/fstab
tmpfs /var/cache/nginx/tgpreview tmpfs size=256m,mode=0700,uid=www-data 0 0
```

Nothing else is written. There is no log of who read what unless you configure
nginx to keep one, and the default `access_log` is worth thinking about before
you claim otherwise in a privacy policy. Nor does who-read-what go to Telegram:
the proxy forwards no reader header — not the address, not the cookie, not the
page they were on (`PUBLIC.md §1`).

## 2. What you DO become responsible for

Be honest with yourself about these before you put a domain on it.

- **Your api_id.** `config.json` is fetched by every visitor, so the credential
  in it is public the moment you deploy. That is unavoidable for a browser
  client — see §3.
- **Being a proxy.** `/tg/s/` fetches Telegram on behalf of anyone who asks.
  `web/nginx-public.conf` ships a `limit_req` at 5r/s with a burst of 10 —
  above a reader paging back through a channel, well below anything using your
  host as free Telegram egress. Declaring the zone is part of the install, and
  the location will not load without it. The limit keys on the TCP peer: with
  TLS terminated in front, that peer is your terminator and every reader shares
  one bucket, so key it on the address the terminator forwards
  (`server/nginx.conf` has the `real_ip` lines, commented).
- **What your instance renders.** You are not storing the content, but you are
  displaying it, and in most jurisdictions and every app store that is enough to
  make it your problem. The reader-side controls (`PRODUCT §2.15`–`§2.20`) are
  the user's own tools, not moderation you perform.
- **Your users' expectations.** People will assume an instance is a service.
  It is a lens over Telegram, and it can stop existing without anyone losing
  anything. Say so on the page.

## 3. Get your own api_id

**Do not reuse another instance's, and do not reuse your own mobile app's.**

Telegram identifies applications by `api_id`/`api_hash` from my.telegram.org. A
browser client must ship them to the page, so a hosted instance's credential is
public by construction — that is a property of the platform, not a mistake you
can engineer around.

The consequence is that a credential can be flooded or flagged as published
(`API_ID_PUBLISHED_FLOOD`), and that lands on every build sharing it. Register
one **for the web instance specifically**, and keep it distinct from anything you
ship in an App Store or Play binary, which cannot be hot-fixed if the credential
is burned.

```bash
cp web/config.json.example web/config.json   # gitignored; fill in your own
```

## 4. Put one up

```bash
git clone https://github.com/lucian-labs/tgsocial && cd tgsocial
cp web/config.json.example web/config.json   # your api_id, api_hash
```

Serve `web/` as static files. Add the `/tg/s/` proxy from `PUBLIC.md §1` — the
whole block is in `web/nginx-public.conf`, including the `proxy_cache_path` line
that goes in `http { }`. Then a certificate, and you are done. There is no build
step, no runtime, no process to keep alive, and nothing to restart.

Without the proxy the app still works signed in; the public `/u/`, `/f/` and
`/n/` routes degrade to the empty card (`PRODUCT §2.6`) rather than breaking.

## 5. Being one of many

Every instance is equivalent and none is canonical. They are lenses over the same
Telegram data, so two instances showing the same node show the same thing, and a
node does not belong to the instance that renders it. A reader can switch
instances, or run one locally, and lose nothing.

Links carry this: with no `publicOrigin` configured a client shares `t.me` links,
because those work everywhere and survive your instance going away. Configure one
and it shares `<origin>/u/<name>` instead. Inbound parsing accepts any origin, so
a link from someone else's instance opens in yours (`PRODUCT §2.13`).

If you want a domain to serve one person rather than the whole network, that is
`DOMAINS.md`, and the identity claim is mutual: the site names the node, the
node's card names the site.

## 6. What this is not

It is worth saying plainly, because the shape resembles federation and the
differences are the interesting part.

**There is no federation protocol.** Instances do not talk to each other, sync,
or relay. They independently read the same public Telegram data. Nothing has to
agree with anything.

**Telegram is the single point of failure, and it does not federate.** This is
the real limit. On a system like Bluesky your data lives in a Personal Data
Server you can migrate while keeping your identity, which is precisely what stops
one operator cutting you off. tgsocial has the same split — Telegram is the
store, an instance is the view — but you cannot move the store. Telegram holds
every byte, moderates by its own rules, and can remove a channel from every
instance at once. Running your own instance buys independence from *me*; it buys
none from Telegram.

That trade is the whole design. You get a social network with no servers, no
storage bill and no user data, and the price is that somebody else owns the
substrate. If that price is wrong for you, the honest answer is a different
protocol, not a different instance.

## 7. Sign in with Bluesky: your own client metadata

`PROTOCOL §12` lets a reader sign in with Bluesky. Reading Bluesky needs none
of this — linked accounts and the tag are read signed out — but signing in
does, and it is the one place an instance has to publish something of its own
beyond the bundle.

**Why it is yours to host.** atproto OAuth has no client registration. A
client's identity *is* a URL: the `client_id` is the https address of a small
JSON document, and the authorization server fetches that document live every
time someone signs in (`PROTOCOL §12.7`). So the document names you — your
domain, your redirect — and nobody else's instance can use it, because the
redirect would land on your origin, not theirs. It holds no secret and no user
data: tgsocial is a public client and ships no keys. It is one more static
file, which is the only kind of thing an instance serves.

**The web instance's document.** Serve it at
`https://<your host>/oauth/client-metadata.json`, with your host in both
places:

```json
{
  "client_id": "https://tgsocial.example.org/oauth/client-metadata.json",
  "client_name": "tgsocial",
  "application_type": "web",
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "redirect_uris": ["https://tgsocial.example.org/oauth/callback"],
  "scope": "atproto repo:ca.lucianlabs.tgsocial.link repo:app.bsky.feed.post?action=create blob:image/* rpc:app.bsky.feed.getTimeline?aud=did:web:api.bsky.app%23bsky_appview rpc:app.bsky.feed.searchPosts?aud=did:web:api.bsky.app%23bsky_appview",
  "token_endpoint_auth_method": "none",
  "dpop_bound_access_tokens": true
}
```

- `client_id` is **exactly** the URL the file is served at — scheme, host,
  path, no port, no query. The server compares the two strings.
- `/oauth/callback` is not a file. It falls through to the SPA fallback
  (`try_files … /index.html`) and the page finishes the sign-in there, which is
  what you want.
- `scope` is the list in `PROTOCOL §12.7`, each entry for one thing. Leave out
  a line and that feature fails for your users at consent; do not add
  `transition:generic`, which grants the whole account.

**The one nginx line that matters.** The SPA fallback answers *every* missing
path with `index.html` and a 200. A missing metadata file then comes back as
`200 text/html`, and the authorization server reports a malformed client rather
than a missing one — a confusing afternoon. Give the file an exact location
that 404s when the file is absent, beside the `location /` block:

```nginx
location = /oauth/client-metadata.json {
    default_type application/json;
    try_files $uri =404;
}
```

(Caddy: a `handle /oauth/client-metadata.json { file_server }` before the SPA
`try_files`.) Then check it the way the authorization server will:

```bash
curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' https://<host>/oauth/client-metadata.json
# 200 application/json
curl -sS -o /dev/null -w '%{http_code}\n' https://<host>/oauth/nope.json
# 404 — if this is 200, the fallback is answering for missing files
```

`clientMetadataProblems(doc, url)` in `web/js/protocol.js` is the rest of the
checklist in code — `[]` means publishable — and the `atproto.clientMetadata`
vectors are its cases, including the mistakes `bsky.social` rejected when they
were tried on 2026-09-25.

**Local development** needs no file. atproto has a loopback exception:
`client_id` `http://localhost` (no port, no path) with the redirect and scope
passed as query parameters, and a redirect to `http://127.0.0.1:<port>/`. The
authorization server does not fetch anything for it.

**The native apps' document** is not an instance's. The iOS, Mac and Android
builds of this repo sign in as one client, whose redirect is a custom URL
scheme and so must be the `client_id`'s host reversed (`PROTOCOL §12.7`). For
Elijah's builds that document is a static file at
`https://lucianlabs.ca/tgsocial/client-metadata.json`, and this is it, to the
byte of JSON (`web/test/protocol.test.mjs` holds this block to the vector):

<!-- client-metadata:native -->
```json
{
  "client_id": "https://lucianlabs.ca/tgsocial/client-metadata.json",
  "client_name": "tgsocial",
  "application_type": "native",
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "redirect_uris": ["ca.lucianlabs:/tgsocial/oauth/callback"],
  "scope": "atproto repo:ca.lucianlabs.tgsocial.link repo:app.bsky.feed.post?action=create blob:image/* rpc:app.bsky.feed.getTimeline?aud=did:web:api.bsky.app%23bsky_appview rpc:app.bsky.feed.searchPosts?aud=did:web:api.bsky.app%23bsky_appview",
  "token_endpoint_auth_method": "none",
  "dpop_bound_access_tokens": true
}
```

- The scheme is `ca.lucianlabs` — `lucianlabs.ca` reversed — and not the bundle
  id `ca.lucianlabs.tgsocial`. The path after it, `/tgsocial/oauth/callback`,
  is what keeps it apart from any other app that ever signs in under
  `lucianlabs.ca`; the iOS callback scheme and the Android intent filter match
  on scheme **and** path.
- One slash after the colon. `bsky.social` rejected two.
- `lucianlabs.ca` answered `200 text/html` for every missing path on
  2026-09-25, `/tgsocial/client-metadata.json` included: until the file is
  placed, native sign-in fails at the first request. Run the two `curl`s above
  against it after placing it.
- A fork's apps need their own copy on their own domain, with their own
  reversed scheme (`docs/FORKING.md`). A web instance never uses this one.
