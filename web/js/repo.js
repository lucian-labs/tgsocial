/* repo.js — MyNode, card cache, feed sources, discovery, posting.
 *
 * Talks to Telegram only through td.js; all parsing/merging is protocol.js.
 * Local state (PROTOCOL §6) is small and serialisable in localStorage:
 *   tgs.myNode   { chatId, supergroupId, username, pinnedMessageId }
 *   tgs.cards    { [username]: { username, title, card, newer, fetchedAt, chatId, supergroupId, description, photo } }
 *   tgs.feed     last rendered post models (cold-start cache)
 *   tgs.prefs    { setupSkipped }
 */
import {
  MARKER,
  parseCard,
  serialiseCard,
  isNewerCard,
  normaliseUsername,
  usernameKey,
  sameUsername,
  emptyCard,
  nodeDescription,
  descriptionLooksLikeNode,
  hasBacklink,
  withBacklink,
  withFollow,
  withoutFollow,
  parseIndexLine,
  indexLine,
  deepLink,
  channelLink,
  isPost,
  createMerge,
  pushMessages,
  markExhausted,
  takeNext,
  isExhausted,
  mergeCursors,
  rankPlusOne,
  entityRuns,
  DEFAULT_INDEX_GROUP,
} from './protocol.js';

const LS = {
  myNode: 'tgs.myNode',
  cards: 'tgs.cards',
  feed: 'tgs.feed',
  prefs: 'tgs.prefs',
};

const CARD_TTL_MS = 10 * 60 * 1000;

/** Errors whose message is already product copy (shown without the "Couldn't update your card." prefix). */
export class PlainError extends Error {
  constructor(message) {
    super(message);
    this.name = 'PlainError';
    this.plain = true;
  }
}

export function userMessage(e, prefix) {
  if (e?.plain) return e.message;
  return prefix ? `${prefix} ${e?.message ?? ''}`.trim() : e?.message ?? 'Something went wrong.';
}
const FEED_CACHE_MAX = 40;
const PAGE = 30;

function load(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch {
    return fallback;
  }
}

function save(key, value) {
  try {
    if (value === null || value === undefined) localStorage.removeItem(key);
    else localStorage.setItem(key, JSON.stringify(value));
  } catch (e) {
    console.warn('[repo] save', key, e.message);
  }
}

async function pmap(items, limit, fn) {
  const out = new Array(items.length);
  let i = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (i < items.length) {
      const idx = i;
      i += 1;
      try {
        out[idx] = await fn(items[idx], idx);
      } catch (e) {
        out[idx] = null;
      }
    }
  });
  await Promise.all(workers);
  return out;
}

/** Trim a TDLib file object to what we need to re-download later. */
function slimFile(file) {
  if (!file || !file.id) return null;
  return { id: file.id, uniqueId: file.remote?.unique_id ?? null, done: !!file.local?.is_downloading_completed };
}

export function supergroupUsername(sg) {
  if (!sg) return null;
  const u = sg.usernames;
  if (u) return u.editable_username || u.active_usernames?.[0] || null;
  return sg.username || null;
}

function messageText(msg) {
  return msg?.content?.['@type'] === 'messageText' ? msg.content.text?.text ?? '' : '';
}

/** TDLib said the object does not exist (as opposed to failing to fetch it). */
export function isNotFound(e) {
  return e?.code === 404;
}

/** searchPublicChat: the username resolves to nothing — a definite answer, not a transient failure. */
export function isUnresolvableUsername(e) {
  if (isNotFound(e)) return true;
  return e?.code === 400 && /USERNAME_NOT_OCCUPIED|USERNAME_INVALID|CHANNEL_PRIVATE|CHAT_NOT_FOUND|chat not found/i.test(e.message ?? '');
}

export function canPostStatus(status) {
  if (!status) return false;
  const t = status['@type'];
  if (t === 'chatMemberStatusCreator') return true;
  if (t === 'chatMemberStatusAdministrator') {
    const rights = status.rights ?? status;
    return !!rights.can_post_messages;
  }
  return false;
}

export class Repo {
  constructor(td, config) {
    this.td = td;
    this.config = config;
    this.indexGroup = normaliseUsername(config?.indexGroup || DEFAULT_INDEX_GROUP) || DEFAULT_INDEX_GROUP;
    this.myNode = load(LS.myNode, null);
    this.cards = load(LS.cards, {});
    this.prefs = load(LS.prefs, {});
    this.chatsById = new Map();
    this.chatIdByUsername = new Map();
    this.userNames = new Map();
    this.listeners = new Set();
    this.me = null;
    /** Set when one of my created public channels carries a card newer than v1 (PROTOCOL §8). Not persisted. */
    this.newerNode = null;
  }

