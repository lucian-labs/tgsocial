# tgsocial connector — v1

The connector lets an AI assistant read (and, if you let it, write) Telegram
through tgsocial. It is part of the tgsocial Mac app, not a separate program:
the app you already signed into hosts a small local HTTP bridge, and an MCP
server on the same machine turns that bridge into tools your assistant can
call.

```
Claude ──MCP(stdio)──▶ lucian-mcp ──HTTP 127.0.0.1──▶ tgsocial.app ──MTProto──▶ Telegram
                                        (bridge)         (TDLib)
```

Same account, same session, same card. Nothing new to sign into, and no
Telegram credential ever leaves the app — the bridge speaks in nodes, feeds
and posts, never in session keys.

## 1. Why it is built this way

Handing an assistant a messaging account is a real grant, so the design is
built to be *narrow, visible and revocable* rather than convenient:

- **Local only.** The bridge binds `127.0.0.1`. It is not reachable from the
  network, and there is no remote mode.
- **Off by default.** The bridge does not listen until you turn it on in the
  app.
- **Scoped by default.** With no scope configured the connector exposes your
  **tgsocial graph only** — your feeds, the feeds of nodes you follow, and
  their cards. Your private chats are not in scope and cannot be brought into
  scope by the assistant; only you can widen it, in the app.
- **Read-only by default.** Posting, commenting and card edits are refused
  unless you enable writes, and each write kind is its own switch.
- **Audited.** Every request is logged with time, tool, scope decision and
  outcome, and the log is on screen in the app.
- **Revocable.** One switch stops the bridge; rotating the token invalidates
  every client immediately.

The assistant is a guest in a room you opened, not a co-owner of the account.

## 2. Transport and auth

- Base URL `http://127.0.0.1:<port>`, default port **8477**, configurable.
- Every request carries `Authorization: Bearer <token>`.
- The token is generated on first enable (32 random bytes, base64url) and can
  be rotated from the app. It is written to
  `~/.tgsocial/connector.json` with mode `600`:

```json
{ "port": 8477, "token": "…", "enabled": true, "version": 1 }
```

That file is the handshake: the app writes it, the MCP server reads it. It is
never committed and never leaves the machine. Rotating writes a new token and
drops all in-flight requests.

- Wrong or missing token → `401 {"error":"unauthorized"}`.
- Bridge off → connection refused (the MCP tools report
  `tgsocial is not running, or the connector is off`).
- Not signed in → `409 {"error":"signed out"}`.
- Out of scope → `403 {"error":"out of scope","detail":"<what was asked>"}`.
- Write attempted with writes disabled → `403 {"error":"read only"}`.
- TDLib error → `502 {"error":"telegram","code":n,"message":"…"}`.
- Rate limited by Telegram → `429 {"error":"flood wait","seconds":n}`.

All responses are JSON. Timestamps are ISO-8601. Usernames omit the `@`.

## 3. Scope

Scope is a set of **sources** the assistant may read. Each entry is a channel
or node username. The app offers three presets and a custom list:

| Preset | What it exposes |
| --- | --- |
| `graph` (default) | My feeds + the feeds and cards of nodes I follow |
| `mine` | Only my own feeds and my own card |
| `custom` | Exactly the usernames I list |

Private chats, group chats and direct messages are **never** in scope in v1,
under any preset. `GET /scope` reports the current preset and the resolved
username list; there is no endpoint that changes scope — that is deliberate,
and it is done in the app.

**The reader's safety lists apply on top of scope.** Settings says "Blocked and
reported content is hidden everywhere in the app" (`PRODUCT §2.20`) and the
filter has no switch (`§2.18`), so it covers the bridge as well as the screens:
a blocked node's posts and comments are absent from `/feed`, `/feed/{username}`,
`/search`, `/thread` and `/graph`; a muted feed leaves `/feed` only, and its own
route still answers with the whole channel; and a reported post is simply not
there — `404` on `/thread` and `/media` like any other id the bridge cannot
serve. The lists themselves never cross: there is no endpoint that reads them,
and nothing in a response says why something is missing (`PROTOCOL §7.1`).

## 4. Endpoints

### Read

`GET /status`
```json
{ "signedIn": true, "account": "+1 604 ••• 0199", "node": "tgs_elijah",
  "scope": { "preset": "graph", "sources": 14 }, "writes": { "post": false, "comment": false, "card": false },
  "tdlib": "1.8.66", "app": "1.0.0 (202608240210)" }
```

