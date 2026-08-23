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
 * media(src, aspect) — aspect is a CSS aspect-ratio value ('4 / 3'); src may be
 * null and set later with el.setImage(url). el.img is the <img>.
 */
export function media(src, aspect) {
  const img = h('img', { alt: '', loading: 'lazy' });
  if (src) img.src = src;
  const el = h('div.media', { style: aspect ? { aspectRatio: String(aspect) } : null }, img);
  el.img = img;
  el.setImage = (url) => {
    img.src = url;
  };
  return el;
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
