# tgsocial

A social network that lives entirely on Telegram. No server, no database,
no account — sign in with the Telegram you already have, pick which of your
channels post as you, follow people, and read everyone's feeds in one
chronological column.

The graph is stored in Telegram objects anyone can read: your **node** is a
public channel, its pinned message is your **card** (name, feeds, follows),
and following someone is a line on that card. Open a node in plain Telegram
and the usernames are tappable — the network is navigable without this app.

- Protocol: [`PROTOCOL.md`](./PROTOCOL.md)
- Product (screens, flows, copy): [`PRODUCT.md`](./PRODUCT.md)
- Design kit (House Pour, shared across platforms): [`design/`](./design/)
- Build it on your own phone: [`docs/BUILDING.md`](./docs/BUILDING.md)
- Ideas not yet built: [`BACKLOG.md`](./BACKLOG.md)
- Fork it: [`docs/FORKING.md`](./docs/FORKING.md) — keep the card + comment
  format and your fork stays on the same network
- Host the web client: [`web/README.md`](./web/README.md), and
  [`PUBLIC.md`](./PUBLIC.md) for the one nginx location it needs

| Build | Stack | Where |
| --- | --- | --- |
| iOS | SwiftUI · TDLib via [TDLibKit](https://github.com/Swiftgram/TDLibKit) | [`ios/`](./ios/) |
| Android | Kotlin · Jetpack Compose · TDLib | [`android/`](./android/) |
| Web | static HTML/CSS/JS · [tdweb](https://github.com/tdlib/td/tree/master/example/web) (TDLib wasm) | [`web/`](./web/) — any static host, at the origin root |

## Run it

There is no hosted tgsocial and there will not be one. The network is already
running — it is Telegram — so the only thing left to host is a client, and a
client is better off being yours: your build, your credentials, your rate
limits, nothing of yours passing through a box someone else owns.

Every build needs a Telegram `api_id` / `api_hash` from
https://my.telegram.org/apps. They are never committed, and a fork ships its
own pair ([`docs/FORKING.md`](./docs/FORKING.md)).

```bash
# iOS
cp ios/Secrets.xcconfig.example ios/Secrets.xcconfig   # fill in TG_API_ID / TG_API_HASH
cd ios && make gen && make device                       # builds + installs on the connected iPhone

# Android
cp android/secrets.properties.example android/secrets.properties
cd android && ./gradlew :app:installDebug

# Web
cp web/config.json.example web/config.json
cd web && python3 -m http.server 8080                   # then open http://localhost:8080
```

## Sharing

Two controls, and only one of them reads config.

**Share**, on a post, always hands out `https://t.me/<channel>/<id>`. That is
where the post actually is, it opens for anyone who has Telegram, and no
server of yours is in the path. There is no public route for a single post, so
nothing you configure changes this one.

**Copy Link**, in a channel, person or node header, is the one config touches.
By default it copies `https://t.me/<channel>` — a feed and a node *are* public
channels, so that link works with nobody's server running. Stand up the web
client, put its origin in the build's config, and it points at your reader
instead: `<origin>/f/<channel>` and `/n/<node>` from the apps, plus
`/u/<name>` on the reader's own person pages ([`PUBLIC.md`](./PUBLIC.md)).
That is the only thing a public origin changes.

Incoming links are unaffected either way — a tgsocial URL is recognised
whatever host it carries, so links people already hold keep resolving.

## Design kit

`design/tokens.json` is the single source for colour, type, spacing, radius,
shadow and motion. `node design/build.mjs --sync` regenerates
`HousePourTokens.swift`, `HousePourTokens.kt`, and `house-pour.css` and
copies fonts into the app trees. Components are hand-written per platform
against the contract in [`design/COMPONENTS.md`](./design/COMPONENTS.md).
The look is Lucian Labs' [House Pour](https://lucianlabs.ca/branding/house-pour.html).

## Status

v1 — chronological only, no ranking. See `PROTOCOL.md §7` for what is
deliberately left out.

## License

MIT. Fonts are SIL OFL (see `design/fonts/OFL-*.txt`). TDLib is Boost
Software License 1.0. Telegram is a trademark of Telegram FZ-LLC; this is an
independent third-party client.
