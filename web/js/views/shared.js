/* Shared composites: PostCard, NodeRow, FeedRow, EmptyCard, entity rendering.
 * Built only from House Pour classes; all Telegram text goes through
 * createTextNode (the `h` helper never sets innerHTML).
 */
import { h, button, pill, avatar, sectionMark, modal } from '../../vendor/house-pour.js';
import { entityRuns, formatTime, formatExactTime, compactCount, serverMessageId } from '../protocol.js';
import { userMessage } from '../repo.js';
import { mediaBlocks } from '../media.js';

export function openExternal(url) {
  window.open(url, '_blank', 'noopener');
}

/** Render formattedText runs into a container: bold → <b>, italic → <i>, code → <code>, links → <a>. */
export function renderEntities(app, text, entities) {
  const frag = document.createDocumentFragment();
  for (const run of entityRuns(text, entities)) {
    let node = document.createTextNode(run.text);
    if (run.code) node = h('code', node);
    if (run.bold) node = h('b', node);
    if (run.italic) node = h('i', node);
    if (run.href) {
      node = h('a', { href: safeHref(run.href), target: '_blank', rel: 'noopener noreferrer', onclick: (e) => e.stopPropagation() }, node);
    } else if (run.mention) {
      node = h('a', {
        href: `#/node/${run.mention}`,
        onclick: (e) => {
          e.stopPropagation();
        },
      }, node);
    }
    frag.append(node);
  }
  return frag;
}

function safeHref(url) {
  const s = String(url ?? '');
  if (/^(https?:|tg:|mailto:)/i.test(s)) return s;
  if (/^[a-z0-9.-]+\.[a-z]{2,}/i.test(s)) return `https://${s}`;
  return 'about:blank';
}

/** Resolve a slim file ({ id, uniqueId }) to a blob URL, or null. */
export async function fileUrl(app, slim) {
  if (!slim?.id || !app.td?.client) return null;
  try {
    return await app.td.fileUrl({ id: slim.id, remote: { unique_id: slim.uniqueId }, local: { is_downloading_completed: false } });
  } catch (e) {
    return null;
  }
}

/** Set an <img> src once the file is available; the placeholder stays otherwise. */
export function loadImage(app, img, slim) {
  fileUrl(app, slim).then((url) => {
    if (url) img.src = url;
  });
}

export function avatarFor(app, name, slim, size = 'row') {
  const el = avatar(name, null, size);
  if (slim?.id) {
    fileUrl(app, slim).then((url) => {
      if (url) el.setImage(url);
    });
  }
  return el;
}

/** Open the Thread screen for a post (PRODUCT §2.12). `compose` opens the composer at once. */
export function openThread(app, post, { compose = false } = {}) {
  app.threadSeed = post;
  app.navigate(`#/thread/${post.username}/${serverMessageId(post.id)}${compose ? '?compose=1' : ''}`);
}

/** PRODUCT §2.3 — Share: navigator.share when available, else copy the link + toast. */
async function sharePost(app, post) {
  if (typeof navigator !== 'undefined' && navigator.share) {
    try {
      await navigator.share({ url: post.link });
    } catch {
      // the user closed the share sheet — not an error
    }
    return;
  }
  try {
    await navigator.clipboard.writeText(post.link);
    app.toast('Link copied.', 'good');
  } catch {
    app.toast("Couldn't copy the link.", 'bad');
  }
}

/** PRODUCT §2.3 — the post sheet: Posted / Views / Feed rows, Open in Telegram, Close. */
export function openPostSheet(app, post) {
  const row = (label, value) => h('div.list-item.sheet-row', h('span.sheet-label', label), h('span.sheet-value', value));
  let m = null;
  const open = button('Open in Telegram', { onClick: () => openExternal(post.link) });
  const close = button('Close', { style: 'ghost', onClick: () => m.close() });
  m = modal([
    sectionMark('Post'),
    h('div.sheet-rows',
      row('Posted', formatExactTime(new Date(post.date * 1000))),
      row('Views', compactCount(post.views)),
      row('Feed', `${post.title || `@${post.username}`} · @${post.username}`),
    ),
    open,
    close,
  ], { label: 'Post' });
  return m;
}

/**
 * Long-press (pointerdown, 500 ms, cancelled by pointerup/cancel, or by
 * moving beyond a small slop radius) or right-click opens the post sheet.
 * The slop matters on touch hardware: WebKit dispatches pointermove for
 * finger micro-jitter (Chrome suppresses sub-slop movement, Safari does
 * not), and iOS never fires contextmenu for touch — with zero tolerance
 * the sheet would be unreachable there. A deliberate drag (text selection,
 * scroll) still travels past the slop and cancels; when the browser takes
 * the pan it fires pointercancel, which cancels unconditionally.
 * Suppressed on buttons, links, media and players so they keep their own
 * gestures; never preventDefaults the press itself, so text selection
 * still works for short presses.
 */
