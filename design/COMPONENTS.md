# House Pour kit — components

Three hand-written component libraries, one contract. Same names, same
variants, same token use. A screen written against this list in SwiftUI,
Compose, or HTML must be recognisably the same card.

| Platform | Location | Namespace |
| --- | --- | --- |
| iOS | `design/swift/HousePour/` | `HP*` SwiftUI views + `HPTokens` |
| Android | `design/kotlin/housepour/` | `HP*` composables + `HPTokens`, package `ca.lucianlabs.housepour` |
| Web | `design/web/house-pour.css` (+ `house-pour.js`) | upstream class names (`.card`, `.btn.primary` …) |

Tokens are generated (`node build.mjs`). Components are written by hand
against the token names — never against raw values. Read `../PRODUCT.md` for
where each component is used and `https://lucianlabs.ca/branding/AGENT.md`
for the ban list before writing any of them.

## Surfaces

**HPBackdrop** — the page background: the three-stop ivory gradient
(`backdropTop → backdropMid → backdropBottom`, 165°) with the gold radial
wash at 20%/-10% and the violet wash at 90%/8%. Fixed; does not scroll with
content. Web: `body` already has it.

**HPColumn** — the single column. Max `columnMax`, side padding `columnSide`,
bottom padding `bottomSafe`. Everything lives inside one.

**HPTopbar(leading, trailing)** — sticky, translucent `topbarBg` with a
backdrop blur (14), hairline `line` underneath, padding `topbarY/topbarX`.
Leading is the wordmark (`HPWordmark`) or a `‹ Back` ghost button; trailing
is a status pill. Web: `.topbar`. Android platform exception: the bar overlays
the scroll container (content passes under `topbarBg`) but carries no backdrop
blur — Compose has no cross-version backdrop blur.

**HPCard** — `panel` fill, 1pt `line` border, `Radius.card`, `cardPad`
padding, `cardGap` below, `Shadow.contact` + `Shadow.cast`. The only raised
surface. Web: `.card`.

**HPListItem(leading, trailing)** — a row inside a card: `rowPad` vertical,
hairline `line` below except on the last row. Web: `.list-item`.

**HPModal(isPresented, content)** — a card centred over a `scrim`, shadow
deepened (cast opacity ×1.5). Fades in `Motion.toast`. Never dark.

**HPToast(message, tone)** — inverted ink pill, fixed bottom centre 26pt up,
`toastBg`/`toastText`, 1pt `toastLine` border (tone `good` → green line,
`bad` → red line), `Shadow.toast`. Fades in/out `Motion.toast`; never slides.
Auto-dismisses after 2.8 s. Web: `.toast.show[.good|.bad]`.

## Type

Each is a text view that applies one `HPTokens.Type` style — face, size,
weight, tracking, line height, uppercase — and one colour.

| Component | Style | Colour | Notes |
| --- | --- | --- | --- |
| HPWordmark | `wordmark` / `brand` (topbar) | ink | brand face, never uppercase |
| HPH1 | `h1` | ink | display serif |
| HPH2 | `h2` | ink | display serif |
| HPSectionMark(text, count?) | `sectionMark` | muted | uppercase, trailing hairline that fades to transparent (`line2 → clear`). Optional count set in `totals` style, ink |
| HPFieldLabel | `fieldLabel` | muted | uppercase; `labelBottom` below |
| HPBody | `body` | ink | default text |
| HPMuted | `body` | muted | secondary copy |
| HPSmall | `small` | muted | |
| HPMono | `mono` / `monoSmall` | muted | ids, usernames, times |
| HPFigure | `figure` | ink | lining numerals; the serif does the numbers |

Text entity rendering (bold, italic, code, link) maps to: bold → `bodyStrong`
weight, italic → display italic only if the run is display, else body italic,
code → `mono`, link → `accent` underlined (1pt, offset 0.18em).

## Controls

**HPButton(label, style, size)** — pill (`Radius.pill`), full width by
default, `buttonY/buttonX` padding, `button` text style (uppercase, 0.14em).

