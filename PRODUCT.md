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
│      │ Feed  Explore  Graph  (◉) │        │  panel fill, 1pt line, pill radius, one card shadow,
│      ╰──────────────────────────╯        │  16pt above the home indicator / viewport bottom; (◉) = your avatar
└──────────────────────────────────────────┘
```

- The topbar is sticky and translucent (House Pour `.topbar`). The status pill
  reads `Synced`, `Syncing`, `Offline`, or `Signed out`; gold only when
  `Synced`. **The pill is a button**: tapping it opens the Status sheet (§2.10).
- The **tab bar floats at the bottom**: the House Pour `.tabs` segmented
  control (same component, same four items `Feed · Explore · Graph` and your
  avatar)
  placed `position: fixed` / overlay at the bottom of the column, centred,
  hugging its content (not full width), `cardGap` (16pt) above the safe-area
  bottom, with `panel` fill and the single card shadow so it reads as a raised
  pill over scrolling content. Content scrolls under it; every scroll view
  pads its bottom by the bar height + `cardGap` so the last card clears it.
  It is hidden on Sign in, Setup, and inside full-screen viewers; it stays
  on pushed screens (profile, feed channel). No native tab bar.
- **The last tab is your avatar, not a word** (Elijah, 2026-09-25: "instead of
  "you" put an avatar on the bottom right of the menu"). A 24pt circle in the
  item's slot, always the rightmost item (on the Mac, after `Connector`,
  §2.14); the 40pt target is an overlay around it (`COMPONENTS.md` rule 6),
  and its accessibility label is `You`. The picture is the first of: your
  node's photo; your Bluesky avatar (§2.35); the initial of your name in the
  display serif — §2.3's last fallback. Selected, the item takes the `.tabs`
  selected fill like the other three, the avatar inside it, and the circle
  takes a 2pt `accent` ring — a photo can hide the fill behind it. The circle
  is laid over the item's hidden word, so the bar is no taller and no wider for
  it (`avatarTab`, 24pt, sits inside the item's `tabY` inset). The screen it
  opens is still called You in this file (§2.8). A person's own face is the
  one thing on the bar that is theirs, and it reads at a glance as "me" where
  the word needed reading.
- No native navigation bars with system titles, no system segmented controls.
  Pushes (profile, feed detail, compose) open as full screens with a
  `‹ Back` ghost button top-left in the same topbar slot where the wordmark
  was; the status pill stays.
- Sheets (compose, confirm, status) are House Pour modals: a card over a
  `rgba(38,35,25,0.4)` scrim. Never a dark sheet.
- Toasts are the one dark surface. They fade; they do not slide. Full-screen
  media viewers (§2.11) are the one other dark surface — `ink` at 96% — because
  photos and video need it.

**Signed in means Telegram, Bluesky, or both** (Elijah, 2026-09-25: "it should
allow combined logins to telegram and blueky"). It is one value, computed in
one place, and every gate reads it — routing, Setup, the tab bar, the status
pill, Compose, Settings, the Connector — so no screen decides for itself what
"signed in" means:

| State | Telegram | Bluesky |
| --- | --- | --- |
| **Telegram only** | `authorizationStateReady` | no session |
| **Bluesky only** | not ready | a session held (§2.35) |
| **Both** | ready | held |
| **Signed out** | not ready | no session — Sign in (§2.1) |

A Bluesky session that Bluesky ended (§2.39) still counts as held: the reader
signed in and did not sign out, and an app that dropped a Bluesky-only reader
back to Sign in whenever a two-week token lapsed would be signing them out on
Bluesky's schedule. The shell is the same in every state — same tabs, same
topbar — and what each screen shows in each state is §2.41. Bluesky alone
never starts TDLib (`PROTOCOL §12.11`).

## 2. Screens

### 2.1 Sign in

Shown whenever the reader is signed in to neither network (§1).

```
tgsocial                                   (wordmark, 3rem)
Telegram and Bluesky, as one feed.         (h1)

┌ card ─────────────────────────────────┐
│ TELEGRAM                               │  (section mark)
│ PHONE NUMBER                           │  (field label)
│ [ +1 604 555 0199            ]         │  (input, tel)
│ ( Send Code )                          │  (btn neutral)
└───────────────────────────────────────┘
┌ card ─────────────────────────────────┐
│ BLUESKY                                │  (section mark)
│ HANDLE                                 │  (field label)
│ [ elijah                     ]         │  (input, mono; placeholder `elijah.bsky.social`)
│ ( Sign In with Bluesky )               │  (btn neutral)
└───────────────────────────────────────┘

( Look Around First )                       (btn ghost, outside the cards — §2.22)
elijah@lucianlabs.ca                        (muted, → mail composer — §2.19)
```

- **Two peer cards, and neither button is gold.** They are two equal next
  actions, and gold marks the one next action (§1): a gold `Send Code` would
  say Telegram is the sign-in and Bluesky the extra, which is the thing this
  screen stopped saying. Either card alone signs in (§1). Telegram's card is
  first because the graph lives there (`PROTOCOL §12`) — first, not primary.
- **No explanation on the screen** (§3). The h1 is the only sentence; what the
  app stores and where is `docs/PRIVACY.md`'s to say, and what each network
  unlocks is §2.41's.
- `Look Around First` is the demo (§2.22), and it is on **step 1 only**. It
  sits below both cards and carries no fill.

Arrived on a public link (§2.13), one muted line under the h1 names the
destination and the network that reaches it: `Sign in to Telegram to see
@<name>.` The destination is a Telegram channel, so only Telegram's card gets
there. A Bluesky sign-in from this screen lands on Feed and parks the
destination, as the demo does (§2.22); signing in to Telegram later lands on
it.

**Telegram's steps.** `Send Code` replaces both cards with Telegram's alone —
once a number is in flight the screen has one job — and from here its button is
gold, because now there is one next action. Step 2 replaces the field with
`CODE` + input (numeric, 5 digits) and the button reads `Sign In`. A ghost
button `Use another number` goes back to both cards.

Step 3 (2FA) shows `PASSWORD` + secure input, hint text from TDLib's
`passwordHint` in muted if present, button `Unlock`.

A step TDLib asks for that the app does not have shows muted
`Sign in with the Telegram app first.`, TDLib's state name in mono faint, and
`Use another number`.

**Bluesky's steps.** `Sign In with Bluesky` runs §2.35's sign-in from this
card: the handle rules, Bluesky's page in the system browser, and the waiting
state (`Waiting for Bluesky…`, the resolved handle, `Finish in your browser.`,
`( Cancel )`) in place of both cards. Cancel, a refusal, a failure and the
10-minute timeout return to both cards with the handle still typed, with
§2.35's and §2.39's toasts. Success: toast `Signed in to Bluesky as
@elijah.bsky.social.`, then the offer below.

**The other one, offered once.** Whichever sign-in succeeds first, this screen
offers the other once, before anything else:

```
tgsocial                                   (wordmark, 3rem)
Also sign in to Bluesky?                   (h1)

┌ card ─────────────────────────────────┐
│ BLUESKY                                │
│ HANDLE                                 │
│ [ elijah                     ]         │
│ ( Sign In with Bluesky )               │  (btn primary — the one next action)
└───────────────────────────────────────┘
( Not Now )                                 (btn ghost)
```

and, after Bluesky first, h1 `Also sign in to Telegram?` over Telegram's card
(`PHONE NUMBER`, `( Send Code )` primary) and `( Not Now )`. Telegram's steps
and Bluesky's steps run from the offer exactly as above; `Use another number`
and a failed Bluesky attempt come back to the offer, not to both cards.

- `Not Now`, or finishing the second sign-in, goes on: to Setup (§2.2) when
  Telegram is signed in and has no node, else to Feed (§2.3).
- **Once per install.** The UI preference `offeredOther` (`PROTOCOL §7`) is set
  when the offer is shown, not when it is answered, so a relaunch mid-offer
  does not show it twice. After `Not Now` the other network is in Settings
  (§2.20) — and, for a Bluesky-only reader, on You (§2.8). It is cleared with
  the rest of local state when the last network signs out (§4), so the next
  person to sign in on the device is offered it too.
- Absent in the demo (§2.22), and when the second network is already held.

**From inside the app.** A Bluesky-only reader's `( Sign In with Telegram )`
(§2.41) pushes Telegram's steps as a full screen — Telegram's card alone, its
button gold, `‹ Back` top left, no `Look Around First`, no offer — and lands
where Telegram's sign-in would: Setup with no node, else back where it was
opened. Leaving before Telegram's sign-in finishes (`‹ Back`, a tab) ends it,
and TDLib is closed again (`PROTOCOL §12.11`). A Telegram-only reader signs in
to Bluesky from Settings (§2.35).

Every step's footer carries one muted line, `elijah@lucianlabs.ca` (§2.19) —
this is the only screen a signed-out reader sees, and the address has to be
reachable from it.

Errors (toast, `.bad`): `That code didn't match.` · `That password didn't
match.` · `Telegram didn't accept that number.` · `Too many tries. Wait a
moment.` (FLOOD_WAIT — show the seconds if TDLib gives them). Other TDLib
errors surface their message text verbatim. Bluesky's are §2.39's.

### 2.2 Setup

Shown after Telegram's sign-in (and §2.1's offer) when no node is found
(`PROTOCOL §4.2`). A Bluesky-only reader never sees it: a node is a Telegram
channel.

Card 1 — **Your node**
```
YOUR NODE                                   (section mark)
Make your node.                             (h2)
It's public on Telegram.                    (muted — the consequence, one sentence)

NODE NAME
[ tgs_elijah                ]               (input; live availability check → pill `Available` / `Taken`)
( Create Node )                             (btn primary)
( I already have one )                      (btn ghost → re-runs §4.2, toast `No node found.` if none)
```

Card 2 — **Your feeds** (appears once the node exists)
```
YOUR FEEDS
┌ list-item ─────────────────────────────┐
│ WaveLoop devlog       @waveloop_devlog │ [toggle]
│ Très Buchet           @tresbuchet      │ [toggle]
│ Notes to self         Needs a public link │ (disabled, faint)
└────────────────────────────────────────┘
( Save Feeds )                              (btn primary)
```

Toggling on asks once per feed, inline below the row, in muted text with two
small buttons: `Add "tgsocial: @tgs_elijah" to its description?` —
`( Verify )` `( Skip )`. Verify appends
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
- A Bluesky post (§2.36) follows the same order with its account in place of
  the channel: the node its account is verified to, else the account itself.

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
else copy the link + toast `Link copied.` On a private post the link is the
`t.me/c/` form and the toast says who can open it (§2.32).

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
- Empty: one card — h2 `Nothing here yet.` and `( Explore )` btn accent.
  Bluesky only (§1): the h2 alone — Explore finds nodes, and that needs
  Telegram (§2.41).
- Own posts appear in the feed like any other, attributed to me.

### 2.4 Explore

```
[ Find a node                 ]  (input; on submit → open profile for @username or toast `Not a tgsocial node.`; an invite link → the join preview, §2.31)

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

Empty states: `Nobody nearby yet.` (Nearby) · `No nodes found.` (Directory).

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

A node with a verified Bluesky link (`PROTOCOL §12.3`) carries a `Bluesky`
row at the top of `FEEDS` (§2.36); an unverified one carries nothing.

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

Empty, each under its section mark in muted: `Not following anyone yet.`
(`DIRECT`) · `Nobody at +1 yet.` (`+1`). Labels, not instructions (§3):
Explore is one tab away and is where following starts.

**Bluesky only** (§1) there is no node graph to draw — no card, no
`follows:`, no +1 — so the tab draws who the account follows on Bluesky,
rather than standing empty:

```
YOUR NETWORK
┌ card ─────────────────────────────────┐
│        ·     ·                         │  you = gold dot at centre; follows = ink dots 8pt, ring 1 only
│    ·    ●    ·                         │  tap a dot → the profile on Bluesky (system browser, §4)
│        ·   ·   ·                       │
└────────────────────────────────────────┘
BLUESKY · 212                                (section mark, serif count)
(avatar) Ana Iliovic                          (list rows: display name body, handle mono muted;
         @ana.bsky.social                      tap → the profile on Bluesky; no Follow button)
```

- No `+1` section: Bluesky follows are never walked (`PROTOCOL §12.9`), and a
  ring 2 would be the graph §12.10 says this is not.
- No `Follow` button: following on Bluesky happens on Bluesky.
- Empty: `Not following anyone yet.` under `BLUESKY`.
- The list pages as it scrolls; the ring draws the accounts loaded so far.
- The §2.18 filter applies: a blocked account is not a dot and not a row.
- **Both** signed in, the tab is the node graph above, unchanged. Bluesky
  follows reach the feed (§2.36), not the graph — `PROTOCOL §12`'s line that
  the graph lives on Telegram holds as soon as there is a Telegram graph.

### 2.8 You

The avatar tab (§1) opens it.

```
                                              ( Settings )   btn ghost sm — top right, pushes §2.20
(avatar 72pt)   Elijah Lucian                 (h2)
                @tgs_elijah                   (mono muted)   ( Edit Card ) btn sm

YOUR FEEDS                     ( Manage ) btn sm
┌ card: list of my feeds; each row → Compose for that feed ┐
  — none yet: `No feeds yet.` (muted, in the card)

( Compose )                                   btn primary — the one gold action on this screen

LISTING
Public listing          [ pill: Listed / Unlisted ]  (toggle writes `public:`)
( Announce in Directory )  btn sm — posts to @tgsocial_index; disabled when unlisted

PRIVATE                                       (§2.27 — absent until there is a node)
Nothing private yet.
( Make a Private Node )     btn neutral sm

( View as others see it )   ghost

elijah@lucianlabs.ca                                 muted, → mail composer
tgsocial 1.0 (12) · TDLib 1.8.x · node @tgs_elijah   mono faint
```

**`Settings` is top right** (Elijah, 2026-09-25: "put "settings" on top right
of that"), a ghost sm in the header's top-right corner — where §2.6 puts a
channel's kebab — present in every state (§1) and in the demo. The ghost
`( Settings )` row that closed the body is gone. The topbar's right is the
status pill's and stays so.

Neither sign-out is on this screen: they live in Settings with `Delete My
Node` (§2.20, §2.21), so the destructive actions sit together and none is a
mis-tap away from `View as others see it`. The contact line is §2.19 and is
present whether or not a node exists; the 24-hour commitment is said once, on
Settings' `CONTACT` card, not here as well (§3).

With no node, the body is §2.3's empty card (h2 `Nothing here yet.`,
`( Set Up )` → §2.2); `Settings` stays top right.

