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
- Fork it: [`docs/FORKING.md`](./docs/FORKING.md) — keep the card + comment
  format and your fork stays on the same network

| Build | Stack | Where |
| --- | --- | --- |
| iOS | SwiftUI · TDLib via [TDLibKit](https://github.com/Swiftgram/TDLibKit) | [`ios/`](./ios/) |
| Android | Kotlin · Jetpack Compose · TDLib | [`android/`](./android/) |
| Web | static HTML/CSS/JS · [tdweb](https://github.com/tdlib/td/tree/master/example/web) (TDLib wasm) | [`web/`](./web/) → https://tgsocial.lucianlabs.ca |

## Run it

Every build needs a Telegram `api_id` / `api_hash` from
https://my.telegram.org/apps. They are never committed.

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
