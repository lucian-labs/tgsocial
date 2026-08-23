/* PRODUCT §2.3 Feed — the chronological main feed (PROTOCOL §4.8). */
import { h, button, replace } from '../../vendor/house-pour.js';
import { isPost, insertIndex, albumId } from '../protocol.js';
import { postCard, emptyCard } from './shared.js';

const PAGE = 20;
/** How long a live album message waits for its siblings before painting. */
const ALBUM_MS = 250;

export function render(app, { cacheOnly = false } = {}) {
  const root = h('div');
  const toolbar = h('div.toolbar');
  const list = h('div');
  const tail = h('div');
  root.append(toolbar, list, tail);

  const refresh = button('Refresh', { style: 'ghost', size: 'sm', ariaLabel: 'Refresh feed' });
  toolbar.append(refresh);

  let session = null;
  let posts = [];
  let loading = false;
  let done = false;
  let gen = 0;

  // cold start: paint the cache first (PRODUCT §4)
  const cached = app.repo.cachedFeed();
  if (cached.length && app.repo.myNode) {
    posts = cached;
    paint();
  }
  if (cacheOnly) {
    // TDLib is still booting; the real render follows on authorizationStateReady
    replace(tail, h('div.loading-row.muted', 'Loading…'));
    refresh.disabled = true;
    return root;
  }

  async function start({ refreshCards = false } = {}) {
    const mine = ++gen;
    if (!app.repo.myNode) {
      replace(list, emptyCard('Nothing here yet.', 'Make your node and pick your feeds to start.', { label: 'Set Up', onClick: () => app.navigate('#/setup') }));
      replace(tail);
      return;
    }
    loading = true;
    done = false;
    replace(tail, h('div.loading-row.muted', 'Loading…'));
    try {
      const sources = await app.busy(app.repo.feedSources({ refresh: refreshCards }));
      if (mine !== gen) return;
      if (!sources.length) {
        posts = [];
        app.repo.cacheFeed([]);
        replace(list, emptyCard('Nothing here yet.', 'Follow a node and their feeds show up here, newest first.', { label: 'Explore', onClick: () => app.navigate('#/explore') }));
        replace(tail);
        done = true;
        return;
      }
      session = app.repo.feedSession(sources);
      const first = await app.busy(session.loadMore(PAGE));
      if (mine !== gen) return;
      posts = first;
      app.repo.cacheFeed(posts);
      app.feedStats = { sources: sources.length, posts: posts.length, at: Date.now() };
      if (!posts.length) {
        replace(list, emptyCard('Nothing here yet.', 'Follow a node and their feeds show up here, newest first.', { label: 'Explore', onClick: () => app.navigate('#/explore') }));
      } else paint();
      done = session.exhausted;
      paintTail();
      // the comment index refreshes alongside the feed (PROTOCOL §6.3); the
      // cards repaint their counts through the 'comments' notification
      app.repo.refreshComments({ force: refreshCards }).catch(() => null);
    } catch (e) {
      if (mine !== gen) return;
      if (!posts.length) replace(list, emptyCard('Nothing here yet.', `Couldn't load the feed. ${e.message}`));
      replace(tail);
    } finally {
      if (mine === gen) loading = false;
    }
  }

  async function more() {
    if (loading || done || !session) return;
    loading = true;
    const mine = gen;
    replace(tail, h('div.loading-row.muted', 'Loading…'));
    try {
      const next = await session.loadMore(PAGE);
      if (mine !== gen) return;
      for (const p of next) {
        posts.push(p);
        list.append(postCard(app, p));
      }
      if (app.feedStats) app.feedStats = { ...app.feedStats, posts: posts.length };
      done = session.exhausted || next.length === 0;
      paintTail();
    } catch (e) {
      if (mine === gen) replace(tail, h('div.end-row.muted', `Couldn't load more. ${e.message}`));
    } finally {
      if (mine === gen) loading = false;
    }
  }

  function paint() {
    replace(list, posts.map((p) => postCard(app, p)));
  }

  function paintTail() {
    if (done) replace(tail, h('div.end-row.muted', "That's everything."));
    else {
      replace(tail, h('div.loading-row.muted', 'Loading…'));
      requestAnimationFrame(onScroll);
    }
  }

  // infinite scroll: load more when the tail is within two screens of the bottom
  const onScroll = () => {
    if (done || loading || !session) return;
    const rect = tail.getBoundingClientRect();
    if (rect.top < window.innerHeight * 3) more();
  };
  window.addEventListener('scroll', onScroll, { passive: true });
  app.onLeave(() => window.removeEventListener('scroll', onScroll));

  refresh.addEventListener('click', () => start({ refreshCards: true }));
  app.onLeave(app.repo.subscribe((what) => {
    if (what === 'card') app.feedDirty = true;
  }));

  // live inserts: a new post in any source slots in at the top (PRODUCT §2.3);
  // album messages are buffered briefly so one album lands as one card (§2.11)
  const pendingAlbums = new Map(); // `${chat_id}:${album}` → { msgs, src, timer }
  const insertPost = (post) => {
    if (!root.isConnected || posts.some((p) => p.key === post.key)) return;
    const i = insertIndex(posts, post.date, post.id);
    posts.splice(i, 0, post);
    // an empty feed keeps its empty-state (or error) card inside `list`:
    // repaint instead of inserting above it, so the card list replaces it
    if (posts.length === 1) paint();
    else list.insertBefore(postCard(app, post), list.children[i] ?? null);
    app.repo.cacheFeed(posts);
    if (app.feedStats) app.feedStats = { ...app.feedStats, posts: posts.length };
  };
  app.onLeave(app.td.on('updateNewMessage', async (u) => {
    const msg = u?.message;
    if (!session || !msg || msg.sending_state) return;
    const src = session.sourceForChat(msg.chat_id);
    if (!src || !isPost(msg)) return;
    if (posts.some((p) => p.key === `${msg.chat_id}:${msg.id}`)) return;
    const album = albumId(msg);
    if (album) {
      // collect the album's siblings for a beat, then merge into one post
      const key = `${msg.chat_id}:${album}`;
      const entry = pendingAlbums.get(key) ?? { msgs: [], src };
      if (entry.timer) clearTimeout(entry.timer);
      entry.msgs.push(msg);
      entry.timer = setTimeout(async () => {
        pendingAlbums.delete(key);
        const siblings = entry.msgs.sort((a, b) => a.id - b.id);
        try {
          insertPost(await app.repo.toPost(siblings[0], entry.src, siblings.slice(1)));
        } catch (e) {
          console.warn('[feed] live insert', e.message);
        }
      }, ALBUM_MS);
      pendingAlbums.set(key, entry);
      return;
    }
    try {
      insertPost(await app.repo.toPost(msg, src));
    } catch (e) {
      console.warn('[feed] live insert', e.message);
    }
  }));
  app.onLeave(() => {
    for (const entry of pendingAlbums.values()) clearTimeout(entry.timer);
    pendingAlbums.clear();
  });

  // the Status sheet's Refresh Now re-runs this screen's refresh (PRODUCT §2.10)
  app.feedRefresh = () => start({ refreshCards: true });
  app.onLeave(() => {
    if (app.feedRefresh) app.feedRefresh = null;
  });

  start({ refreshCards: !!app.feedDirty });
  app.feedDirty = false;
  return root;
}
