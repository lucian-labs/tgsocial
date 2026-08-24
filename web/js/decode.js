/* decode.js — the downsampling decode path.
 *
 * A feed card is at most 540 CSS px wide. Telegram's `x` photo size is 800–1280
 * px and its originals go past 2500; decoding one of those to paint a card
 * costs w × h × 4 bytes of decoded surface — a 2560 × 1920 photo is 19 MB for
 * something the phone shows at 390 pt. This module decodes straight to the
 * size that will actually be painted, using the browser's own resizing decode
 * (`createImageBitmap` with resizeWidth/resizeHeight), and hands back a small
 * re-encoded blob to cache in its place.
 *
 * Three things bound the TRANSIENT cost, which is the term that gets a tab
 * jetsammed and the one the byte budget in blobcache.js cannot see (nothing is
 * charged until the decode has already finished):
 *
 *   1. The header, not a decode, answers "how big is this?". An image already
 *      small enough — every avatar, every thumbnail, every photo Telegram
 *      already sized for us — now costs a 64 KB read and no decoded surface
 *      at all.
 *   2. Where the header is readable and the image is upright, the resize is a
 *      SINGLE pass straight from the compressed bytes: no full-size
 *      intermediate is ever materialised. Only the fallback path (unreadable
 *      header, or an EXIF rotation the header dimensions cannot describe)
 *      decodes at full size, and it releases that surface the moment the
 *      resized copy exists — before the canvas draw and the re-encode, which
 *      are the long part.
 *   3. Decodes are capped at MAX_DECODES at a time. The visibility observer
 *      arms every card within ~3 screens at once, so without a cap the peak is
 *      set by how many cards happen to be near the viewport rather than by
 *      anything this module controls.
 *
 * Every ImageBitmap is closed. An un-closed bitmap holds its decoded surface
 * until GC gets round to it, which on a phone is exactly the memory we are
 * trying not to spend.
 */

/** Formats where re-encoding would destroy the thing (animation, vectors). */
const NO_DOWNSCALE = /^image\/(gif|svg\+xml|apng)$/i;

/** Re-encode target. WebP where the browser has it, JPEG otherwise. */
let encodeType = null;

function pickEncodeType() {
  if (encodeType) return encodeType;
  encodeType = 'image/jpeg';
  try {
    if (typeof document !== 'undefined') {
      const c = document.createElement('canvas');
      c.width = 1;
      c.height = 1;
      if (c.toDataURL('image/webp').startsWith('data:image/webp')) encodeType = 'image/webp';
    }
  } catch {
    encodeType = 'image/jpeg';
  }
  return encodeType;
}

function canvasFor(w, h) {
  if (typeof OffscreenCanvas === 'function') return new OffscreenCanvas(w, h);
  if (typeof document === 'undefined') return null;
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  return c;
}

function encode(canvas, type, quality) {
  if (typeof canvas.convertToBlob === 'function') return canvas.convertToBlob({ type, quality });
  return new Promise((resolve) => canvas.toBlob(resolve, type, quality));
}

// ── decode concurrency ─────────────────────────────────────────────────────

/**
 * How many decodes may hold a surface at once. Each one costs up to
 * w × h × 4 bytes for as long as it runs, and none of it is charged to the
 * media budget, so this is the only thing bounding the peak.
 */
const MAX_DECODES = 2;
let running = 0;
const waitingForSlot = [];

function acquireDecode() {
  if (running < MAX_DECODES) {
    running += 1;
    return Promise.resolve();
  }
  return new Promise((resolve) => waitingForSlot.push(resolve));
}

function releaseDecode() {
  const next = waitingForSlot.shift();
  if (next) next(); // hand the slot straight over rather than reopening it
  else running -= 1;
}

/** Live decode-slot state, for tests and the Status sheet. */
export function decodeLoad() {
  return { running, waiting: waitingForSlot.length, max: MAX_DECODES };
}

// ── header probe ───────────────────────────────────────────────────────────

/**
 * How much of a file we will read looking for its dimensions. JPEG's SOF
 * marker sits after any EXIF/ICC blocks, which a camera can make large; 64 KB
 * covers every real case and is two orders of magnitude under one decode.
 */
const HEADER_BYTES = 64 * 1024;

/** JPEG frame headers that carry the image size (not DHT/JPG/DAC). */
const SOF_MARKERS = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);

function u16(b, i, le) {
  if (i + 1 >= b.length) return -1;
  return le ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1];
}

function u32(b, i, le) {
  if (i + 3 >= b.length) return -1;
  const v = le
    ? b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)
    : (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  return v >>> 0;
}

function matches(b, i, ascii) {
  for (let k = 0; k < ascii.length; k += 1) if (b[i + k] !== ascii.charCodeAt(k)) return false;
  return true;
}

