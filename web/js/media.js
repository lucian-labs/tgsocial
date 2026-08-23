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
 */
import { h, replace, button, media, pill, icon, ring, scrubber, playerRow, nowPlaying, viewer } from '../vendor/house-pour.js';
import { formatDuration } from './protocol.js';
import { pickPhotoSize } from './repo.js';

// ── file plumbing ──────────────────────────────────────────────────────────

/** Rehydrate a slim file ({ id, uniqueId, done, size }) into a TDLib File shell. */
function fullFile(slim) {
  return { id: slim.id, size: slim.size ?? 0, remote: { unique_id: slim.uniqueId }, local: { is_downloading_completed: !!slim.done } };
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
    }, { rootMargin: '100% 0px' });
  }
  pendingVisible.set(el, fn);
  visObserver.observe(el);
}

/**
 * Visibility-driven download with the gold ring over the placeholder.
 * Starts at priority 1 when `container` scrolls near the viewport (or at 32
 * at once with { eager }); the ring cancels on tap; a cancelled or failed
 * download leaves a resume affordance. onUrl(url) fires with the blob URL.
 * Returns { start(priority) } so a tap can begin/bump the download.
 */
export function autoLoad(app, container, slim, { kind, mime = null, onUrl, auto = true, showRing = true }) {
  if (!slim?.id) return { start: () => {} };
  const file = fullFile(slim);
  const cached = app.td.cachedUrl(file);
  if (cached) {
    onUrl(cached);
    return { start: () => {} };
  }
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
    app.td
      .fileUrlOrThrow(file, { priority, label: labelFor(kind), mime, onProgress: (f) => ringEl?.set(f) })
      .then((url) => {
        state = 'done';
        clearChrome();
        onUrl(url);
      })
      .catch(() => {
        state = 'idle';
        showResume();
      });
  };
  if (auto) whenVisible(container, () => start(1));
  return { start };
}

/** Resolve a slim file to a blob URL at tap priority; rejects on cancel/failure. */
function urlFor(app, slim, kind, mime = null) {
  return app.td.fileUrlOrThrow(fullFile(slim), { priority: 32, label: labelFor(kind), mime });
}

// ── exclusive playback ─────────────────────────────────────────────────────

/** All live media elements; starting one pauses every other (PRODUCT §2.11). */
const liveMedia = new Set();

