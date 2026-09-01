/* House Pour kit — web helpers.
 *
 * Tiny DOM helpers plus the behaviours the stylesheet cannot express:
 * toast (fades, never slides, 2.8 s), modal (card over the scrim, never dark),
 * tabs (the one segmented control), toggle (the derived switch), media,
 * avatar. Every class name here is styled by house-pour.css (upstream
 * classes plus house-pour.components.css); every value is a token via CSS.
 * No framework.
 *
 * Copied verbatim to web/vendor/house-pour.js by hand (design/web is the
 * source). ES module; no globals.
 */

// ── DOM ────────────────────────────────────────────────────────────────────

/**
 * h('div.card', { onclick, 'aria-label': 'x', dataset: {...} }, child, 'text', [more])
 * Strings become text nodes — never markup — so Telegram-sourced text is safe.
 */
export function h(spec, attrs, ...children) {
  const [tag, ...classes] = spec.split('.');
  const el = document.createElement(tag || 'div');
  if (classes.length) el.className = classes.join(' ');
  if (attrs && typeof attrs === 'object' && !(attrs instanceof Node) && !Array.isArray(attrs)) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v === null || v === undefined || v === false) continue;
      if (k === 'class') el.className = `${el.className} ${v}`.trim();
      else if (k === 'dataset') Object.assign(el.dataset, v);
      else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
      else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
      else if (k in el && typeof v !== 'string' && k !== 'list') el[k] = v;
      else el.setAttribute(k, v === true ? '' : String(v));
    }
  } else if (attrs !== undefined) {
    children.unshift(attrs);
  }
  append(el, children);
  return el;
}

