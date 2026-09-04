# tgsocial — product spec

One app, three builds (iOS, Android, web). Same screens, same copy, same look.
This file is the shared contract for screens, flows, and words. The wire
contract is `PROTOCOL.md`. The look is `design/` (House Pour).

## 0. Naming

- Product: **tgsocial** — always lowercase, one word, set in the brand face
  (Kaushan Script) wherever it appears as a wordmark. In running text it is
  `tgsocial` in the body face.
- Bundle / package id: `ca.lucianlabs.tgsocial`.
- Web: no canonical host. The client in [`web/`](./web/) is self-hosted, so a
  deployment's origin is whatever its operator owns ([`PUBLIC.md`](./PUBLIC.md)).
  Nothing in the product names one.
- Repo: `github.com/lucian-labs/tgsocial` (MIT).

## 1. Shell

Every screen sits in a single 540px-max column (web) / full width with 14pt
side padding (native). The shell is:

```
┌──────────────────────────────────────────┐
│ tgsocial                       [Synced]  │  topbar: wordmark left, status pill right (tap → Status sheet)
├──────────────────────────────────────────┤
│                                          │
│  cards …                                 │
│                                          │
│                                          │
│      ╭──────────────────────────╮        │  floating tab bar, bottom, House Pour `.tabs` pill:
│      │ Feed  Explore  Graph  You │        │  panel fill, 1pt line, pill radius, one card shadow,
│      ╰──────────────────────────╯        │  16pt above the home indicator / viewport bottom
└──────────────────────────────────────────┘
```

- The topbar is sticky and translucent (House Pour `.topbar`). The status pill
  reads `Synced`, `Syncing`, `Offline`, or `Signed out`; gold only when
  `Synced`. **The pill is a button**: tapping it opens the Status sheet (§2.10).
- The **tab bar floats at the bottom**: the House Pour `.tabs` segmented
  control (same component, same four items `Feed · Explore · Graph · You`)
  placed `position: fixed` / overlay at the bottom of the column, centred,
  hugging its content (not full width), `cardGap` (16pt) above the safe-area
  bottom, with `panel` fill and the single card shadow so it reads as a raised
  pill over scrolling content. Content scrolls under it; every scroll view
  pads its bottom by the bar height + `cardGap` so the last card clears it.
  It is hidden on Sign in, Setup, and inside full-screen viewers; it stays
  on pushed screens (profile, feed channel). No native tab bar.
- No native navigation bars with system titles, no system segmented controls.
  Pushes (profile, feed detail, compose) open as full screens with a
  `‹ Back` ghost button top-left in the same topbar slot where the wordmark
  was; the status pill stays.
- Sheets (compose, confirm, status) are House Pour modals: a card over a
  `rgba(38,35,25,0.4)` scrim. Never a dark sheet.
- Toasts are the one dark surface. They fade; they do not slide. Full-screen
  media viewers (§2.11) are the one other dark surface — `ink` at 96% — because
  photos and video need it.

## 2. Screens

### 2.1 Sign in

Shown whenever TDLib is not `authorizationStateReady`.

```
tgsocial                                   (wordmark, 3rem)
Your Telegram, as a feed.                  (h1)
Sign in with the Telegram account you       (muted)
already have. Nothing is stored anywhere
but Telegram and this device.

PHONE NUMBER                                (field label)
[ +1 604 555 0199            ]              (input, tel)
( Send Code )                               (btn primary)
```

Arrived on a public link (§2.13), the muted line names the destination
instead: `Sign in to see @<name>.` Everything else is unchanged.

Step 2 replaces the field with `CODE` + input (numeric, 5 digits) and the
button reads `Sign In`. A ghost button `Use another number` goes back.

Step 3 (2FA) shows `PASSWORD` + secure input, hint text from TDLib's
`passwordHint` in muted if present, button `Unlock`.

Every step's footer carries one muted line, `elijah@lucianlabs.ca` (§2.19) —
this is the only screen a signed-out reader sees, and the address has to be
reachable from it.

Errors (toast, `.bad`): `That code didn't match.` · `That password didn't
match.` · `Telegram didn't accept that number.` · `Too many tries. Wait a
moment.` (FLOOD_WAIT — show the seconds if TDLib gives them). Other TDLib
errors surface their message text verbatim.

### 2.2 Setup

Shown after sign-in when no node is found (`PROTOCOL §4.2`).

Card 1 — **Your node**
```
YOUR NODE                                   (section mark)
Make your node.                             (h2)
A public channel that holds your feeds and   (muted)
who you follow. It lives on Telegram, and
anyone can read it there.

NODE NAME
[ tgs_elijah                ]               (input; live availability check → pill `Available` / `Taken`)
( Create Node )                             (btn primary)
( I already have one )                      (btn ghost → re-runs §4.2, toast `No node found.` if none)
```

Card 2 — **Your feeds** (appears once the node exists)
```
YOUR FEEDS
Pick the channels that post as you.          (muted)
┌ list-item ─────────────────────────────┐
│ WaveLoop devlog       @waveloop_devlog │ [toggle]
│ Très Buchet           @tresbuchet      │ [toggle]
│ Notes to self         Needs a public link │ (disabled, faint)
└────────────────────────────────────────┘
( Save Feeds )                              (btn primary)
```

Toggling on asks once per feed, inline below the row, in muted text with two
small buttons: `Add a line to this channel's description so readers can
verify it's yours?` — `( Verify )` `( Skip )`. Verify appends
`tgsocial: @<node>` to the description (`PROTOCOL §3`).

Setup is skippable; `Skip for now` (ghost) goes to Feed with an empty-state
card that links back here.

### 2.3 Feed

The main feed (`PROTOCOL §4.8`). A vertical list of **post cards**:

```
┌ card ──────────────────────────────────────┐
│ (avatar) Ana Iliovic        2h ago · Share │  avatar + name = the PERSON (see Attribution);
│          WaveLoop devlog                   │  subheading = the channel/room, mono muted
│                                            │
│ Post text with *bold* and links…           │  body 1rem/1.5
│ [ media, 12pt radius, full width ]         │  photo / video (inline player) / GIF (autoplay, muted, looped)
│ [ ▶ 0:00 ───────── 3:42  Track title ]     │  audio + voice: inline House Pour player row (§2.11)
│ [ ▤ file name · 2.4 MB          Open ]     │  document row; Open → in-app viewer when viewable
│                                            │
│ 14 reactions · 3 comments      ( Comment ) │  footer: mono faint counts left, ghost sm right
└────────────────────────────────────────────┘
```

**Attribution — the person leads, the channel follows.** The header avatar
and name are the **node** (the person) the post reaches you through, not the
channel:

- If the source feed is one of my feeds → me.
- Else the node I follow whose card lists the source feed (when several
  list it, the earliest in my `follows:` order).
