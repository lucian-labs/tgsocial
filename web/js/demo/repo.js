/* demo/repo.js — the object the app reaches its data through while the demo is
 * open (PRODUCT §2.22.4).
 *
 * "The demo is a different object, not a mode." Every screen already talks to
 * `Repo`; this is the whole implementation substituted, holding the fixture
 * world of js/demo/world.js and no reference to the TDLib client. A boolean
 * checked at each call site has branches that can be missed; a substituted
 * object has no code path to Telegram to miss in the first place — and nothing
 * in this directory imports js/td.js, which test/protocol.test.mjs asserts as
 * a build-time grep.
 *
 * Two deliberate re-uses of the real code, because §2.22.2 says the demo runs
 * the real code paths:
 *   - the comment index, tree and count are `Repo`'s own methods, borrowed,
 *     so §2.12's depth-5 flattening and the footer's `5 comments` are produced
 *     by the code a real session runs (PROTOCOL §6.3);
 *   - the feed is `FeedSession`, with only its four reader seams overridden —
 *     the same k-way merge as PROTOCOL §4.8 and the same §2.18 filter, exactly
 *     as the public reader does it (js/public/feed.js).
 *
 * Every write is refused with the one string §2.22.3 gives it. The refusal is
 * a `plain` error, which is what makes the toast read `The demo doesn't write
 * to Telegram.` at every call site instead of `Couldn't update your card. …`
 * (js/repo.js `userMessage`).
 */
import { FeedSession, Repo } from '../repo.js';
import { rankPlusOne, usernameKey } from '../protocol.js';
import { WRITE_REFUSED } from './mode.js';
import { MAIN_SOURCES, READER, buildWorld, primeClips } from './world.js';
import { releaseGenerated } from './media.js';

/** The demo pages eight posts at a time, so §2.3's pagination and `That's everything.` both run. */
const PAGE = 8;

function refuse(message = WRITE_REFUSED) {
  const e = new Error(message);
  e.plain = true;
  return Promise.reject(e);
}

/**
 * One merged demo feed. `resolve` / `page` / `keep` / `postOf` are the only
 * four things a different reader has to supply (js/repo.js), so ordering,
 * refill choice, exhaustion, the load-more loop and §2.18's "pagination
 * compensates" are the signed-in feed's, unmodified.
 */
class DemoFeedSession extends FeedSession {
  constructor(repo, usernames, { applyMute = false } = {}) {
    super(repo, usernames, { safety: repo.safety, applyMute });
  }

  async resolve(username) {
    const key = usernameKey(username);
    if (this.sources.has(key)) return this.sources.get(key);
    const feed = this.repo.world.feeds.get(key) ?? null;
    const src = feed ? { key, username: feed.username, chatId: feed.chatId, title: feed.title, photo: feed.photo } : null;
    this.sources.set(key, src);
    return src;
  }

  /** One page of this channel, newest first, older than `from`. */
  async page(src, from) {
    const all = this.repo.postsOf(src.username);
    const start = from ? all.findIndex((p) => p.id === from) + 1 : 0;
    const slice = all.slice(start, start + PAGE);
    return {
      items: slice.map((post) => ({ id: post.id, date: post.date, post })),
      cursor: slice.length ? slice[slice.length - 1].id : from,
      done: start + slice.length >= all.length,
    };
  }

  /**
   * §2.22.1 — the demo hands over eight posts at a time whatever the screen
   * asks for, so Feed loads a second page and then says `That's everything.`:
   * pagination is exercised, and so is §2.18's rule that a fully-filtered page
   * fetches the next one.
   */
  loadMore(count = 20) {
    return super.loadMore(Math.min(count, PAGE));
  }

  /** Everything in a demo channel is a post; there is no card message to skip. */
  keep() {
    return true;
  }

  async postOf(src, head) {
    return head.message.post;
  }
}

export class DemoRepo {
  /**
   * `safety` is the in-memory record of PROTOCOL §7.1's demo paragraph:
   * `userId: null`, never written to `tgs.moderation`, and never loaded from
   * it. A demo block is not the reader's judgement about a real person, and a
   * real block list is not a demo's to show.
   */
  constructor(safety) {
    this.safety = safety;
    this.world = buildWorld(Date.now());
    this.cards = this.world.cards;
    this.comments = {};
    this.commentIndexCache = null;
    this.listeners = new Set();
    this.prefs = {};
    this.newerNode = null;
    this.candidates = null;
    const entry = this.cards[usernameKey(READER)];
    this.myNode = { chatId: entry.chatId, supergroupId: entry.supergroupId, username: READER, pinnedMessageId: entry.pinnedMessageId };
    this.indexComments();
    primeClips();
  }