export function append(el, children) {
  for (const c of children.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

export function clear(el) {
  while (el.firstChild) el.removeChild(el.firstChild);
  return el;
}

export function replace(el, ...children) {
  clear(el);
  append(el, children);
  return el;
}

// ── components ─────────────────────────────────────────────────────────────

/** .btn[.primary|.accent|.ghost|.danger][.sm] — label is text, never markup. */
export function button(label, { style = 'neutral', size, onClick, disabled = false, type = 'button', ariaLabel, title } = {}) {
  const el = h('button.btn', { type, disabled, 'aria-label': ariaLabel, title }, label);
  if (style && style !== 'neutral') el.classList.add(style);
  if (size === 'sm') el.classList.add('sm');
  if (onClick) el.addEventListener('click', onClick);
  return el;
}

export function pill(text, tone = 'neutral') {
  const el = h('span.pill', text);
  if (tone === 'gold') el.classList.add('gold');
  if (tone === 'bad') el.classList.add('bad');
  return el;
}

/** Section mark: uppercase label with the trailing hairline; optional serif count. */
export function sectionMark(text, count) {
  const label = h('span.mark-label', text);
  if (count !== undefined && count !== null) {
    label.append(document.createTextNode(' · '));
    label.append(h('span.mark-count', String(count)));
  }
  return h('h3', label);
}

/** label.field + input. Returns { wrap, input }. */
export function field(label, attrs = {}) {
  const id = attrs.id || `f_${Math.random().toString(36).slice(2, 8)}`;
  const tag = attrs.multiline ? 'textarea' : 'input';
  const { multiline, ...rest } = attrs;
  const input = h(tag, { ...rest, id });
  const wrap = h('div.field-wrap', h('label.field', { for: id }, label), input);
  return { wrap, input };
}

/** .tabs segmented control. items: [{ id, label }]. Returns the element; el.select(id) to change. */
export function tabs(items, selected, onSelect) {
  const el = h('div.tabs', { role: 'tablist' });
  const buttons = new Map();
  for (const item of items) {
    const b = h('button', { type: 'button', role: 'tab', 'aria-selected': item.id === selected ? 'true' : 'false' }, item.label);
    if (item.id === selected) b.classList.add('active');
    b.addEventListener('click', () => {
      el.select(item.id);
      if (onSelect) onSelect(item.id);
    });
    buttons.set(item.id, b);
    el.append(b);
  }
  el.select = (id) => {
    for (const [k, b] of buttons) {
      b.classList.toggle('active', k === id);
      b.setAttribute('aria-selected', k === id ? 'true' : 'false');
    }
  };
  return el;
}

/**
 * HPToggle: a role="switch" button. toggle(isOn, onChange, { label, disabled }).
 * Repaints itself on click, then calls onChange(next). el.set(on) repaints
 * without firing (rollback); el.isOn() reads the state.
 */
export function toggle(isOn, onChange, { label, disabled = false } = {}) {
  const el = h('button.toggle', { type: 'button', role: 'switch', 'aria-checked': isOn ? 'true' : 'false', 'aria-label': label, disabled });
  el.isOn = () => el.getAttribute('aria-checked') === 'true';
  el.set = (on) => el.setAttribute('aria-checked', on ? 'true' : 'false');
  el.addEventListener('click', () => {
    const next = !el.isOn();
    el.set(next);
    if (onChange) onChange(next);
  });
  return el;
}

/**
 * HPMedia: full-width image box, media radius, bg2 placeholder while loading.
 * media(src, aspect, { mini }) — aspect is a CSS aspect-ratio value ('4 / 3');
 * src may be null and set later with el.setImage(url). `mini` is a tiny data:
 * URI painted blurred under the image until it loads (PRODUCT §2.11 blur-up).
 * el.img is the <img>.
 */
export function media(src, aspect, { mini = null } = {}) {
  const img = h('img', { alt: '', loading: 'lazy' });
  const el = h('div.media', { style: aspect ? { aspectRatio: String(aspect) } : null });
  if (mini) el.append(h('img.media-mini', { src: mini, alt: '', 'aria-hidden': 'true' }));
  el.append(img);
  img.addEventListener('load', () => el.classList.add('loaded'), { once: true });
  if (src) img.src = src;
  el.img = img;
  el.setImage = (url) => {
    img.src = url;
  };
  return el;
}

// ── HPKebabButton / HPMenu ─────────────────────────────────────────────────

/** Fade-out grace before the menu leaves the DOM — matches --motion-toast. */
const MENU_FADE_MS = 220;

/**
 * HPKebabButton: the vertical three-dot button. 40pt ghost hit box; the dots
 * are three token-coloured boxes drawn by the stylesheet, never a glyph, so
 * nothing system-styled leaks in. Icon-only, so the label is required in
 * spirit — it becomes the accessible name.
 */
export function kebabButton({ label = 'More', onClick } = {}) {
  const el = h('button.kebab', { type: 'button', 'aria-label': label, 'aria-haspopup': 'menu', 'aria-expanded': 'false' }, h('i'), h('i'), h('i'));
  if (onClick) el.addEventListener('click', onClick);
  return el;
}

/** The app column width, in px, read off the token — the compact-width line. */
function columnMax() {
  const v = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--space-column-max'));
  return Number.isFinite(v) ? v : 0;
}

/**
 * HPMenu: a panel card of HPListItem rows, anchored under `anchor` (absolute,
 * right-aligned) — or, when the viewport is narrower than the app column, a
 * bottom sheet over a scrim. Dismisses on outside click, Escape and scroll.
 *
 * menu(items, { anchor, label, onClose }) → { root, card, close }
 * items: [{ label, onSelect }]
 */
export function menu(items, { anchor = null, label = 'Menu', onClose = null } = {}) {
  const card = h('div.menu', { role: 'menu', 'aria-label': label });
  for (const item of items) {
    const row = h('button.list-item', { type: 'button', role: 'menuitem' }, item.label);
    row.addEventListener('click', (e) => {
      e.stopPropagation();
      close();
      if (item.onSelect) item.onSelect();
    });
    card.append(row);
  }

  const compact = window.innerWidth <= columnMax();
  if (compact) card.classList.add('sheet');
  const root = compact ? h('div.menu-scrim', card) : card;
  const host = compact ? document.getElementById('modal') || document.body : anchor || document.body;
  host.append(root);

  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    document.removeEventListener('keydown', onKey, true);
    document.removeEventListener('pointerdown', onOutside, true);
    window.removeEventListener('scroll', onScroll, true);
    window.removeEventListener('resize', onScroll);
    root.classList.remove('show');
    setTimeout(() => root.remove(), MENU_FADE_MS);
    if (onClose) onClose();
  };
  const onKey = (e) => {
    if (e.key !== 'Escape') return;
    e.stopPropagation();
    close();
  };
  // Anything outside the card — the scrim included — dismisses. The anchor is
  // exempt so the button's own click can toggle rather than close-then-reopen.
  const onOutside = (e) => {
    if (card.contains(e.target)) return;
    if (anchor && anchor.contains(e.target)) return;
    close();
  };
  const onScroll = () => close();
  document.addEventListener('keydown', onKey, true);
  document.addEventListener('pointerdown', onOutside, true);
  window.addEventListener('scroll', onScroll, { passive: true, capture: true });
  window.addEventListener('resize', onScroll);
  requestAnimationFrame(() => root.classList.add('show'));
  return { root, card, close };
}

/**
 * HPKebabMenu: the button and its menu as one element. Returns the anchor —
 * drop it wherever the corner is. el.closeMenu() dismisses programmatically.
 */
export function kebabMenu(items, { label = 'More' } = {}) {
  const wrap = h('div.menu-anchor');
  let open = null;
  const btn = kebabButton({
    label,
    onClick: () => {
      if (open) {
        open.close();
        return;
      }
      btn.setAttribute('aria-expanded', 'true');
      open = menu(items, {
        anchor: wrap,
        label,
        onClose: () => {
          open = null;
          btn.setAttribute('aria-expanded', 'false');
        },
      });
    },
  });
  wrap.append(btn);
  wrap.closeMenu = () => open?.close();
  return wrap;
}

// ── icons (inline SVG, currentColor — no emoji in chrome) ──────────────────

const ICON_PATHS = {
  play: 'M5.5 3.2v9.6a.5.5 0 0 0 .77.42l7.2-4.8a.5.5 0 0 0 0-.84l-7.2-4.8a.5.5 0 0 0-.77.42Z',
  pause: 'M4.5 3h2.4a.5.5 0 0 1 .5.5v9a.5.5 0 0 1-.5.5H4.5a.5.5 0 0 1-.5-.5v-9a.5.5 0 0 1 .5-.5Zm4.6 0h2.4a.5.5 0 0 1 .5.5v9a.5.5 0 0 1-.5.5H9.1a.5.5 0 0 1-.5-.5v-9a.5.5 0 0 1 .5-.5Z',
  close: 'M4.05 4.05a.6.6 0 0 1 .85 0L8 7.15l3.1-3.1a.6.6 0 1 1 .85.85L8.85 8l3.1 3.1a.6.6 0 1 1-.85.85L8 8.85l-3.1 3.1a.6.6 0 1 1-.85-.85L7.15 8l-3.1-3.1a.6.6 0 0 1 0-.85Z',
  download: 'M8 2.2a.6.6 0 0 1 .6.6v6l2.02-2.02a.6.6 0 1 1 .85.85L8.42 10.7a.6.6 0 0 1-.84 0L4.53 7.63a.6.6 0 1 1 .85-.85L7.4 8.8v-6a.6.6 0 0 1 .6-.6ZM3.2 12.2h9.6a.6.6 0 0 1 0 1.2H3.2a.6.6 0 0 1 0-1.2Z',
  file: 'M4.6 1.8h4.2l2.6 2.6v9.2a.6.6 0 0 1-.6.6H4.6a.6.6 0 0 1-.6-.6V2.4a.6.6 0 0 1 .6-.6Zm4 1.2H5.2v10h5.6V5.2H9.2a.6.6 0 0 1-.6-.6V3Z',
};

/** icon('play') → inline SVG in currentColor. Decorative: aria-hidden. */
export function icon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 16 16');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('class', `icon icon-${name}`);
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', ICON_PATHS[name] ?? '');
  path.setAttribute('fill', 'currentColor');
  svg.append(path);
  return svg;
}