**Both** signed in (§1): the screen above, unchanged. Bluesky lives in
Settings' `BLUESKY` card (§2.35); the avatar in the header and the tab falls
back to the Bluesky avatar when the node has no photo (§1).

**Bluesky only** — no node, so no node sections; the Telegram section stands
where they would be:

```
                                              ( Settings )   btn ghost sm
(avatar 72pt)   Elijah Lucian                 (h2 — Bluesky display name, else the handle)
                @elijah.bsky.social           (mono muted; the header taps through to the profile on Bluesky)

( Compose )                                   btn primary — posts to Bluesky (§2.9)

TELEGRAM                                      (section mark)
( Sign In with Telegram )                     btn neutral sm → §2.1's Telegram steps

elijah@lucianlabs.ca                          muted, → mail composer
tgsocial 1.0 (12)                             mono faint
```

No `Edit Card`, `YOUR FEEDS`, `LISTING`, `PRIVATE` or `View as others see it`:
each is a node's, and a node is a Telegram channel. `( Compose )` is absent
while Bluesky has ended the session, until `Sign In Again` (§2.39).

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
is text only. Success toast `Posted.`; the feed refreshes. A private channel's
tab carries a faint `Private` pill (§2.28). Signed in to Bluesky, the sheet
gains `Also post to Bluesky` (§2.38). With no feeds to post to, the tabs' place
reads `No feeds yet.` (muted) — a label (§3); `( Manage )` on You is where
feeds are picked.

**Bluesky only** (§1) the sheet posts to Bluesky directly (`PROTOCOL §12.8`,
direct post) — there is no Telegram post for it to follow:

```
POST TO
Bluesky · @elijah.bsky.social                (mono muted, in the tabs' place — one destination, no control)
[ textarea, 6 rows, placeholder "Say it." ]
212 / 300                                     (mono faint)
( Add Photo )                                 (btn ghost sm — native; web is text only)
( Post )      ( Cancel )
```

- The counter is §2.38's: graphemes, `bad` past 300, `Post` disabled, and the
  line reads `Too long for Bluesky.` The app never cuts the sentence.
- One photo at most, posted as the post's image.
- Toasts: `Posted.` · `Bluesky didn't take it — <error>.` · `You're offline.`
  No retry button, for §2.38's reason.
- No `Also post to Bluesky` row: it already is.

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
Bluesky           Not signed in              (§2.35 — present with any Bluesky source)
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
- **Bluesky only** (§1): `Telegram` reads `Not signed in`, and `Connection`,
  `Node` and `TDLib` are absent — each describes a TDLib client that is not
  running (`PROTOCOL §12.11`). The pill reads `Syncing` while `Pending` is
  non-empty, `Offline` while the device has no network, else `Synced`.
  `Refresh Now` re-reads the Bluesky sources.

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
No comments from your network.                (empty, muted, full stop)
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
`YOUR COMMENTS CHANNEL` section mark, muted `It's public on Telegram.`, input prefilled `<node>_r` with the availability pill,
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
account data, no private chats, no private channels (§2.34) — a channel is
only readable here because its owner made it public on Telegram.

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
Sign in naming the destination, then lands there. A Bluesky-only app (§1)
shows the destination's screen as §2.41's Telegram card — `Sign in to Telegram
to see @<name>.` — and lands there after Telegram's sign-in.

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
14 sources                                    (mono muted)
( Review Sources )                            (btn ghost sm → list of usernames)

WRITES
Post to my feeds     [ toggle ]  Off
Comment as me        [ toggle ]  Off
Edit my card         [ toggle ]  Off

ACTIVITY
┌ card ─────────────────────────────────────┐
│ 14:02  Feed              30 posts          │  mono; newest first, last 100
│ 14:02  Node @tgs_ana     cached            │
│ 14:03  Post              Refused, read-only│  refusals in `bad`
└───────────────────────────────────────────┘
( Clear Activity )                            (btn ghost sm)
```

`Let an assistant read your feeds.` is the screen's one helper line: without
it, `Bridge` names nothing a person recognises. What each preset exposes, that
writes are off by default, and that an assistant never sees the Telegram
sign-in are `CONNECTOR.md`'s to say, not the screen's (§3).

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
- Signing out of Telegram turns the bridge off and wipes the token.

On iOS and Android the Connector tab does not exist and the bridge is not
compiled in — a phone is not a host for a local service an assistant dials.

**Bluesky only** (§1) the tab is still there — the shell does not change shape
with the account — and its body is §2.41's Telegram card, `Sign in to Telegram
to use the Connector.` with `( Sign In with Telegram )`. The bridge does not
listen: every source it serves is a Telegram channel, and Bluesky is not
something it pipes (§2.40). Signing out of Telegram turns the bridge off and
wipes the token, whether or not Bluesky stays (`CONNECTOR.md §2`).

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
Report this post.                            (h2)     — `Report this comment.` on a comment, `Report this vouch.` on a vouch (§2.25)
It's hidden here and emailed to              (muted — the consequence, one sentence)
elijah@lucianlabs.ca.

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
Their posts and comments disappear here,      (muted — the consequence, one sentence)
and they aren't told.

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
  `elijah@lucianlabs.ca` (muted, tapping opens the mail composer).
- **Sign in screen** (§2.1), one muted line under the form:
  `elijah@lucianlabs.ca` — the only screen a signed-out reader sees.
- **Settings** (§2.20), the `CONTACT` card, with the full commitment.
- **Public pages** (§2.13) carry the address in their footer.

The commitment, verbatim, in the Settings `CONTACT` card:

```
CONTACT                                      (section mark)
elijah@lucianlabs.ca                         (link row, 40pt → mail composer)
Read by a person within 24 hours.            (muted)
```

The commitment is the one line, because it is a promise a reader holds us to
rather than an explanation. What happens next is here, not on the screen:
content that breaks the rules is reported to Telegram (or Bluesky, §2.40), the
only parties that can remove it from their networks; the reader's copy is
hidden on their device the moment they report it, whether or not anyone else
acts; and a client with no server cannot delete someone else's channel, so it
does not imply a takedown it cannot perform.

### 2.20 Settings

A pushed screen, reached from You (§2.8) by `( Settings )` (ghost sm, top
right). It holds the safety lists, the contact card, and one card per network,
each with its own sign-in or sign-out. Every
list row is 40pt with the hit target as an overlay (`COMPONENTS.md` rule 6).

```
‹ Back                                          [Synced]

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

PRIVATE                                      (§2.33 — present only with a private node or a private follow)

BLUESKY                                      (§2.35 — always, outside the demo)

CONTACT                                      (§2.19)

