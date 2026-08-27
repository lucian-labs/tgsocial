/* spectro.js — the spectrogram strip's analysis (PRODUCT §2.11.1).
 *
 * The audio scrubber is not a hairline: it is a spectrogram of the WHOLE clip
 * with a one-pole amplitude envelope drawn over it, and it doubles as the
 * scrubber. Same instrument as Wake's waterfall (waveloop/ios/wake/Sources —
 * WakeFFT.swift, WakeFFTAnalyzer.swift, LZWaveform.swift), in House Pour's
 * palette, with one structural difference:
 *
 *   Wake visualises a LIVE mic and SCROLLS — a bitmap that memmoves down one
 *   row per frame and colourises the newest row. tgsocial plays a FINITE FILE,
 *   so time is the x axis end to end and nothing scrolls: the strip is
 *   computed ONCE, cached against the file's identity, and the playhead sweeps
 *   it. What survives from Wake is the reason the bitmap exists at all — the
 *   output is a texture, never a path re-emitted per frame, because a path is
 *   O(columns × rows) draw ops for something that never changes.
 *
 * Everything here is pure and DOM-free on purpose: no AudioContext, no canvas,
 * no worker plumbing. Float32Array in, magnitudes and RGBA bytes out, so the
 * follower, the log axis, the AGC, the ramp and the caps are unit-testable
 * under node (test/protocol.test.mjs). js/strip.js does the decoding and the
 * caching; js/spectro.worker.js runs this off the main thread.
 */

// ── the axis ───────────────────────────────────────────────────────────────

/**
 * The strip's frequency axis (§2.11.1). `F_MIN` is the bottom; `F_MAX` is a
 * CEILING on the top, not the top itself — the axis runs from 20 Hz to the
 * analysis Nyquist, ceilinged here (`axisMaxHz`).
 *
 * That is the decision, written down in §2.11.1 and shared by all three
 * platforms (iOS `SpectrogramSpec.axisMax(rate:)`, Android
 * `SpectrogramSpec.effectiveFMax`): the axis follows the rate rather than
 * reserving rows for a band the decimation discarded before the FFT ever saw
 * it. A literal 20 kHz top leaves 13% of a 44pt strip permanently dark at a
 * 16 kHz analysis and 23% at 8 kHz — and because the rate now slides with the
 * clip's LENGTH (`analysisRate`), the height of that dead band would move
 * around with the clip's length too, which is the one thing a fixed axis was
 * supposed to prevent.
 */
export const F_MIN = 20;
export const F_MAX = 20000;

/**
 * Decimated analysis rate ceiling. §2.11.1 allows 8–16 kHz ("plenty for a strip
 * this size"); 16 kHz is the top of that band, so the decimated Nyquist (8 kHz)
 * covers everything a compressed Telegram clip actually carries — and, since
 * the axis follows the rate, IS the top of the strip for a clip under five
 * minutes.
 */
export const TARGET_RATE = 16000;

/**
 * …and the floor of that band, which a long clip decimates down to
 * (`analysisRate`). At the floor the strip's top is 4 kHz, which §2.11.1 states
 * outright: a ten-minute clip is a coarser picture than a two-minute one,
 * because it is the same number of pixels over five times the audio.
 */
export const MIN_RATE = 8000;

/**
 * Ceiling on the decoded working set, in samples: 4.8 M Float32 ≈ 19 MB,
 * transient, and the same number iOS runs on (`SpectrogramSpec.maxSamples`).
 * It is what makes the rate adaptive instead of the memory unbounded — a clip
 * long enough to blow the ceiling is analysed at a lower rate, and at the
 * duration cap the arithmetic lands exactly on `MIN_RATE`.
 */
export const MAX_SAMPLES = 4800000;

/**
 * The top of the axis for an analysis at `rate`: §2.11.1's ceiling, or the
 * decimated Nyquist, whichever is lower. Wake clamps the same way
 * (`let fMax = min(Self.fMax, sr / 2)`) and for the same reason — painting rows
 * for frequencies the decode threw away is drawing a floor and calling it
 * silence. Every axis function here takes `fMax` explicitly so the mapping is
 * testable against either number.
 */
