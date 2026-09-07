# Forking tgsocial

Fork it. Reskin it, rearrange it, strip it down, build it into something
else — that's the point of MIT and of a network with no server: the network
can't tell which client wrote a card, and nobody has to approve yours.

Forking this repo and starting from an empty file are the same move at two
distances. A fork inherits the clients, the design kit and the tests and changes
what it wants; a client written from scratch inherits only the contract below.
Both land on the same graph on the same terms.
[`docs/CLIENTS.md`](./CLIENTS.md) argues the far end of that range — why you might
want a reader nobody else would ship. This page is where the rules live for
either end of it.

The one thing that keeps every fork part of the *same* network is the
protocol. The graph lives in Telegram objects, so interop is nothing more
than reading and writing them the same way.

## The compatibility contract

A fork that wants its users on the shared graph MUST keep, byte for byte:

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

Everything else is yours, including every product decision the protocol
declines to make: ordering, what a feed even looks like, whether you show
counts, what you hide by default, one column or three. Chronological-only is
our choice, not a law (`PROTOCOL.md §8`). `docs/card-vectors.json` is the
executable form of rules 1–2: wire your parser tests to it and you're
compatible.

Break rule 1 and nothing stops you — you are simply on your own network then,
with your own users, which is a fine thing to build and a different thing from
this one. The four rules are the price of the shared graph and the only price
of it. The rest of this page — your own `api_id`, your own identifiers,
Telegram's own rules — is the price of shipping a client at all, and it holds
whether you forked this repo or started from an empty file.

## Running an instance

Putting up a public instance is [`docs/HOSTING.md`](./HOSTING.md) — a client you host
for other people. What it holds (nothing), what it makes you responsible for
(more than you would guess), and why it needs its own api_id.

## What you must change

- **API credentials.** Get your own `api_id`/`api_hash`
  (https://my.telegram.org/apps). Telegram rate-limits and audits per app
  id; shipping on someone else's id gets both of you throttled.
- **Bundle / application id** (`ca.lucianlabs.tgsocial` is ours) and the
  app name on any store listing.
- **The wordmark.** The House Pour look and the `design/` kit are MIT — use
  them — but don't present your fork as published by Lucian Labs.

## What you may not do (Telegram's rules, not ours)

Third-party clients are explicitly allowed by Telegram, with obligations:
no spam or bulk automation, respect flood-wait, don't misrepresent the
client to the API, keep user data on-device. See
https://core.telegram.org/api/terms.

## Extending the protocol

Propose changes as PRs against `PROTOCOL.md` + `docs/card-vectors.json` in
the upstream repo. New optional card keys are cheap (old clients ignore
them); anything that changes the meaning of existing lines needs a
`tgsocial v2` marker and a migration story (`PROTOCOL.md §9`).
`PROTOCOL.md §10` (work) and `§11` (private) are the two worked examples:
prefixed keys, a second parse pass, vectors in the same file.
