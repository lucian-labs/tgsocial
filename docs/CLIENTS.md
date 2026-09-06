# Build your own client

tgsocial is a protocol with three reference clients, not an app with three
builds. The distinction matters because of where the graph lives: in Telegram
objects that any Telegram account can already read and write. Nothing about
this network is behind a program of ours, so a client you write is on it from
the moment it parses a card correctly. No key of ours, no review, no
registration, no handshake with anybody.

That is not a promise about the future. It is a description of the storage
layer. Read `PROTOCOL.md` and you have read everything the network knows how
to be.

## 1. What a client is here

A client is a program that reads and writes five kinds of Telegram object.
That is the whole surface.

| Object | What your client does with it |
| --- | --- |
| **Node channel** — a public channel with a username | Finds the user's own (`getCreatedPublicChats`), reads other people's (`searchPublicChat`) |
| **The card** — that channel's pinned message | Parses it for name, bio, link, feeds, follows, replies (`getChatPinnedMessage`); writes the user's own with `editMessageText` |
| **Feed channels** — ordinary public channels the user can post in | Reads posts with `getChatHistory`, writes with `sendMessage` |
| **A comments channel** — one public channel per node, listed as `replies:` | Reads and writes messages whose first line is `re: https://t.me/…` |
| **Channel descriptions** | Reads the `tgsocial v1` marker to recognise a node in search results, and `tgsocial: @<node>` to verify a feed |

Everything a feed contains is an ordinary channel post, so the read path is
`getChatHistory` and a merge. Following is appending `@name` to one line of
your own card and re-editing the pinned message; it joins nothing, notifies
nobody, and costs one `editMessageText`. `PROTOCOL.md §4` walks each operation
in TDLib terms, including the parts that bite — that `getChatHistory` returns
fewer messages than you asked for until you page it, and that a post's `t.me`
link needs `message.id >> 20`.

There is no reverse index anywhere in this. Nothing points from a node back to
whoever lists it, so a follower count is only ever a count over the part of
the graph your client has read. `PROTOCOL.md §5` renders one that way already
("Followed by N of yours"), and `PROTOCOL.md §6.3` defends a post's comment
count as "comments from your network". The complete number is what the storage
layer withholds, and `PROTOCOL.md §8` says what would have to exist before a
client could compute one — a property of the substrate, not a feature we
skipped.

## 2. The contract, in four rules

A client that keeps these is on the shared graph. The four below are copied
verbatim from [`docs/FORKING.md`](./FORKING.md), which is the normative one —
if the two lists ever differ, that page is right and this one is the bug.

1. **The card** (`PROTOCOL.md §2`) — the `tgsocial v1` marker line, the
   `key: value` line format, the known keys (`name, bio, link, public,
   feeds, follows, replies`), unknown-key tolerance, and the serialisation
   order. Add your own keys if you need them (readers ignore unknown keys);
   never repurpose an existing one.
2. **The comment format** (`PROTOCOL.md §6.2`) — `re: https://t.me/...`,
   one space, newline, body.
3. **The backlink** (`PROTOCOL.md §3`) — `tgsocial: @<node>` in a feed
   channel's description means verified; append, never replace.
4. **Ownership semantics** — one node per user, comments only in channels
   the commenter owns, `public: no` respected in every directory surface.

Rule 4 is the one that is easy to break by accident and impossible to detect
from outside, so it is worth saying plainly: a directory screen that shows a
`public: no` node is a client bug that other people pay for.

## 3. The executable contract

[`docs/card-vectors.json`](./card-vectors.json) is rules 1 and 2 as test data.
Wire your parser to it and compatibility stops being a reading-comprehension
exercise.

It holds `parse` (14 cases, among them a full card, a bare marker, two
non-cards, a `v2` card that must be recognised as newer rather than parsed,
CRLF and stray whitespace, repeated keys concatenating, unknown keys ignored,
invalid usernames dropped, `t.me` links accepted as usernames, a colon inside
a bio value), `serialise` (4 cases, exact expected bytes, including which
empty keys are omitted and that `replies` comes last), `username` (9
normalisation cases), `deepLink` (the `>> 20` shift), `backlink` (4 cases,
case-insensitive), `timeFormat` and `compactCount` for display, and `comment`
(6 parse cases and a serialise case).

Load the file, loop the arrays, assert. All three reference clients do exactly
that and nothing cleverer:

| Client | Test |
| --- | --- |
| iOS | `ios/Tests/CardVectorTests.swift` |
| Android | `android/app/src/test/kotlin/ca/lucianlabs/tgsocial/protocol/CardVectorsTest.kt`, fed by the `copyCardVectors` Gradle task |
| Web | `web/test/protocol.test.mjs` against `web/js/protocol.js` |

The display sections (`timeFormat`, `compactCount`) are there because the
reference clients agreed to look the same, not because the network cares. Skip
them if your client shows time differently. The card, username, deepLink,
backlink and comment sections are the ones that decide whether you interoperate.

