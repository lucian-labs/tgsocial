# Store listing copy

Same words on the App Store and Google Play. House Pour voice: short
declaratives, no exclamation marks, no emoji.

## Name

tgsocial

## Subtitle (App Store, 30 chars)

Your Telegram, as a feed.

## Short description (Play, 80 chars)

Follow people's Telegram channels in one chronological feed. No server, no account.

## Description

tgsocial turns the Telegram you already have into a social network.

Sign in with your Telegram account. Pick which of your public channels post
as you. Follow other people, and every post from every channel they list
lands in one column, newest first. No ranking, no recommendations — the feed
is the order things happened.

There is no tgsocial server. Your profile is a public Telegram channel; its
pinned message holds your name, your feeds, and who you follow. Anyone with
plain Telegram can open it and tap through the network by hand. tgsocial is
a lens on that, not a gatekeeper.

— One chronological feed from the nodes you follow
— Your channels become your feeds; verified with a line in the description
— Explore: the people your people follow, and a public directory
— Graph: your network at a glance
— Post to your own feeds from the app
— Look around before you sign in: a demo network that runs on your device
— Nothing stored anywhere but Telegram and your device

The feed is other people's public Telegram channels, unfiltered. tgsocial
shows what they post, in the order they posted it, and does not moderate it.
The age rating on this page follows from that.

tgsocial is open source (MIT) at github.com/lucian-labs/tgsocial. It is an
independent third-party client and is not affiliated with Telegram.

## Keywords (App Store, 100 chars)

telegram,feed,social,channels,chronological,decentralized,open source,follow,network,graph

## Category

Social Networking

## Age rating

**16+** on the App Store. **ESRB Mature**, 17 and up, on Google Play.

The two stores stopped naming the same tier in 2025. Apple retired 12+ and
17+; its tiers are now 4+, 9+, 13+, 16+ and 18+. Play still runs ESRB, where
the band that covers the same ground is Mature, 17 and up. That is why the
Description above says "the age rating on this page" and never a figure: the
copy is shared (`PRODUCT §3`), and any number written into it is wrong on one
of the two pages it appears on.

The app renders arbitrary public Telegram channels, chosen by the reader,
exactly as their owners posted them. Nothing is filtered on the way in and
there is no editorial layer, so the rating is set by what the app can put on
screen, not by what it ships with. A lower rating needs filtering to exist
first; it is not a wording problem.

Apple computes the tier from the questionnaire, so 16+ is an output. These
are the input, and they are the part to re-answer when the app changes.

Capabilities — no frequency on these; each sets a floor:

— User-Generated Content: yes — public Telegram channels (4+ and higher)
— Social Media: yes — redistribution of and interaction with user-generated
  content through feeds, which is the whole app: one chronological column of
  other people's channels, plus comments (`PRODUCT §2.3`, `§2.12`) (13+ and
  higher)
— Unrestricted Web Access: yes — links and link previews in posts open the
  system browser (`PRODUCT §4`), and the channels are the reader's own choice
  (16+ and higher)

Content descriptors — these are frequency-qualified:

— Mature or Suggestive Themes: frequent (16+; "infrequent" would be 9+).
  Unfiltered channels, so infrequent is not an answer we can stand behind.
— Violence, horror, chance-based activities, medical or wellness topics,
  drugs, alcohol, profanity: none. None of it ships in the app, and what a
  followed channel posts is carried by the capabilities above.

In-app controls: none. No parental gate, no content filter, no age
declaration. Report, block and mute (`PRODUCT §2.15`–`§2.17`) and the
always-on filter behind them (`§2.18`) are the reader's own tools rather than
controls someone else sets over their device, and a reader's own tools do not
lower a rating — a tier below 16+ needs the app to filter what arrives, which
it does not and does not claim to.

The explicit descriptors are answered none, Graphic Sexual Content and Nudity
included — Apple scores that one Unrated and does not publish it. The reading
that makes none the honest answer is that the app provides no content of its
own, and the possibility that a channel someone chose to follow does is what
the unmoderated-UGC capabilities above declare. That holds while the reader
picks every channel. If Apple reads it the other way, the answer is the
filter, not a different number.

16+ is the highest floor any of those answers produces, so 16+ is the
calculated rating and we take it as calculated. Apple lets a developer raise
a rating by hand; a number no answer supports is the same class of mistake as
a retired one, so we don't.

Google Play, IARC questionnaire: user-generated content, unmoderated, with
links out of the app — ESRB Mature, 17 and up. Same facts, different form,
different label.

## Privacy

Policy: https://github.com/lucian-labs/tgsocial/blob/main/docs/PRIVACY.md
Data collected: none. Data linked to you: none. Tracking: none.

App Store "App Privacy" answers: the app does not collect data. TDLib stores
session data on-device only.

## Review notes (App Store)