  /** Leaving drops the object; this drops what it minted (js/demo/media.js). */
  destroy() {
    this.listeners.clear();
    releaseGenerated();
  }

  // ── events (js/repo.js's contract) ───────────────────────────────────────

  subscribe(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  notify(what) {
    if (what === 'comments' || what === 'safety') this.commentIndexCache = null;
    for (const fn of this.listeners) {
      try {
        fn(what);
      } catch (e) {
        console.warn('[demo] listener', e);
      }
    }
  }

  track(label, work) {
    return typeof work === 'function' ? work() : work;
  }

  // ── nothing is persisted (PRODUCT §2.22.5) ───────────────────────────────

  store() {}

  storeVersioned() {}

  persist() {}

  setPref(key, value) {
    this.prefs[key] = value;
  }

  cachedFeed() {
    return [];
  }

  cacheFeed() {}

  wipe() {
    this.myNode = null;
    this.comments = {};
    this.commentIndexCache = null;
  }

  // ── reads ────────────────────────────────────────────────────────────────

  get myCard() {
    return this.cards[usernameKey(READER)]?.card ?? null;
  }

  cachedCard(username) {
    return this.cards[usernameKey(username)] ?? null;
  }

  /** Every fixture is already here, so a read is a lookup; an unknown name is `Not a tgsocial node.` */
  async readNode(username) {
    const entry = this.cachedCard(username);
    if (entry) return entry;
    return { username, title: null, card: null, newer: false, missing: true, photo: null, description: null, fetchedAt: Date.now() };
  }

  async findMyNode() {
    return this.myNode;
  }

  async getMe() {
    return null;
  }

  async feedInfo(username) {
    const feed = this.world.feeds.get(usernameKey(username));
    if (!feed) throw new Error('Channel not found.');
    return { ...feed };
  }

  verifiedFor(description, nodeUsername) {
    return new RegExp(`tgsocial:\\s*@${nodeUsername}\\b`, 'i').test(String(description ?? ''));
  }

  /** Newest-first posts of one channel. */
  postsOf(username) {
    const key = usernameKey(username);
    return this.world.posts.filter((p) => usernameKey(p.username) === key);
  }

  async feedSources() {
    return MAIN_SOURCES;
  }

  feedSession(usernames, { applyMute = false } = {}) {
    return new DemoFeedSession(this, usernames, { applyMute });
  }

  /** §2.4's NEARBY, ranked by the app's own walk over the fixture graph. */
  async nearby() {
    const card = this.myCard;
    const byUser = new Map();
    for (const u of card.follows) {
      const e = this.cachedCard(u);
      if (e?.card) byUser.set(usernameKey(u), e.card);
    }
    return rankPlusOne(READER, card.follows, byUser)
      .map((r) => ({ ...r, entry: this.cachedCard(r.username) }))
      // §2.18: a blocked node is not in the +1 walk, and not in `+1 · 7`
      .filter((r) => r.entry?.card && r.entry.card.public !== false && !this.safety?.isBlocked(r.username));
  }

  /**
   * §2.22.1's DIRECTORY: the nodes in no walk — `lume`, `noor`, `veda`. The
   * reader is not among them because their card says `public: no`, which is
   * §2.4's rule and not a special case for the demo.
   */
  async directory({ exclude = new Set() } = {}) {
    const walk = this.walkKeys();
    const seen = new Set([...exclude].map(usernameKey));
    seen.add(usernameKey(READER));
    return Object.values(this.cards)
      .filter((e) => e.card && e.card.public !== false)
      .filter((e) => !seen.has(usernameKey(e.username)) && !walk.has(usernameKey(e.username)))
      .filter((e) => !this.safety?.isBlocked(e.username))
      .sort((a, b) => usernameKey(a.username).localeCompare(usernameKey(b.username)));
  }

  /** Everyone reachable at distance ≤ 2 — the walk the Directory is the complement of. */
  walkKeys() {
    const card = this.myCard;
    const out = new Set((card?.follows ?? []).map(usernameKey));
    for (const u of card?.follows ?? []) {
      for (const p of this.cachedCard(u)?.card?.follows ?? []) out.add(usernameKey(p));
    }
    out.delete(usernameKey(READER));
    return out;
  }

  /** The four rows of §2.22.5's sheet, derived rather than written down twice. */
  demoStats() {
    const direct = this.myCard?.follows?.length ?? 0;
    return {
      nodes: Object.keys(this.cards).length,
      sources: MAIN_SOURCES.length,
      posts: this.world.posts.filter((p) => MAIN_SOURCES.some((s) => usernameKey(s) === usernameKey(p.username))).length,
      direct,
      plusOne: this.walkKeys().size - direct,
    };
  }

  async postByLink(username, serverId) {
    const post = this.world.posts.find((p) => usernameKey(p.username) === usernameKey(username) && p.link.endsWith(`/${serverId}`));
    if (!post) throw new Error('Post not found.');
    return post;
  }

  // ── comments (PROTOCOL §6.3) ─────────────────────────────────────────────

  /**
   * The index is built once, from the fixture comments that are in scope —
   * mine, my follows' and my +1s' comments channels, exactly as
   * `Repo.commentChannels()` scopes them. `crate` is reached through `pell`,
   * so their spam comment is in scope and carries the `+1` pill (§2.12).
   */
  indexComments() {
    const scope = new Set([usernameKey(READER), ...this.walkKeys()]);
    this.comments = {};
    for (const c of this.world.comments) {
      if (!scope.has(usernameKey(c.node))) continue;
      const k = usernameKey(c.channel);
      if (!this.comments[k]) this.comments[k] = { channel: c.channel, node: c.node, comments: [], fetchedAt: Date.now() };
      this.comments[k].comments.push(c);
    }
    this.commentIndexCache = null;
  }

  async refreshComments() {
    this.indexComments();
    this.notify('comments');
  }

  // ── writes: every one of them refused (PRODUCT §2.22.3) ──────────────────

  follow() { return refuse(); }

  unfollow() { return refuse(); }

  writeCard() { return refuse(); }

  setPublic() { return refuse(); }

  setFeeds() { return refuse(); }

  editProfile() { return refuse(); }

  addBacklink() { return refuse(); }

  createNode() { return refuse(); }

  post() { return refuse(); }

  postComment() { return refuse(); }

  createRepliesChannel() { return refuse(); }

  deleteComment() { return refuse(); }

  announce() { return refuse(); }

  async checkUsername() {
    return 'invalid';
  }

  async suggestedUsername() {
    return READER;
  }

  cachedCandidates() {
    return this.candidates;
  }

  /** The feeds on the reader's card, so §2.2's Manage screen has its rows — and `Save Feeds` has something to refuse. */
  async myFeedCandidates() {
    return (this.myCard?.feeds ?? []).map((u) => {
      const feed = this.world.feeds.get(usernameKey(u));
      return { chatId: feed?.chatId ?? null, supergroupId: null, title: feed?.title ?? `@${u}`, username: u, canPost: true, photo: null };
    });
  }

  async refreshCandidates() {
    this.candidates = await this.myFeedCandidates();
    this.notify('candidates');
    return this.candidates;
  }

  // ── delete my node (PRODUCT §2.21, §2.22.2) ──────────────────────────────

  /**
   * The whole §2.21 flow against the fixtures — this is the point of the demo
   * being visible at all: Guideline 5.1.1(v) asks for an in-app way to delete
   * the account, and nobody who cannot make an account can reach it any other
   * way. The two channels go, comments channel first, and `wipe()` leaves the
   * client nodeless exactly as §4.11 step 3 does.
   */
  async deleteMyNode() {
    const replies = this.myCard?.replies ?? null;
    for (const name of [replies, READER]) {
      if (!name) continue;
      delete this.cards[usernameKey(name)];
      this.world.feeds.delete(usernameKey(name));
    }
    this.world.posts = [];
    this.world.comments = [];
    this.wipe();
    this.notify('myNode');
    return { ok: true };
  }

  signOut() { return refuse(); }
}

// §2.22.2 — "the real code paths": borrowed rather than reimplemented, so the
// demo's tree, its depth-5 flattening and its `5 comments` footer come out of
// the code a real session runs.
DemoRepo.prototype.commentIndex = Repo.prototype.commentIndex;
DemoRepo.prototype.commentThread = Repo.prototype.commentThread;
DemoRepo.prototype.commentCount = Repo.prototype.commentCount;
