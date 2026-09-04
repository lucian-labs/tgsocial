/* strip.js — computing the spectrogram strip for a clip (PRODUCT §2.11.1).
 *
 * js/spectro.js is the pure transform; js/spectro.worker.js runs it off the
 * main thread; this file is everything in between — deciding whether a clip
 * gets analysed at all, fetching and decoding it at a decimated rate, handing
 * the samples to the worker, turning the returned texture into cache bytes,
 * and degrading when any of that fails.
 *
 * Three rules from §2.11.1 shape all of it:
 *
 *   1. "Analysis never runs for a row that has not been played or scrolled
 *      into view." Nothing here starts on its own; media.js arms it on the
 *      visibility observer and on the play tap.
 *   2. "Cost is bounded, and it degrades rather than blocking." Past the
 *      duration ceiling the spectrum is skipped and the clip is decoded coarse
 *      for the silhouette alone; past the hard ceiling nothing is fetched at
 *      all (`analysisPlan`). A decode that fails keeps whatever silhouette the
 *      row already had — for a voice note that is Telegram's own waveform
 *      bytes, drawn before this file is even called.
 *   3. The result is cached against the FILE's identity, not the row's, so the
 *      same clip in the feed and in a thread is analysed once and shares one
 *      texture.
 *
 * Memory: the decoded AudioBuffer is the largest object in the process while
 * it exists — a 3 minute stereo track at 48 kHz is ~70 MB of float — so it is
 * downmixed to one decimated mono channel and dropped inside `decodeMono`,
 * before the analysis starts. What survives is the strip, and its bytes are
 * registered with the SAME MediaCache budget as every picture (td.putDerived),
 * so it is evictable, visible in the Status sheet, and never held outside the
 * accounting.
 *
 * That accounting only covers the FINISHED strip, though, so the working set
 * that produces it is bounded here instead, in three places, because none of it
 * is visible to `mediaStats()` and eviction cannot relieve any of it:
 *
 *   · the rate is chosen from the clip's duration and the decode is capped at
 *     `MAX_SAMPLES` (`spectro.analysisRate`), so one clip's floats are ~19 MB
 *     however long it is — against a total media budget of 12–48 MB;
 *   · the silhouette-only band past the duration cap is charged against its own
 *     `ENVELOPE_MAX_SAMPLES` (~43 MB) instead, because it decodes a much longer
 *     clip at a much coarser rate and the FFT never sees the result — the mono
 *     copy it leaves behind is still capped at `MAX_SAMPLES` by the box average
 *     below;
 *   · `decodeMono` decimates INSIDE the downmix, so the mono copy is the
 *     capped length rather than the buffer's length;
 *   · `DECODE_SLOTS` gates how many of those exist at once. `whenVisible` arms
 *     on a `100%` root margin, so a screen and a half of audio rows can reach
 *     this file inside one scroll gesture and without the gate they would all
 *     decode together.
 */
import { rampStops } from '../vendor/house-pour.js';
import {
  analyse,
  analysisPlan,
  DURATION_CAP_S,
  ENVELOPE_RATE,
  envelopeColumns,
  MAX_SAMPLES,
  paintStrip,
  resampleEnvelope,
  TARGET_RATE,
} from './spectro.js';

/** Painted height of the strip, in CSS px — mirrors `--space-strip-height`. */
const STRIP_HEIGHT_CSS = 44;

/**
 * CSS px between the app column and the strip, in tokens: the card's padding
 * on both sides (2 × `cardPad`), the 40pt play circle (`touchMin`), the row
 * gap (`rowPad`), and the player row's own inset and hairline
 * (2 × (`inputX` + `border`)). Adding them up rather than measuring a laid-out
 * element is what makes the feed and the thread agree on ONE size — and
 * therefore one cache key — instead of forking it over a pixel of layout.
 */
const PLAYER_LEAD_CSS = 2 * 20 + 40 + 14 + 2 * (15 + 1);

/**
 * Columns are quantised DOWN to a multiple of this. Two reasons, and they are
 * the same reason: a pixel of layout difference between a feed card and a
 * thread card must not fork the cache into two analyses of one clip, and
 * rounding down is what keeps §2.11.1's "one column per pixel, NO MORE" true
 * when the sum above is a token or two out.
 */
const COL_QUANTUM = 32;

