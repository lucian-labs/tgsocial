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

On Mac, closing the window hides it to the `tg` menu-bar item; an enabled
bridge keeps running. Choose `Open tgsocial` to return or `Quit tgsocial` to
stop the app and bridge. Closing a window never enables the bridge or changes
its permissions.

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
  scope by the assistant. Connected agents may manage explicitly named public
  sources with `PATCH /scope` when you request it; there is no blanket chat access.
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
- **The Connector needs Telegram.** The app can be signed in to Bluesky alone
  (`PRODUCT §1`), and then the bridge does not listen at all — connection
  refused, as if off — and the Connector tab shows `Sign in to Telegram to use
  the Connector.` in place of its switches (`PRODUCT §2.14`). Every source the
  bridge serves is a Telegram channel, so there is nothing to serve; and a
  Bluesky session is never something it pipes (`PROTOCOL §12.9`). Signing out
  of Telegram turns the bridge off and wipes the token whether or not Bluesky
  stays signed in.
- Not signed in to Telegram while listening (the session ended under a
  request) → `409 {"error":"signed out"}`.
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
username list. The local screen and authenticated `PATCH /scope` can change
the public source list. Enabling the connector delegates this management to
connected agents for user-requested changes, independently of the three
Telegram write grants. Agents must not add sources on their own initiative.

`PATCH /scope` accepts `{ "add": ["channel_name"], "remove": [] }`.
Either array may be omitted; at least one entry is required. Each array is
limited to 100 names; invalid usernames, wildcards or adding and removing the
same name return 400. Names are normalized and deduplicated. Every addition
must resolve to a public channel, or the entire change fails. The operation
starts from the currently resolved sources, preserves them unless explicitly
removed, applies the edits and activates the resulting Custom list. It does
not include inactive saved Custom entries automatically. No chat is joined,
no Telegram content is changed and write switches are untouched.

Settings are atomically saved and read back before success. An overlapping
scope/settings/token change during validation returns 409; read `/scope` and
retry. The 200 response has the same `{preset,sources,count}` shape as GET
`/scope`. Every attempt is audited; successful changes list added/removed
usernames in Activity. The local Scope screen immediately reflects the new
list and explains `Connected agents can manage public sources.` Token rotation
or disabling the connector still revokes the connection.

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

`GET /history/{username}?limit=30&cursor=<opaque>` — complete-history traversal
for one in-scope public channel. Returns `{ "posts": [...], "nextCursor":
"...", "exhausted": false }`. Omit the cursor initially; URL-encode and pass
each returned cursor unchanged. Cursors are exclusive message IDs, bound to
the source, so posts sharing a timestamp remain distinct. Malformed or
wrong-source cursors return 400. Limits are 1–100 raw Telegram messages per
request; short or empty filtered pages can still have a next cursor. Continue
until `exhausted: true` with `nextCursor: null`, which requires an empty
Telegram history response. Non-progress returns an error, never exhaustion.
Album parts remain individual posts on this route. Normal scope and safety
filters still apply; exhaustion describes accessible history, not deleted or
otherwise unavailable messages, and a scan is not a snapshot of later edits.

The date-based `/feed` routes are previews, not a complete-history contract:
the merged route uses the current app window, dates cannot distinguish equal
timestamps, and a bounded channel-preview scan can return 400 directing the
caller to `/history`. Full scans must use `/history` per source.

The owner can find channel titles locally under Connector → Custom →
`Find a channel`, then select `Add` for a public channel. This searches up to
100 matching known chats and shows only channels. Private channels are labelled
unavailable; no discovery endpoint or permission change is exposed to agents.

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
its real content type and exact `Content-Length`. Delivery is file-backed:
one 256 KiB chunk at a time, with socket backpressure; the bridge never loads
the entire video into RAM. `maxMediaBytes` defaults to 1 GiB. Set the local app
process environment `TGSOCIAL_CONNECTOR_MAX_MEDIA_BYTES` and restart to change
it (clamped to 1 byte–2 GiB). `/capabilities.limits.mediaBytes` reports the
actual cap. Known oversized files fail `413` before download; requests to
TDLib are bounded to cap + 1 bytes, with size checks before and after download.
Completed cache size must match Telegram's declared size when available.

`GET /media/{postId}/{index}/status` returns `downloadedBytes`, `expectedBytes`,
`active`, `complete`, `maxBytes`. It is authenticated and applies the same scope
and safety checks; it does not start a download or expose a local path.

The media request waits up to 10 minutes for Telegram, then streams the file.
Clients should allow that first-byte delay, poll status from another connection,
stream into a private file, and validate the received count against Content-Length.
The whole connection has a 15-minute deadline. Disconnecting cancels the bridge
request/delivery; disabling the bridge, rotating its token or signing out drops
all active sockets. When the final connector reader finishes, fails or disconnects,
the app cancels the fetch and deletes that file from TDLib's local cache. Concurrent
connector readers share a lease, so one finishing cannot delete another's file.
A later request downloads it again from Telegram; this can also make app playback
fetch the media again. No HTTP Range/resume or cryptographic digest is provided
yet. On a truncated transfer clients must discard their partial output or retry.

Mac TDLib media uses the app-private temporary directory `tgsocial-telegram-media`
(mode 700), cleared on the next process launch to recover from crashes. Connector
transfers also evict their file immediately after use. On migration, named TDLib
media cache folders under Application Support are removed; the session database
and binlog are preserved. Telegram is the persistent media store. The
session database, connector settings and token stay persistent so restarting does
not require setup again. Temporary files consume disk while a job is active;
they are not a permanent local media library. Clients must use temporary source
and working files too, retaining only final outputs the user requested.