function exclusive(el) {
  liveMedia.add(el);
  el.addEventListener('play', () => {
    for (const other of [...liveMedia]) {
      // in-DOM videos that were re-rendered away are pruned; detached Audio objects persist
      if (other.tagName === 'VIDEO' && !other.isConnected) liveMedia.delete(other);
      else if (other !== el && !other.paused) other.pause();
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
};

function audioRowsFor(key) {
  const out = [];
  for (const ref of [...detachedAudio.rows]) {
    if (!ref.row.isConnected) detachedAudio.rows.delete(ref);
    else if (ref.key === key) out.push(ref.row);
  }
  return out;
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
    dockNowPlaying(app, null);
  } else if (a.np) {
    a.np.setPlaying(playing);
    a.np.setTime(elapsed);
  } else {
    dockNowPlaying(app, nowPlaying({ title: a.meta.title, onToggle: () => toggleAudio(app, a.meta) }));
    a.np.setPlaying(playing);
  }
}

function dockNowPlaying(app, el) {
  if (detachedAudio.np) detachedAudio.np.remove();
  detachedAudio.np = el;
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
    a.el.pause();
    liveMedia.delete(a.el);
    a.el = null;
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

function targetWidth() {
  return Math.round(Math.min(window.innerWidth, 540) * (window.devicePixelRatio || 1));
}

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
  const load = autoLoad(app, box, size.file, { kind: 'photo', onUrl: (url) => box.setImage(url) });
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

/** Poster + play glyph + duration pill → inline video with House Pour transport. */
function videoBlock(app, post, item, index) {
  const aspect = item.w && item.h ? `${item.w} / ${item.h}` : '4 / 3';
  const box = mediaBox(aspect, item.mini);
  if (item.thumb?.file?.id) autoLoad(app, box, item.thumb.file, { kind: 'photo', showRing: false, onUrl: (url) => box.setImage(url) });
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
  if (item.thumb?.file?.id) autoLoad(app, box, item.thumb.file, { kind: 'photo', showRing: false, onUrl: (url) => box.setImage(url) });
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
    title: kind === 'voice' ? 'Voice message' : item.title,
    sub: item.performer || '',
    duration: item.duration,
    file: item.file,
    mime: item.mime,
    waveform: item.waveform ?? null,
  };
}

function audioBlock(app, post, item, kind) {
  const meta = audioMeta(post, item, kind);
  const row = playerRow({
    title: meta.title,
    sub: meta.sub,
    duration: formatDuration(meta.duration),
    waveform: kind === 'voice' ? decodeWaveform(meta.waveform) : null,
    onToggle: () => toggleAudio(app, meta),
    onSeek: (f) => seekAudio(app, meta, f),
    label: `Play ${meta.title}`,
  });
  detachedAudio.rows.add({ row, key: meta.key });
  const wrap = h('div.post-player', row);
  wrap.addEventListener('click', stop);
  // rebind state when the feed re-renders mid-playback
  if (detachedAudio.key === meta.key) paintAudio(app);
  return wrap;
}

/** Circular inline player for video notes. */
function videoNoteBlock(app, post, item) {
  const box = mediaBox('1 / 1', item.mini);
  box.classList.add('video-note');
  if (item.thumb?.file?.id) autoLoad(app, box, item.thumb.file, { kind: 'photo', showRing: false, onUrl: (url) => box.setImage(url) });
  const play = h('button.media-play', { type: 'button', 'aria-label': 'Play video note' }, h('span.disc', icon('play')));
  box.append(play);
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
    pauseOffscreen(video);
    video.addEventListener('click', (ev) => {
      stop(ev);
      if (video.paused) video.play().catch(() => null);
      else video.pause();
    });
    video.play().catch(() => null);
  });
  return box;
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
  const meta = [item.file?.size ? formatSize(item.file.size) : null, item.mime || null].filter(Boolean).join(' · ');
  const action = button(viewable ? 'Open' : 'Download', { size: 'sm', ariaLabel: `${viewable ? 'Open' : 'Download'} ${item.fileName}` });
  const row = h('div.post-file',
    icon('file'),
    h('div.post-file-text', h('div.post-file-name', item.fileName), meta ? h('div.post-file-meta', meta) : null),
    action,
  );
  row.addEventListener('click', stop);
  action.addEventListener('click', async (e) => {
    stop(e);
    if (viewable) {
      openViewer(app, post, null, { doc: item });
      return;
    }
    // not viewable: fetch with the ring in the row, then hand the file over
    const prog = ring({ onCancel: () => app.td.cancel(item.file.id) });
    action.replaceWith(prog);
    try {
      const url = await app.td.fileUrlOrThrow(fullFile(item.file), { priority: 32, label: labelFor('document'), mime: item.mime, onProgress: (f) => prog.set(f) });
      triggerDownload(url, item.fileName);
    } catch (err) {
      if (!err?.cancelled) app.toast("Couldn't download this file.", 'bad');
    } finally {
      prog.replaceWith(action);
    }
  });
  return row;
}