| style | fill | text | border | shadow |
| --- | --- | --- | --- | --- |
| `primary` | gradient `primaryGradientStart → End` 135° | `primaryText` | none | `Shadow.primaryButton` |
| `accent` (charcoal) | gradient `charcoalGradientStart → End` 150° | `charcoalText` | none | `Shadow.charcoalButton` |
| `neutral` (default) | transparent | ink | 1pt `line2` | none |
| `ghost` | transparent | muted (ink on hover) | none | none |
| `danger` | `bad` @ 5% | `bad` | 1pt `bad` @ 40% | none |

`size: .small` → `buttonSmY/buttonSmX`, `buttonSm` style, hugs content.
Pressed: translate down `Motion.pressTranslateY` over `Motion.press`; web also
`brightness(1.04)` on hover. Disabled: 45% opacity. **One `primary` per
screen.** Web: `.btn[.primary|.accent|.ghost|.danger][.sm]`.

**HPButtonRow(a, b)** — two buttons side by side, `btnRowGap`, equal widths.
The only side-by-side layout in the look. Web: `.btn-row`.

**HPTextField(label, text, kind)** — `HPFieldLabel` above, input with
`inputBg`, 1pt `line2` border, `Radius.input`, `inputY/inputX` padding,
`input` style (16pt so iOS doesn't zoom), `inputBottom` below. Focus: border
`accent` + 3pt `accentSoft` ring (the one ring in the look — it is a focus
state, not decoration). Placeholder `faint`. `kind`: text, phone, number,
secure, multiline(rows). Web: `label.field` + `input`/`textarea`.

**HPPill(text, tone)** — `pill` style, `pillY/pillX`, `Radius.pill`, 1pt
border. `neutral`: muted on `bg2`, `line2` border. `gold`: accent on
`accentSoft`, accent @ 35% border. `bad`: bad on bad @ 6%, bad @ 45% border.
Web: `.pill[.gold|.bad]`.

**HPTabs(items, selected)** — segmented control: `bg2` track, 1pt `line`
border, pill radius, `tabsPad` inset, `tabsGap`; each item `tabY/tabX`,
`tab` style, muted; selected item `panel` fill, ink text, inset 1pt `line`
ring + a 1pt/3pt contact shadow at 12%. Equal widths. Web: `.tabs`.

**HPToggle(isOn)** — there is no switch in the upstream kit; derive: a pill
track 44×26, `bg2` + 1pt `line2` off, `accentSoft` + `accent` border on; a
22pt `panel` knob with the contact shadow. Colour animates `Motion.color`.

**HPAvatar(image, size, fallbackInitial)** — circle, `bg2` fill, 1pt `line`
ring, initial set in `h2` (size 36) / `h1` (size 72) display serif, muted.

**HPMedia(image, aspect)** — full width, `Radius.media`, `bg2` placeholder
while loading, no border, no shadow.

**HPMosaic(count, aspects, onTap, tile)** — an album as **one object** (PRODUCT
§2.11.3). Two tiles side by side; three as one tall leading tile with two
stacked beside it; four as two by two; five or more as the first four with a
`+N` in the `pill` style over a `scrim` on the last. Every arrangement is two
columns, which is what fixes the block's shape: a cell's ratio follows the
block's, so the block wants `2 × r` at two tiles and `r` at three or four, where
`r` is the **median** photo ratio — the median, so one panorama among squares
does not flatten it — clamped between `ratio.mosaicMin` and `ratio.mosaicMax`.
Tiles `cover` their cell; `Radius.media` clips the **block**, never the tiles,
with `border.width` gutters in `line` showing through between them. A cell that
would fall under `touchMin` in either axis is not a tap target, so the block
reflows to a single column rather than overflowing. Tapping a tile calls
[onTap] with its index — §2.11.3's "opens the carousel at that tile" — and each
tile's painted shape simply *is* its region (rule 6), minus the block's own
corner radius. `tile` is handed the cell's pixel size, because the tiles are
thumbnails and must be requested at tile size. Layout rule shared verbatim with
`web/js/mosaic.js`.

**HPSpectrogramStrip(content, progress, onSeek)** — the audio scrubber
(PRODUCT §2.11.1). A spectrogram of the *whole clip* on `bg2` at
`Radius.media`, its one-pole envelope mirrored about the centre and filled
over the top, a 1pt `accent` playhead, played in `accent` and ahead of the
head in `ink` at reduced opacity. Time is the x axis end to end, so the strip
**is** the scrubber: tap or drag anywhere on it to seek. It is `stripHeight`
(44) tall, so its painted shape simply is its 40pt target — rule 6's first
case, no overlay, nothing owed by the container. Two ingredients ship with
it: **HPRamp**, the interpolation of the `ramp` token set (transparent →
`line2` → `muted` → `accent`, topping out at `accent2` — the only gradient in
the look that carries data, and the only place a colour is computed rather
than named), and **HPMirrorWave**, the connected-line-through-peaks
silhouette with played/unplayed runs keyed on an `Int`. The spectrum arrives
as a **bitmap**, never a path: a full-width strip is ~1400 columns, and
re-emitting that per frame is the O(columns × rows) blowup the texture
exists to avoid. Analysis is the app's job, not the kit's. Currently iOS
only; the ramp tokens are generated for all three so the other two match
when they land.

**HPMiniWave(peaks, progress, onSeek)** — the now-playing dock's waveform
(PRODUCT §2.11.2). **One polyline** through the envelope's column peaks: a line
drawing, not the strip's mirrored filled silhouette and not the spectrum.
Hairline (`border.width`), `muted` ahead of the playhead and `accent` behind
it, no fill under the curve, split once at the playhead so the two runs share a
vertex and the line stays continuous. The baseline is the band's **centre**, so
a clip whose strip degraded to the hairline draws a *flat line* rather than
nothing. It paints `miniWaveHeight` (20) tall inside a `touchMin` frame with a
`miniWaveWidth` (96) floor — rule 6's chrome case: the dock row is a 40pt play
button tall already, so nothing is inflated to reach the target and a long
title truncates against the floor instead of squeezing the control away. Tap or
drag anywhere on it to seek. It draws peaks and never computes them: the
envelope is the strip's (§2.11.1), resampled to the dock's width, because
playing a clip must never trigger a second analysis. Web: `.mini-wave` — a
canvas inside a `.hit-min` slider, so the 40pt region is an **HPHitTarget**
overlay past the painted 20 and the dock row must not clip its overflow.

**HPKebabButton(label, action)** — the vertical three-dot button (PRODUCT
§2.6). Ghost: no fill, no border, `Radius.pill`, three `faint` dots `pillY` (4)
across stacked with a 3pt gap — an 18pt column of dots centred in a `touchMin`
(40) hit box. The dots are drawn from tokens, never a glyph, icon font or
emoji. The dots step up on interaction over `Motion.color` — ink while pressed
(native), muted on hover and while the menu is open (web) — and the button
carries the ghost press translate. Icon-only, so the label is the accessible
name and defaults to `More`. Web:
`.kebab` (three `<i>` boxes) inside `.menu-anchor`.

**HPMenu(items)** — the menu a kebab opens (PRODUCT §2.6). The card is an
`HPCard` surface: `panel`, 1pt `line`, `Radius.card`, the one card shadow
(`Shadow.contact` + `Shadow.cast`). It holds one **HPMenuItem** per action —
an `HPListItem` row, `body` text in ink, `touchMin` minimum height, hairline
`line` between rows and none under the last. Two presentations, split at
`columnMax` (540):

- **Anchored** (wider than the column): hangs under the button, right edges
  aligned, `rowGap` below it, `menuWidth` (240 = 6 × `touchMin`) wide — a
  floor, not a cap, on the kits whose rows size to their text, and never wider
  than `columnMax`. Flips above the button when it would fall off the bottom.
- **Sheet** (at `columnMax` or narrower — every phone): the same card docked to
  the bottom edge over the `scrim`, `columnSide` inset, `columnMax` at most.

Only the surface fades (`Motion.toast`); it never slides, scales, or moves —
rule 4 holds here too. Dismissal: a tap outside the card, `Escape` (web), the
back gesture (Android), a swipe down past `menuDismissDrag` (40 — one hit
target) on the sheet, or a scroll of the page behind it (web). Never the
platform's own menu — SwiftUI `Menu` and Compose `DropdownMenu` both paint
system chrome. Web: `.menu` anchored, `.menu.sheet` inside `.menu-scrim`.

**HPViewer(counter, caption, actions, onClose)** — the full-screen media
viewer chrome (PRODUCT §2.11, §2.12). `ink` at 96%, `Close` leading and a LIST
of `HPButton .ghostOnInk .small` actions trailing — `Comments` beside `Save`,
each 40pt by its own drawn shape. `HPViewerChrome.height` (`touchMin` + `pillY`)
is what a caller insets by to pin content under that row: with the thread open
the media shrinks to a `viewerMiniHeight` (120 = 3 × `touchMin`) mini view and
the thread takes the rest of the sheet. The mini view is tappable to restore
it full-screen, and paging re-targets the thread at that item's own post. The chrome column spans the screen but
only hit-tests where it paints, so the sheet under it keeps its own touches.

**HPStepper** — from upstream; not used in tgsocial v1 but kept in the kit.

## Composite (product-level, built from the above)

**PostCard** — see PRODUCT §2.3. `HPCard` → **one** header row: `HPAvatar 36`
of the **source channel** (its photo → the node's photo → the initial), a tight
stack of the person's name (`HPBody` strong) over the channel (`HPMonoSmall`
muted) at their two natural line heights, then `HPMonoSmall` faint time and an
`HPButton ghost small "Share"`. The avatar is centred against that stack and
the row measures about one avatar tall; every control in it takes its 40pt from
**HPHitTarget** (rule 6), never from a taller line box. Then body text with
entities → `HPMedia` → footer row (`HPMonoSmall` faint counts, `HPButton ghost
small "Comment"`). The channel's half of that target hangs *below* the header,
so the card owes it `PostHeaderBottomGap` clear of tap surfaces before the first
of those — and the body's tap surface starts at its glyphs, not at its padding,
because padding inside the shape claims the band and swallows the subheading.

**PhotoMosaic** — see PRODUCT §2.11.3. More than one photo in a post is ONE
block, not a stack. The rule is **N equal-width columns, each an equal-height
stack**, and §2.11.3's table is that rule with different column contents: 2 →
`[[0],[1]]`, 3 → `[[0],[1,2]]` (the tall tile leads), 4 and up → `[[0,2],[1,3]]`
with `+N` in the `pill` style over a `scrim` on the fourth. Those are the
**transpose** of the `HPMosaic` table above, which Android and web spell as rows
because their placers walk rows — this one walks columns, and album order still
reads left to right THEN down, so photo 1 is the top-right tile. The block's
ratio is the same derivation as `HPMosaic`: the **median** photo ratio times
`columns / rows` — the median, so one panorama among squares does not set the
shape — clamped between `ratio.mosaicMin` and `ratio.mosaicMax`. Tiles `cover`
their cells;
gutters are the `line` colour showing through one `border.width` gap, and
`Radius.media` is clipped on the **outer** corners only, so it reads as one
object. It reflows to a single column when a tile would fall under `touchMin`
wide, because every tile is a control: tapping one opens the §2.11 carousel at
that tile's index. Implemented as a `Layout` (the height depends on the width,
which is exactly what `sizeThatFits` answers) so each tile is handed its own
cell size and can ask the image cache for **tile** pixels rather than card
pixels. Web: `.post-mosaic` / `.post-mosaic-tile` — one CSS grid
with `grid-template-areas` per count (never four bespoke components), the gutters
its `gap` over a `line` background, and the tiles asking the byte-budgeted image
cache for half the block's width. Its narrow end is fluid rather than
stepped — `minmax(0, 1fr)` columns and `min-width: 0` tiles are what stop a
photo's intrinsic width from becoming the floor and overflowing the card — so the
web build keeps two columns all the way down instead of collapsing to one; on the
app column that threshold is a viewport under 149pt, which no phone reaches.