/**
 * EXIF orientation out of a JPEG APP1 payload: 1 when the image is upright,
 * 2–8 when it is mirrored or rotated, 0 when there is no readable value.
 */
function exifOrientation(b, off, len) {
  if (len < 14 || !matches(b, off, 'Exif') || b[off + 4] !== 0 || b[off + 5] !== 0) return 0;
  const tiff = off + 6;
  const le = b[tiff] === 0x49 && b[tiff + 1] === 0x49;
  const be = b[tiff] === 0x4d && b[tiff + 1] === 0x4d;
  if (!le && !be) return 0;
  if (u16(b, tiff + 2, le) !== 42) return 0;
  const offset = u32(b, tiff + 4, le);
  if (offset < 8) return 0;
  const ifd = tiff + offset;
  const count = u16(b, ifd, le);
  if (count < 0) return 0;
  for (let k = 0; k < count; k += 1) {
    const e = ifd + 2 + k * 12;
    if (e + 12 > b.length) break;
    if (u16(b, e, le) !== 0x0112) continue;
    const v = u16(b, e + 8, le);
    return v >= 1 && v <= 8 ? v : 0;
  }
  return 0;
}

function readJpeg(b) {
  if (b[0] !== 0xff || b[1] !== 0xd8) return null;
  let i = 2;
  let orientation = 1;
  while (i + 3 < b.length) {
    if (b[i] !== 0xff || b[i + 1] === 0xff) {
      i += 1; // fill byte, or resync after something we did not understand
      continue;
    }
    const marker = b[i + 1];
    // standalone markers carry no length word
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      i += 2;
      continue;
    }
    if (marker === 0xd9 || marker === 0xda) break; // end of image / start of scan
    const len = u16(b, i + 2, false);
    if (len < 2) return null;
    const payload = i + 4;
    if (marker === 0xe1) {
      const o = exifOrientation(b, payload, len - 2);
      if (o) orientation = o;
    } else if (SOF_MARKERS.has(marker)) {
      const height = u16(b, payload + 1, false);
      const width = u16(b, payload + 3, false);
      if (width <= 0 || height <= 0) return null;
      return { width, height, orientation };
    }
    i = payload + (len - 2);
  }
  return null;
}

function readPng(b) {
  if (!matches(b, 1, 'PNG') || b[0] !== 0x89) return null;
  if (!matches(b, 12, 'IHDR')) return null;
  const width = u32(b, 16, false);
  const height = u32(b, 20, false);
  if (width <= 0 || height <= 0) return null;
  // an eXIf chunk may follow, but PNG orientation is vanishingly rare and the
  // browser honours it either way; treating it as unknown would only cost a
  // needless full decode
  return { width, height, orientation: 1 };
}

function readWebp(b) {
  if (!matches(b, 0, 'RIFF') || !matches(b, 8, 'WEBP')) return null;
  const p = 20; // first chunk payload
  if (matches(b, 12, 'VP8 ')) {
    if (b[p + 3] !== 0x9d || b[p + 4] !== 0x01 || b[p + 5] !== 0x2a) return null;
    const width = u16(b, p + 6, true) & 0x3fff;
    const height = u16(b, p + 8, true) & 0x3fff;
    return width && height ? { width, height, orientation: 1 } : null;
  }
  if (matches(b, 12, 'VP8L')) {
    if (b[p] !== 0x2f) return null;
    const v = u32(b, p + 1, true);
    if (v < 0) return null;
    return { width: (v & 0x3fff) + 1, height: ((v >>> 14) & 0x3fff) + 1, orientation: 1 };
  }
  if (matches(b, 12, 'VP8X')) {
    if (p + 9 >= b.length) return null;
    const flags = b[p];
    const width = (b[p + 4] | (b[p + 5] << 8) | (b[p + 6] << 16)) + 1;
    const height = (b[p + 7] | (b[p + 8] << 8) | (b[p + 9] << 16)) + 1;
    // bit 3 is "has EXIF": the canvas size is right but the orientation is not
    // ours to assume, so let the full decode settle it
    return { width, height, orientation: flags & 0x08 ? 0 : 1 };
  }
  return null;
}

/**
 * Dimensions and EXIF orientation from a file's leading bytes, or null when the
 * format is not one we can read. Pure and byte-oriented so it is testable under
 * node (test/protocol.test.mjs).
 */
export function readImageHeader(bytes) {
  if (!bytes || bytes.length < 24) return null;
  try {
    return readJpeg(bytes) ?? readPng(bytes) ?? readWebp(bytes);
  } catch {
    return null; // a truncated or malformed header is "unknown", never a throw
  }
}

async function headerOf(blob) {
  if (typeof blob?.slice !== 'function' || typeof blob.arrayBuffer !== 'function') return null;
  try {
    const size = Number(blob.size) || HEADER_BYTES;
    const buf = await blob.slice(0, Math.min(size, HEADER_BYTES)).arrayBuffer();
    return readImageHeader(new Uint8Array(buf));
  } catch {
    return null;
  }
}

