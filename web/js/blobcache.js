/* blobcache.js — the byte-bounded media cache that sits under td.js.
 *
 * The browser's leak in this app was never the DOM: it was `URL.createObjectURL`
 * with no matching revoke. Every photo, thumbnail, GIF and video the feed
 * touched minted a blob: URL that pinned its Blob for the life of the tab, and
 * the registry had no bound of any kind — not bytes, not entries. Scrolling a
 * long feed on a phone therefore grew without limit until the tab was killed.
 *
 * MediaCache is the fix: one LRU keyed by TDLib's file key (plus a rendition
 * suffix), bounded by TOTAL BYTES first and entry count second, revoking every
 * URL it drops and never handing a revoked URL back out.
 *
 * Pure and DOM-free on purpose — `create`/`revoke` are injected, so the cost
 * accounting and the eviction order are unit-testable under node
 * (test/protocol.test.mjs).
 */

export const MB = 1024 * 1024;

/** Bytes a decoded RGBA pixel costs on the compositor's side. */
const BYTES_PER_PIXEL = 4;

/**
 * Ceiling and floor for the decoded-media budget. The ceiling is deliberately
 * in the tens of MB: a browser tab that keeps more decoded imagery than this
 * is trading a feed nobody scrolls back to for the tab itself.
 */
const BUDGET_CEILING = 48 * MB;
const BUDGET_FLOOR = 12 * MB;

/**
 * What the whole page may occupy before the OS starts looking at it. iOS
 * Safari kills a tab whose footprint passes roughly 200–400 MB, and tdweb's
 * wasm heap plus the DOM already claim a large slice of that.
 */
const PAGE_CEILING = 384 * MB;

/** Conservative device-RAM assumption when navigator.deviceMemory is absent (Safari never reports it). */
const ASSUMED_DEVICE_GIB = 2;

/**
 * Derive the decoded-media budget from what the runtime will actually tell us,
 * rather than picking a number.
 *
 *   1. Device RAM: `navigator.deviceMemory` (GiB, coarse, spec-capped at 8).
 *      Safari does not implement it, so assume a 2 GiB phone when it is absent.
 *   2. Page share: a tab gets nowhere near the device's RAM. A quarter of it,
 *      capped at PAGE_CEILING, is the most this page should ever occupy —
 *      on every phone the cap is the binding term, which is the point.
 *   3. Chrome also exposes `performance.memory.jsHeapSizeLimit`; when present
 *      it is a harder fact than the estimate above, so take the smaller.
 *   4. The decoded-image cache gets ONE EIGHTH of that page budget. The other
 *      seven eighths are the wasm heap, the DOM, the JS heap and the blobs
 *      still being downloaded — the cache is a guest here, not the tenant.
 *   5. Clamp into [12 MB, 48 MB] so a wrong or missing signal cannot produce
 *      either a useless cache or an unbounded one.
 *
 * On a typical phone: min(2 GiB / 4, 384 MB) = 384 MB → /8 = 48 MB → the
 * ceiling. On a 512 MB device: 128 MB → /8 = 16 MB.
 */
export function mediaBudgetBytes(env = globalThis) {
  const gib = Number(env?.navigator?.deviceMemory) || ASSUMED_DEVICE_GIB;
  let page = Math.min((gib * 1024 * MB) / 4, PAGE_CEILING);
  const heapLimit = Number(env?.performance?.memory?.jsHeapSizeLimit) || 0;
  if (heapLimit > 0) page = Math.min(page, heapLimit);
  return Math.round(Math.max(BUDGET_FLOOR, Math.min(BUDGET_CEILING, page / 8)));
}

/**
 * Entry cap. Bytes are the binding constraint by design; this only stops a
 * pathological run of tiny renditions (stickers, avatars) from turning the
 * cache into a hash table with thousands of live blob: URLs.
 */
export const DEFAULT_MAX_ENTRIES = 256;

/**
 * Cache key for one rendition of one file. `width` null means "the bytes
 * Telegram sent" — the viewer asks for a bigger rendition than the feed card
 * did, and both live in the cache side by side under different keys.
 */
export function renditionKey(fileKey, width = null) {
  return width ? `${fileKey}@${Math.round(width)}` : `${fileKey}@full`;
}

/** True decoded cost of a blob: the surface it paints, or its bytes when unknown. */
export function costOf(blob, width = 0, height = 0) {
  const bytes = Number(blob?.size) || 0;
  if (width > 0 && height > 0) return Math.max(bytes, Math.round(width * height * BYTES_PER_PIXEL));
  return bytes;
}

const defaultCreate = (blob) => URL.createObjectURL(blob);
const defaultRevoke = (url) => URL.revokeObjectURL(url);

/** How many revoked URLs to remember, so a stale reference can be recognised. */
const REVOKED_MEMORY = 512;

export class MediaCache {
  constructor({ maxBytes = mediaBudgetBytes(), maxEntries = DEFAULT_MAX_ENTRIES, create = defaultCreate, revoke = defaultRevoke } = {}) {
    this.maxBytes = Math.max(1, maxBytes);
    this.maxEntries = Math.max(1, maxEntries);
    this.create = create;
    this.revoke = revoke;
    /** key → { blob, url, bytes, pins } in LRU order (least recent first). */
    this.entries = new Map();
    this.bytes = 0;
    this.evictions = 0;
    this.revokedCount = 0;
    this.revoked = new Set();
  }

