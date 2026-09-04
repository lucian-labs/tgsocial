/* demo/media.js — every picture, clip and waveform the demo shows, produced in
 * this page from the item's own key (PRODUCT §2.22.1).
 *
 * Nothing here is bundled and nothing here is fetched. "No fixture carries a
 * photograph of a person" is enforced by there being no photograph anywhere:
 * a plate is a seeded gradient between two House Pour tokens with a few shapes
 * over it and the fixture key printed in its corner, so a post card cropped out
 * of context still says what it is.
 *
 * Every generator is deterministic in its key, memoised, and LAZY — the getter
 * on the media item's `file.url` is what runs it (js/demo/world.js). A feed of
 * fifteen posts therefore costs nothing until something scrolls into view, and
 * the 3:42 clip is only synthesised if somebody plays it.
 *
 * The two exceptions to "synchronous" are the video and the animation
 * (§2.22.1's procedural frame sources). A browser has exactly one way to turn
 * drawn frames into a seekable clip — MediaRecorder over a captured canvas —
 * and it records in real time, so those two answer a Promise instead of a
 * string. `directUrl` in js/media.js takes either.
 */
import { analysisRate } from '../spectro.js';

/** Deterministic 32-bit hash of the item key — the only entropy in here. */
function seedOf(key) {
  let h = 0x811c9dc5;
  for (let i = 0; i < key.length; i += 1) {
    h ^= key.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h || 1;
}

/** xorshift32, so the same key draws the same plate on every run. */
function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s ^= s << 13; s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5; s >>>= 0;
    return s / 4294967296;
  };
}

const TOKENS = ['--accent', '--accent-2', '--violet', '--good', '--ink', '--muted', '--faint', '--bg-2', '--panel'];

function token(name, fallback) {
  try {
    const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    return v || fallback;
  } catch {
    return fallback;
  }
}

const memo = new Map();
/** Recordings still running, so leaving the demo can stop them (js/app.js). */
const recordings = new Set();
/**
 * Bumped every time the demo is left. A clip that was still recording then
 * must hand nothing back: the memo has gone, but whoever asked for it is still
 * holding the promise, and a URL minted now would be set on a detached element
 * one tick before this module revoked it — a media fetch for a blob that is
 * already gone, which the browser reports as a network error in the console of
 * a demo that has already ended.
 */
let generation = 0;

function once(key, make) {
  if (!memo.has(key)) memo.set(key, make());
  return memo.get(key);
}

/**
 * Leaving the demo keeps nothing, here included: every blob: URL this module
 * minted is revoked and every recording still drawing frames is stopped. The
 * plates are data: URIs and go with the memo.
 */
export function releaseGenerated() {
  generation += 1;
  for (const stop of [...recordings]) stop();
  recordings.clear();
  for (const value of memo.values()) {
    if (typeof value === 'string' && value.startsWith('blob:')) URL.revokeObjectURL(value);
    // a clip is a promise of a URL; it may still be in flight
    else if (value && typeof value.then === 'function') value.then((url) => URL.revokeObjectURL(url), () => null);
  }
  memo.clear();
}

// ── plates (PRODUCT §2.22.1) ───────────────────────────────────────────────

function drawPlate(key, w, h, { label = true } = {}) {
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d');
  const rand = rng(seedOf(key));
  const a = token(TOKENS[Math.floor(rand() * TOKENS.length)], '#a4813b');
  const b = token(TOKENS[Math.floor(rand() * TOKENS.length)], '#f1eee6');
  const grad = ctx.createLinearGradient(0, 0, w, h);
  grad.addColorStop(0, a);
  grad.addColorStop(1, b);
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, w, h);
  const unit = Math.min(w, h);
  for (let i = 0; i < 5; i += 1) {
    ctx.globalAlpha = 0.10 + rand() * 0.18;
    ctx.fillStyle = token(TOKENS[Math.floor(rand() * TOKENS.length)], '#262319');
    if (rand() < 0.5) {
      ctx.beginPath();
      ctx.arc(rand() * w, rand() * h, unit * (0.06 + rand() * 0.24), 0, Math.PI * 2);
      ctx.fill();
    } else {
      ctx.fillRect(rand() * w, rand() * h, unit * (0.05 + rand() * 0.5), unit * (0.02 + rand() * 0.1));
    }
  }
  ctx.globalAlpha = 1;
  if (label) {
    // §2.22: the plate names itself, in mono `faint`, bottom-left
    const size = Math.max(11, Math.round(unit * 0.045));
    ctx.font = `${size}px Inconsolata, ui-monospace, monospace`;
    ctx.textBaseline = 'alphabetic';
    ctx.fillStyle = token('--faint', '#a79f8d');
    ctx.fillText(key, size, h - size);
  }
  return canvas;
}