Downloads are audited as `prepared-bytes` when the validated file is ready;
this does not assert that the client received every byte. Scope and safety are
rechecked after the potentially long download before any file headers are sent.

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
  signing out of Telegram revokes the connector too — with or without Bluesky.

## 9. Headless agent control

After the owner enables Connector, all supported requests work while the window
is hidden. The app must remain running in the Mac login session. Read the local
handshake file for its current port and bearer token; do not hard-code either.

- `GET /capabilities`: machine-readable methods, paths, fields, permission names,
  current write grants, limits and unsupported operations. All routes require bearer auth.
- `GET /connections`: Telegram sign-in/transport state, Bluesky sign-in status
  (Bluesky data is not exposed), app offline state and feed refresh state.
- `GET /channels?q=Captain`: search the signed-in account's locally known channels
  by title. Required nonblank query, at most 200 characters. Returns
  `{channels:[{title,username}],limit:100}`. Only public channels appear;
  private titles/IDs are excluded. This is discovery metadata, not message access.
  Use `PATCH /scope` to connect a result, then `/history/{username}` to query it.
- `POST /refresh`: requests the app's feed refresh and returns the same state as
  `/connections`. Inspect `refresh.inProgress`, `refresh.stale`, and
  `refresh.lastCompletedAt` (ISO-8601 or null): a queued or offline refresh is not
  a completed network sync. Poll `/connections` if still in progress.

`/status`, `/capabilities` and `/connections` can answer during a transient
signed-out state if the listener still exists. Other operations require sign-in.
Account authentication, account sign-out and changing write grants are not agent
API operations. Sign-out revokes the connector; the agent cannot grant itself
Telegram posting permissions. Existing `/post`, `/comment` and `/card` actions
work headlessly with their respective enabled grants. Public source additions
and removals preserve other sources and all write grants.

## 10. Headless media posting

Uses the existing **Post to my feeds** grant. The target must be a currently
in-scope public channel where Telegram says the signed-in account is creator
or administrator with `can_post_messages`. Unlike text `/post`, a media target
need not also be listed in the node card. This does not allow DMs or groups.
No endpoint accepts an arbitrary local path or remote URL.

1. `POST /uploads/{requestId}` with JSON:
   `{ "feed":"tastycrow", "kind":"video", "filename":"edit.mp4",
      "bytes":142756677, "sha256":"<64 hex characters>", "caption":"" }`.
   Use a fresh random request ID (8–80 ASCII letters/digits, `-`, `_`).
   Kinds: `video`, `photo`, `document`. All six fields are required. Captions are
   plain text, at most 1024 UTF-16 units. Photos are at most 10 MiB; other media
   use `/capabilities.mediaUpload.maxBytes` (default 1 GiB).
2. Read the source file in chunks of at most `chunkBytes` (1 MiB) and send each
   raw binary chunk using `PUT /uploads/{requestId}?offset=<receivedBytes>`.
   The normal bearer header is required for every chunk. This is bounded
   file-backed streaming over repeated HTTP requests, not JSON/base64. Chunk
   offsets must be contiguous. A repeated offset with identical saved bytes is
   acknowledged without appending twice; different bytes or gaps fail `409`.
3. `POST /uploads/{requestId}/send` with no body verifies the complete SHA-256,
   inspects the media and checks current posting rights/scope/grant again.
   Returns `202` with `state:queued` when a single Telegram send is scheduled.
   There is no automatic Telegram retry. Repeating this endpoint never schedules
   another send for that request ID.
4. Poll `GET /uploads/{requestId}`. Responses contain `state`, `phase`,
   `receivedBytes`, `uploadedBytes`, `bytes`, `postURL`, `error`, and `chunkBytes`.
   Local receipt is `uploading`, then `staged`/`verifying`. `queued` with phase
   `telegram-upload` reports network upload progress; phase `telegram-queue`
   means all bytes are uploaded but Telegram has not acknowledged the message.
   Only a final Telegram message acknowledgment produces `sent` and `postURL`.
   Use that link as the result, not a locally queued message ID.
5. `DELETE /uploads/{requestId}` cancels staging. For a queued send cancellation
   is best effort: pending messages are cancelled if still pending, but a post
   already accepted by Telegram can complete. This never deletes a confirmed
   published post. Disabling Post/Bridge, rotating the token, signing out, or
   removing the source also revokes pending work with this same boundary.

A request ID and its normalized metadata form an idempotency key. Creating the
same ID with different metadata fails `409`; creating it with the same metadata
returns the existing receipt. Small receipts persist across restarts. Send intent
is saved **before** the send call. Restart/network ambiguity yields `uncertain`,
never a second automatic send. If uncertain, inspect Telegram and the receipt;
do not invent a new ID and repost blindly. Late acknowledgments can still settle
the receipt. A send without acknowledgment after 10 minutes becomes uncertain.
Definite checksum/validation errors or Telegram send-failed events yield `failed`.
Terminal IDs cannot be reset or resent. GET remains readable if Post is disabled.

Staging is private temporary storage (`tgsocial-agent-uploads`, mode 700, files
600), at most four active jobs and a combined 1 GiB reservation. Unsent staging
expires after 15 minutes. Payloads are removed after success, failure, cancellation
or restart; the caller's original file is never read or removed by the app.
The receipt ledger is capped at 1000 IDs; it refuses new work rather than dropping
old duplicate protection. Signing out resets the account's ledger. A restarted
upload must use a new ID only after the old receipt is known not to have sent.

Video input must already be a Telegram-compatible MP4/H.264 file; the connector
inspects duration/dimensions but does not transcode. Photo and document paths
share the authorization and transfer checks. This API sends one media item per
post; albums, scheduling, caption formatting and editing published posts are
not supported. Audit entries record request ID, destination and final outcome,
never payloads or captions.