- Else (feed channel screen for an unattributed channel, +1 previews) fall
  back to the channel itself: channel photo + title, no subheading.

Name is the node card's `name` (falls back to `@username`), body 600, tap →
node profile. The subheading is the channel: its title in mono small muted,
tap → feed channel screen (2.6).

**The avatar is the source channel, 36pt.** A node is an *aggregate* — a
person's channels merged into one stream — so the avatar's job on a post is
to say *which channel this came from*. It is the only thing distinguishing
two posts by the same person from different feeds, and on a person page that
is the distinction that matters. The name beside it stays the person.

Fallback chain, since any of these can be missing:

1. the **source channel's** photo;
2. else the node's own photo;
3. else the initial, in the display serif.

Telegram serves a **generated letter avatar** for a channel with no photo — a
`data:image/svg+xml` image on a `bgcolorN` element. That is not a photo:
treat it as absent and fall through, or every unphotographed channel renders
Telegram's letter instead of ours. (Public pages read this from the preview;
the app reads `chat.photo`, which is simply null in that case.)

On a single-channel screen (§2.6) every post carries the same avatar, which
is redundant but correct — the rule is one rule everywhere, not a special
case per screen.

**Header metrics.** The header is one row: avatar, then the name/channel
stack, then the time and Share. The stack is **tight** — name at the body
line height, channel directly under it at the mono-small line height, no
extra leading between them — and the avatar is centred against that stack,
not pinned above it. The whole header measures about one avatar tall; a
header appreciably taller than its own avatar means something in it has been
inflated.

The 40pt hit target (`COMPONENTS.md` rule 6) is **an overlay, not a box**:
extend the tappable area beyond the element's painted bounds, and never by
growing the line box a text element occupies. Padding a 13pt subheading to
40pt tall and pulling it back with a negative margin does satisfy the rule
and does wreck the rhythm — it leaves a 47pt box around 19pt of text.

**The card owes the header a band.** An overlay only counts for what actually
reaches it, and the channel's hangs *below* its own line box — 40pt of target
over a 19pt line means 21pt of it lives under the header, and over the ~14pt
line SwiftUI paints, 26pt does. The first tappable thing beneath the header
therefore starts a full band down, not at the usual row gap: whatever is
placed later wins every point the two share, so a body text pushed up against
the header takes the bottom half of the channel's target and a mis-tap opens
the thread. Padding is not enough on its own — padding *inside* the body's own
tappable shape is still tappable, and takes the band just the same. Measure
the header's controls on the **assembled card**, not on the header alone — the
header alone always passes.

**Time is relative.** `now` (<60 s), `5m ago`, `2h ago`, `3d ago`, `2w ago`
(<8 w), `4mo ago` (<12 mo), `2y ago` — mono faint, top right. Derive, never
hand-format; largest unit only, floor rounding. The exact timestamp lives in
the long-press sheet.

**Share** — ghost small button right of the time. Native: the system share
sheet with the post's `t.me` link. Web: `navigator.share` when available,
else copy the link + toast `Link copied.`

- **Order is strictly newest first** (reverse chronological): the most recent
  post is at the top, "Load more" appends older posts at the bottom. New posts
  arriving live are inserted at the top. Never oldest-first, on any screen
  that lists posts (Feed, Feed channel). A feed cached by an older build MUST
  NOT paint in old order: the feed cache carries a schema version, a version
  mismatch discards it, and cached pages are re-sorted defensively on load.
- Tapping the name opens the node profile; tapping the channel subheading
  opens the feed channel screen (2.6). Tapping the text or the comments
  count opens the **Thread screen** (§2.12). Tapping media opens it **in the
  app** (§2.11).
- **Long-press a post** (web: long-press or right-click) opens the **post
  sheet** — a House Pour modal:

```
POST                                         (section mark)
Posted        2026-08-23 14:02               (list rows; values mono)
Views         1.2k
Feed          WaveLoop devlog · @waveloop_devlog
( Open in Telegram )                         (btn neutral)

SAFETY                                       (section mark)
( Report Post )                              (btn danger sm)
( Block @tgs_ana )                           (btn ghost sm)
( Mute WaveLoop devlog )                     (btn ghost sm)

( Close )                                    (btn ghost)
```

  `Open in Telegram` lives here now — nowhere else on the card. Views moved
  here from the footer. The `SAFETY` block is §2.15–§2.17; `Block` names the
  attributed node and is absent when the post has none, `Mute` names the
  source channel.
- Footer counts: `N reactions · N comments` (reactions render as the
  reaction emoji + count when few, summed count otherwise; comments count
  per §2.12, tappable). Views are not in the footer.
- Pull-to-refresh (native) / `Refresh` ghost button under the tabs (web).
- Infinite scroll: load more when the last card is within two screens of the
  bottom. A muted `Loading…` row at the end; `That's everything.` when all
  sources are exhausted.
- Empty: one card — h2 `Nothing here yet.` muted `Follow a node and their
  feeds show up here, newest first.` `( Explore )` btn accent.
- Own posts appear in the feed like any other, attributed to me.

### 2.4 Explore

```
[ Find a node                 ]  (input; on submit → open profile for @username or toast `Not a tgsocial node.`)

NEARBY                                      (section mark)
nodes at distance 2, ranked by mutual count; each row:
(avatar) Ana Iliovic            ( Follow )
         @tgs_ana · 2 feeds · Followed by 3 of yours

DIRECTORY
union of prefix search + index group, minus nodes already shown, minus
nodes I follow, minus me; same row without the "Followed by" line.
```

Rows are `.list-item`s inside one card per section. `Follow` is a `.btn sm`
(neutral — not gold: the view has many of them). After following it reads
`Following` and is ghost. Tapping the row opens the profile.

Empty states: `Follow someone and their people appear here.` (Nearby) ·
`No nodes found. Be the first: make yours public.` (Directory).

### 2.5 Node profile

```
‹ Back                                          [Synced]

(avatar 72pt)
Ana Iliovic                                  (h1)
@tgs_ana                                     (mono muted)
Voice, product, Vancouver.                   (muted)
anailiovic.com                               (link)

( Follow )                                   (btn primary when not following; `Unfollow` btn ghost when following)

The top-right corner carries the same kebab menu as the feed channel header
(§2.6): `Open in Telegram`, `Copy Link`, `Block @tgs_ana` (§2.16). A blocked
node's profile is the blocked card in §2.16 instead of all of this.

FEEDS
┌ card ─────────────────────────────────┐
│ Ana's notes          @ana_notes   Verified │  → feed screen
│ VII devlog           @thevii_dev          │
└───────────────────────────────────────┘

FOLLOWS · 12                                 (section mark with count in the serif)
┌ card ─────────────────────────────────┐
│ (avatar) Bob          @tgs_bob     ›   │  → profile
│ …                                      │
└───────────────────────────────────────┘
```