TELEGRAM                                     (section mark — always, outside the demo)
Phone                 +1 604 ••• 0199        (list row, value mono)
( Sign Out of Telegram )                     (btn danger)
( Delete My Node )                           (btn danger — present only with a node)
```

Signed out of Telegram (Bluesky only, §1), the `TELEGRAM` card is:

```
TELEGRAM                                     (section mark)
( Sign In with Telegram )                    (btn neutral sm → §2.1's Telegram steps)
```

— no `Phone` row, no `Delete My Node`: the app created nothing on Bluesky, and
the Bluesky account is Bluesky's to delete. `PRIVATE` is absent too; a private
node is a Telegram channel.

- The screen opens on the lists themselves. The `SAFETY` paragraph that used to
  head it — the filter is always on, has no switch, and the lists live on this
  device only — is §2.18's and `PROTOCOL §7.1`'s to say, not the screen's (§3).
- **Each network signs out in its own card.** `Sign Out of Telegram` keeps its
  confirm (§4) and `Sign Out of Bluesky` its own (§2.35); either leaves the
  other signed in, and the last one out lands on Sign in (§4). `Delete My Node`
  sits below Telegram's sign-out (§2.21) — the order is deliberate: the
  reversible destructive action comes before the irreversible one, and both
  are last on the screen.
- Toasts: `Unblocked @tgs_ana.` · `Unmuted WaveLoop devlog.` ·
  `Unhidden. It's back in your feed.`
- A hidden row names its channel and message id, never the content: showing a
  preview of the thing someone reported would undo the report.
- A hidden row whose channel is also blocked or muted still lists here; the
  lists are independent and each undo only lifts its own.

### 2.21 Delete my node

Setup (§2.2) creates two public channels a person cannot remove from anywhere
else in the app, so the app removes them. Last item in Settings, in the
`TELEGRAM` card below `Sign Out of Telegram`; absent without a node, so absent
for a Bluesky-only reader. With a private node the same action removes the private channels
first, and the copy grows to say so (§2.33). What the modal no longer says on screen, and still
does: the public card other people read disappears, and the names are released
for anyone to take.

```
DELETE MY NODE                               (section mark)
Delete my node.                              (h2)
Deletes @tgs_elijah and @tgs_elijah_r and     (muted — the consequence, one sentence)
everything in them; your feeds stay.
This can't be undone.                        (muted)

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

- **Both deleted.** Telegram's local state is wiped exactly as `Sign Out of
  Telegram` wipes it (`PROTOCOL §7`), the Telegram session stays signed in, and the app lands on Setup (§2.2) with nothing
  filled in. Toast: `Your node is gone.` A Bluesky session is untouched; a
  link to the node (§2.37) ends with the card, and the record left in the
  Bluesky repo attributes nothing on its own (`PROTOCOL §12.3`).
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

### 2.22 The demo

Sign in needs a phone number and a code (§2.1). Anyone who has neither — an
App Store reviewer, or a person deciding whether to hand over their number —
sees one screen and a form. The demo is the rest of the app, running on an
invented network, with no Telegram behind it.

**It is visible, not hidden.** This repository is public, so a review-only
credential typed into the phone field would be a credential printed in the
source: it hides nothing, and a build with functionality a reviewer has to be
told about in a message is the other kind of rejection. Everything below is on
the sign-in screen where any reader can find it, which also makes it the one
route to `Delete My Node` (§2.21) that needs no account — the account-deletion
control cannot be demonstrated by someone who cannot make an account.

**The entry point.** On §2.1 **step 1 only**, below the `TELEGRAM` and
`BLUESKY` cards and above the contact line:

```
( Look Around First )                       (btn ghost, outside the cards)
```

It is ghost and it is outside both cards, so the two sign-ins stay the
screen's two filled buttons and the demo reads as the third, lesser way in. The line that used to sit
under it went with the rest of the on-screen explanation (§3): the `Demo` pill
and strip below say what the demo is from its first frame. It is absent on
step 2 (code), step 3 (2FA), the other-device and registration steps, Bluesky's
waiting state and §2.1's offer: once a sign-in is in flight the screen has one
job. Tapping it enters the demo at Feed (§2.3)
— at Feed even when the visit arrived on a public link (§2.13): that
destination is parked for the length of the demo, not spent by it, and it is
named on §2.1 again when the demo is left.

**Leaving.** The `Demo` pill (below) opens the demo sheet, whose first action is
`( Leave Demo )`; Settings (§2.20) carries the same button where the
`TELEGRAM` card sits in a real session. Either one returns to §2.1 step 1 with
both fields empty, toast `Left the demo.` Reloading the web page or relaunching the app
also leaves it, because nothing about the demo is written to disk (below).

**What is persistently obvious.** Three things, none of them dismissible:

1. **The status pill reads `Demo`** on every screen that has a topbar, in the
   neutral `HPPill` — `panel` fill, 1pt `line`, ink text — and **never gold**,
   because gold on that pill means a live Telegram connection (§1). It is a
   button like the status pill it replaces, and opens the demo sheet instead of
   the status sheet (§2.10).
2. **A strip under the topbar**, sticky with it, on every screen: full column
   width, `bg2` fill, hairline `line` below, mono small in `muted`, reading

   ```
   Demo. Everyone here is invented. Nothing leaves this device.
   ```

   It is a label under §3, not an explanation: it names the state every frame
   is in, so a cropped screenshot cannot pass for someone's real account.
   It persists into the full-screen media viewers and the carousel (§2.11) —
   the one place the topbar hides — drawn over the dark surface in the same
   mono small, because an unmarked full-screen photo is exactly the screenshot
   that could be mistaken for someone's real Telegram.
3. **The fixtures name themselves.** Every node username begins `tgs_demo_`,
   every channel username begins `demo_`, and every generated image carries its
   own key (`demo_kiln_log/224·1`) in mono `faint` in its bottom-left corner. A
   single post card, cropped out of context, still says what it is.

No fixture carries a photograph of a person. Node and channel avatars are the
initial in the display serif over a seeded tint — §2.3's third fallback,
reached honestly, since fixture channels have no photo — except
`demo_tidewright` and `demo_slow_radio`, which carry a generated plate as their
channel photo so §2.3's first branch paints too.

#### 2.22.1 The fixture world

Invented, fixed, and identical on all three builds. Nothing here is captured
from a real channel, and the captures in `web/test/fixtures/` are not reused:
those are real people's posts.

**Nodes.** Fifteen. `@tgs_demo_you` is the reader.

| Node | Name | Bio | Feeds |
| --- | --- | --- | --- |
| `@tgs_demo_you` | Demo Reader | Looking around. | `@demo_you_notes` |
| `@tgs_demo_wren` | Wren Alderiss | Tide clocks and bad solder. | `@demo_tidewright`, `@demo_wren_bench` |
| `@tgs_demo_mox` | Mox Petrakis | Field recordings. Mostly rain. | `@demo_slow_radio` |
| `@tgs_demo_juno` | Juno Bell-Okafor | Ceramics, mostly failures. | `@demo_kiln_log` |
| `@tgs_demo_pell` | Pell Nakagawa | Letterpress, one press. | `@demo_press_run` |
| `@tgs_demo_arto` | Arto Vansi | Trail cameras on the creek. | `@demo_creek_cam` |
| `@tgs_demo_orrin` | Orrin Baptiste | Bread, weather, complaints. | `@demo_proof_box` |
| `@tgs_demo_sable` | Sable Quiring | Maps nobody asked for. | `@demo_paper_maps` |
| `@tgs_demo_bly` | Bly Toussaint | Night sky, cheap lens. | `@demo_dark_sky` |
| `@tgs_demo_hask` | Hask Oyelaran | Fixes the ferry radio. | `@demo_ferry_net` |
| `@tgs_demo_ilka` | Ilka Ferreira | Bike frames. | `@demo_frame_jig` |
| `@tgs_demo_crate` | Crate Mailer | Free crates. Ask me. | `@demo_free_crates` |
| `@tgs_demo_lume` | Lume Adeyemi | Neon repair. | `@demo_neon_bench` |
| `@tgs_demo_noor` | Noor Salk | Weather balloons. | `@demo_balloon_log` |
| `@tgs_demo_veda` | Veda Marchetti | Sails. | `@demo_sail_loft` |

The reader's card, serialised per `PROTOCOL §2`, is the shared vector the three
builds parse:

```
tgsocial v1
name: Demo Reader
bio: Looking around.
public: no
feeds: @demo_you_notes
follows: @tgs_demo_wren @tgs_demo_mox @tgs_demo_juno @tgs_demo_pell
replies: @tgs_demo_you_r
```

`public: no`, so the reader is absent from the Directory the way §2.4 requires.
`@tgs_demo_you_r` exists and is empty. Every other node has `public: yes` and a
`replies:` channel `<node>_r`.

**The follow graph**, which is the whole of Explore and Graph:

| Node | Follows |
| --- | --- |
| `you` | `wren`, `mox`, `juno`, `pell` |
| `wren` | `mox`, `arto`, `sable`, `ilka` |
| `mox` | `juno`, `arto`, `bly` |
| `juno` | `pell`, `wren`, `orrin` |
| `pell` | `sable`, `hask`, `orrin`, `crate` |

So `DIRECT · 4` and `+1 · 7` on Graph (§2.7). Explore's NEARBY (§2.4) is those
seven ranked by mutual count, ties broken by username ascending: `arto` (2),
`orrin` (2), `sable` (2), `bly` (1), `crate` (1), `hask` (1), `ilka` (1). The
DIRECTORY is the three nodes in no walk — `lume`, `noor`, `veda`. Searching an
exact `tgs_demo_*` username opens that profile; anything else toasts
`Not a tgsocial node.`

`demo_tidewright` and `demo_kiln_log` carry the `tgsocial: @<node>` backlink
(`PROTOCOL §3`) and show the `Verified` pill; the rest do not, so both states
are on screen.

**Posts.** Fifteen across six sources — the reader's feed plus the five feeds
of the four nodes they follow, and those six are the whole of the post table
below. The +1 nodes have feeds and no posts: `@demo_creek_cam` is listed on
`arto`'s profile, is never in Feed, and opens on §2.6's empty channel. That is
the point being made — the merge is the follow graph and nothing else, so a feed
one walk out is a feed the reader has to go and find. An empty channel is a real
state of the app rather than an error, and the demo sheet's `15 posts` counts
the table and only the table.

Times are **offsets from the moment the demo starts**, never fixed dates, so
the §2.3 relative-time ladder reads correctly in a review a year from now.
Newest first, which is the order Feed paints them:

| # | Source | Id | Age | Content |
| --- | --- | --- | --- | --- |
| 1 | `demo_tidewright` | 147 | 40 s | Text. `Tide clock is off by nine minutes and I know exactly why.` |
| 2 | `demo_slow_radio` | 101 | 6 min | **Audio** 3:42, title `Rain on the shed roof`, performer `Slow Radio`. Body `Three in the morning, and it did not let up.` |
| 3 | `demo_kiln_log` | 224 | 22 min | **Album, four photos** (4:3, 3:4, 1:1, 16:9). `Glaze tests. Two of these are the same glaze.` |
| 4 | `demo_press_run` | 72 | 2 h | **Link preview** — `A Short History of the Em Dash` / `Why the long dash outlived the metal it was cast in.` / `example.com`. Body `Found this while cleaning out a drawer.` |
| 5 | `demo_wren_bench` | 17 | 5 h | Text + **document** row `tide-table-1971.pdf · 2.4 MB`. |
| 6 | `demo_you_notes` | 2 | 9 h | Text, **the reader's own**. `Testing the demo. This one is mine.` |
| 7 | `demo_slow_radio` | 95 | 14 h | **Video** 0:18. `The ferry leaving in fog.` |
| 8 | `demo_tidewright` | 144 | 1 d | Text, **five comments**. `New moon. Everything in the harbour is six inches lower than it should be.` |
| 9 | `demo_kiln_log` | 219 | 2 d | **One photo** (1:1), **six comments**. `Failure on the left.` |
| 10 | `demo_press_run` | 71 | 3 d | **Voice note** 0:47, with waveform bytes. |
| 11 | `demo_wren_bench` | 12 | 6 d | Text. `Ordered the wrong solder again.` |
| 12 | `demo_slow_radio` | 88 | 2 w | **Animation**, 2 s loop, muted, autoplaying. |
| 13 | `demo_kiln_log` | 203 | 5 w | Text. `Kiln is at cone six and holding.` |
| 14 | `demo_press_run` | 58 | 4 mo | Text. `The press is level. It only took a year.` |
| 15 | `demo_you_notes` | 1 | 2 y | Text. `First post.` |

Every rung of §2.3's ladder — `now`, `6m ago`, `22m ago`, `2h ago`, `1d ago`,
`2w ago`, `4mo ago`, `2y ago` — is on that list, so a wrong rounding is
visible without arithmetic. Every age is an exact multiple of its unit, so the
world's clock is the **start of the minute the demo was entered in**, not the
instant: a card renders its relative time on a minute tick and floors, and
against an instant that tick trails by up to 59 s and paints `5m` where the
table says `6m`. Anchoring the offsets to the tick is what makes the table a
statement about the screen. Reactions and views derive from the id rather than
being invented per row, so all three builds print the same figures:
`reactions = (id × 7) mod 23`, `views = 60 + (id × 37) mod 900`. The comment
count is the real count from the index below.

The demo pages **eight posts at a time**, so Feed loads a second page and then
says `That's everything.` — pagination is exercised, and so is §2.18's rule
that a fully-filtered page fetches the next one.

**Comments** (`PROTOCOL §6`), eleven, network-scoped exactly as the real client
scopes them. On post `demo_tidewright/144`:

| Comment | Age | Targets | Body |
| --- | --- | --- | --- |
| `demo_mox_r/31` | 22 h | the post | `Six inches is the whole reason I stopped trusting that gauge.` |
| `demo_wren_r/40` | 21 h | `demo_mox_r/31` | `The gauge is fine. The pier moved.` |
| `demo_mox_r/32` | 20 h | `demo_wren_r/40` | `Then the pier moved.` |
| `demo_juno_r/9` | 19 h | the post | `Photograph the pier or it didn't happen.` |
| `demo_crate_r/12` | 18 h | the post | `FREE CRATES today only, message me for the link.` |

`crate` is reached at +1 (through `pell`), so their comment is in scope and
carries the `+1` neutral pill (§2.12). It is also the thing a reviewer reports
and blocks.

On post `demo_kiln_log/219`, one chain six deep, so the depth-5 cap flattens
its last row: `demo_wren_r/41` (`Which one is the failure?`) → `demo_juno_r/10`
(`Both.`) → `demo_wren_r/42` (`Then it worked.`) → `demo_juno_r/11`
(`It cracked.`) → `demo_mox_r/33` (`It always cracks.`) → `demo_wren_r/43`
(`Agreed.`), ages 47 h down to 42 h.

`@tgs_demo_you_r` is empty: the reader has never commented, and commenting is a
write (§2.22.3), so the `YOUR COMMENTS CHANNEL` card in §2.12 never appears.

**Media is generated, never bundled.** Every image, clip and waveform is
produced in-process from the item's key as a seed, so the world is the same
everywhere without shipping a byte of anyone's content:

- **Photos** are a plate at the item's aspect: a linear gradient between two
  House Pour tokens chosen by the seed, a handful of seeded circles and bars
  over it, and the item key in mono `faint` bottom-left. Deterministic per
  platform; not pixel-identical between platforms, which does not matter — the
  contract is the same world, not the same pixels.
- **Audio** is synthesised at the strip's decimated rate (§2.11.1): a pink-noise
  bed near −24 dBFS, a 220 Hz → 880 Hz log sweep from 0:30 to 0:38, and two
  40 ms clicks a minute. Broadband plus tonal, so the spectrogram has structure
  to draw and the one-pole envelope has a silhouette rather than a rectangle.
  Generated lazily on first play, off the main thread, like any other clip.
- **The voice note** ships Telegram-shaped waveform bytes in the fixture, so
  §2.11.2's draw-immediately-then-analyse path is the one that runs.
- **Video and the animation** are procedural frame sources, not decoded files:
  a moving House Pour bar at 12 fps against a real transport, with a real
  poster, duration pill, scrubber, full-screen player and pause-on-scroll-off.
  Shipping an mp4 into three app bundles to prove a transport works is more
  binary than the feature is worth, and a decoded file exercises nothing the
  frame source does not.
- **The link preview's** thumbnail is a plate, its host is `example.com`
  (reserved, RFC 2606), and tapping it does not navigate (§2.22.3).

#### 2.22.2 What still works, because it has to

The §1.2 safety controls work against the fixtures, in full, with the real
code paths — a demo that cannot exercise report, block, mute and the default
filter proves nothing about them.

- **Report** (§2.15) opens the same seven-reason sheet, hides the item
  immediately, lists it in Settings → `HIDDEN`, and opens the platform's mail
  composer prefilled per §2.15 with one line added at the top of the body:
  `Demo: this report is from the demo and the link is invented.` §2.15 says the
  app adds nothing else, and this is the one exception, written down: without
  it the operator opens their inbox and goes looking for a channel that does
  not exist.
- **Block** (§2.16) and **mute** (§2.17) behave exactly as specified, confirm
  copy and toasts included, and the blocked node's profile is the §2.16 blocked
  card.
- **The filter** (§2.18) runs at render on every surface. It is checkable by
  counting: blocking `@tgs_demo_crate` takes post 144's footer from
  `5 comments` to `4 comments`, drops the `crate` row from Explore's NEARBY,
  and takes Graph from `+1 · 7` to `+1 · 6`. Muting `Slow Radio` takes Feed
  from 15 posts to 12 while `@demo_slow_radio`'s own screen stays complete and
  the feed row on Mox's profile gains the faint `Muted` pill.
- **Settings** (§2.20) shows those lists with working `Unblock`, `Unmute` and
  `Unhide`, and every surface repaints on the next render.
- **Delete my node** (§2.21) runs the whole flow — the modal naming
  `@tgs_demo_you` and `@tgs_demo_you_r`, the type-to-confirm, the comments
  channel first — against the fixture world. This is the point of the demo
  being visible: Guideline 5.1.1(v) asks for an in-app way to delete the
  account, and nobody who cannot make an account can reach it any other way.
  One deviation from §2.21's outcome, because a demo has no session to survive:
  on success the demo ends and the app lands on §2.1, toast
  `Your node is gone. The demo is over.`

#### 2.22.3 What is disabled

Everything that writes to Telegram: `Post`, `Comment`, `Reply`, `Follow` /
`Unfollow`, `Edit Card`, the feed toggles and their `Verify`, `Make Channel`,
the `Public listing` toggle, `Announce in Directory`, `Create Node`, and — on
the Mac build — the Connector bridge toggle and its three write grants (§2.14),
since a bridge serving fixtures over a real socket is an assistant being told
invented things by a real port.

**No write control is hidden or greyed out.** Each one stays exactly where it
is, stays tappable, and answers with a toast. A disabled button teaches
nothing and reads as a broken app; a toast names the boundary:

```
The demo doesn't write to Telegram.
```

Manage feeds (§2.2) therefore lists the reader's own feed — read off the
fixture card's `feeds:` line, never queried — because an empty candidate list
paints that card's `No channels you can post to.` and takes the toggles and
their `Verify` off the screen with it. That line is also false one tap from a
You screen listing `Notes`.

Two other things are refused, each with its own line, because each is a
different truth:

- `Open in Telegram`, `Copy Link` and `Share`, anywhere they appear:
  `Nothing here is on Telegram.`
- A link, a link preview, or a `t.me` link in post text:
  `Links don't open in the demo.`

`Sign Out` is not in the demo at all, and neither network's card is: Settings
carries `( Leave Demo )` (btn neutral) where the `TELEGRAM` card would be,
above `( Delete My Node )` (btn danger). A demo is not signed in to anything
(§1), so it has nothing to sign out of or in to.

#### 2.22.4 No network, and how that is guaranteed

The demo makes no request, of any kind, to anything. This is the claim a
reviewer's proxy can falsify, so it is a property of the build rather than a
discipline at each call site:

- **The client is off the network before the first fixture paints.**
  `Look Around First` is only on §2.1 step 1, so nothing is in flight when it is
  tapped. iOS and web construct their TDLib handle lazily and `close` any handle
  that does exist on the way in, so the demo runs with no client at all. Android
  cannot: it builds the handle in `Application.onCreate`, because the
  authorization state is what decides whether the first screen is sign-in or the
  feed, and sign-in is the screen the demo is entered from. It hands TDLib
  `networkTypeNone` instead and **waits for the acknowledgement** before the demo
  opens, which stops TDLib's own connection and every retry behind it. The claim
  a reviewer's proxy can falsify is the same on all three, and it is the one the
  store listing makes: nothing leaves the process while the demo runs.
- **The demo is a different object, not a mode.** All three builds already
  reach data through one interface — `Repo` on web, the model's source on iOS,
  the repository on Android. The demo substitutes the whole implementation with
  `DemoRepo`, which holds no reference to the TDLib client. A boolean checked at
  each call site has branches that can be missed; a substituted object has no
  code path to Telegram to miss in the first place.
- **`DemoRepo` imports nothing from the TDLib layer**, and that is the
  build-time check: each platform's test asserts that the demo sources import
  no symbol from `web/js/td.js` / the iOS `TD` module / the Android `td`
  package. It is a grep, it runs in the build, and it fails the build.
- **Media cannot reach the network** because fixture media has no file id.
  `downloadFile` is not reachable from `DemoRepo`; the generators are.
- **Web asserts it end to end**, in the shipped `npm test`.
  `web/test/smoke.mjs` boots the real bundled tdweb, waits for a real client to
  exist, enters the demo, walks Feed, a thread, a profile and a full-screen
  photo, and asserts zero requests to any origin but the page's own, every
  socket the client had closed while the demo runs, and no TDLib client
  constructed from the tap onward — having first asserted that one was
  constructed at boot, so the count is known to be measuring something. Against
  a mocked tdweb none of that would mean anything: a mock makes no request
  either way.

The one thing that leaves the device is the report email (§2.22.2), which the
reader's own mail client sends. The app hands the composer a `mailto:` and
makes no request itself.

#### 2.22.5 The demo sheet, and how it ends

Tapping the `Demo` pill opens a House Pour modal in the status sheet's place:

```
DEMO                                         (section mark)
You're in the demo.                          (h2)

Nodes             15                          (list rows, values mono)
Feeds             6 sources · 15 posts
Network           4 direct · 7 at +1
Telegram          Not connected
( Leave Demo )                               (btn primary)
( Close )                                    (btn ghost)
```

`Telegram · Not connected` is the row that answers the reviewer's question
without them having to take our word for §2.22.4.

**Leaving persists nothing.** `DemoRepo` holds the entire world in memory and
writes to none of the homes a real session uses — no card cache, no feed cache,
no cursors, no comment index, no UI preferences, nothing keyed under `LS` /
`LocalStore` / the Preferences DataStore. `Leave Demo` drops the object and
returns to §2.1. There is no cleanup step to get wrong, because there is
nothing on disk to clean up, which is also why relaunching leaves the demo.

**The safety lists are the one piece of demo state that has to live**, since
block, mute and report must survive a screen change and show up in Settings.
`PROTOCOL §7.1` keys that record to the Telegram `userId` that wrote it, and a
demo has no Telegram user. So the demo keeps a record **of the same shape, in
memory, with `userId: null`, and a `userId: null` record is never written to
any of §7.1's three homes.** The real record is not loaded into the demo
session either. Both directions matter: a demo block of `@tgs_demo_crate` must
not turn up in a real account's list, and a real account's blocks are not
someone's demo to browse.

### 2.23 Work — the card, and where it is edited

`PROTOCOL §10` adds four optional keys to the card. This is the surface they
get, and the shape of that surface is the same argument the protocol section
makes: **work is a layer on the network, not a second network.** There is no
fifth tab, no separate sign-in, no parallel profile. A person who never fills a
work key never sees any of it, and their profile looks exactly as it does
today — the UI is additive because the protocol is.

The word is **work**. Never "professional", never "career", never "job" as a
noun for the surface. The product does not have a second name.

#### The work card on a profile

On the node profile (§2.5), between the bio/link block and `FEEDS`. **Absent
entirely** when the node has no work keys and no vouches this reader can see —
no empty section, no "not set up yet", nothing.

The vouch half of that condition is not a hedge, it is `PROTOCOL §10.4`: a
vouch is the voucher's sentence, written in the voucher's own channel, and the
subject cannot edit it — **including by editing their own card**. Gate the
section on `work.` keys alone and clearing your card deletes what somebody else
wrote about you from every screen, which is the one thing §10.4 exists to
prevent; worse, the person it is about is the one who cannot see it, and
`VOUCHED, NOT CLAIMED` is exactly the case that reader is owed. So a node with
no work keys and at least one vouch in scope renders `WORK`, then
`VOUCHED, NOT CLAIMED` and its tags, and nothing else — no role line, no intent
pill, no claimed-tag card, because the node claimed nothing.

```
WORK                                          (section mark)
Staff product architect at Lucian Labs        (body)
[ Open to contract ]  until 1 Dec             (HPPill gold, then HPMonoSmall faint)

┌ card ──────────────────────────────────────┐
│ live sound                Vouched by 2  ›  │  HPListItem: tag body, count HPSmall muted
│ swift                                      │  a tag with none carries no trailing text
│ product architecture      Vouched by 1  ›  │
└────────────────────────────────────────────┘

VOUCHED, NOT CLAIMED                          (section mark; only when non-empty)
┌ card ──────────────────────────────────────┐
│ front of house            Vouched by 1  ›  │
└────────────────────────────────────────────┘

( Vouch for Ana )                             (btn neutral sm)
```

- The role line is **body text, undecorated**. No pill, no tick, no badge. It
  is a self-claim exactly like the bio two lines above it, and it must not
  borrow the visual language of the `Verified` pill (`PROTOCOL §10.8`).
- The intent pill is the one gold thing in this card and appears only when
  `work.open` is current (`PROTOCOL §10.3`). Its four strings, verbatim:
  `Open to work` · `Open to contract` · `Hiring` · `Open to collaborate`.
  Beside it, mono faint: `until 1 Dec` — day and month, derived from the date,
  the year appended only when it is not this one. Expired or over the horizon:
  the pill and the date are simply not drawn.
- A tag row with vouches taps through to the Vouches screen (§2.25). A row with
  none is not a control: no chevron, no hit target, no press state.
- `VOUCHED, NOT CLAIMED` holds tags nobody claimed but someone vouched
  (`PROTOCOL §10.4`). It is how a person finds out what they are known for.
- `Vouch for <name>` is absent on my own profile and on a blocked node's.

Empty states inside a present work card:

- Tags but no vouches anywhere, under the tag card, muted:
  `No vouches from your network.`
- **My own work card, no vouches**, under the tag card, muted:
  `No vouches from your network yet.` The word `network` is the whole of the
  caveat on screen: a vouch from someone the reader cannot reach is not seen
  (`PROTOCOL §10.5`), and the label says whose vouches these are rather than
  implying there are none anywhere.

#### Editing: the Edit Card modal grows a section

`( Edit Card )` on You (§2.8). The existing `NAME` / `BIO` / `LINK` fields are
unchanged; below them:

```
WORK                                          (section mark)

ROLE                                          (field label)
[ Staff product architect at Lucian Labs ]    (input; hard cap 80)
80 / 80                                       (faint, right, from 60 characters on)

WHAT YOU DO                                   (field label)
[ swift, product architecture, live sound ]   (input)
Up to twelve, separated by commas.            (faint)

OPEN TO                                       (field label)
[ Nothing  Work  Contract  Hiring  Collab ]   (.tabs, five items)
FOR                                           (field label; absent while Nothing)
[ 30 days  60 days  90 days ]                 (.tabs, three items)
Ends 5 Dec 2026.                              (faint; the date derived, never typed)

WORK FEEDS                                    (section mark)
┌ card: one row per feed on my card, each with an HPToggle ┐
You have no feeds yet.                        (empty, muted; → §2.2's feeds card)

( Save )                                      (btn primary)
```

Refusals and toasts, verbatim:

- Pasting a role over 80 characters: the field takes the first 80, faint under
  it reads `Trimmed to 80.`
- More than twelve tags on Save: `Twelve at most. The rest were dropped.`
- A tag the grammar refuses (`PROTOCOL §10.2`), on Save:
  `Dropped "live/sound". Letters, numbers, spaces, and + # . - only.`
- The card would pass 4096 characters: the existing refusal, unchanged, plus
  one muted line under it:
  ```
  Card is full. Shorten your bio or drop a tag.
  ```
- Offline: `You're offline.` Save is not attempted.
- Success: `Card saved.`

A client that writes the card for any other reason — a follow, a feed change —
writes the work lines back with it (`PROTOCOL §10.6`). This is not visible
anywhere and it is the single most important line in this section.

#### The reminder, which is the only nag

`work.open` expires on its own, and a person who forgets is invisible without
being told. On You (§2.8), above `LISTING`, when my own intent has expired or
expires within seven days:

```
Your Open to contract ends in 3 days.   ( Edit Card )    (muted row, btn ghost sm)
Your Open to contract has ended.        ( Edit Card )
```

One row, no badge, no red, dismissible by acting or by ignoring it. It never
appears on anyone else's screen and there is no notification.

### 2.24 The work feed

Elijah's ask was "a custom feed, but with different features — more forward to
the thing, but it's still effectively a social thing." Both halves are product
decisions and both are made here.

#### It is a mode on Feed, not a tab

Feed (§2.3) grows a two-item `.tabs` control, sticky under the topbar, full
column width less the side padding, `bg2` track, **no shadow** — the floating
tab bar (§1) is the raised pill on this screen and there is only one of those:

```
[ All   Work ]
```

Why a mode and not a fifth tab: a tab would say there are two networks, and
there is one. The same nodes, the same follows, the same cards, read two ways —
which is the whole claim `PROTOCOL §10` is built to prove. A tab also implies a
place to go and be seen; a mode implies a way to look. The second is what this
is.

**The control appears only when at least one node in my `follows:`, or I,
carry a `work.feeds` entry.** A reader whose network has no work in it sees
Feed exactly as it is today. Same rule as the profile: the surface is additive
or it is not additive.

The mode is remembered (`PROTOCOL §7`, UI preferences) and the control is
visible in both modes, so it is never a state someone is stuck in.

#### What Work mode shows

Two things, in this order, and the first is the reason the mode exists.

**1. Open now.** Current intent (`PROTOCOL §10.3`) from me, my follows, **and
my +1**:

```
OPEN NOW · 3                                  (section mark, serif count)
┌ card ──────────────────────────────────────┐
│ (avatar) Ana Iliovic     [ Open to work ] › │  NodeRow shape; pill gold
│          until 1 Dec · live sound, swift    │  mono faint · muted, first three tags
│ (avatar) Bly Toussaint   [ Hiring ]  +1   › │  neutral +1 pill, as §2.12 uses
│          until 12 Nov · night sky           │
└────────────────────────────────────────────┘
```

Ordered by end date **ascending** — soonest first — ties broken by username
ascending. Specified because three platforms otherwise produce three orders,
and because "what expires first" is the only ranking this app has ever needed:
it is derived from the data, not scored.

+1 is included here and nowhere else in this mode. Intent is a small structured
line on a card the client already fetched for Explore and Graph (§2.4, §2.7), so
reaching one hop further costs nothing; walking +1's feed history would cost a
fetch per channel. A hiring notice one hop out is exactly the case worth the
extra hop, and a post one hop out is not.

Empty: `Nobody in your network is open right now.`

**2. The work column.** Post cards (§2.3, unchanged — same card, same
attribution, same long-press sheet) from the `work.feeds` of me and my
follows, merged newest-first exactly as §4.8 merges. Not +1.

Suppressed: every post from a feed nobody marked as work. That is the entire
filter. There is no scoring, no promotion, no "relevant to you".

Empty: h2 `No work posts yet.` and `( Edit Card )` btn accent.

#### A work post is an ordinary post, and this was the decision

Two ways to build this, and the cheap one is also the right one.

**Marking posts** would need a new post format — a magic first line the way
`re:` is one — which puts protocol scaffolding in front of every plain-Telegram
reader of that channel, asks the author to classify each post as they write it,
cannot be applied to the six years of posts already in the channel, and cannot
be corrected later without editing every message.

**Marking feeds** costs one card line, is reversible in a toggle, applies
backwards and forwards at once, and needs no post format at all — which is why
a client that has never heard of `PROTOCOL §10` still shows every one of these
posts, in All, correctly attributed, today. It also runs with the grain of the
substrate: Telegram users already sort their output by channel, because a
channel is the thing you subscribe to.

The cost, stated: a person who posts work and life in one channel gets
all-or-nothing. The answer is a second channel, which on Telegram is free and
ordinary, and which the app already knows how to list (§2.2). We take that
cost.

#### Finding people by what they do

Explore (§2.4) keeps its one search field. A query that is not a username now
also matches `work.does` across every card the client has read — my follows, my
+1, and the directory (`PROTOCOL §10.7`). A new section, above `NEARBY`, shown
only when the query matched something:

```
WHAT THEY DO                                  (section mark)
(avatar) Ana Iliovic             ( Follow )
         @tgs_ana · live sound · Followed by 3 of yours
```

The search reaches the cards the client can reach — the network and the
directory — and there is no global search (`PROTOCOL §10.7`). That used to be a
permanent faint line under the section; it is here instead (§3). The empty
state, `Nobody you can reach lists that.`, carries it.

Empty: `Nobody you can reach lists that.`

The safety filter (§2.18) applies to every surface in this section without
exception: a blocked node is absent from `OPEN NOW`, from `WHAT THEY DO`, and
from the work column, and leaves no gap and no residue in a count.

### 2.25 Vouching

A vouch is one person saying one thing another person can do
(`PROTOCOL §10.4`). It lives in the voucher's comments channel, so the subject
cannot write it, edit it, or take it down — which is the only reason it is
worth anything.

#### Writing one

`( Vouch for Ana )` on the work card (§2.23) opens a modal:

```
VOUCH                                         (section mark)
Say one thing Ana does.                       (h2)
Public, under your name.                      (muted — the consequence)

WHAT ANA DOES                                 (field label)
[ live sound ] [ swift ] [ product architecture ]   (pills, single-select, 40pt targets)
[ Something else ]                            (pill; selecting it reveals the input below)
[ front of house              ]               (input, hidden until Something else)

[ textarea, 4 rows, placeholder "Why." ]

( Post Vouch )   ( Cancel )                   (btn-row: primary + ghost)
```

- The field label uses the subject's name, not a pronoun the app does not know:
  `WHAT ANA DOES`. It is set from the node's display name, uppercased by the
  section-mark style, and falls back to `WHAT THEY DO` when the card has no
  `name`.
- The chips are the subject's own `work.does`, in card order, plus
  `Something else`. A node with no `work.does` shows only `Something else`,
  with the input already revealed — you can vouch for someone who has claimed
  nothing.
- The body is optional. `Why.` is the placeholder and the whole of the prompt.

Refusals, verbatim:

- Nothing selected: `Post Vouch` is disabled, faint under the row:
  `Pick one thing.`
- A custom tag the grammar refuses: inline faint under the input,
  `Letters, numbers, spaces, and + # . - only.`; the button stays disabled.
- Already vouched them for that thing: the chip reads `Vouched` in the ghost
  style and is not selectable, faint under the row:
  `You already vouched Ana for live sound.` A second identical vouch is noise,
  and the count it would inflate is not a count anyone should trust anyway.
- On my own profile the control does not exist. Reached by deep link anyway:
  toast `You can't vouch for yourself.` and the modal does not open.
- **No comments channel yet**: the modal first shows §2.12's
  `YOUR COMMENTS CHANNEL` card, verbatim and unchanged — same copy, same
  availability pill, same `( Make Channel )`. It is the same channel
  (`PROTOCOL §10.4`), so it is the same card, not a second one that says
  nearly the same thing.
- Offline: `You're offline.`

Success: toast `Vouched.` The vouch is optimistic in the subject's work card
the same way a comment is (§2.12), settling or rolling back.

#### Reading them

Tapping a tag row pushes the **Vouches screen**:

```
‹ Back                                          [Synced]

live sound                                    (h1 — the tag, as written)
Ana Iliovic                                   (mono muted — who it is about)

VOUCHES · 2                                   (section mark, serif count)
┌ card ──────────────────────────────────────┐
│ (avatar) Bob Vance              Mar 2026   │  name body → profile; date mono faint
│ Ran front of house for two years. Never    │  body; empty bodies render the row alone
│ missed a cue.                              │
│                                            │
│ (avatar) Wren Alderiss     +1   Aug 2024   │  neutral +1 pill for nodes I don't follow
│ Ran sound for the ferry sessions.          │
└────────────────────────────────────────────┘
```

**The date is a month and a year, not a relative time.** Everywhere else in
this app time is relative (§2.3) because a post's recency is what matters. A
vouch is the opposite: `2y ago` buries exactly the thing a reader is weighing,
which is whether this was last year or half a career ago. Ordered newest first.

Long-press a vouch (web: long-press or right-click) opens the **vouch sheet** —
§2.12's comment sheet with two strings changed: `Feed` names the voucher's
comments channel, and `SAFETY` reads `Report Vouch` and `Block @tgs_bob`. No
`Mute`. On my own vouch the sheet carries `Delete` instead of `Report Vouch`,
with the confirm modal `Delete this vouch?` `Report Vouch` opens §2.15's report
confirm unchanged, with its h2 reading `Report this vouch.` — a button that
names the thing and a modal that asks about "this post" is two names for one
object.

**A vouch someone wrote about me, that I do not want.** It is in their channel
and I cannot reach it. The sheet, on my own work card, carries one muted line
above the `SAFETY` block:

```
You can't remove a vouch someone wrote. Report it or block them.
```

This is not a new exposure: §6 already lets anyone point at my post from their
own channel, and §2.15–§2.17 are already the answer — report it, hide it here,
block the node. `PROTOCOL §10.8` is why the format has no negative vouch to
make this worse.

Empty (reachable only when the last vouch was deleted between renders):
`No vouches from your network.`

### 2.26 Work in the demo

§2.22's fixture world gains work data, so a reviewer who never signs in still
sees every branch of §2.23–§2.25. Six of the fifteen nodes carry it; the
reader, `@tgs_demo_you`, carries **none** — the first thing the demo shows about
work is the empty state on your own card.

| Node | `work.role` | `work.does` | `work.open` | `work.feeds` |
| --- | --- | --- | --- | --- |
| `@tgs_demo_wren` | Tide clocks, built one at a time | electronics, tide clocks, bad solder | `contract` +45 d | `@demo_wren_bench` |
| `@tgs_demo_mox` | Records rain for a living | field recording, sound design | — | `@demo_slow_radio` |
| `@tgs_demo_juno` | Production potter, small kiln | ceramics, glaze chemistry | `work` +20 d | `@demo_kiln_log` |
| `@tgs_demo_pell` | Letterpress, one press | letterpress, typesetting | `hiring` +60 d | `@demo_press_run` |
| `@tgs_demo_hask` | Fixes the ferry radio | marine radio, antennas | `collab` +8 d | `@demo_ferry_net` |
| `@tgs_demo_ilka` | Frame builder | frame building, brazing | — | `@demo_frame_jig` |

`+N d` is **N days after the demo is entered, computed at entry** — never a
literal date in a fixture file. A hardcoded date rots into an expired intent and
then §2.24's `OPEN NOW` is permanently empty, which is a fixture that tests
nothing. This is the same derive-never-recall rule §2.3's relative times follow.

`OPEN NOW` therefore paints, in order: Hask (+8, a +1 node — the pill is
exercised), Juno (+20), Wren (+45), Pell (+60, `Hiring`).

Five vouch fixtures, and the fifth is the point:

| In | About | `does:` | Body |
| --- | --- | --- | --- |
| `@tgs_demo_wren_r` | `@tgs_demo_juno` | glaze chemistry | Fired my clock faces for a year. Nothing cracked. |
| `@tgs_demo_mox_r` | `@tgs_demo_wren` | tide clocks | Built the clock in my studio. Still right. |
| `@tgs_demo_juno_r` | `@tgs_demo_wren` | bad solder | I've seen worse. Not much worse. |
| `@tgs_demo_pell_r` | `@tgs_demo_juno` | kiln repair | Got my kiln lit the night before a show. |
| `@tgs_demo_wren_r` | `@tgs_demo_wren` | tide clocks | Nobody does this better. |

Which exercises, in one screen each: a claimed tag with a vouch, a claimed tag
with none (`swift`-shaped rows on Juno and Wren), `VOUCHED, NOT CLAIMED`
(`kiln repair`, which Juno does not claim), and — the fifth row — a **self-vouch
that MUST NOT render anywhere** (`PROTOCOL §10.4`). It is in the fixtures
precisely so that a client which forgot that rule fails visibly, on all three
platforms, without anyone writing a test for it.

### 2.27 Private — what it is, and making your private node

`PROTOCOL §11` adds a private layer: a second channel of yours with no
username, where Telegram lets in only the people you approve. This is the
surface, and the shape of it is the protocol's argument again — **private is a
layer on your node, not a second account.** No fifth tab, no separate sign-in,
no second profile. A person who never makes a private node never sees any of
this, and the app looks exactly as it does today.

The word is **private**. It means one thing here — Telegram membership, owner
approval — and the copy says so where it matters. Never "encrypted", never
"secure", never "secret", never "close friends": each of those promises
something this does not do (`PROTOCOL §11.9`).

**Where it starts.** You (§2.8) gains one section between `LISTING` and
`View as others see it`:

```
PRIVATE
Nothing private yet.                          (muted)
( Make a Private Node )                       (btn neutral sm)
```

Tapping it opens the confirm, every time — this modal is not skippable and has
no "don't show again":

```
PRIVATE NODE                                  (section mark)
Make your private node.                       (h2)
People you approve can read everything in     (muted — the consequence, one sentence)
it, and so can Telegram.
( Make It )                                   (btn primary)
( Cancel )                                    (btn ghost)
```

- The sentence is the consequence, and it names Telegram on purpose: a confirm
  that said only "people you approve" would promise end-to-end encryption by
  omission (`PROTOCOL §11.9`). The rest of what private means — members can
  screenshot and forward, a new member sees the whole history, the public card
  notes that a private node exists (`PROTOCOL §11.3`, switched off in §2.33) —
  is this spec's and the docs', not the modal's (§3).
- `Make It` runs `PROTOCOL §11.4.1` with the pill at `Syncing` and the pending
  row reading `Making your private node`. On success the modal closes onto the
  Private screen (§2.28) with the invite sheet (§2.29) already open, because the
  next thing anyone does with a private node is hand somebody the way in.
  Toast: `Your private node is ready.`
- No public node yet: the section is absent from You, because You without a
  node is Setup (§2.2) and a private node needs a public one to point at
  (`PROTOCOL §11.1`).
- Errors surface TDLib's text verbatim. Offline: `You're offline.`

### 2.28 The private card, and private feeds

A pushed screen, `‹ Back`, reached from the `PRIVATE` section of You once a
private node exists — the section then reads:

```
PRIVATE
Elijah · private                  3 members   (title body; count mono muted)
2 requests                                    (mono; gold when > 0; absent when 0)
( Open )                                      (btn neutral sm)
```

The screen:

```
‹ Back                                          [Synced]

(avatar 72pt)                                    ⋮
Elijah · private                                 (h2)
private node of @tgs_elijah                      (mono muted)
3 members · 2 requests                           (mono faint; requests gold when > 0)

( Share Invite )                                 (btn primary — the one gold action)
( Requests · 2 )                                 (btn neutral; reads `Requests` at 0)

PRIVATE FEEDS
┌ card ─────────────────────────────────────┐
│ Elijah · private          3 members    ›  │  the node itself, always first, not removable
│ Band notes                 2 members    ›  │  → feed channel screen (§2.6, private variant)
└───────────────────────────────────────────┘
( Add a Private Feed )                           (btn ghost sm)

MEMBERS · 3                                      (section mark, serif count)
┌ card ─────────────────────────────────────┐
│ (avatar) Ana Iliovic          ( Remove )  │  Telegram name body, @handle mono muted under
│          @anailiovic · since 4 Sep        │
└───────────────────────────────────────────┘
```

- The kebab holds `Open in Telegram` and `Revoke Invite` (§2.29). No
  `Copy Link`: the only link this channel has is the invite, and the invite
  has its own button with its own warning.
- `MEMBERS` is `PROTOCOL §11.4.10`'s list. Rows show the Telegram account —
  name, username, join date — because that is what Telegram knows; the app
  does not guess a node here. `Remove` confirms:

  ```
  REMOVE                                       (section mark)
  Remove Ana Iliovic?                          (h2)
  They lose access now; what they saved stays  (muted — the consequence, one sentence)
  with them.

  [ ] Also remove from your private feeds      (checkbox row, 40pt; present only when they are in any)

  ( Remove )                                   (btn danger)
  ( Cancel )                                   (btn ghost)
  ```

  Toast: `Removed Ana Iliovic.` They are not told by the app; there is nothing
  to send it from.
- Empty members: `No members yet.` (muted, under the section mark; the card is
  absent).

**Adding a private feed** (`PROTOCOL §11.4.2`), modal:

```
PRIVATE FEED                                  (section mark)
Add a private feed.                           (h2)
You approve its members separately.           (muted — the consequence)

FEED NAME
[ Band notes                 ]                (input)
( Add It )                                    (btn primary)
( Cancel )                                    (btn ghost)
```

Toast `Added Band notes.` and the feed's invite sheet opens (§2.29). The
feed appears in Compose's `POST TO` tabs (§2.9) with a faint `Private` pill on
its tab and the same pill on the private node's tab — a person posting sees
where it is going.

**The feed channel screen** (§2.6) for a private channel: no username line
(mono muted reads `private · 3 members`), no `Verified` pill of its own (the
card is verified as a whole, `PROTOCOL §11.5`), a `Private` neutral pill in
the pill slot, and the kebab holds `Open in Telegram` and — for a channel you
own — `Share Invite`, `Revoke Invite`; for one you are a member of —
`Leave` (§2.33). Never `Copy Link`.

### 2.29 Sharing an invite

The one way in. A House Pour modal, opened by `Share Invite` on the Private
screen, on a private feed's kebab, and automatically after creating either:

```
INVITE                                        (section mark)
Invite someone to Elijah · private.           (h2)
https://t.me/+AbCdEfGh12345678                (mono, selectable, one line, ellipsised middle)

Anyone with this link can ask to join.        (muted)

( Copy Invite )                               (btn primary)
( Share… )                                    (btn neutral — native share sheet; web: hidden when navigator.share is absent)
( Show as QR )                                (btn ghost sm — swaps the link line for a QR of it; reads `Show as Link` to swap back)
( Close )                                     (btn ghost)
```

- The muted line is `PROTOCOL §11.7`'s bearer-token fact and appears **every
  time** the sheet opens; there is no "got it". It stays because it is the
  consequence of the one thing this sheet does. What it no longer says —
  nobody gets in unapproved, and Telegram's own channel screen offers a
  primary link that joins without approval (11.4.1) — is this spec's to carry.
- `Copy Invite`: toast `Invite copied.`
- The app never posts the invite anywhere, never puts it on a card, never
  hands it to the Connector, and never opens a share sheet the owner did not
  tap.
- `Revoke Invite` (kebab), confirm:

  ```
  REVOKE                                       (section mark)
  Revoke this invite?                          (h2)
  The old link stops working.                  (muted — the consequence)

  ( Revoke )                                   (btn danger)
  ( Cancel )                                   (btn ghost)
  ```

  Then `PROTOCOL §11.4.4`, the invite sheet reopens with the new link, toast
  `New invite. The old one is dead.`

### 2.30 Requests — the inbox, and approving

Pushed from `Requests` on the Private screen and from the gold `2 requests`
line on You. One list, every private channel you own, newest first:

```
‹ Back                                          [Synced]

REQUESTS · 2                                  (section mark, serif count)
┌ card ─────────────────────────────────────┐
│ (avatar) Ana Iliovic                       │  Telegram name, body
│          @anailiovic · 2h ago              │  mono muted
│          Voice, product, Vancouver.        │  their Telegram bio, muted; absent when empty
│          Maybe @tgs_ana ›                  │  mono faint; only when the §4.3 guess resolves; taps to the profile
│          Elijah · private                  │  which channel, mono faint; absent when you own only one
│          ( Approve )  ( Decline )          │  btn primary sm · btn ghost sm
└───────────────────────────────────────────┘
No requests.                                  (empty, muted)
```

- `Maybe @tgs_ana` is `PROTOCOL §11.4.5`'s guess and is labelled as one. It is
  the only tgsocial fact on the row and it is not a fact: Telegram does not
  say which channels a user owns, so the app looks for a node named the way
  Setup names them and shows it if it finds one. **Nothing else is inferred
  from it** — no "follows you", no mutual count, no `Followed by N of yours`.
  A row without the line is a person the app could not guess, which is most
  people.
- `Approve`: `processChatJoinRequest(…, true)`; the row leaves; toast
  `Approved Ana Iliovic.` They are in from that moment and read everything
  ever posted (§2.27 said so). `Decline`: `…false`; the row leaves; toast
  `Declined.` No confirm on either — approval is one tap because the owner is
  looking at exactly one person, and decline is reversible by the person
  asking again.
- The list refreshes live from `updateChatPendingJoinRequests`; a request
  withdrawn on the other side leaves the list without a toast.
- The count on You and on the Private screen is the same number this screen
  shows, and it is gold only while non-zero. Nothing badges the tab bar.

### 2.31 Asking to join — what a requester sees

**Getting in.** An invite link arrives however people send things — a message,
a QR, a note. Opening it lands here; so does pasting it into Explore's
`Find a node` field (§2.4), which now accepts an invite link as well as a
username (`PROTOCOL §11.4.6` step 1). The preview, a House Pour modal:

```
INVITE                                        (section mark)
(avatar 48pt)  Elijah · private               (title, body 600)
               3 members                      (mono muted)

( Ask to Join )                               (btn primary)
( Cancel )                                    (btn ghost)
```

- The preview is `checkChatInviteLink` — title, photo, member count — and
  nothing more, because that is all Telegram shows a non-member. No card, no
  posts, no owner name beyond the title.
- A link to a public channel (`is_public`) skips this and opens the channel
  (§2.6). A link needing a bot's approval: toast `This channel uses a bot to
  approve members. Open it in Telegram.` and stop.

**Waiting.** After `Ask to Join`, toast `Asked.` and Explore gains a section
above `NEARBY`:

```
WAITING                                       (section mark)
┌ card ─────────────────────────────────────┐
│ (avatar) Elijah · private                  │
│          asked 2h ago         ( Ask Again )│  btn ghost sm
└───────────────────────────────────────────┘
```

No line under it. `PROTOCOL §11.4.7`: Telegram tells a declined requester
nothing, so the row simply stays until an approval arrives; the app does not
pretend to know more than Telegram does, and it does not explain that on
screen (§3). `Ask Again`
re-sends (11.4.6 step 3); a duplicate is whatever TDLib says, verbatim. There
is no `Cancel` because there is no call for it; the row can be swiped away
(`Forget`), which forgets it locally and nothing else. The section is absent
when the list is empty.

**Approved.** On the next refresh the row leaves `WAITING` and the person's
private posts are in the feed (§2.32). Toast, once: `You're in Elijah · private.`

**Their card.** The private node's channel screen for a member (§2.28, feed
variant) shows the private card's owner as a link when the card is
**verified** (`PROTOCOL §11.3`) — the mono muted line reads
`private node of @tgs_elijah` and taps to the public profile, and the pill
slot carries the gold `Verified` pill, which here means exactly the §11.3
check. When it is **not** verified:

```
(avatar 72pt)                        [Unconfirmed]  ⋮      ← neutral pill
Elijah · private                                 (h2)
says it belongs to @tgs_elijah                   (mono muted; taps to the profile, which is what it claims, not what it is)
```

Posts from an unverified private channel are attributed to the channel — its
title and photo — never to the node it names (`PROTOCOL §11.5`). The pill and
the `says it belongs to` line carry the doubt; they stay until the public card
confirms it; a client that shows a
person's name and face over an unconfirmed channel has handed that face to
whoever made the channel.

### 2.32 Private posts in the feed, and Share

A private post is a §2.3 post card with one addition and one subtraction.

**The addition.** A neutral `Private` pill after the channel name in the
header subheading, on every private post, on every screen that lists posts
— Feed, the feed channel screen, the carousel's post sheet. There is no
setting that hides it. The reader about to forward, screenshot, or read aloud
is the person the pill is for.

```
┌ card ──────────────────────────────────────┐
│ (avatar) Elijah Lucian     2h ago · Share  │
│          Elijah · private  [Private]       │  mono muted + neutral pill
│ …                                          │
│ 3 reactions                                │  no comments count, no Comment button
└────────────────────────────────────────────┘
```

Attribution is §2.3's rule with `PROTOCOL §11.5`'s source: a verified private
card's channel is attributed to the public node it names, so the name is
Elijah's, the avatar is the private channel's (the source-channel rule), and
tapping the name opens Elijah's public profile. Unverified: the channel's own
title and photo, and the name does not tap.

