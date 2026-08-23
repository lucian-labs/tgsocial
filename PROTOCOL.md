# tgsocial protocol — v1

tgsocial is a social network with no server. Everything it knows lives on
Telegram, in objects every Telegram client can already read: public channels,
pinned messages, descriptions. This document is the contract. Every client
(iOS, Android, web) implements exactly this; nothing here is platform-specific.

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

Signing out (`logOut`) clears all of it.

## 8. What v1 deliberately does not do

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