// ── HPScrubber ─────────────────────────────────────────────────────────────

/**
 * Hairline scrubber: line2 track, gold played segment, 12pt panel knob with
 * the contact shadow. scrubber({ onSeek, label }) → el; el.set(fraction).
 * onSeek(fraction) fires on tap and on drag release.
 */
export function scrubber({ onSeek = null, label = 'Seek' } = {}) {
  const played = h('div.scrubber-played');
  const knob = h('div.scrubber-knob');
  const el = h('div.scrubber', { role: 'slider', tabindex: 0, 'aria-label': label, 'aria-valuemin': '0', 'aria-valuemax': '100', 'aria-valuenow': '0' }, h('div.scrubber-track', played), knob);
  let fraction = 0;
  const paint = (f) => {
    const pct = `${Math.round(f * 1000) / 10}%`;
    played.style.width = pct;
    knob.style.left = pct;
    el.setAttribute('aria-valuenow', String(Math.round(f * 100)));
  };
  el.set = (f) => {
    if (el.dataset.dragging) return;
    fraction = Math.max(0, Math.min(1, f || 0));
    paint(fraction);
  };
  const fractionAt = (clientX) => {
    const r = el.getBoundingClientRect();
    return r.width ? Math.max(0, Math.min(1, (clientX - r.left) / r.width)) : 0;
  };
  el.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    e.stopPropagation();
    el.dataset.dragging = '1';
    el.setPointerCapture(e.pointerId);
    paint(fractionAt(e.clientX));
  });
  el.addEventListener('pointermove', (e) => {
    if (el.dataset.dragging) paint(fractionAt(e.clientX));
  });
  const release = (e) => {
    if (!el.dataset.dragging) return;
    delete el.dataset.dragging;
    fraction = fractionAt(e.clientX);
    paint(fraction);
    if (onSeek) onSeek(fraction);
  };
  el.addEventListener('pointerup', release);
  el.addEventListener('pointercancel', (e) => {
    delete el.dataset.dragging;
    paint(fraction);
  });
  el.addEventListener('keydown', (e) => {
    const step = e.key === 'ArrowRight' ? 0.05 : e.key === 'ArrowLeft' ? -0.05 : null;
    if (step === null) return;
    e.preventDefault();
    fraction = Math.max(0, Math.min(1, fraction + step));
    paint(fraction);
    if (onSeek) onSeek(fraction);
  });
  return el;
}

// ── tokens read back out of CSS ────────────────────────────────────────────

/**
 * A token's computed value, for the two things CSS cannot paint by itself: a
 * canvas and a bitmap. Rule 1 says zero raw hex in component code, and a
 * canvas needs a concrete colour string — so the component asks the cascade
 * for the token it would have used in a stylesheet. One source of truth, and a
 * brand change still moves everything.
 */
export function tokenValue(el, name, fallback = '') {
  try {
    const v = getComputedStyle(el).getPropertyValue(name).trim();
    return v || fallback;
  } catch {
    return fallback;
  }
}

/**
 * The spectrogram ramp (PRODUCT §2.11.1) as parsed stops, straight out of the
 * generated `--ramp-*` custom properties (design/tokens.json → build.mjs). The
 * analysis colourises a bitmap pixel by pixel, so it needs numbers; reading
 * them back from the cascade is what keeps the ramp ONE edit shared with iOS
 * and Android instead of a second copy in JavaScript.
 *
 * Returns `[{ at, r, g, b, a }]` sorted by `at`, or [] when the stylesheet has
 * not loaded (the caller then leaves the strip at its hairline fidelity).
 */
