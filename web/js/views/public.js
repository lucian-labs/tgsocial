/* PRODUCT §2.13 — the public pages. A URL for every feed and every person,
 * readable with no account, no app, and no 14 MB wasm.
 *
 *   /u/<name>     a person: the merged, newest-first feed of every channel on
 *                 their card (PUBLIC §4 resolves <name> → node, directly or
 *                 through the feed's backlink)
 *   /f/<channel>  one channel's posts
 *   /n/<node>     a node's card — bio, feeds, follows
 *
 * What renders is §2.3's post card, unchanged: media playable inline, the
 * full-screen viewer, relative times, the long-press sheet — minus the things
 * that need an identity (no Comment, no comment counts, no Follow). The
 * floating tab bar is hidden and the topbar carries a neutral `Public` pill;
 * both of those live in app.js, which also docks the nag.
 *
 * The data comes from Telegram's own preview through our proxy
 * (js/public/source.js → js/public/preview.js) and the merge is the app's own
 * (js/public/feed.js extends the signed-in FeedSession). Nothing is stored:
 * the page is a lens, so a post deleted on Telegram is gone here on the next
 * fetch.
 */
import { h, kebabMenu, pill, replace, sectionMark } from '../../vendor/house-pour.js';
import { channelLink, publicFeedUrl, publicNodeUrl, publicPersonUrl, usernameKey } from '../protocol.js';
import { avatarFor, postCard, emptyCard, notFoundCard, feedRow, nodeRow, openExternal } from './shared.js';
import { releaseMedia } from '../media.js';
import { PublicFeedSession } from '../public/feed.js';
import { FOUND, UNLISTED, isUnlisted, resolveChannel, resolveNode, resolvePerson } from '../public/resolve.js';

const PAGE = 20;
/** How many rows on a node page fetch their own preview to fill in a title and a face. */
const ROW_LOOKUPS = 12;

/**
 * A node that asked not to be in directories is not served on a public page at
 * all (PUBLIC §4) — a public URL is a directory of one.
 */
function unlistedCard(node) {
  return emptyCard('Not listed.', `@${node} asked to stay out of directories.`);
}

function loading() {
  return h('div.card', h('p.muted', 'Loading…'));
}

/** PRODUCT §2.6 header kebab, on every public screen; `Copy Link` copies this page's URL. */
function publicMenu(app, { channel, url }) {
  return kebabMenu([
    { label: 'Open in Telegram', onSelect: () => openExternal(channelLink(channel)) },
    {
      label: 'Copy Link',
      onSelect: async () => {
        try {
          await navigator.clipboard.writeText(url);
          app.toast('Link copied.', 'good');
        } catch {
          app.toast("Couldn't copy the link.", 'bad');
        }
      },
    },
  ], { label: `More for @${channel}` });
}

/** The §2.6 header block: avatar, title, @username, description, Verified pill, kebab. */
function head(app, { title, username, photo, description, link, verified, copyUrl }) {
  return h('div.card.profile-head',
    h('div.head-actions',
      verified ? pill('Verified', 'gold') : null,
      publicMenu(app, { channel: username, url: copyUrl }),
    ),
    avatarFor(app, title, photo, 'profile'),
    h('h2', title),
    h('span.mono', `@${username}`),
    description ? h('p.muted', description) : null,
    link ? h('p', h('a', { href: safeUrl(link), target: '_blank', rel: 'noopener nofollow ugc' }, displayUrl(link))) : null,
  );
}

function safeUrl(u) {
  return /^https?:\/\//i.test(u) ? u : `https://${u}`;
}