  get size() {
    return this.entries.size;
  }

  has(key) {
    return this.entries.has(key);
  }

  /** Was this URL string revoked by this cache? Nothing may hand it out again. */
  wasRevoked(url) {
    return this.revoked.has(url);
  }

  /** Move an entry to the most-recent end and return it. */
  touch(key) {
    const e = this.entries.get(key);
    if (!e) return null;
    this.entries.delete(key);
    this.entries.set(key, e);
    return e;
  }

  /**
   * Store a blob under `key`, charging its real cost: the decoded surface
   * (width × height × 4) when the dimensions are known, otherwise the buffer's
   * own byte length. Replacing an entry refunds the old cost and revokes its
   * URL — a superseded URL must never stay live.
   */
  put(key, blob, { width = 0, height = 0 } = {}) {
    const existing = this.entries.get(key);
    // storing the same blob again is a no-op, not a replacement: revoking the
    // live URL for a picture that is already on screen would blank it
    if (existing && existing.blob === blob) return this.touch(key);
    if (existing) this.drop(key);
    const bytes = costOf(blob, width, height);
    this.entries.set(key, { blob, url: null, bytes, pins: 0, width, height });
    this.bytes += bytes;
    // a blob bigger than the whole budget (a video being played) still has to
    // be reachable by the caller that just asked for it: it is never its own
    // eviction victim, and the next insert takes it out
    this.enforce(key);
    return this.entries.get(key) ?? null;
  }

  /** The blob stored for `key`, or null. Counts as a use. */
  blobOf(key) {
    return this.touch(key)?.blob ?? null;
  }

  /**
   * The blob: URL for `key`, minted on first use, or null when the entry is
   * gone. Never returns a URL this cache has revoked: if one is somehow still
   * on the entry, it is replaced with a fresh one.
   */
  url(key) {
    const e = this.touch(key);
    if (!e) return null;
    if (e.url && this.revoked.has(e.url)) e.url = null;
    if (!e.url) e.url = this.create(e.blob);
    return e.url;
  }

  /**
   * Hold an entry against eviction — the photo the full-screen viewer is
   * showing, the audio that is playing. Pinned bytes still count toward the
   * budget; they are simply skipped when choosing a victim.
   */
  pin(key) {
    const e = this.touch(key);
    if (e) e.pins += 1;
    return !!e;
  }

  unpin(key) {
    const e = this.entries.get(key);
    if (e && e.pins > 0) e.pins -= 1;
  }

  /** Drop one entry: revoke its URL, refund its bytes, forget it. */
  drop(key) {
    const e = this.entries.get(key);
    if (!e) return false;
    this.entries.delete(key);
    this.bytes -= e.bytes;
    if (this.bytes < 0) this.bytes = 0;
    if (e.url) {
      try {
        this.revoke(e.url);
      } catch {
        // a revoke that throws must not wedge eviction
      }
      this.revokedCount += 1;
      this.revoked.add(e.url);
      if (this.revoked.size > REVOKED_MEMORY) this.revoked.delete(this.revoked.values().next().value);
    }
    return true;
  }

  /** Evict least-recently-used unpinned entries until both bounds hold. */
  enforce(protect = null) {
    let evicted = 0;
    if (this.bytes <= this.maxBytes && this.entries.size <= this.maxEntries) return evicted;
    for (const [key, e] of [...this.entries]) {
      if (this.bytes <= this.maxBytes && this.entries.size <= this.maxEntries) break;
      if (key === protect) continue;
      if (e.pins > 0) continue; // in use on screen; the budget takes the hit instead
      this.drop(key);
      evicted += 1;
    }
    this.evictions += evicted;
    return evicted;
  }

  /** Shrink to a fraction of the budget (a backgrounded tab keeps a little, not everything). */
  trimTo(fraction) {
    const was = this.maxBytes;
    this.maxBytes = Math.max(1, Math.round(was * fraction));
    const n = this.enforce();
    this.maxBytes = was;
    return n;
  }

  /** Release everything droppable. Returns how many entries went. */
  clear() {
    let n = 0;
    for (const [key, e] of [...this.entries]) {
      if (e.pins > 0) continue;
      this.drop(key);
      n += 1;
    }
    return n;
  }

  /** Re-bound the cache at runtime (tests, and a device that changes its mind). */
  configure({ maxBytes = this.maxBytes, maxEntries = this.maxEntries } = {}) {
    this.maxBytes = Math.max(1, maxBytes);
    this.maxEntries = Math.max(1, maxEntries);
    return this.enforce();
  }

  /** Introspection for the Status sheet and the flow test. */
  stats() {
    return {
      entries: this.entries.size,
      bytes: this.bytes,
      maxBytes: this.maxBytes,
      maxEntries: this.maxEntries,
      evictions: this.evictions,
      revoked: this.revokedCount,
    };
  }
}