/** Column ceiling. One column per strip pixel (§2.11.1), and no more than this. */
const MAX_COLS = 1024;

/**
 * Concurrent decodes. Each one holds a decoded AudioBuffer and its mono copy —
 * tens of megabytes that no cache can see — so this is the only thing standing
 * between a fast scroll through a channel of DJ sets and the tab's memory
 * ceiling. Two rather than one so a tapped row is not stuck behind a scrolled
 * one, and no more than two because the work is CPU-bound anyway.
 */
const DECODE_SLOTS = 2;

/**
 * How long a failed analysis stays failed before a row that comes back into
 * view may try again. A download that stalled or was cancelled does not wait
 * even that long (see `ensureStrip`); this is for the ones that might be the
 * clip's own fault.
 */
const RETRY_AFTER_MS = 30000;

/** …and how many times, so an undecodable clip stops costing a download. */
const MAX_ATTEMPTS = 3;

/** The analysis records, keyed by file identity. */
const jobs = new Map();

/**
 * Everything watching for a record to settle — the now-playing dock, which owns
 * no analysis of its own (§2.11.2) and only wants to know when the one the
 * STRIP started has an envelope to share. A Set of plain callbacks rather than
 * a waiter element, because the dock's mini waveform is not a strip: it takes
 * the envelope at its own width and never the texture.
 */
const readyListeners = new Set();

/**
 * Call `fn(cacheId)` whenever an analysis settles (ready or failed). Returns
 * the unsubscribe. Nothing here starts work — it is a notification that the
 * cache changed, and `cachedEnvelope` is how you read it.
 */
export function onStripReady(fn) {
  readyListeners.add(fn);
  return () => readyListeners.delete(fn);
}

function announce(cacheId) {
  for (const fn of [...readyListeners]) {
    try {
      fn(cacheId);
    } catch (e) {
      console.warn('[strip] listener', e?.message ?? e);
    }
  }
}

let workerFailed = false;
let worker = null;
let nextId = 1;
const pending = new Map();

/** Rolling stats for the Status sheet and test/flows.mjs. */
const stats = { started: 0, ready: 0, failed: 0, refused: 0, retried: 0, silhouette: 0, queued: 0, lastMs: 0, worker: null };

// ── identity and size ──────────────────────────────────────────────────────

/**
 * What makes this clip this clip. TDLib's `unique_id` is the same string for
 * the same file in every chat, which is exactly the sharing §2.11.1 asks for;
 * a public-preview item has no TDLib file at all and is identified by the URL
 * Telegram served it at.
 */
export function stripIdentity(slim) {
  if (!slim) return null;
  return slim.uniqueId || (typeof slim.url === 'string' && slim.url) || (slim.id ? `id:${slim.id}` : null);
}

/**
 * The strip's size in device pixels: one column per pixel of its painted
 * width, one row per pixel of its painted height, dpr capped at 2 like every
 * other decode in this app (js/decode.js) because a 3× strip is 2.25× the
 * bytes for a difference nobody sees.
 */
export function stripPixels(env = globalThis) {
  const dpr = Math.min(env?.devicePixelRatio || 1, 2);
  const cssWidth = Math.max(80, Math.min(env?.innerWidth || 540, 540) - 2 * 14 - PLAYER_LEAD_CSS);
  const wide = Math.min(MAX_COLS, Math.round(cssWidth * dpr));
  return {
    cols: Math.max(COL_QUANTUM, COL_QUANTUM * Math.floor(wide / COL_QUANTUM)),
    rows: Math.max(2, Math.round(STRIP_HEIGHT_CSS * dpr)),
  };
}

/**
 * The envelope this clip's STRIP already computed, resampled to `cols`
 * (PRODUCT §2.11.2: "a view of the analysis the strip already did — the same
 * envelope array, resampled to the dock's width").
 *
 * This never starts anything. It reads the record `ensureStrip` keyed under the
 * same file identity and strip size, and returns null for every state that has
 * no envelope yet — pending, refused, failed, or the hairline a decode failure
 * left behind. Null is not "draw nothing": §2.11.2 says a clip whose strip
 * degraded to the hairline shows a FLAT LINE, and that is the mini waveform's
 * own no-envelope shape.
 */