**NodeRow** — `HPListItem`: `HPAvatar 36`, name (`HPBody` strong) over
`HPMonoSmall` (`@username · n feeds`), optional `HPSmall` "Followed by n of
yours", trailing `HPButton neutral small "Follow"` / ghost "Following".

**FeedRow** — `HPListItem`: title (`HPBody`), `HPMonoSmall` username,
optional `HPPill gold "Verified"`, trailing chevron in `faint`.

**StatusPill** — `HPPill`: `Synced` gold, `Syncing`/`Offline`/`Signed out`
neutral.

**EmptyCard(title, body, action?)** — `HPCard` → `HPH2` → `HPMuted` → one
`HPButton accent` at most.

## Rules every component obeys

1. Colours come from `HPTokens.Colors` (Swift/Kotlin) or `var(--token)` (CSS).
   Zero raw hex in component or screen code.
2. One border width (1). Radii: `card` on cards/modals, `input`/`media` on
   inputs and images, `pill` on everything round. No other radius.
3. One shadow on cards (contact + cast), one on each gradient button, one on
   the toast. Nothing else casts.
4. Motion: 150 ms colour/border, 50 ms press, 200 ms toast fade. No
   transforms except the 1pt press. Nothing animates on appear.
5. No emoji in chrome. No system-styled buttons, navigation bars, tab bars,
   switches, or segmented controls leaking through (`.buttonStyle(.plain)` on
   iOS; no `Material*` components on Android except `Text`, `BasicTextField`,
   layouts, and `LazyColumn`).
