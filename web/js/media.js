/* media.js — everything a post can carry, inside the app (PRODUCT §2.11).
 *
 * Inline blocks (photo blur-up, video player, GIF autoplay, audio/voice rows,
 * video notes, documents, stickers, link previews, summaries), the full-screen
 * viewer (ink 96%, pinch/double-tap zoom, swipe-down dismiss, album swipe),
 * one-audio-at-a-time with the now-playing row docked above the floating tab
 * bar, visibility-driven downloads (priority 1 visible / 32 tapped) with the
 * gold determinate ring, tap to cancel.
 *
 * Nothing here hands off to Telegram or the browser; only link previews and
 * the explicit Open in Telegram button do (shared.js).
 *
 * The audio scrubber is the spectrogram strip of PRODUCT §2.11.1, not a
 * hairline: js/strip.js computes it (off the main thread, at a decimated rate,
 * capped by duration) and the row below arms that analysis on visibility and on
 * the play tap, never on render. A voice note draws Telegram's own waveform
 * bytes as its silhouette immediately, with no decode, and the spectrum fills
 * in behind it. A video NOTE gets the same strip as its transport under the
 * circle (videoNoteBlock); a video MESSAGE keeps its poster and hairline, which
 * is the line §2.11.1 draws — the strip replaces the audio scrubber only.
 *
 * Memory: every picture on this screen goes through td.imageUrl(), which
 * decodes at the size the card paints and caches the result under a byte
 * bound (js/blobcache.js). Nothing here calls URL.createObjectURL, nothing
 * here keeps a decoded copy of its own, and everything that binds a picture to
 * an element registers itself so a memory-pressure flush can repaint it
 * instead of leaving a hole (watchMedia / releaseMedia below).
 */
import { h, replace, button, media, pill, icon, ring, scrubber, strip, playerRow, nowPlaying, tokenValue, viewer } from '../vendor/house-pour.js';
import { cachedEnvelope, ensureStrip, onStripReady, releaseStrip, stripPixels } from './strip.js';
import { deepLink, formatDuration } from './protocol.js';
import { pickPhotoSize } from './repo.js';
import { cardWidthPx, viewerWidthPx } from './decode.js';
import { mosaicPlan, mosaicRatio, tileArea } from './mosaic.js';

// ── file plumbing ──────────────────────────────────────────────────────────

/** Rehydrate a slim file ({ id, uniqueId, done, size }) into a TDLib File shell. */
function fullFile(slim) {
  return { id: slim.id, size: slim.size ?? 0, remote: { unique_id: slim.uniqueId }, local: { is_downloading_completed: !!slim.done } };
}

/**
 * A file whose bytes are already somewhere this page can read, as opposed to a
 * TDLib id we have to download first:
 *   - a public page's preview file (PUBLIC.md §3 — Telegram serves the
 *     preview's media straight off its CDN), scheme-checked in the parser, so
 *     only http/https ever reaches here;
 *   - the demo's generated media (PRODUCT §2.22.1), produced in this page and
 *     handed over as a data: or blob: URL.
 *
 * This is the single seam that lets §2.3's post card, §2.11's players and the
 * full-screen viewer render a preview post, a demo post and a TDLib post with
 * one set of code: everything below asks for a URL, and this answers without
 * a download when there is nothing to download.
 *
 * It may answer a PROMISE of one. The demo's video and animation are
 * procedural frame sources recorded off a canvas in real time (§2.22.1), so
 * they are not a string yet when the card is built; every caller below already
 * had to await a download, so awaiting this costs nothing.
 */
function directUrl(slim) {
  const url = slim?.url;
  if (typeof url === 'string' && url) return url;
  if (url && typeof url.then === 'function') return url;
  return null;
}

const DOWNLOAD_LABELS = {
  photo: 'Downloading photo',
  video: 'Downloading video',
  animation: 'Downloading GIF',
  audio: 'Downloading audio',
  voice: 'Downloading voice message',
  videoNote: 'Downloading video note',
  document: 'Downloading file',
  sticker: 'Downloading sticker',
};

function labelFor(kind) {
  return DOWNLOAD_LABELS[kind] ?? 'Downloading file';
}

export function formatSize(bytes) {
  const b = Math.max(0, Number(bytes) || 0);
  if (b < 1024) return `${b} B`;
  const kb = b / 1024;
  if (kb < 1024) return `${kb < 10 ? Math.round(kb * 10) / 10 : Math.round(kb)} KB`;
  const mb = kb / 1024;
  if (mb < 1024) return `${mb < 10 ? Math.round(mb * 10) / 10 : Math.round(mb)} MB`;
  const gb = mb / 1024;
  return `${Math.round(gb * 10) / 10} GB`;
}

/** Fires fn once when el first enters the viewport (±one screen). */
const pendingVisible = new Map();
let visObserver = null;

/**
 * Elements that were watched but never became visible — a card trimmed out of
 * the feed window, a screen replaced mid-scroll — would otherwise sit in this
 * map (and in the observer) for the life of the tab, holding their subtree.
 */
function pruneVisible() {
  for (const el of [...pendingVisible.keys()]) {
    if (el.isConnected) continue;
    pendingVisible.delete(el);
    visObserver?.unobserve(el);
  }
}

function whenVisible(el, fn) {
  if (typeof IntersectionObserver === 'undefined') {
    fn();
    return;
  }
  if (!visObserver) {
    visObserver = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        const cb = pendingVisible.get(e.target);
        pendingVisible.delete(e.target);
        visObserver.unobserve(e.target);
        if (cb) cb();
      }
      pruneVisible();
    }, { rootMargin: '100% 0px' });
  }
  pendingVisible.set(el, fn);
  visObserver.observe(el);
}

function unwatchVisible(el) {
  if (!pendingVisible.has(el)) return;
  pendingVisible.delete(el);
  visObserver?.unobserve(el);
}

// ── picture bindings (memory-pressure repaint) ─────────────────────────────

/**
 * Every element currently showing a picture that came out of the media cache,
 * with the callback that can fetch it again. A flush revokes the URLs those
 * elements are pointing at; without this the feed would keep painting the last
 * frame it decoded and show nothing at all for anything scrolled past.
 */
const bindings = new Set();

function bind(el, reload) {
  for (const b of bindings) {
    if (b.el !== el) continue;
    b.reload = reload;
    return b;
  }
  const entry = { el, reload };
  bindings.add(entry);
  return entry;
}

function pruneBindings() {
  for (const b of [...bindings]) if (!b.el.isConnected) bindings.delete(b);
}

/**
 * Repaint after a memory-pressure flush: anything within a screen of the
 * viewport is fetched again now, anything further away is re-armed on the
 * visibility observer so it comes back when it is scrolled to — refilling the
 * whole feed at once would just trip the byte bound again.
 */
function repaintAfterFlush() {
  pruneBindings();
  for (const b of [...bindings]) {
    const r = b.el.getBoundingClientRect();
    const near = r.bottom > -window.innerHeight && r.top < window.innerHeight * 2;
    try {
      if (near) b.reload();
      else whenVisible(b.el, b.reload);
    } catch (e) {
      console.warn('[media] repaint', e);
    }
  }
}

/**
 * Register an element that is painting a picture from the media cache, with
 * the callback that fetches it again. Used by anything outside this module
 * that binds a cached URL to an element (avatars, in views/shared.js).
 */
export function bindPicture(el, reload) {
  bind(el, reload);
}

/** Subscribe the media layer to the app's memory-pressure flushes. Called once, from boot. */
export function watchMedia(app) {
  return app.td.on('mediaFlush', () => repaintAfterFlush());
}

/**
 * Release the players and picture bindings inside a subtree that is going
 * away — a trimmed feed card, a closed viewer, a screen being replaced. A
 * <video> that keeps its src keeps its decoded frames and its blob alive long
 * after the element leaves the DOM, which is exactly what the phone runs out
 * of memory on.
 */
export function releaseMedia(root) {
  if (!root) return;
  const players = root.querySelectorAll ? [...root.querySelectorAll('video, audio')] : [];
  if (root.tagName === 'VIDEO' || root.tagName === 'AUDIO') players.push(root);
  for (const el of players) releasePlayer(el);
  for (const b of [...bindings]) if (b.el === root || root.contains?.(b.el)) bindings.delete(b);
  // a strip whose row is going away must stop being a repaint target, or the
  // analysis record holds the trimmed card the way the row registry used to
  if (root.querySelectorAll) for (const el of root.querySelectorAll('.strip')) releaseStrip(el);
  if (root.classList?.contains('strip')) releaseStrip(root);
  pruneAudioRows(root);
  if (root.querySelectorAll) for (const el of root.querySelectorAll('*')) unwatchVisible(el);
  unwatchVisible(root);
  pruneVisible();
}