## 4. What the protocol leaves you

Everything a person would actually call the product. The protocol says where
bytes live; it says nothing about what you do with them.

Ordering is yours. The reference clients are strictly chronological because
that was a decision, made once, in the client — `PROTOCOL.md §8` records it as
a choice, not a rule. Layout is yours, and so is what a feed even is,
whether you show counts, what you hide by default, which platform you
target, and whether you have a feed at all.

Four clients that would be legitimate and nothing like the ones in this repo:

**A ranked reader.** Same sources — your feeds plus the feeds of everyone you
follow — but scored locally instead of merged by date: how often you open a
given channel, how many people in your network commented on a post, a recency
decay you can tune. The scoring never leaves the device, because there is no
server for it to leave to, and nobody upstream can turn it off.

**An e-ink reader.** Text only. It never calls `downloadFile`, renders
`messageText` and captions and drops the rest, refreshes on a schedule instead
of on pull, and pages instead of scrolling. That drops a whole surface rather
than a feature: `media.js`, `spectro.js`, `strip.js`, `decode.js` and
`blobcache.js` are roughly 3.7k of the 13.8k lines under `web/js`, and this
client ships none of them.

**One person's site.** A build step, not an app: read one card, walk its
`feeds:` and `follows:`, emit static HTML. It can skip TDLib entirely by
reading Telegram's own public previews at `https://t.me/s/<channel>` — the
same door `PUBLIC.md` goes through — which means it needs no session and no
`api_id`, at the cost of being read-only.

**A terminal client.** One line per post, `j`/`k` to move, a key to open the
`t.me` link, a key to follow that rewrites your card. TDLib has C bindings and
bindings in most languages; the graph operations here are small enough that a
TUI is a weekend, not a project.

They all read the same graph. Someone using the e-ink client and someone using
the ranked one follow each other without either of them knowing what the other
runs.

## 5. What you need from Telegram

**A TDLib binding.** TDLib is Telegram's own client library and does the
MTProto, the local database and the file cache. The reference clients use
[TDLibKit](https://github.com/Swiftgram/TDLibKit) on iOS,
[`dev.g000sha256:tdl-coroutines`](https://github.com/g000sha256/tdl-coroutines)
on Android, and [tdweb](https://github.com/tdlib/td/tree/master/example/web)
(TDLib compiled to wasm) on the web. Those are examples of bindings that work,
not requirements — every operation in `PROTOCOL.md §4` is a plain TDLib
function call, so any binding in any language reaches all of them.

**Your own `api_id` / `api_hash`** from https://my.telegram.org/apps. This is
per application and not shareable: Telegram rate-limits and audits by app id,
so shipping on someone else's throttles both of you. Ours is not in this repo
and never will be. [`docs/BUILDING.md`](./BUILDING.md) covers getting a pair
and wiring it into a build.

Note that TDLib answers no chat read before authorization —
`searchPublicChat`, `getChat` and `getChatHistory` all return `401` until the
session is authorized, and `web/test/smoke.mjs` asserts it. A client with a
sign-in screen is the normal shape. A client without one is the third sketch
above, going through the public preview instead.

## 6. The limits

Telegram is the substrate and no client escapes it. Telegram enforces its own
rules and can delete a channel, and a deleted node channel is a deleted node —
there is no copy of it anywhere else, because the whole point is that there is
nowhere else. Your client can cache what it has read, but `PROTOCOL.md §7`
keeps local state deliberately thin — a pointer, some caches and the reader's
own safety lists — because the card is the source of truth and a cache that
outlived it would be lying.

The card's keys are fixed on purpose. "Design your own client" is not "design
your own data model" — the fixity is exactly what lets someone else's client
read what yours wrote, and it is why rule 1 lets you add keys of your own but
never repurpose one.

## 7. The worked example of adding keys

`PROTOCOL.md §10` is a professional layer — role, capabilities, expiring
intent, and vouches written by other people — added entirely in new
`work.`-prefixed card keys and one message format in the comments channel §6.1
already made. Nothing existing was repurposed and the marker is still
`tgsocial v1`, so a client that ignores all of it parses those cards into
exactly the cards it parses today; `docs/card-vectors.json` asserts that through
the same §2 loop every client already runs, and adds a `work` section for
clients that do implement it.

Read it as the shape of an extension rather than as a feature: namespace your
keys, keep the malformed ones non-fatal, write back what you read (§10.6 — a
serialiser that emits only the keys it knows deletes the rest on the next
follow), and say in the spec which of your numbers cannot exist without a
server (§10.5, §10.8). The product half is `PRODUCT.md §2.23`–`§2.26`, and it
is a different client's to disagree with — which is the whole point of §4.

And breaking the contract does not extend the network, it leaves it. A client
that writes a card in its own format still works, for its own users, on its
own graph, and none of the people already here can read them. That is a real
option and MIT permits it. It is just a different thing than the one this
document is about.