**The subtraction.** No `Comment` button, no comments count, no thread
screen. `PROTOCOL §11.5` says why in one sentence: comments live in public
channels, and a reply would publish the post. Tapping the text does nothing;
long-press still opens the post sheet.

**The post sheet** (§2.3) on a private post:

```
POST
Posted        2026-09-07 14:02
Views         41
Feed          Elijah · private · Private       (the pill again, mono)
( Open in Telegram )                          (btn neutral — t.me/c/<id>/<n>, opens for members)

SAFETY
( Report Post )
( Block @tgs_elijah )                         (present only when the card is verified — there is no node to name otherwise)
( Mute Elijah · private )
( Close )
```

**Share** copies the post's `https://t.me/c/<id>/<n>` link — the only link a
private post has — with the toast `Link copied. Members only.`
Native share sheets get the same URL. There is no `t.me/s/` preview to fall
back to and no public route (§2.13) to substitute, and the app does not
manufacture one: a private post has no public address, and Share says so
rather than pretending.

**Safety on private content** (§2.15–§2.18) works unchanged. The maintainer
cannot open a private post, so a private report is worth also making to
Telegram from the post; that is the reader's to know from this spec and the
docs, and the confirm does not say it (§3). The email's `Link:`
is the `t.me/c/` link, `Channel:` reads `private · <supergroupId>`, and the
post is hidden on this device the moment `Send Report` is tapped, exactly as
before. Block names the verified node and removes their private and public
posts together. Mute names the channel by title and keys it by id
(`PROTOCOL §7.2`). Settings' `MUTED` and `HIDDEN` rows show the channel title
with a `Private` pill in place of a username; the `HIDDEN` key column reads
`c/<id> · <n>`.