/**
 * Hold a player's bytes against eviction for exactly as long as it is playing.
 * A video whose URL is revoked mid-playback stalls; a video that is merely
 * mounted has no claim on the budget, so the pin follows play/pause rather
 * than the element's lifetime.
 */
function pinWhilePlaying(app, el, slim) {
  if (!slim?.id) return;
  const file = fullFile(slim);
  let key = null;
  const grab = () => {
    if (!key) key = app.td.pinImage(file, null);
  };
  const drop = () => {
    if (!key) return;
    app.td.unpinKey(key);
    key = null;
  };
  el.addEventListener('play', grab);
  el.addEventListener('pause', drop);
  el.addEventListener('ended', drop);
  el.tgsRelease = drop;
}

/** Stop a player and let go of its buffer. Never touches the detached audio element. */
function releasePlayer(el) {
  if (!el || el === detachedAudio.el) return;
  el.tgsRelease?.();
  liveMedia.delete(el);
  offscreenObserver?.unobserve(el);
  try {
    el.pause();
  } catch {
    // a player that never started cannot be paused; nothing to do
  }
  el.removeAttribute('src');
  try {
    el.load();
  } catch {
    // load() throws on a detached element in some browsers — the src is gone either way
  }
}

/**
 * Visibility-driven download with the gold ring over the placeholder.
 * Starts at priority 1 when `container` scrolls near the viewport (or at 32
 * at once with { eager }); the ring cancels on tap; a cancelled or failed
 * download leaves a resume affordance. onUrl(url) fires with the blob URL.
 * Returns { start(priority) } so a tap can begin/bump the download.
 */
export function autoLoad(app, container, slim, { kind, mime = null, onUrl, auto = true, showRing = true, decodeWidth = null }) {
  // a preview file is already at a URL: nothing to download, no ring, no
  // decode budget — paint it and we are done
  const direct = directUrl(slim);
  if (direct) {
    const paint = () => Promise.resolve(direct).then(onUrl).catch(() => null);
    paint();
    return { start: () => {}, reload: paint };
  }
  if (!slim?.id) return { start: () => {} };
  const file = fullFile(slim);
  // a picture goes through the downsampling decode path and is cached at the
  // size this card paints; anything else (video, audio, a document) keeps its
  // bytes as they came
  const fetchUrl = (priority, onProgress) => (decodeWidth
    ? app.td.imageUrl(file, { width: decodeWidth, priority, label: labelFor(kind), mime, onProgress })
    : app.td.fileUrlOrThrow(file, { priority, label: labelFor(kind), mime, onProgress }));
  let ringEl = null;
  let resumeEl = null;
  let state = 'idle';
  const clearChrome = () => {
    if (ringEl) ringEl.remove();
    if (resumeEl) resumeEl.remove();
    ringEl = null;
    resumeEl = null;
  };
  const showResume = () => {
    clearChrome();
    resumeEl = h('button.media-play', { type: 'button', 'aria-label': 'Download' }, h('span.disc', icon('download')));
    resumeEl.addEventListener('click', (e) => {
      e.stopPropagation();
      start(32);
    });
    container.append(resumeEl);
  };
  const start = (priority = 1) => {
    if (state === 'done') return;
    if (state === 'loading') {
      // bump: a tap on already-downloading media raises the priority to 32
      if (priority > 1) app.td.download(file, { priority, label: labelFor(kind) }).catch(() => null);
      return;
    }
    state = 'loading';
    clearChrome();
    if (showRing) {
      ringEl = ring({ onCancel: () => app.td.cancel(slim.id) });
      container.append(ringEl);
    }
    fetchUrl(priority, (f) => ringEl?.set(f))
      .then((url) => {
        state = 'done';
        clearChrome();
        if (!url) throw new Error('File is empty.');
        onUrl(url);
        // the URL just handed over can be revoked under memory pressure; this
        // is what puts the picture back afterwards
        if (decodeWidth) bind(container, reload);
      })
      .catch(() => {
        state = 'idle';
        showResume();
      });
  };
  /** Fetch again after a flush revoked what we were showing. */
  const reload = () => {
    if (state === 'loading') return;
    state = 'idle';
    start(1);
  };
  // already decoded at this size: paint it now, and keep the binding so a
  // flush can fetch it again (the declarations above have to exist first —
  // the reload closure is live from here on)
  const cached = decodeWidth ? app.td.cachedImageUrl(file, decodeWidth) : app.td.cachedUrl(file);
  if (cached) {
    state = 'done';
    onUrl(cached);
    if (decodeWidth) bind(container, reload);
    return { start, reload };
  }
  if (auto) whenVisible(container, () => start(1));
  return { start, reload };
}

/**
 * The clip's raw bytes, for the strip's analysis (js/strip.js). Priority is the
 * caller's: 1 for a row that merely scrolled into view, 32 for one that was
 * tapped, as §2.11 requires of every media fetch. The Blob is the SAME one the
 * player will use, already in the media cache under the file key, so analysing
 * a row and then playing it is one download and not two.
 */
function bytesFor(app, slim, kind, mime, priority) {
  const direct = directUrl(slim);
  if (direct) return Promise.resolve(direct).then((u) => fetch(u)).then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(new Error(`Fetch ${r.status}`))));
  if (!slim?.id) return Promise.reject(new Error('File is empty.'));
  return app.td
    .fileBlobOrThrow(fullFile(slim), { priority, label: labelFor(kind), mime })
    .then((blob) => blob.arrayBuffer());
}

/** Resolve a slim file to a playable URL at tap priority; rejects on cancel/failure. */
function urlFor(app, slim, kind, mime = null) {
  const direct = directUrl(slim);
  if (direct) return Promise.resolve(direct);
  // a preview block can carry a thumbnail and no file at all (Telegram serves
  // some media only in the app); that is a failure to play, not a crash
  if (!slim?.id) return Promise.reject(new Error('File is empty.'));
  return app.td.fileUrlOrThrow(fullFile(slim), { priority: 32, label: labelFor(kind), mime });
}

// ── exclusive playback ─────────────────────────────────────────────────────

/** All live media elements; starting one pauses every other (PRODUCT §2.11). */
const liveMedia = new Set();

function exclusive(el) {
  liveMedia.add(el);
  el.addEventListener('play', () => {
    for (const other of [...liveMedia]) {
      // anything that was rendered away is pruned and released here: only the
      // detached now-playing audio survives without a parent (it is deliberately
      // kept alive across re-renders), everything else is a leak if it stays
      if (other !== detachedAudio.el && !other.isConnected) {
        releasePlayer(other);
        continue;
      }
      if (other !== el && !other.paused) other.pause();
    }
  });
}

/** Pause a video when it leaves the viewport. */
let offscreenObserver = null;

function pauseOffscreen(video) {
  if (typeof IntersectionObserver === 'undefined') return;
  if (!offscreenObserver) {
    offscreenObserver = new IntersectionObserver((entries) => {
      for (const e of entries) {
        // a video whose card was trimmed or re-rendered away is released, not
        // just paused — otherwise the observer holds it and it holds its buffer
        if (!e.target.isConnected) {
          releasePlayer(e.target);
          continue;
        }
        if (!e.isIntersecting && !e.target.paused && !e.target.muted) e.target.pause();
      }
    }, { threshold: 0 });
  }
  offscreenObserver.observe(video);
}

// ── one-audio-at-a-time + now-playing dock ─────────────────────────────────

const detachedAudio = {
  el: null, // HTMLAudioElement, survives view re-renders
  key: null,
  meta: null,
  loading: false,
  np: null, // now-playing row in the dock
  rows: new Set(), // { row, key } player rows currently bound
  pinned: null, // media-cache key held against eviction while this plays
  offStrip: null, // unsubscribe from strip.js while a clip is docked
  wave: null, // { key, columns, values } — the dock's resample, kept per clip
};

/**
 * The two things this module needs from the app but must not import: opening a
 * post (js/views/shared.js owns the Thread route) and rendering a comment
 * thread (js/views/comments.js renders media, which is this file). Both live
 * upstream of media.js in the import graph, so js/app.js — which already
 * imports everything — hands them down here instead, the same shape as the
 * `openExternal` that `mediaBlocks` takes.
 */
const host = { openPost: null, comments: null };

/** js/app.js wires the host once, at boot. */
export function useHost(fns) {
  Object.assign(host, fns);
}

function audioRowsFor(key) {
  const out = [];
  for (const ref of [...detachedAudio.rows]) {
    if (!ref.row.isConnected) detachedAudio.rows.delete(ref);
    else if (ref.key === key) out.push(ref.row);
  }
  return out;
}