function displayUrl(u) {
  return String(u).replace(/^https?:\/\//i, '').replace(/\/$/, '');
}

/**
 * The scrolling post list for a public session: §2.3 cards with `thread:false`
 * (no Comment, no comment counts), `Loading…` while a page is in flight,
 * `That's everything.` when every source is spent. Endless scroll is real —
 * each source pages with its own `?before=` (PUBLIC §4).
 */
function postList(app, session, { alive, empty }) {
  const list = h('div');
  const tail = h('div');
  let loadingNow = false;
  let done = false;

  const more = async () => {
    if (loadingNow || done || !alive()) return;
    loadingNow = true;
    replace(tail, h('div.loading-row.muted', 'Loading…'));
    try {
      const next = await session.loadMore(PAGE);
      if (!alive()) return;
      for (const p of next) list.append(postCard(app, p, { thread: false }));
      done = session.exhausted || next.length === 0;
      if (!list.childElementCount) replace(list, empty);
      replace(tail, done ? h('div.end-row.muted', "That's everything.") : h('div.loading-row.muted', 'Loading…'));
      if (!done) requestAnimationFrame(onScroll);
    } catch (e) {
      replace(tail, h('div.end-row.muted', `Couldn't load more. ${e.message}`));
    } finally {
      loadingNow = false;
    }
  };

  const onScroll = () => {
    if (done || loadingNow || !alive()) return;
    if (tail.getBoundingClientRect().top < window.innerHeight * 3) more();
  };
  window.addEventListener('scroll', onScroll, { passive: true });
  app.onLeave(() => window.removeEventListener('scroll', onScroll));
  more();
  return h('div', list, tail);
}

/** Screen scaffolding shared by the three routes: a root that survives async paints. */
function screen(app, build) {
  const root = h('div', loading());
  let alive = true;
  app.onLeave(() => {
    alive = false;
    // players and picture bindings go with the screen (js/media.js)
    releaseMedia(root);
  });
  build(root, () => alive).catch((e) => {
    console.warn('[public] render', e);
    if (alive) replace(root, emptyCard("Couldn't load this page.", e.message));
  });
  return root;
}

// ── /u/<name> — a person ───────────────────────────────────────────────────

export function renderPerson(app, { username }) {
  return screen(app, async (root, alive) => {
    const res = await resolvePerson(app.source, username);
    if (!alive()) return;
    if (res.kind === UNLISTED) return replace(root, unlistedCard(res.node));
    if (res.kind !== FOUND) return replace(root, notFoundCard(username));

    const { node, card, page } = res;
    const name = card.name || page.channel.title || `@${node}`;
    const photo = page.channel.photo;
    const header = head(app, {
      title: name,
      username: node,
      photo,
      description: card.bio || '',
      link: card.link,
      verified: false,
      // §2.13 Sharing: a person page copies /u/<name> — the handle the visitor
      // arrived by, which is the one people actually know
      copyUrl: publicPersonUrl(username),
    });
    replace(root, header);
    if (!card.feeds.length) {
      root.append(emptyCard('Nothing here yet.', 'This node lists no feeds.'));
      return;
    }
    // the merged, newest-first feed of every channel on the card, attributed to
    // the person (PRODUCT §2.3: the person leads, the channel follows)
    const session = new PublicFeedSession(app.source, card.feeds, {
      attribution: { username: node, name, photo },
    });
    root.append(postList(app, session, { alive, empty: emptyCard('Nothing here yet.', 'No posts in these feeds yet.') }));
  });
}

// ── /f/<channel> — one channel ─────────────────────────────────────────────

export function renderChannel(app, { username }) {
  return screen(app, async (root, alive) => {
    const res = await resolveChannel(app.source, username);
    if (!alive()) return;
    if (res.kind === UNLISTED) return replace(root, unlistedCard(res.node));
    if (res.kind !== FOUND) return replace(root, notFoundCard(username));

    const info = res.page.channel;
    replace(root, head(app, {
      title: info.title,
      username: info.username,
      photo: info.photo,
      description: info.description,
      link: null,
      verified: res.verified,
      copyUrl: publicFeedUrl(info.username),
    }));
    const session = new PublicFeedSession(app.source, [info.username]);
    root.append(postList(app, session, { alive, empty: emptyCard('Nothing here yet.', 'This channel has no posts.') }));
  });
}

// ── /n/<node> — the card ───────────────────────────────────────────────────

export function renderNode(app, { username }) {
  return screen(app, async (root, alive) => {
    const res = await resolveNode(app.source, username);
    if (!alive()) return;
    if (res.kind === UNLISTED) return replace(root, unlistedCard(res.node));
    if (res.kind !== FOUND) return replace(root, notFoundCard(username));

    const { node, card, page } = res;
    const name = card.name || page.channel.title || `@${node}`;
    const header = head(app, {
      title: name,
      username: node,
      photo: page.channel.photo,
      description: card.bio || '',
      link: card.link,
      verified: false,
      copyUrl: publicNodeUrl(node),
    });

    const feeds = h('div.card');
    if (!card.feeds.length) feeds.append(h('p.muted', 'No feeds listed.'));
    const follows = h('div.card');
    if (!card.follows.length) follows.append(h('p.muted', 'Follows no one yet.'));
    replace(root, header, sectionMark('Feeds'), feeds, sectionMark('Follows', card.follows.length), follows);

    // rows paint immediately with what the card says and fill in a title, a
    // face and the Verified pill as each channel's own preview comes back
    for (const f of card.feeds) {
      const row = feedRow(app, { title: `@${f}`, username: f, onClick: () => app.openChannel(f) });
      feeds.append(row);
    }
    for (const u of card.follows) {
      const row = nodeRow(app, { username: u, title: null, card: null, photo: null }, { showFollow: false });
      follows.append(row);
    }

    // A row for an unlisted node keeps the bare `@handle` the card it came from
    // already published, and nothing more. Filling one in would republish the
    // name, the face and the feed count of someone who asked to stay out of
    // directories — one hop from the `/n/` route that refuses them outright
    // (PUBLIC §4). Following needs no consent, so this fires on ordinary use.
    await lookups(card.feeds.slice(0, ROW_LOOKUPS), async (f, i) => {
      const parsed = await app.source.channel(f);
      if (!alive() || parsed.unavailable || isUnlisted(parsed.card)) return;
      const row = feeds.children[i];
      if (!row?.isConnected) return;
      row.replaceWith(feedRow(app, {
        title: parsed.channel.title,
        username: parsed.channel.username,
        verified: usernameKey(parsed.channel.verifiedFor ?? '') === usernameKey(node),
        onClick: () => app.openChannel(parsed.channel.username),
      }));
    });
    await lookups(card.follows.slice(0, ROW_LOOKUPS), async (u, i) => {
      const parsed = await app.source.channel(u);
      if (!alive() || parsed.unavailable || isUnlisted(parsed.card)) return;
      const row = follows.children[i];
      if (!row?.isConnected) return;
      row.replaceWith(nodeRow(app, {
        username: parsed.channel.username,
        title: parsed.channel.title,
        card: parsed.card,
        photo: parsed.channel.photo,
      }, { showFollow: false }));
    });
  });
}

/** Three at a time: a node with forty follows must not open forty connections. */
async function lookups(items, fn, limit = 3) {
  let i = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (i < items.length) {
      const idx = i;
      i += 1;
      try {
        await fn(items[idx], idx);
      } catch {
        // a row that will not resolve keeps the handle it was painted with
      }
    }
  });
  await Promise.all(workers);
}

export function render(app, route) {
  if (route.name === 'person') return renderPerson(app, route);
  if (route.name === 'node') return renderNode(app, route);
  return renderChannel(app, route);
}