This is a third-party Telegram client built on TDLib, Telegram's official
client library, with our own registered api_id. Signing in needs a Telegram
account and an SMS/Telegram code, so **the app ships a demo and the demo is
the review path** — no credential is needed and none is supplied. It is a
visible button on the first screen rather than a hidden mode, because this
app is open source (MIT, github.com/lucian-labs/tgsocial) and anything a
reviewer could be told in private would be in the repository for everyone to
read. There is no hidden functionality in this build and nothing to declare
under Guideline 2.3.1.

The demo is specified in full in `PRODUCT §2.22`.

### What to tap

1. Launch. On the sign-in screen, below the phone field, tap
   **`Look Around First`**.
2. You land on the feed. Every screen from here carries a `Demo` pill in the
   top bar and the strip `Demo. Everyone here is invented. Nothing leaves this
   device.` The people, channels, posts, photos, audio and video are invented
   for this purpose; every node handle starts `tgs_demo_`, every channel handle
   starts `demo_`, and every image carries its own fixture key in its corner.
   No real person's content is in the build.
3. Tap the `Demo` pill for the demo sheet. The row `Telegram · Not connected`
   is literal: the demo makes no network request of any kind, on any of the
   three builds (`PRODUCT §2.22.4`, asserted by `web/test/smoke.mjs`).
4. Anything that would write to Telegram — post, comment, follow, edit — is
   present, tappable, and answers `The demo doesn't write to Telegram.`

### Guideline 1.2 — safety controls, exercised on the fixtures

All of it works in the demo, on the real code paths, and each step is
checkable by a number on screen:

- **Report.** Open the feed post from `Tidewright` that begins `New moon…`
  (about a day old). Its footer reads `5 comments`; tap it. Long-press (or
  right-click) the last comment, from `Crate Mailer` — the one offering free
  crates — and the comment sheet opens with a `SAFETY` block. Tap
  `Report Comment`, pick a reason, tap `Send Report`. The comment disappears
  at once and the footer reads `4 comments`. A mail composer opens prefilled
  to elijah@lucianlabs.ca; you do not need to send it — hiding does not wait
  on the mail (`PRODUCT §2.15`).
- **Block.** In the same sheet, `Block @tgs_demo_crate`, confirm. Their
  comment and everything else of theirs is gone: the Explore tab's `NEARBY`
  list loses their row, and the Graph tab reads `+1 · 6` where it read
  `+1 · 7`.
- **Mute.** Long-press any post from `Slow Radio` and tap
  `Mute Slow Radio`. The feed goes from 15 posts to 12. Open that channel from
  a node profile and it is still complete — mute is about the merged feed, not
  a takedown.
- **The filter is always on and has no switch** (`PRODUCT §2.18`). There is no
  preference to find, and blocked, muted or reported content never paints
  anywhere: feed, channel, threads, Explore, Graph, search.
- **Undo.** You tab → `Settings` shows `BLOCKED · 1`, `MUTED · 1`,
  `HIDDEN · 1`, each with a one-tap reverse. The hidden row names the channel
  and message id and the reason, never the content.
- **Contact.** elijah@lucianlabs.ca is on the sign-in screen, in the You
  footer and in Settings, with the 24-hour commitment. There is no server, so
  a report is an email the reader's own mail client sends plus an immediate
  local hide; `PRODUCT §2.19` says so in the app rather than implying a
  takedown we cannot perform.

### Guideline 5.1.1(v) — account deletion

Also reachable without an account, which is why the demo is visible rather
than hidden: You → `Settings` → `Delete My Node`. The modal names both public
channels the app created (`@tgs_demo_you` and its comments channel
`@tgs_demo_you_r`), explains that the public card and every post in them
disappear and the names are released, and requires the node name typed exactly
before the button enables. Confirming runs the real flow — comments channel
first, node second (`PROTOCOL §4.11`) — and, because a demo has no session to
survive, ends the demo and returns to sign in.

In a real session the same control is in the same place and deletes the same
two channels through TDLib; feed channels the person already owned are not
touched, and the app lands back on Setup, still signed in.

### Nothing else changes

The app creates a public channel ("node") on first run with the user's
consent (Setup screen, `Create Node`); everything else reads public channels.
The 16+ rating is because the reader picks the public channels and we render
them unchanged: we do not select, rank or filter what those channels post, and
we do not claim to. The questionnaire answers behind the 16+ are in the Age
rating section above; Unrestricted Web Access is the one that sets the floor.

Export compliance: the app declares `ITSAppUsesNonExemptEncryption` true.
TDLib, Telegram's official client library, implements MTProto inside the
binary, which is outside the exemption for OS-provided cryptography. The
reasoning is in docs/EXPORT.md.

## Screenshots

Six per platform, in this order, at the device's native size, no device
frames, ivory background:

1. Feed — three post cards, one with a photo
2. Explore — Nearby with "Followed by 3 of yours"
3. Node profile — feeds list with a Verified pill
4. Graph — the radial network
5. Setup — Make your node
6. Compose — Post to

Captions (serif, ink, top-aligned): `Newest first.` · `The people your
people follow.` · `Your channels, as you.` · `Your network.` · `One public
channel. That's your profile.` · `Say it.`