export function cachedEnvelope(meta, cols) {
  const id = stripIdentity(meta?.file);
  if (!id) return null;
  const { cols: sc, rows } = stripPixels();
  const record = jobs.get(`${id}@${sc}x${rows}`);
  if (!record || record.state !== 'ready' || !record.envelope) return null;
  return resampleEnvelope(record.envelope, cols);
}

// ── decode ─────────────────────────────────────────────────────────────────

function offlineContext(channels, length, rate) {
  const Ctor = globalThis.OfflineAudioContext || globalThis.webkitOfflineAudioContext;
  if (!Ctor) throw new Error('No OfflineAudioContext.');
  return new Ctor(channels, Math.max(1, length), rate);
}

/**
 * An OfflineAudioContext at `rate`, or at the closest rate up the ladder that
 * this engine will actually give us. The Web Audio spec only obliges an
 * implementation to support 8 kHz upwards; most engines go down to 3 kHz, and
 * the ones that do not throw `NotSupportedError` from the constructor. Asking
 * and catching is the only way to know.
 */
function contextAtOrAbove(rate) {
  let last = null;
  for (const r of [rate, 8000, 16000, 44100]) {
    if (r < rate) continue;
    try {
      return offlineContext(1, 1, r);
    } catch (e) {
      last = e;
    }
  }
  throw last ?? new Error('No OfflineAudioContext.');
}

let envelopeRate = 0;

/**
 * The coarsest rate this runtime will decode at, at or above `ENVELOPE_RATE` —
 * probed once, because it decides where the silhouette-only band actually ends
 * (`analysisPlan`), and a promise of a 40 minute silhouette on an engine that
 * cannot decode below 8 kHz is a promise to allocate 115 MB for one row.
 */
export function envelopeDecodeRate() {
  if (envelopeRate) return envelopeRate;
  try {
    envelopeRate = contextAtOrAbove(ENVELOPE_RATE).sampleRate;
  } catch {
    envelopeRate = ENVELOPE_RATE;
  }
  return envelopeRate;
}

/**
 * Compressed bytes → one mono Float32Array at the decimated rate.
 *
 * `decodeAudioData` resamples to the context's own sample rate, so decoding
 * INTO a 16 kHz OfflineAudioContext is the decimation — properly filtered by
 * the browser's resampler, rather than by throwing away three samples in four
 * and aliasing the result. The AudioBuffer is dereferenced before this returns.
 *
 * Two things the browser will not do for us, and both are memory:
 *
 *   · `decodeAudioData` returns the SOURCE's channel count whatever the context
 *     asked for, so a stereo clip is two channels of AudioBuffer regardless;
 *   · nothing stops it decoding a file whose header lied about its duration.
 *
 * So the downmix box-averages down to `maxSamples` in the same pass that sums
 * the channels: the mono copy is never longer than the ceiling, whatever came
 * back, and the reported rate follows it down so the time axis stays honest.
 * A box average rather than a stride — dropping samples aliases, and the whole
 * reason to decode into a low-rate context was to avoid exactly that.
 */
export async function decodeMono(bytes, rate = TARGET_RATE, maxSamples = MAX_SAMPLES) {
  const ctx = contextAtOrAbove(rate);
  const buffer = await new Promise((resolve, reject) => {
    let p;
    try {
      p = ctx.decodeAudioData(bytes, resolve, reject);
    } catch (e) {
      reject(e);
      return;
    }
    if (p && typeof p.then === 'function') p.then(resolve, reject);
  });
  if (!buffer || !buffer.length) throw new Error('Decoded to nothing.');
  const n = buffer.length;
  const channels = buffer.numberOfChannels;
  const stride = Math.max(1, Math.ceil(n / Math.max(1, maxSamples)));
  const out = new Float32Array(Math.ceil(n / stride));
  for (let c = 0; c < channels; c += 1) {
    const data = buffer.getChannelData(c);
    if (stride === 1) {
      for (let i = 0; i < n; i += 1) out[i] += data[i];
      continue;
    }
    let o = 0;
    for (let i = 0; i < n; i += stride) {
      const to = Math.min(i + stride, n);
      let sum = 0;
      for (let k = i; k < to; k += 1) sum += data[k];
      out[o] += sum / (to - i);
      o += 1;
    }
  }
  if (channels > 1) for (let i = 0; i < out.length; i += 1) out[i] /= channels;
  return {
    samples: out,
    rate: buffer.sampleRate / stride,
    seconds: n / buffer.sampleRate,
    decimated: stride > 1,
  };
}