/**
 * Forget the player rows inside a subtree that is going away, and any row that
 * has already left the document.
 *
 * `audioRowsFor` only prunes while something is playing, so without this a
 * feed of voice notes nobody pressed play on kept one entry per post for the
 * life of the tab — and each entry holds its row, which holds its parent chain,
 * which is the whole trimmed post card and every picture in it. Called from
 * releaseMedia, so the registry is pruned by exactly the same sweep that
 * releases the players and the picture bindings.
 *
 * `root` is still in the document when releaseMedia runs (the caller removes it
 * afterwards), so containment is what identifies the doomed rows, not
 * isConnected.
 */
function pruneAudioRows(root = null) {
  for (const ref of [...detachedAudio.rows]) {
    const doomed = !ref.row.isConnected || (root && (ref.row === root || root.contains?.(ref.row)));
    if (doomed) detachedAudio.rows.delete(ref);
  }
}

function paintAudio(app) {
  const a = detachedAudio;
  if (!a.el || !a.key) return;
  const playing = !a.el.paused && !a.el.ended;
  const elapsed = formatDuration(a.el.currentTime);
  const fraction = a.el.duration ? a.el.currentTime / a.el.duration : 0;
  for (const row of audioRowsFor(a.key)) {
    row.setPlaying(playing);
    row.setTime(elapsed, formatDuration(a.el.duration || a.meta.duration || 0));
    row.set(fraction);
    row.setBusy(a.loading);
  }
  if (a.el.ended) {
    stopAudio(app);
    dockNowPlaying(app, null);
    return;
  }
  if (!a.np) {
    dockNowPlaying(app, nowPlaying({
      title: a.meta.title,
      onToggle: () => toggleAudio(app, a.meta),
      onSeek: (f) => seekAudio(app, a.meta, f),
      // §2.11: "Tapping the row anywhere but its controls opens the post the
      // audio came from." The controls stop their own gestures; this is the row.
      onOpen: host.openPost && a.meta.post ? () => host.openPost(a.meta.post) : null,
    }));
  }
  a.np.setPlaying(playing);
  a.np.setTime(elapsed);
  a.np.set(fraction);
  paintDockWave();
}

/**
 * PRODUCT §2.11.2 — the dock's waveform is "a view of the analysis the strip
 * already did", so this only ever READS: `cachedEnvelope` returns the strip's
 * own envelope resampled to the dock's column count, and null for every state
 * that has none (pending, refused, or the hairline a failed decode left). Null
 * is the flat line, not an empty row.
 *
 * Playing a clip therefore starts no analysis of its own. The one the play tap
 * arms is the STRIP's (`audioBlock`'s `analyse(32)`), keyed on the file, and
 * this row joins its result rather than asking for a second.
 */
function paintDockWave() {
  const a = detachedAudio;
  if (!a.np || !a.meta) return;
  const columns = a.np.wave.columns;
  // `timeupdate` lands about four times a second and the playhead has to be
  // repainted every time; the ENVELOPE has not changed, so it is resampled once
  // per clip and per width instead of once per tick.
  if (a.wave?.key === a.meta.key && a.wave.columns === columns && a.wave.values) return;
  const values = cachedEnvelope(a.meta, columns);
  a.wave = { key: a.meta.key, columns, values };
  a.np.setEnvelope(values);
}

/** Playback is over: unpin the file, let the element go, forget the item. */
function stopAudio(app) {
  const a = detachedAudio;
  const gone = a.el;
  a.el = null;
  a.key = null;
  a.meta = null;
  if (a.pinned) {
    app.td.unpinKey(a.pinned);
    a.pinned = null;
  }
  if (!gone) return;
  liveMedia.delete(gone);
  gone.removeAttribute('src');
  try {
    gone.load();
  } catch {
    // detached element; the src is already gone
  }
}

function dockNowPlaying(app, el) {
  if (detachedAudio.np) detachedAudio.np.remove();
  detachedAudio.np = el;
  detachedAudio.wave = null;
  if (detachedAudio.offStrip) {
    detachedAudio.offStrip();
    detachedAudio.offStrip = null;
  }
  // The strip is usually analysed before anything is played (§2.11.1 arms it on
  // visibility), but a row tapped the moment it scrolls in is not: this paints
  // the mini waveform when that analysis settles, without starting one.
  if (el) {
    detachedAudio.offStrip = onStripReady(() => {
      detachedAudio.wave = null;
      paintDockWave();
    });
  }
  if (el) app.els.dock.prepend(el);
  document.body.toggleAttribute('data-now-playing', !!el);
  // the dock stays visible for the row even where the tab bar is hidden, and
  // the column's --dock-extra inset follows the row's mount/unmount
  app.updateDock();
}

/** The detached audio element while one is live, or null (state introspection / tests). */
export function currentAudio() {
  return detachedAudio.el;
}

/**
 * The player rows the audio dock is tracking: how many are registered, and how
 * many of those are still in the document. The two must stay equal — a gap is
 * the registry retaining trimmed cards (state introspection / test/flows.mjs).
 */
export function audioRowStats() {
  let connected = 0;
  for (const ref of detachedAudio.rows) if (ref.row.isConnected) connected += 1;
  return { rows: detachedAudio.rows.size, connected };
}

/**
 * Play/pause an audio item. meta: { key, kind, title, sub, duration, file,
 * mime, waveform }. Starting a different item stops the current one.
 */
async function toggleAudio(app, meta) {
  const a = detachedAudio;
  if (a.key === meta.key && a.el) {
    if (a.el.paused) a.el.play().catch(() => null);
    else a.el.pause();
    paintAudio(app);
    return;
  }
  if (a.el) {
    // the element goes: pausing it is not enough, it holds its buffer (and the
    // blob behind it) until the src is gone
    const gone = a.el;
    a.el = null;
    gone.pause();
    liveMedia.delete(gone);
    gone.removeAttribute('src');
    try {
      gone.load();
    } catch {
      // detached element; the src is already gone
    }
  }
  if (a.pinned) {
    app.td.unpinKey(a.pinned);
    a.pinned = null;
  }
  a.key = meta.key;
  a.meta = meta;
  a.loading = true;
  for (const row of audioRowsFor(meta.key)) row.setBusy(true);
  let url;
  try {
    url = await urlFor(app, meta.file, meta.kind, meta.mime);
  } catch (e) {
    a.loading = false;
    for (const row of audioRowsFor(meta.key)) row.setBusy(false);
    if (!e?.cancelled) app.toast("Couldn't play this audio.", 'bad');
    return;
  }
  if (a.key !== meta.key) return; // another item took over while downloading
  a.loading = false;
  const el = new Audio(url);
  a.el = el;
  // the URL this element is playing must survive an eviction sweep
  a.pinned = app.td.pinImage(fullFile(meta.file), null);
  exclusive(el);
  for (const ev of ['play', 'pause', 'ended', 'timeupdate', 'durationchange']) {
    el.addEventListener(ev, () => paintAudio(app));
  }
  el.play().catch(() => null);
  paintAudio(app);
}

function seekAudio(app, meta, fraction) {
  const a = detachedAudio;
  if (a.key === meta.key && a.el && a.el.duration) {
    a.el.currentTime = fraction * a.el.duration;
    paintAudio(app);
  }
}

/** Telegram voice waveform: base64 of packed 5-bit samples → `bars` values 0..1. */
export function decodeWaveform(b64, bars = 40) {
  if (!b64) return null;
  let bytes;
  try {
    const bin = atob(b64);
    bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
  } catch {
    return null;
  }
  const count = Math.floor((bytes.length * 8) / 5);
  if (!count) return null;
  const values = new Array(count);
  for (let i = 0; i < count; i += 1) {
    const bit = i * 5;
    const byte = bit >> 3;
    const shift = bit & 7;
    values[i] = ((bytes[byte] | ((bytes[byte + 1] ?? 0) << 8)) >> shift) & 0x1f;
  }
  const out = new Array(bars).fill(0);
  for (let i = 0; i < bars; i += 1) {
    const from = Math.floor((i * count) / bars);
    const to = Math.max(from + 1, Math.floor(((i + 1) * count) / bars));
    let sum = 0;
    for (let j = from; j < to; j += 1) sum += values[j];
    out[i] = sum / (to - from) / 31;
  }
  return out;
}

// ── inline blocks ──────────────────────────────────────────────────────────

/**
 * Device pixels a full-width card paints — which is also the size we ask
 * Telegram for and the size we decode to. devicePixelRatio is capped at 2 in
 * cardWidthPx(): a 3× decode is 2.25× the memory for a difference nobody sees
 * in a scrolling feed.
 */
function targetWidth() {
  return cardWidthPx(window);
}

/** Device pixels a link-preview / video thumbnail paints. */
const THUMB_PX = 288;

function stop(e) {
  e.stopPropagation();
}

function mediaBox(aspect, mini) {
  const box = media(null, aspect, { mini });
  box.classList.add('post-media');
  return box;
}