/**
 * Decode `blob` at no more than `maxWidth` device pixels wide.
 *
 * Resolves { blob, width, height, downsampled } — the ORIGINAL blob when it is
 * already small enough, when the format must not be re-encoded, or when the
 * browser has no resizing decode. Never throws: a failed decode falls back to
 * the original bytes, because a slightly heavy photo beats a blank card.
 */
export async function downscale(blob, maxWidth, { quality = 0.86 } = {}) {
  const fallback = { blob, width: 0, height: 0, downsampled: false };
  if (!blob || !maxWidth || typeof createImageBitmap !== 'function') return fallback;
  if (blob.type && NO_DOWNSCALE.test(blob.type)) return fallback;
  if (blob.type && !/^image\//i.test(blob.type)) return fallback;

  // re-encoding to JPEG would flatten transparency; where the browser cannot
  // encode WebP, anything that might have an alpha channel is left alone
  const reencodable = pickEncodeType() === 'image/webp' || /^image\/jpe?g$/i.test(blob.type ?? '');

  // The header settles both questions a full decode used to answer — how big
  // is it, and is it upright — for a few hundred bytes instead of a surface.
  // Orientation must be 1 for the dimensions to describe what will be painted:
  // a rotated photo's stored width is its painted HEIGHT, and resizing to it
  // would squash the picture.
  const head = await headerOf(blob);
  const upright = !!head && head.orientation === 1 && head.width > 0 && head.height > 0;
  if (upright && (head.width <= maxWidth || !reencodable)) {
    return { blob, width: head.width, height: head.height, downsampled: false };
  }

  await acquireDecode();
  let source = null;
  let scaled = null;
  try {
    let sw = upright ? head.width : 0;
    let sh = upright ? head.height : 0;
    if (!upright) {
      // Unreadable header, or an EXIF rotation: decode once at full size to
      // learn what will actually be painted. This is the only path that ever
      // materialises the original surface.
      // 'from-image' so a photo with an EXIF rotation is not re-encoded sideways
      source = await createImageBitmap(blob, { imageOrientation: 'from-image' });
      sw = source.width;
      sh = source.height;
      if (!sw || !sh) return fallback;
      if (sw <= maxWidth || !reencodable) return { blob, width: sw, height: sh, downsampled: false };
    }
    const w = Math.max(1, Math.round(maxWidth));
    const h = Math.max(1, Math.round((sh * w) / sw));
    const resize = { resizeWidth: w, resizeHeight: h, resizeQuality: 'high' };
    // the upright path resizes straight from the compressed bytes: the browser
    // never hands us a full-size surface, so there is nothing to hold
    scaled = source
      ? await createImageBitmap(source, resize)
      : await createImageBitmap(blob, { ...resize, imageOrientation: 'from-image' });
    // the full-size surface has done its job — release it before the draw and
    // the encode rather than at the end of the function, or its w × h × 4 bytes
    // stay resident for the whole of the slowest step
    source?.close?.();
    source = null;
    const canvas = canvasFor(w, h);
    if (!canvas) return { blob, width: sw, height: sh, downsampled: false };
    const ctx = canvas.getContext('2d');
    if (!ctx) return { blob, width: sw, height: sh, downsampled: false };
    ctx.drawImage(scaled, 0, 0, w, h);
    // the canvas owns these pixels now; the bitmap is a second copy of them
    scaled.close();
    scaled = null;
    const out = await encode(canvas, pickEncodeType(), quality);
    // free the canvas backing store too — Safari keeps it alive with the element
    canvas.width = 0;
    canvas.height = 0;
    if (!out || !out.size) return { blob, width: sw, height: sh, downsampled: false };
    return { blob: out, width: w, height: h, downsampled: true };
  } catch {
    return fallback;
  } finally {
    source?.close?.();
    scaled?.close?.();
    releaseDecode();
  }
}

/**
 * Device pixels a full-width feed card actually paints.
 *
 * The card is capped at 540 CSS px by the layout, and devicePixelRatio is
 * capped at 2 for photographs: a 3× decode costs 2.25× the memory of a 2× one
 * for a difference nobody can see in a scrolling feed.
 */
export function cardWidthPx(env = globalThis, cap = 540) {
  const css = Math.min(env?.innerWidth || cap, cap);
  const dpr = Math.min(env?.devicePixelRatio || 1, 2);
  return Math.max(1, Math.round(css * dpr));
}

/** Device pixels the full-screen viewer paints — the whole screen, dpr capped at 2. */
export function viewerWidthPx(env = globalThis) {
  const css = env?.innerWidth || 540;
  const dpr = Math.min(env?.devicePixelRatio || 1, 2);
  return Math.max(1, Math.round(css * dpr));
}