My own profile (reached from You → `View as others see it`) is the same
screen with no Follow button.

### 2.6 Feed channel

```
‹ Back                                          [Synced]

(avatar 72pt)                        [Verified]  ⋮      ← pill top right, then the menu
WaveLoop devlog                                  (h2)
@waveloop_devlog                                 (mono muted)
Notes from the bench.                            (muted)
─────────────────────────────────────────────
posts, newest first (§2.3 post cards)
```

Header layout: the avatar and title block sit left; the top-right corner
carries the `Verified` gold pill (present only when backlinked, `PROTOCOL
§3`) and, to its right, a **kebab menu** — a vertical three-dot button,
40pt target, ghost styling, `faint` dots.

Tapping it opens a House Pour menu: a `panel` card with the card radius, one
shadow, anchored under the button (a modal sheet on small screens), holding
one `HPListItem` per action, body text, ink, 40pt rows:

- `Open in Telegram`
- `Copy Link` (public routes and signed-in alike — copies the channel's share
  URL: `t.me/<channel>` unless the build has a public origin configured
  (§2.13), toast `Link copied.`)
- `Mute Feed` — reads `Unmute Feed` when the feed is already muted (§2.17)

`Open in Telegram` appears nowhere else in this header. Dismiss by tapping
outside or pressing Escape (web) / swiping down (native sheet).

Then that channel's posts chronologically (newest first) using the same
post card as §2.3.

### 2.7 Graph

```
YOUR NETWORK
┌ card ─────────────────────────────────┐
│                                        │
│        ·     ·                         │  canvas: you = gold dot 10pt at centre,
│    ·    ●━━━●    ·                     │  follows = ink dots 8pt ring 1, +1 = faint dots 6pt ring 2,
│        ·   ·   ·                       │  edges = 1px --line; tap a dot → profile; drag to pan
│                                        │  (no physics; fixed radial layout, angles evenly spaced)
└────────────────────────────────────────┘
DIRECT · 12
list of follows (same row as Explore)
+1 · 84
list of distance-2 nodes ranked by mutual count
```

The figure in the section marks (`12`, `84`) is set in the serif — the one
place numerals appear on this screen.

### 2.8 You

```
(avatar 72pt)   Elijah Lucian                 (h2)
                @tgs_elijah                   (mono muted)   ( Edit Card ) btn sm

YOUR FEEDS                     ( Manage ) btn sm
┌ card: list of my feeds; each row → Compose for that feed ┐

( Compose )                                   btn primary — the one gold action on this screen

LISTING
Public listing          [ pill: Listed / Unlisted ]  (toggle writes `public:`)
( Announce in Directory )  btn sm — posts to @tgsocial_index; disabled when unlisted

( View as others see it )   ghost
( Settings )                ghost — pushes §2.20, which now holds Sign Out

Questions or reports: elijah@lucianlabs.ca           muted, → mail composer
Reports are read by a person within 24 hours.        faint
tgsocial 1.0 (12) · TDLib 1.8.x · node @tgs_elijah   mono faint
```

`Sign Out` is no longer on this screen: it lives in Settings with
`Delete My Node` (§2.20, §2.21), so the two destructive actions sit together
and neither is a mis-tap away from `View as others see it`. The contact line
is §2.19 and is present whether or not a node exists.

**Edit Card** modal: `NAME` input, `BIO` input, `LINK` input, `( Save )`.
**Manage feeds**: the Setup feeds card.

### 2.9 Compose

Modal card:
```
POST TO
[ WaveLoop devlog ] [ Très Buchet ]          (.tabs; preselected when opened from a feed row)
[ textarea, 6 rows, placeholder "Say it." ]
( Post )      ( Cancel )                     btn-row: primary + ghost
```
Photo attach is a `( Add Photo )` ghost sm above the row on native; web v1
is text only. Success toast `Posted.`; the feed refreshes.

### 2.10 Status sheet

Opened by tapping the status pill. A House Pour modal card:

```
STATUS                                       (section mark)
Connection        Connected                  (list-item rows; value in mono)
Telegram          Signed in · +1 604 ••• 0199
Node              @tgs_elijah · card 2 min ago
Feed              12 sources · 340 posts · refreshed 14:02
Pending           Reading 3 cards…            (what is in flight right now, or `Nothing`)
Last error        FLOOD_WAIT 23 s at 13:58    (or `None`)
TDLib             1.8.66
( Refresh Now )                              (btn accent)
( Close )                                    (btn ghost)
```

- `Connection` mirrors TDLib `updateConnectionState`: `Connected`,
  `Connecting`, `Updating`, `Waiting for network`, `Connecting to proxy`.
- `Pending` is a live list of the operations the app is running
  (`Reading card @tgs_ana`, `Loading @waveloop_devlog`, `Downloading photo`,
  `Writing your card`); the pill says `Syncing` exactly while this list is
  non-empty, `Synced` when it is empty and the connection is `Connected`,
  `Offline` when TDLib reports waiting for network. A `Syncing` pill that
  never resolves is a bug: every in-flight operation must remove itself on
  success, failure, or timeout (30 s).
- The sheet updates live while open. `Refresh Now` re-runs the feed refresh
  and re-reads my card.

### 2.11 Media viewers and players

Everything a post can carry opens or plays **inside the app**. Nothing hands
off to Telegram or the browser except the explicit `Open in Telegram` button.

| Content | Inline in the post card | On tap |
| --- | --- | --- |
| Photo | `HPMedia` at the post width, minithumbnail blur until loaded | Full-screen viewer: ink 96% background, pinch-zoom + double-tap zoom, swipe down or `Close` to dismiss, `Save` (native) / `Download` (web) ghost buttons, caption below in `charcoalText` |
| Video | Poster (thumbnail) with a centred play glyph and duration pill; tap plays inline, muted off, with a minimal House Pour scrubber | Full-screen player (same viewer chrome), native playback (`AVPlayer` / `ExoPlayer`-free `VideoView`/`MediaPlayer` / `<video>`), landscape allowed |
| Animation (GIF / mp4 loop) | Autoplays muted and looped inline once downloaded | Full-screen viewer, loop continues |
| Audio (`messageAudio`) | **Player row** with the spectrogram strip (§2.11.1): play/pause circle 40pt, title + performer, serif elapsed / total, and the strip as the scrubber | Same row; no full-screen |
| Voice / video note | Same player row with a waveform drawn from TDLib's waveform bytes (ink bars, gold played) | Video notes: circular inline player |
| Document | Row: file glyph, name in body, size + type in mono | PDF, images, text, audio/video documents open in the in-app viewer; other types download then offer `Share` (native) / `Download` (web) |
| Sticker | Rendered static (webp/png); animated stickers show their thumbnail | — |
| Link preview | `linkPreview` title/description/thumbnail as a bordered row | Opens the link in the system browser (links are the one exception) |
| Poll, location, contact, other | A muted one-line summary (`Poll · 3 options`, `Location`) | `Open in Telegram` |