export function triggerDownload(url, name) {
  const a = h('a', { href: url, download: name || 'file' });
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
  if (file?.id) autoLoad(app, box, file, { kind: 'sticker', showRing: false, onUrl: (url) => box.setImage(url) });
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
      autoLoad(app, thumbBox, size.file, { kind: 'photo', showRing: false, onUrl: (url) => thumbBox.setImage(url) });
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
  album.forEach((item, i) => {
    let el = null;
    if (item.kind === 'photo') el = photoBlock(app, post, item, i);
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
      for (const s of slides.values()) {
        const video = s.querySelector('video');
        if (video) video.pause();
      }
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
  const downloadBtn = button('Download', { style: 'ghost', size: 'sm', ariaLabel: 'Download' });
  v.actions.append(downloadBtn);
  downloadBtn.addEventListener('click', async () => {
    const item = items[idx];
    const slim = item.kind === 'photo' ? pickPhotoSize(item.sizes, 4096)?.file : item.file;
    if (!slim?.id) return;
    downloadBtn.disabled = true;
    try {
      const url = await app.td.fileUrlOrThrow(fullFile(slim), { priority: 32, label: labelFor(item.kind), mime: item.mime ?? null });
      triggerDownload(url, item.fileName || `${item.kind}-${slim.id}`);
    } catch (e) {
      if (!e?.cancelled) app.toast("Couldn't download this file.", 'bad');
    } finally {
      downloadBtn.disabled = false;
    }
  });
  if (post?.text && !doc) v.caption.textContent = post.text;

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
    else if (item.kind === 'photo') buildPhotoSlide(app, slide, item);
    else buildVideoSlide(app, slide, item, item.kind === 'animation', i === idx ? resumeAt : 0);
    return slide;
  }

  function show(i, { autoplayVideo = false } = {}) {
    idx = i;
    const current = slides.get(i);
    for (const [k, s] of slides) {
      if (k !== i) {
        s.remove();
        const video = s.querySelector('video');
        if (video && !video.muted) video.pause();
      }
    }
    const slide = buildSlide(i);
    if (!slide.isConnected) v.stage.append(slide);
    v.counter.textContent = items.length > 1 ? `${i + 1} / ${items.length}` : '';
    if (autoplayVideo) slide.querySelector('video')?.play().catch(() => null);
    // warm the neighbours
    if (i + 1 < items.length) buildSlide(i + 1);
    if (i > 0) buildSlide(i - 1);
  }

  wireGestures(v, {
    count: () => items.length,
    index: () => idx,
    goTo: (i) => show(i, { autoplayVideo: false }),
    close: () => v.close(),
    zoomable: () => !doc && items[idx].kind === 'photo',
    slideOf: () => slides.get(idx),
  });

  document.getElementById('viewer-root').append(v.root);
  show(idx, { autoplayVideo: false });
}

function buildPhotoSlide(app, slide, item) {
  const size = pickPhotoSize(item.sizes, Math.round(window.innerWidth * (window.devicePixelRatio || 1)));
  const img = h('img', { alt: '' });
  if (item.mini) {
    img.src = item.mini;
    img.style.filter = 'blur(var(--media-blur))';
  }
  const wrap = h('div.viewer-zoom', img);
  slide.append(wrap);
  if (!size?.file?.id) return;
  const prog = ring({ onCancel: () => app.td.cancel(size.file.id) });
  slide.append(prog);
  app.td
    .fileUrlOrThrow(fullFile(size.file), { priority: 32, label: labelFor('photo'), onProgress: (f) => prog.set(f) })
    .then((url) => {
      prog.remove();
      img.src = url;
      img.style.filter = '';
    })
    .catch(() => prog.remove());
}

function buildVideoSlide(app, slide, item, loop, resumeAt = 0) {
  const prog = ring({ onCancel: () => app.td.cancel(item.file.id) });
  slide.append(prog);
  app.td
    .fileUrlOrThrow(fullFile(item.file), { priority: 32, label: labelFor(item.kind), mime: item.mime ?? null, onProgress: (f) => prog.set(f) })
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
  const prog = ring({ onCancel: () => app.td.cancel(item.file.id) });
  slide.append(prog);
  app.td
    .fileUrlOrThrow(fullFile(item.file), { priority: 32, label: labelFor('document'), mime: item.mime ?? null, onProgress: (f) => prog.set(f) })
    .then(async (url) => {
      prog.remove();
      if (kind === 'image') slide.append(h('div.viewer-zoom', h('img', { src: url, alt: item.fileName })));
      else if (kind === 'pdf') slide.append(h('iframe.viewer-doc', { src: url, title: item.fileName }));
      else if (kind === 'text') {
        const blob = await app.td.fileBlob(fullFile(item.file), { mime: item.mime });
        const text = blob ? await blob.text() : '';
        slide.append(h('div.viewer-textdoc', text.slice(0, 200000)));
      } else if (kind === 'audio') {
        const row = playerRow({ title: item.fileName, duration: '0:00', label: `Play ${item.fileName}` });
        const audio = new Audio(url);
        exclusive(audio);
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

  document.addEventListener('keydown', function onKey(e) {
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
  });
}

/** True while the full-screen viewer is open (the app hides its chrome then). */
export function viewerOpen() {
  return !!activeViewer;
}

/** Close the viewer if a route change happens under it. */
export function closeViewer() {
  if (activeViewer) activeViewer.close();
}
