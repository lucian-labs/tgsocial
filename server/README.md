# server/

A tgsocial host holds nothing: no database, no accounts, no sessions — TDLib
runs in the visitor's browser and speaks to Telegram directly. What a host does
is serve `web/` as files and proxy one path, `/tg/s/<channel>`, to Telegram's
public preview, because `t.me` sends no CORS header and a browser cannot fetch
it alone. The argument, and what you become responsible for by putting a domain
on one, is [`docs/HOSTING.md`](../docs/HOSTING.md).

This folder is that host, once, in nginx, with a Caddy version beside it. It is
an example, not a product: run it, watch it work, then keep it or replace it
with whatever you already run. The only part that is not yours to change is the
contract.

## The contract

Any server for `web/` meets this, in any technology. Nothing else is asked of
it.

- [ ] Serve `web/` as static files from the origin root — `/`, not a sub-path;
      tdweb resolves its worker against `/vendor/tdweb/`.
- [ ] SPA fallback: a path that is not a file gets `index.html`. `/u/…`,
      `/f/…`, `/n/…` are routes inside the page.
- [ ] `.wasm` is served as `application/wasm`.
- [ ] Proxy `GET /tg/s/<channel>` to `https://t.me/s/<channel>` with
      `Host: t.me` and a User-Agent that names a contact. `HEAD` too; any
      other method is 405, never forwarded.
- [ ] `<channel>` is `[A-Za-z0-9_]{4,32}`. Anything else under `/tg/` is 404,
      never forwarded.
- [ ] The only query accepted is `?before=<digits>`. Any other query is 404.
- [ ] Forward nothing that identifies the reader: no `X-Forwarded-For`,
      `X-Forwarded-Host`, `X-Forwarded-Proto` or `Via`, no `Cookie`, `Referer`
      or `Authorization`. Telegram sees your address and your User-Agent,
      never which reader on which page. nginx adds none of the first four by
      itself; Caddy, Traefik and HAProxy add them by default and have to be
      told not to.
- [ ] Drop Telegram's `Set-Cookie`: not stored, not passed on.
- [ ] Drop Telegram's `Strict-Transport-Security`: it is policy for `t.me`,
      and passed through under your domain it enrols the domain in HSTS for a
      year without you deciding to.
- [ ] Drop `Location`. A name that is not a channel is a 302 to
      `https://t.me/<name>`; the page fetches with `redirect: 'follow'`, so a
      `Location` that survives sends the reader's browser to Telegram directly
      — the one trip the proxy exists to prevent. Without it the 302 is a dead
      end and the page shows the empty card.
- [ ] Reply with `Content-Type: text/plain; charset=utf-8`,
      `X-Content-Type-Options: nosniff`,
      `Content-Security-Policy: sandbox; default-src 'none'` and
      `Access-Control-Allow-Origin: *`, replacing whatever t.me sent for those.
- [ ] Cache a 200 for about 60 seconds, in memory or on tmpfs, and collapse
      simultaneous misses into one upstream fetch.
- [ ] Rate-limit the path per reader address. nginx ships 5 r/s with a burst
      of 10, 429 on excess. The address has to be the reader's: behind a TLS
      terminator the TCP peer is the terminator, every reader shares its one
      bucket, and the instance starts answering 429 at ten reads in a burst —
      three people opening a node with four feeds each. Key on the address
      the terminator forwards, trusting only the terminator; `nginx.conf` has
      the three lines, commented, beside the zone.

The first three lines are `root`, `try_files` and `mime.types` in
`nginx.conf`, the way any static host does them. Every line after that is a
directive in [`web/nginx-public.conf`](../web/nginx-public.conf) with its
reason in a comment; `PUBLIC.md §1` prints that proxy block as a spec, and the
rate limit is `docs/HOSTING.md §2`. TLS is not in the contract because it is
not the proxy's job: terminate it in front, with whatever you already use, and
then re-key the rate limit as above.

## Run it

```bash
cp web/config.json.example web/config.json   # your own api_id — docs/HOSTING.md §3 on why not someone else's
cd server && docker compose up
```

Open <http://localhost:8080>. `/tg/s/telegram` comes back as text with
`X-Cache: MISS`, then `HIT`; `/tg/s/telegram?x=1` is a 404; a `POST` to it is
a 405; `/tg/s/no_such_channel_here` is a 302 with no `Location`. `PORT=9000
docker compose up` moves it, and `docker compose run --rm tgsocial nginx -t`
checks the config without starting it.

One thing to know on Docker Desktop: every published-port request reaches the
container from the VM's forwarder, one address for all readers, so locally the
rate limit is one bucket for everyone — fifteen quick reads and the last few
are 429. That is the Mac's NAT, not the config; Linux hands the container the
reader's address.

`nginx.conf` is complete — it declares the cache and rate-limit zones the
location needs, serves the SPA, and `include`s `../web/nginx-public.conf`
rather than copying it, so one file holds the contract and a `git pull` brings
its fixes. `docker-compose.yml` mounts `web/` read-only and puts the cache on
tmpfs; there is no volume that persists anything, which is the point.

`Caddyfile` is the same contract in Caddy, run from this folder with `caddy
run` or the `docker run` line at its top. Stock Caddy has no cache and no rate
limiter; the file says so where each is missing rather than dropping the
lines quietly.

Then a certificate and a domain, and you are one of many (`docs/HOSTING.md
§5`).