#### 2.11.1 The spectrogram strip

The audio scrubber is not a hairline — it is a **spectrogram of the clip**
with its amplitude envelope drawn over it. Same instrument as Wake's
waterfall, in House Pour's palette, and sized to a player row.

**What it shows.** The whole clip, left to right, so the strip is also the
scrubber: you can see where the loud part is before you drag to it.

- **Spectrum.** A short-time FFT across the clip. Frequency runs bottom
  (low) to top (high) on a **log** axis, because that is how pitch is
  spaced; magnitude in dB, not linear. The axis runs from 20 Hz to the
  **analysis Nyquist**, ceilinged at 20 kHz — the strip is analysed
  decimated (below), so in practice its top is 8 kHz for a clip under five
  minutes and slides to 4 kHz at the ten-minute cap. It follows the rate
  rather than reserving rows for a band the decimation discarded before the
  FFT saw it: a literal 20 kHz top leaves 13% of a 44pt strip permanently
  dark at a 16 kHz analysis and 23% at 8 kHz, and moves the height of that
  dead band around with the clip's *length*, which is the one thing a fixed
  axis was meant to prevent. Painting rows for frequencies the decode threw
  away is drawing a floor and calling it silence. Column count follows the
  strip's pixel width — one column per pixel, no more; row count follows its
  height. Normalise with a rolling peak (an AGC) rather than absolute dBFS,
  so a quiet recording still fills the strip instead of reading as silence.
- **The envelope, overlaid.** A **one-pole** follower over the sample
  magnitudes — fast attack, slow release, `y += (x > y ? attack : release) *
  (x - y)` — drawn as a connected line through the column peaks, mirrored
  about the strip's centre. One pole, not a peak-per-bin bar chart: the point
  is a smooth silhouette that reads as the shape of the take.
- **Played vs unplayed.** The played portion carries `accent`; ahead of the
  playhead the strip is `ink` at reduced opacity. The playhead is a 1pt
  `accent` rule.

**Colour.** A House Pour ramp, not a rainbow: transparent → `line2` →
`muted` → `accent`, with the top of the range at `accent-2`. It is a
`--ramp-*` token set so the ramp is one edit, and it is the only place in
the look where a gradient carries data rather than decoration. The strip
sits on `bg2` at `radius-media`; it is a data surface inside the card, not a
second dark surface.

**Cost is bounded, and it degrades rather than blocking.** Analysis is
off the main thread, at a decimated sample rate (8–16 kHz is plenty for a
strip this size — 16 kHz up to about five minutes, sliding to 8 kHz at the
cap so the decoded buffer stays bounded), and capped: past a duration
ceiling (about 10 minutes) or
on any decode failure, fall back to the amplitude-only silhouette — for a
voice note that is Telegram's own waveform bytes, which need no decode at
all and should be drawn immediately while the spectrum computes behind it.
Past the ceiling the silhouette is still *decoded*, far coarser (a follower
over sample magnitudes needs no frequency resolution), so a 12-minute set
gets a silhouette rather than a hairline; past a second, much higher ceiling
(an hour) there is no strip at all, because even that pass has to read the
whole file to draw a few hundred numbers. The row is usable the moment it
appears; the spectrum fills in.

**Interaction.** Tap or drag anywhere on the strip to seek. The strip keeps
the 40pt hit region of any control (`COMPONENTS.md` rule 6), taller than its
painted height if need be. Analysis never runs for a row that has not been
played or scrolled into view.

Voice notes and video notes use the same strip — a video note keeps its
circular player and gets the strip as the transport underneath it. Video
*messages* keep their poster and hairline scrubber; this replaces the audio
scrubber only.

*Port state:* all three builds clamp the axis to the analysis Nyquist as
above, all three give a video note the strip as its transport, and all three
**cover** the clip rather than sampling it — every sample of the file is
inside at least one window. They reach that from opposite ends, because their
STFTs are laid out differently: web lays frames over the whole clip and grows
the window when its frame budget runs out (`framePlan`), iOS lays them per
column and takes more than one window in a column wider than a window
(`SpectrogramBuilder.frames`). The silhouette band runs to the hour above on
every build; on web an engine that refuses to decode below 8 kHz shortens it,
which is a platform floor rather than a product decision.

#### 2.11.2 The mini waveform

The dock is not the place for a spectrogram. It carries a **single-line
waveform**: one polyline through the envelope's column peaks — a line
drawing, not the mirrored filled silhouette of the strip and not the
spectrum. Hairline weight, `muted` ahead of the playhead and `accent`
behind it, no fill under the curve.

It is a **view of the analysis the strip already did** — the same envelope
array, resampled to the dock's width. Playing a clip must never trigger a
second analysis, and a clip whose strip degraded to the hairline shows a
flat line rather than nothing.

Tapping it seeks, like the strip. It keeps a 40pt hit region even though it
paints thinner.

#### 2.11.3 Photos: mosaic, then carousel

A post with more than one photo is a **mosaic**, not a stack — an album is
one thing, and reading it as one block is the point.

| Photos | Layout |
| --- | --- |
| 2 | Two tiles side by side, equal width |
| 3 | One tall tile leading, two stacked beside it |
| 4 | Two by two |
| 5+ | Two by two of the first four; the fourth carries a `+N` count in the `pill` style over a scrim |

The mosaic is **responsive and aspect-aware**: tiles fill their cell
(`cover`), the block keeps a sane overall ratio rather than letting one tall
photo set the height, and it reflows at the narrow end rather than
overflowing. `radius-media` on the outer corners only, so the mosaic reads
as one object with hairline `line` gutters between tiles.

Tapping any tile opens the **carousel** at that tile: the §2.11 full-screen
viewer, paging between the album's items, with the same zoom, save and
dismiss. The mosaic is the summary; the carousel is the reading.

Player rules (all platforms):

- One audio item plays at a time; starting another pauses the first. Playback
  continues while scrolling and across tabs; a slim **now-playing row** docks
  above the floating tab bar while audio plays: play/pause, title, elapsed,
  and a **mini waveform** (§2.11.2). Tapping the row anywhere but its
  controls opens the post the audio came from.
- Videos pause when scrolled off-screen and when another video starts.
- Progress and time use the serif for the numerals; the scrubber is a
  hairline (1pt `line2`) with a gold played segment and a 12pt `panel` knob
  with the contact shadow. No system transport controls visible.
- Downloads show a determinate hairline ring/bar (gold) over the placeholder;
  tapping cancels. Media files are fetched with `downloadFile` priority 1 when
  visible, 32 when tapped; the viewer streams video as soon as the
  downloaded prefix allows (native: local file URL; web: `readFilePart`
  blobs / `MediaSource` when supported, otherwise wait for full download
  with the ring).
