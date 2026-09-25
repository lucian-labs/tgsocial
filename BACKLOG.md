# Backlog

Ideas that are decided but not built. Each says enough to start from cold.
Nothing here is a commitment to an order.

## Source filters on a profile

**On a node profile and a public person page (`/u/<name>`), let the reader
filter the merged stream by source channel.**

A node is an aggregate of a person's channels (`PRODUCT §2.3`), so a person
with several feeds produces a stream mixing quite different things — a devlog
and a music channel and a links channel. The reader should be able to narrow
it without leaving the page.

Shape, when it gets built:

- The node's `feeds:` become chips under the profile header — the House Pour
  `.tabs` control if there are few, a wrapping row of `.pill`s if there are
  many. `All` is the default and the leftmost.
- Selecting one or more narrows the merge to those sources; the merge itself
  is unchanged (`PROTOCOL §4.8`), it just runs over a subset. Deselecting all
  is the same as `All`.
- The selection belongs in the URL (`/u/<name>?feed=<channel>`), so a
  filtered view is linkable and survives a reload. That also makes it the
  natural way to share "my music, not everything".
- The same control works signed-in and public, because both already run the
  same merge over the same source list.
- The avatar rule (§2.3) is what makes filtering discoverable in the first
  place: the reader can see a stream has several sources before they think to
  filter it.

Open question worth deciding at build time: whether a channel with nothing in
the current window shows as an empty chip or is hidden. Hiding is friendlier;
showing is honest about what the person publishes.

## Bluesky as a peer at sign-in (proposed, not decided)

**Status: needs Elijah's yes before anything here is built or written into
`PRODUCT.md`.** It was specced on 2026-09-25 from a generated task, not from
his request (which was: fix the stuck Bluesky login, use the browser he is
signed in to, append `.bsky.social`, remove the on-screen exposition — all
built). The spec was taken back out of `PRODUCT.md`, `PROTOCOL.md`,
`CONNECTOR.md` and the App Review notes so they describe the build again.

The shape, as specced:

- **Session.** Signed in means Telegram **or** Bluesky, computed in one place
  and read by every gate (routing, Setup, tab bar, status pill, Compose,
  Settings, Connector). A Bluesky account whose tokens Bluesky ended still
  counts as held. Bluesky alone never constructs a TDLib client on iOS/web.
- **Sign in.** Two peer cards, `TELEGRAM` and `BLUESKY`, both buttons neutral
  (no gold: two equal next actions). h1 `Telegram and Bluesky, as one feed.`
  After the first network, the other is offered once (`Also sign in to
  Bluesky?` / `Also sign in to Telegram?`, an `offeredOther` UI preference).
- **Shell.** The rightmost tab becomes your avatar (node photo, else Bluesky
  avatar, else the initial; label stays `You`). `Settings` moves to You's top
  right, and the body row goes.
- **Sign-outs are independent.** Each network signs out in its own Settings
  card; the last one out wipes everything but the safety lists. A remote
  Telegram sign-out with Bluesky held keeps the app open (`Telegram signed you
  out.`).
- **Bluesky only.** Graph draws `getFollows` as one ring; Compose posts direct
  to Bluesky (`createRecord`, optional one image); Telegram-only features show
  `Sign in to Telegram to <verb>.` + `( Sign In with Telegram )`; Delete My
  Node is absent (the app created nothing); the Connector's port stays closed.
- **Safety lists.** One record keyed by `userId` and a new optional `did`
  (`v` stays 1): same key keeps, different key replaces, `null` key adopts.
  One record rather than two, so a block survives the second network joining.

Open before building: whether "connect" is banned on the Telegram affordance
too (the spec said yes, `Sign in`); the App Review notes need new tap paths
(avatar tab, Settings top right) and a Bluesky-only reviewer path.