const SHEET_SUPPRESS = 'button, a, input, textarea, .media, .post-media, .player, .waveform, .scrubber, video, audio';
const LONG_PRESS_MS = 500;
const LONG_PRESS_SLOP_PX = 10;

function attachPostSheet(app, el, post) {
  let timer = null;
  let fired = false;
  let startX = 0;
  let startY = 0;
  const cancel = () => {
    if (timer) clearTimeout(timer);
    timer = null;
  };
  el.addEventListener('pointerdown', (e) => {
    // reset on every press: a release outside the card (e.g. over the sheet)
    // never fires the card's click, so the flag must not linger
    fired = false;
    if (e.button !== 0 || e.target.closest(SHEET_SUPPRESS)) return;
    cancel();
    startX = e.clientX;
    startY = e.clientY;
    timer = setTimeout(() => {
      timer = null;
      fired = true;
      openPostSheet(app, post);
    }, LONG_PRESS_MS);
  });
  el.addEventListener('pointermove', (e) => {
    if (!timer) return;
    if (Math.hypot(e.clientX - startX, e.clientY - startY) > LONG_PRESS_SLOP_PX) cancel();
  });
  el.addEventListener('pointerup', cancel);
  el.addEventListener('pointercancel', cancel);
  // the click that follows a fired long-press must not open the thread
  el.addEventListener('click', (e) => {
    if (!fired) return;
    fired = false;
    e.preventDefault();
    e.stopPropagation();
  }, true);
  el.addEventListener('contextmenu', (e) => {
    if (e.target.closest(SHEET_SUPPRESS)) return;
    e.preventDefault();
    cancel();
    openPostSheet(app, post);
  });
}

/** PRODUCT §2.3 post card. `thread: false` renders it at the top of its own Thread screen. */
export function postCard(app, post, { thread = true } = {}) {
  // attribution (§2.3): the node the post reaches me through leads; the
  // channel is the subheading. Unattributed → the channel itself, no subheading.
  const attributed = !!post.node;
  const name = attributed ? post.nodeName || `@${post.node}` : post.title || `@${post.username}`;
  const title = h('button.post-title', {
    type: 'button',
    'aria-label': attributed ? `Open ${name}` : `Open ${post.title} feed`,
    onclick: (e) => {
      e.stopPropagation();
      app.navigate(attributed ? `#/node/${post.node}` : `#/feed/${post.username}`);
    },
  }, name);
  const sub = attributed
    ? h('button.post-sub', {
      type: 'button',
      'aria-label': `Open ${post.title || post.username} feed`,
      onclick: (e) => {
        e.stopPropagation();
        app.navigate(`#/feed/${post.username}`);
      },
    }, post.title || `@${post.username}`)
    : null;

  const head = h('div.post-head',
    avatarFor(app, name, attributed ? post.nodeAvatar : post.avatar, 'row'),
    h('div.post-head-text', title, sub),
    h('div.post-head-trail',
      h('div.post-time', formatTime(new Date(post.date * 1000))),
      button('Share', { style: 'ghost', size: 'sm', ariaLabel: 'Share this post', onClick: () => sharePost(app, post) }),
    ),
  );

  const parts = [head];
  if (post.forwardedFrom) parts.push(h('div.post-fwd', `Forwarded from ${post.forwardedFrom}`));
  if (post.text) {
    const body = h('div.post-body', renderEntities(app, post.text, post.entities));
    if (thread) {
      // tapping the text opens the Thread screen (PRODUCT §2.3)
      body.classList.add('opens-thread');
      body.addEventListener('click', () => openThread(app, post));
    }
    parts.push(body);
  }
  // media renders and plays in the app (PRODUCT §2.11); taps there never leave it
  parts.push(...mediaBlocks(app, normalisePostMedia(post), { openExternal }));

  // footer (§2.3): N reactions · N comments, Comment ghost sm — no views, no
  // Open in Telegram on the card face (both live in the post sheet now)
  const reactions = post.reactions ?? [];
  const reactionTotal = reactions.reduce((sum, r) => sum + r.count, 0);
  const reactionText = reactions.length >= 1 && reactions.length <= 3
    ? reactions.map((r) => `${r.emoji} ${compactCount(r.count)}`).join(' ')
    : `${compactCount(reactionTotal)} ${reactionTotal === 1 ? 'reaction' : 'reactions'}`;
  const countsEl = h('div.post-counts', reactionText);
  if (thread) {
    // "N comments" — from your network (PROTOCOL §6.3); tappable → Thread
    const n = app.repo?.commentCount(post.link) ?? 0;
    const commentsBtn = h('button.post-comments-count', { type: 'button', 'aria-label': 'Open thread' },
      ` · ${compactCount(n)} ${n === 1 ? 'comment' : 'comments'}`);
    commentsBtn.addEventListener('click', () => openThread(app, post));
    countsEl.append(commentsBtn);
    if (app.repo) {
      // self-unsubscribe once the card leaves the DOM: in-screen repaints
      // (Refresh) replace cards without a route change, so waiting for the
      // route's leaveFns would let dead subscriptions pile up
      const unsub = app.repo.subscribe((what) => {
        if (what !== 'comments') return;
        if (!commentsBtn.isConnected) return unsub();
        const c = app.repo.commentCount(post.link);
        commentsBtn.textContent = ` · ${compactCount(c)} ${c === 1 ? 'comment' : 'comments'}`;
      });
      app.onLeave(unsub);
    }
  }
  const foot = h('div.post-foot', countsEl);
  if (thread) foot.append(button('Comment', { style: 'ghost', size: 'sm', onClick: () => openThread(app, post, { compose: true }) }));
  parts.push(foot);

  const card = h('article.card.post', { 'aria-label': `Post by ${name}` }, parts);
  // long-press / right-click → the post sheet (§2.3)
  attachPostSheet(app, card, post);
  return card;
}