function photoBlock(app, post, item, index) {
  const size = pickPhotoSize(item.sizes, targetWidth());
  if (!size) return null;
  const box = mediaBox(`${size.w} / ${size.h}`, item.mini);
  const load = autoLoad(app, box, size.file, { kind: 'photo', decodeWidth: targetWidth(), onUrl: (url) => box.setImage(url) });
  box.setAttribute('role', 'button');
  box.setAttribute('tabindex', '0');
  box.setAttribute('aria-label', 'View photo');
  box.addEventListener('click', (e) => {
    stop(e);
    load.start(32);
    openViewer(app, post, index);
  });
  box.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      stop(e);
      openViewer(app, post, index);
    }
  });
  return box;
}

/**
 * CSS px a full-width media block paints inside a post card: the app column
 * (capped at `columnMax`) less its side padding and the card's own padding on
 * both sides. Summed from the tokens the cascade actually holds rather than
 * measuring a laid-out element, which is the same trick js/strip.js plays with
 * `PLAYER_LEAD_CSS` — and the reason the feed and the thread agree on one tile
 * size, and therefore one cache key, instead of forking it over a pixel.
 */
function mosaicWidthCss(env = window) {
  const t = (name, fallback) => {
    const v = parseFloat(tokenValue(document.documentElement, name, ''));
    return Number.isFinite(v) ? v : fallback;
  };
  const columnMax = t('--space-column-max', 540);
  const side = t('--space-column-side', 14);
  const pad = t('--space-card-pad', 20);
  return Math.max(1, Math.min(env?.innerWidth || columnMax, columnMax) - 2 * side - 2 * pad);
}

/**
 * Device pixels ONE mosaic tile paints. Every layout in §2.11.3 is two columns
 * wide — even the three-up, whose tall leading tile is half the block — so a
 * tile is never more than half the card, and that is the size the tiles are
 * requested and decoded at. Four full-screen renditions to draw one summary
 * block is exactly the decode this cap exists to refuse; the carousel asks for
 * the big one, and only for the item it is showing (`buildPhotoSlide`).
 */
function mosaicTilePx(env = window) {
  const dpr = Math.min(env?.devicePixelRatio || 1, 2);
  return Math.max(1, Math.round((mosaicWidthCss(env) / 2) * dpr));
}

/** The clamped block ratio for these photos, with the bounds read as tokens. */
function mosaicBlockRatio(photos, shown) {
  const num = (name, fallback) => {
    const v = parseFloat(tokenValue(document.documentElement, name, ''));
    return Number.isFinite(v) ? v : fallback;
  };
  const aspects = photos.slice(0, shown).map(({ item }) => {
    const size = item.sizes?.[item.sizes.length - 1];
    return size?.w && size?.h ? size.w / size.h : NaN;
  });
  return mosaicRatio(aspects, shown, { min: num('--ratio-mosaic-min', 0.8), max: num('--ratio-mosaic-max', 1.9) });
}

/**
 * PRODUCT §2.11.3 — a post with more than one photo is a MOSAIC, not a stack.
 *
 * The arrangement is one CSS grid with `grid-template-areas` per count
 * (css/app.css, keyed on `data-count`); js/mosaic.js is the shared rule both
 * that stylesheet and test/flows.mjs read. Here we only place the tiles into
 * `a`…`d` in album order, set the block's clamped ratio, and hang the `+N`
 * pill over the fourth when there are more.
 *
 * `radius-media` and `overflow: hidden` live on the block, so the radius lands
 * on the OUTER corners only and the hairline `line` gutters read as one object
 * (the grid's gap is the border width over a `line` background).
 *
 * "Tapping any tile opens the carousel at that tile": each tile carries its own
 * ALBUM index, which is what `openViewer` maps onto the viewable items.
 */
function photoMosaic(app, post, photos) {
  const plan = mosaicPlan(photos.length);
  const el = h('div.post-mosaic', {
    'data-count': String(plan.shown),
    style: { aspectRatio: String(mosaicBlockRatio(photos, plan.shown)) },
  });
  const tilePx = mosaicTilePx();
  photos.slice(0, plan.shown).forEach(({ item, index }, i) => {
    const size = pickPhotoSize(item.sizes, tilePx);
    // the tile is an HPMedia box with no aspect of its own: the CELL sets the
    // shape and the picture covers it (§2.11.3)
    const tile = media(null, null, { mini: item.mini });
    tile.classList.add('post-mosaic-tile');
    tile.style.gridArea = tileArea(i);
    tile.setAttribute('role', 'button');
    tile.setAttribute('tabindex', '0');
    tile.setAttribute('aria-label', `View photo ${i + 1} of ${photos.length}`);
    if (size?.file) {
      autoLoad(app, tile, size.file, { kind: 'photo', decodeWidth: tilePx, onUrl: (url) => tile.setImage(url) });
    }
    const open = (e) => {
      stop(e);
      openViewer(app, post, index);
    };
    tile.addEventListener('click', open);
    tile.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') open(e);
    });
    // §2.11.3: the fourth tile carries `+N` in the pill style over a scrim
    if (i === plan.shown - 1 && plan.extra > 0) {
      const more = pill(`+${plan.extra}`);
      more.classList.add('post-mosaic-more');
      tile.append(h('div.post-mosaic-scrim', more));
      tile.setAttribute('aria-label', `View photo ${i + 1} of ${photos.length}, ${plan.extra} more`);
    }
    el.append(tile);
  });
  return el;
}

/** Poster + play glyph + duration pill → inline video with House Pour transport. */
function videoBlock(app, post, item, index) {
  const aspect = item.w && item.h ? `${item.w} / ${item.h}` : '4 / 3';
  const box = mediaBox(aspect, item.mini);
  if (item.thumb?.file?.id) autoLoad(app, box, item.thumb.file, { kind: 'photo', showRing: false, decodeWidth: targetWidth(), onUrl: (url) => box.setImage(url) });
  const tag = pill(formatDuration(item.duration));
  tag.classList.add('post-media-tag');
  const play = h('button.media-play', { type: 'button', 'aria-label': `Play video, ${formatDuration(item.duration)}` }, h('span.disc', icon('play')));
  box.append(tag, play);
  const load = autoLoad(app, box, item.file, { kind: 'video', mime: item.mime, auto: false, onUrl: () => null });
  play.addEventListener('click', async (e) => {
    stop(e);
    play.remove();
    tag.remove();
    let url;
    try {
      url = await urlFor(app, item.file, 'video', item.mime);
    } catch (err) {
      if (!err?.cancelled) app.toast("Couldn't play this video.", 'bad');
      box.append(tag, play);
      return;
    }
    mountInlineVideo(app, box, post, item, index, url);
  });
  // start fetching at priority 1 once visible so a later tap is instant-ish
  whenVisible(box, () => load.start(1));
  return box;
}

function mountInlineVideo(app, box, post, item, index, url) {
  const video = h('video', { src: url, preload: 'metadata' });
  video.playsInline = true;
  video.setAttribute('playsinline', '');
  const playBtn = h('button.player-btn', { type: 'button', 'aria-label': 'Pause' }, icon('pause'));
  const time = h('span.player-time', '0:00');
  const scrub = videoScrubber(video);
  const controls = h('div.media-controls', playBtn, scrub, time);
  replace(box, video, controls);
  box.classList.add('loaded');
  exclusive(video);
  pinWhilePlaying(app, video, item.file);
  pauseOffscreen(video);
  playBtn.addEventListener('click', (e) => {
    stop(e);
    if (video.paused) video.play().catch(() => null);
    else video.pause();
  });
  video.addEventListener('play', () => replace(playBtn, icon('pause')));
  video.addEventListener('pause', () => replace(playBtn, icon('play')));
  video.addEventListener('timeupdate', () => {
    time.textContent = formatDuration(video.currentTime);
    scrub.set(video.duration ? video.currentTime / video.duration : 0);
  });
  // tapping the picture itself expands to the full-screen player
  video.addEventListener('click', (e) => {
    stop(e);
    video.pause();
    openViewer(app, post, index, { resumeAt: video.currentTime });
  });
  controls.addEventListener('click', stop);
  video.play().catch(() => null);
}

function videoScrubber(video) {
  return scrubber({
    onSeek: (f) => {
      if (video.duration) video.currentTime = f * video.duration;
    },
    label: 'Seek video',
  });
}