export function rampStops(root = document.documentElement) {
  const count = parseInt(tokenValue(root, '--ramp-stops', '0'), 10);
  if (!Number.isFinite(count) || count < 2) return [];
  const out = [];
  for (let i = 0; i < count; i += 1) {
    const raw = tokenValue(root, `--ramp-${i}`);
    const at = parseFloat(tokenValue(root, `--ramp-${i}-at`, 'NaN'));
    const m = /rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:[\s,/]+([\d.]+))?\s*\)/.exec(raw);
    if (!m || !Number.isFinite(at)) return [];
    out.push({ at, r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] });
  }
  return out.sort((a, b) => a.at - b.at);
}

// ── HPStrip ────────────────────────────────────────────────────────────────

/** Progress fraction from a pointer's x, against an element's box. */
function fractionIn(el, clientX) {
  const r = el.getBoundingClientRect();
  return r.width ? Math.max(0, Math.min(1, (clientX - r.left) / r.width)) : 0;
}

/**
 * HPStrip — the audio scrubber (PRODUCT §2.11.1). Not a hairline: a
 * spectrogram of the WHOLE clip with its one-pole amplitude envelope over it,
 * on `bg2` at `radius-media`, and it IS the scrubber — you can see where the
 * loud part is before you drag to it.
 *
 * Three fidelities, because §2.11.1 requires the row to be usable the moment
 * it appears and the spectrum to fill in behind it. `data-fidelity` says which
 * one is painted:
 *
 *   hair  the hairline of §2.11 — line2 track, gold played segment. What a
 *         clip past the duration ceiling, or one that would not decode, keeps.
 *   wave  the silhouette alone. A voice note gets this IMMEDIATELY from
 *         Telegram's own waveform bytes, with no decode at all.
 *   full  silhouette over spectrogram.
 *
 * Painted height is `--space-strip-height` (44), which is over `touchMin`, so
 * the 40pt hit region of rule 6 is simply the strip's own drawn shape — no
 * overlay reaching past it into a neighbour's band.
 *
 * strip({ onSeek, label }) → el with
 *   el.set(fraction) · el.setSpectrum(url) · el.setEnvelope(values|null)
 *   el.clearSpectrum() · el.fidelity · el.hasEnvelope
 */