export function axisMaxHz(rate, fMax = F_MAX) {
  return Math.max(F_MIN * 2, Math.min(fMax, rate / 2));
}

/**
 * The rate a clip of `seconds` is decimated to: the top of §2.11.1's band until
 * the decoded buffer would pass `MAX_SAMPLES`, then whatever keeps it inside,
 * floored at `MIN_RATE`. iOS's `SpectrogramSpec.rate(forDuration:)`, number for
 * number, so a 10 minute clip is 4.8 M samples at 8 kHz on both platforms.
 */
export function analysisRate(seconds, maxSamples = MAX_SAMPLES) {
  const d = Number(seconds);
  if (!Number.isFinite(d) || d <= 0) return TARGET_RATE;
  // rounded, because this becomes an OfflineAudioContext's sampleRate and a
  // fractional one is a NotSupportedError on some engines
  return Math.round(Math.min(TARGET_RATE, Math.max(MIN_RATE, maxSamples / d)));
}

// ── the transform ──────────────────────────────────────────────────────────

/**
 * 1024 points at 16 kHz → ~15.6 Hz bins over a 64 ms window. Wake uses 8192
 * because it is resolving bird calls in a live room; a strip 44pt tall showing
 * a whole clip resolves nothing finer than its own rows, and a shorter window
 * keeps transients (the thing the envelope is for) from smearing.
 */
export const FFT_SIZE = 1024;

/**
 * Hard ceiling on STFT frames, whatever the clip's length. At ~50% overlap a
 * 30 s clip is ~937 frames and lands under this on its own; a 10 minute clip
 * would be 18,750, so past the ceiling the WINDOW grows and the hop grows with
 * it, half a window at a time (`framePlan`).
 *
 * The window has to grow, and this is the whole point: opening the hop ALONE
 * past `FFT_SIZE` would leave a gap between one window and the next that no
 * frame ever looks at. At a 180 s clip that gap is 23 ms wide and 27% of the
 * audio falls in it — a snare hit landing there lights no column at all, and
 * the strip stops being a picture of the clip and becomes a sample of it.
 * Growing the window keeps the hop at half a window, so the windows still
 * overlap and every sample is inside one, for a frame count that is still a
 * function of the strip rather than of the file.
 */
export const MAX_FRAMES = 2048;

/**
 * …and the window's own ceiling. 8192 points is a 1 s window at 8 kHz, which is
 * as coarse as a column ever gets (a 600 s clip across 448 columns is 1.34 s
 * per column).
 *
 * What growing the window costs, measured rather than guessed — the longest
 * clip the caps allow (600 s decoded at 8 kHz, 4.8 M samples, 448×88), same
 * hop of 4096 either way, node on an M-series laptop:
 *
 *   1024 window, hop 4096   1173 frames    32 ms   25% of the clip inside a window
 *   8192 window, hop 4096   1171 frames   241 ms  100% of the clip inside a window
 *
 * 7.5× the DSP, and 270 ms for the whole `analyse` including the envelope and
 * the colourise — which is why §2.11.1 puts this in a worker. That is the
 * price of the strip being a picture of the clip instead of a sample of it,
 * and it is paid once per file and then cached.
 *
 * Past this ceiling `framePlan` lets the windows ABUT rather than growing
 * further — still gapless, just no longer overlapped.
 */
export const MAX_FFT_SIZE = 8192;

/**
 * §2.11.1's duration ceiling ("about 10 minutes"): past this the spectrum is
 * skipped and the row falls back to the amplitude-only silhouette.
 */
export const DURATION_CAP_S = 600;

/**
 * And past THIS there is no strip at all — not even the silhouette. An hour of
 * audio is not a 44pt picture, and the envelope pass still has to decode the
 * whole file to draw 448 numbers. iOS's `SpectrogramSpec.envelopeCap`.
 */
