/* Shared composites: PostCard, NodeRow, FeedRow, EmptyCard, entity rendering.
 * Built only from House Pour classes; all Telegram text goes through
 * createTextNode (the `h` helper never sets innerHTML).
 */
import { h, button, pill, avatar, sectionMark } from '../../vendor/house-pour.js';
import { entityRuns, formatTime, compactCount, channelLink, serverMessageId } from '../protocol.js';
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

/** PRODUCT §2.3 post card. `thread: false` renders it at the top of its own Thread screen. */
export function postCard(app, post, { thread = true } = {}) {
  const title = h('button.post-title', {
    type: 'button',
    'aria-label': `Open ${post.title} feed`,
    onclick: (e) => {
      e.stopPropagation();
      app.navigate(`#/feed/${post.username}`);
    },
  }, post.title || `@${post.username}`);

  const head = h('div.post-head',
    avatarFor(app, post.title, post.avatar, 'row'),
    h('div.post-head-text', title, h('div.post-user', `@${post.username}`)),
    h('div.post-time', formatTime(new Date(post.date * 1000))),
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

  const counts = [];
  if (post.views > 0) counts.push(`${compactCount(post.views)} views`);
  for (const r of post.reactions) counts.push(`${r.emoji} ${compactCount(r.count)}`);
  const countsEl = h('div.post-counts', counts.join(' · '));
  if (thread) {
    // "N comments" — from your network (PROTOCOL §6.3); tappable → Thread
    const n = app.repo?.commentCount(post.link) ?? 0;
    const commentsBtn = h('button.post-comments-count', { type: 'button', 'aria-label': 'Open thread' },
      `${counts.length ? ' · ' : ''}${compactCount(n)} ${n === 1 ? 'comment' : 'comments'}`);
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
        commentsBtn.textContent = `${counts.length ? ' · ' : ''}${compactCount(c)} ${c === 1 ? 'comment' : 'comments'}`;
      });
      app.onLeave(unsub);
    }
  }
  parts.push(h('div.post-foot', countsEl));

  const open = button('Open in Telegram', { style: 'ghost', size: 'sm', onClick: () => openExternal(post.link) });
  const actions = h('div.btn-row.post-actions');
  if (thread) actions.append(button('Comment', { style: 'ghost', size: 'sm', onClick: () => openThread(app, post, { compose: true }) }));
  actions.append(open);
  parts.push(actions);

  return h('article.card.post', { 'aria-label': `Post by ${post.title}` }, parts);
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

export function openInTelegramButton(username) {
  return button('Open in Telegram', { style: 'ghost', size: 'sm', onClick: () => openExternal(channelLink(username)) });
}

export function section(title, count) {
  return sectionMark(title, count);
}
