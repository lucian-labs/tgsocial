# Known gaps

What tgsocial does not do yet. This is a roadmap, not a disclaimer — each item
is work that has to land before a public release, and the order is roughly the
order it will be built. The last section is the exception: two store
declarations that were filed wrong and are now settled, kept here rather than
dropped because a declaration that was wrong once is worth being able to find.

## Moderation and safety

Specified, not yet built. `PRODUCT §2.15`–`§2.20` and `PROTOCOL §7.1` settle the
design; the three clients implement it:

- **Report** on every post and comment, opening an email to
  elijah@lucianlabs.ca with a 24-hour response commitment (`PRODUCT §2.15`).
- **Block** a node, **mute** a feed — durable local state applied everywhere a
  post can surface, `/u/` pages and the +1 walk included (`§2.16`, `§2.17`).
- **Filter** — always on, no switch (`§2.18`).
- **Contact** — the address in the You footer, on Sign in, and in Settings
  (`§2.19`).

The network has no server (`PROTOCOL §1`), so all of it is local state plus an
email the reader's own mail client sends. The lists are never published.

Until this ships, nothing the app displays is filtered, and the store listing
says so: the age rating in `docs/STORE_LISTING.md` follows from this section
being open.

## Account deletion

Specified in `PRODUCT §2.21` and `PROTOCOL §4.11`, not yet built: Settings →
`Delete My Node` deletes the node channel and the comments channel through
TDLib, behind a type-the-username confirm, and lands the app back at Setup,
signed in and nodeless.

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