  // ── events ───────────────────────────────────────────────────────────────

  subscribe(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  notify(what) {
    for (const fn of this.listeners) {
      try {
        fn(what);
      } catch (e) {
        console.warn('[repo] listener', e);
      }
    }
  }

  // ── persistence ──────────────────────────────────────────────────────────

  persist() {
    save(LS.myNode, this.myNode);
    save(LS.cards, this.cards);
    save(LS.prefs, this.prefs);
  }

  wipe() {
    for (const k of Object.values(LS)) localStorage.removeItem(k);
    this.myNode = null;
    this.newerNode = null;
    this.cards = {};
    this.prefs = {};
    this.chatsById.clear();
    this.chatIdByUsername.clear();
  }

  /** PRODUCT §4: writes toast "You're offline." and never reach Telegram. */
  assertOnline() {
    const offline = (typeof navigator !== 'undefined' && navigator.onLine === false) || this.td.connectionState === 'connectionStateWaitingForNetwork';
    if (offline) throw new PlainError("You're offline.");
  }

  get myCard() {
    if (!this.myNode) return null;
    return this.cards[usernameKey(this.myNode.username)]?.card ?? null;
  }

  setPref(key, value) {
    this.prefs[key] = value;
    save(LS.prefs, this.prefs);
  }

  // ── chat lookups ─────────────────────────────────────────────────────────

  async chatByUsername(username) {
    const key = usernameKey(username);
    if (this.chatIdByUsername.has(key)) {
      const cached = this.chatsById.get(this.chatIdByUsername.get(key));
      if (cached) return cached;
    }
    const chat = await this.td.send({ '@type': 'searchPublicChat', username });
    this.chatsById.set(chat.id, chat);
    this.chatIdByUsername.set(key, chat.id);
    return chat;
  }

  async chat(chatId) {
    if (this.chatsById.has(chatId)) return this.chatsById.get(chatId);
    const chat = await this.td.send({ '@type': 'getChat', chat_id: chatId });
    this.chatsById.set(chatId, chat);
    return chat;
  }

  async supergroup(chat) {
    const id = chat?.type?.supergroup_id;
    if (!id) return null;
    return this.td.send({ '@type': 'getSupergroup', supergroup_id: id });
  }

  async supergroupDescription(chat) {
    const id = chat?.type?.supergroup_id;
    if (!id) return '';
    const full = await this.td.trySend({ '@type': 'getSupergroupFullInfo', supergroup_id: id });
    return full?.description ?? '';
  }

  /**
   * Newest pinned message of a chat. `{ id: null, text: null }` only when TDLib says
   * there is none (404); any other failure (network, FLOOD_WAIT, aborted) propagates so
   * callers never mistake "could not read" for "not a node".
   */
  async pinnedText(chatId) {
    let msg;
    try {
      msg = await this.td.send({ '@type': 'getChatPinnedMessage', chat_id: chatId });
    } catch (e) {
      if (isNotFound(e)) return { id: null, text: null };
      throw e;
    }
    return { id: msg.id, text: messageText(msg) };
  }

  async userName(userId) {
    if (this.userNames.has(userId)) return this.userNames.get(userId);
    const u = await this.td.trySend({ '@type': 'getUser', user_id: userId });
    const name = u ? `${u.first_name ?? ''} ${u.last_name ?? ''}`.trim() : '';
    this.userNames.set(userId, name);
    return name;
  }

  async getMe() {
    if (!this.me) this.me = await this.td.send({ '@type': 'getMe' });
    return this.me;
  }

  // ── nodes (PROTOCOL §4.2 – §4.6) ─────────────────────────────────────────

  /**
   * getCreatedPublicChats → first channel whose pinned message is a card.
   * A channel whose card is a newer version (PROTOCOL §8) is still my node —
   * it is recorded in `newerNode` and null is returned, so callers show
   * "Newer card. Update the app." instead of offering to create a second one.
   */
  async findMyNode() {
    const res = await this.td.send({ '@type': 'getCreatedPublicChats', type: { '@type': 'publicChatTypeHasUsername' } });
    let newer = null;
    for (const chatId of res?.chat_ids ?? []) {
      const chat = await this.chat(chatId);
      if (chat?.type?.['@type'] !== 'chatTypeSupergroup' || !chat.type.is_channel) continue;
      const { id, text } = await this.pinnedText(chatId);
      const card = parseCard(text);
      if (!card) {
        if (!newer && isNewerCard(text)) {
          const sg = await this.supergroup(chat);
          const username = supergroupUsername(sg);
          if (username) newer = { chatId, supergroupId: chat.type.supergroup_id, username, pinnedMessageId: id };
        }
        continue;
      }
      const sg = await this.supergroup(chat);
      const username = supergroupUsername(sg);
      if (!username) continue;
      this.myNode = { chatId, supergroupId: chat.type.supergroup_id, username, pinnedMessageId: id };
      this.newerNode = null;
      this.rememberCard(username, { title: chat.title, card, newer: false, chatId, supergroupId: chat.type.supergroup_id, photo: slimFile(chat.photo?.small), description: null });
      this.persist();
      this.notify('myNode');
      return this.myNode;
    }
    this.newerNode = newer;
    return null;
  }

  /** 'available' | 'taken' | 'invalid' | 'toomany' | 'unavailable' */
  async checkUsername(username) {
    const u = normaliseUsername(username);
    if (!u) return 'invalid';
    try {
      const r = await this.td.send({ '@type': 'checkChatUsername', chat_id: 0, username: u });
      const t = r?.['@type'] ?? '';
      if (t === 'checkChatUsernameResultOk') return 'available';
      if (t === 'checkChatUsernameResultUsernameInvalid') return 'invalid';
      if (t === 'checkChatUsernameResultPublicChatsTooMany') return 'toomany';
      if (t === 'checkChatUsernameResultPublicGroupsUnavailable') return 'unavailable';
      return 'taken';
    } catch (e) {
      if (/USERNAME_INVALID/.test(e.message)) return 'invalid';
      if (/USERNAME_OCCUPIED|USERNAME_PURCHASE/.test(e.message)) return 'taken';
      throw e;
    }
  }

  async suggestedUsername() {
    const me = await this.getMe();
    const mine = supergroupUsername(me) || me?.usernames?.editable_username || me?.username;
    if (mine) return `tgs_${mine}`.slice(0, 32);
    const first = (me?.first_name || 'node').toLowerCase().replace(/[^a-z0-9]/g, '') || 'node';
    const digits = String(Math.floor(1000 + Math.random() * 9000));
    return `tgs_${first}${digits}`.slice(0, 32);
  }

  /** sendMessage and wait for the server id (updateMessageSendSucceeded). */
  async sendAndWait(chatId, content, { silent = true } = {}) {
    const sent = await this.td.send({
      '@type': 'sendMessage',
      chat_id: chatId,
      input_message_content: content,
      options: { '@type': 'messageSendOptions', disable_notification: silent },
    });
    if (sent?.sending_state == null) return sent;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        offOk();
        offFail();
        resolve(sent);
      }, 30000);
      const offOk = this.td.on('updateMessageSendSucceeded', (u) => {
        if (u.old_message_id === sent.id) {
          clearTimeout(timer);
          offOk();
          offFail();
          resolve(u.message);
        }
      });
      const offFail = this.td.on('updateMessageSendFailed', (u) => {
        if (u.old_message_id === sent.id) {
          clearTimeout(timer);
          offOk();
          offFail();
          reject(new Error(u.error?.message || u.error_message || 'Telegram rejected the message.'));
        }
      });
    });
  }

  /** PROTOCOL §4.3 */
  async createNode(username, title) {
    this.assertOnline();
    const u = normaliseUsername(username);
    if (!u) throw new Error('That username is not valid.');
    const me = await this.getMe();
    const name = title || `${me.first_name ?? ''} ${me.last_name ?? ''}`.trim() || u;
    const chat = await this.td.send({
      '@type': 'createNewSupergroupChat',
      title: name,
      is_forum: false,
      is_channel: true,
      description: MARKER,
      message_auto_delete_time: 0,
      for_import: false,
    });
    const supergroupId = chat.type?.supergroup_id;
    try {
      await this.td.send({ '@type': 'setSupergroupUsername', supergroup_id: supergroupId, username: u });
    } catch (e) {
      await this.td.trySend({ '@type': 'deleteChat', chat_id: chat.id });
      throw e;
    }
    const card = { ...emptyCard(), name };
    const msg = await this.sendAndWait(chat.id, inputText(serialiseCard(card)));
    await this.td.send({ '@type': 'pinChatMessage', chat_id: chat.id, message_id: msg.id, disable_notification: true, only_for_self: false });
    this.myNode = { chatId: chat.id, supergroupId, username: u, pinnedMessageId: msg.id };
    this.chatsById.set(chat.id, chat);
    this.chatIdByUsername.set(usernameKey(u), chat.id);
    this.rememberCard(u, { title: name, card, newer: false, chatId: chat.id, supergroupId, photo: null, description: MARKER });
    this.persist();
    this.notify('myNode');
    // optional: channel photo from the profile photo
    const big = me.profile_photo?.big;
    if (big?.id) {
      await this.td.trySend({ '@type': 'setChatPhoto', chat_id: chat.id, photo: { '@type': 'inputChatPhotoStatic', photo: { '@type': 'inputFileId', id: big.id } } });
    }
    return this.myNode;
  }

  rememberCard(username, entry) {
    const key = usernameKey(username);
    const prev = this.cards[key] ?? {};
    this.cards[key] = { ...prev, ...entry, username, fetchedAt: Date.now() };
    save(LS.cards, this.cards);
    return this.cards[key];
  }

  cachedCard(username) {
    return this.cards[usernameKey(username)] ?? null;
  }

  /**
   * PROTOCOL §4.5 — read any node; returns the cache entry ({card: null} when not a node).
   * The cache is only overwritten by a definite answer from Telegram: the username
   * resolves to nothing, or it resolves and the pinned message is absent or not a card.
   * A transient failure (network, FLOOD_WAIT, aborted request) rejects and leaves the
   * cached entry untouched, so reads keep serving cache (PRODUCT §4).
   */
  async readNode(username, { force = false } = {}) {
    const key = usernameKey(username);
    const cached = this.cards[key];
    if (!force && cached && Date.now() - cached.fetchedAt < CARD_TTL_MS) return cached;
    let chat;
    try {
      chat = await this.chatByUsername(username);
    } catch (e) {
      if (!isUnresolvableUsername(e)) throw e;
      return this.rememberCard(username, { title: null, card: null, newer: false, chatId: null, supergroupId: null, photo: null, description: null, missing: true });
    }
    const { id, text } = await this.pinnedText(chat.id);
    const card = parseCard(text);
    const newer = !card && isNewerCard(text);
    const description = await this.supergroupDescription(chat);
    const entry = this.rememberCard(username, {
      username: supergroupUsername(await this.supergroup(chat)) || username,
      title: chat.title,
      card,
      newer,
      chatId: chat.id,
      supergroupId: chat.type?.supergroup_id ?? null,
      photo: slimFile(chat.photo?.small),
      description,
      pinnedMessageId: id,
      missing: false,
    });
    if (this.myNode && sameUsername(username, this.myNode.username) && id) {
      this.myNode.pinnedMessageId = id;
      this.persist();
    }
    return entry;
  }

  /**
   * PROTOCOL §4.4 — getChatPinnedMessage → modify → editMessageText.
   *
   * `mutate(card) → card` is applied to the card as it is on Telegram at write time,
   * never to the local copy, so an edit made on another device (one account, three
   * builds) is carried forward instead of clobbered. The local copy is updated
   * optimistically from the cache and replaced by the merged result on success, or
   * rolled back on failure. With no cached card there is nothing to show
   * optimistically; the fresh read is the only base a write may start from.
   */
  async writeCard(mutate) {
    if (!this.myNode) throw new Error('No node.');
    this.assertOnline();
    const key = usernameKey(this.myNode.username);
    const prevEntry = this.cards[key] ?? null;
    const prevCard = prevEntry?.card ?? null;
    if (prevCard) {
      const guess = mutate(prevCard);
      this.serialise(guess); // refuse "Card is full." before touching anything
      this.cards[key] = { ...prevEntry, card: guess, fetchedAt: Date.now() };
      save(LS.cards, this.cards);
      this.notify('card');
    }
    try {
      const { messageId, card: fresh } = await this.readMyCardMessage();
      const next = mutate(fresh);
      await this.editCardMessage(messageId, this.serialise(next));
      if ((fresh.bio ?? '') !== (next.bio ?? '')) {
        await this.td.trySend({ '@type': 'setChatDescription', chat_id: this.myNode.chatId, description: nodeDescription(next) });
      }
      this.cards[key] = { ...(this.cards[key] ?? {}), username: this.myNode.username, card: next, newer: false, missing: false, pinnedMessageId: messageId, fetchedAt: Date.now() };
      save(LS.cards, this.cards);
      this.notify('card');
      return next;
    } catch (e) {
      if (prevEntry) this.cards[key] = prevEntry;
      else delete this.cards[key];
      save(LS.cards, this.cards);
      this.notify('card');
      throw e;
    }
  }

  serialise(card) {
    try {
      return serialiseCard(card);
    } catch (e) {
      throw new PlainError(e.message); // "Card is full."
    }
  }

  /**
   * My card as Telegram holds it right now: `{ messageId, card }`. The pinned message
   * is the record; if the pin was lost (or something else got pinned over it) the
   * known card message is read back and re-pinned (PROTOCOL §4.4). Never falls back
   * to the local cache — a write must not start from a guess.
   */
  async readMyCardMessage() {
    const { chatId, pinnedMessageId } = this.myNode;
    let msg = null;
    try {
      msg = await this.td.send({ '@type': 'getChatPinnedMessage', chat_id: chatId });
    } catch (e) {
      if (!isNotFound(e)) throw e;
    }
    let card = msg ? parseCard(messageText(msg)) : null;
    if (!card && pinnedMessageId && msg?.id !== pinnedMessageId) {
      const known = await this.td.trySend({ '@type': 'getMessage', chat_id: chatId, message_id: pinnedMessageId });
      const knownCard = known ? parseCard(messageText(known)) : null;
      if (knownCard) {
        msg = known;
        card = knownCard;
        await this.td.trySend({ '@type': 'pinChatMessage', chat_id: chatId, message_id: known.id, disable_notification: true, only_for_self: false });
      }
    }
    if (!card) {
      if (msg && isNewerCard(messageText(msg))) throw new PlainError('Newer card. Update the app.');
      throw new Error('Card message not found.');
    }
    return { messageId: msg.id, card };
  }

  async editCardMessage(messageId, text) {
    const { chatId } = this.myNode;
    try {
      await this.td.send({ '@type': 'editMessageText', chat_id: chatId, message_id: messageId, input_message_content: inputText(text) });
    } catch (e) {
      if (!/MESSAGE_NOT_MODIFIED/.test(e.message)) throw e;
    }
    this.myNode.pinnedMessageId = messageId;
    this.persist();
  }

  follow(username) {
    return this.writeCard((card) => withFollow(card, username));
  }

  unfollow(username) {
    return this.writeCard((card) => withoutFollow(card, username));
  }

  setPublic(isPublic) {
    return this.writeCard((card) => ({ ...card, public: !!isPublic }));
  }

  editProfile({ name, bio, link }) {
    return this.writeCard((card) => ({ ...card, name: name || null, bio: bio || null, link: link || null }));
  }

  // ── my feeds (PROTOCOL §4.7) ─────────────────────────────────────────────

  async loadAllChats() {
    for (let i = 0; i < 20; i += 1) {
      try {
        await this.td.send({ '@type': 'loadChats', chat_list: { '@type': 'chatListMain' }, limit: 200 });
      } catch (e) {
        if (e.code === 404) break;
        throw e;
      }
    }
    const res = await this.td.send({ '@type': 'getChats', chat_list: { '@type': 'chatListMain' }, limit: 200 });
    return res?.chat_ids ?? [];
  }

  /** Channels I can post to. [{ chatId, supergroupId, title, username, canPost, description }] */
  async myFeedCandidates() {
    const ids = new Set();
    const created = await this.td.trySend({ '@type': 'getCreatedPublicChats', type: { '@type': 'publicChatTypeHasUsername' } });
    for (const id of created?.chat_ids ?? []) ids.add(id);
    try {
      for (const id of await this.loadAllChats()) ids.add(id);
    } catch (e) {
      console.warn('[repo] chat scan', e.message);
    }
    const out = [];
    for (const chatId of ids) {
      const chat = await this.chat(chatId).catch(() => null);
      if (!chat || chat.type?.['@type'] !== 'chatTypeSupergroup' || !chat.type.is_channel) continue;
      if (this.myNode && chatId === this.myNode.chatId) continue;
      const sg = await this.supergroup(chat).catch(() => null);
      if (!sg || !canPostStatus(sg.status)) continue;
      const username = supergroupUsername(sg);
      out.push({ chatId, supergroupId: chat.type.supergroup_id, title: chat.title, username, canPost: true, photo: slimFile(chat.photo?.small) });
    }
    out.sort((a, b) => (a.username ? 0 : 1) - (b.username ? 0 : 1) || a.title.localeCompare(b.title));
    return out;
  }

  setFeeds(usernames) {
    return this.writeCard((card) => ({ ...card, feeds: usernames }));
  }

  /** Append `tgsocial: @node` to a feed's description (PROTOCOL §3). */
  async addBacklink(feedUsername) {
    if (!this.myNode) throw new Error('No node.');
    this.assertOnline();
    const chat = await this.chatByUsername(feedUsername);
    const current = await this.supergroupDescription(chat);
    const next = withBacklink(current, this.myNode.username);
    if (next === current) return true;
    await this.td.send({ '@type': 'setChatDescription', chat_id: chat.id, description: next });
    return true;
  }

  /** Channel header info for a feed (PRODUCT §2.6). */
  async feedInfo(username, { force = false } = {}) {
    const chat = await this.chatByUsername(username);
    const description = await this.supergroupDescription(chat);
    const sg = await this.supergroup(chat);
    return {
      chatId: chat.id,
      username: supergroupUsername(sg) || username,
      title: chat.title,
      description,
      photo: slimFile(chat.photo?.small),
      canPost: canPostStatus(sg?.status),
      memberCount: sg?.member_count ?? null,
    };
  }

  /** Which of the listing node(s) this feed is verified for. */
  verifiedFor(description, nodeUsername) {
    return hasBacklink(description, nodeUsername);
  }

  // ── feed (PROTOCOL §4.8) ─────────────────────────────────────────────────

  /** Sources = my feeds ∪ feeds of every node I follow (usernames, deduped). */
  async feedSources({ refresh = false } = {}) {
    if (!this.myNode) return [];
    // my own card is re-read on refresh or when the cached copy is stale (TTL), so a follow or
    // feed changed on another device or in plain Telegram reaches this build (PROTOCOL §4.5)
    await this.readNode(this.myNode.username, { force: refresh || !this.myCard }).catch(() => null);
    const card = this.myCard;
    if (!card) return [];
    const list = [];
    const seen = new Set();
    const add = (u) => {
      const k = usernameKey(u);
      if (seen.has(k)) return;
      seen.add(k);
      list.push(u);
    };
    for (const f of card.feeds) add(f);
    // a follow whose refresh fails keeps contributing from its cached card
    await pmap(card.follows, 4, (u) => this.readNode(u, { force: refresh }));
    for (const u of card.follows) for (const f of this.cachedCard(u)?.card?.feeds ?? []) add(f);
    return list;
  }

  feedSession(usernames) {
    return new FeedSession(this, usernames);
  }

  cachedFeed() {
    return load(LS.feed, []);
  }

  cacheFeed(posts) {
    save(LS.feed, posts.slice(0, FEED_CACHE_MAX));
  }

  /** Fetch one page of channel history, repeating while TDLib returns short (§4.8). */
  async history(chatId, fromMessageId, want = PAGE) {
    const out = [];
    let from = fromMessageId;
    for (let i = 0; i < 6 && out.length < want; i += 1) {
      const res = await this.td.send({
        '@type': 'getChatHistory',
        chat_id: chatId,
        from_message_id: from,
        offset: 0,
        limit: want - out.length,
        only_local: false,
      });
      const msgs = res?.messages ?? [];
      if (!msgs.length) break;
      out.push(...msgs);
      from = msgs[msgs.length - 1].id;
    }
    return out;
  }

  /** Message → post model (serialisable; files are slimmed). */
  async toPost(message, source) {
    const c = message.content ?? {};
    const t = c['@type'];
    const post = {
      key: `${message.chat_id}:${message.id}`,
      id: message.id,
      chatId: message.chat_id,
      username: source.username,
      title: source.title,
      avatar: source.photo ?? null,
      date: message.date,
      text: '',
      entities: [],
      media: null,
      views: message.interaction_info?.view_count ?? 0,
      reactions: [],
      forwardedFrom: null,
      link: deepLink(source.username, message.id),
    };
    const formatted = t === 'messageText' ? c.text : c.caption;
    if (formatted) {
      post.text = formatted.text ?? '';
      post.entities = (formatted.entities ?? []).map((e) => ({ offset: e.offset, length: e.length, type: e.type }));
    }
    if (t === 'messagePhoto' && c.photo?.sizes?.length) {
      post.media = { kind: 'photo', sizes: c.photo.sizes.map((s) => ({ w: s.width, h: s.height, file: slimFile(s.photo) })) };
    } else if (t === 'messageVideo' && c.video) {
      post.media = { kind: 'video', duration: c.video.duration, thumb: thumb(c.video.thumbnail), w: c.video.width, h: c.video.height };
    } else if (t === 'messageAnimation' && c.animation) {
      post.media = { kind: 'animation', duration: c.animation.duration, thumb: thumb(c.animation.thumbnail), w: c.animation.width, h: c.animation.height };
    } else if (t === 'messageDocument' && c.document) {
      post.media = { kind: 'document', fileName: c.document.file_name || 'File', thumb: thumb(c.document.thumbnail) };
    } else if (t === 'messageAudio' && c.audio) {
      post.media = { kind: 'audio', title: c.audio.title || c.audio.file_name || 'Audio', performer: c.audio.performer || '', duration: c.audio.duration };
    }
    const ii = message.interaction_info;
    const reactions = Array.isArray(ii?.reactions) ? ii.reactions : ii?.reactions?.reactions ?? [];
    for (const r of reactions) {
      const emoji = r.type?.['@type'] === 'reactionTypeEmoji' ? r.type.emoji : r.reaction?.emoji ?? r.reaction;
      const count = r.total_count ?? 0;
      if (typeof emoji === 'string' && count > 0) post.reactions.push({ emoji, count });
    }
    const origin = message.forward_info?.origin;
    if (origin) post.forwardedFrom = await this.originName(origin);
    return post;
  }

  async originName(origin) {
    if (origin.sender_name) return origin.sender_name;
    const chatId = origin.chat_id ?? origin.sender_chat_id;
    if (chatId) {
      const chat = await this.chat(chatId).catch(() => null);
      return chat?.title || 'a channel';
    }
    if (origin.sender_user_id) return (await this.userName(origin.sender_user_id)) || 'a user';
    return 'Telegram';
  }

  // ── discovery (PROTOCOL §5) ──────────────────────────────────────────────

  /** Graph walk: distance-2 nodes ranked by mutual count. */
  async nearby({ refresh = false } = {}) {
    if (!this.myNode) return [];
    await this.readNode(this.myNode.username, { force: refresh || !this.myCard }).catch(() => null);
    const card = this.myCard;
    if (!card) return [];
    await pmap(card.follows, 4, (u) => this.readNode(u, { force: refresh }));
    const byUser = new Map();
    for (const u of card.follows) {
      const e = this.cachedCard(u);
      if (e?.card) byUser.set(usernameKey(u), e.card);
    }
    const ranked = rankPlusOne(this.myNode.username, card.follows, byUser).slice(0, 60);
    await pmap(ranked, 3, (r) => this.readNode(r.username));
    return ranked
      .map((r) => ({ ...r, entry: this.cachedCard(r.username) }))
      .filter((r) => r.entry?.card && r.entry.card.public !== false);
  }

  /** Username prefix search ∪ index group; returns cache entries for public nodes. */
  async directory({ exclude = new Set() } = {}) {
    const found = [];
    const seen = new Set([...exclude].map(usernameKey));
    if (this.myNode) seen.add(usernameKey(this.myNode.username));
    for (const f of this.myCard?.follows ?? []) seen.add(usernameKey(f));
    const consider = (u) => {
      const n = normaliseUsername(u);
      if (!n) return;
      const k = usernameKey(n);
      if (seen.has(k)) return;
      seen.add(k);
      found.push(n);
    };
    // 1. prefix search
    const res = await this.td.trySend({ '@type': 'searchPublicChats', query: 'tgs_' });
    for (const chatId of res?.chat_ids ?? []) {
      const chat = await this.chat(chatId).catch(() => null);
      if (!chat || chat.type?.['@type'] !== 'chatTypeSupergroup' || !chat.type.is_channel) continue;
      const sg = await this.supergroup(chat).catch(() => null);
      const u = supergroupUsername(sg);
      if (u) consider(u);
    }
    // 2. index group
    try {
      const group = await this.chatByUsername(this.indexGroup);
      const msgs = await this.history(group.id, 0, 200);
      for (const m of msgs) {
        if (m.content?.['@type'] !== 'messageText') continue;
        const u = parseIndexLine(m.content.text?.text);
        if (u) consider(u);
      }
    } catch (e) {
      // no index group yet — fine
    }
    await pmap(found, 3, (u) => this.readNode(u));
    return found.map((u) => this.cachedCard(u)).filter((e) => e?.card && e.card.public !== false);
  }

  /** PROTOCOL §5.3: members post one message. Resolves false when my line is already in the last 200. */
  async announce() {
    if (!this.myNode) throw new Error('No node.');
    this.assertOnline();
    if (this.myCard?.public === false) throw new Error('Your node is unlisted.');
    const group = await this.chatByUsername(this.indexGroup);
    await this.td.trySend({ '@type': 'joinChat', chat_id: group.id });
    const mine = usernameKey(this.myNode.username);
    const recent = await this.history(group.id, 0, 200).catch(() => []);
    const listed = recent.some((m) => m.content?.['@type'] === 'messageText' && usernameKey(parseIndexLine(m.content.text?.text)) === mine);
    if (listed) return false;
    await this.sendAndWait(group.id, inputText(indexLine(this.myNode.username)), { silent: true });
    return true;
  }

  // ── posting (PROTOCOL §4.9) ──────────────────────────────────────────────

  async post(feedUsername, text) {
    this.assertOnline();
    const chat = await this.chatByUsername(feedUsername);
    return this.sendAndWait(chat.id, inputText(text), { silent: false });
  }

  // ── sign out ─────────────────────────────────────────────────────────────

  async signOut() {
    await this.td.logOut();
    this.wipe();
  }
}