export const ENVELOPE_CAP_S = 3600;

/**
 * The silhouette-only fallback needs no frequency resolution at all — it is a
 * one-pole follower over sample magnitudes — so it decodes far coarser than the
 * spectrum, which is what buys the band between the two ceilings.
 *
 * iOS decodes it at 1 kHz. The web cannot ask for that reliably: an
 * `OfflineAudioContext` may refuse any rate its implementation does not
 * support, and the floor is 8 kHz in the Web Audio spec and 3 kHz in most
 * engines. So this is a REQUEST — js/strip.js probes down to what the runtime
 * actually accepts and `analysisPlan` recomputes the reachable ceiling from
 * whatever came back, rather than promising a band the browser cannot decode.
 */
export const ENVELOPE_RATE = 3000;

/**
 * …and what that band is allowed to COST, which is not `MAX_SAMPLES`. The two
 * numbers bound different things: `MAX_SAMPLES` is the ceiling on the mono
 * ANALYSIS buffer the FFT reads, and `decodeMono`'s box average enforces it
 * independently whatever the decode hands back; this is the ceiling on how long
 * a clip the silhouette band may decode at all.
 *
 * Charging the coarse pass against the fine pass's ceiling is what collapsed
 * this band to zero width on any engine whose `OfflineAudioContext` floor is
 * the Web Audio spec's own 8 kHz — the case `contextAtOrAbove` exists for.
 * 601 s x 8000 = 4.808 M already clears 4.8 M, so the silhouette was refused
 * from the first second past `DURATION_CAP_S` and the whole band existed only
 * on the engines that happen to decode at 3 kHz. Headless Chrome is one of
 * them, which is why no test saw it.
 *
 * 9.6 M samples is 38 MB of transient float, gated to two at a time by
 * `DECODE_SLOTS` — the same order as the spectrum path's 19 MB — and it buys
 * 1200 s at 8 kHz and 3200 s at 3 kHz. The band is therefore non-empty on every
 * engine, which is what §2.11.1 asks for ("a 12-minute set gets a silhouette
 * rather than a hairline") and what iOS gets for free by decoding at 1 kHz.
 */
export const ENVELOPE_MAX_SAMPLES = 9600000;

// ── normalisation ──────────────────────────────────────────────────────────

/** Display span below the rolling peak, in dB (Wake's `dynRangeDb`). */
export const DYN_RANGE_DB = 48;

/**
 * Floor for the rolling AGC reference (Wake's `agcFloor`). The AGC keeps
 * OPENING through a quiet passage so a quiet recording still fills the strip;
 * this is where it stops, so true digital silence stays dark instead of
 * blooming into the noise of nothing.
 */
export const AGC_FLOOR = 1e-4;

/** Seconds for the AGC peak to fall by 1/e once the loud part is over. */
export const AGC_RELEASE_S = 2;

/**
 * Spectral-tilt compensation, straight from Wake. Natural sound has a ~1/f
 * slope, so a RAW magnitude spectrum always reads bass-heavy — a bright bar
 * along the bottom of the strip and black above it. Lifting the display by a
 * fixed dB/octave about a mid-band pivot is what every analyser does and what
 * makes the top of the strip carry information.
 */
export const TILT_DB_PER_OCT = 4.5;
export const TILT_PIVOT_HZ = 1000;

// ── the envelope ───────────────────────────────────────────────────────────

/**
 * One-pole follower time constants (§2.11.1: "fast attack, slow release").
 * These are TIME constants, not coefficients: the per-sample coefficient is
 * derived from the decimated rate by `onePoleCoefficient`, so the silhouette
 * is the same shape whatever rate the analysis ran at. 5 ms catches a
 * transient; 150 ms is slow enough that the result reads as the shape of the
 * take rather than as a bar chart of peaks.
 */
export const ENVELOPE_ATTACK_MS = 5;
export const ENVELOPE_RELEASE_MS = 150;