/** GIF / mp4 loop: autoplays muted and looped inline once downloaded. */
function animationBlock(app, post, item, index) {
  const aspect = item.w && item.h ? `${item.w} / ${item.h}` : '4 / 3';
  const box = mediaBox(aspect, item.mini);
  if (item.thumb?.file?.id) autoLoad(app, box, item.thumb.file, { kind: 'photo', showRing: false, decodeWidth: targetWidth(), onUrl: (url) => box.setImage(url) });
  const tag = pill('GIF');
  tag.classList.add('post-media-tag');
  box.append(tag);
  autoLoad(app, box, item.file, { kind: 'animation', mime: item.mime, onUrl: (url) => {
    const video = h('video', { src: url, loop: true });
    video.muted = true;
    video.setAttribute('muted', '');
    video.playsInline = true;
    video.setAttribute('playsinline', '');
    video.autoplay = true;
    replace(box, video, tag);
    box.classList.add('loaded');
    // a muted loop never joins the one-at-a-time set (it must not pause the
    // audio someone is listening to), but it is still observed so that a GIF
    // whose card is trimmed away is released rather than left decoding
    pauseOffscreen(video);
    video.play().catch(() => null);
    video.addEventListener('click', (e) => {
      stop(e);
      openViewer(app, post, index);
    });
  } });
  return box;
}

function audioMeta(post, item, kind) {
  return {
    key: `${post.key}:${item.file?.uniqueId ?? item.file?.id}`,
    kind,
    // the dock outlives the card, and §2.11's row tap has to be able to get
    // back to the post the audio came from
    post,
    title: kind === 'voice' ? 'Voice message' : item.title,
    sub: item.performer || '',
    duration: item.duration,
    file: item.file,
    mime: item.mime,
    waveform: item.waveform ?? null,
  };
}

/** Values for the silhouette a voice note has before anything is decoded. */
function voiceEnvelope(meta, cols) {
  const values = decodeWaveform(meta.waveform, Math.max(2, Math.min(cols, 160)));
  return values && values.length > 1 ? Float32Array.from(values) : null;
}

function audioBlock(app, post, item, kind) {
  const meta = audioMeta(post, item, kind);
  const { cols } = stripPixels();
  // The scrubber IS the spectrogram (§2.11.1): tap or drag anywhere on it to
  // seek, and its painted height is over touchMin so the 40pt region of rule 6
  // is its own drawn shape.
  const track = strip({ onSeek: (f) => seekAudio(app, meta, f), label: `Seek ${meta.title}` });
  // Telegram already shipped the shape of a voice note. Draw it NOW — the row
  // is usable the moment it appears, and the spectrum arrives behind it.
  if (kind === 'voice') {
    const bytes = voiceEnvelope(meta, cols);
    if (bytes) track.setEnvelope(bytes);
  }
  // Priority 32 is the tap (§2.11), and a tap is also the signal that somebody
  // is waiting on this row: it jumps the decode queue and it retries an
  // analysis that failed, instead of inheriting a stalled download for good.
  const analyse = (priority) => ensureStrip(app, meta, track, () => bytesFor(app, meta.file, meta.kind, meta.mime, priority), { retry: priority > 1 });
  const row = playerRow({
    title: meta.title,
    sub: meta.sub,
    duration: formatDuration(meta.duration),
    track,
    onToggle: () => {
      analyse(32);
      toggleAudio(app, meta);
    },
    label: `Play ${meta.title}`,
  });
  detachedAudio.rows.add({ row, key: meta.key });
  const wrap = h('div.post-player', row);
  wrap.addEventListener('click', stop);
  // "Analysis never runs for a row that has not been played or scrolled into
  // view" (§2.11.1) — this and the play tap above are its only two triggers
  whenVisible(wrap, () => analyse(1));
  // A strip is cache bytes like any picture, so a memory-pressure flush can
  // take it; this is what puts it back, the same binding the photos use
  bind(track, () => analyse(1));
  // rebind state when the feed re-renders mid-playback
  if (detachedAudio.key === meta.key) paintAudio(app);
  return wrap;
}

/**
 * Circular inline player for video notes, with the spectrogram strip as its
 * transport underneath — §2.11.1: "Voice notes and video notes use the same
 * strip — a video note keeps its circular player and gets the strip as the
 * transport underneath it." The sentence after that one is where the line
 * falls: a video MESSAGE keeps its poster and hairline scrubber
 * (`mountInlineVideo`), because this replaces the audio scrubber only.
 *
 * The transport arrives with the player, not before it, which is the same gate
 * iOS runs (`InlineVideoView.body`: `if mode.hasTransport, started`). Until the
 * circle is tapped there is no <video> for a strip to drive, and a scrubber
 * that seeks nothing is a control that lies. It also keeps §2.11's fetch rules
 * honest: an audio ROW is a transport from the moment it renders and therefore
 * analyses at priority 1 on visibility, while a video note is a poster until
 * somebody plays it — arming it on visibility would download every round video
 * in a scrolled feed to draw a strip nobody asked for. iOS refuses the same
 * way, from the other end: `SpectrogramScrubber.analyse` bails unless the file
 * is ALREADY local and never starts a download of its own.
 *
 * The strip drives this block's OWN <video>, not the shared audio player: a
 * video note is not part of the one-audio-at-a-time set the now-playing row
 * docks for, so `onSeek` and the playhead both go through the element — again
 * as iOS does, handing `SpectrogramScrubber` its `transport:` instead of the
 * audio model.
 *
 * The analysis reads the note's own mp4: `decodeAudioData` opens an MPEG-4
 * container and hands back its audio track, so `bytesFor` gets the same file
 * the player is already streaming and there is one download, not two. A
 * container the engine will not decode degrades like any other failure — the
 * strip keeps the §2.11 hairline and the row stays seekable.
 */
function videoNoteBlock(app, post, item) {
  const box = mediaBox('1 / 1', item.mini);
  box.classList.add('video-note');
  if (item.thumb?.file?.id) autoLoad(app, box, item.thumb.file, { kind: 'photo', showRing: false, decodeWidth: THUMB_PX, onUrl: (url) => box.setImage(url) });
  const play = h('button.media-play', { type: 'button', 'aria-label': 'Play video note' }, h('span.disc', icon('play')));
  box.append(play);
  const wrap = h('div.post-video-note', box);
  wrap.addEventListener('click', stop);

  const meta = {
    key: `${post.key}:${item.file?.uniqueId ?? item.file?.id}`,
    kind: 'videoNote',
    duration: item.duration,
    file: item.file,
    mime: item.mime,
  };

  play.addEventListener('click', async (e) => {
    stop(e);
    play.remove();
    let url;
    try {
      url = await urlFor(app, item.file, 'videoNote', item.mime);
    } catch (err) {
      if (!err?.cancelled) app.toast("Couldn't play this video.", 'bad');
      box.append(play);
      return;
    }
    const video = h('video', { src: url });
    video.playsInline = true;
    video.setAttribute('playsinline', '');
    replace(box, video);
    box.classList.add('loaded');
    exclusive(video);
    pinWhilePlaying(app, video, item.file);
    pauseOffscreen(video);
    video.addEventListener('click', (ev) => {
      stop(ev);
      if (video.paused) video.play().catch(() => null);
      else video.pause();
    });

    // The transport, now that there is something to transport. The row is
    // usable the moment it appears (§2.11.1) — the hairline is under the strip
    // from the start and the spectrum fills in behind it.
    const track = strip({
      onSeek: (f) => {
        if (video.duration) video.currentTime = f * video.duration;
      },
      label: 'Seek video note',
    });
    wrap.append(track);
    video.addEventListener('timeupdate', () => {
      track.set(video.duration ? video.currentTime / video.duration : 0);
    });
    // Priority 32, because this IS the tap (§2.11) — and a tap is also what
    // retries an analysis that failed, exactly as the audio row's does.
    const analyse = (priority) => ensureStrip(app, meta, track, () => bytesFor(app, meta.file, meta.kind, meta.mime, priority), { retry: priority > 1 });
    analyse(32);
    // A strip is cache bytes like any picture, so a memory-pressure flush can
    // take it; this is what puts it back, the same binding the photos use
    bind(track, () => analyse(1));

    video.play().catch(() => null);
  });

  return wrap;
}

const VIEWABLE_DOC = /^(application\/pdf|image\/|text\/|application\/json|audio\/|video\/)/;

