# tgsocial

Make your own social media client, and they all talk to each other.

The graph lives on Telegram, and tgsocial is the protocol for reading and
writing it — so there is no server to run and no one to ask. Sign in with the
Telegram you already have, pick which of your channels post as you, follow
people, and read everyone's feeds in one chronological column.

Your **node** is a public channel, its pinned message is your **card** (name,
feeds, follows), and following someone is a line on that card. Every one of
those objects is readable by anyone: open a node in plain Telegram and the
usernames are tappable — the network is navigable without this app.

Which is also why a client you write yourself is a full member of it. Nobody
approves a client: there is nothing of ours to register with, no key, no
review, no federation handshake — a program that parses a card correctly is on
the same network as the iOS build from its first read. The one registration in
the picture is Telegram's own. Every client needs its own `api_id` / `api_hash`
from https://my.telegram.org/apps, ours included, because Telegram rate-limits
and audits per application ([`docs/CLIENTS.md`](./docs/CLIENTS.md) §5). It is a
form on Telegram's site and a pair of values you keep out of git
([`docs/BUILDING.md`](./docs/BUILDING.md)).

No client is privileged here. The reference builds get nothing from the
protocol that yours does not; the three in this repo share the protocol and a
design kit, and they interoperate because of the protocol.

[`docs/FORKING.md`](./docs/FORKING.md) names the four things a client keeps to
stay on the shared graph — the card format, the comment format, the feed
backlink, ownership semantics — and
[`docs/card-vectors.json`](./docs/card-vectors.json) is the executable form of
the first two: wire your parser tests to it and you are compatible. Everything
above that line is yours. Chronological or ranked, a column or a wall, whether
counts are shown at all, what is hidden by default, whether it renders on
e-ink — none of that is in the protocol. The product decisions live in the
client, which means they are yours to make.

The limits, because overselling this is the easy failure. Telegram is the
substrate and no client escapes it; Telegram enforces its own rules and can
delete a channel, which deletes what that channel held. The contract is a real
constraint — break the card format and you have your own network rather than
this one. And it is the *client* you design: the card's keys are fixed, on
purpose, since that fixity is what lets anyone else's client read yours.

- Protocol: [`PROTOCOL.md`](./PROTOCOL.md)
- Write your own client: [`docs/CLIENTS.md`](./docs/CLIENTS.md) — the contract,
  and what it leaves you
- Product (screens, flows, copy): [`PRODUCT.md`](./PRODUCT.md)
- Design kit (House Pour, shared across platforms): [`design/`](./design/)
- Build it on your own phone: [`docs/BUILDING.md`](./docs/BUILDING.md)
- Ideas not yet built: [`BACKLOG.md`](./BACKLOG.md)
- Fork it: [`docs/FORKING.md`](./docs/FORKING.md) — keep the card + comment
  format and your fork stays on the same network
- Run your own instance: [`docs/HOSTING.md`](./docs/HOSTING.md)
- Host the web client: [`web/README.md`](./web/README.md), and
  [`PUBLIC.md`](./PUBLIC.md) for the one nginx location it needs

The three reference clients. The design kit is the only source they share —
`design/swift/HousePour` compiles into the iOS target, `design/kotlin` into the
Android module, `design/web/house-pour.css` is vendored into `web/`. No
application code crosses between them: each implements `PROTOCOL.md` itself,
and they interoperate because every parser runs against the same
`docs/card-vectors.json` (`ios/Tests/CardVectorTests.swift`,
`android/app/src/test/.../CardVectorsTest.kt`, `web/test/protocol.test.mjs`).

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

v1 — chronological only, no ranking. See `PROTOCOL.md §8` for what is
deliberately left out, and which of it is a client decision rather than a rule
of the format.

## License

MIT. Fonts are SIL OFL (see `design/fonts/OFL-*.txt`). TDLib is Boost
Software License 1.0. Telegram is a trademark of Telegram FZ-LLC; this is an
independent third-party client.