// ── the worker ─────────────────────────────────────────────────────────────

function ensureWorker() {
  if (worker || workerFailed) return worker;
  try {
    worker = new Worker(new URL('./spectro.worker.js', import.meta.url), { type: 'module' });
    worker.onmessage = (e) => {
      const { id } = e.data ?? {};
      const settle = pending.get(id);
      if (!settle) return;
      pending.delete(id);
      if (e.data.ok) settle.resolve(e.data);
      else settle.reject(new Error(e.data.error || 'Analysis failed.'));
    };
    worker.onerror = () => {
      // a worker that will not start is a degrade, not a failure: everything
      // falls back to the chunked main-thread path below
      workerFailed = true;
      worker = null;
      // Every job in flight dies with it, and their samples died with the
      // transfer, so they cannot simply be re-run here — the flag says WHY, and
      // `ensureStrip` re-queues them from the top, which now takes the
      // main-thread path because `workerFailed` is set. A dead worker must not
      // be the reason a clip has no strip for the life of the page.
      for (const settle of pending.values()) {
        const e = new Error('Worker stopped.');
        e.workerStopped = true;
        settle.reject(e);
      }
      pending.clear();
    };
    stats.worker = true;
  } catch {
    workerFailed = true;
    worker = null;
    stats.worker = false;
  }
  return worker;
}

/** Yield to the event loop so a long clip cannot hold the frame. */
const breathe = () => new Promise((r) => setTimeout(r, 0));

/**
 * Run the transform. The worker is the path; the main thread is the fallback
 * for a runtime that will not give us one — and even then it yields around the
 * two expensive halves, so the worst case is a slow strip and never a stuck
 * feed.
 *
 * `mode` is `analysisPlan`'s: `spectrum` returns a texture and a silhouette,
 * `envelope` returns the silhouette alone and never touches the FFT.
 */
async function transform(samples, rate, cols, rows, stops, mode = 'spectrum') {
  const w = ensureWorker();
  if (w) {
    const id = nextId;
    nextId += 1;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      w.postMessage({ id, samples, rate, cols, rows, stops, mode }, [samples.buffer]);
    });
  }
  await breathe();
  if (mode === 'envelope') return { rgba: null, envelope: envelopeColumns(samples, rate, cols), cols, rows };
  const { mag, envelope } = analyse({ samples, rate, cols, rows });
  await breathe();
  return { rgba: paintStrip(mag, cols, rows, stops), envelope, cols, rows };
}

// ── the decode gate ────────────────────────────────────────────────────────

let decoding = 0;
const waiting = [];

/**
 * One decode slot. The download is deliberately OUTSIDE this — bytes are the
 * network's business and the media cache's, and holding a slot through a slow
 * fetch would serialise the downloads too. What is gated is the part that
 * allocates: decode, downmix, analyse.
 *
 * A tapped row jumps the queue, because it is the one with somebody waiting on
 * it; scrolled-into-view rows take their turn.
 */
function acquireDecode(urgent = false) {
  if (decoding < DECODE_SLOTS) {
    decoding += 1;
    return Promise.resolve();
  }
  stats.queued += 1;
  return new Promise((resolve) => {
    if (urgent) waiting.unshift(resolve);
    else waiting.push(resolve);
  });
}

function releaseDecode() {
  const next = waiting.shift();
  if (next) next(); // hand the slot straight over rather than reopening it
  else decoding = Math.max(0, decoding - 1);
}

// ── the texture ────────────────────────────────────────────────────────────

/** RGBA bytes → a PNG Blob, which is what the media cache stores and an <img> paints. */
async function toBlob(rgba, cols, rows) {
  const image = new ImageData(rgba, cols, rows);
  if (typeof OffscreenCanvas !== 'undefined') {
    const canvas = new OffscreenCanvas(cols, rows);
    canvas.getContext('2d').putImageData(image, 0, 0);
    return canvas.convertToBlob({ type: 'image/png' });
  }
  const canvas = document.createElement('canvas');
  canvas.width = cols;
  canvas.height = rows;
  canvas.getContext('2d').putImageData(image, 0, 0);
  return new Promise((resolve, reject) => {
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Canvas would not encode.'))), 'image/png');
  });
}