### 2.33 Settings additions, and Delete My Node

Settings (§2.20) gains one card between `HIDDEN` and `CONTACT`, present only
when the reader has a private node or is a member of any:

```
PRIVATE                                      (section mark)
Mention on public card       [ toggle ]  On  (list row, 40pt)

Revoke invite                ( Revoke )       (list row; §2.29's confirm)

PRIVATE FOLLOWS · 2                           (section mark, serif count)
┌ card ─────────────────────────────────┐
│ Ana · private              ( Leave )   │  title body; `of @tgs_ana` mono muted under it (verified) or `unconfirmed` (not)
│ of @tgs_ana                            │
└───────────────────────────────────────┘
You're not in anyone's private node.         (empty, muted)
```

- `Mention on public card` writes or strips `private.id` (`PROTOCOL §11.2`,
  §4.4). It is on by default. Its cost, no longer on screen: the public card
  notes that a private node exists (not how to reach it); off, members' apps
  cannot confirm the private node is yours and see it as unconfirmed. While on, a
  missing or wrong `private.id` — a §2-only client rewrote the card
  (`PROTOCOL §11.6`) — is repaired silently on the next card write and on the
  next read of your own card, with the toast `Card repaired.`
- `Leave` confirms:

  ```
  LEAVE                                        (section mark)
  Leave Ana · private?                         (h2)
  Their private posts leave your feed.         (muted — the consequence)

  [x] Also leave their private feeds           (checkbox row; present when you are in any; on by default)

  ( Leave )                                    (btn danger)
  ( Cancel )                                   (btn ghost)
  ```

  Toast: `Left Ana · private.` The owner is not told by the app.

**Delete My Node** (§2.21) grows to cover the private channels, and the copy
grows with it. When a private node exists the muted lines read:

```
Deletes @tgs_elijah, @tgs_elijah_r, your
private node and 1 private feed, and
everything in them for every member; your
feeds stay.
This can't be undone.
```

`1 private feed` is derived — `2 private feeds`, or the clause is absent with
no feeds. The order is `PROTOCOL §11.4.12`: private feeds, private node,
comments channel, node. Four more outcomes join §2.21's list, one per point
the run can stop at — and once the private channels have gone, no later
refusal may say `Nothing was deleted.`: `deleteChat` on a private channel is
for every member at once and cannot be undone (`PROTOCOL §11.4.12`).

- **A private channel failed.** Stop before touching anything public.
  `Couldn't delete Band notes — Telegram said: <error>. Nothing was deleted.`
  with `( Try Again )` and `( Close )`.
- **Private channels went, comments channel failed.** The card is rewritten
  without `private.id` and the modal reads `Your private channels are gone.
  @tgs_elijah_r and @tgs_elijah are still there — Telegram said: <error>.`
  with `( Try Again )` and `( Close )`.
- **Private channels went, public node failed.** The card is rewritten
  without `private.id` and the modal reads `Your private channels are gone.
  @tgs_elijah is still there — Telegram said: <error>.` with `( Try Again )`
  and `( Close )`.
- **Private channels and comments channel went, public node failed.** The
  card is rewritten without `replies:` and `private.id` and the modal reads
  `Your private channels and your comments channel are gone. @tgs_elijah is
  still there — Telegram said: <error>.` with `( Try Again )` and `( Close )`.

A private channel deleted from Telegram's own client — not through the app —
is gone for every member the same way, and the owner's app notices on its
next refresh or the moment `updateSupergroup` says so: the record drops it,
`private.id` comes off the public card (the private node) or its link comes
off the private card (a private feed), and `Delete My Node` no longer stops
on a channel that is not there. Nothing is toasted; there is nothing to say
that Telegram did not already show.

