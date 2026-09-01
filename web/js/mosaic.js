/* mosaic.js — the photo mosaic's layout rule (PRODUCT §2.11.3).
 *
 * "A post with more than one photo is a mosaic, not a stack — an album is one
 * thing, and reading it as one block is the point."
 *
 * Everything here is pure: the count decides the grid, the photos' own shapes
 * decide the block's ratio, and nothing touches the DOM. js/media.js builds the
 * element from this; css/app.css carries the same grid as `grid-template-areas`
 * keyed on `data-count`, so there is ONE arrangement per count rather than four
 * bespoke components — and test/flows.mjs derives its expected rectangles from
 * `MOSAIC_AREAS` below rather than restating them, which is what keeps the two
 * copies honest.
 */

/** §2.11.3: five photos and fifty both draw four tiles; the rest become `+N`. */
export const MOSAIC_MAX_TILES = 4;

/**
 * The grid, per shown count — rows of area letters, exactly the
 * `grid-template-areas` in css/app.css. Tiles take `a`, `b`, `c`, `d` in album
 * order, so the shape of the table IS the rule:
 *
 *   2   a b       two tiles side by side, equal width
 *   3   a b       one TALL leading tile with two stacked beside it
 *       a c
 *   4   a b       two by two
 *       c d
 *
 * Five or more is the four-tile grid with `+N` over the fourth (§2.11.3).
 */
export const MOSAIC_AREAS = {
  2: [['a', 'b']],
  3: [['a', 'b'], ['a', 'c']],
  4: [['a', 'b'], ['c', 'd']],
};

/** Area letter for the nth tile (0-based), matching `MOSAIC_AREAS`. */
export function tileArea(i) {
  return String.fromCharCode('a'.charCodeAt(0) + i);
}

/**
 * How many tiles this album paints and how many it hides behind the `+N`.
 * Anything under two photos is not a mosaic at all — the caller falls back to
 * §2.11's single full-width `HPMedia`.
 */
export function mosaicPlan(count) {
  const n = Math.max(0, Math.floor(count));
  if (n < 2) return { mosaic: false, shown: n, extra: 0, areas: null };
  const shown = Math.min(n, MOSAIC_MAX_TILES);
  return { mosaic: true, shown, extra: n - shown, areas: MOSAIC_AREAS[shown] };
}

/** The middle value — one panorama in an album of squares must not set the shape. */
function median(values) {
  const xs = values.filter((v) => Number.isFinite(v) && v > 0).sort((a, b) => a - b);
  if (!xs.length) return null;
  const mid = xs.length >> 1;
  return xs.length % 2 ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2;
}

/**
 * §2.11.3's "aspect-aware, and the block keeps a sane overall ratio instead of
 * letting one tall photo set the height."
 *
 * Every layout above is two columns wide, so a cell's own ratio follows the
 * block's: at 3 and 4 tiles a cell is half the width and half the height, which
 * is the block's ratio again, and at 2 it is half the width at full height —
 * half the block's. Solve that for "the cells look like the photos" and the
 * block wants `2 × r` at two tiles and `r` at three or four, where `r` is the
 * median photo ratio. Then clamp: the sane range is what stops a column of
 * portraits from painting a block taller than the screen, and it is why a tall
 * photo COVERS its cell instead of setting the height (§2.11.3).
 *
 * `min`/`max` are the caller's, read from the cascade (`--ratio-mosaic-min` /
 * `--ratio-mosaic-max`, generated from design/tokens.json's `ratio` group) —
 * the numbers are tokens, never literals here.
 */
export function mosaicRatio(aspects, shown, { min, max }) {
  const r = median(aspects ?? []);
  const lo = Number.isFinite(min) && min > 0 ? min : null;
  const hi = Number.isFinite(max) && max > 0 ? max : null;
  // No usable shape (a photo with no declared size) falls back to the middle of
  // the sane range rather than to a guess about the picture.
  const wanted = r === null ? (lo !== null && hi !== null ? Math.sqrt(lo * hi) : 1) : (shown === 2 ? 2 * r : r);
  let out = wanted;
  if (lo !== null) out = Math.max(lo, out);
  if (hi !== null) out = Math.min(hi, out);
  return out;
}