`GET /feed?limit=30&before=<iso>` — the merged main feed, newest first, the
same k-way merge the app shows (`PROTOCOL §4.8`). Returns posts:
```json
{ "posts": [ { "id": "…", "date": "2026-08-24T14:02:00Z", "node": "tgs_ana",
  "nodeName": "Ana Iliovic", "feed": "waveloop_devlog", "feedTitle": "WaveLoop devlog",
  "text": "…", "media": [ { "kind": "photo", "caption": "…", "durationSeconds": null } ],
  "views": 1200, "reactions": 14, "comments": 3, "link": "https://t.me/waveloop_devlog/144" } ],
  "nextBefore": "2026-08-20T09:15:00Z" }
```
Media is described, never returned as bytes — see §5.

`GET /feeds` — the sources in scope with title, username, verified flag.

`GET /feed/{username}?limit=30&before=<iso>` — one channel's posts.

`GET /node/{username}` — a node's card: name, bio, link, feeds, follows,
`public`, and whether I follow them.

`GET /graph?depth=2` — my follows and (depth 2) their follows, as
`{ "nodes": [...], "edges": [[from, to], ...] }`.

`GET /thread/{username}/{messageId}` — a post plus the comments visible from
my network (`PROTOCOL §6.3`), as a nested tree.

`GET /search?q=<text>&limit=20` — full-text search **within the sources in
scope only**. Not a global Telegram search.

`GET /audit?limit=100` — the audit log.

### Write (each refused unless its switch is on)

`POST /post` `{ "feed": "waveloop_devlog", "text": "…" }` → the created post.
`POST /comment` `{ "target": "https://t.me/…/144", "text": "…" }` → the comment.
`PATCH /card` `{ "name": "…", "bio": "…", "link": "…" }` → the updated card.

Follow/unfollow is **not** exposed in v1: changing who you follow reshapes the
graph others read, and that stays a human decision.

Every write echoes back what it wrote and appends to the audit log.

## 5. Media

The bridge returns media *descriptions* by default (kind, caption, duration,
dimensions) so an assistant can reason about a post without pulling megabytes
through a tool call. To actually fetch bytes:

`GET /media/{postId}/{index}` — downloads via TDLib and returns the file with
its real content type. Bounded by the same byte budget the app uses; a file
above `maxMediaBytes` (default 25 MB) is refused with `413`. Downloads are
audited like everything else.

Transcription, OCR and any other interpretation are the assistant's job, not
the bridge's.

## 6. Audit log

Every request appends one line to `~/.tgsocial/audit.log` (mode `600`,
rotated at 5 MB) and to an in-memory ring the app displays:

```
2026-08-24T14:02:03Z  GET /feed        scope=graph  ok      posts=30
2026-08-24T14:02:11Z  GET /node/tgs_ana scope=graph ok      cached
2026-08-24T14:03:40Z  POST /post       feed=waveloop_devlog REFUSED read-only
```

The log records what was asked and what was decided — never message bodies,
so the log itself is not a second copy of your Telegram.

## 7. MCP tools

`lucian-mcp` exposes the bridge as `tgsocial_*` tools, following the existing
Tide pattern (local HTTP proxied into MCP). Every tool reports the bridge
being off or the app being signed out as a plain, actionable message rather
than an exception.

| Tool | Endpoint |
| --- | --- |
| `tgsocial_status` | `GET /status` |
| `tgsocial_feed` | `GET /feed` |
| `tgsocial_feeds` | `GET /feeds` |
| `tgsocial_channel` | `GET /feed/{username}` |
| `tgsocial_node` | `GET /node/{username}` |
| `tgsocial_graph` | `GET /graph` |
| `tgsocial_thread` | `GET /thread/{username}/{id}` |
| `tgsocial_search` | `GET /search` |
| `tgsocial_audit` | `GET /audit` |
| `tgsocial_post` | `POST /post` |
| `tgsocial_comment` | `POST /comment` |

Write tools are registered always but fail closed with the reason, so the
assistant can tell the difference between "not allowed" and "broken".

## 8. What this is not

- Not a bot. It acts as you, which is exactly why it is scoped and audited.
- Not a bridge to your DMs. v1 has no path to private chats at all.
- Not remote. There is no hosted mode, and adding one would need a different
  security model than a bearer token on loopback.
- Not a second session to maintain: it is the Mac app's own TDLib client, so
  signing out of the app revokes the connector too.