6. Every interactive element has a 40pt minimum hit target and an
   accessibility label. The target is a **region, not a box**: a pill button
   can simply *be* 40pt because that is its drawn shape, but a line of text
   cannot — growing its line box to `touchMin` is what leaves a 13pt
   subheading sitting in a 47pt box (PRODUCT §2.3). Those controls paint at
   their natural size and take the target from **HPHitTarget** instead, which
   extends past the painted bounds. Web: `.hit-min` (a transparent `::after`;
   `--hit-top` / `--hit-left` slide it, and the host must not clip its own
   overflow or it clips the region away). Two controls stacked closer together
   than 2 × `touchMin` **tile** their regions — each keeps a full `touchMin`
   and the boundary between them is a line, not an overlap, because whichever
   region paints last would otherwise swallow the other's half. Tiling binds the **layout** as well as the pair: a
   region that reaches past its own element is claimed by any later-placed
   control it lands on, so a region is worth only the clear space its
   neighbours leave it — a gap nothing else has made tappable.

   So the **container owes the overhang**: whatever follows a stack holds a gap
   the size of it before its first tappable thing. Whitespace counts — what the
   band may not contain is another tap surface, which is why a block that pads
   itself away from the stack keeps that padding *outside* its own content
   shape. The one place this bites in tgsocial is the post card (PRODUCT §2.3):
   the channel subheading's region hangs a whole `touchMin` minus one
   mono-small line box below the header, and the card holds that band —
   `PostHeaderBottomGap` on iOS and Android alike, 20.8dp there and ~26pt here,
   because Compose sets the ramp's line height explicitly and SwiftUI paints a
   shorter line box. Get it wrong and the target measures 40 and lives at 14,
   its lower two thirds opening the thread instead of the feed.

   A region only counts for what actually reaches it, so these get asserted on
   the **assembled** screen — Android injects taps in 1dp steps over the card
   (`PostCardHitRegionTest`); iOS measures every region in place, in one
   coordinate space, against every neighbouring tap surface
   (`hpMeasureTouchTargets` + `PostHeaderHitRegionTests`). Never by measuring a
   control on its own: that reports the overlay a component drew, which is the
   same 40pt whether or not anything can reach it.
7. Dynamic Type (iOS) / font scale (Android) scale the ramp proportionally;
   clamp at 1.4× so the layout holds.