export function strip({ onSeek = null, label = 'Seek' } = {}) {
  const spectrum = h('img.strip-spectrum', { alt: '', 'aria-hidden': 'true', decoding: 'async' });
  const wave = h('canvas.strip-wave', { 'aria-hidden': 'true' });
  const played = h('div.strip-played');
  const head = h('div.strip-head');
  const el = h('div.strip', {
    role: 'slider',
    tabindex: 0,
    'aria-label': label,
    'aria-valuemin': '0',
    'aria-valuemax': '100',
    'aria-valuenow': '0',
    'data-fidelity': 'hair',
  }, h('div.strip-track'), played, spectrum, wave, head);

  let fraction = 0;
  let envelope = null;

  const paintWave = () => {
    const box = el.getBoundingClientRect();
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const w = Math.max(1, Math.round(box.width * dpr));
    const hpx = Math.max(1, Math.round(box.height * dpr));
    if (wave.width !== w || wave.height !== hpx) {
      wave.width = w;
      wave.height = hpx;
    }
    const ctx = wave.getContext('2d');
    if (!ctx) return;
    ctx.clearRect(0, 0, w, hpx);
    const n = envelope?.length ?? 0;
    if (n < 2) return;

    // Colours and weights come from the cascade (see tokenValue): played is
    // `accent`, ahead of the playhead the strip is `ink` at reduced opacity.
    const playedColor = tokenValue(el, '--strip-played');
    const unplayedColor = tokenValue(el, '--strip-unplayed');
    const fillAlpha = parseFloat(tokenValue(el, '--strip-fill-alpha', '0.55'));
    const dim = parseFloat(tokenValue(el, '--strip-unplayed-alpha', '0.35'));
    const line = parseFloat(tokenValue(el, '--strip-ridge', '1.5')) * dpr;

    const mid = hpx / 2;
    const amp = mid * 0.92;
    const stepX = w / (n - 1);
    const yAt = (i) => mid - Math.max(0, Math.min(1, envelope[i])) * amp;

    // Mirrored about the strip's centre and filled — LZWaveform's
    // LZPointWave silhouette, closed against its reflection instead of
    // against a baseline. Played and unplayed are separate runs that SHARE
    // their boundary point, so the split is an Int compare and the outline
    // stays continuous across the colour change.
    const split = fraction <= 0 ? 0 : Math.max(1, Math.min(n - 1, Math.round(fraction * (n - 1))));
    const runs = fraction <= 0
      ? [[0, n - 1, false]]
      : [[0, split, true], [split, n - 1, false]];
    for (const [from, to, isPlayed] of runs) {
      if (to <= from) continue;
      const color = isPlayed ? playedColor : unplayedColor;
      const alpha = isPlayed ? 1 : dim;
      ctx.beginPath();
      for (let i = from; i <= to; i += 1) {
        const x = i * stepX;
        if (i === from) ctx.moveTo(x, yAt(i));
        else ctx.lineTo(x, yAt(i));
      }
      for (let i = to; i >= from; i -= 1) ctx.lineTo(i * stepX, mid + (mid - yAt(i)));
      ctx.closePath();
      ctx.globalAlpha = fillAlpha * alpha;
      ctx.fillStyle = color;
      ctx.fill();
      ctx.globalAlpha = alpha;
      ctx.strokeStyle = color;
      ctx.lineWidth = line;
      ctx.stroke();
    }
    ctx.globalAlpha = 1;
  };

  const paint = (f) => {
    fraction = Math.max(0, Math.min(1, f || 0));
    const pct = `${Math.round(fraction * 1000) / 10}%`;
    played.style.width = pct;
    head.style.left = pct;
    head.hidden = fraction <= 0;
    el.setAttribute('aria-valuenow', String(Math.round(fraction * 100)));
    if (envelope) paintWave();
  };

  const fidelity = () => {
    if (spectrum.getAttribute('src')) return 'full';
    return envelope ? 'wave' : 'hair';
  };
  const sync = () => el.setAttribute('data-fidelity', fidelity());

  el.set = (f) => {
    if (el.dataset.dragging) return;
    paint(f);
  };
  el.setSpectrum = (url) => {
    if (!url) return el.clearSpectrum();
    spectrum.src = url;
    sync();
    return el;
  };
  el.clearSpectrum = () => {
    spectrum.removeAttribute('src');
    sync();
    return el;
  };
  /** The silhouette: 0…1 per column. Null drops back to the hairline. */
  el.setEnvelope = (values) => {
    envelope = values && values.length > 1 ? values : null;
    sync();
    paint(fraction);
    return el;
  };
  el.repaint = () => paint(fraction);
  Object.defineProperty(el, 'fidelity', { get: fidelity });
  Object.defineProperty(el, 'hasEnvelope', { get: () => !!envelope });

  // a texture that failed to load must not leave the strip claiming `full`
  spectrum.addEventListener('error', () => el.clearSpectrum());

  // Tap or drag anywhere on the strip to seek (§2.11.1). Painting follows the
  // finger; the seek itself lands on release, as HPScrubber does, so a drag
  // across a card is one seek and not forty.
  el.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    e.stopPropagation();
    el.dataset.dragging = '1';
    try {
      el.setPointerCapture(e.pointerId);
    } catch {
      // a synthetic pointer with no capture support still drags fine
    }
    paint(fractionIn(el, e.clientX));
  });
  el.addEventListener('pointermove', (e) => {
    if (el.dataset.dragging) paint(fractionIn(el, e.clientX));
  });
  el.addEventListener('pointerup', (e) => {
    if (!el.dataset.dragging) return;
    delete el.dataset.dragging;
    paint(fractionIn(el, e.clientX));
    if (onSeek) onSeek(fraction);
  });
  el.addEventListener('pointercancel', () => {
    delete el.dataset.dragging;
    paint(fraction);
  });
  el.addEventListener('keydown', (e) => {
    const step = e.key === 'ArrowRight' ? 0.05 : e.key === 'ArrowLeft' ? -0.05 : null;
    if (step === null) return;
    e.preventDefault();
    paint(fraction + step);
    if (onSeek) onSeek(fraction);
  });
  head.hidden = true;
  return el;
}

// ── HPMiniWave ─────────────────────────────────────────────────────────────

/**
 * HPMiniWave — the now-playing dock's waveform (PRODUCT §2.11.2).
 *
 * The dock is not the place for a spectrogram. This is ONE polyline through the
 * envelope's column peaks: a line drawing, not the strip's mirrored filled
 * silhouette and not the spectrum. Hairline weight, `muted` ahead of the
 * playhead and `accent` behind it, and nothing under the curve.
 *
 * It computes nothing. The caller hands it the envelope the STRIP already
 * analysed (§2.11.1), resampled to this element's own column count — which is
 * what `el.columns` reports — so playing a clip never triggers a second
 * analysis. With no envelope at all (a clip whose strip degraded to the
 * hairline) the polyline is FLAT rather than absent: zero amplitude is a
 * straight line down the middle, which is §2.11's hairline drawn by the same
 * code path.
 *
 * It paints `--space-dock-wave` tall and keeps a full `touchMin` region through
 * `.hit-min` (rule 6): the target reaches past the painted bounds instead of
 * inflating the dock row. The host row must not clip its overflow.
 *
 * miniWave({ onSeek, label }) → el with
 *   el.set(fraction) · el.setEnvelope(values|null) · el.columns · el.hasEnvelope
 */