/**
 * The per-sample coefficient of a one-pole filter with time constant `ms` at
 * `rate`: `1 − e^(−1/(τ·rate))`. A step held for τ seconds lands at 1 − 1/e
 * (≈0.632) of its target, which is what the unit test measures.
 */
export function onePoleCoefficient(ms, rate) {
  const tau = Math.max(1e-6, ms) / 1000;
  const fs = Math.max(1, rate);
  return 1 - Math.exp(-1 / (tau * fs));
}

/**
 * §2.11.1's follower, verbatim: `y += (x > y ? attack : release) * (x − y)`
 * over sample MAGNITUDES. One pole, not a peak-per-bin bar chart.
 *
 * The canonical statement of the formula, and what the unit test measures the
 * time constants through. The strip itself does not call it — `envelopeColumns`
 * inlines the same three lines to avoid holding a float per input sample.
 */
export function followEnvelope(samples, rate, { attackMs = ENVELOPE_ATTACK_MS, releaseMs = ENVELOPE_RELEASE_MS } = {}) {
  const a = onePoleCoefficient(attackMs, rate);
  const r = onePoleCoefficient(releaseMs, rate);
  const n = samples.length;
  const out = new Float32Array(n);
  let y = 0;
  for (let i = 0; i < n; i += 1) {
    const x = Math.abs(samples[i]);
    y += (x > y ? a : r) * (x - y);
    out[i] = y;
  }
  return out;
}

/**
 * The follower collapsed to one value per strip column — the peak of the
 * envelope inside each column's slice of time — then normalised so the
 * silhouette spans the strip (LZWaveform's `bins.max()` scaling). A column
 * with no samples inherits the one before it, so a clip shorter than the strip
 * is wide is still a continuous line rather than a comb.
 *
 * The follower runs INLINE here rather than through `followEnvelope`, because
 * that returns one float per input sample: at the sample cap that is a second
 * 19 MB array whose only purpose is to be peak-picked down to 448 numbers, and
 * it would live alongside the decoded buffer it was computed from. One pass, no
 * allocation but the columns.
 */
export function envelopeColumns(samples, rate, cols, { attackMs = ENVELOPE_ATTACK_MS, releaseMs = ENVELOPE_RELEASE_MS } = {}) {
  const w = Math.max(1, cols);
  const out = new Float32Array(w);
  const n = samples.length;
  if (!n) return out;
  const a = onePoleCoefficient(attackMs, rate);
  const r = onePoleCoefficient(releaseMs, rate);
  const seen = new Uint8Array(w);
  let peak = 0;
  let y = 0;
  for (let i = 0; i < n; i += 1) {
    const x = Math.abs(samples[i]);
    y += (x > y ? a : r) * (x - y);
    const c = Math.min(w - 1, Math.floor((i * w) / n));
    if (y > out[c]) out[c] = y;
    seen[c] = 1;
    if (y > peak) peak = y;
  }
  // a clip shorter than the strip is wide leaves columns untouched: carry the
  // last value forward so the silhouette is a line and not a comb
  for (let c = 1; c < w; c += 1) if (!seen[c]) out[c] = out[c - 1];
  const scale = 1 / Math.max(peak, 1e-6);
  for (let c = 0; c < w; c += 1) out[c] = Math.min(1, out[c] * scale);
  return out;
}

// ── the log frequency axis ─────────────────────────────────────────────────

/**
 * Row index (0 = lowest, `rows − 1` = highest) for a frequency, on the log
 * axis §2.11.1 asks for. Below the span floors at 0, above it clamps to the
 * top row: pitch is spaced logarithmically, so the axis is too.
 */
export function rowForFrequency(hz, rows, fMax = F_MAX, fMin = F_MIN) {
  const span = Math.log(fMax / fMin);
  const t = span > 0 ? Math.log(Math.max(hz, 1e-9) / fMin) / span : 0;
  return Math.max(0, Math.min(rows - 1, Math.floor(t * rows)));
}

