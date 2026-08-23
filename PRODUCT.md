# tgsocial — product spec

One app, three builds (iOS, Android, web). Same screens, same copy, same look.
This file is the shared contract for screens, flows, and words. The wire
contract is `PROTOCOL.md`. The look is `design/` (House Pour).

## 0. Naming

- Product: **tgsocial** — always lowercase, one word, set in the brand face
  (Kaushan Script) wherever it appears as a wordmark. In running text it is
  `tgsocial` in the body face.
- Bundle / package id: `ca.lucianlabs.tgsocial`.
- Web: `https://tgsocial.lucianlabs.ca`.
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

Step 2 replaces the field with `CODE` + input (numeric, 5 digits) and the
button reads `Sign In`. A ghost button `Use another number` goes back.

Step 3 (2FA) shows `PASSWORD` + secure input, hint text from TDLib's
`passwordHint` in muted if present, button `Unlock`.

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
tap → feed channel screen (2.6). Avatar 36pt = the node's photo.

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
( Close )                                    (btn ghost)
```

  `Open in Telegram` lives here now — nowhere else on the card. Views moved
  here from the footer.
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

`‹ Back`, then the channel header (avatar, title h2, `@username` mono,
description muted, `Open in Telegram` ghost sm, pill `Verified` if backlinked),
then that channel's posts chronologically using the same post card.

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
( Sign Out )                danger

tgsocial 1.0 (12) · TDLib 1.8.x · node @tgs_elijah   mono faint
```

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
| Audio (`messageAudio`) | **Player row**: play/pause circle 40pt (`stepper` style), title + performer in body/mono, serif elapsed / total time, a hairline progress bar in `line2` with a gold played segment | Same row; no full-screen |
| Voice / video note | Same player row with a waveform drawn from TDLib's waveform bytes (ink bars, gold played) | Video notes: circular inline player |
| Document | Row: file glyph, name in body, size + type in mono | PDF, images, text, audio/video documents open in the in-app viewer; other types download then offer `Share` (native) / `Download` (web) |
| Sticker | Rendered static (webp/png); animated stickers show their thumbnail | — |
| Link preview | `linkPreview` title/description/thumbnail as a bordered row | Opens the link in the system browser (links are the one exception) |
| Poll, location, contact, other | A muted one-line summary (`Poll · 3 options`, `Location`) | `Open in Telegram` |

Player rules (all platforms):

- One audio item plays at a time; starting another pauses the first. Playback
  continues while scrolling and across tabs; a slim **now-playing row** docks
  above the floating tab bar (title, play/pause, elapsed) while audio plays.
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

### 2.13 Public links — browse without signing in (web only)

`https://tgsocial.lucianlabs.ca/f/<channel>` shows that channel's posts to
anyone, signed in or not. `/n/<node>` does the same for a node profile.
Telegram exposes public channels to anonymous clients, so no account is
needed to read one — the app just has to not demand one first.

**Anonymous mode.** When the route is `/f/…` or `/n/…` and TDLib is not
signed in, the client authenticates as an anonymous TDLib session and reads
only that public chat (`searchPublicChat` → `getChatHistory`). Nothing is
written, no node is created, and the local database is namespaced so an
anonymous visit never touches a signed-in user's data. If the channel is
private or missing: one card, h2 `Nothing here.` muted `That channel is
private, or it doesn't exist.`

**What renders.** The feed channel screen (§2.6) exactly as a signed-in user
sees it — post cards with media playable inline, the full-screen viewer,
relative times, the long-press post sheet — with these differences:

- Post attribution falls back to the channel (§2.3), since an anonymous
  visitor has no follows to attribute through.
- `Comment` is absent; comment counts are absent (comments are network-
  scoped, and an anonymous visitor has no network).
- The floating tab bar is hidden; the topbar shows the wordmark and a
  neutral `Public` pill instead of the status pill.

**The nag.** A dismissible bar docked at the bottom (the floating-bar slot,
same panel/pill/shadow treatment), on every public route:

```
  ╭────────────────────────────────────────────╮
  │ Follow this feed in tgsocial.   ( Get It ) │   body muted + btn primary sm
  ╰────────────────────────────────────────────╯
```

`Get It` goes to `/` (sign in). Dismiss (×, 40pt target) hides it for the
session; it returns on the next visit. Content padding accounts for it the
same way it accounts for the tab bar (§1).

A signed-in visitor opening the same link gets the normal feed channel
screen with the tab bar and no nag — the public route is a lens, not a
separate app.

**Sharing.** The Share button (§2.3) keeps sharing the Telegram `t.me` link;
the channel header on a public route gains a `Copy Link` ghost sm that
copies the `tgsocial.lucianlabs.ca/f/<channel>` URL, toast `Link copied.`

**Native.** iOS and Android register `tgsocial.lucianlabs.ca/f/*` and `/n/*`
as universal/app links so a tapped link opens the installed app on that
screen. Neither platform has an anonymous mode in v1 — an unsigned-in app
opening a public link shows Sign in, then lands on the linked screen.

## 3. Copy rules

House Pour voice. Short declaratives, no exclamation marks, no emoji in
chrome, no "Oops", no apologies. Buttons are verb-first title case. Empty
states end in a full stop and offer one action at most. Numbers the user is
meant to feel (follow counts in section marks) are serif.

Word list: `node`, `card`, `feed`, `follow`, `network`, `+1`, `comment`,
`reply`, `thread`, `comments channel`. Never
"friends", "subscribe", "timeline", "algorithm".

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
- Sign out asks once (modal: `Sign out of tgsocial? Your node stays on
  Telegram.` `( Sign Out )` danger, `( Cancel )` ghost) then `logOut` and
  wipes local state.
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
- **Web**: static files, no bundler, no framework. Media via `<img>`, `<video>`, `<audio>` on object URLs from tdweb `readFile`/`readFilePart`. `tdweb` (TDLib wasm) loaded
  from `vendor/`. Must work from a plain nginx host over https. Installable
  PWA manifest with the ivory theme colour.

## 6. Versioning

Marketing version `1.0.0`; build number increases every archive. Show
`tgsocial <version> (<build>)` in the You screen footer on all platforms.
