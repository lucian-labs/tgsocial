# tgsocial — web

Static site. No bundler, no framework, no server: plain HTML, CSS, and ES
modules talking to Telegram through [tdweb](https://github.com/tdlib/td/tree/master/example/web)
(TDLib compiled to WebAssembly). Deployed by copying this directory to an
nginx host at https://tgsocial.lucianlabs.ca; runs locally from
`python3 -m http.server`.

## Configure

```bash
cp config.json.example config.json     # gitignored
```

Fill in `apiId` / `apiHash` from https://my.telegram.org/apps. `indexGroup` is
the public supergroup used for directory announcements (`tgsocial_index` by
default, PROTOCOL §5.3). The app fetches `/config.json` at boot; when it is
missing or still holds the placeholder it renders a "Missing config.json."
card instead of starting TDLib. The hash ends up in the page, which is how
every Telegram web client works — treat it as public and keep the app id's
rate limits in mind.

## Run

```bash
python3 -m http.server 8080            # then open http://localhost:8080
node scripts/dev-proxy.mjs --port 8080 # the same, plus /tg/s/ and the SPA fallback
```

`python3 -m http.server` is enough for the signed-in app. The **public pages**
(`/u/`, `/f/`, `/n/` — PRODUCT §2.13) need two things it cannot do: the SPA
fallback that serves `index.html` for those paths, and the `/tg/s/` proxy onto
Telegram's public preview. `scripts/dev-proxy.mjs` is both, in node built-ins
only — no dependency, nothing to install. `--fixtures test/fixtures` serves the
saved pages instead of reaching Telegram, which is how you work on the parser
offline.

The site must live at the origin root (`/`), not a sub-path: tdweb resolves
its Web Worker relative to the page URL and the vendored `tdweb.js` is
patched to `/vendor/tdweb/`. nginx needs `application/wasm` for `.wasm`
(`types { application/wasm wasm; }`, shipped with nginx ≥ 1.21), an SPA
fallback to `index.html`, and https (TDLib talks MTProto over `wss://`). No
COOP/COEP headers are needed — the wasm is single-threaded. No service worker:
it would fight tdweb's own IndexedDB caching; rely on cache headers for the
hashed worker/wasm files.

## Test

```bash
node test/protocol.test.mjs            # card parser/serialiser etc. against ../docs/card-vectors.json
node test/smoke.mjs                    # headless Chromium: loads the page, checks fonts + config + TDLib reaching WaitPhoneNumber
node test/flows.mjs [--shots DIR]      # every screen against test/mock-tdweb.js (no network), optional screenshots
npm test                               # protocol + smoke
```

`smoke.mjs` serves `web/` on a free port with `python3 -m http.server` and
drives Playwright Chromium. It looks for a browser at `/opt/pw-browsers`,
then `$PLAYWRIGHT_BROWSERS_PATH`, then `~/.cache/tgsocial-pw/browsers`; the
`playwright` package resolves from `$PW_MODULE_DIR`, then
`~/.cache/tgsocial-pw`. When neither exists it installs both into
`~/.cache/tgsocial-pw` (never into this repo — `node_modules` is ignored).
The TDLib assertion needs real network to Telegram; if it cannot connect the
test reports the connection state as an environment note rather than failing
on the auth state machine (which reaches `authorizationStateWaitPhoneNumber`
offline). It also runs the public reader **live**: it starts
`scripts/dev-proxy.mjs`, checks the proxy refuses anything that is not a bare
channel, and loads `/f/tastycrow` in the browser — a real anonymous read of a
real channel, with no TDLib. Those assertions are skipped with a note when
t.me is unreachable. When they fail while `flows.mjs` still passes on the
fixtures, Telegram changed its markup: refresh `test/fixtures/`.

`flows.mjs` swaps `vendor/tdweb/tdweb.js` for `test/mock-tdweb.js` via route
interception and walks sign-in (code + 2FA), setup (create node, feed picker,
verify backlink), feed (merge, media, entities, infinite scroll, live insert),
media (player rows, GIF autoplay, full-screen viewer with album swipe, the
now-playing dock), comments (thread screen, first-run channel creation,
optimistic post, delete), the Status sheet, explore, profile (optimistic
follow + rollback), feed channel, graph, you (edit card, listing, announce,
compose), sign-out wipe, cold-start cache, the FLOOD_WAIT toast, and the
Offline pill.

It also covers the **public pages** (§2.13) end to end against the saved
previews in `test/fixtures/`: the parser (posts, ids, `<time datetime>`,
views, media kinds, the card, the backlink, `?before=`), a signed-out visit
rendering real posts with no sign-in wall and no Comment button, the nag
appearing and dismissing, `/u/<name>` resolving through a feed's backlink and
merging the node's `feeds:` newest-first, endless scroll, `public: no` being
refused on all three routes, a zero-post page reported unavailable, Copy Link
per route, XSS (a hostile fixture through parser and renderer, asserting
nothing executed and no handler, `javascript:` or `data:` href survived), and
the signed-in reader getting the ordinary screen on the same URLs with no nag
— including the pre-auth 401 that made the preview necessary in the first
place.

Its static server does what the deploy host's nginx does — `try_files $uri
$uri/ /index.html`, plus `/tg/s/<channel>` (from `test/fixtures/`, so the run
stays offline) — so a public link resolves the same way it does in production.

## Layout

```
index.html            shell: topbar + view + floating tab dock + toast/modal/viewer roots
privacy.html          docs/PRIVACY.md as a House Pour page
css/tokens.css        GENERATED --hp-* token supplement (design/web/tokens.build.mjs)
css/app.css           product composites (post card, node row, graph, profile head) — var(--token) only
js/app.js             boot, router (hash + public /u/ /f/ /n/ paths), public mode + nag, status pill + floating tab dock, sign-out
js/td.js              TdClient wrapper: auth stream, send + FLOOD_WAIT backoff, update bus, downloads, file → blob cache
js/activity.js        in-flight operation registry behind the Syncing pill and the Status sheet
js/protocol.js        pure protocol module (card + replies, comments, usernames, backlink, deep link, merge cursor, entities) — no DOM/TDLib
js/repo.js            MyNode, card cache, feed sources + FeedSession, comment index, discovery, posting (localStorage state)
js/media.js           PRODUCT §2.11: inline players, full-screen viewer, one-audio-at-a-time, download rings
js/graph.js           canvas radial graph
js/public/preview.js  PUBLIC §3: t.me/s/<channel> HTML → the same Post model, text + entities only, never HTML
js/public/source.js   PUBLIC §1: the client for /tg/s/, with the proxy's own 60 s cache
js/public/feed.js     PUBLIC §4: the public feed — FeedSession with the reader seams overridden
js/public/resolve.js  PUBLIC §4: /u/<name> → node (directly or by backlink); public: no is refused
js/views/*.js         one module per screen + shared composites (views/public.js is the three public screens)
nginx-public.conf     the /tg/s/ proxy for the deploy host — an include, applied by hand once
scripts/dev-proxy.mjs the same proxy + SPA fallback for local runs (node built-ins only)
vendor/house-pour.css GENERATED from design/tokens.json + upstream stylesheet + design/web/house-pour.components.css (do not edit)
vendor/house-pour.js  design-kit helpers (toast, modal, tabs, toggle, media, avatar, DOM) — copy of design/web/house-pour.js
vendor/fonts/         Cormorant Garamond, Kaushan Script, Inconsolata (SIL OFL)
vendor/tdweb/         TDLib wasm build — see below
scripts/install-tdweb.sh
tdweb-build/Dockerfile
test/                 protocol.test.mjs, smoke.mjs, flows.mjs, mock-tdweb.js
test/fixtures/        real fetched t.me/s/ pages (tastycrow, tgs_dankcoin, telegram) + synthetic edge cases
```

## Public pages (PRODUCT §2.13, PUBLIC.md)

`/u/<name>`, `/f/<channel>` and `/n/<node>` are pathnames, not hashes. nginx's
SPA fallback serves `index.html` for them and `js/app.js` reads
`location.pathname` when there is no `#/` route, so a deep link loads on that
screen. Hash routes are unchanged and win whenever there is one — navigating
inside the signed-in app from a public URL never reloads the page.

**Anonymous reading does not go through TDLib.** TDLib answers `401
Unauthorized` to every chat request made before authorization. Measured against
the bundled tdweb 1.8.66 on a client at `connectionStateReady` and
`authorizationStateWaitPhoneNumber`:

```
getOption         → optionValueString
searchPublicChat  → 401 Unauthorized
getChat           → 401 Unauthorized
getChatHistory    → 401 Unauthorized
```

Only preauthentication requests answer — `PREAUTH_QUERIES` in `js/td.js`.
`test/smoke.mjs` asserts this against the real library on every run and
`test/mock-tdweb.js` enforces the same gate, so nobody re-assumes otherwise.

**It goes through Telegram's own public preview instead.** `t.me/s/<channel>`
is served to anonymous browsers and carries everything the protocol needs:
post text, media, `<time datetime>`, view counts, `data-post` message ids, the
channel description with its backlink, and the pinned card message itself. It
sends no `Access-Control-Allow-Origin`, so nginx proxies it under our origin
and caches it for 60 s (`nginx-public.conf`, PUBLIC §1). A different door onto
the same public data — and the door browsers are allowed through.

The reading path is four small modules:

- `js/public/preview.js` — HTML in, the same `Post` model `repo.toPost()`
  builds out, so §2.3's post card, §2.11's players and the full-screen viewer
  render a public post with the signed-in code. The only difference is inside
  the file slots: a preview file is `{ url }`, a TDLib file is `{ id }`, and
  `media.js` answers both.
- `js/public/source.js` — the client for `/tg/s/`, and nothing else.
- `js/public/feed.js` — `FeedSession` with four reader seams overridden, so
  the k-way merge, refill choice and exhaustion are the signed-in feed's.
- `js/public/resolve.js` — `/u/<name>` → the node, directly or by following
  the feed's `tgsocial: @<node>` backlink. A card that says `public: no` is
  refused on every route, backlink included — and its `isUnlisted` is used by
  `feed.js` and `views/public.js` too, so an unlisted node is refused as a
  merge source and as a filled-in row on somebody else's page. Naming someone
  in your `feeds:` or following them needs no consent from them, so the
  refusal has to be a property of what may be read, not of which URL asked.

**Sanitisation is the load-bearing part.** The parser returns text and
structured entities, never HTML; the renderer builds nodes; `javascript:` and
`data:` URLs are dropped at the parse; preview links get `rel="noopener
nofollow ugc"`; a document row's href must be on Telegram's own file hosts or
it degrades to a summary, because that is the one row whose action hands the
reader somewhere to go. There is no `innerHTML` anywhere in `js/`, and
`test/protocol.test.mjs` greps for the sinks so there never is. Two walls sit
behind all of that: the proxy relabels Telegram's HTML `text/plain` and
sandboxes it, so a direct visit to `/tg/s/<channel>` runs nothing on the
origin that stores the TDLib session, and `index.html` carries a
`Content-Security-Policy` pinning scripts, frames and objects to our origin.

**Which shell a visitor gets is decided before TDLib boots.** `App.boot()`
looks for `tgs.*` local state: absent on a public URL means a visitor, so the
tab enters `publicMode` — no TDLib, no repo, no 14 MB wasm — with the tab bar
hidden, a neutral `Public` pill, no Comment/comment counts/Follow, and the
dismissible nag in the floating-bar slot. Present means a reader coming back to
their own app, so the URL is a destination instead: `app.pendingDest` holds it
through Sign in (`Sign in to see @<name>.`) and Setup, and `render()` spends it
on the first pass that has a session. Nothing is written to storage for it: the
URL is the memory.

Signed in, a public route is the ordinary channel or node screen, and
`/u/<name>` resolves the same way PUBLIC §4 does — with TDLib rather than the
preview — and lands on that person's profile. A malformed escape (`/f/%zz`) is
not a route at all: `parsePublicPath` swallows the `URIError` and returns null,
because it runs in `boot()` before there is a repo or a view to render an error
into.

**Deploying the proxy.** `nginx-public.conf` is an `include` for the host's
`server { }` block plus the `proxy_cache_path` line it needs in `http { }`.
The deploy webhook does not edit nginx config, so it is a one-time
manual step on the host; the file documents it. Until it is in place the public
pages degrade to the §2.6 empty card rather than a blank page. Nothing in
`npm test` exercises that file — `test/smoke.mjs` runs the dev proxy, a second
implementation of the same rules — so its header carries a `docker run
nginx:alpine` recipe for checking the real thing, and the four promises worth
checking: text/plain out, no `Set-Cookie`, `X-Cache: HIT` on a repeat, and 404
for any query that is not `?before=<digits>`.

## vendor/tdweb provenance

The official npm `tdweb@1.8.0` is obsolete (TDLib 1.8.0, legacy
`setTdlibParameters { parameters }` wrapper and an encryption-key step). This
app targets TDLib ≥ 1.8.6 semantics: flat `setTdlibParameters`, no
`checkDatabaseEncryptionKey`. Two sources for the dist, in order of preference:

1. **Self-built from tdlib/td master** with `tdweb-build/Dockerfile`
   (emsdk 3.1.1, the upstream `build-openssl.sh → build-tdlib.sh →
   copy-tdlib.sh → build-tdweb.sh` scripts):

   ```bash
   docker build -t tdweb-build web/tdweb-build
   docker run --rm -v "$PWD/out:/out" tdweb-build
   web/scripts/install-tdweb.sh out
   ```

2. **Fallback: the community rebuild `@aefen/tdweb@1.8.49`** (built from the
   same upstream scripts, wasm-only, verified to reach
   `authorizationStateWaitPhoneNumber` with the flat form):

   ```bash
   npm pack @aefen/tdweb@1.8.49 && tar -xzf aefen-tdweb-1.8.49.tgz
   cp package/package.json package/dist/
   web/scripts/install-tdweb.sh package/dist
   ```

`install-tdweb.sh <dist-dir>` wipes `vendor/tdweb/`, copies `tdweb.js`, the
hashed `*.worker.js` chunks and the `.wasm`, records `PROVENANCE.txt`, and
patches the webpack publicPath in `tdweb.js` from `""` to `/vendor/tdweb/`
(`__webpack_require__.p = "";`) — without that the worker URL resolves
against the page and 404s anywhere but the dist directory. `vendor/tdweb/PROVENANCE.txt`
says which source the current files came from; `TD_COMMIT` is present for
self-built dists. A registry binary handles your session keys, so ship the
self-built one.

`tdweb.js` is a webpack UMD bundle: loaded with a classic `<script>` in
`index.html`, it exposes `window.tdweb.default` (TdClient). Requests go
through `client.send({ '@type': ... })`; media is read with `readFile` after
`updateFile` reports `local.is_downloading_completed` (the file lives in
IndexedDB, not on a path).

## Design kit

`vendor/house-pour.css` and `css/tokens.css` are generated from
`design/tokens.json` (`node design/build.mjs --sync` and
`node design/web/tokens.build.mjs`). The kit's own components (avatar, toggle,
media, modal, section-mark count, the 40pt hit floor) live in
`design/web/house-pour.components.css`, concatenated into `house-pour.css`;
`house-pour.js` carries their helpers (`toggle()`, `media()`, `avatar()`,
`modal()`). Screen and component code uses only `var(--token)` values; the
two product constants that are not brand tokens (graph dot sizes, topbar
blur) sit in the `:root` block at the top of `css/app.css` with their
PRODUCT/COMPONENTS citations.
