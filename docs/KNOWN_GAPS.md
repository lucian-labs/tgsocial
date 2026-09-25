# Known gaps

What tgsocial does not do yet. This is a roadmap, not a disclaimer — each item
is work that has to land before a public release, and the order is roughly the
order it will be built. The last two sections are the exception: things that
were open and are now settled, kept rather than dropped because a gap that was
real once is worth being able to find.

## Moderation and safety — shipped

Built on all three clients. `PRODUCT §2.15`–`§2.20` and `PROTOCOL §7.1` are the
design; this is what the reader has:

- **Report** on every post and comment, opening an email to
  elijah@lucianlabs.ca with a 24-hour response commitment (`PRODUCT §2.15`).
- **Block** a node, **mute** a feed — durable local state applied everywhere a
  post can surface, `/u/` pages and the +1 walk included (`§2.16`, `§2.17`).
- **Filter** — always on, no switch (`§2.18`).
- **Contact** — the address in the You footer, on Sign in, and in Settings
  (`§2.19`).

The network has no server (`PROTOCOL §1`), so all of it is local state plus an
email the reader's own mail client sends. The lists are never published.

What this does **not** do is filter what arrives. Nothing is screened on the way
in, and there is no editorial layer — these are the reader's own tools, applied
after the fact, to a feed of channels they chose. That distinction is what the
age rating in `docs/STORE_LISTING.md` turns on, and a tier below 16+ would need
the first kind of filtering to exist, which is not planned.

## Account deletion — shipped

Settings → `Delete My Node` deletes the comments channel and then the node
channel through TDLib, behind a type-the-username confirm, and lands the app
back at Setup, signed in and nodeless (`PRODUCT §2.21`, `PROTOCOL §4.11`). The
comments channel goes first on purpose: the other order can strand a public
comments channel backlinking to a node that no longer exists.

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

## Bluesky (PROTOCOL §12) — specified, not built

`PROTOCOL §12` and `PRODUCT §2.35`–`§2.40` are written; the clients are not.
What exists is the wire half, in the web client only: `web/js/protocol.js` has
the card key, the link check, the merge rules, the tag admission, the safety
keys and the client-metadata checker, and `web/test/protocol.test.mjs` runs
every `atproto` vector against them. iOS and Android parse the same file and
ignore the block. Still to land, roughly in this order:

- **Place the native client metadata** at
  `https://lucianlabs.ca/tgsocial/client-metadata.json` (`docs/HOSTING.md §7`).
  On 2026-09-25 that path answered `200 text/html`, so native sign-in fails at
  its first request until the file is there.
- **One real login.** No session has completed end to end: granular scopes,
  token lifetimes and refresh rotation are from the spec and the servers' error
  messages (`PROTOCOL §12.7`).
- **Reads on all three clients** — the link check, author sources, the tag
  source — which need no sign-in and are most of the value.
- **The OAuth flow** per platform (`PROTOCOL §12.7`: PAR, PKCE, DPoP, per-server
  nonces), then linking, the follows source and cross-posting.
- **The AppView's limits** for unauthenticated reads, measured before the
  author-source fan-out ships (`PROTOCOL §12.4`).

## Settled — the two store declarations

Neither of these is open any more.

- **Age rating.** The listing declared 12+ for a feed of arbitrary unfiltered
  public Telegram channels, which it is not. Then it declared 17+, which Apple
  retired along with 12+ in 2025 — its tiers are 4+, 9+, 13+, 16+ and 18+. It
  reads 16+ (App Store) / ESRB Mature, 17 and up (Play) now, with the
  questionnaire answers that carry it in `docs/STORE_LISTING.md`. The two
  stores no longer share a tier name, so no store-facing sentence names a
  number; the shared Description points at the rating on the page instead. The
  rating tracks what the app can put on screen, so lowering it means building
  the filtering above, not rewording anything.
- **Export compliance.** `ios/project.yml` declared
  `ITSAppUsesNonExemptEncryption: false` while TDLib compiles MTProto into the
  binary — outside the exemption, which is aimed at apps whose only
  cryptography is the OS's. It is `true`, and `docs/EXPORT.md` records the
  reasoning, the two compliance paths, and what the annual self-classification
  report involves. The first version of that file leaned on TDLib's "encrypted
  local database" as a second reason; all three clients pass an empty database
  key, so there is no such encryption, and the declaration rests on MTProto
  alone.
