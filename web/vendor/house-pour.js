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
 * title + performer, serif elapsed/total, hairline progress with a gold played
 * segment — or waveform bars for voice (ink bars, gold played).
 *
 * playerRow({ title, sub, duration, waveform, onToggle, onSeek }) → el with
 * el.setPlaying(bool) · el.setTime(elapsedText, totalText) · el.set(fraction)
 * · el.setBusy(bool).
 */
export function playerRow({ title, sub = '', duration = '0:00', waveform = null, onToggle = null, onSeek = null, label = 'Play' } = {}) {
  const btn = h('button.player-btn', { type: 'button', 'aria-label': label }, icon('play'));
  const elapsed = h('span.player-time', '0:00');
  const total = h('span.player-time.player-total', duration);
  let track;
  let bars = [];
  if (waveform && waveform.length) {
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
  return el;
}

// ── HPNowPlaying ───────────────────────────────────────────────────────────

/**
 * Slim now-playing row docked above the floating tab bar while audio plays:
 * play/pause, title, serif elapsed. nowPlaying({ title, onToggle }) → el with
 * el.setPlaying(bool) · el.setTime(text).
 */
export function nowPlaying({ title, onToggle = null } = {}) {
  const btn = h('button.player-btn.sm', { type: 'button', 'aria-label': `Pause ${title}` }, icon('pause'));
  const elapsed = h('span.player-time', '0:00');
  const el = h('div.now-playing', btn, h('div.now-playing-title', title), elapsed);
  if (onToggle) btn.addEventListener('click', onToggle);
  el.setPlaying = (playing) => {
    replace(btn, icon(playing ? 'pause' : 'play'));
    btn.setAttribute('aria-label', playing ? `Pause ${title}` : `Play ${title}`);
  };
  el.setTime = (t) => {
    elapsed.textContent = t;
  };
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
