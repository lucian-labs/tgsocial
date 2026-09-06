# tgsocial protocol — v1

tgsocial is a social network with no server. Everything it knows lives on
Telegram, in objects every Telegram client can already read: public channels,
pinned messages, descriptions.

This document is the contract clients implement, and implementing it is the
whole of joining the network. There is no registration with us, no API key of
ours, no review: a client that reads and writes a card correctly is on the same
graph as every other one from its first run, because the graph is Telegram's
objects and this is how they are read. The one registration in the picture is
Telegram's own — every client, ours included, ships its own `api_id` /
`api_hash` from https://my.telegram.org/apps (§4). The three clients in this
repo (iOS, Android, web) share the protocol and a design kit, and they
interoperate because of the first, not the second. Nothing here is
platform-specific.

What the contract leaves out is as deliberate as what it fixes. Ordering, what a
feed looks like, whether counts are shown, what is hidden by default — none of
that is below, so two clients can disagree about all of it and still show the
same graph. [`docs/CLIENTS.md`](./docs/CLIENTS.md) is the case for writing your
own; [`docs/FORKING.md`](./docs/FORKING.md) states the four things a client must
keep to stay on the network, and [`docs/card-vectors.json`](./docs/card-vectors.json)
is the executable form of the first two.

The design goal is that a person with plain Telegram and no tgsocial app can
still read the graph by hand — open a node channel, read its card, tap the
usernames. The app is a lens, not a gatekeeper.

## 1. Objects

| Term | What it is on Telegram |
| --- | --- |
| **Node** | A public channel (has a username) that represents one person on the graph. Its pinned message is the **card**. |
| **Card** | The pinned message of a node channel. Plain text in the line format in §2. Holds name, bio, feeds, follows. |
| **Feed** | Any public channel the node's owner administers and lists in the card's `feeds:` line. Posts in a feed are ordinary channel posts. |
| **Follow** | An edge from node A to node B: `@B` appears in A's card `follows:` line. Follows are one-way. |
| **Main feed** | The chronological merge of every post in every feed of every node you follow, plus your own feeds. |
| **+1 network** | The nodes followed by the nodes you follow (distance 2). The graph is walked by reading cards; no index is required. |

A Telegram user owns at most one node. A node may list many feeds. A feed may
be listed by more than one node (co-admins), which is allowed.

## 2. The card format