// ── the job ────────────────────────────────────────────────────────────────

async function run(app, key, fetchBytes, cols, rows, plan, urgent) {
  const stops = rampStops();
  if (!stops.length) throw new Error('Ramp tokens not loaded.');
  const started = (globalThis.performance ?? Date).now();
  const bytes = await fetchBytes();
  if (!bytes || !bytes.byteLength) throw new Error('File is empty.');

  let out;
  await acquireDecode(urgent);
  try {
    // the decoded buffer dies inside decodeMono; only the decimated mono
    // channel crosses this line, and it is transferred to the worker below
    const { samples, rate } = await decodeMono(bytes, plan.rate);
    out = await transform(samples, rate, cols, rows, stops, plan.mode);
  } finally {
    releaseDecode();
  }

  const ms = () => Math.round((globalThis.performance ?? Date).now() - started);
  // Past the duration ceiling there is no texture by design — the record is the
  // silhouette, and §2.11.1's `wave` fidelity is the whole point of the band.
  if (!out.rgba) {
    stats.lastMs = ms();
    return { key: null, envelope: out.envelope, ms: stats.lastMs, degraded: true };
  }
  try {
    const blob = await toBlob(out.rgba, cols, rows);
    const painted = app.td.putDerived(key, blob, { width: cols, height: rows });
    if (!painted) throw new Error('The budget dropped the strip on arrival.');
  } catch {
    // The spectrum computed and then the PICTURE failed — the canvas would not
    // encode, or the budget refused it. The silhouette in hand is worth more
    // than the hairline, so the row degrades one step instead of all the way.
    stats.lastMs = ms();
    return { key: null, envelope: out.envelope, ms: stats.lastMs, degraded: true };
  }
  stats.lastMs = ms();
  return { key, envelope: out.envelope, ms: stats.lastMs, degraded: false };
}

// ── the public surface ─────────────────────────────────────────────────────

/**
 * Paint a record onto a strip element: the envelope always, the texture when
 * the cache still holds one. A strip whose texture the budget has evicted keeps
 * its silhouette rather than blanking — the row stays usable either way.
 */
function apply(record, el, url) {
  if (!el) return;
  if (record.envelope) el.setEnvelope(record.envelope);
  if (url) el.setSpectrum(url);
  else if (record.key) el.clearSpectrum();
}

/**
 * Analyse this clip if it has not been analysed, and paint the result onto
 * `el`. Safe to call repeatedly and from several rows at once: the record is
 * shared, so the second caller joins the first one's work rather than starting
 * a second decode of the same file.
 *
 * `fetchBytes` is injected (media.js owns the download rules) so this module
 * never has to know the difference between a TDLib file read and a public
 * preview's CDN URL — and so the caller, not this one, decides the download
 * priority: 1 for a row scrolled into view, 32 for one that was tapped.
 *
 * `retry` marks the tapped call. A failure is never permanent — see
 * `retryable` — and a tap is the one trigger that does not wait out the
 * cooldown, because somebody is looking at the row right now.
 */
