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
you claim otherwise in a privacy policy.

## 2. What you DO become responsible for

Be honest with yourself about these before you put a domain on it.

- **Your api_id.** `config.json` is fetched by every visitor, so the credential
  in it is public the moment you deploy. That is unavoidable for a browser
  client — see §3.
- **Being a proxy.** `/tg/s/` fetches Telegram on behalf of anyone who asks.
  `web/nginx-public.conf` ships a `limit_req` at 5r/s with a burst of 10 —
  above a reader paging back through a channel, well below anything using your
  host as free Telegram egress. Declaring the zone is part of the install, and
  the location will not load without it.
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