/** Geometric centre frequency of a row — the inverse of `rowForFrequency`. */
export function bandCentreHz(row, rows, fMax = F_MAX, fMin = F_MIN) {
  return fMin * (fMax / fMin) ** ((row + 0.5) / rows);
}

/**
 * FFT bin index bounds `[lo, hi)` for every row of the log axis. Wake computes
 * these inline per frame; precomputing them once is the whole difference
 * between a strip and a stutter, because the frame loop runs thousands of
 * times over the same edges.
 */
export function logBandEdges(rows, rate, fftSize = FFT_SIZE, fMax = axisMaxHz(rate)) {
  const bins = fftSize >> 1;
  const nyquist = Math.max(1, rate) / 2;
  const lo = new Int32Array(rows);
  const hi = new Int32Array(rows);
  const centre = new Float32Array(rows);
  for (let i = 0; i < rows; i += 1) {
    const f0 = F_MIN * (fMax / F_MIN) ** (i / rows);
    const f1 = F_MIN * (fMax / F_MIN) ** ((i + 1) / rows);
    centre[i] = bandCentreHz(i, rows, fMax);
    if (f0 >= nyquist) {
      // Unreachable at the default axis, which ENDS at Nyquist — this is for a
      // caller that passes a higher `fMax` anyway. An EMPTY range rather than a
      // clamp onto the top real bin: clamping would smear the highest band the
      // analysis can see across every row above it, painting a bright ceiling
      // out of one bin's worth of energy.
      lo[i] = 0;
      hi[i] = 0;
      continue;
    }
    const b0 = Math.max(0, Math.floor((f0 * fftSize) / rate));
    lo[i] = Math.min(bins - 1, b0);
    hi[i] = Math.min(bins, Math.max(lo[i] + 1, Math.floor((f1 * fftSize) / rate)));
  }
  return { lo, hi, centre, fMax };
}

// ── the FFT ────────────────────────────────────────────────────────────────

/** Hann window (`vDSP_hann_window`'s periodic-free, symmetric form). */
export function hannWindow(n) {
  const w = new Float32Array(n);
  for (let i = 0; i < n; i += 1) w[i] = 0.5 * (1 - Math.cos((2 * Math.PI * i) / (n - 1)));
  return w;
}

/**
 * In-place radix-2 complex FFT. The house primitive on iOS is vDSP's
 * real-to-complex path (WakeFFTAnalyzer.swift); the web has no vDSP and this
 * repo has no dependencies and adds none, so this is the same transform written
 * out — a real signal with a zero imaginary part, N/2 magnitude bins taken off
 * the front half. Twiddles are precomputed once per size because the frame loop
 * re-enters this thousands of times.
 */
export class Fft {
  constructor(size = FFT_SIZE) {
    if (size < 2 || (size & (size - 1)) !== 0) throw new Error('fft size must be a power of two');
    this.size = size;
    this.levels = Math.log2(size);
    this.cos = new Float32Array(size / 2);
    this.sin = new Float32Array(size / 2);
    for (let i = 0; i < size / 2; i += 1) {
      this.cos[i] = Math.cos((2 * Math.PI * i) / size);
      this.sin[i] = Math.sin((2 * Math.PI * i) / size);
    }
    this.re = new Float32Array(size);
    this.im = new Float32Array(size);
    this.window = hannWindow(size);
    this.mags = new Float32Array(size / 2);
  }

