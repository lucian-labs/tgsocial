# Known gaps

What tgsocial does not do yet. This is a roadmap, not a disclaimer — each item
is work that has to land before a public release, and the order is roughly the
order it will be built.

## Moderation and safety

The feed renders arbitrary public Telegram channels, and there is currently no
moderation layer of any kind. Before release it needs:

- **Report** on every post and comment, reaching a real inbox with a stated
  response time.
- **Block** a node, and **mute** a feed — durable, and applied everywhere a post
  can surface, including `/u/` pages and the +1 walk.
- **Filter** — hide blocked and reported content by default.
- **Contact** — a way to reach a human, visible in the app.

Because the network has no server (`PROTOCOL §1`), report and block need
somewhere to live that is not a Telegram channel. That design is not settled.

## Account deletion

Setup creates a public Telegram channel as your node, and a second one for
comments. Sign Out clears local state (`PROTOCOL §7`) but nothing deletes those
channels from inside the app. A delete path — with a clear warning that it
removes the public card others read — is required.

## iPad

The app builds universal but the layout is designed for phone. iPad is either a
deliberate layout or an explicit exclusion; today it is neither.

## Reader limits

The public reader (`PUBLIC.md §5`) shows recent history only, has no comments,
and depends on Telegram's preview markup, which is not a contract. Deep archives
need the app.

## Web client credentials

A browser TDLib client must ship `api_id`/`api_hash` to the page — this is
architectural, not a defect. Self-hosters should register their own at
my.telegram.org rather than reusing another deployment's (`web/README.md`).
