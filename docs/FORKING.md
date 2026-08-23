# Forking tgsocial

Fork it. Reskin it, rearrange it, strip it down, build it into something
else — that's the point of MIT and of a network with no server: the network
can't tell which client wrote a card, and nobody has to approve yours.

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

Everything else — look, ranking OFF is our choice not a law, screens,
platforms, extra features — is yours. `docs/card-vectors.json` is the
executable form of rules 1–2: wire your fork's parser tests to it and
you're compatible.

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
