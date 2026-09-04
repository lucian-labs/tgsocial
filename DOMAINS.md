# Serving a tgsocial person on your own domain

Any domain can serve any tgsocial person. `yourname.com` shows your merged
feed, styled how you like, powered by the same public reader the web client
uses (`PUBLIC.md`) — no account needed to read it, and nothing of yours moves
off Telegram.

This is deliberately generic. There is no special-cased domain in this repo,
and pointing a new one at a node is a config change and a script run, not a
code change.

## 1. What a domain deployment is

Three things, none of them a database:

1. **A site config** — one JSON file at the site root saying which node the
   domain serves and how to present it.
2. **An nginx vhost** — serves the static bundle and proxies `/tg/s/` per
   `PUBLIC.md §1`, so the browser can reach Telegram's public preview.
3. **A certificate** — Let's Encrypt, same as every other host here.

`site.json` at the domain's root:

```json
{
  "node": "tgs_dankcoin",
  "mode": "person",
  "title": "Tasty Crow",
  "tagline": "The Tasty Crow Caws",
  "look": "house-pour",
  "poweredBy": true
}
```

- `node` — whose feed this is. The only required field.
- `mode` — `person` (merged feeds, the default), `feed` (one channel; add
  `"feed": "<channel>"`), or `card` (the graph view).
- `title` / `tagline` — what the page and its `<title>`/OG tags say. Falls
  back to the node card's `name` and `bio`.
- `look` — which design kit to load. `house-pour` today; a domain is exactly
  the place a different identity belongs, and the kit is swappable because
  every component is written against token *names* (`design/COMPONENTS.md`).
- `poweredBy` — show the "powered by tgsocial" link. There is no hosted
  tgsocial to point it at, so it goes to the repo,
  `github.com/lucian-labs/tgsocial`. Default true; it is a link, not a badge,
  and it is not load-bearing.

## 2. Two-way verification (optional, recommended)

The site config is the domain saying "I serve this node". For the claim to be
mutual, the node can say it back: a `site:` key on the card.

```
tgsocial v1
name: Elijah
site: tastycrow.com
feeds: @tastycrow
```

Same shape as the feed backlink in `PROTOCOL §3`: one side claims, the other
confirms, and neither needs a registry. When both agree, clients may show the
domain as verified next to the node. When only the site claims it, the page
still works — it just isn't confirmed, exactly like an unverified feed.

A domain is **never** required. A node with no `site:` is a normal node.

## 3. Standing one up

```bash
scripts/provision-domain.sh <domain> <node> [--mode person|feed|card] [--feed <channel>]
```

What it does, idempotently:

1. Points DNS at the host (DigitalOcean domains via `doctl`; for a domain on
   another registrar or on Cloudflare, it prints the record to create and
   waits for it to resolve rather than guessing at an API it does not own).
2. Creates the webroot, writes `site.json`.
3. Writes the vhost — the static bundle plus the `/tg/s/` proxy from
   `PUBLIC.md §1` and the wasm/font/cache rules the other Lucian Labs hosts
   use.
4. Issues the certificate with certbot (`certonly --webroot`, then rewrites
   the vhost with TLS — the same split the existing
   a provisioning script should use, for the same reason:
   the script fully owns the conf and a re-run is safe).
5. Registers a deploy target so pushing the repo updates the domain's bundle.

Re-running it changes the config and reloads; it does not re-issue a
still-valid certificate.

## 4. What a domain does not get

- **No write access.** A domain page is read-only. Posting, following and
  commenting happen in the app, as you, signed in.
- **No private anything.** It renders exactly what Telegram serves to an
  anonymous browser (`PUBLIC.md §5`). A node marked `public: no` is not
  served on a public domain at all.
- **No archive.** The page is a lens on the live channel, cached for seconds.
  Delete a post on Telegram and the domain follows.
- **No lock-in.** The domain is a view. Point it somewhere else, or take it
  down, and your node, feeds and followers are untouched — they were never
  here.

## 5. Landing-page mode

`mode: person` is a feed, but a domain is also somewhere people land, so the
page supports a header block above the feed: avatar, title, tagline, and the
card's `link`. Endless scroll below it.

How much more than that a domain does — sections, pinned items, a custom
order, a different look entirely — is a per-domain decision, and the reason
`look` and `mode` are in `site.json` rather than compiled in. The default is
deliberately plain: a person, their words, newest first.