function thumb(t) {
  if (!t) return null;
  return { file: slimFile(t.file), w: t.width, h: t.height };
}

export function inputText(text) {
  return {
    '@type': 'inputMessageText',
    text: { '@type': 'formattedText', text, entities: [] },
    link_preview_options: { '@type': 'linkPreviewOptions', is_disabled: true },
    clear_draft: false,
  };
}

/** Pick the smallest photo size whose width covers the target, else the largest. */
export function pickPhotoSize(sizes, targetWidth) {
  const withFile = (sizes ?? []).filter((s) => s.file?.id);
  if (!withFile.length) return null;
  const sorted = [...withFile].sort((a, b) => a.w - b.w);
  return sorted.find((s) => s.w >= targetWidth) ?? sorted[sorted.length - 1];
}

/**
 * One merged feed across sources with per-source cursors. Sources that
 * cannot be resolved are marked exhausted so the merge never stalls.
 */
export class FeedSession {
  constructor(repo, usernames, { cardMessageIds = {} } = {}) {
    this.repo = repo;
    this.usernames = usernames;
    this.merge = createMerge(usernames.map(usernameKey));
    this.sources = new Map();
    this.cardMessageIds = cardMessageIds;
    this.primed = false;
  }

  get exhausted() {
    return isExhausted(this.merge);
  }

