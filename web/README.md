# tgsocial — web

Static site. No bundler, no framework, no server: plain HTML, CSS, and ES
modules talking to Telegram through [tdweb](https://github.com/tdlib/td/tree/master/example/web)
(TDLib compiled to WebAssembly). Runs locally from `python3 -m http.server`.

**There is no tgsocial web host.** If you want one, it is yours: copy this
directory to an origin you control, add the `/tg/s/` proxy from `PUBLIC.md
§1`, and you have the whole thing — files on disk, an SPA fallback, and one
nginx location. Nothing in this repo deploys it and nothing in it knows where
it lives.

## Configure

```bash
cp config.json.example config.json     # gitignored
```

Fill in `apiId` / `apiHash` from https://my.telegram.org/apps — your own,
registered against your own Telegram account. `indexGroup` is the public
supergroup used for directory announcements (`tgsocial_index` by default,
PROTOCOL §5.3). `publicOrigin` is optional and unset by default; set it only
if you deploy, and set it to *your* origin — scheme and host, no path and no
query, since the public routes are root-anchored (see **Public links** below).
A trailing slash is what a config file gets typed with, so it is trimmed
rather than refused; a bare host, a path or a `javascript:` URL *is* refused,
and sharing stays on `t.me`. The app fetches `/config.json` at boot; when it
is missing or still holds the placeholder it renders a "Missing config.json."
card instead of starting TDLib.

**A web deployment's credentials are public. There is no version of this
where they are not.** TDLib runs in the page, so the page has to be handed the
`api_id`/`api_hash` — anyone who opens devtools reads them, and moving them
into a bundle, an env var at build time or a header only changes how long it
takes. That is architecture, not an oversight, and it is the same for every
Telegram web client there has ever been. Two consequences worth acting on:
register a **separate pair** for the web build, so a scraped web id cannot get
your iOS and Android builds rate-limited or banned alongside it; and treat the
id's flood limits as shared with every visitor, because they are.

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

It also covers the **demo** (§2.22): the entry on step 1 and its absence on
step 2, the closed TDLib handle, the three persistent indicators (including the
strip surviving into the full-screen viewer), the fifteen posts on every rung
of §2.3's time ladder, the media matrix, the demo sheet's four rows, the three
refusals in their own words, block and mute changing the counts §2.22.2 names,
the report email's one added line, `Leave Demo` leaving nothing on disk, and
`Delete My Node` running §2.21 to the end and then ending the demo.

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

Its static server does what a deployment's nginx does — `try_files $uri $uri/
/index.html`, plus `/tg/s/<channel>` (from `test/fixtures/`, so the run stays
offline) — so a public link resolves locally the way it will once you host
it.

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
js/moderation.js      PRODUCT §2.15–§2.18 / PROTOCOL §7.1: the reader's block, mute and hidden lists, the filter, the report email
js/media.js           PRODUCT §2.11: inline players, full-screen viewer, one-audio-at-a-time, download rings
js/graph.js           canvas radial graph
js/public/preview.js  PUBLIC §3: t.me/s/<channel> HTML → the same Post model, text + entities only, never HTML
js/public/source.js   PUBLIC §1: the client for /tg/s/, with the proxy's own 60 s cache
js/public/feed.js     PUBLIC §4: the public feed — FeedSession with the reader seams overridden
js/public/resolve.js  PUBLIC §4: /u/<name> → node (directly or by backlink); public: no is refused
js/demo/world.js      PRODUCT §2.22.1: the fixture world — 15 nodes, 6 feeds, 15 posts, 11 comments, times as offsets
js/demo/media.js      §2.22.1: plates, the synthesised clip, the waveform bytes, the PDF and the procedural video — generated, never bundled
js/demo/repo.js       §2.22.4: DemoRepo — the substituted data layer, and DemoFeedSession over the app's own merge
js/demo/mode.js       §2.22: the copy (verbatim, shared with iOS and Android), the strip, the demo sheet, the in-memory safety record
js/views/*.js         one module per screen + shared composites (views/public.js is the three public screens)
nginx-public.conf     the /tg/s/ proxy for whoever hosts this — an include, applied by hand once
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
sends no `Access-Control-Allow-Origin`, so nginx proxies it under the site's
own origin and caches it for 60 s (`nginx-public.conf`, PUBLIC §1). A different
door onto the same public data — and the door browsers are allowed through.

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
`Content-Security-Policy` pinning scripts, frames and objects to its own
origin.

**Which shell a visitor gets is decided before TDLib boots.** `App.boot()`
looks for `tgs.*` local state — every key but `tgs.moderation`, which survives
sign-out by design and is written on the public routes too (PROTOCOL §7.1), so
counting it would boot 14 MB of wasm at somebody who only hid one post. Absent
on a public URL means a visitor, so the
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

**Deploying the proxy.** `nginx-public.conf` is an `include` for your
`server { }` block plus the `proxy_cache_path` line it needs in `http { }`.
Nothing in this repo applies it — there is no deploy step here to apply it
*from* — so it is a one-time manual edit on your host; the file's header is
the instructions. Until it is in place the public pages degrade to the §2.6
empty card rather than a blank page. Nothing in
`npm test` exercises that file — `test/smoke.mjs` runs the dev proxy, a second
implementation of the same rules — so its header carries a `docker run
nginx:alpine` recipe for checking the real thing, and the four promises worth
checking: text/plain out, no `Set-Cookie`, `X-Cache: HIT` on a repeat, and 404
for any query that is not `?before=<digits>`.

**Public links are opt-in.** `publicOrigin` is optional and stays unset unless
you put it in `config.json`; while it is unset, the `Copy Link` on a person,
feed or node header copies `https://t.me/<channel>` — on a person page, the
node the page resolved to rather than the handle in the URL, since only the
node names the person (PRODUCT §2.13). That is
the right default for a clone that is not hosted anywhere: there is no origin
to link to, and the channel is public on Telegram regardless. Set it to your
own https origin once the three routes are genuinely served there — an origin
that 404s is worse than a `t.me` link, which is exactly the failure this
default exists to prevent.

A post's **Share** button sits outside all of this. `deepLink()` mints
`https://t.me/<channel>/<id>` in every configuration, because there is no
public route for a single message to point at — `publicPath` /
`parsePublicPath` know `u`, `f` and `n` and nothing else. Setting an origin
moves the three header links and leaves post links exactly where they are.

Reading is not affected either way: `parsePublicPath` accepts a `/u/ /f/ /n/`
path on any host, so links copied out of somebody else's deployment still open
here.

## The demo (PRODUCT §2.22)

Sign-in needs a phone number and a code, so anyone who has neither — an App
Store reviewer, or a person deciding whether to hand over their number — would
see one screen and a form. `Look Around First`, on §2.1 **step 1 only**, is the
rest of the app running on an invented network.

**It is visible, not hidden**, and this repository is why: a review-only
credential typed into the phone field would be a credential printed in the
source. It is also the only route to `Delete My Node` (§2.21) that needs no
account, which is what Guideline 5.1.1(v) asks for.

**The demo is a different object, not a mode.** Entering it closes the TDLib
handle (`Td.close()`) and substitutes `app.repo` with `DemoRepo` and
`app.safety` with an in-memory record whose `userId` is `null` (PROTOCOL §7.1's
demo paragraph — it is never written to `tgs.moderation` and never loaded from
it). A boolean checked at each call site has branches that can be missed; a
substituted object has no code path to Telegram to miss. `app.demo` exists, but
only the shell reads it, for the pill, the strip and §2.22.3's three refusals.

Two things are deliberately the app's own code rather than a second
implementation: `DemoFeedSession` extends `FeedSession` and overrides only its
four reader seams, exactly as `js/public/feed.js` does, so the k-way merge and
§2.18's filter are the signed-in feed's; and the comment index, tree and count
are `Repo`'s own methods, borrowed, so §2.12's depth-5 flattening and the
`5 comments` footer come out of the code a real session runs.

**Nothing is bundled and nothing is fetched.** Photos are seeded gradient
plates carrying their own fixture key, drawn to a canvas and handed over as
`data:` URIs; the 3:42 clip is synthesised as a WAV at the spectrogram strip's
own decimated rate; the voice note ships Telegram-shaped waveform bytes; the
document is a one-page PDF written out in `js/demo/media.js`. The video and the
2 s loop are the one place the web needs a seam of its own: a browser will only
seek a clip it has been given as a file, and the only way to turn drawn frames
into one is MediaRecorder over a captured canvas, which records in real time.
So those two answer a **promise** of a URL, `directUrl()` in `js/media.js`
takes either, and they are started when the demo opens. A build with no
MediaRecorder rejects and the blocks keep their posters.

Two tests hold the guarantees. `test/protocol.test.mjs` walks the demo's whole
import closure and fails the build if anything in it can reach `js/td.js`;
`test/flows.mjs` enters the demo and asserts, among the rest, that the tab made
no request to any origin but its own and that `window.__tgsocial.td.client` is
null.

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