/** Older cached feed models predate post.album/post.preview; normalise in place. */
function normalisePostMedia(post) {
  if (!Array.isArray(post.album)) post.album = post.media ? [post.media] : [];
  if (post.preview === undefined) post.preview = null;
  return post;
}

/** COMPONENTS NodeRow. entry: card cache entry; opts: { via, following, onFollow, showFollow } */
export function nodeRow(app, entry, { mutual = null, showFollow = true } = {}) {
  const username = entry.username;
  const name = entry.card?.name || entry.title || `@${username}`;
  const feeds = entry.card?.feeds?.length ?? 0;
  const sub = `@${username} · ${feeds} ${feeds === 1 ? 'feed' : 'feeds'}`;
  const text = h('div.row-text', h('div.row-name', name), h('div.row-sub', sub));
  if (mutual !== null) text.append(h('div.row-via', `Followed by ${mutual} of yours`));
  const trail = h('div.row-trail');
  if (showFollow && app.repo.myNode && username.toLowerCase() !== app.repo.myNode.username.toLowerCase()) {
    trail.append(followButton(app, username));
  } else {
    trail.append(h('span.chevron', { 'aria-hidden': 'true' }, '›'));
  }
  const row = h('div.list-item.node-row', { role: 'link', tabindex: 0, 'aria-label': `Open ${name}` },
    h('div.row-main', avatarFor(app, name, entry.photo, 'row'), text),
    trail,
  );
  const go = () => app.navigate(`#/node/${username}`);
  row.addEventListener('click', go);
  row.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target === row) go();
  });
  return row;
}

/** `Follow` (.btn.sm neutral) ↔ `Following` (ghost). Optimistic via repo. */
export function followButton(app, username, { size = 'sm' } = {}) {
  const isFollowing = () => app.repo.myCard?.follows?.some((u) => u.toLowerCase() === username.toLowerCase()) ?? false;
  const btn = button('Follow', { size, ariaLabel: `Follow @${username}` });
  const paint = () => {
    const f = isFollowing();
    btn.textContent = f ? 'Following' : 'Follow';
    btn.classList.toggle('ghost', f);
    btn.setAttribute('aria-label', f ? `Unfollow @${username}` : `Follow @${username}`);
  };
  paint();
  btn.addEventListener('click', async (e) => {
    e.stopPropagation();
    const was = isFollowing();
    btn.textContent = was ? 'Follow' : 'Following';
    btn.classList.toggle('ghost', !was);
    btn.disabled = true;
    try {
      if (was) await app.repo.unfollow(username);
      else await app.repo.follow(username);
    } catch (err) {
      app.toast(userMessage(err, "Couldn't update your card."), 'bad');
    } finally {
      btn.disabled = false;
      paint();
    }
  });
  app.onLeave(app.repo.subscribe((what) => {
    if (what === 'card' && btn.isConnected) paint();
  }));
  return btn;
}

/** COMPONENTS FeedRow: title, @username, optional Verified pill, chevron. */
export function feedRow(app, { title, username, verified = false, onClick }) {
  const sub = h('div.row-sub', `@${username}`);
  if (verified) sub.append(pill('Verified', 'gold'));
  const row = h('div.list-item.feed-row', { role: 'link', tabindex: 0, 'aria-label': `Open ${title || username}` },
    h('div.row-main', h('div.row-text', h('div.row-name', title || `@${username}`), sub)),
    h('div.row-trail', h('span.chevron', { 'aria-hidden': 'true' }, '›')),
  );
  const go = onClick || (() => app.navigate(`#/feed/${username}`));
  row.addEventListener('click', go);
  row.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') go();
  });
  return row;
}

/** COMPONENTS EmptyCard: h2 + muted + at most one accent button. */
export function emptyCard(title, body, action) {
  const parts = [h('h2', title), h('p.muted', body)];
  if (action) parts.push(button(action.label, { style: 'accent', onClick: action.onClick }));
  return h('div.card.empty', parts);
}

export function section(title, count) {
  return sectionMark(title, count);
}