- The full-screen viewer hides the topbar and the floating tab bar, supports
  swipe between the media items of one post (albums), and restores scroll
  position on dismiss.

### 2.12 Comments and threads

Comments follow `PROTOCOL §6`: a comment lives in the commenter's own public
**comments channel** and points at its target with a `re:` link, so what you
see on a post is "comments from your network" — the honest, serverless
number. The count in the post footer is that number.

**Thread screen** (push, `‹ Back`): the post rendered at the top (full post
card, media playable), then:

```
COMMENTS · 3                                  (section mark, serif count)
┌ card ─────────────────────────────────────┐
│ (avatar) Ana Iliovic          14:07        │  same header row as a post card
│ Nice one. The bass is huge.                │  body; media renders like a post
│ 1 reply · Reply                            │  mono faint · ghost sm
│   └ (avatar) Bob              14:20        │  replies indent one level (12pt),
│     Agreed.                                │  hairline gutter in `line`; depth
│     Reply                                  │  capped at 5, deeper shows flat
└───────────────────────────────────────────┘
No comments from your network yet.            (empty, muted, full stop)
( Comment )                                   (btn primary — the screen's one gold action)
```

**Comments in the carousel.** The viewer carries a `Comments` control. Opening
it does not leave the media: the media **shrinks to a mini view** pinned at the
top — the current item, still tappable to restore it full-screen — and the
thread takes the rest of the sheet. Paging the carousel while comments are open
moves the mini view and re-targets the thread to that item's post.

Tapping any comment in the thread **selects it as the reply target**: it lifts
into a quoted line above the composer and the composer's placeholder becomes
`Reply to <name>.` Tapping it again, or the quote's `×`, clears the target and
the reply goes to the post instead. This is the `re:` chain of `PROTOCOL §6.2`
made direct — the target is whatever you tapped.

The same selection behaviour applies on the Thread screen; the carousel just
hosts it over the media.

**Comment composer** (modal, same card as Compose): a muted quote line of
the target ("re: WaveLoop devlog — 'Post text…'"), textarea placeholder
`Say it.`, `( Add Photo )` ghost sm, `( Post )` primary + `( Cancel )` ghost.

First comment ever: the modal first shows one extra card —
`YOUR COMMENTS CHANNEL` section mark, muted `Your comments live in a public
channel you own. Anyone can read it on Telegram; you can edit or delete
anything there.`, input prefilled `<node>_r` with the availability pill,
`( Make Channel )` primary. On success the composer proceeds. The channel is
added to the card's `replies:` (`PROTOCOL §6.4`).

Behaviour:

- Comment sending is optimistic: the comment appears in the thread
  immediately with a faint `Posting…` mono tag, then settles or rolls back
  with a toast.
- `Reply` on a comment opens the composer targeting that comment's `t.me`
  link; the thread renders `re:` chains as the indented tree.
- The thread refreshes its comment index for the visible target when opened
  (`PROTOCOL §6.3`); pull-to-refresh re-scans.
- Deleting your comment: swipe / long-press → `Delete` (danger confirm
  modal `Delete this comment?`) — deletes the message in your channel.
- A commenter row's avatar/name opens their node profile. Comments from
  nodes you don't follow (found via +1) show a small `+1` neutral pill.
- **Long-press a comment** (web: long-press or right-click) opens the
  **comment sheet** — the post sheet's twin (§2.3), with `Posted`, the
  comments channel in `Feed`, `Open in Telegram`, and the same `SAFETY` block
  reading `Report Comment` and `Block @tgs_ana` (§2.15, §2.16). No `Mute`:
  mute is about a feed's posts, and a comment is not one. On your own comment
  the sheet carries `Delete` instead of `Report Comment` — you do not report
  yourself.

### 2.13 Public pages — a URL for every feed and every person

Anyone can read a public tgsocial page without an account, without the app,
and without waiting for a 14 MB wasm to boot. Three routes — served by whoever
hosts the web client, since nobody hosts it centrally, so read every path
below as relative to *that* origin ([`PUBLIC.md`](./PUBLIC.md)):

| Route | Shows |
| --- | --- |
| `/u/<name>` | A **person**: the merged, newest-first feed of every channel on their card. The landing page. |
| `/f/<channel>` | One **channel**'s posts. |
| `/n/<node>` | A node's **card** — bio, feeds, follows — the graph view. |

`<name>` on `/u/` resolves two ways, so a person can be reached by the handle
people actually know:

1. If `<name>` is a node channel (its pinned message is a card), use it.
2. Otherwise, if `<name>` is a feed channel whose description carries
   `tgsocial: @<node>` (`PROTOCOL §3`), follow that backlink to the node.

So `/u/tastycrow` reaches the person behind `@tastycrow` even though their
node is `@tgs_dankcoin`. A name that resolves to neither shows the §2.6 empty
card.

**How it reads without an account.** Not through TDLib — TDLib refuses every
chat read before authorization (401, measured; `web/test/smoke.mjs` asserts
it). It reads Telegram's own public preview, `t.me/s/<channel>`, which
Telegram serves to anonymous browsers and which carries everything the
protocol needs: post text, media, timestamps, view counts, `data-post`
message ids, the channel description with its backlink, and the pinned card
message itself. The wire details are in [`PUBLIC.md`](./PUBLIC.md).

The public page is a **lens, not a copy**: nothing is stored, the cache is
seconds long, and deleting a post in Telegram removes it from the page. No
account data, no private chats — a channel is only readable here because its
owner made it public on Telegram.

**What renders.** The post card of §2.3 with media playable inline and the
full-screen viewer, relative times, and the long-press sheet — minus the
things that need an identity: no Comment button, no comment counts, no
Follow. The sheet keeps its `SAFETY` block: `Report Post` and `Mute` work
signed out (§2.15, §2.17) against the same local lists, and `Block` needs an
attributed node so it appears only on `/u/` and `/n/`, where there is one.
The page footer carries `elijah@lucianlabs.ca` (§2.19). The floating tab bar is hidden; the topbar carries the wordmark and a
neutral `Public` pill.

**The nag.** A dismissible bar in the floating-bar slot on every public page:

```
  ╭────────────────────────────────────────────╮
  │ Follow this feed in tgsocial.   ( Get It ) │
  ╰────────────────────────────────────────────╯
```

`Get It` goes to `/`. Dismiss (×, 40pt) hides it for the session.

A signed-in visitor on the same URL gets the full screen — tab bar, Follow,
Comment — with no nag. The public page is the same product seen from outside.

**Sharing.** Two controls hand out links, and only one of them reads config.

**Share** on a post (§2.3) is always `https://t.me/<channel>/<id>`. The three
routes above address a person, a channel and a card — there is no route for a
single message — so a public origin has nothing to substitute here and does
not try. The post is on Telegram; the link says so.