export function miniWave({ onSeek = null, label = 'Seek' } = {}) {
  const canvas = h('canvas.mini-wave-line', { 'aria-hidden': 'true' });
  const el = h('div.mini-wave.hit-min', {
    role: 'slider',
    tabindex: 0,
    'aria-label': label,
    'aria-valuemin': '0',
    'aria-valuemax': '100',
    'aria-valuenow': '0',
  }, canvas);

  let fraction = 0;
  let envelope = null;

  /** Device columns this wave paints — the width the caller resamples to. */
  const columns = () => {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    return Math.max(2, Math.round(el.getBoundingClientRect().width * dpr));
  };

  const paintWave = () => {
    const box = el.getBoundingClientRect();
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const w = Math.max(2, Math.round(box.width * dpr));
    const hpx = Math.max(2, Math.round(box.height * dpr));
    if (canvas.width !== w || canvas.height !== hpx) {
      canvas.width = w;
      canvas.height = hpx;
    }
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    ctx.clearRect(0, 0, w, hpx);

    // Rule 1: a canvas needs a concrete colour, so the component asks the
    // cascade for the token it would have used in a stylesheet.
    const playedColor = tokenValue(el, '--mini-wave-played');
    const aheadColor = tokenValue(el, '--mini-wave-ahead');
    const line = parseFloat(tokenValue(el, '--mini-wave-ridge', '1')) * dpr;

    // The baseline is the middle and the peaks rise off it, so silence and a
    // missing envelope are the SAME shape — the flat line §2.11.2 asks for.
    const mid = hpx / 2;
    const amp = Math.max(0, mid - line / 2);
    const n = envelope?.length ?? 0;
    const cols = Math.max(2, n);
    const stepX = w / (cols - 1);
    const yAt = (i) => mid - (n ? Math.max(0, Math.min(1, envelope[i])) : 0) * amp;

    // Two runs sharing their boundary point, as HPStrip does: the split is an
    // Int compare and the polyline stays continuous across the colour change.
    const split = fraction <= 0 ? 0 : Math.max(1, Math.min(cols - 1, Math.round(fraction * (cols - 1))));
    const runs = fraction <= 0
      ? [[0, cols - 1, false]]
      : [[0, split, true], [split, cols - 1, false]];
    ctx.lineWidth = line;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    for (const [from, to, isPlayed] of runs) {
      if (to <= from) continue;
      ctx.beginPath();
      for (let i = from; i <= to; i += 1) {
        const x = i * stepX;
        if (i === from) ctx.moveTo(x, yAt(i));
        else ctx.lineTo(x, yAt(i));
      }
      ctx.strokeStyle = isPlayed ? playedColor : aheadColor;
      ctx.stroke();
    }
  };

  const paint = (f) => {
    fraction = Math.max(0, Math.min(1, f || 0));
    el.setAttribute('aria-valuenow', String(Math.round(fraction * 100)));
    paintWave();
  };

  el.set = (f) => {
    if (el.dataset.dragging) return;
    paint(f);
  };
  /** The envelope, already at `el.columns`. Null draws the flat line. */
  el.setEnvelope = (values) => {
    envelope = values && values.length > 1 ? values : null;
    paint(fraction);
    return el;
  };
  el.repaint = () => paint(fraction);
  Object.defineProperty(el, 'columns', { get: columns });
  Object.defineProperty(el, 'hasEnvelope', { get: () => !!envelope });

  // Tap or drag to seek, exactly as the strip does: painting follows the
  // finger, the seek lands on release, and the row underneath never sees the
  // gesture (the dock row's own tap opens the post the audio came from).
  el.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    e.stopPropagation();
    el.dataset.dragging = '1';
    try {
      el.setPointerCapture(e.pointerId);
    } catch {
      // a synthetic pointer with no capture support still drags fine
    }
    paint(fractionIn(el, e.clientX));
  });
  el.addEventListener('pointermove', (e) => {
    if (el.dataset.dragging) paint(fractionIn(el, e.clientX));
  });
  el.addEventListener('pointerup', (e) => {
    if (!el.dataset.dragging) return;
    delete el.dataset.dragging;
    paint(fractionIn(el, e.clientX));
    if (onSeek) onSeek(fraction);
  });
  el.addEventListener('pointercancel', () => {
    delete el.dataset.dragging;
    paint(fraction);
  });
  el.addEventListener('click', (e) => e.stopPropagation());
  el.addEventListener('keydown', (e) => {
    const step = e.key === 'ArrowRight' ? 0.05 : e.key === 'ArrowLeft' ? -0.05 : null;
    if (step === null) return;
    e.preventDefault();
    e.stopPropagation();
    paint(fraction + step);
    if (onSeek) onSeek(fraction);
  });
  return el;
}

// ── HPRing ─────────────────────────────────────────────────────────────────

/**
 * Determinate gold progress ring over a media placeholder. Tapping cancels.
 * ring({ onCancel, label }) → el; el.set(fraction).
 */
export function ring({ onCancel = null, label = 'Cancel download' } = {}) {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 40 40');
  svg.setAttribute('aria-hidden', 'true');
  const track = document.createElementNS(NS, 'circle');
  const arc = document.createElementNS(NS, 'circle');
  for (const [c, cls] of [[track, 'ring-track'], [arc, 'ring-arc']]) {
    c.setAttribute('cx', '20');
    c.setAttribute('cy', '20');
    c.setAttribute('r', '17');
    c.setAttribute('class', cls);
    svg.append(c);
  }
  const circumference = 2 * Math.PI * 17;
  arc.style.strokeDasharray = String(circumference);
  arc.style.strokeDashoffset = String(circumference);
  const el = h('button.ring', { type: 'button', 'aria-label': label }, svg);
  el.set = (f) => {
    arc.style.strokeDashoffset = String(circumference * (1 - Math.max(0, Math.min(1, f || 0))));
  };
  if (onCancel) {
    el.addEventListener('click', (e) => {
      e.stopPropagation();
      onCancel();
    });
  }
  return el;
}

