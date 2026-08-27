/* spectro.worker.js — the strip's analysis, off the main thread (PRODUCT §2.11.1).
 *
 * "Analysis is off the main thread." A 10 minute clip is thousands of FFTs;
 * running them on the feed's thread is a scroll that stops dead while a card
 * nobody is looking at computes a picture. Everything the worker needs arrives
 * in the message — decimated mono samples (transferred, not copied) and the
 * ramp stops the main thread read out of `--ramp-*` — so this file imports the
 * pure module and nothing else, and never touches the DOM or a token.
 *
 * The reply carries the RGBA texture and the envelope back as transfers too:
 * a 1024×88 strip is 360 KB, and structured-cloning that per clip is the kind
 * of copy the media budget was written to stop.
 */
import { analyse, envelopeColumns, paintStrip } from './spectro.js';

self.onmessage = (e) => {
  const { id, samples, rate, cols, rows, stops, mode = 'spectrum' } = e.data ?? {};
  try {
    // Past §2.11.1's duration ceiling there is no spectrum, only the
    // silhouette — but it is still a pass over every sample of a clip that is
    // long by definition, so it runs here rather than on the feed's thread.
    if (mode === 'envelope') {
      const envelope = envelopeColumns(samples, rate, cols);
      self.postMessage({ id, ok: true, rgba: null, envelope, cols, rows }, [envelope.buffer]);
      return;
    }
    const { mag, envelope } = analyse({ samples, rate, cols, rows });
    const rgba = paintStrip(mag, cols, rows, stops);
    self.postMessage({ id, ok: true, rgba, envelope, cols, rows }, [rgba.buffer, envelope.buffer]);
  } catch (err) {
    self.postMessage({ id, ok: false, error: String(err?.message ?? err) });
  }
};