**`Copy Link`** in the header kebab (§2.6) — the channel screen, and the
person, feed and node pages — copies one URL, and which one is decided by a
single piece of build config: the **public origin**, unset by default.

- **Unset** — the default, and the only state for a fresh clone:
  `https://t.me/<channel>`, on all three. A node and a feed *are* public
  channels (`PROTOCOL §3`), so it opens for anyone with Telegram, it needs no
  host, and it points at where the content is actually stored. A network whose
  storage layer is Telegram has no business handing out a link that dies when
  somebody stops paying for a droplet. On a person page the channel is the
  **node the page resolved to** (`PUBLIC §4`), not the handle in the URL: with
  no reader on the other end to follow the backlink a second time, only the
  node names the person, and the handle may be one of their feeds.
- **Set** — a self-hoster who deployed the reader (`PUBLIC.md`): absolute URLs
  to that origin, `<origin>/u/<name>` for a person, `/f/<channel>` for a
  channel, `/n/<node>` for a node. The same three, one for one.

Reading a link is not symmetrical with writing one. Every build recognises a
tgsocial `/u/ /f/ /n/` path on **any** host, configured or not, so a link
copied out of somebody else's deployment still lands on the right screen here.

**Native.** iOS and Android register these paths as universal/app links, so a
tapped link opens the installed app on that screen. An unsigned-in app shows
Sign in naming the destination, then lands there.

### 2.14 Connector (Mac only)

The Mac build hosts a local bridge that lets an AI assistant read your
tgsocial graph — and, if you allow it, post as you. The wire contract is
[`CONNECTOR.md`](./CONNECTOR.md); this is the screen that governs it. It is a
fifth tab, `Connector`, present only on macOS.

```
CONNECTOR                                     (section mark)
Let an assistant read your feeds.             (muted)

Bridge              [ toggle ]  Off           (list rows)
Port                8477                      (mono; editable when off)
Token               ••••••••  ( Copy ) ( Rotate )

SCOPE
[ Graph ] [ Mine ] [ Custom ]                 (.tabs)
14 sources — your feeds and the feeds of the
nodes you follow. Private chats are never
included.                                     (muted)
( Review Sources )                            (btn ghost sm → list of usernames)

WRITES
Post to my feeds     [ toggle ]  Off
Comment as me        [ toggle ]  Off
Edit my card         [ toggle ]  Off
Writes are off until you turn them on. Each
one is separate.                              (muted)

ACTIVITY
┌ card ─────────────────────────────────────┐
│ 14:02  Feed              30 posts          │  mono; newest first, last 100
│ 14:02  Node @tgs_ana     cached            │
│ 14:03  Post              Refused, read-only│  refusals in `bad`
└───────────────────────────────────────────┘
( Clear Activity )                            (btn ghost sm)

Connected assistants read through tgsocial;
they never see your Telegram sign-in.         (muted, footer)
```

Behaviour:

- The bridge is **off** until the toggle is on, and turning it off stops
  listening immediately and drops in-flight requests.
- `Port` is editable only while the bridge is off. A port already in use
  shows `That port is taken.` and the toggle stays off.
- `Copy` puts the token on the clipboard, toast `Token copied.`; `Rotate`
  asks first (modal: `Rotate the token? Connected assistants stop working
  until you give them the new one.`) then writes a new one.
- Switching scope preset repaints the source count immediately; `Review
  Sources` pushes a plain list of the usernames currently exposed, so the
  answer to "what can it see" is always one tap away.
- `Custom` scope pushes an editable list of usernames with the same
  availability check as feeds elsewhere.
- Each write toggle is independent; enabling one shows a one-line confirm
  (`Let an assistant post to your feeds?`) because it is a grant, not a
  preference.
- Activity streams live while the screen is open, newest first, refusals
  in `bad`. `Clear Activity` clears the on-screen ring, not the log file.
- Signing out turns the bridge off and wipes the token.

On iOS and Android the Connector tab does not exist and the bridge is not
compiled in — a phone is not a host for a local service an assistant dials.

### 2.15 Report a post or a comment

Anything a person can publish, a reader can report. There is no server to
report *to*, so a report is an email the reader's own mail client sends to
the published address (§2.19), and the reported thing is hidden on that
device immediately — waiting on a human is not a reason to keep looking at it.

**Where it lives.** On a post: the post sheet (§2.3), long-press or
right-click. On a comment: the same gesture on the comment row in a thread or
in the carousel's comment sheet (§2.12), which opens the **comment sheet** —
the same modal with the comment's own rows. Both sheets carry the same
`SAFETY` block:

```
SAFETY                                       (section mark)
( Report Post )                              (btn danger sm)   — `Report Comment` on a comment
( Block @tgs_ana )                           (btn ghost sm)    — the attributed node (§2.3); absent when unattributed, and when that node is your own (§2.16)
( Mute WaveLoop devlog )                     (btn ghost sm)    — the source channel; posts only, never comments
```

Tapping `Report Post` replaces the sheet with the report confirm:

```
REPORT                                       (section mark)
Report this post.                            (h2)     — `Report this comment.` on a comment
This sends an email from your mail app to    (muted)
the person who maintains tgsocial, with a
link to it. It disappears from this device
as soon as you send.

WHY                                          (section mark)
┌ card ─────────────────────────────────┐
│ Spam                                   │   single-select list rows, 40pt, the
│ Nudity or sexual content               │   picked row carries a gold check
│ Violence or threats                    │
│ Hate or harassment                     │
│ Child safety                           │
│ Illegal content                        │
│ Something else                         │
└───────────────────────────────────────┘

( Send Report )                              (btn danger; disabled until a reason is picked)
( Cancel )                                   (btn ghost)
```

The seven reasons are the whole list on every platform. They are the subject
line of the email verbatim, so they do not get reworded per build.

**The email.** `Send Report` opens the platform's mail composer — iOS
`MFMailComposeViewController` when mail is configured, else `mailto:` through
`openURL`; Android `ACTION_SENDTO` on a `mailto:` URI; web a `mailto:` link
with percent-encoded subject and body. Prefilled:

- To: `elijah@lucianlabs.ca`
- Subject: `tgsocial report — <reason>`
- Body:

```
Reason: <reason>
Link: https://t.me/<channel>/<id>
Channel: @<channel>
Message: <id>
Node: @<node>
Kind: post
App: tgsocial 1.0.0 (12) · iOS

Anything you want to add:

```

`Kind:` is `post` or `comment`. `Node:` is the attributed node (§2.3) and
reads `unattributed` when there is none; on a comment it is the commenter's
node. `App:` is the same version string as the You footer (§6) plus the
platform (`iOS`, `Android`, `Web`). The body ends on a blank line so the
composer's cursor lands under the prompt. **The app adds nothing else** — no
phone number, no node, no device id; the reporter's address is whatever their
own mail client sends, and they can edit or delete every line before sending.