The card is the pinned message of the node channel. It is plain text,
UTF-8, at most 4096 characters (Telegram's message limit).

```
tgsocial v1
name: Elijah Lucian
bio: Staff product architect. Software, music, voice.
link: https://elijahlucian.ca
public: yes
feeds: @waveloop_devlog @tresbuchet
follows: @tgs_ana @tgs_bob @tgs_carol
```

Rules:

- Line 1 is the **marker** and MUST be exactly `tgsocial v1`. A pinned message
  that does not start with this line is not a card; the channel is not a node.
- Every other line is `key: value`. Keys are lowercase ASCII. Whitespace around
  the colon is trimmed. Unknown keys MUST be ignored (forward compatibility).
- `name` — display name. Falls back to the channel title if absent.
- `bio` — one line, free text. Optional.
- `link` — one URL. Optional.
- `public` — `yes` or `no`. Whether the node wants to appear in directories
  (§5). Default `yes`.
- `feeds` — whitespace-separated channel usernames, each with a leading `@`.
  Order is the owner's preferred display order.
- `replies` — one channel username with a leading `@`: the node's **comments
  channel** (§6). Optional; absent means the node doesn't comment, or hasn't
  yet.
- `follows` — whitespace-separated node usernames, each with a leading `@`.
  Order is chronological (oldest first); clients append.
- A key MAY be repeated; values concatenate with a space. This is how a client
  continues `follows:` past a long line without a second message.
- Usernames are case-insensitive. Clients normalise to lowercase when comparing
  and MUST NOT rewrite the owner's casing when re-serialising other keys.
- Tokens that are not valid Telegram usernames (5–32 chars, `[A-Za-z0-9_]`,
  no leading digit) are ignored. `https://t.me/<name>` and `t.me/<name>` are
  accepted as aliases for `@<name>`. Duplicates collapse to the first.

Serialisation when the client writes the card: emit the marker, then keys in
the order `name, bio, link, public, feeds, follows, replies`, omitting empty
`name`, `bio`, `link`, `feeds`, `follows`, `replies`; `public` is always
written. One space
after the colon. No trailing whitespace. `\n` line endings. Shared test
vectors live in `docs/card-vectors.json`; every client's unit tests run them.
If the result would exceed 4096 characters the client MUST refuse the write
and surface "Card is full." — v1 caps `follows` at whatever fits.

The node channel's **description** (Telegram "about", 255 chars max) SHOULD
begin with `tgsocial v1` followed by ` · ` and the bio. This lets a client
recognise a node from a search result without fetching the pinned message.
The pinned message, not the description, is authoritative.

## 3. Identity and ownership

- The node channel's creator is the node's owner. Clients MAY verify with
  `getChatMember(chat, me)` returning `chatMemberStatusCreator`; for foreign
  nodes this is not checkable and is not needed.
- **Feed ownership is claimed, and optionally verified by backlink.** When the
  owner marks a channel as a feed, the client offers to append
  `tgsocial: @<node>` to that channel's description. A feed whose description
  contains `tgsocial: @<node>` for the listing node is **verified**; clients
  show a `Verified` pill. A feed without a backlink is still shown, unmarked.
  Clients MUST NOT drop unverified feeds in v1.
- A node MUST NOT list a channel as a feed unless the owner is an
  administrator with post rights (`can_post_messages`) or the creator. Clients
  enforce this on write; readers cannot enforce it and rely on backlinks.

## 4. Operations (TDLib)

All clients use TDLib (the official Telegram client library) with the
operator's own `api_id` / `api_hash`. Function names below are TDLib's.

### 4.1 Sign in

`setTdlibParameters` → `setAuthenticationPhoneNumber` →
`checkAuthenticationCode` → (if `authorizationStateWaitPassword`)
`checkAuthenticationPassword` → `authorizationStateReady`.
Handle `authorizationStateWaitOtherDeviceConfirmation` by showing the QR
link as plain text; handle `authorizationStateWaitRegistration` by refusing:
"Sign up in Telegram first." (tgsocial never creates Telegram accounts).

### 4.2 Find my node

1. `getCreatedPublicChats(publicChatTypeHasUsername)` → for each channel,
   `getChatPinnedMessage`; the first whose text starts with the marker is mine.
2. Cache `{chatId, supergroupId, username, pinnedMessageId}` locally.

### 4.3 Create my node

1. `createNewSupergroupChat(title, isForum=false, isChannel=true,
   description="tgsocial v1", ...)`.
2. `checkChatUsername(chatId, username)` then `setSupergroupUsername(
   supergroupId, username)`. Suggested default: `tgs_<telegram username>`,
   or `tgs_<firstname><4 digits>` when the user has no username. Telegram
   allows at most 10 public channels per user; surface the TDLib error text
   verbatim ("Too many public channels.") rather than inventing one.
3. `sendMessage(chatId, inputMessageText(card))` with `disable_notification`.
4. `pinChatMessage(chatId, messageId, disableNotification=true)`.
5. Optionally `setChatPhoto` from the user's profile photo.

### 4.4 Write my card

`getChatPinnedMessage` → modify → `editMessageText(chatId, messageId,
inputMessageText(card))`. Never send a second card message; the pinned one is
the record. If the pin was lost, re-pin the existing card message.

### 4.5 Read any node

`searchPublicChat("<username>")` → `getChatPinnedMessage(chat.id)` → parse.
Avatar = `chat.photo`. Title = `chat.title`. Cache parsed cards locally with
a `fetchedAt`; refresh on pull-to-refresh and when opening a profile.
A node whose card fails to parse is shown as "Not a tgsocial node."

### 4.6 Follow / unfollow

Append/remove `@node` in my card's `follows:`, then §4.4. Following does NOT
join any Telegram chat. Clients MAY offer "Join on Telegram" per feed as a
separate action.

### 4.7 My feeds

Candidate feeds = channels (`chatTypeSupergroup` with `isChannel`) where my
`chatMemberStatus` is creator or administrator with `can_post_messages`, AND
the supergroup has a username. Discover via `getCreatedPublicChats` plus a
scan of `getChats(chatListMain, 200)`. Private channels are listed disabled
with the hint "Needs a public link." Toggling a feed rewrites `feeds:` (§4.4)
and offers the backlink (§3).

### 4.8 Main feed

Sources = my feeds ∪ feeds of every node in my `follows:`.

For each source: `searchPublicChat(username)` → `getChatHistory(chatId,
fromMessageId=0, offset=0, limit=30, onlyLocal=false)`. TDLib may return
fewer messages than `limit` on the first call (it returns what is cached);
call again with `fromMessageId = lastReturnedId` until you have 30 or the
response is empty.

Merge: k-way by `message.date` descending. Keep a per-source cursor (oldest
`message.id` fetched). "Load more" refills the source whose buffer is empty
and whose last-known item was newest, then continues the merge. Reading
public channel history does not require joining.

Ignore service messages (`messagePinMessage`, `messageChatChangePhoto`, etc.)
and the card itself. Render `messageText`, `messagePhoto`, `messageVideo`
(thumbnail + duration), `messageAnimation`, `messageDocument` (file name),
`messageAudio`, with `content.caption` where present. Apply text entities for
bold, italic, code, links, mentions; everything else renders as plain text.

Counts: `interactionInfo.viewCount`, `interactionInfo.reactions`.
`forwardInfo` shows "Forwarded from <origin>".

Deep link for a post: `https://t.me/<username>/<serverMessageId>` where
`serverMessageId = message.id >> 20` (TDLib shifts server ids by 20 bits).

### 4.9 Post

`sendMessage(feedChatId, inputMessageText)` or `inputMessagePhoto`. Only into
my own feeds. Channels post as the channel, so no `sendAs` handling in v1.

### 4.10 Media

`downloadFile(fileId, priority=1, offset=0, limit=0, synchronous=false)`,
then wait for `updateFile` with `local.isDownloadingCompleted`; read from
`local.path` (native) or `readFile`/IndexedDB (web). Use the smallest photo
size ≥ the display width. Cache by `file.remote.uniqueId`.

### 4.11 Delete my node

Removes the two channels the client created (`PRODUCT §2.21`). Order is
fixed: comments channel, then node channel.

1. If the card carries `replies: @<username>`, `searchPublicChat` it and check
   `chat.canBeDeletedForAllUsers`. False → stop, nothing deleted, report "not
   the owner". True → `deleteChat(chatId)`. Any error → stop, nothing else is
   touched.
2. Check `chat.canBeDeletedForAllUsers` on the node channel, then
   `deleteChat(myNode.chatId)`. If this fails after step 1 succeeded, strip
   `replies:` from the card and write it (§4.4) so the card stops pointing at
   a channel that no longer exists.
3. On success clear the `myNode` pointer, the card cache, the feed cache, the
   comment index and the feed cursors — everything §7 calls discardable —
   without `logOut`. The session stays authorized and the client is nodeless.

`deleteChat` releases the channel's username. Feed channels listed in
`feeds:` are never deleted: the client did not create them and other things
may depend on them.

## 5. Discovery

Three modalities; clients implement all three and union the results.

1. **Graph walk.** For every node in my `follows:`, read its card; its
   `follows:` are my +1. Rank +1 nodes by how many of my follows list them.
   Depth 2 only in v1.
2. **Username prefix.** `searchPublicChats("tgs_")`. Telegram returns up to
   ~20 matches; filter to chats whose description begins with the marker or
   whose pinned message parses as a card. The `tgs_` prefix is a convention,
   not a requirement — a node with any username is still a node.
3. **Index group.** The public supergroup `@tgsocial_index`, if it exists.
   Members post one message `node: @tgs_x` to list themselves; clients read
   the last 200 messages and parse that line. A node with `public: no` MUST
   NOT be announced, and clients MUST skip such nodes when rendering
   directories even if they appear in the group. Announcing is explicit
   (a button on the You screen), never automatic.

A directory entry shows the node's name, username, feed count, and — for +1
results — "Followed by N of yours".

## 6. Comments and replies

Comments live in the commenter's own channel, not the author's — the same
ownership rule as everything else here. Nobody can put words on your post;
they can only point at it from a channel they own.

### 6.1 The comments channel

Each node MAY have one **comments channel**: a public channel owned by the
node's owner, listed in the card as `replies: @<username>`. Convention:
`<node>_r` (e.g. `@tgs_elijah_r`), created by the client on the user's first
comment after an explicit confirm ("Make your comments channel."). The owner
manages it like any channel — edit or delete comments from any Telegram
client, delete the channel to withdraw everything.

### 6.2 The comment format

A comment is an ordinary message in a comments channel whose first line is a
`re:` pointer to the target, followed by the comment body. For media
comments the pointer line leads the caption.

```
re: https://t.me/waveloop_devlog/144
Nice one. The bass is huge.
```

- The first line MUST be `re: ` + a `t.me` post link (`PROTOCOL §4.8` deep
  link form). Everything after the first newline is the body. A message
  without that first line is not a comment (owners may post anything else in
  their channel; readers skip it).
- The target may be a feed post **or another comment** (comments channels
  are public channels, so every comment has its own `t.me` link) — that is a
  reply, and threads are exactly `re:` chains. Clients cap rendered depth at
  5 and show deeper replies flattened.
- One comment targets one post. Editing/deleting the message on Telegram
  edits/deletes the comment.

### 6.3 Reading comments — network-scoped by design

There is no global comment index and none is wanted. When a client renders a
post, the comments it shows are those found in the comments channels of:

1. me,
2. every node in my `follows:`,
3. my +1 nodes (distance 2), best-effort and cached.

The client maintains a local **comment index**: for each known comments
channel, page `getChatHistory` newest-first (same repeat-until-filled loop
as feeds), parse `re:` lines, and index by target link. Refresh alongside
the feed; a post's comment count is "comments from your network", which is
the honest number a serverless design can give. Two different users may see
different comment sets — that is the model, not a bug: you read the people
you chose.

### 6.4 Writing

`sendMessage(myRepliesChatId, inputMessageText | inputMessagePhoto | …)`
with the `re:` line prepended (as text, or as the caption's first line).
If the card has no `replies:` yet: create the channel (§4.3 steps 1–2 with
the `_r` username; description `tgsocial v1 replies · @<node>`), add
`replies:` to the card (§4.4), then send. The reply channel's description
backlink lets readers verify it belongs to the node.

### 6.5 Interop

A plain-Telegram reader sees a channel of quotes with tappable links — the
`re:` line is a working deep link, so the format degrades gracefully. Forks
and other clients MUST keep §6.2 byte-compatible: `re: ` prefix, one space,
full `https://t.me/...` link, newline, body.

## 7. Local state

The card is the source of truth for the graph. Locally a client keeps only:

- TDLib's own database (auth, chats, files).
- `myNode` pointer (chat id, supergroup id, username, pinned message id).
- Card cache keyed by username with `fetchedAt`.
- Per-source feed cursors for pagination (discardable).
- The comment index (§6.3): comments-channel → parsed pointers (discardable).
- UI preferences.
- The **safety lists** below.

Signing out (`logOut`) clears all of it except the safety lists.

### 7.1 Safety lists

The reader's own block, mute and report state (`PRODUCT §2.15`–`§2.18`). One
record, stored apart from every cache:

```json
{
  "v": 1,
  "userId": 176543210,
  "blocked": ["tgs_ana", "tgs_bob"],
  "mutedFeeds": ["waveloop_devlog"],
  "hidden": [
    { "key": "waveloop_devlog/144", "reason": "Spam", "at": "2026-09-04T21:02:11Z" }
  ]
}
```

- `blocked` and `mutedFeeds` are **node** and **feed channel** usernames,
  lowercased, no `@`. Compare with the same normalisation the card parser
  uses (`usernameKey`) — Telegram usernames are case-insensitive and a list
  that missed `@TGS_Ana` would be a filter with a hole in it.
- `hidden[].key` is the §6.2 target key, `<channel>/<messageId>`, lowercased
  — the same string a `re:` line resolves to, so a hidden post and a hidden
  comment are the same kind of key and one lookup filters both.
- `hidden[].reason` is the reason string `PRODUCT §2.15` sent in the email,
  verbatim, so Settings can show what was reported without storing the
  content. `at` is ISO 8601 UTC.
- `v` is this record's own version and is **not** the cache schema version
  (`PRODUCT §2.3`): a cache bump discards caches, and it must never discard
  someone's block list. Unknown `v` is read as best it can be and never
  dropped.

**It survives Sign Out, for the same account.** `userId` is the Telegram user
id that wrote the record; on reaching `authorizationStateReady` a client
compares it and, on a mismatch, replaces the lists with empty ones. A block
list that evaporated on sign-out would re-expose the reader to the person
they blocked the next time they signed in, and a list inherited by a
different account on a shared device would be someone else's judgement — the
id settles both. `PRODUCT §2.21` (delete my node) keeps the record too: it
protects the person, not the node.

Per platform:

| Platform | Home |
| --- | --- |
| iOS / Mac | `LocalStore` file `moderation.json` under `Application Support/tgsocial`. `LocalStore.clear()` must preserve it — it wipes the directory today, so sign-out reads the record, clears, and writes it back. |
| Android | The `tgsocial` Preferences DataStore, key `moderation`, holding the JSON. `LocalStore.clear()` clears every other key. |
| Web | `localStorage["tgs.moderation"]`, excluded from the sign-out loop over `LS` and from the versioned-cache path. |

**The demo has no user id, and no home.** `PRODUCT §2.22` runs the app on
invented fixtures with no Telegram session behind it, and block, mute and
report work there in full. That state is a record of this shape held **in
memory**, with `userId: null`, and a `userId: null` record MUST NOT be written
to any of the three homes above. The reverse holds too: a demo session MUST NOT
load the stored record. A demo block is not the reader's judgement about a real
person, and a real block list is not a demo's to show.

**Nothing here is published.** The lists are never written to the card, never
sent to Telegram (a tgsocial block is not a Telegram block), and never leave
the device by any route. No other client can read them, and the blocked node
is not notified — there is nowhere for a notification to come from. The only
thing that ever leaves is the report email in `PRODUCT §2.15`, which the
reader's own mail client sends and which carries a link, a reason, and
nothing about any list.

## 8. What v1 deliberately does not do

Most of this is a decision the clients in this repo made rather than a rule the
format imposes. What is normative is the compatibility contract in
[`docs/FORKING.md`](./docs/FORKING.md) — the card, the comment format, the
backlink, ownership semantics — and a client that keeps those four can order a
feed however it likes and still be on this network. Two of the items below are
the substrate rather than the choice: private feeds, because §1 defines a feed
as a public channel, and the followers count, because nothing in Telegram
indexes an edge in reverse — its bullet says what would have to exist before a
client could show one. The rest is listed so a fork disagrees on purpose.

- No ranking, no recommendations. The main feed is strictly chronological.
- No likes or reposts in-app. Telegram reactions and native channel
  discussions stay on Telegram; a post's "Open in Telegram" link lands on
  them. (tgsocial's own comment threads are §6 and are in-app.)
- No followers count. There is no reverse index without a server; a future
  version may compute it from the index group.
- No private feeds. A feed is a public channel.
- No DMs. Telegram has them.

## 9. Versioning

The marker carries the version. A v2 card will start with `tgsocial v2` and
v1 clients MUST treat it as "Newer card. Update the app." rather than
silently ignoring it. Keys added to v1 later are ignored by older clients by
rule; keys removed or renamed require a version bump.

## 10. Extension: work

A professional layer, built as an extension rather than a version. This is the
first thing added to the card since v1 froze, and it is here to be the worked
proof of the claim `docs/FORKING.md` rule 1 and `docs/CLIENTS.md` make — that a
client may add keys and stay on the same graph — so it is held to that claim
rather than excused from it.

Three properties, and each is checkable rather than asserted:

- **Additive.** New keys only, nothing existing repurposed. §2 already says
  unknown keys are ignored, so a client that does not implement this section
  parses a card carrying it into exactly the card it parsed before — the vector
  `work keys are unknown keys to the v1 parser` in
  [`docs/card-vectors.json`](./docs/card-vectors.json) is that sentence as a
  test, run by the same loop every client already has. The marker stays
  `tgsocial v1`; §9 is not touched.
- **Ownership unchanged.** The only thing a person can write is their own
  channel. So a self-claim (what you do) lives on your own card, and a claim
  about someone else — a **vouch** — lives in the claimant's channel and points
  at the subject, the same shape §6 uses for comments. Nobody can write a word
  onto your node.
- **No server.** No index, no directory beyond §5, no verifier. Every number
  this section produces is scoped to what the reader's own client walked, and
  §10.8 says plainly which numbers therefore cannot exist.

### 10.1 Namespaced keys

Every key below is prefixed `work.`. §2's keys are bare because they are the
protocol's own; an extension's are not, and two extensions written by people
who never met must not collide on `role:`. A client adding keys of its own
SHOULD take a prefix the same way. Parsing is unchanged: `work.role` is a
lowercase ASCII key with a colon, and to a client that has never heard of it,
an unknown one.

### 10.2 The keys

All optional. A card with none of them has no work card, which is the state of
every card written before this section existed.

| Key | Value | Cap |
| --- | --- | --- |
| `work.role` | One line, free text. What you do. | 80 characters |
| `work.does` | Comma-separated capability tags. | 12 tags, each 2–24 characters |
| `work.open` | `<intent> until <YYYY-MM-DD>` (§10.3). | one |
| `work.feeds` | Whitespace-separated channel usernames, each `@`-led, each of which MUST also appear in `feeds:`. | fits the card |

- A **tag** is lowercased, its inner whitespace collapsed to single spaces, and
  matches `[a-z0-9][a-z0-9 +#.-]{0,22}[a-z0-9+#]` — so `c++`, `c#`, `node.js`
  and `front of house` are tags and `live/sound` is not. Tags are compared
  lowercased; duplicates collapse to the first.
- **Malformed values are dropped, never fatal.** A `work.role` longer than 80
  characters keeps its first 80. A tag outside the grammar is dropped and the
  rest of the line stands. Tags past the twelfth are dropped. A `work.open`
  that does not match the grammar, names an intent outside the closed set, or
  carries a date that is not a real calendar day (`2026-02-30`) is absent. A
  `work.feeds` entry not present in `feeds:` is dropped — `feeds:` is the
  ownership claim, and §3 requires post rights for it, so a marking line has no
  business introducing a channel the owner never claimed. A card whose every
  work line is malformed is a card with no work card. **A malformed work line
  never invalidates the card**; §2 decides what a card is, and it decides
  alone.
- Repetition follows §2: a repeated `work.` key concatenates with a space.

Serialisation: the §10 lines come **after** every §2 key, in the order
`work.role, work.does, work.open, work.feeds`, each omitted when empty.
`work.does` is written comma-and-space separated, and `work.feeds` is written
as its intersection with `feeds:` — the MUST above is a rule about the wire,
not only about what a reader forgives, so a channel that leaves `feeds:` takes
its marking with it in the same write. A writer that keeps the dangling entry
puts a line §10.2 forbids in a message its owner can read on plain Telegram,
and re-marks that channel as work the moment it is listed again. §2's own order and output are
unchanged, so a card written before this section and one written after differ
by an append — a diff a person reading their own channel on Telegram can
follow. The 4096-character cap is §2's and is unmoved; a full work card costs
about what a `bio` costs, and the client refuses the write with `Card is full.`
the same way.

### 10.3 Intent expires

`work.open` is the one time-sensitive thing on a card, and stale intent is
worse than none: a year-old "open to work" wastes the reader's message and
embarrasses the writer. So it carries its own end date and the reader enforces
it.

Intent is one of a closed set — `work`, `contract`, `hiring`, `collab` — and
unknown intents are dropped rather than shown, because a client cannot render
a word it has no copy for. The date is `YYYY-MM-DD`, interpreted UTC.

A reader MUST treat `work.open` as **absent** when the date is behind today, and
also when it is more than **180 days** ahead. The second rule is the one that
makes the first mean something: `until 2099-01-01` is an expiry nobody ever has
to renew, which is no expiry. Both are pure reader-side arithmetic on the card
text and need no write date. There is no rendering of an expired intent — not
greyed, not "was open until" — it is simply not there.

Writers SHOULD offer horizons well inside the cap; the reference clients offer
30, 60 and 90 days (`PRODUCT §2.23`).

A writer MUST NOT move an existing `work.open` date except when the person
picked one. §10.6 requires writing back what you read, and a client that
recomputes the horizon on every card write instead — a follow, a bio edit, a
feed toggle — has built `until 2099-01-01` out of moving parts: the intent
renews itself forever and is never re-asserted by anybody. The same arithmetic
run on an expired date resurrects intent this section had retired. Preserving
the stored date, expired or not, is both rules at once.

### 10.4 The vouch

A self-claim is cheap and the card is already made of them. The one thing a
professional network has that a social one does not is a statement someone
**else** makes about you, and its whole value is that you cannot write it. That
maps onto §6 without inventing anything: the voucher writes it in the voucher's
own channel, pointing at your node.

A vouch is an ordinary message in the voucher's **comments channel** (§6.1,
`replies: @<username>`) — no new channel, no new card key, and one pass over
one channel builds both the comment index and the vouch index.

```
vouch: https://t.me/tgs_elijah
does: live sound
Ran front of house for two years. Never missed a cue.
```

- Line 1 MUST be `vouch: ` — one space — then the **node channel's** link,
  `https://t.me/<node>`, with no message id and no trailing slash. A link with
  a message id is a §6.2 comment, not a vouch.
- Line 2 MUST be `does: ` then **exactly one** tag, in the §10.2 grammar.
  Both lines are mandatory: a `vouch:` with no `does:` asserts "I vouch for
  this person", which nobody can weigh and which decays into a like button
  inside a week. The claim is specific or it is nothing. A message missing
  either line is not a vouch; readers skip it, the same way §6.2 skips a
  message with no `re:` line.
- Everything after the second newline is the body, and it may be empty.
- **One vouch, one tag, one message.** Vouching the same person for two things
  is two messages. This is what makes a vouch countable per capability rather
  than in aggregate, and §10.8 says why the aggregate would be a lie anyway.
- The tag does **not** have to appear in the subject's `work.does`. A vouch is
  the voucher's sentence and the subject cannot edit it, including by editing
  their own card; a client renders such a vouch under its own heading
  (`PRODUCT §2.23`).
- **A vouch for the channel's own owner MUST be ignored by readers.** The
  format is unforgeable only because the one channel a person can write is the
  one that cannot speak about them, and a client that renders a self-vouch has
  given that away.
- That rule is only as good as the binding it is checked against, and the
  binding is `replies:` — a claim on somebody's own card, which **nothing
  verifies**. A feed has §3's description backlink; a comments channel has no
  equivalent a reader can rely on. So when two nodes in the reader's scope
  claim the same comments channel, the client cannot tell which owns it and
  **MUST NOT attribute that channel to either**: dropping it costs the reader
  some comments, and awarding it renders the one message the format forbids —
  a self-vouch, wearing the name of whoever the walk reached first. A client
  MAY except the reader's own node, which is the one card in the walk they
  wrote themselves.
- Editing or deleting the message on Telegram edits or deletes the vouch. The
  subject cannot delete it — that is the cost of the guarantee, and
  `PRODUCT §2.25` says so to the person it costs.

A plain-Telegram reader sees a channel of short statements with a working link
to the person each is about, which is the same graceful degradation §6.5 asks
for. Forks MUST keep the two lines byte-compatible.

### 10.5 Reading vouches — network-scoped, like everything else

§6.3 applies unchanged and for the same reason. The vouches a client shows for
a node are those found in the comments channels of me, every node in my
`follows:`, and my +1 — the channels it was already paging for comments, now
classified two ways instead of one.

So a vouch count is **vouches from your network**, and two readers looking at
the same person see different ones. Say it plainly, because it is the part
that sounds like a bug and is not: a node with two hundred vouches shows
**zero** to a reader who follows nobody, and a person's own client shows them
only the vouches whose writers they can reach — **you can be vouched and never
know it**. There is no reverse index in Telegram (§8) and no server here to
build one, so the complete number does not exist for anyone. What a client can
honestly render is *who* — names the reader recognises, from their own network,
which they can weigh themselves.

So a client MAY show a figure, and it MUST be one the reader can resolve into
names in one step and MUST be labelled with its scope. `Vouched by 2` above a
list of the two is a description of what this reader can see; `2 endorsements`
is a claim about the world, and there is no world here to make it about.
`PRODUCT §2.23` and `§2.25` are that distinction on a screen.

### 10.6 Writing, and the one thing that can go wrong

A client that implements this section MUST write back the work lines it read
when it rewrites the card for any other reason. Following somebody is an
`editMessageText` of the whole pinned message (§4.4, §4.6), and a serialiser
that emits only the keys it knows deletes the rest.

That hazard is real and it reaches past this section: §2 says unknown keys are
ignored, and ignoring is exactly what destroys them on the next write. So a v1
client that has never heard of `work.` **will** drop these lines the first time
its user follows anyone, and it is behaving correctly when it does. The
consequences, honestly:

- The loss is one person's own work card, on their own node, caused by their
  own second client. It is not silent to them — their work card is simply
  empty next time they look — and re-entering it is a minute's typing.
- Nobody else's data is touched, and no other client's read is broken.
- The fix belongs to whoever adds a key, not to whoever ignores it: **an
  extension is only as durable as the clients that implement it.** A future
  revision of §2 could require preserving unknown lines on rewrite. This
  section does not require it retroactively, because a rule that quietly
  reclassifies every shipped v1 client as broken is not an additive change.

`docs/card-vectors.json` holds both halves as `§10.6` in the web suite: a
§2-only rewrite drops the lines, and a round-tripping rewrite keeps them while
changing nothing a §2 client can see.

### 10.7 Discovery by capability

§5's three modalities, honestly assessed against "find me people who do X":

1. **Graph walk — yes, and bounded.** Cards the client has already read carry
   `work.does`; filtering them is local, instant, and covers exactly the
   reader's follows and +1. It is not search, it is a filter over a network the
   reader assembled themselves.
2. **Username prefix — no.** `searchPublicChats` indexes usernames and titles,
   not card contents. Telegram will never return a node because of a tag inside
   its pinned message. A client MUST NOT present capability search as though it
   reaches the whole network.
3. **Index group — partially.** A node announcing itself in `@tgsocial_index`
   (§5.3) MAY add a second line to its announcement:

   ```
   node: @tgs_elijah
   does: swift, product architecture, live sound
   ```

   This is additive to §5.3 — the `node:` line is unchanged and clients that
   only read it are unaffected. It exists so a directory can filter a couple of
   hundred announcements without fetching a couple of hundred cards. It is
   **stale by construction**: it says what someone claimed when they announced,
   which may be old and which they may never revisit. A client MUST resolve the
   node's card before showing its profile, and the card wins.

The union of 1 and 3 is what capability discovery is here, and it is smaller
than a search box implies. `PRODUCT §2.24` prints that limit on the screen
rather than in a footnote.

### 10.8 What this section deliberately cannot do

Each of these needs an authority. There is none, and a version that pretends
otherwise would be worse than the absence.

- **Verified employment.** `work.role` is a self-claim, exactly as `bio` is.
  Nothing can check it, no company can confirm it, and the `Verified` pill §3
  defines for a feed backlink MUST NOT appear anywhere on a work card — that
  pill means one checkable thing and lending it to an unverifiable one empties
  it.
- **A vouch count that means anything.** §10.5: no reverse index, so no total.
  Clients show who, not how many out of what.
- **Reputation scores, rankings, "top" anything.** They need a complete graph
  to be computed over and an authority to be trusted. Neither exists.
- **A global capability directory.** §10.7.2.
- **Company or organisation nodes.** §1 is one node per person, and an
  employment edge between a person and an organisation would be a claim by one
  about the other with nothing to check it. A company can make a node like
  anyone else and post from it; it just cannot be anyone's employer here.
- **Job postings as an object.** A posting is an ordinary post in a work feed.
  A first-class one would need an index to be findable, which is the same
  server this network does not have.
- **Negative vouches.** Deliberately absent from the format. Unforgeable-by-
  construction cuts both ways: a claim written in the claimant's own channel,
  about someone else, reachable through that someone's own network, with no
  takedown path anywhere in the design, is a harassment tool. The `does:` line
  makes a vouch a statement of capability and there is no grammar here for its
  negation.