  cursors() {
    return mergeCursors(this.merge);
  }

  async resolve(username) {
    const key = usernameKey(username);
    if (this.sources.has(key)) return this.sources.get(key);
    try {
      const chat = await this.repo.chatByUsername(username);
      const sg = await this.repo.supergroup(chat);
      const src = { key, username: supergroupUsername(sg) || username, chatId: chat.id, title: chat.title, photo: slimFile(chat.photo?.small) };
      this.sources.set(key, src);
      return src;
    } catch (e) {
      this.sources.set(key, null);
      return null;
    }
  }

  async fill(key) {
    const src = await this.resolve(this.usernames.find((u) => usernameKey(u) === key) ?? key);
    if (!src) {
      markExhausted(this.merge, key);
      return;
    }
    const from = this.merge.sources[key].cursor;
    let msgs;
    try {
      msgs = await this.repo.history(src.chatId, from, PAGE);
    } catch (e) {
      console.warn('[feed] history', src.username, e.message);
      markExhausted(this.merge, key);
      return;
    }
    const cardId = this.cardMessageIds[key] ?? null;
    if (!msgs.length) {
      markExhausted(this.merge, key);
      return;
    }
    const posts = msgs.filter((m) => isPost(m, cardId));
    pushMessages(this.merge, key, posts);
    // the cursor advances past everything fetched, including filtered service messages;
    // a source is only exhausted once a fetch comes back empty
    const s = this.merge.sources[key];
    const oldest = msgs[msgs.length - 1];
    if (s.cursor === 0 || oldest.id < s.cursor) s.cursor = oldest.id;
    if (oldest.date < s.lastDate) s.lastDate = oldest.date;
    s.exhausted = false;
  }

  async prime() {
    if (this.primed) return;
    this.primed = true;
    await pmap(Object.keys(this.merge.sources), 4, (k) => this.fill(k));
  }

  /** Returns up to `count` post models in strict date-desc order. */
  async loadMore(count = 20) {
    await this.prime();
    const out = [];
    for (let guard = 0; guard < 40 && out.length < count; guard += 1) {
      const r = takeNext(this.merge, count - out.length);
      out.push(...r.items);
      if (out.length >= count) break;
      if (r.blockedOn) await this.fill(r.blockedOn);
      else break;
    }
    const posts = [];
    for (const item of out) {
      const src = this.sources.get(item.key);
      if (!src) continue;
      posts.push(await this.repo.toPost(item.message, src));
    }
    return posts;
  }
}

export { entityRuns, channelLink, descriptionLooksLikeNode };