  /**
   * Windowed magnitudes of `count` samples starting at `offset`, scaled by 1/N
   * exactly as WakeFFTAnalyzer does, so a 0 dBFS sine reads the same number on
   * both platforms. Short tails are zero-padded rather than dropped.
   */
  magnitudes(samples, offset = 0, count = this.size) {
    const { size, re, im, window, cos, sin, mags } = this;
    const len = Math.max(0, Math.min(size, count, samples.length - offset));
    for (let i = 0; i < len; i += 1) re[i] = samples[offset + i] * window[i];
    for (let i = len; i < size; i += 1) re[i] = 0;
    im.fill(0);

    // bit reversal
    for (let i = 1, j = 0; i < size; i += 1) {
      let bit = size >> 1;
      for (; j & bit; bit >>= 1) j ^= bit;
      j ^= bit;
      if (i < j) {
        let t = re[i]; re[i] = re[j]; re[j] = t;
        t = im[i]; im[i] = im[j]; im[j] = t;
      }
    }
    for (let len2 = 2; len2 <= size; len2 <<= 1) {
      const half = len2 >> 1;
      const step = size / len2;
      for (let i = 0; i < size; i += len2) {
        for (let j = 0, k = 0; j < half; j += 1, k += step) {
          const c = cos[k];
          const s = -sin[k];
          const a = i + j;
          const b = a + half;
          const tr = re[b] * c - im[b] * s;
          const ti = re[b] * s + im[b] * c;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
    const scale = 1 / size;
    for (let i = 0; i < size / 2; i += 1) mags[i] = Math.hypot(re[i], im[i]) * scale;
    return mags;
  }
}

// ── the analysis ───────────────────────────────────────────────────────────

/**
 * How the STFT is laid out over a clip: ~50% overlap (§2.11.1) until the frame
 * count would pass `MAX_FRAMES`, at which point the WINDOW doubles and the hop
 * doubles with it — never the hop alone.
 *
 * The invariant this exists to hold is `hop <= fftSize`: every sample of the
 * clip is inside at least one window, so the strip is a picture of the whole
 * clip and not a periodic sample of it. Opening the hop past the window is
 * what would put blind gaps between the frames — see `MAX_FRAMES`.
 *
 * At `MAX_FFT_SIZE` the doubling stops and the hop opens to exactly one window:
 * still gapless, no longer overlapped, and only reachable by a clip longer than
 * anything `analysisPlan` will decode (8.4 M samples against a 4.8 M cap), so
 * it is a guard rather than a mode.
 */
export function framePlan(sampleCount, fftSize = FFT_SIZE, maxFrames = MAX_FRAMES, maxFftSize = MAX_FFT_SIZE) {
  const cap = Math.max(2, maxFrames);
  let size = Math.max(2, fftSize);
  // ceil, not floor: with floor the frames stop up to one hop short of the end
  // and the clip's last half second is never inside a window. The extra frame
  // starts inside the clip (hop <= fftSize) and zero-pads its tail, which is
  // what `Fft.magnitudes` does with a short read anyway.
  const framesAt = (s, h) => Math.ceil(Math.max(0, sampleCount - s) / h) + 1;
  let hop = size >> 1;
  while (framesAt(size, hop) > cap && size * 2 <= maxFftSize) {
    size *= 2;
    hop = size >> 1;
  }
  if (framesAt(size, hop) > cap) hop = size; // the window ceiling: windows abut
  return { hop, frames: Math.max(1, framesAt(size, hop)), fftSize: size };
}

/**
 * The whole clip → one `cols × rows` field of 0…1 magnitudes plus the
 * envelope, ready to colourise.
 *
 * Two passes per frame, as in Wake's `logBars`: peak-pick each log band and
 * apply the pink-slope tilt, tracking the tilted frame max; roll the AGC off
 * that max (instant attack, exponential release toward AGC_FLOOR); then
 * dB-normalise each band against the rolling reference over DYN_RANGE_DB.
 * Because the frames run left to right in time, that rolling reference IS the
 * strip's AGC — a quiet passage brightens as the reference falls to meet it.
 *
 * Frames collapse onto columns by peak-pick when there are more frames than
 * columns, and by carry-forward when there are fewer, so `mag` is always
 * exactly `cols × rows` whatever the clip's length.
 */
export function analyse({ samples, rate, cols, rows, fftSize = FFT_SIZE, maxFrames = MAX_FRAMES, dynRangeDb = DYN_RANGE_DB, tiltDbPerOct = TILT_DB_PER_OCT }) {
  const w = Math.max(1, cols | 0);
  const h = Math.max(1, rows | 0);
  const mag = new Float32Array(w * h);
  const envelope = envelopeColumns(samples, rate, w);
  const plan = framePlan(samples.length, fftSize, maxFrames);
  // plan.fftSize, not fftSize: a long clip runs a WIDER window so the frames
  // still abut (framePlan), and the bins, the twiddles and the band edges all
  // have to be the window the frames are actually taken at.
  const bands = logBandEdges(h, rate, plan.fftSize);
  const fft = new Fft(plan.fftSize);
  const tilt = new Float32Array(h);
  for (let b = 0; b < h; b += 1) tilt[b] = 10 ** ((tiltDbPerOct * Math.log2(bands.centre[b] / TILT_PIVOT_HZ)) / 20);

  const tilted = new Float32Array(h);
  const seen = new Uint8Array(w);
  // Seed the reference off the first frame rather than off silence: without it
  // the opening of every clip is clipped white while the AGC catches up.
  let agc = AGC_FLOOR;
  const hopSeconds = plan.hop / Math.max(1, rate);
  const release = Math.exp(-hopSeconds / AGC_RELEASE_S);

  for (let f = 0; f < plan.frames; f += 1) {
    const mags = fft.magnitudes(samples, f * plan.hop, plan.fftSize);
    let frameMax = 0;
    for (let b = 0; b < h; b += 1) {
      let m = 0;
      for (let k = bands.lo[b]; k < bands.hi[b]; k += 1) if (mags[k] > m) m = mags[k];
      const mt = m * tilt[b];
      tilted[b] = mt;
      if (mt > frameMax) frameMax = mt;
    }
    if (f === 0) agc = Math.max(frameMax, AGC_FLOOR);
    else agc = frameMax > agc ? frameMax : Math.max(agc * release, AGC_FLOOR);

    const col = Math.min(w - 1, Math.floor((f * w) / plan.frames));
    const base = col * h;
    for (let b = 0; b < h; b += 1) {
      const rel = tilted[b] / Math.max(agc, AGC_FLOOR);
      const db = 20 * Math.log10(Math.max(rel, 1e-5));
      const v = Math.max(0, Math.min(1, (db + dynRangeDb) / dynRangeDb));
      if (!seen[col] || v > mag[base + b]) mag[base + b] = v;
    }
    seen[col] = 1;
  }
  // fewer frames than columns: carry the last computed column forward, so a
  // 2 s voice note is a continuous strip and not a picket fence
  for (let c = 1; c < w; c += 1) {
    if (seen[c]) continue;
    mag.copyWithin(c * h, (c - 1) * h, c * h);
    seen[c] = 1;
  }
  return { mag, envelope, cols: w, rows: h, frames: plan.frames, hop: plan.hop, fftSize: plan.fftSize, fMax: bands.fMax };
}

// ── the ramp ───────────────────────────────────────────────────────────────

/**
 * Stop-interpolated ramp colour for 0…1 — the shape of Wake's `LZ.heatRGB`,
 * none of its colours. Wake's ramp is near-black → cyan → gold → white, which
 * is the Console family's language; House Pour's is transparent → line2 →
 * muted → accent → accent2, and it arrives here as `--ramp-*` from
 * design/tokens.json (see `rampStops` in vendor/house-pour.js). Nothing in
 * this file names a colour.
 *
 * Both ends clamp: below the first stop is the first stop, above the last is
 * the last.
 */
export function rampColorAt(stops, v) {
  const empty = { r: 0, g: 0, b: 0, a: 0 };
  if (!stops || !stops.length) return empty;
  const x = Math.max(0, Math.min(1, Number.isFinite(v) ? v : 0));
  const first = stops[0];
  if (x <= first.at) return { r: first.r, g: first.g, b: first.b, a: first.a };
  for (let i = 1; i < stops.length; i += 1) {
    if (x > stops[i].at) continue;
    const s0 = stops[i - 1];
    const s1 = stops[i];
    const span = s1.at - s0.at;
    const t = span > 0 ? (x - s0.at) / span : 0;
    return {
      r: s0.r + (s1.r - s0.r) * t,
      g: s0.g + (s1.g - s0.g) * t,
      b: s0.b + (s1.b - s0.b) * t,
      a: s0.a + (s1.a - s0.a) * t,
    };
  }
  const last = stops[stops.length - 1];
  return { r: last.r, g: last.g, b: last.b, a: last.a };
}

/**
 * Colourise a `cols × rows` magnitude field into straight (non-premultiplied)
 * RGBA bytes, ready for `ImageData`. Image row 0 is the TOP of the strip and
 * therefore the HIGHEST band: §2.11.1 runs frequency bottom (low) to top
 * (high), and image rows run the other way.
 *
 * A texture, not a path — the Wake lesson. The strip never changes once it is
 * computed, so it is blitted; only the envelope and the playhead repaint.
 */
export function paintStrip(mag, cols, rows, stops) {
  const px = new Uint8ClampedArray(cols * rows * 4);
  for (let c = 0; c < cols; c += 1) {
    const base = c * rows;
    for (let r = 0; r < rows; r += 1) {
      const band = rows - 1 - r;
      const { r: cr, g: cg, b: cb, a } = rampColorAt(stops, mag[base + band]);
      const o = (r * cols + c) * 4;
      px[o] = cr;
      px[o + 1] = cg;
      px[o + 2] = cb;
      px[o + 3] = a * 255;
    }
  }
  return px;
}

// ── the caps ───────────────────────────────────────────────────────────────

/**
 * What this clip is allowed to cost, decided BEFORE a byte is fetched — the
 * cheapest place to degrade, and §2.11.1's cost rule is that the strip degrades
 * rather than blocking. Three bands, the same three iOS runs
 * (`SpectrogramPlan.forDuration`):
 *
 *   spectrum  decode at `analysisRate`, FFT, colourise: the whole strip.
 *   envelope  past `DURATION_CAP_S` — decode coarse and mono for the
 *             silhouette alone, skip the FFT and the texture. This is the band
 *             §2.11.1 asks for by name ("fall back to the amplitude-only
 *             silhouette") and the one the web used to drop on the floor: a
 *             12 minute DJ set rendered as the bare §2.11 hairline while the
 *             same clip drew a silhouette on iOS.
 *   none      past `ENVELOPE_CAP_S`, or past what the runtime's slowest
 *             decodable rate can fit inside `ENVELOPE_MAX_SAMPLES` — an hour of
 *             audio is not a 44pt picture.
 *
 * An unknown or absent duration is not a refusal: it plans a spectrum and lets
 * the decode be the one that fails. `decodeMono`'s own sample ceiling is what
 * catches a file whose header lied about its length.
 */
export function analysisPlan(durationSeconds, {
  cap = DURATION_CAP_S,
  hardCap = ENVELOPE_CAP_S,
  envelopeRate = ENVELOPE_RATE,
  maxSamples = MAX_SAMPLES,
  envelopeMaxSamples = ENVELOPE_MAX_SAMPLES,
} = {}) {
  const d = Number(durationSeconds);
  if (!Number.isFinite(d) || d <= 0) return { mode: 'spectrum', rate: TARGET_RATE, reason: null };
  if (d <= cap) return { mode: 'spectrum', rate: analysisRate(d, maxSamples), reason: null };
  const rate = Math.max(1, envelopeRate);
  if (d > hardCap) return { mode: 'none', rate: 0, reason: 'too-long' };
  // The runtime may not decode as coarsely as we asked (see ENVELOPE_RATE), and
  // a silhouette is not worth blowing the working-set ceiling for. That ceiling
  // is the envelope band's OWN (see ENVELOPE_MAX_SAMPLES) — charging this pass
  // against the spectrum's `maxSamples` refuses every clip past the cap on an
  // 8 kHz-floor engine, which is the band deleting itself.
  if (d * rate > envelopeMaxSamples) return { mode: 'none', rate: 0, reason: 'too-many-samples' };
  return { mode: 'envelope', rate, reason: 'too-long' };
}
