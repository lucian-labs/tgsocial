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