// ── HPPlayerRow ────────────────────────────────────────────────────────────

/**
 * Audio / voice player row (PRODUCT §2.11): 40pt play circle (stepper style),
 * title + performer, serif elapsed/total, and the scrubber underneath.
 *
 * The scrubber is normally an HPStrip (§2.11.1 — the spectrogram of the clip,
 * which is also how you seek): the caller owns the analysis, so it builds the
 * strip and hands it in as `track`. Without one the row falls back to the
 * hairline HPScrubber, or to waveform bars when `waveform` values are given —
 * the shapes a player row had before the strip existed, kept because a video's
 * transport and the tests still use them.
 *
 * playerRow({ title, sub, duration, waveform, track, onToggle, onSeek }) → el
 * with el.setPlaying(bool) · el.setTime(elapsedText, totalText) ·
 * el.set(fraction) · el.setBusy(bool) · el.track.
 */
export function playerRow({ title, sub = '', duration = '0:00', waveform = null, track: given = null, onToggle = null, onSeek = null, label = 'Play' } = {}) {
  const btn = h('button.player-btn', { type: 'button', 'aria-label': label }, icon('play'));
  const elapsed = h('span.player-time', '0:00');
  const total = h('span.player-time.player-total', duration);
  let track;
  let bars = [];
  if (given) {
    track = given;
  } else if (waveform && waveform.length) {
    track = h('div.waveform', { role: 'presentation' });
    bars = waveform.map((v) => h('i', { style: { height: `${Math.round(18 + v * 82)}%` } }));
    append(track, bars);
    if (onSeek) {
      track.addEventListener('pointerdown', (e) => {
        e.stopPropagation();
        const r = track.getBoundingClientRect();
        if (r.width) onSeek(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)));
      });
    }
  } else {
    track = scrubber({ onSeek, label: `Seek ${title}` });
  }
  const el = h('div.player',
    btn,
    h('div.player-main',
      h('div.player-head', h('div.player-title', title), h('div.player-times', elapsed, h('span.player-time.player-sep', '/'), total)),
      sub ? h('div.player-sub', sub) : null,
      track,
    ),
  );
  if (onToggle) {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      onToggle();
    });
  }
  el.setPlaying = (playing) => {
    replace(btn, icon(playing ? 'pause' : 'play'));
    btn.setAttribute('aria-label', playing ? `Pause ${title}` : `Play ${title}`);
  };
  el.setTime = (a, b) => {
    elapsed.textContent = a;
    if (b !== undefined) total.textContent = b;
  };
  el.set = (f) => {
    if (bars.length) {
      const k = Math.round(f * bars.length);
      bars.forEach((bar, i) => bar.classList.toggle('played', i < k));
    } else track.set(f);
  };
  el.setBusy = (busy) => el.classList.toggle('busy', !!busy);
  el.track = track;
  return el;
}

// ── HPNowPlaying ───────────────────────────────────────────────────────────

/**
 * Slim now-playing row docked above the floating tab bar while audio plays
 * (PRODUCT §2.11): play/pause, title, serif elapsed, and the mini waveform of
 * §2.11.2 — the strip's own envelope, resampled to this row's width.
 *
 * "Tapping the row anywhere but its controls opens the post the audio came
 * from", so the row is a control too: the play button and the waveform stop
 * their gestures at themselves and everything else in the row reaches `onOpen`.
 *
 * nowPlaying({ title, onToggle, onSeek, onOpen }) → el with
 *   el.setPlaying(bool) · el.setTime(text) · el.set(fraction) ·
 *   el.setEnvelope(values|null) · el.wave
 */
export function nowPlaying({ title, onToggle = null, onSeek = null, onOpen = null } = {}) {
  const btn = h('button.player-btn.sm', { type: 'button', 'aria-label': `Pause ${title}` }, icon('pause'));
  const elapsed = h('span.player-time', '0:00');
  const wave = miniWave({ onSeek, label: `Seek ${title}` });
  const el = h('div.now-playing', btn, wave, h('div.now-playing-title', title), elapsed);
  if (onToggle) {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      onToggle();
    });
  }
  if (onOpen) {
    el.setAttribute('role', 'button');
    el.setAttribute('tabindex', '0');
    el.setAttribute('aria-label', `Open ${title}`);
    el.addEventListener('click', onOpen);
    el.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter' && e.key !== ' ') return;
      e.preventDefault();
      onOpen();
    });
  }
  el.setPlaying = (playing) => {
    replace(btn, icon(playing ? 'pause' : 'play'));
    btn.setAttribute('aria-label', playing ? `Pause ${title}` : `Play ${title}`);
  };
  el.setTime = (t) => {
    elapsed.textContent = t;
  };
  el.set = (f) => wave.set(f);
  el.setEnvelope = (values) => wave.setEnvelope(values);
  el.wave = wave;
  return el;
}

