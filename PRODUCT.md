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
│ tgsocial                       [Synced]  │  topbar: wordmark left, status pill right
├──────────────────────────────────────────┤
│ [ Feed ] [ Explore ] [ Graph ] [ You ]   │  .tabs segmented control (not a native tab bar)
├──────────────────────────────────────────┤
│                                          │
│  cards …                                 │
│                                          │
└──────────────────────────────────────────┘
```

- The topbar is sticky and translucent (House Pour `.topbar`). The status pill
  reads `Synced`, `Syncing`, `Offline`, or `Signed out`; gold only when
  `Synced`.
- The `.tabs` control sits directly under the topbar and scrolls away with
  content on native; on web it is sticky with the topbar.
- No native tab bars, no navigation bars with system titles, no system
  segmented controls. Pushes (profile, feed detail, compose) open as full
  screens with a `‹ Back` ghost button top-left in the same topbar slot where
  the wordmark was; the status pill stays.
- Sheets (compose, confirm) are House Pour modals: a card over a
  `rgba(38,35,25,0.4)` scrim. Never a dark sheet.
- Toasts are the one dark surface. They fade; they do not slide.

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
│ (avatar) WaveLoop devlog          14:02    │  title: body 600; time: mono faint; avatar 36pt circle
│          @waveloop_devlog                  │  mono muted
│                                            │
│ Post text with *bold* and links…           │  body 1rem/1.5
│ [ media, 12pt radius, full width ]         │
│                                            │
│ 1.2k views · 14 reactions     Open in Telegram │  footer: mono faint left, ghost sm right
└────────────────────────────────────────────┘
```

- Time: `HH:mm` today, `Mon d` this year, `yyyy-MM-dd` otherwise. Derive,
  never hand-format.
- Forwarded posts show a muted line `Forwarded from <origin>` above the text.
- Reactions render as the reaction emoji followed by the count (that emoji is
  Telegram's data, not our chrome). Views use the figure-compact rule: `1.2k`.
- Tapping the title opens the feed's channel screen (2.6). Tapping the card
  body opens the post on Telegram (`t.me` link, `PROTOCOL §4.8`).
- Pull-to-refresh (native) / `Refresh` ghost button under the tabs (web).
- Infinite scroll: load more when the last card is within two screens of the
  bottom. A muted `Loading…` row at the end; `That's everything.` when all
  sources are exhausted.
- Empty: one card — h2 `Nothing here yet.` muted `Follow a node and their
  feeds show up here, newest first.` `( Explore )` btn accent.
- Own posts appear in the feed like any other.

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

## 3. Copy rules

House Pour voice. Short declaratives, no exclamation marks, no emoji in
chrome, no "Oops", no apologies. Buttons are verb-first title case. Empty
states end in a full stop and offer one action at most. Numbers the user is
meant to feel (follow counts in section marks) are serif.

Word list: `node`, `card`, `feed`, `follow`, `network`, `+1`. Never
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
- **Web**: static files, no bundler, no framework. `tdweb` (TDLib wasm) loaded
  from `vendor/`. Must work from a plain nginx host over https. Installable
  PWA manifest with the ivory theme colour.

## 6. Versioning

Marketing version `1.0.0`; build number increases every archive. Show
`tgsocial <version> (<build>)` in the You screen footer on all platforms.