**Hiding is immediate and unconditional.** The moment `Send Report` is
tapped, the post or comment is written to the hidden list (`PROTOCOL §7`) and
vanishes from every surface (§2.18). It does not matter whether the mail is
actually sent — the app cannot know, and the reader has already said they do
not want to see it. Undo is Settings → `HIDDEN` (§2.20).

Toast on send: `Reported. It's hidden here now.`
No mail app, or the composer refuses to open: the content is hidden anyway
and the toast reads `No mail app. Write to elijah@lucianlabs.ca.`

Reporting works signed out, on the public routes (§2.13) too; the hidden
list is the same list.

### 2.16 Block a node

Blocking is the reader's own list, kept on their device. It is never written
to the card, never sent anywhere, and the blocked person is not told — there
is no notification to send and no server to send it from. Nobody but the
reader can read it.

**Where it lives.** The node profile (§2.5) gains a kebab menu in the
top-right corner, same component as the feed channel's (§2.6): `Open in
Telegram`, `Copy Link`, `Block @tgs_ana`. And the post sheet's `SAFETY`
block (§2.15).

**Never your own node.** The confirm below is written about a second party,
and blocking yourself has none: nobody is told, nothing is published, and the
only thing that happens is your own posts leave your own feed and your own
`DIRECT` list. So the row is absent on your own posts, your own comments and
your own profile — which carries `Open in Telegram` and `Copy Link` and
nothing else.

Confirm modal:

```
BLOCK                                        (section mark)
Block @tgs_ana?                              (h2)
Their posts and their comments disappear      (muted)
from your feed, your threads, your graph,
and search. They are not told. Undo it in
Settings.

( Block )                                    (btn danger)
( Cancel )                                   (btn ghost)
```

Toast: `Blocked @tgs_ana.`

**What a blocked node looks like: nothing at all.** No tombstone, no "content
hidden" row, no count. A tombstone in a chronological merged feed still
reports how often the blocked person posts and hands them a strip of the
screen every time they use it, which is the thing the reader asked to stop.
So blocking removes, everywhere: the main feed, feed channel screens, thread
comments (and the comment counts they feed), the +1 walk and both graph
lists, Explore rows, and search results.

The **one** exception is the blocked node's own profile, reached deliberately
— a `t.me` link, a public URL (§2.13), an exact-username search. An empty
screen there reads as a broken app, so it says so:

```
(avatar 72pt — initial only, their photo is not loaded)
@tgs_ana                                     (mono muted)
You blocked this node.                       (h2)
Nothing they post reaches you.               (muted)
( Unblock )                                  (btn ghost)
```

`Unblock` here and in Settings is one tap, no confirm — toast
`Unblocked @tgs_ana.` — and every surface repaints on the next render.

**Blocking never edits your card.** If you follow a blocked node you go on
following them publicly and see nothing from them here. Unfollowing is a
separate act and a public one (`PROTOCOL §4.6`); blocking is private, and
rewriting `follows:` to enforce it would publish exactly the fact this
feature promises to keep. This also means a blocked node still counts in your
`FOLLOWS` count on your own card, because that count is the card's.

### 2.17 Mute a feed

Softer than a block and aimed at a channel, not a person: a muted feed's
posts leave the merged feed and nothing else changes.

**Where it lives.** The feed channel kebab (§2.6) gains `Mute Feed` — reading
`Unmute Feed` when it is already muted — and the post sheet's `SAFETY` block
(§2.15) carries `Mute WaveLoop devlog`. No confirm: it is one tap to undo in
the same two places.

Toasts: `Muted WaveLoop devlog.` · `Unmuted WaveLoop devlog.`

What mute does **not** do: the channel stays reachable and complete on its own
screen (§2.6), it stays listed on its node's profile (§2.5) with a faint
`Muted` pill after the title, its comments are untouched wherever they appear,
and public pages (§2.13) are unaffected. Muting my own feed is allowed and
means the same thing.

### 2.18 The default filter

**The filter is on and there is no switch.** A fresh install has empty lists,
and blocked, muted, and reported content is hidden the moment it is on a
list — there is no "safe mode" to enable, no preference to find, and no way
to turn filtering off. The only reverse is per item, in Settings (§2.20).

Concretely, on every screen that renders posts or comments — Feed, Feed
channel, Thread, the carousel's comment sheet, Explore, Graph, search, and
the public routes (§2.13) — a client drops:

- every post whose attributed node (§2.3) is blocked;
- every comment whose commenter node is blocked, including replies under it;
- every post and comment on the hidden list from a report;
- and, on the main feed only, every post from a muted feed.

Dropped items leave no gap, no placeholder, and no residue in a count: a
hidden comment is not in the post footer's `N comments`, and a blocked node
is not in `DIRECT · 12` or `+1 · 84`. Pagination compensates — a page whose
items are all filtered fetches the next one rather than rendering an empty
list.

The Connector bridge (§2.14) is not a screen, but it is the same app answering
for the same reader, so every response it makes is filtered the same way —
`CONNECTOR.md §3` says which route drops what.

A reviewer can confirm the filter without opening Settings: block a node,
and their posts are gone from the feed on the next render.

### 2.19 Contact

`elijah@lucianlabs.ca` is the published address (`docs/PRIVACY.md`), and it
is reachable inside the app without signing in.

- **You screen footer** (§2.8), above the version line:
  `Questions or reports: elijah@lucianlabs.ca` (muted, tapping opens the mail
  composer) then `Reports are read by a person within 24 hours.` (faint).
- **Sign in screen** (§2.1), one muted line under the form:
  `elijah@lucianlabs.ca` — the only screen a signed-out reader sees.
- **Settings** (§2.20), the `CONTACT` card, with the full commitment.
- **Public pages** (§2.13) carry the address in their footer.

The commitment, verbatim, in the Settings `CONTACT` card:

```
CONTACT                                      (section mark)
elijah@lucianlabs.ca                         (link row, 40pt → mail composer)
Reports are read by a person within 24        (muted)
hours. Content that breaks the rules is
reported to Telegram, the only party that
can remove it from the network. Your copy is
hidden on your device the moment you report
it, whether or not anyone else acts.
```

That last clause is the honest part: a client with no server cannot delete
someone else's channel, and saying so is better than implying a takedown it
cannot perform.

### 2.20 Settings

A pushed screen, reached from You (§2.8) by `( Settings )` (ghost). It holds
the safety lists, the contact card, and the two destructive actions. Every
list row is 40pt with the hit target as an overlay (`COMPONENTS.md` rule 6).

```
‹ Back                                          [Synced]

SAFETY                                       (section mark)
Blocked and reported content is hidden        (muted)
everywhere in the app. The filter is always
on; there is no switch. These lists live on
this device only and nobody else can read
them.