// ── HPViewer ───────────────────────────────────────────────────────────────

/**
 * Full-screen media viewer shell (PRODUCT §2.11): ink at 96%, the one other
 * dark surface. Top chrome: Close (ghost) left, serif counter centre, actions
 * right. Stage in the middle, caption below in charcoal text. Zoom/swipe
 * behaviour belongs to the caller; Escape and the Close button call onClose.
 *
 * viewer({ onClose, label }) → { root, stage, caption, counter, actions, close }.
 */
export function viewer({ onClose = null, label = 'Media viewer' } = {}) {
  const stage = h('div.viewer-stage');
  const caption = h('div.viewer-caption');
  const counter = h('span.viewer-counter');
  const actions = h('div.viewer-actions');
  const closeBtn = button('Close', { style: 'ghost', size: 'sm', ariaLabel: 'Close viewer' });
  const root = h('div.viewer', { role: 'dialog', 'aria-modal': 'true', 'aria-label': label },
    h('div.viewer-chrome', closeBtn, counter, actions),
    stage,
    caption,
  );
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    document.removeEventListener('keydown', onKey);
    root.remove();
    if (onClose) onClose();
  };
  const onKey = (e) => {
    if (e.key === 'Escape') close();
  };
  closeBtn.addEventListener('click', close);
  document.addEventListener('keydown', onKey);
  return { root, stage, caption, counter, actions, close };
}

// ── toast ──────────────────────────────────────────────────────────────────

let toastRoot = null;
let toastTimer = null;

function ensureToastRoot() {
  if (!toastRoot) {
    toastRoot = document.getElementById('toast') || h('div.toast', { id: 'toast', role: 'status', 'aria-live': 'polite' });
    if (!toastRoot.isConnected) document.body.append(toastRoot);
  }
  return toastRoot;
}

/** toast('Posted.', 'good') — fades in, holds 2.8 s, fades out. tone: 'good' | 'bad' | undefined. */
export function toast(message, tone, { duration = 2800 } = {}) {
  const el = ensureToastRoot();
  if (toastTimer) clearTimeout(toastTimer);
  el.classList.remove('good', 'bad', 'show');
  el.textContent = message;
  if (tone === 'good' || tone === 'bad') el.classList.add(tone);
  // next frame so the opacity transition runs when the toast was already hidden
  requestAnimationFrame(() => el.classList.add('show'));
  toastTimer = setTimeout(() => {
    el.classList.remove('show');
    toastTimer = null;
  }, duration);
  return el;
}

// ── modal ──────────────────────────────────────────────────────────────────

/**
 * modal(cardContent, { onClose, dismissible }) → { close(), root }.
 * A .card centred over the scrim. Escape and scrim click close when dismissible.
 */
export function modal(content, { onClose, dismissible = true, label = 'Dialog' } = {}) {
  const host = document.getElementById('modal') || document.body;
  const card = h('div.card.modal-card', { role: 'dialog', 'aria-modal': 'true', 'aria-label': label }, content);
  const root = h('div.modal-scrim', card);
  let closed = false;
  const close = (result) => {
    if (closed) return;
    closed = true;
    root.classList.remove('show');
    document.removeEventListener('keydown', onKey);
    setTimeout(() => root.remove(), 220);
    if (onClose) onClose(result);
  };
  const onKey = (e) => {
    if (e.key === 'Escape' && dismissible) close();
  };
  root.addEventListener('click', (e) => {
    if (e.target === root && dismissible) close();
  });
  document.addEventListener('keydown', onKey);
  host.append(root);
  requestAnimationFrame(() => root.classList.add('show'));
  const focusable = card.querySelector('input, textarea, button');
  if (focusable) setTimeout(() => focusable.focus(), 30);
  return { close, root, card };
}

/** Confirm modal: h2 + muted body + .btn-row. Resolves true/false. */
export function confirm({ title, body, okLabel = 'OK', okStyle = 'primary', cancelLabel = 'Cancel' }) {
  return new Promise((resolve) => {
    let m;
    const ok = button(okLabel, { style: okStyle, onClick: () => m.close(true) });
    const cancel = button(cancelLabel, { style: 'ghost', onClick: () => m.close(false) });
    const content = [title ? h('h2', title) : null, body ? h('p.muted', body) : null, h('div.btn-row', ok, cancel)];
    m = modal(content, { onClose: (r) => resolve(!!r), label: title || 'Confirm' });
  });
}

// ── misc ───────────────────────────────────────────────────────────────────

export function initial(name) {
  const s = (name || '').trim().replace(/^@/, '');
  if (!s) return '·';
  const ch = Array.from(s)[0];
  return ch.toUpperCase();
}

/** Avatar: circle with an img when a src is given, else the serif initial. size: 'row' | 'profile'. */
export function avatar(name, src, size = 'row') {
  const el = h(`div.avatar.${size}`, { 'aria-hidden': 'true' });
  if (src) el.append(h('img', { src, alt: '' }));
  else el.append(h('span', initial(name)));
  el.setImage = (url) => {
    clear(el);
    el.append(h('img', { src: url, alt: '' }));
  };
  return el;
}

export function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}
