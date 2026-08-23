/* Shared composites: PostCard, NodeRow, FeedRow, EmptyCard, entity rendering.
 * Built only from House Pour classes; all Telegram text goes through
 * createTextNode (the `h` helper never sets innerHTML).
 */
import { h, button, pill, avatar, media, sectionMark } from '../../vendor/house-pour.js';
import { entityRuns, formatTime, compactCount, formatDuration, channelLink } from '../protocol.js';
import { pickPhotoSize, userMessage } from '../repo.js';

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

/** PRODUCT §2.3 post card. */
export function postCard(app, post) {
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
  if (post.text) parts.push(h('div.post-body', renderEntities(app, post.text, post.entities)));
  const media = mediaBlock(app, post.media);
  if (media) parts.push(media);

  const counts = [];
  if (post.views > 0) counts.push(`${compactCount(post.views)} views`);
  for (const r of post.reactions) counts.push(`${r.emoji} ${compactCount(r.count)}`);
  const open = button('Open in Telegram', {
    style: 'ghost',
    size: 'sm',
    onClick: (e) => {
      e.stopPropagation();
      openExternal(post.link);
    },
  });
  parts.push(h('div.post-foot', h('div.post-counts', counts.join(' · ')), open));

  const card = h('article.card.post', { tabindex: 0, role: 'link', 'aria-label': `Post by ${post.title}. Open in Telegram` }, parts);
  card.addEventListener('click', () => openExternal(post.link));
  card.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') openExternal(post.link);
  });
  return card;
}

/** Kit HPMedia with the post card's top gap. */
function mediaBox(src, aspect) {
  const box = media(src, aspect);
  box.classList.add('post-media');
  return box;
}

function mediaBlock(app, media) {
  if (!media) return null;
  const targetWidth = Math.round(Math.min(window.innerWidth, 540) * (window.devicePixelRatio || 1));
  if (media.kind === 'photo') {
    const size = pickPhotoSize(media.sizes, targetWidth);
    if (!size) return null;
    const box = mediaBox(null, `${size.w} / ${size.h}`);
    box.img.width = size.w;
    box.img.height = size.h;
    loadImage(app, box.img, size.file);
    return box;
  }
  if (media.kind === 'video' || media.kind === 'animation') {
    const tag = media.kind === 'video' ? formatDuration(media.duration) : 'GIF';
    const hasThumb = !!media.thumb?.file?.id;
    // no thumbnail: the bg2 placeholder at 4:3 carries the duration tag alone
    const box = mediaBox(null, hasThumb && media.w && media.h ? `${media.w} / ${media.h}` : '4 / 3');
    const tagPill = pill(tag);
    tagPill.classList.add('post-media-tag');
    box.append(tagPill);
    if (hasThumb) loadImage(app, box.img, media.thumb.file);
    return box;
  }
  if (media.kind === 'document') {
    return h('div.post-file', media.fileName);
  }
  if (media.kind === 'audio') {
    const label = [media.performer, media.title].filter(Boolean).join(' — ');
    return h('div.post-file', `${label} · ${formatDuration(media.duration)}`);
  }
  return null;
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
