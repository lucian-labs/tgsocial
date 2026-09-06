/* PRODUCT §2.3 Feed — the chronological main feed (PROTOCOL §4.8). */
import { h, button, replace, tabs } from '../../vendor/house-pour.js';
import { isPost, insertIndex, albumId, trimFeedWindow } from '../protocol.js';
import { releaseMedia } from '../media.js';
import { postCard, emptyCard } from './shared.js';
import { openNowSection } from './work.js';
import { editCard } from './you.js';

const PAGE = 20;
/** How long a live album message waits for its siblings before painting. */
const ALBUM_MS = 250;
/**
 * The most posts the feed keeps live at once — models and cards both.
 *
 * Twelve pages of twenty is far more scrollback than anyone reaches for
 * without pulling to refresh, and it is the term that stops an infinite scroll
 * from being an unbounded allocation: past this, loading a page drops one off
 * the head (protocol.js trimFeedWindow), and the pictures that went with it
 * are released with their cards.
 */
const FEED_WINDOW = 240;
/** What the cold-start cache holds; matches repo.js FEED_CACHE_MAX. */
const CACHE_HEAD = 40;

export function render(app, { cacheOnly = false } = {}) {
  const root = h('div');
  /**
   * PRODUCT §2.24 — a MODE on Feed, not a fifth tab. A tab would say there are
   * two networks; there is one, read two ways, which is the whole claim
   * PROTOCOL §10 exists to prove. The control is sticky under the topbar and
   * carries no shadow: the floating tab bar (§1) is the raised pill on this
   * screen and there is only one of those.
   */
  const modeHost = h('div.feed-mode');
  const toolbar = h('div.toolbar');
  /** Work mode's first block: expiring intent (§2.24). Empty in All mode. */
  const openHost = h('div');
  const list = h('div');
  const tail = h('div');
  root.append(modeHost, toolbar, openHost, list, tail);

  const refresh = button('Refresh', { style: 'ghost', size: 'sm', ariaLabel: 'Refresh feed' });
  toolbar.append(refresh);

  /** The mode is a UI preference (PROTOCOL §7), remembered between visits. */
  let mode = app.repo.prefs?.feedMode === 'work' ? 'work' : 'all';

  /**
   * Has a sources walk read my follows' cards this session? `hasWorkFeeds()`
   * answers from the card cache alone, so before the walk it cannot tell "my
   * network has no work in it" from "this client has not looked yet" — and a
   * cold cache is ordinary: first render on a new device, or a cache-version
   * bump that discarded `tgs.cards`.
   */
  let walked = false;

  /**
   * §2.24 — the control appears only when at least one node in my follows, or
   * I, carry a `work.feeds` entry. A reader whose network has no work in it
   * sees Feed exactly as it is today. It is visible in BOTH modes once it is
   * there, so the mode is never a state someone is stuck in.
   */
  function paintMode() {
    if (!app.repo.hasWorkFeeds?.()) {
      replace(modeHost);
      // a network that lost its last work feed must not leave the reader
      // looking at a column they can no longer get out of — but only once the
      // walk has actually established that it lost it. Resetting off a cold
      // cache destroys a preference §2.24 promises to remember (PROTOCOL §7)
      // and does it permanently, on a client that simply had not read yet.
      if (mode === 'work' && walked) {
        mode = 'all';
        app.repo.setPref('feedMode', 'all');
      }
      return;
    }
    if (modeHost.firstElementChild) return;
    replace(modeHost, tabs([{ id: 'all', label: 'All' }, { id: 'work', label: 'Work' }], mode, (id) => {
      if (id === mode) return;
      mode = id;
      app.repo.setPref('feedMode', id);
      start({ refreshCards: false });
    }));
  }

  let session = null;
  let posts = [];
  let loading = false;
  let done = false;
  let gen = 0;
  /**
   * The newest posts, kept separately from the live window: once the window
   * has trimmed its head, `posts[0]` is no longer the newest thing we have
   * seen, and the cold-start cache must not be rewritten with mid-history.
   */
  let cacheHead = [];

  const writeCache = () => {
    if (mode !== 'all') return;
    cacheHead = cacheHead.slice(0, CACHE_HEAD);
    app.repo.cacheFeed(cacheHead);
  };

  /**
   * Hold the window at FEED_WINDOW, dropping cards from the end the reader is
   * not at: the head after a load-more (the reader is at the bottom), the tail
   * after a live insert (the reader is at the top, and the post that just
   * arrived must not be the one that goes). The cards' media is released with
   * them, and a head trim scrolls back by exactly the height that went away so
   * the reader keeps their place.
   */
  const trim = (from = 'head') => {
    const { posts: kept, dropped } = trimFeedWindow(posts, app.feedWindow ?? FEED_WINDOW, { from });
    if (!dropped) return;
    if (from === 'tail') {
      for (let i = 0; i < dropped; i += 1) {
        const card = list.lastElementChild;
        if (!card) break;
        releaseMedia(card);
        card.remove();
      }
      posts = kept;
      return;
    }
    const anchor = list.children[dropped] ?? null;
    const before = anchor ? anchor.getBoundingClientRect().top : 0;
    for (let i = 0; i < dropped; i += 1) {
      const card = list.firstElementChild;
      if (!card) break;
      releaseMedia(card);
      card.remove();
    }
    posts = kept;
    if (anchor) window.scrollBy(0, anchor.getBoundingClientRect().top - before);
  };

  paintMode();
  // cold start: paint the cache first (PRODUCT §4). The cache is the main
  // feed's; work mode's column is a different merge and starts from nothing.
  const cached = mode === 'all' ? app.repo.cachedFeed() : [];
  if (cached.length && app.repo.myNode) {
    posts = cached;
    cacheHead = cached.slice(0, CACHE_HEAD);
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
      const sources = mode === 'work'
        ? await app.busy(app.repo.workSources({ refresh: refreshCards }))
        : await app.busy(app.repo.feedSources({ refresh: refreshCards }));
      if (mine !== gen) return;
      // the sources walk read my follows' cards, so this is the first render
      // that can honestly answer whether my network has any work in it
      walked = true;
      paintMode();
      if (mode === 'work') await paintOpenNow(mine, refreshCards);
      else replace(openHost);
      if (!sources.length) {
        posts = [];
        cacheHead = [];
        writeCache();
        replace(list, mode === 'work'
          ? emptyCard('No work posts yet.', 'Mark one of your feeds as work, or follow someone who has.', { label: 'Edit Card', onClick: () => editCard(app) })
          : emptyCard('Nothing here yet.', 'Follow a node and their feeds show up here, newest first.', { label: 'Explore', onClick: () => app.navigate('#/explore') }));
        replace(tail);
        done = true;
        return;
      }
      // §2.17/§2.18: this is the main feed, the one place a muted feed's posts
      // are dropped
      session = app.repo.feedSession(sources, { applyMute: true });
      const first = await app.busy(session.loadMore(PAGE));
      if (mine !== gen) return;
      posts = first;
      cacheHead = posts.slice(0, CACHE_HEAD);
      writeCache();
      app.feedStats = { sources: sources.length, posts: posts.length, at: Date.now() };
      if (!posts.length) {
        replace(list, mode === 'work'
          ? emptyCard('No work posts yet.', 'Mark one of your feeds as work, or follow someone who has.', { label: 'Edit Card', onClick: () => editCard(app) })
          : emptyCard('Nothing here yet.', 'Follow a node and their feeds show up here, newest first.', { label: 'Explore', onClick: () => app.navigate('#/explore') }));
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

  /**
   * §2.24 — OPEN NOW reads me, my follows AND my +1, because intent is one
   * structured line on a card the +1 walk already fetched. The work column
   * below stops at my follows: walking +1's feed history is a fetch per
   * channel, and a post one hop out is not worth it.
   */
  async function paintOpenNow(mine, refreshCards) {
    replace(openHost, h('div.loading-row.muted', 'Loading…'));
    try {
      const rows = await app.busy(app.repo.openNow({ refresh: refreshCards }));
      if (mine !== gen || mode !== 'work') return;
      replace(openHost, ...openNowSection(app, rows, { follows: app.repo.myCard?.follows?.length ?? 0 }));
    } catch (e) {
      if (mine !== gen || mode !== 'work') return;
      replace(openHost, ...openNowSection(app, [], { follows: app.repo.myCard?.follows?.length ?? 0 }));
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
      trim();
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
    // a wholesale repaint discards cards the same way a trim does, so it has to
    // release them the same way: replace() only clears the children, and a card
    // dropped without releaseMedia leaves its players, its picture bindings and
    // its audio player row behind, detached and still holding their blobs
    for (const card of [...list.children]) releaseMedia(card);
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
  // leaving the feed releases every player and picture binding it built;
  // without this a screen full of videos keeps its buffers after navigation
  app.onLeave(() => releaseMedia(root));

  refresh.addEventListener('click', () => start({ refreshCards: true }));
  app.onLeave(app.repo.subscribe((what) => {
    if (what === 'card') app.feedDirty = true;
  }));

  // live inserts: a new post in any source slots in at the top (PRODUCT §2.3);
  // album messages are buffered briefly so one album lands as one card (§2.11)
  const pendingAlbums = new Map(); // `${chat_id}:${album}` → { msgs, src, timer }
  const insertPost = (post) => {
    if (!root.isConnected || posts.some((p) => p.key === post.key)) return;
    // §2.18 is a render rule, so it holds for a post that arrives live too
    if (session && !session.keepPost(post)) return;
    const i = insertIndex(posts, post.date, post.id);
    posts.splice(i, 0, post);
    // an empty feed keeps its empty-state (or error) card inside `list`:
    // repaint instead of inserting above it, so the card list replaces it
    if (posts.length === 1) paint();
    else list.insertBefore(postCard(app, post), list.children[i] ?? null);
    cacheHead.splice(insertIndex(cacheHead, post.date, post.id), 0, post);
    writeCache();
    trim('tail');
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