Members of the deleted channels see them leave the feed on their next
refresh, with no toast and no tombstone (§2.16's rule: nothing at all). The
`PRIVATE FOLLOWS` row on their Settings leaves with it.

### 2.34 What does not touch the private layer

Three surfaces, each excluded by construction and each saying so once.

- **The public reader** (§2.13) renders nothing private and cannot: it reads
  `t.me/s/<channel>`, which Telegram serves for public channels only, and its
  reader is anonymous — the one reader membership excludes by definition. A
  `t.me/c/…` or `t.me/+…` link pasted into a public route shows the §2.6
  empty card. Nothing is written about it on the page.
- **The Connector** (§2.14) exposes no private source under any preset, and
  `Custom` cannot name one (it lists usernames). The screen no longer says so
  (§3); `CONNECTOR.md §3` does. A member's consent to read a friend's private channel is not consent to pipe
  it to an assistant (`PROTOCOL §11.5`).
- **The demo** (§2.22) carries no private fixtures and no `PRIVATE` section
  on You. `Make a Private Node` is not in the demo to refuse; a demo that
  painted an invite link would be handing the reviewer a fake bearer token
  to reason about, and §2.22's fixture world is invented people who cannot
  approve anyone.

### 2.35 Bluesky — signing in, the account, signing out

`PROTOCOL §12` reads Bluesky into the feed. **Bluesky is a peer of Telegram at
sign-in, and never a second profile** (Elijah, 2026-09-25: "it should allow
combined logins to telegram and blueky"). Either network alone signs in, or
both (§1); there is no new tab and no second You. A reader who signs in to
Telegram alone and says `Not Now` to §2.1's offer sees none of this beyond one
card in Settings — except that a node they follow may carry Bluesky posts,
which needs nothing from them (§2.36).

**Where it lives.** On Sign in (§2.1), the `BLUESKY` card beside Telegram's,
and once as the offer after Telegram's sign-in. After that, Settings (§2.20):
a `BLUESKY` card between `PRIVATE` and `CONTACT`, always there outside the demo
(§2.40), signed in or not, because the tag toggle needs no account. Not in
Setup (§2.2), which makes a Telegram channel, and not on You (§2.8), which is
the node's — except for a Bluesky-only reader, whose You is the account
(§2.8).

The sign-in below is the sheet Settings opens. §2.1's `BLUESKY` card runs the
same steps inline — same handle rules, same browser, same waiting state, same
toasts — with the card in place of the sheet.

Signed out of Bluesky:

```
BLUESKY                                      (section mark)
( Sign In with Bluesky )                     (btn neutral sm)

#waveloop drops in your feed   [ toggle ] Off  (list row, 40pt)
```

No explanation on the card (§3): the button and the toggle are labels enough.
What the tag is — drops people post to Bluesky from WaveLoop, which anyone can
post — is §2.36's and `PROTOCOL §12.6`'s to say.

`Sign In with Bluesky` opens a sheet:

```
BLUESKY                                      (section mark)
Sign in with Bluesky.                        (h2)

HANDLE                                       (field label)
[ elijah                     ]               (input, mono; placeholder `elijah.bsky.social`; a DID works too)

( Sign In with Bluesky )                     (btn primary; enabled once the handle rules below leave something to resolve)
( Cancel )                                   (btn ghost)
```

- **No scope paragraph.** The scopes (`PROTOCOL §12.7`) are listed by
  Bluesky's own consent page, which is where the person grants them; the app
  does not restate them (§3). A client that asks for more changes
  `PROTOCOL §12.7`'s table, and Bluesky's page shows the change.
- `Sign In with Bluesky` puts the pill at `Syncing` (pending row: `Finding your
  Bluesky server`), then opens Bluesky's own page **in the system default
  browser** — Chrome, Safari, whatever the person set — in its most recent
  window, so a browser already signed in to Bluesky is the login (RFC 8252's
  external user agent; `PROTOCOL §12.7` step 6). The password is typed into
  Bluesky, never into tgsocial. `Cancel` is live while the server is found:
  it stops the attempt there, at once, and nothing is said, whatever the lookup
  would have answered.
- While Bluesky's page is open the sheet shows the waiting state in place of
  the field:

  ```
  BLUESKY                                      (section mark)
  Waiting for Bluesky…                         (h2)
  @elijah.bsky.social                          (mono small — the resolved handle)
  Finish in your browser.                      (muted — the screen's one helper line, §3)
  ( Cancel )                                   (btn ghost)
  ```

- **It never hangs.** `Cancel` is on screen the whole time; closing the sheet
  any other way cancels too. Coming back to the app with no callback keeps
  waiting. At **10 minutes** the attempt ends on its own: toast
  `Bluesky sign-in timed out.` and the sheet returns to the field with the
  handle still typed. One sign-in at a time.
- **The callback** arrives as `ca.lucianlabs:/tgsocial/oauth/callback?…`
  through the app's registered URL scheme (§5, `PROTOCOL §12.7`). It completes
  the attempt only when its `state` matches; a callback with an unknown or
  stale `state` is ignored — no toast, the waiting state carries on.
  `error=access_denied` (the person declined on Bluesky's page) ends it with
  the toast `Not signed in to Bluesky.` Any other `error` ends it with §2.39's
  `Bluesky didn't finish signing you in.` Cancel ends it with nothing said.
- Back from Bluesky, the sheet closes onto Settings with the account row below.
  Toast: `Signed in to Bluesky as @elijah.bsky.social.` The follows toggle
  starts **on**: reading who you follow is the reason to sign in. A failure or
  the timeout keeps the sheet, so a mistyped handle is fixed where it was typed.

**Handle entry**, on every surface that takes a handle (this sheet and
`Sign In Again`, §2.39), before anything is resolved:

1. Trim whitespace, then drop one leading `@`.
2. A value starting `did:` is a DID and is used exactly as typed; the steps
   below are for handles.
3. A value with no `.` gets `.bsky.social` appended: `elijah` →
   `elijah.bsky.social`, `@elijah` → `elijah.bsky.social`.
4. A value with a `.` is used as typed — a custom domain is a handle
   (`ana.example.com`).
5. Then lowercase the handle, and resolve it (`PROTOCOL §12.7` step 1).

Nothing left to resolve (an empty field, a lone `@`) keeps the button disabled.
The cases are `docs/card-vectors.json` `atproto.handleInput`. The field shows
what was typed; the waiting state shows the resolved handle.

Signed in:

```
BLUESKY                                      (section mark)
┌ card ─────────────────────────────────┐
│ (avatar) Elijah Lucian                 │  display name body; handle mono muted
│          @elijah.bsky.social           │
└───────────────────────────────────────┘
Your Bluesky follows in your feed [ toggle ] On   (list row, 40pt)
#waveloop drops in your feed      [ toggle ] Off  (list row, 40pt)
Linked to @tgs_elijah            [Verified]       (list row — §2.37; `( Link to My Node )` until linked)

( Sign Out of Bluesky )                      (btn ghost)
```

- The account row taps through to the profile on Bluesky (system browser, §4).
- `Linked to` is absent without a node, since there is nothing to link to.
- The follows toggle is the following source (`PROTOCOL §12.5`); off, the
  reader stays signed in for linking and posting and sees only linked accounts
  and the tag.

`Sign Out of Bluesky` confirms:

```
BLUESKY                                      (section mark)
Sign out of Bluesky?                         (h2)
Your Bluesky follows leave your feed.         (muted — the consequence, one sentence)

( Sign Out )                                 (btn danger)
( Cancel )                                   (btn ghost)
```

Toast: `Signed out of Bluesky.` A link to the node stays — it is two public
lines, not a sign-in (`PROTOCOL §12.8`) — and the confirm does not say so (§3).

**Sign-outs are independent.** Signing out of Bluesky leaves Telegram signed
in, and signing out of Telegram (§4) leaves Bluesky signed in: each clears its
own network's local state (`PROTOCOL §7`). The one that leaves neither signed
in is the last one out, and it wipes everything but the safety lists and lands
on Sign in (§2.1). The confirms do not change for being last — the consequence
each states is still the true one.

**The Status sheet** (§2.10) gains one row, under `Feed`:

```
Bluesky           @elijah.bsky.social · 5 sources   (or `Not signed in`, `Sign in again`, `Can't reach <host>`)
```

`5 sources` counts the atproto sources in the merge — linked accounts, the
follows source, the tag — so a reader can see the Bluesky share of `Feed`'s
number. Pending rows while it works: `Loading @ana.bsky.social on Bluesky`,
`Checking @tgs_ana's Bluesky link`, `Posting to Bluesky`.

### 2.36 Bluesky posts in the feed

**Marked by source, not a different card.** A Bluesky post is a §2.3 post card
with the channel subheading replaced and one pill added — same header, same
body, same media treatment, same place in the newest-first merge:

```
┌ card ──────────────────────────────────────┐
│ (avatar) Ana Iliovic        2h ago · Share │  name: the node when linked (below), else the account
│          @ana.bsky.social  [Bluesky]       │  mono muted handle + neutral pill
│                                            │
│ Post text with links and @mentions…        │
│ [ images · link card · video still ]       │
│                                            │
│ 12 likes · 3 replies                        │  mono faint; no Comment button
└────────────────────────────────────────────┘
```

- **Attribution** is §2.3's rule with `PROTOCOL §12.5`'s source. An account
  verified to a node (`PROTOCOL §12.3`) is that node: the name is Ana's card
  `name`, tapping it opens her profile, and blocking names her node. Any other
  account is itself: its Bluesky display name (falling back to the handle), and
  tapping the name opens its profile on Bluesky. The avatar is the account's
  own — §2.3's "the avatar is the source" rule, and here the source is the
  account.
- **The pill** is the neutral `HPPill` reading `Bluesky`, on every Bluesky post
  on every screen that lists posts, including a node profile's merged feed. It
  never goes gold (§1 reserves gold). It is what makes a reader know that the
  reply they want to write lives somewhere else.
- **Footer**: `N likes · N replies` from the post view's counts, `compactCount`
  like reactions, mono faint. No `Comment` button and no comments count:
  tgsocial comments point at `t.me` posts (`PROTOCOL §6.2`).
- **Tapping the text** opens the post on Bluesky, where its replies are.
  Tapping media opens it in the app (§2.11). Long-press opens the post sheet.
- **Time** is the post's merge date (`PROTOCOL §12.5`), formatted as §2.3.
- **Share** copies or shares `https://bsky.app/profile/<did>/post/<rkey>` — the
  DID form, which still opens after a handle change.

The post sheet:

```
POST                                         (section mark)
Posted        2026-09-21 18:04               (list rows; values mono)
On            Bluesky · @ana.bsky.social
Likes         41
( Open on Bluesky )                          (btn neutral)

SAFETY                                       (section mark)
( Report Post )                              (btn danger sm)
( Block @tgs_ana )                           (btn ghost sm — `Block @ana.bsky.social` when unlinked)
( Mute @ana.bsky.social )                    (btn ghost sm)

( Close )                                    (btn ghost)
```

**Rich text.** Link facets are links, mention facets are `@handle` linking to
that profile on Bluesky, tag facets are plain text. Telegram's entity rules
(§2.3) do not apply — a Bluesky post has no bold.

**Media in v1**, on all three builds alike:

| Bluesky embed | Renders as |
| --- | --- |
| Images (1–4) | §2.11.3's mosaic, then the carousel: the view's `thumb` in the card, `fullsize` in the viewer; alt text is the image's accessibility label. |
| External link | A link card: its thumb (12pt radius, full width), title in body 600, domain in mono faint. Tap opens the link (§4). A WaveLoop drop is one of these, domain `waveloop.app`. A cross-post from a node you follow never renders — you already have the Telegram original (`PROTOCOL §12.5` rule 7). |
| Video | The video's still, full width, with the ▶ glyph and `Plays on Bluesky` in faint. Tap opens the post on Bluesky. |
| Quote | Its media, if any, as above, then one faint row `Quoting @handle` that opens the quoted post on Bluesky. |
| Anything else | Text only. |

Video is the one that looked cheap and is not. Bluesky serves HLS: Safari and
AVPlayer play it natively, Chrome and Firefox need `hls.js`, a script the web
client would have to vendor and ship, and Android needs ExoPlayer's HLS
module. Playing it on two builds and not the third breaks §0's one-app,
same-screens promise, so v1 plays it on none and says where it plays.

**Not in v1**, and why: a WaveLoop drop's own media inline (audio in the §2.11
player, stereo and depth images) — each card would cost a DID resolution, a
`getRecord` and a blob of up to 50 MB from the owner's PDS, none of it
measured; and a thread screen for Bluesky replies, which is Bluesky's app.

**A node profile** (§2.5) with a verified link gains one row at the top of
`FEEDS`, and the profile's merged posts include that account's:

```
FEEDS
┌ card ───────────────────────────────────────┐
│ Bluesky      @ana.bsky.social     Verified  │  → opens on Bluesky; `Verified` gold, PROTOCOL §12.3
│ Ana's notes  @ana_notes           Verified  │
└─────────────────────────────────────────────┘
```

An unverified link shows nothing at all — no row, no greyed row, no
`Unconfirmed` (`PROTOCOL §12.3` says why) — to everyone but the node's owner,
who sees §2.37's pending state on their own screen.

### 2.37 Linking your Bluesky to your node

**Where it starts.** The `Linked to` row in Settings' `BLUESKY` card (§2.35)
reads `( Link to My Node )` until there is a link. Present only when signed in
to Bluesky and a node exists.

It opens a sheet that shows both halves before writing either, because the
link is two public statements and the person should see both being made:

```
LINK                                         (section mark)
Link @elijah.bsky.social to @tgs_elijah.     (h2)
Your followers here see your Bluesky posts.   (muted — the consequence)

TWO LINES, BOTH PUBLIC                       (section mark)
┌ card ─────────────────────────────────┐
│ 1  Your Bluesky account names          │  list rows; status pill right:
│    @tgs_elijah                  [ — ]  │  `—` · `Writing` · `Done` · `Failed`
│ 2  Your card names                     │
│    @elijah.bsky.social          [ — ]  │
│ 3  Anyone can check both        [ — ]  │  `Checking` · `Verified`
└───────────────────────────────────────┘

( Link )                                     (btn primary)
( Cancel )                                   (btn ghost)
```

- `Link` runs `PROTOCOL §12.8` in order and the pills move as it goes: the record
  in the Bluesky account, then the card, then the check a stranger would run,
  signed out. Row 3's pill is the gold `Verified` when it passes — the same word
  the feed backlink earns (`PROTOCOL §3`), for the same reason: both sides said
  so.
- Success closes the sheet. Toast: `Linked.`
- **Step 1 failed**: nothing was written. Row 1 reads `Failed` and the sheet
  says `Bluesky said: <error>. Nothing was changed.` with `( Try Again )`.
- **Step 2 failed**: the account names the node, the card does not, and that
  half attributes nothing. `Your Bluesky account names @tgs_elijah. Your card
  doesn't yet — Telegram said: <error>.` with `( Try Again )`, which retries step
  2 only.
- **Step 3 failed** after both writes: the check could not reach the account's
  server. `Both lines are written. Couldn't check them yet.` and the row keeps
  `Checking` until the next refresh settles it.

**The owner's pending states**, shown on the `Linked to` row — and only to the
owner; to everyone else an incomplete link is no link:

- The card names this account and the account does not name the node (a line
  typed on plain Telegram, or step 1 lost): `Your Bluesky account doesn't
  name @tgs_elijah yet.` with `( Finish Linking )`.
- The card names a different account from the one signed in: `Your card
  names a different Bluesky account.` with `( Replace )`, which runs the same
  sheet for the signed-in account and unlinks nothing on the other.
- A §2-only client dropped the line (`PROTOCOL §12.2`): repaired silently on
  the next card write while signed in to the same account, toast `Card
  repaired.` — §2.33's behaviour, for the same reason.

**Unlink** — the row's value becomes `( Unlink )` once linked — confirms:

```
UNLINK                                       (section mark)
Unlink @elijah.bsky.social?                  (h2)
Your Bluesky posts leave your followers'      (muted — the consequence)
feeds here.

( Unlink )                                   (btn danger)
( Cancel )                                   (btn ghost)
```

The card line goes first, then the record (`PROTOCOL §12.8`). Toast:
`Unlinked.`

### 2.38 Compose: Also post to Bluesky

The compose sheet (§2.9) gains one row between the textarea and the buttons,
present only while signed in to Bluesky:

```
POST TO
[ WaveLoop devlog ] [ Très Buchet ]
[ textarea, 6 rows, placeholder "Say it." ]
Also post to Bluesky          [ toggle ] Off  (list row, 40pt)
212 / 300 · @elijah.bsky.social               (mono faint; only while on)
( Post )      ( Cancel )
```

- **Off every time the sheet opens.** The choice is per post and never
  remembered: a toggle that stayed on would post to a second network things the
  person wrote for this one.
- **The counter** counts graphemes, which is what Bluesky counts. Past 300 it
  turns `bad`, `Post` disables, and the line reads `Too long for Bluesky.
  Shorten it or turn this off.` The app never cuts someone's sentence to fit.
- **Absent** on a private channel's tab (§2.28 — private posts never leave,
  `PROTOCOL §12.9`), in the demo (§2.22), and while signed out of Bluesky.
- **What goes to Bluesky** is `PROTOCOL §12.8`: the same words, links and
  hashtags live, Telegram `@names` as plain text, and a link card back to the
  Telegram post. A photo (native only; web compose is text only, §2.9) rides as
  that card's image.
- Toasts: `Posted.` (toggle off) · `Posted here and on Bluesky.` · and when the
  Telegram post succeeded but Bluesky refused: `Posted here. Bluesky didn't
  take it — <error>.` There is no retry button: the copy may have landed before
  the error came back, and a retry that posts twice is worse than asking the
  person to look.
- Telegram failed: nothing is sent to Bluesky, and §4's error stands alone.
- Deleting the Telegram post never deletes the Bluesky copy (`PROTOCOL §12.8`,
  create-only scope). The sheet used to say so under the toggle; it no longer
  does (§3), and this line is where it is written down.

### 2.39 Bluesky errors

None of these touches the Telegram half of the app. The feed keeps painting
what it can.

- **The session ended** — Bluesky's two-week limit for apps like this one, a
  refresh that failed, access revoked from Bluesky's side. The follows source
  pauses; linked accounts and the tag keep coming, because they never needed the
  session. One toast, once: `Bluesky signed you out.` The Settings card shows the account row with `Signed out by
  Bluesky` in muted and `( Sign In Again )`, which opens §2.35's sheet with the
  handle filled in. Status sheet: `Bluesky  Sign in again`. The compose toggle
  is absent until then. Bluesky only (§1), the reader stays signed in — the
  session is held, not live — and the app stays open: Feed paints its cache
  and the tag, Graph its last list, You loses `( Compose )`, and `Sign In
  Again` is in Settings' `BLUESKY` card as above, with `( Sign Out of Bluesky )`
  (ghost) under it: an ended session is held, so it can be signed out of like a
  live one — for a Bluesky-only reader that is the last one out (§4).
- **A server is down** — the account's PDS, or the AppView. That source is left
  out of this refresh and tried again on the next (`PROTOCOL §12.5` rule 6);
  there is no toast for a failed read, because it happens again by itself in a
  minute. Status sheet: `Bluesky  Can't reach puffball.us-east.host.bsky.network`
  and the same host under `Last error`. A link whose check cannot reach the
  server keeps its last result for a day (`PROTOCOL §12.3`).
- **A write failed** — linking (§2.37) and posting (§2.38) say so where they
  happened. Offline: `You're offline.`
- **Rate limited**: `Bluesky asked us to wait n s.` — §4's `FLOOD_WAIT` line,
  same back-off.
- **Signing in**: `Couldn't find that Bluesky account.` (the handle does not
  resolve) · `Bluesky didn't finish signing you in.` (Bluesky's page returned an
  error) · `Couldn't sign in to Bluesky.` (a check in `PROTOCOL §12.7` step 9
  failed, or the client's own metadata could not be fetched; the server's words
  go to `Last error` verbatim).

### 2.40 Safety on Bluesky posts, and what does not touch Bluesky

§2.15–§2.18 work on Bluesky posts with the same controls, the same lists and the
same address. What changes is honest copy about what nobody here can do.

**Report.** The confirm gains a ghost sm `( Report on Bluesky )` under the
reasons, which opens the post on Bluesky, where Bluesky's own report lives. The
button is the whole of the difference on screen (§3): nobody here can remove a
Bluesky post from Bluesky, and the button is where a reader acts on that. The email
goes to the same address with a body shaped for a post that has no channel:

```
Reason: <reason>
Link: https://bsky.app/profile/<did>/post/<rkey>
Account: @<handle> · <did>
Record: at://<did>/app.bsky.feed.post/<rkey>
Node: @<node>                                (or `unattributed`)
Kind: bluesky post
App: tgsocial 1.0.0 (12) · iOS

Anything you want to add:

```

It is hidden on this device the moment `Send Report` is tapped, as always. The
§2.19 commitment stands and its honest clause gets longer: a Bluesky post is
removed by Bluesky or by its author, and by nobody else.

**Block.** On a post from a linked account the button names the node, and
blocking writes the account's DID beside the node (`PROTOCOL §12.9`), so their
Bluesky posts stay gone however they arrive. On any other account it names the
handle, and the confirm reads:

```
BLOCK                                        (section mark)
Block @ana.bsky.social?                      (h2)
Their posts disappear here, and they aren't   (muted — §2.16's sentence)
told.
```

Nothing changes on Bluesky (`PROTOCOL §12.9`).

**Mute** names the handle: `Muted @ana.bsky.social.` — out of the merged feed,
nothing else. The tag is not muted; it is switched off in Settings.

**Settings** (§2.20): a blocked or muted account is a row with its handle in
body and its DID in mono muted beneath; a hidden Bluesky post is a row reading
`Bluesky · @ana.bsky.social` with its record key `3mw2cdr44fc2a` in mono and
the reason and date under it.

**The filter** (§2.18) also drops, with no residue and no switch: posts carrying
Bluesky's hiding labels, the author's own adult self-label included; and posts
by accounts the reader has blocked on Bluesky, read from their account's public
block records. A tgsocial block is never sent to Bluesky.

**What does not touch Bluesky**, each by construction:

- **The public reader** (§2.13) reads `t.me/s/` previews and shows no Bluesky
  post, linked or not.
- **The Connector** (§2.14) exposes no Bluesky source; its scopes list
  usernames. Reading a Bluesky account in your feed is not consent to pipe it
  to an assistant.
- **The demo** (§2.22) has no `BLUESKY` card, no Bluesky posts and no compose
  toggle. It makes no network request (§2.22.4), and invented accounts under a
  real network's name would be exactly the screenshot §2.22's strip exists to
  prevent.

### 2.41 Which network, which screen

§1 names four states; Sign in (§2.1) is the fourth. This is every screen in
the other three, with its words. Where a cell says "as §N", the screen is that
section's, unchanged.

**The Telegram card.** A screen whose content needs Telegram, reached by a
Bluesky-only reader, keeps its topbar and tab bar and shows one card in place
of its body:

```
┌ card ─────────────────────────────────┐
│ Sign in to Telegram to find nodes.     │  (muted — the screen's one helper line, §3)
│ ( Sign In with Telegram )              │  (btn primary — the screen's one action)
└───────────────────────────────────────┘
```

The line is `Sign in to Telegram to <verb>.` with the verb the screen's own.
The button runs §2.1's Telegram steps and comes back to the screen it left,
now filled. A Telegram feature is **not** gated this way where it is a control
on a screen Bluesky-only readers use (Comment, Follow, Edit Card): those
controls are absent, because the thing they act on — a Telegram post, a node,
a card — is not on the screen.

| Screen | Telegram only | Bluesky only | Both |
| --- | --- | --- | --- |
| Tab bar (§1) | `Feed · Explore · Graph ·` avatar: node photo, else initial | same four; avatar: Bluesky avatar, else initial | node photo, else Bluesky avatar, else initial |
| Status pill (§1, §2.10) | `Synced` · `Syncing` · `Offline` from TDLib | same words, from Pending and the device's network | as Telegram only |
| Status sheet (§2.10) | as §2.10; `Bluesky` row only with a Bluesky source (the tag) | `Telegram  Not signed in`; no `Connection`, `Node`, `TDLib` | as §2.10 with `Bluesky  @elijah.bsky.social · 5 sources` |
| §2.1's offer | h1 `Also sign in to Bluesky?`, once | h1 `Also sign in to Telegram?`, once | not shown |
| Setup (§2.2) | as §2.2, when no node | never | as §2.2, when no node |
| Feed (§2.3) | Telegram sources, and the tag when on | following source and tag (§2.36); no Work control | all of `PROTOCOL §12.5`'s sources |
| Feed, empty | `Nothing here yet.` `( Explore )` | `Nothing here yet.` | `Nothing here yet.` `( Explore )` |
| Explore (§2.4) | as §2.4 | Telegram card: `Sign in to Telegram to find nodes.` | as §2.4 |
| Node profile (§2.5), from a link | as §2.5 | Telegram card: `Sign in to Telegram to see @tgs_ana.` | as §2.5 |
| Feed channel (§2.6), from a link | as §2.6 | Telegram card: `Sign in to Telegram to see @waveloop_devlog.` | as §2.6 |
| Thread (§2.12) | as §2.12 | unreachable: a Bluesky post's text opens on Bluesky (§2.36) | as §2.12 |
| Graph (§2.7) | `DIRECT · 12`, `+1 · 84` | `BLUESKY · 212`, ring 1 only | as Telegram only |
| You (§2.8) | node, feeds, listing, private; `( Settings )` top right | account, `( Compose )`, `TELEGRAM` `( Sign In with Telegram )`; `( Settings )` top right | as Telegram only |
| Compose (§2.9) | `POST TO` feed tabs | `POST TO` `Bluesky · @elijah.bsky.social`, counter, one photo | feed tabs and `Also post to Bluesky` (§2.38) |
| Post sheet (§2.3, §2.36) | as §2.3 | as §2.36; `Block @ana.bsky.social` (no node to name) | both, by post |
| Settings (§2.20) | lists, `PRIVATE`\*, `BLUESKY` signed out, `CONTACT`, `TELEGRAM` with `Sign Out of Telegram`, `Delete My Node`\* | lists, `BLUESKY` signed in (no `Linked to`), `CONTACT`, `TELEGRAM` `( Sign In with Telegram )` | lists, `PRIVATE`\*, `BLUESKY` signed in with `Linked to`\*, `CONTACT`, `TELEGRAM` with both buttons\* |
| Sign-out confirm (§4, §2.35) | `Sign out of Telegram?` `Your node stays on Telegram.` → Sign in | `Sign out of Bluesky?` `Your Bluesky follows leave your feed.` → Sign in | either one; the other stays |
| Delete My Node (§2.21) | with a node | absent | with a node |
| Work, Private (§2.23–§2.34) | as specified | absent: each is on a node | as specified |
| Connector (§2.14, Mac) | as §2.14 | Telegram card: `Sign in to Telegram to use the Connector.`; the port is closed | as §2.14; Bluesky is never a source (§2.40) |
| Public link (§2.13), in the app | the screen | the Telegram card, then the screen | the screen |
| Demo (§2.22) | — | — | — |

\* present when §2.20, §2.21, §2.33 or §2.37 say so: a node, a private node,
a verified link.

The demo row is empty on purpose: the demo is entered from Sign in, is signed
in to neither network, and is its own world (§2.22) — no `BLUESKY` card, no
`TELEGRAM` card, `( Leave Demo )` in their place.

## 3. Copy rules

House Pour voice. Short declaratives, no exclamation marks, no emoji in
chrome, no "Oops", no apologies. Buttons are verb-first title case. Empty
states end in a full stop and offer one action at most. Numbers the user is
meant to feel (follow counts in section marks) are serif.

**On-screen copy is labels, not explanation** (Elijah, 2026-09-25: "remove all
the exposition on the app"). What stays on screen: labels, buttons, section
marks, field labels, pills, toasts and error messages. What goes: sentences
about why, how it works, what Telegram or Bluesky does, and privacy caveats in
body text. The reasoning lives in this file and the docs, where it has room to
be right. Four rules, for every build:

1. **At most one short helper line per screen**, and only where a person would
   otherwise be stuck (`Finish in your browser.` on §2.35's waiting state; the
   Connector's `Let an assistant read your feeds.`; the vouch sheet's
   `You can't remove a vouch someone wrote. Report it or block them.`; §2.41's
   `Sign in to Telegram to find nodes.`).
2. **Empty states are a short label** (`No members yet.`, `Nothing here yet.`),
   plus at most one action.
3. **A confirm states its consequence in one sentence** (`Their posts and
   comments disappear here, and they aren't told.`). A consequence is what will
   happen to the person or to what they made; a reason is not a consequence.
   `Delete My Node` keeps its type-to-confirm and `This can't be undone.` —
   that is consequence.
4. **A label that names a state stays** even when it reads like a sentence —
   the demo strip (§2.22), `Signed out by Bluesky` (§2.39), `says it belongs to
   @tgs_elijah` (§2.31). Each says what *is*, not why.

A client that adds an explanatory line changes this file first. The verbatim
copy in §2 is the source of truth, and a build whose strings differ from it is
the one that is wrong.

Word list: `node`, `card`, `feed`, `follow`, `network`, `+1`, `comment`,
`reply`, `thread`, `comments channel`, `block`, `mute`, `report`, `hidden`,
`demo` (§2.22 — never "sandbox", "sample", "test mode", "fake"),
`work`, `work card`, `work feed`, `vouch`, `open to` (§2.23–§2.25),
`private`, `private node`, `private feed`, `invite`, `member`, `request`,
`approve`, `unconfirmed` (§2.27–§2.34),
`Bluesky`, `Bluesky account`, `link`, `linked`, `drop`, `Also post to
Bluesky`, `Sign In with Bluesky` (§2.35–§2.40),
`Sign In with Telegram`, `Sign Out of Telegram`, `Sign Out of Bluesky`,
`Also sign in to Bluesky?`, `Also sign in to Telegram?` (§2.1, §2.41).
Never "friends", "subscribe", "timeline", "algorithm", "flag", "ban",
"moderation", "community guidelines".

And never, on the private surfaces: "encrypted", "secure", "secret",
"close friends", "circle", "safe". Each promises something Telegram
membership does not do (`PROTOCOL §11.9`), and the one place the feature is
allowed to be reassuring is the paragraph that says exactly what it does.
`Verified` on a private card means `PROTOCOL §11.3`'s check and appears only
when it passed; `Unconfirmed` is its absence, said aloud.

And never, on the work surfaces: "professional", "career", "job", "skill",
"endorse", "endorsement", "recommendation", "recruiter", "résumé", "CV",
"connection". Two reasons, and both are the same reason. The borrowed words
carry a second product's promises — a directory, a verifier, a score — and this
one has none of them (`PROTOCOL §10.8`). And naming it "the professional
network" would name a second network, which is exactly what §2.24 decided it is
not. `Verified` is reserved for the feed backlink (`PROTOCOL §3`) and appears
nowhere on a work card.

**Signing in is `Sign in`, on both networks** — never "connect", "log in",
"link" or "add account". The button is `Sign In with Telegram` or `Sign In
with Bluesky`, the state is `Signed in` / `Not signed in`, the way out is `Sign
Out of Telegram` or `Sign Out of Bluesky`. One verb for both, because the two
are peers (§2.1) and a reader should not have to wonder whether "connecting"
Telegram is a different act from signing in to Bluesky. `Link` is §2.37's and
means the two public lines, never a sign-in. `Connected` survives in one place,
`Connection` on the Status sheet (§2.10) and the demo's `Telegram · Not
connected` (§2.22.5), where it names TDLib's network connection, not an
account.

And never, on the Bluesky surfaces: "connect", "sync" (of an account — §1's
`Syncing` pill is unchanged), "import",
"federated", "fediverse", "decentralized", "skeet", "cross-post". Sync and
import promise a copy tgsocial never keeps — Bluesky posts are read live and
stored nowhere but the feed cache (`PROTOCOL §12`). Connect is the work
surfaces' banned "connection" by another route. Federated names what
`docs/HOSTING.md §6` says this is not. The action is `Also post to Bluesky`,
said in full. `Verified` beside a Bluesky account means `PROTOCOL §12.3`'s
two-way check and appears only when it passed; an unverified link has no word
at all, because it is not shown.

## 4. Behaviour rules

- Cold start: show the last cached feed immediately, then refresh. Never a
  blank screen behind a spinner if there is a cache.
- Every write to the card (follow, feeds, edit) is optimistic in the UI and
  rolled back with a toast on failure: `Couldn't update your card.` plus
  TDLib's message.
- Network errors: status pill `Offline`; reads serve cache; writes toast
  `You're offline.` When the network returns, the feed refreshes by itself.
  Signed in to Telegram, TDLib's `Connected` is the signal; Bluesky only, it is
  the device's network (§2.10).
- Rate limits (`FLOOD_WAIT_n`): toast `Telegram asked us to wait n s.` and
  back off that long before retrying automatically.
- Sign out of Telegram (Settings, §2.20) asks once (modal: h2 `Sign out of
  Telegram?`, muted `Your node stays on Telegram.`, `( Sign Out )` danger,
  `( Cancel )` ghost) then `logOut` and wipes Telegram's local state
  (`PROTOCOL §7`). A Bluesky session stays, and the app stays open, Bluesky
  only (§1). Sign out of Bluesky is §2.35's.
- **The last one out** — whichever network leaves nothing signed in — wipes
  all local state, UI preferences included, except the safety lists, which
  survive by design (`PROTOCOL §7.1`), and lands on Sign in (§2.1).
- **Telegram signs you out** — the session ended from another device, or
  TDLib reached `authorizationStateClosed` without our `logOut`: toast
  `Telegram signed you out.`, Telegram's local state goes as above, and the
  app stays open on Bluesky when a session is held, else lands on Sign in.
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
  photo library access only when `Add Photo` is tapped. Registers the URL
  scheme `ca.lucianlabs` (`CFBundleURLTypes`) for the Bluesky callback
  (`PROTOCOL §12.7`). A fork's scheme is derived at build time from its
  `TGS_ATPROTO_REDIRECT` (`ios/scripts/redirect-scheme.sh`), never set by hand,
  and a half-set or mismatched client pair fails the build.
- **Android**: Kotlin + Jetpack Compose, minSdk 26, targetSdk 35. Edge-to-edge,
  light status bar icons on the ivory background. Predictive back supported.
- **Mac**: the same SwiftUI app built for Mac Catalyst, plus the Connector tab (§2.14) and the bridge. Same TDLib session, same House Pour look. Bluesky sign-in opens the default browser with `UIApplication.shared.open`, as on iOS; the browser asks before it hands `ca.lucianlabs:` to the app, and that prompt is the browser's.
- **Web**: static files, no bundler, no framework. Media via `<img>`, `<video>`, `<audio>` on object URLs from tdweb `readFile`/`readFilePart`. `tdweb` (TDLib wasm) loaded
  from `vendor/`. Must work from a plain nginx host over https. Installable
  PWA manifest with the ivory theme colour.

## 6. Versioning

Marketing version `1.0.0`; build number increases every archive. Show
`tgsocial <version> (<build>)` in the You screen footer on all platforms.