export function ensureStrip(app, meta, el, fetchBytes, { retry = false } = {}) {
  const id = stripIdentity(meta?.file);
  if (!id) return null;
  const { cols, rows } = stripPixels();
  const cacheId = `${id}@${cols}x${rows}`;
  let record = jobs.get(cacheId);

  if (record && record.state === 'ready') {
    const url = record.key ? app.td.derivedUrl(record.key) : null;
    apply(record, el, url);
    // A record with no key never had a texture (the silhouette-only band, or a
    // spectrum whose picture failed) and must not be mistaken for an evicted
    // one — re-running it would decode the same long clip again for the same
    // envelope.
    if (url || !record.key) return record;
    // The texture is gone — the media budget evicted it, exactly as it evicts a
    // photo. Forget the record and fall through to a fresh run, which is what
    // the picture bindings do after a memory-pressure flush.
    jobs.delete(cacheId);
    stats.ready = Math.max(0, stats.ready - 1);
    record = null;
  }
  if (record && record.state === 'pending') {
    record.waiters.add(el);
    return record;
  }
  if (record && record.state === 'refused') return record;
  let attempts = 0;
  if (record && record.state === 'failed') {
    if (!retryable(record, retry)) return record;
    attempts = record.attempts ?? 0;
    // Failure is a moment, not a property of the clip: a download that stalled
    // behind a tunnel, or was cancelled while the row was off-screen, used to
    // pin that clip to the hairline for the life of the page — neither the play
    // tap nor the memory-pressure rebind could ever get past this branch.
    jobs.delete(cacheId);
    stats.failed = Math.max(0, stats.failed - 1);
    stats.retried += 1;
    record = null;
  }

  // §2.11.1's cheapest degrade: a clip past the ceiling never fetches a byte.
  // Past the FIRST ceiling that means the spectrum is skipped and the clip is
  // decoded coarsely for the silhouette alone; only past the second is there
  // nothing to draw at all.
  const plan = stripPlan(meta?.duration);
  if (plan.mode === 'none') {
    const refused = { state: 'refused', reason: plan.reason, waiters: new Set() };
    jobs.set(cacheId, refused);
    stats.refused += 1;
    return refused;
  }

  const next = { state: 'pending', mode: plan.mode, attempts: attempts + 1, waiters: new Set([el].filter(Boolean)), envelope: null, key: null, ms: 0 };
  jobs.set(cacheId, next);
  stats.started += 1;
  const job = () => run(app, `${cacheId}#strip`, fetchBytes, cols, rows, plan, retry);
  // A worker that died took this job's samples with it (they were transferred).
  // Re-running from the top is what puts the clip on the main-thread path,
  // which `workerFailed` has just switched everything to.
  job()
    .catch((e) => (e?.workerStopped ? job() : Promise.reject(e)))
    .then((result) => {
      next.state = 'ready';
      next.key = result.key;
      next.envelope = result.envelope;
      next.ms = result.ms;
      next.degraded = result.degraded;
      stats.ready += 1;
      if (result.degraded) stats.silhouette += 1;
      const url = result.key ? app.td.derivedUrl(result.key) : null;
      for (const target of next.waiters) apply(next, target, url);
      next.waiters.clear();
      announce(cacheId);
    }, (e) => {
      // Degrade, never block: the row keeps the silhouette it already had (a
      // voice note's Telegram bytes) or its hairline, and nothing is logged as
      // an error — a clip the browser cannot decode is a fact about the clip.
      next.state = 'failed';
      next.reason = String(e?.message ?? e);
      next.failedAt = Date.now();
      // A cancel or a stall says nothing about the clip, so it does not count
      // against the attempt budget and does not wait out the cooldown.
      next.transient = !!e?.cancelled || /timed out|cancelled/i.test(next.reason);
      if (next.transient) next.attempts -= 1;
      stats.failed += 1;
      next.waiters.clear();
      announce(cacheId);
      if (!e?.cancelled) console.warn('[strip]', next.reason);
    });
  return next;
}

/** Whether a failed record gets another go — see `RETRY_AFTER_MS`. */
function retryable(record, tapped) {
  if (record.transient) return true; // a stall or a cancel is not the clip's fault
  if ((record.attempts ?? 1) >= MAX_ATTEMPTS) return false;
  if (tapped) return true;
  return Date.now() - (record.failedAt ?? 0) >= RETRY_AFTER_MS;
}

/**
 * `analysisPlan` for a duration, with the runtime's own coarsest decodable rate
 * filled in — probed only for the clips that would use it, so a feed of ordinary
 * voice notes never builds an AudioContext to answer a question about
 * forty-minute sets.
 */
function stripPlan(duration) {
  const d = Number(duration);
  if (!Number.isFinite(d) || d <= 0 || d <= DURATION_CAP_S) return analysisPlan(duration);
  return analysisPlan(duration, { envelopeRate: envelopeDecodeRate() });
}

/** Forget a strip element that is leaving the document. */
export function releaseStrip(el) {
  for (const record of jobs.values()) record.waiters?.delete(el);
}

/** Introspection for the Status sheet and test/flows.mjs. */
export function stripStats() {
  const { cols, rows } = stripPixels();
  const states = {};
  const modes = {};
  for (const record of jobs.values()) {
    states[record.state] = (states[record.state] ?? 0) + 1;
    if (record.mode) modes[record.mode] = (modes[record.mode] ?? 0) + 1;
  }
  return { ...stats, cols, rows, records: jobs.size, states, modes, decoding, waiting: waiting.length };
}
