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