function docKind(mime) {
  if (/^image\//.test(mime)) return 'image';
  if (mime === 'application/pdf') return 'pdf';
  if (/^text\/|^application\/json/.test(mime)) return 'text';
  if (/^audio\//.test(mime)) return 'audio';
  if (/^video\//.test(mime)) return 'video';
  return 'other';
}

function documentBlock(app, post, item) {
  const viewable = VIEWABLE_DOC.test(item.mime ?? '');
  // the preview gives a size line and no mime; TDLib gives bytes and a mime
  const meta = [item.file?.size ? formatSize(item.file.size) : item.extra || null, item.mime || null].filter(Boolean).join(' · ');
  // A preview file is somebody else's URL, and `download` is ignored
  // cross-origin — a button would therefore *navigate this tab* to it, off
  // tgsocial, to an address the row never showed. So a preview document's
  // action is a real link: hoverable, with its destination in the status bar,
  // opening in its own tab, and marked `noopener nofollow ugc` like every other
  // link out of the preview (PUBLIC §3). The parser has already refused every
  // host but Telegram's own; this is the wall behind that one.
  const label = viewable ? 'Open' : 'Download';
  const previewUrl = post?.source === 'preview' ? directUrl(item.file) : null;
  const action = previewUrl
    ? h('a.btn.sm', {
      href: previewUrl,
      download: item.fileName || 'file',
      target: '_blank',
      rel: 'noopener nofollow ugc',
      'aria-label': `${label} ${item.fileName}`,
    }, label)
    : button(label, { size: 'sm', ariaLabel: `${label} ${item.fileName}` });
  const row = h('div.post-file',
    icon('file'),
    h('div.post-file-text', h('div.post-file-name', item.fileName), meta ? h('div.post-file-meta', meta) : null),
    action,
  );
  row.addEventListener('click', stop);
  if (previewUrl) {
    // the link is the action; `Open` still opens the in-app viewer
    action.addEventListener('click', (e) => {
      stop(e);
      if (!viewable) return;
      e.preventDefault();
      openViewer(app, post, null, { doc: item });
    });
    return row;
  }
  action.addEventListener('click', async (e) => {
    stop(e);
    if (viewable) {
      openViewer(app, post, null, { doc: item });
      return;
    }
    // not viewable: fetch with the ring in the row, then hand the file over
    const direct = directUrl(item.file);
    const prog = ring({ onCancel: () => app.td.cancel(item.file?.id) });
    if (!direct) action.replaceWith(prog);
    try {
      const url = await (direct || app.td.fileUrlOrThrow(fullFile(item.file), { priority: 32, label: labelFor('document'), mime: item.mime, onProgress: (f) => prog.set(f) }));
      triggerDownload(url, item.fileName);
    } catch (err) {
      if (!err?.cancelled) app.toast("Couldn't download this file.", 'bad');
    } finally {
      prog.replaceWith(action);
    }
  });
  return row;
}

/** True only for an http(s) URL on somebody else's origin — blob: and our own stay false. */
function isForeignUrl(url) {
  try {
    const u = new URL(String(url), location.href);
    return /^https?:$/.test(u.protocol) && u.origin !== location.origin;
  } catch {
    return false;
  }
}

/**
 * Hand a file over. A TDLib download is a blob: on our own origin, where
 * `download` is honoured and this saves silently.
 *
 * A preview file is Telegram's CDN — a different origin, where browsers ignore
 * `download` and *follow the link instead*. A bare click would therefore
 * navigate this tab off tgsocial, so a foreign URL gets its own tab and
 * `noopener`: the reader keeps the page they were reading either way.
 */
export function triggerDownload(url, name) {
  const foreign = isForeignUrl(url);
  const a = h('a', { href: url, download: name || 'file' });
  if (foreign) {
    a.target = '_blank';
    a.rel = 'noopener nofollow ugc';
  }
  document.body.append(a);
  a.click();
  a.remove();
}

function stickerBlock(app, item) {
  const aspect = item.w && item.h ? `${item.w} / ${item.h}` : '1 / 1';
  const box = mediaBox(aspect, null);
  box.classList.add('sticker');
  // animated stickers show their thumbnail; static ones render the webp itself
  const file = item.animated ? item.thumb?.file : item.file;
  if (file?.id) autoLoad(app, box, file, { kind: 'sticker', showRing: false, decodeWidth: THUMB_PX, onUrl: (url) => box.setImage(url) });
  box.addEventListener('click', stop);
  return box;
}

function summaryBlock(item) {
  return h('div.post-summary', item.text);
}

function previewBlock(app, preview, openExternal) {
  const parts = [
    h('div.post-preview-text',
      preview.siteName ? h('div.post-preview-site', preview.siteName) : null,
      h('div.post-preview-title', preview.title),
      preview.description ? h('div.post-preview-desc', preview.description) : null,
    ),
  ];
  if (preview.thumb?.length) {
    const size = pickPhotoSize(preview.thumb, 144);
    if (size?.file?.id) {
      const thumbBox = media(null, '1 / 1', { mini: preview.mini });
      autoLoad(app, thumbBox, size.file, { kind: 'photo', showRing: false, decodeWidth: THUMB_PX, onUrl: (url) => thumbBox.setImage(url) });
      parts.push(thumbBox);
    }
  }
  const row = h('button.post-preview', { type: 'button', 'aria-label': `Open link: ${preview.title}` }, parts);
  row.addEventListener('click', (e) => {
    stop(e);
    openExternal(preview.url);
  });
  return row;
}

/**
 * All inline media blocks for a post, in order. openExternal is injected so
 * this module stays free of navigation policy.
 */
export function mediaBlocks(app, post, { openExternal }) {
  const blocks = [];
  const album = post.album?.length ? post.album : post.media ? [post.media] : [];
  // §2.11.3: more than one photo is ONE block, not a stack of them. The photos
  // leave the per-item loop below and become a mosaic; anything else in the
  // album (Telegram lets a group mix in a video) still renders as its own
  // block, in album order, after it. Each tile keeps its ALBUM index, so a tap
  // opens the carousel on that item and not on the mosaic's own numbering.
  const photos = album.map((item, index) => ({ item, index })).filter(({ item }) => item.kind === 'photo');
  const mosaic = mosaicPlan(photos.length).mosaic;
  if (mosaic) blocks.push(photoMosaic(app, post, photos));
  album.forEach((item, i) => {
    let el = null;
    if (item.kind === 'photo') el = mosaic ? null : photoBlock(app, post, item, i);
    else if (item.kind === 'video') el = videoBlock(app, post, item, i);
    else if (item.kind === 'animation') el = animationBlock(app, post, item, i);
    else if (item.kind === 'audio') el = audioBlock(app, post, item, 'audio');
    else if (item.kind === 'voice') el = audioBlock(app, post, item, 'voice');
    else if (item.kind === 'videoNote') el = videoNoteBlock(app, post, item);
    else if (item.kind === 'document') el = documentBlock(app, post, item);
    else if (item.kind === 'sticker') el = stickerBlock(app, item);
    else if (item.kind === 'summary') el = summaryBlock(item);
    if (el) blocks.push(el);
  });
  if (post.preview) blocks.push(previewBlock(app, post.preview, openExternal));
  return blocks;
}

// ── full-screen viewer ─────────────────────────────────────────────────────

const VIEWER_KINDS = new Set(['photo', 'video', 'animation', 'videoNote']);

let activeViewer = null;

/**
 * Open the full-screen viewer on a post's media (album index `index`), or on
 * a document ({ doc }). Hides the topbar and tab bar, locks scroll, restores
 * the scroll position on dismiss; browser back closes it.
 */
export function openViewer(app, post, index = 0, { doc = null, resumeAt = 0 } = {}) {
  if (activeViewer) activeViewer.close();
  const items = doc ? [doc] : (post.album?.length ? post.album : [post.media]).filter((i) => i && VIEWER_KINDS.has(i.kind));
  if (!items.length) return;
  let idx = doc ? 0 : Math.max(0, Math.min(items.length - 1, indexAmongViewable(post, index)));

  const scrollY = window.scrollY;
  document.body.setAttribute('data-viewer', '');
  document.body.style.position = 'fixed';
  document.body.style.top = `-${scrollY}px`;
  document.body.style.width = '100%';

  let poppedByHistory = false;
  const v = viewer({
    label: 'Media viewer',
    onClose: () => {
      activeViewer = null;
      window.removeEventListener('popstate', onPop);
      document.body.removeAttribute('data-viewer');
      document.body.style.position = '';
      document.body.style.top = '';
      document.body.style.width = '';
      window.scrollTo(0, scrollY);
      // full-screen renditions are the biggest things the app decodes: they go
      // the moment the viewer does, along with every player it built
      for (const s of slides.values()) releaseMedia(s);
      slides.clear();
      for (const key of pinnedKeys) app.td.unpinKey(key);
      pinnedKeys.clear();
      if (panel) panel.release();
      panel = null;
      if (offKeys) offKeys();
      if (!poppedByHistory && history.state?.tgsViewer) history.back();
    },
  });
  activeViewer = v;
  history.pushState({ tgsViewer: true }, '');
  const onPop = () => {
    poppedByHistory = true;
    v.close();
  };
  window.addEventListener('popstate', onPop);

  const slides = new Map();
  /** Media-cache keys held while this viewer paints them; released on close. */
  const pinnedKeys = new Set();
  let offKeys = null;
  const downloadBtn = button('Download', { style: 'ghost', size: 'sm', ariaLabel: 'Download' });
  v.actions.append(downloadBtn);
  downloadBtn.addEventListener('click', async () => {
    const item = items[idx];
    const slim = item.kind === 'photo' ? pickPhotoSize(item.sizes, 4096)?.file : item.file;
    if (!slim?.id && !directUrl(slim)) return;
    downloadBtn.disabled = true;
    try {
      const url = await urlFor(app, slim, item.kind, item.mime ?? null);
      triggerDownload(url, item.fileName || `${item.kind}-${slim.id ?? 'file'}`);
    } catch (e) {
      if (!e?.cancelled) app.toast("Couldn't download this file.", 'bad');
    } finally {
      downloadBtn.disabled = false;
    }
  });
  if (post?.text && !doc) v.caption.textContent = post.text;

  // ── comments over the media (PRODUCT §2.12) ──────────────────────────────
  //
  // "Opening it does not leave the media": nothing is unmounted and nothing is
  // rebuilt — the stage keeps the same slides and simply becomes the
  // `--space-viewer-mini` strip at the top (CSS), with the thread underneath
  // it. Paging still runs `show()`, which moves that strip and re-targets the
  // thread at the item's own post.
  const commentsHost = h('div.viewer-comments');
  v.root.append(commentsHost);
  const restore = h('button.viewer-restore', { type: 'button', 'aria-label': 'Show the media full screen' });
  v.stage.append(restore);
  let panel = null;
  let commentsOpen = false;
  let commentsBtn = null;

  /**
   * The post a carousel item belongs to. An album is a run of Telegram
   * MESSAGES merged into one post (repo.toPost), so every item carries its own
   * message id and therefore its own `t.me` link — which is what a comment's
   * `re:` line points at (PROTOCOL §6.2). That is what "re-targets the thread
   * to that item's post" means: the same post, addressed at the item.
   */
  function itemPost(i) {
    const messageId = items[i]?.messageId;
    if (doc || !post || !messageId || messageId === post.id) return post;
    return { ...post, id: messageId, key: `${post.chatId}:${messageId}`, link: deepLink(post.username, messageId) };
  }

  function toggleComments(open) {
    if (open === commentsOpen) return;
    commentsOpen = open;
    v.root.classList.toggle('comments-open', open);
    restore.hidden = !open;
    if (commentsBtn) {
      commentsBtn.textContent = open ? 'Hide' : 'Comments';
      commentsBtn.setAttribute('aria-label', open ? 'Hide comments' : 'Comments');
    }
    if (!open) return;
    if (!panel) {
      panel = host.comments(app, itemPost(idx));
      commentsHost.append(panel);
    } else panel.setPost(itemPost(idx));
    commentsHost.scrollTop = 0;
  }

  if (!doc && post?.link && host.comments && app.repo) {
    commentsBtn = button('Comments', { style: 'ghost', size: 'sm', ariaLabel: 'Comments' });
    commentsBtn.addEventListener('click', () => toggleComments(!commentsOpen));
    v.actions.append(commentsBtn);
  }
  restore.hidden = true;
  // The overlay covers the whole mini view, so a swipe that pages the carousel
  // (§2.12: "paging the carousel while comments are open moves the mini view")
  // both starts and ends on it — and the browser then fires a `click` here.
  // Only a tap restores full-screen, so hold the same tap-vs-drag line the
  // stage's own gestures hold (wireGestures' `panStart.moved`, 6px of slop).
  let downAt = null;
  restore.addEventListener('pointerdown', (e) => {
    downAt = { x: e.clientX, y: e.clientY, moved: false };
  });
  restore.addEventListener('pointermove', (e) => {
    if (downAt && Math.abs(e.clientX - downAt.x) + Math.abs(e.clientY - downAt.y) > 6) downAt.moved = true;
  });
  restore.addEventListener('click', (e) => {
    const down = downAt;
    downAt = null;
    stop(e);
    // `detail === 0` is a keyboard activation of the button: no pointer travel
    // to judge, and no stale `downAt` from a drag that ended off the overlay.
    if (e.detail !== 0 && down
      && (down.moved || Math.abs(e.clientX - down.x) + Math.abs(e.clientY - down.y) > 6)) return;
    toggleComments(false);
  });

  function indexAmongViewable(p, albumIndex) {
    // `index` counts album positions; the viewer only pages its viewable items
    const all = p.album?.length ? p.album : [p.media];
    let n = 0;
    for (let i = 0; i < all.length && i < albumIndex; i += 1) {
      if (all[i] && VIEWER_KINDS.has(all[i].kind)) n += 1;
    }
    return n;
  }

  function buildSlide(i) {
    if (slides.has(i)) return slides.get(i);
    const item = items[i];
    const slide = h('div.viewer-slide');
    slides.set(i, slide);
    if (doc) buildDocSlide(app, slide, item);
    else if (item.kind === 'photo') buildPhotoSlide(app, slide, item, pinnedKeys);
    else buildVideoSlide(app, slide, item, item.kind === 'animation', i === idx ? resumeAt : 0);
    return slide;
  }

  function show(i, { autoplayVideo = false } = {}) {
    idx = i;
    for (const [k, s] of [...slides]) {
      if (k === i) continue;
      s.remove();
      // the neighbours stay built (a swipe back is instant); anything further
      // away is released — a 40-item album would otherwise hold 40 decoded
      // full-screen renditions and 40 players at once
      if (Math.abs(k - i) > 1) {
        releaseMedia(s);
        slides.delete(k);
      } else {
        const video = s.querySelector('video');
        if (video && !video.muted) video.pause();
      }
    }
    const slide = buildSlide(i);
    if (!slide.isConnected) v.stage.append(slide);
    v.counter.textContent = items.length > 1 ? `${i + 1} / ${items.length}` : '';
    // §2.12: paging with comments open moves the mini view AND re-targets the
    // thread — the reply goes to the item you are looking at.
    if (commentsOpen && panel) panel.setPost(itemPost(i));
    if (autoplayVideo) slide.querySelector('video')?.play().catch(() => null);
    // warm the neighbours
    if (i + 1 < items.length) buildSlide(i + 1);
    if (i > 0) buildSlide(i - 1);
  }

  offKeys = wireGestures(v, {
    count: () => items.length,
    index: () => idx,
    goTo: (i) => show(i, { autoplayVideo: false }),
    close: () => v.close(),
    zoomable: () => !doc && !commentsOpen && items[idx].kind === 'photo',
    slideOf: () => slides.get(idx),
  });

  document.getElementById('viewer-root').append(v.root);
  show(idx, { autoplayVideo: false });
}

/**
 * The full-screen photo — the one place a bigger rendition is genuinely
 * needed. It asks for the screen's own width (dpr capped at 2), which is a
 * different cache key from the feed card's rendition, and pins it so the
 * picture cannot be evicted out from under an open viewer.
 */
function buildPhotoSlide(app, slide, item, pinnedKeys = null) {
  const want = viewerWidthPx(window);
  const size = pickPhotoSize(item.sizes, want);
  const img = h('img', { alt: '' });
  if (item.mini) {
    img.src = item.mini;
    img.style.filter = 'blur(var(--media-blur))';
  }
  const wrap = h('div.viewer-zoom', img);
  slide.append(wrap);
  // a preview photo is one rendition at a URL: no bigger size to ask for, no
  // decode budget to hold, nothing to pin
  const direct = directUrl(size?.file);
  if (direct) {
    img.src = direct;
    img.style.filter = '';
    return;
  }
  if (!size?.file?.id) return;
  const file = fullFile(size.file);
  const prog = ring({ onCancel: () => app.td.cancel(size.file.id) });
  slide.append(prog);
  const paint = (url) => {
    if (!url) return;
    prog.remove();
    img.src = url;
    img.style.filter = '';
    const key = app.td.pinImage(file, want);
    if (key && pinnedKeys) pinnedKeys.add(key);
  };
  app.td
    .imageUrl(file, { width: want, priority: 32, label: labelFor('photo'), onProgress: (f) => prog.set(f) })
    .then((url) => {
      paint(url);
      // a flush while the viewer is open must put the picture back, not leave black
      bind(img, () => app.td.imageUrl(file, { width: want, priority: 32, label: labelFor('photo') }).then(paint).catch(() => null));
    })
    .catch(() => prog.remove());
}

function buildVideoSlide(app, slide, item, loop, resumeAt = 0) {
  const direct = directUrl(item.file);
  const prog = ring({ onCancel: () => app.td.cancel(item.file?.id) });
  if (!direct) slide.append(prog);
  (direct
    ? Promise.resolve(direct)
    : app.td.fileUrlOrThrow(fullFile(item.file), { priority: 32, label: labelFor(item.kind), mime: item.mime ?? null, onProgress: (f) => prog.set(f) }))
    .then((url) => {
      prog.remove();
      const video = h('video', { src: url, loop });
      video.playsInline = true;
      video.setAttribute('playsinline', '');
      if (loop) {
        video.muted = true;
        video.setAttribute('muted', '');
        video.autoplay = true;
      }
      if (item.kind === 'videoNote') {
        video.style.borderRadius = 'var(--radius-pill)';
        video.style.aspectRatio = '1 / 1';
        video.style.objectFit = 'cover';
      }
      slide.append(video);
      exclusive(video);
      pinWhilePlaying(app, video, item.file);
      if (!loop) {
        const playBtn = h('button.player-btn', { type: 'button', 'aria-label': 'Play' }, icon('play'));
        const time = h('span.player-time', '0:00');
        const scrub = videoScrubber(video);
        const controls = h('div.media-controls', playBtn, scrub, time);
        slide.append(controls);
        controls.addEventListener('click', stop);
        playBtn.addEventListener('click', (e) => {
          stop(e);
          if (video.paused) video.play().catch(() => null);
          else video.pause();
        });
        video.addEventListener('play', () => replace(playBtn, icon('pause')));
        video.addEventListener('pause', () => replace(playBtn, icon('play')));
        video.addEventListener('timeupdate', () => {
          time.textContent = formatDuration(video.currentTime);
          scrub.set(video.duration ? video.currentTime / video.duration : 0);
        });
        if (resumeAt) video.currentTime = resumeAt;
        video.play().catch(() => null);
      } else {
        video.play().catch(() => null);
      }
    })
    .catch(() => prog.remove());
}

function buildDocSlide(app, slide, item) {
  const kind = docKind(item.mime ?? '');
  const direct = directUrl(item.file);
  const prog = ring({ onCancel: () => app.td.cancel(item.file?.id) });
  if (!direct) slide.append(prog);
  (direct
    ? Promise.resolve(direct)
    : app.td.fileUrlOrThrow(fullFile(item.file), { priority: 32, label: labelFor('document'), mime: item.mime ?? null, onProgress: (f) => prog.set(f) }))
    .then(async (url) => {
      prog.remove();
      if (kind === 'image') slide.append(h('div.viewer-zoom', h('img', { src: url, alt: item.fileName })));
      else if (kind === 'pdf') slide.append(h('iframe.viewer-doc', { src: url, title: item.fileName }));
      else if (kind === 'text') {
        // a preview document is behind a URL, not in TDLib's file store
        const blob = direct ? await fetch(url).then((r) => r.blob()).catch(() => null) : await app.td.fileBlob(fullFile(item.file), { mime: item.mime });
        const text = blob ? await blob.text() : '';
        slide.append(h('div.viewer-textdoc', text.slice(0, 200000)));
      } else if (kind === 'audio') {
        const row = playerRow({ title: item.fileName, duration: '0:00', label: `Play ${item.fileName}` });
        const audio = new Audio(url);
        // parked in the slide (not merely referenced by the closure) so closing
        // the viewer releases it with everything else — a detached Audio kept
        // playing its blob for the life of the tab before this
        audio.style.display = 'none';
        slide.append(audio);
        exclusive(audio);
        pinWhilePlaying(app, audio, item.file);
        row.querySelector('.player-btn').addEventListener('click', () => {
          if (audio.paused) audio.play().catch(() => null);
          else audio.pause();
        });
        for (const ev of ['play', 'pause', 'timeupdate', 'durationchange']) {
          audio.addEventListener(ev, () => {
            row.setPlaying(!audio.paused && !audio.ended);
            row.setTime(formatDuration(audio.currentTime), formatDuration(audio.duration || 0));
            row.set(audio.duration ? audio.currentTime / audio.duration : 0);
          });
        }
        slide.append(row);
      } else if (kind === 'video') {
        const video = h('video', { src: url, controls: false });
        video.playsInline = true;
        video.setAttribute('playsinline', '');
        exclusive(video);
        slide.append(video);
        pinWhilePlaying(app, video, item.file);
        video.addEventListener('click', () => {
          if (video.paused) video.play().catch(() => null);
          else video.pause();
        });
        video.play().catch(() => null);
      }
    })
    .catch(() => prog.remove());
}

/** Pinch/double-tap zoom for photos, swipe between album items, swipe down to dismiss. */
function wireGestures(v, api) {
  const pointers = new Map();
  let scale = 1;
  let tx = 0;
  let ty = 0;
  let startDist = 0;
  let startScale = 1;
  let panStart = null;
  let lastTap = 0;
  const zoomTarget = () => api.slideOf()?.querySelector('.viewer-zoom');

  const apply = () => {
    const el = zoomTarget();
    if (el) el.style.transform = scale === 1 && !tx && !ty ? '' : `translate(${tx}px, ${ty}px) scale(${scale})`;
  };
  const reset = () => {
    scale = 1;
    tx = 0;
    ty = 0;
    apply();
  };

  v.stage.addEventListener('pointerdown', (e) => {
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      startDist = Math.hypot(a.x - b.x, a.y - b.y);
      startScale = scale;
      panStart = null;
    } else if (pointers.size === 1) {
      panStart = { x: e.clientX, y: e.clientY, tx, ty, moved: false };
    }
  });

  v.stage.addEventListener('pointermove', (e) => {
    const p = pointers.get(e.pointerId);
    if (!p) return;
    p.x = e.clientX;
    p.y = e.clientY;
    if (pointers.size === 2 && api.zoomable()) {
      const [a, b] = [...pointers.values()];
      const dist = Math.hypot(a.x - b.x, a.y - b.y);
      if (startDist > 0) {
        scale = Math.max(1, Math.min(5, (startScale * dist) / startDist));
        if (scale === 1) {
          tx = 0;
          ty = 0;
        }
        apply();
      }
    } else if (pointers.size === 1 && panStart) {
      const dx = e.clientX - panStart.x;
      const dy = e.clientY - panStart.y;
      if (Math.abs(dx) + Math.abs(dy) > 6) panStart.moved = true;
      if (scale > 1) {
        tx = panStart.tx + dx;
        ty = panStart.ty + dy;
        apply();
      } else {
        const el = api.slideOf();
        if (el) el.style.transform = Math.abs(dy) > Math.abs(dx) ? `translateY(${Math.max(0, dy)}px)` : `translateX(${dx}px)`;
      }
    }
  });

  const end = (e) => {
    const had = pointers.get(e.pointerId);
    pointers.delete(e.pointerId);
    if (pointers.size > 0 || !had) return;
    const el = api.slideOf();
    if (scale > 1) {
      apply();
      return;
    }
    const dx = e.clientX - (panStart?.x ?? e.clientX);
    const dy = e.clientY - (panStart?.y ?? e.clientY);
    if (el) el.style.transform = '';
    if (panStart && !panStart.moved) {
      // tap: double-tap toggles zoom on photos
      const now = Date.now();
      if (now - lastTap < 320 && api.zoomable()) {
        if (scale === 1) {
          scale = 2.5;
          const r = v.stage.getBoundingClientRect();
          tx = (r.width / 2 - (e.clientX - r.left)) * 1.5;
          ty = (r.height / 2 - (e.clientY - r.top)) * 1.5;
        } else {
          scale = 1;
          tx = 0;
          ty = 0;
        }
        apply();
        lastTap = 0;
      } else lastTap = now;
    } else if (Math.abs(dy) > Math.abs(dx) && dy > 80) {
      api.close();
      return;
    } else if (Math.abs(dx) > 60) {
      const n = api.count();
      const next = api.index() + (dx < 0 ? 1 : -1);
      if (next >= 0 && next < n) {
        reset();
        api.goTo(next);
      }
    }
    panStart = null;
  };
  v.stage.addEventListener('pointerup', end);
  v.stage.addEventListener('pointercancel', (e) => {
    pointers.delete(e.pointerId);
    panStart = null;
    const el = api.slideOf();
    if (el && scale === 1) el.style.transform = '';
  });

  // returned so the viewer's onClose can take the listener off document even
  // when no key was ever pressed after it closed
  const onKey = (e) => {
    if (!v.root.isConnected) {
      document.removeEventListener('keydown', onKey);
      return;
    }
    if (e.key === 'ArrowRight' && api.index() + 1 < api.count()) {
      reset();
      api.goTo(api.index() + 1);
    } else if (e.key === 'ArrowLeft' && api.index() > 0) {
      reset();
      api.goTo(api.index() - 1);
    }
  };
  document.addEventListener('keydown', onKey);
  return () => document.removeEventListener('keydown', onKey);
}

/** True while the full-screen viewer is open (the app hides its chrome then). */
export function viewerOpen() {
  return !!activeViewer;
}

/** Close the viewer if a route change happens under it. */
export function closeViewer() {
  if (activeViewer) activeViewer.close();
}