/** A plate at the item's aspect, as a data: URI. `key` is `<channel>/<id>·<n>`. */
export function plate(key, w, h) {
  return once(`plate:${key}:${w}x${h}`, () => drawPlate(key, w, h).toDataURL('image/jpeg', 0.72));
}

/** The blur-up placeholder §2.11 paints before the picture (a 16 px plate). */
export function minithumb(key, w, h) {
  const scale = 16 / Math.max(w, h);
  return once(`mini:${key}`, () => drawPlate(key, Math.max(2, Math.round(w * scale)), Math.max(2, Math.round(h * scale)), { label: false }).toDataURL('image/jpeg', 0.5));
}

// ── audio (PRODUCT §2.22.1) ────────────────────────────────────────────────

function wavBlob(samples, rate) {
  const n = samples.length;
  const bytes = new ArrayBuffer(44 + n * 2);
  const view = new DataView(bytes);
  const ascii = (at, s) => { for (let i = 0; i < s.length; i += 1) view.setUint8(at + i, s.charCodeAt(i)); };
  ascii(0, 'RIFF');
  view.setUint32(4, 36 + n * 2, true);
  ascii(8, 'WAVEfmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, rate, true);
  view.setUint32(28, rate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, 'data');
  view.setUint32(40, n * 2, true);
  for (let i = 0; i < n; i += 1) view.setInt16(44 + i * 2, Math.max(-32768, Math.min(32767, Math.round(samples[i] * 32767))), true);
  return new Blob([bytes], { type: 'audio/wav' });
}

/**
 * §2.22.1's clip: a pink-noise bed near −24 dBFS, a 220 → 880 Hz log sweep
 * from 0:30 to 0:38, and two 40 ms clicks a minute. Broadband plus tonal, so
 * the spectrogram (§2.11.1) has structure to draw and the one-pole envelope
 * has a silhouette rather than a rectangle.
 *
 * Synthesised at the strip's own decimated rate, because that is the rate the
 * analysis will resample to anyway and a 3:42 clip at 48 kHz is ten megabytes
 * of samples nobody hears.
 */
export function clipUrl(key, seconds) {
  return once(`wav:${key}`, () => {
    const rate = analysisRate(seconds);
    const n = Math.round(seconds * rate);
    const samples = new Float32Array(n);
    const rand = rng(seedOf(key));
    // one-pole low-passed white noise ≈ pink enough for a spectrogram to show
    // a tilted floor rather than a flat one
    let pink = 0;
    let phase = 0;
    for (let i = 0; i < n; i += 1) {
      const t = i / rate;
      pink = pink * 0.94 + (rand() * 2 - 1) * 0.06;
      let v = pink * 1.6; // ≈ −24 dBFS
      if (t >= 30 && t < 38) {
        const f = 220 * (880 / 220) ** ((t - 30) / 8);
        phase += (2 * Math.PI * f) / rate;
        v += 0.35 * Math.sin(phase);
      }
      const intoMinute = t % 60;
      if ((intoMinute >= 12 && intoMinute < 12.04) || (intoMinute >= 41 && intoMinute < 41.04)) v += 0.5 * (rand() * 2 - 1);
      samples[i] = v;
    }
    return URL.createObjectURL(wavBlob(samples, rate));
  });
}

/**
 * Telegram-shaped waveform bytes for the voice note: packed 5-bit samples,
 * base64. §2.11.2's draw-immediately-then-analyse path is the one that runs
 * only when these are here, so the fixture ships them rather than leaving the
 * row blank until the decode lands.
 */
export function waveformBytes(key, bars = 100) {
  return once(`wave:${key}`, () => {
    const rand = rng(seedOf(key));
    const values = new Array(bars);
    let level = 6;
    for (let i = 0; i < bars; i += 1) {
      level = Math.max(1, Math.min(31, level + Math.round((rand() * 2 - 1) * 9)));
      // a spoken phrase falls away at the end rather than stopping square
      values[i] = Math.round(level * (i > bars * 0.9 ? (bars - i) / (bars * 0.1) : 1));
    }
    const bytes = new Uint8Array(Math.ceil((bars * 5) / 8));
    for (let i = 0; i < bars; i += 1) {
      const bit = i * 5;
      const byte = bit >> 3;
      const shift = bit & 7;
      const packed = (values[i] & 0x1f) << shift;
      bytes[byte] |= packed & 0xff;
      if (byte + 1 < bytes.length) bytes[byte + 1] |= (packed >> 8) & 0xff;
    }
    let bin = '';
    for (const b of bytes) bin += String.fromCharCode(b);
    return btoa(bin);
  });
}

// ── the document (PRODUCT §2.22.1) ─────────────────────────────────────────

/**
 * A real one-page PDF, written out here rather than bundled, so a reader who
 * saves `tide-table-1971.pdf` out of the demo gets a file that opens and says
 * what it is.
 */
export function documentUrl(key, fileName) {
  return once(`doc:${key}`, () => {
    const lines = [
      `(${fileName}) Tj`,
      '0 -28 Td',
      '(Invented for the tgsocial demo. PRODUCT 2.22.) Tj',
      '0 -28 Td',
      `(${key}) Tj`,
    ].join('\n');
    const stream = `BT\n/F1 16 Tf\n56 720 Td\n${lines}\nET`;
    const objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
      `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ];
    let pdf = '%PDF-1.4\n';
    const offsets = [];
    objects.forEach((body, i) => {
      offsets.push(pdf.length);
      pdf += `${i + 1} 0 obj\n${body}\nendobj\n`;
    });
    const xref = pdf.length;
    pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
    for (const at of offsets) pdf += `${String(at).padStart(10, '0')} 00000 n \n`;
    pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
    return URL.createObjectURL(new Blob([pdf], { type: 'application/pdf' }));
  });
}

// ── procedural clips (PRODUCT §2.22.1) ─────────────────────────────────────

const FPS = 12;

/**
 * A moving House Pour bar drawn at 12 fps and recorded off the canvas, at the
 * fixture's declared length, so the duration pill, the scrubber and the
 * full-screen player are all telling the truth about the same clip.
 *
 * §2.22.1 keeps this a frame source rather than a bundled mp4 — "a decoded
 * file exercises nothing the frame source does not". On the web the only
 * frame source a `<video>` will seek is one that has been recorded, and
 * MediaRecorder records in real time, so this is started EAGERLY when the demo
 * opens (js/demo/world.js) and answers a promise. A build with no
 * MediaRecorder rejects, the block keeps its poster, and nothing else changes.
 */
export function recordClip(key, seconds, w, h) {
  return once(`clip:${key}`, () => new Promise((resolve, reject) => {
    const canvas = document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext('2d');
    const rand = rng(seedOf(key));
    const bg = token(TOKENS[Math.floor(rand() * TOKENS.length)], '#f1eee6');
    const bar = token(TOKENS[Math.floor(rand() * TOKENS.length)], '#a4813b');
    let stream;
    let rec;
    try {
      stream = canvas.captureStream(FPS);
      const type = ['video/webm;codecs=vp8', 'video/webm', 'video/mp4'].find((t) => typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(t));
      if (!type) throw new Error('No recordable video type.');
      rec = new MediaRecorder(stream, { mimeType: type });
    } catch (e) {
      reject(e);
      return;
    }
    const chunks = [];
    let timer = null;
    const started = performance.now();
    const born = generation;
    /**
     * Stop drawing and ask the recorder to flush. Called when the clip reaches
     * its declared length, and by releaseGenerated() when the demo is left
     * mid-recording — an 18 s clip outlives a reader who looked around for
     * five, and its interval must not.
     */
    const stop = () => {
      if (timer) clearInterval(timer);
      timer = null;
      recordings.delete(stop);
      try {
        if (rec.state !== 'inactive') rec.stop();
        else settle();
      } catch {
        settle();
      }
    };
    const settle = () => {
      for (const track of stream.getTracks()) track.stop();
      // the demo was left while this was still recording: mint nothing and
      // settle nothing, so nobody is handed a URL that is about to be revoked
      if (born !== generation) return;
      if (!chunks.length) {
        reject(new Error('Recording produced nothing.'));
        return;
      }
      resolve(URL.createObjectURL(new Blob(chunks, { type: rec.mimeType || 'video/webm' })));
    };
    rec.ondataavailable = (e) => {
      if (e.data && e.data.size) chunks.push(e.data);
    };
    rec.onerror = () => {
      if (timer) clearInterval(timer);
      timer = null;
      recordings.delete(stop);
      reject(new Error('Recording failed.'));
    };
    rec.onstop = settle;
    const draw = () => {
      const t = (performance.now() - started) / 1000;
      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, w, h);
      ctx.fillStyle = bar;
      const x = ((t / seconds) % 1) * (w * 1.4) - w * 0.2;
      ctx.fillRect(x, 0, w * 0.18, h);
      ctx.globalAlpha = 0.5;
      ctx.fillRect(0, h * 0.5 - 1, w * ((t / seconds) % 1), 2);
      ctx.globalAlpha = 1;
      const size = Math.max(11, Math.round(Math.min(w, h) * 0.045));
      ctx.font = `${size}px Inconsolata, ui-monospace, monospace`;
      ctx.fillStyle = token('--faint', '#a79f8d');
      ctx.fillText(key, size, h - size);
      if (t >= seconds) stop();
    };
    recordings.add(stop);
    draw();
    timer = setInterval(draw, 1000 / FPS);
    rec.start();
  }));
}
