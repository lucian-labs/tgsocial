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
```

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
offline).

`flows.mjs` swaps `vendor/tdweb/tdweb.js` for `test/mock-tdweb.js` via route
interception and walks sign-in (code + 2FA), setup (create node, feed picker,
verify backlink), feed (merge, media, entities, infinite scroll, live insert),
media (player rows, GIF autoplay, full-screen viewer with album swipe, the
now-playing dock), comments (thread screen, first-run channel creation,
optimistic post, delete), the Status sheet, explore, profile (optimistic
follow + rollback), feed channel, graph, you (edit card, listing, announce,
compose), sign-out wipe, cold-start cache, the FLOOD_WAIT toast, the Offline
pill, and public links (§2.13: `/f/<channel>` signed out → Sign in naming the
destination → landing on the channel, the same across a Setup detour, the
refused pre-auth read, `/n/<node>`, the missing-channel empty card, Copy Link,
and malformed escapes falling through). Its static server does what the deploy
host's nginx does — `try_files $uri $uri/ /index.html` — so a public link
resolves the same way it does in production.

## Layout

```
index.html            shell: topbar + view + floating tab dock + toast/modal/viewer roots
privacy.html          docs/PRIVACY.md as a House Pour page
css/tokens.css        GENERATED --hp-* token supplement (design/web/tokens.build.mjs)
css/app.css           product composites (post card, node row, graph, profile head) — var(--token) only
js/app.js             boot, router (hash + public /f//n/ paths), status pill + floating tab dock, sign-out
js/td.js              TdClient wrapper: auth stream, send + FLOOD_WAIT backoff, update bus, downloads, file → blob cache
js/activity.js        in-flight operation registry behind the Syncing pill and the Status sheet
js/protocol.js        pure protocol module (card + replies, comments, usernames, backlink, deep link, merge cursor, entities) — no DOM/TDLib
js/repo.js            MyNode, card cache, feed sources + FeedSession, comment index, discovery, posting (localStorage state)
js/media.js           PRODUCT §2.11: inline players, full-screen viewer, one-audio-at-a-time, download rings
js/graph.js           canvas radial graph
js/views/*.js         one module per screen + shared composites
vendor/house-pour.css GENERATED from design/tokens.json + upstream stylesheet + design/web/house-pour.components.css (do not edit)
vendor/house-pour.js  design-kit helpers (toast, modal, tabs, toggle, media, avatar, DOM) — copy of design/web/house-pour.js
vendor/fonts/         Cormorant Garamond, Kaushan Script, Inconsolata (SIL OFL)
vendor/tdweb/         TDLib wasm build — see below
scripts/install-tdweb.sh
tdweb-build/Dockerfile
test/                 protocol.test.mjs, smoke.mjs, flows.mjs, mock-tdweb.js
```

## Public links (PRODUCT §2.13)

`/f/<channel>` and `/n/<node>` are pathnames, not hashes. nginx's SPA fallback
serves `index.html` for them and `js/app.js` reads `location.pathname` when
there is no `#/` route, so a deep link loads the app on that screen. Hash
routes are unchanged and win whenever there is one — navigating inside the app
from a public URL never reloads the page.

**There is no anonymous read.** TDLib answers `401 Unauthorized` to every chat
request made before authorization. Measured against the bundled tdweb 1.8.66
on a client at `connectionStateReady` and `authorizationStateWaitPhoneNumber`:

```
getOption         → optionValueString
searchPublicChat  → 401 Unauthorized
getChat           → 401 Unauthorized
getChatHistory    → 401 Unauthorized
```

Only preauthentication requests (`setTdlibParameters`, `getOption`,
`setNetworkType`, the auth calls) answer — `PREAUTH_QUERIES` in `js/td.js`.
A public channel is public to Telegram's servers, not to an unauthorized
client, so a public page cannot be served from the browser alone. Serving one
would take a server-side reader (bot API or an MTProto session on the host),
which v1 does not have. `test/smoke.mjs` asserts this against the real library
on every run, and `test/mock-tdweb.js` enforces the same gate, so a future
change cannot quietly re-assume otherwise.

**So a link is a destination, not a mode.** `App.boot()` parses the pathname
into `app.pendingDest` before TDLib comes up. With no session the visitor gets
Sign in with the destination named (`Sign in to see @<name>.`); the pathname
stays in the address bar through the whole detour, and `render()` spends the
destination on the first pass that has a session — navigating to
`#/feed/<name>` or `#/node/<name>` if Setup rewrote the hash along the way,
and doing nothing when the pathname already resolves there. Nothing is
written to storage: the URL is the memory.

Signed in, a public route is the ordinary channel or node screen with a
`Copy Link` ghost in the header (`app.route.viaPath`). A malformed escape
(`/f/%zz`) is not a route at all — `parsePublicPath` swallows the `URIError`
and returns null, because it runs in `boot()` before there is a repo or a view
to render an error into.

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