BLOCKED · 2                                  (section mark, serif count)
┌ card ─────────────────────────────────┐
│ (avatar) Ana Iliovic      ( Unblock )  │  name body, @handle mono muted under it
│          @tgs_ana                      │  row taps through to the profile
└───────────────────────────────────────┘
You haven't blocked anyone.                  (empty, muted)

MUTED · 1
┌ card ─────────────────────────────────┐
│ WaveLoop devlog            ( Unmute )  │
│ @waveloop_devlog                       │
└───────────────────────────────────────┘
No muted feeds.                              (empty, muted)

HIDDEN · 3
┌ card ─────────────────────────────────┐
│ WaveLoop devlog · 144      ( Unhide )  │  title body, key mono; reason + date
│ Spam · reported 2026-09-04             │  in muted underneath
└───────────────────────────────────────┘
Nothing hidden.                              (empty, muted)

CONTACT                                      (§2.19)

( Sign Out )                                 (btn danger)
( Delete My Node )                           (btn danger)
```

- `Sign Out` moves here from You and keeps its confirm (§4). `Delete My Node`
  sits below it (§2.21) — the order is deliberate: the reversible destructive
  action comes before the irreversible one.
- Toasts: `Unblocked @tgs_ana.` · `Unmuted WaveLoop devlog.` ·
  `Unhidden. It's back in your feed.`
- A hidden row names its channel and message id, never the content: showing a
  preview of the thing someone reported would undo the report.
- A hidden row whose channel is also blocked or muted still lists here; the
  lists are independent and each undo only lifts its own.

### 2.21 Delete my node

Setup (§2.2) creates two public channels a person cannot remove from anywhere
else in the app, so the app removes them. Last item in Settings, below
Sign Out.

```
DELETE MY NODE                               (section mark)
Delete my node.                              (h2)
This deletes the channel @tgs_elijah and     (muted)
your comments channel @tgs_elijah_r from
Telegram. The public card other people read
disappears, every post and comment in those
two channels goes with it, and the names are
released for anyone to take. This cannot be
undone.

Your feed channels are not touched.           (muted)

TYPE @tgs_elijah TO CONFIRM                  (field label)
[                            ]               (input, mono, no autocorrect)
( Delete My Node )                           (btn danger; disabled until the input matches exactly)
( Cancel )                                   (btn ghost)
```

The match is case-insensitive and tolerates a missing `@`. While the delete
runs the button reads `Deleting…` and is disabled, and the modal cannot be
dismissed.

**Order, and it matters** (`PROTOCOL §4.11`): the comments channel first, the
node channel second. Deleting the node first and then failing on the comments
channel would leave a public channel backlinking to a node that no longer
exists, with no way back to it in an app that is now at Setup.

Outcomes:

- **Both deleted.** Local state is wiped exactly as Sign Out wipes it, the
  session stays signed in, and the app lands on Setup (§2.2) with nothing
  filled in. Toast: `Your node is gone.`
- **No comments channel.** Step one is skipped silently; there is nothing to
  say about a channel that was never made.
- **Not the owner** (`chat.canBeDeletedForAllUsers` is false on either
  channel): nothing is deleted and the modal shows
  `Telegram won't let you delete @tgs_elijah — only the channel's owner can.
  Open it in Telegram to see who owns it.` with `( Open in Telegram )`
  (btn neutral) and `( Close )` (btn ghost).
- **Comments channel failed.** Stop before touching the node.
  `Couldn't delete @tgs_elijah_r — Telegram said: <error>. Nothing was
  deleted.` with `( Try Again )` (btn danger) and `( Close )` (btn ghost).
- **Node failed after the comments channel went.** The card is rewritten to
  drop its `replies:` line (`PROTOCOL §4.4`) so it stops pointing at a dead
  channel, and the modal reads `Your comments channel is gone. @tgs_elijah is
  still there — Telegram said: <error>.` with `( Try Again )` and `( Close )`.
  The app stays in Settings, still has a node.
- **Offline.** Nothing runs; toast `You're offline.`

The safety lists (`PROTOCOL §7`) survive this, as they survive Sign Out: they
protect the person holding the phone, not the node they just deleted.

## 3. Copy rules

House Pour voice. Short declaratives, no exclamation marks, no emoji in
chrome, no "Oops", no apologies. Buttons are verb-first title case. Empty
states end in a full stop and offer one action at most. Numbers the user is
meant to feel (follow counts in section marks) are serif.

Word list: `node`, `card`, `feed`, `follow`, `network`, `+1`, `comment`,
`reply`, `thread`, `comments channel`, `block`, `mute`, `report`, `hidden`.
Never "friends", "subscribe", "timeline", "algorithm", "flag", "ban",
"moderation", "community guidelines".

## 4. Behaviour rules

- Cold start: show the last cached feed immediately, then refresh. Never a
  blank screen behind a spinner if there is a cache.
- Every write to the card (follow, feeds, edit) is optimistic in the UI and
  rolled back with a toast on failure: `Couldn't update your card.` plus
  TDLib's message.
- Network errors: status pill `Offline`; reads serve cache; writes toast
  `You're offline.`
- Rate limits (`FLOOD_WAIT_n`): toast `Telegram asked us to wait n s.` and
  back off that long before retrying automatically.
- Sign out (Settings, §2.20) asks once (modal: `Sign out of tgsocial? Your
  node stays on Telegram.` `( Sign Out )` danger, `( Cancel )` ghost) then
  `logOut` and wipes local state — except the safety lists, which survive by
  design (`PROTOCOL §7`).
- The safety filter (§2.18) is applied at render on every surface, always,
  with no preference behind it. Blocked, muted and reported content never
  paints, and nothing about those lists is written to the card or leaves the
  device.
- Links open in the system browser (web: new tab). Telegram links
  (`t.me`, `tg://`) open the Telegram app when installed.
- Accessibility: 40pt minimum targets, labels on icon-only controls,
  Dynamic Type / font scaling respected on native, focus rings visible on web.

## 5. Platform notes

- **iOS**: SwiftUI, iOS 17+, iPhone and iPad (single column everywhere).
  Portrait and landscape. Request nothing at launch except what TDLib needs;
  photo library access only when `Add Photo` is tapped.
- **Android**: Kotlin + Jetpack Compose, minSdk 26, targetSdk 35. Edge-to-edge,
  light status bar icons on the ivory background. Predictive back supported.
- **Mac**: the same SwiftUI app built for Mac Catalyst, plus the Connector tab (§2.14) and the bridge. Same TDLib session, same House Pour look.
- **Web**: static files, no bundler, no framework. Media via `<img>`, `<video>`, `<audio>` on object URLs from tdweb `readFile`/`readFilePart`. `tdweb` (TDLib wasm) loaded
  from `vendor/`. Must work from a plain nginx host over https. Installable
  PWA manifest with the ivory theme colour.

## 6. Versioning

Marketing version `1.0.0`; build number increases every archive. Show
`tgsocial <version> (<build>)` in the You screen footer on all platforms.
