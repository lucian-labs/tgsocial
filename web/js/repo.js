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
  takeAlbumRest,
  groupAlbums,
  isExhausted,
  mergeCursors,
  rankPlusOne,
  entityRuns,
  DEFAULT_INDEX_GROUP,
  parseComment,
  serialiseComment,
  targetKey,
  attributionNode,
} from './protocol.js';

const LS = {
  myNode: 'tgs.myNode',
  cards: 'tgs.cards',
  feed: 'tgs.feed',
  prefs: 'tgs.prefs',
  comments: 'tgs.comments',
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

/**
 * Persisted-cache schema (PRODUCT §2.3 stale cache guard). Bumped whenever a
 * cached model changes shape or ordering rules; a payload written by another
 * schema — including the pre-versioned raw arrays/objects — is discarded, so
 * an older build's cache can never paint.
 */
const CACHE_SCHEMA = 2;

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

/** Read a versioned cache payload; anything not written by this schema is discarded. */
function loadVersioned(key, fallback) {
  const raw = load(key, null);
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || raw.v !== CACHE_SCHEMA) return fallback;
  return raw.data ?? fallback;
}

function saveVersioned(key, data) {
  save(key, data === null || data === undefined ? null : { v: CACHE_SCHEMA, data });
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
  return { id: file.id, uniqueId: file.remote?.unique_id ?? null, done: !!file.local?.is_downloading_completed, size: file.size || file.expected_size || 0 };
}

/** TDLib minithumbnail → data URI for the blur-up placeholder (PRODUCT §2.11). */
function miniUri(mini) {
  return mini?.data ? `data:image/jpeg;base64,${mini.data}` : null;
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
    this.cards = loadVersioned(LS.cards, {});
    this.prefs = load(LS.prefs, {});
    /** Comment index (PROTOCOL §6.3): comments-channel → parsed comments. Discardable. */
    this.comments = loadVersioned(LS.comments, {});
    /** Memoised commentIndex(); dropped on every 'comments' notification. */
    this.commentIndexCache = null;
    this.chatsById = new Map();
    this.chatIdByUsername = new Map();
    this.userNames = new Map();
    this.listeners = new Set();
    this.me = null;
    /** Set when one of my created public channels carries a card newer than v1 (PROTOCOL §8). Not persisted. */
    this.newerNode = null;
    /** Last live feed-candidates result (session cache: painted instantly, then replaced by a fresh scan). */
    this.candidates = null;
    this.candidatesStale = true;
    this.candidatesInflight = null;
    this.watchCandidates();
  }

  /**
   * TDLib updates that can change feed candidacy invalidate the candidates
   * cache and notify 'candidates-dirty' — the Setup / Manage feeds surface,
   * while visible, answers with a debounced live re-query (never a timer):
   *   - updateSupergroup: a username appeared/changed or admin rights changed
   *     (a channel made public while the screen is open);
   *   - updateNewChat for a channel: a channel just became known;
   *   - updateChatPosition joining the main list: a chat entered chatListMain.
   */
  watchCandidates() {
    const dirty = () => {
      this.candidatesStale = true;
      this.notify('candidates-dirty');
    };
    this.td.on('updateSupergroup', dirty);
    this.td.on('updateNewChat', (u) => {
      const chat = u?.chat;
      if (chat?.type?.['@type'] !== 'chatTypeSupergroup' || !chat.type.is_channel) return;
      this.chatsById.set(chat.id, chat);
      dirty();
    });
    this.td.on('updateChatPosition', (u) => {
      if (u?.position?.list?.['@type'] === 'chatListMain') dirty();
    });
  }

  /** Report an operation into the app's activity registry (status pill / Status sheet). */
  track(label, work) {
    return this.td.track(label, work);
  }

  // ── events ───────────────────────────────────────────────────────────────

  subscribe(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  notify(what) {
    if (what === 'comments') this.commentIndexCache = null;
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
    saveVersioned(LS.cards, this.cards);
    save(LS.prefs, this.prefs);
  }

  wipe() {
    for (const k of Object.values(LS)) localStorage.removeItem(k);
    this.myNode = null;
    this.newerNode = null;
    this.candidates = null;
    this.candidatesStale = true;
    this.cards = {};
    this.prefs = {};
    this.comments = {};
    this.commentIndexCache = null;
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
  findMyNode() {
    return this.track('Looking for your node', () => this.findMyNodeInner());
  }

  async findMyNodeInner() {
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
    saveVersioned(LS.cards, this.cards);
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
    return this.track(`Reading card @${username}`, () => this.readNodeInner(username));
  }

  async readNodeInner(username) {
    const key = usernameKey(username);
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
      saveVersioned(LS.cards, this.cards);
      this.notify('card');
    }
    try {
      const { messageId, card: fresh } = await this.track('Writing your card', () => this.readMyCardMessage());
      const next = mutate(fresh);
      await this.track('Writing your card', () => this.editCardMessage(messageId, this.serialise(next)));
      if ((fresh.bio ?? '') !== (next.bio ?? '')) {
        await this.td.trySend({ '@type': 'setChatDescription', chat_id: this.myNode.chatId, description: nodeDescription(next) });
      }
      this.cards[key] = { ...(this.cards[key] ?? {}), username: this.myNode.username, card: next, newer: false, missing: false, pinnedMessageId: messageId, fetchedAt: Date.now() };
      saveVersioned(LS.cards, this.cards);
      this.notify('card');
      return next;
    } catch (e) {
      if (prevEntry) this.cards[key] = prevEntry;
      else delete this.cards[key];
      saveVersioned(LS.cards, this.cards);
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
      // the comments channel is not a feed (PROTOCOL §6.1)
      if (username && this.myCard?.replies && sameUsername(username, this.myCard.replies)) continue;
      out.push({ chatId, supergroupId: chat.type.supergroup_id, title: chat.title, username, canPost: true, photo: slimFile(chat.photo?.small) });
    }
    out.sort((a, b) => (a.username ? 0 : 1) - (b.username ? 0 : 1) || a.title.localeCompare(b.title));
    return out;
  }

  /** Last live candidates result, or null before the first scan. */
  cachedCandidates() {
    return this.candidates;
  }

  /**
   * Live re-query of the feed candidates (getCreatedPublicChats + the
   * admin-channel scan) — always hits Telegram; the result replaces the
   * session cache. Concurrent callers share one in-flight scan. Reported to
   * the activity registry so the pill reads Syncing while it runs.
   */
  refreshCandidates() {
    if (this.candidatesInflight) return this.candidatesInflight;
    this.candidatesInflight = this.track('Syncing your channels', () => this.myFeedCandidates())
      .then((list) => {
        this.candidates = list;
        this.candidatesStale = false;
        this.notify('candidates');
        return list;
      })
      .finally(() => {
        this.candidatesInflight = null;
      });
    return this.candidatesInflight;
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

  /**
   * Cold-start cache (PRODUCT §2.3): a schema mismatch discards the payload,
   * and whatever survives is re-sorted newest-first defensively — a cached
   * page must never paint in old order.
   */
  cachedFeed() {
    const posts = loadVersioned(LS.feed, []);
    if (!Array.isArray(posts)) return [];
    return [...posts].sort((a, b) => b.date - a.date || b.id - a.id);
  }

  cacheFeed(posts) {
    saveVersioned(LS.feed, posts.slice(0, FEED_CACHE_MAX));
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

  /**
   * PRODUCT §2.3 attribution — the node this feed's posts reach me through,
   * as { username, name, photo }, or null when no node lists the feed. Name
   * is the node card's `name` (fallback @username); photo is the node
   * channel's, from the card cache.
   */
  attributionFor(feedUsername) {
    if (!this.myNode) return null;
    const node = attributionNode(feedUsername, this.myNode.username, this.myCard, (u) => this.cachedCard(u)?.card);
    if (!node) return null;
    const entry = this.cachedCard(node);
    return {
      username: entry?.username ?? node,
      name: entry?.card?.name || `@${node}`,
      photo: entry?.photo ?? null,
    };
  }

  /**
   * Message → post model (serialisable; files are slimmed). `extra` carries the
   * other messages of the same album (PRODUCT §2.11: swipe between album items);
   * their media joins post.album and the first non-empty caption wins. Every
   * post carries its attribution node (§2.3) — null when unattributed.
   */
  async toPost(message, source, extra = []) {
    const attr = this.attributionFor(source.username);
    const post = {
      key: `${message.chat_id}:${message.id}`,
      id: message.id,
      chatId: message.chat_id,
      username: source.username,
      title: source.title,
      avatar: source.photo ?? null,
      node: attr?.username ?? null,
      nodeName: attr?.name ?? null,
      nodeAvatar: attr?.photo ?? null,
      date: message.date,
      text: '',
      entities: [],
      media: null,
      album: [],
      preview: null,
      views: message.interaction_info?.view_count ?? 0,
      reactions: [],
      forwardedFrom: null,
      link: deepLink(source.username, message.id),
    };
    for (const msg of [message, ...extra]) {
      const c = msg.content ?? {};
      if (!post.text) {
        const formatted = c['@type'] === 'messageText' ? c.text : c.caption;
        if (formatted?.text) {
          post.text = formatted.text;
          post.entities = (formatted.entities ?? []).map((e) => ({ offset: e.offset, length: e.length, type: e.type }));
        }
      }
      const item = mediaItem(c);
      if (item) {
        item.messageId = msg.id;
        post.album.push(item);
      }
      if (!post.preview) post.preview = linkPreviewOf(c);
      post.date = Math.max(post.date, msg.date);
      post.views = Math.max(post.views, msg.interaction_info?.view_count ?? 0);
    }
    // album items swipe in posting order (PRODUCT §2.11), whatever order they merged in
    post.album.sort((a, b) => a.messageId - b.messageId);
    post.media = post.album[0] ?? null;
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
    return this.track(`Posting to @${feedUsername}`, async () => {
      const chat = await this.chatByUsername(feedUsername);
      return this.sendAndWait(chat.id, inputText(text), { silent: false });
    });
  }

  // ── comments (PROTOCOL §6) ───────────────────────────────────────────────

  /**
   * Comments channels in scope: mine, my follows', and my cached +1 nodes'
   * (§6.3 — network-scoped by design). All from the card cache; a node with
   * no `replies:` key contributes nothing.
   */
  commentChannels() {
    if (!this.myNode) return [];
    const nodes = new Set([usernameKey(this.myNode.username)]);
    for (const f of this.myCard?.follows ?? []) {
      nodes.add(usernameKey(f));
      for (const p of this.cachedCard(f)?.card?.follows ?? []) nodes.add(usernameKey(p));
    }
    const out = [];
    const seen = new Set();
    for (const node of nodes) {
      const entry = this.cachedCard(node);
      const channel = entry?.card?.replies;
      if (!channel) continue;
      const k = usernameKey(channel);
      if (seen.has(k)) continue;
      seen.add(k);
      out.push({ channel, node: entry.username });
    }
    return out;
  }

  /**
   * Message in a comments channel → comment model, or null when the first
   * line is not a `re:` pointer (§6.2). Entity offsets shift past the
   * pointer line; media joins the model the way it joins a post.
   */
  toComment(message, { channel, node }) {
    const c = message.content ?? {};
    const formatted = c['@type'] === 'messageText' ? c.text : c.caption;
    const raw = formatted?.text ?? '';
    const parsed = parseComment(raw);
    if (!parsed) return null;
    const cut = raw.length - parsed.body.length;
    const entities = (formatted?.entities ?? [])
      .map((e) => ({ offset: e.offset - cut, length: e.length, type: e.type }))
      .filter((e) => e.offset >= 0 && e.length > 0);
    const item = mediaItem(c);
    if (item) item.messageId = message.id;
    const entry = this.cachedCard(node);
    return {
      key: `${message.chat_id}:${message.id}`,
      id: message.id,
      chatId: message.chat_id,
      channel,
      node,
      name: entry?.card?.name || entry?.title || `@${node}`,
      avatar: entry?.photo ?? null,
      date: message.date,
      target: parsed.target,
      targetKey: targetKey(parsed.target),
      text: parsed.body,
      entities,
      media: item,
      album: item ? [item] : [],
      preview: null,
      link: deepLink(channel, message.id),
      mine: !!this.myNode && sameUsername(node, this.myNode.username),
    };
  }

  /**
   * §6.3: page each in-scope comments channel newest-first (same loop as
   * feeds), parse `re:` lines, index by target. Refreshed alongside the feed;
   * a channel whose read fails keeps its cached comments.
   */
  async refreshComments({ force = false } = {}) {
    const channels = this.commentChannels();
    const keep = new Set(channels.map((c) => usernameKey(c.channel)));
    for (const k of Object.keys(this.comments)) {
      if (!keep.has(k)) delete this.comments[k];
    }
    await pmap(channels, 3, async ({ channel, node }) => {
      const k = usernameKey(channel);
      const cached = this.comments[k];
      if (!force && cached && Date.now() - cached.fetchedAt < CARD_TTL_MS) return;
      try {
        await this.track(`Reading comments @${channel}`, async () => {
          const chat = await this.chatByUsername(channel);
          const msgs = await this.history(chat.id, 0, 100);
          const list = [];
          for (const m of msgs) {
            const comment = this.toComment(m, { channel, node });
            if (comment && comment.targetKey) list.push(comment);
          }
          this.comments[k] = { channel, node, comments: list, fetchedAt: Date.now() };
        });
      } catch (e) {
        console.warn('[repo] comments', channel, e.message);
      }
    });
    saveVersioned(LS.comments, this.comments);
    this.notify('comments');
  }

  /**
   * All indexed comments, targetKey → comments oldest-first. Memoised until
   * the next 'comments' notification so a screenful of cards asking for
   * counts shares one build instead of O(cards × comments) rebuilds.
   */
  commentIndex() {
    if (this.commentIndexCache) return this.commentIndexCache;
    const byTarget = new Map();
    for (const entry of Object.values(this.comments)) {
      for (const c of entry.comments ?? []) {
        if (!byTarget.has(c.targetKey)) byTarget.set(c.targetKey, []);
        byTarget.get(c.targetKey).push(c);
      }
    }
    for (const list of byTarget.values()) list.sort((a, b) => a.date - b.date || a.id - b.id);
    this.commentIndexCache = byTarget;
    return byTarget;
  }

  /**
   * The comment tree for one post link: [{ comment, children }], oldest
   * first, replies resolved through `re:` chains (§6.2). `count` is the
   * whole tree — "comments from your network".
   */
  commentThread(link) {
    const index = this.commentIndex();
    const seen = new Set();
    const build = (key) => {
      const out = [];
      for (const c of index.get(key) ?? []) {
        if (seen.has(c.key)) continue;
        seen.add(c.key);
        out.push({ comment: c, children: build(targetKey(c.link)) });
      }
      return out;
    };
    const tree = build(targetKey(link));
    return { tree, count: seen.size };
  }

  commentCount(link) {
    return this.commentThread(link).count;
  }

  /**
   * §6.4 — first comment ever: create the comments channel (§4.3 steps 1–2,
   * `_r` username, description `tgsocial v1 replies · @<node>`) and add
   * `replies:` to the card.
   */
  async createRepliesChannel(username) {
    if (!this.myNode) throw new Error('No node.');
    this.assertOnline();
    const u = normaliseUsername(username);
    if (!u) throw new Error('That username is not valid.');
    return this.track('Making your comments channel', async () => {
      const entry = this.cachedCard(this.myNode.username);
      const title = `${entry?.card?.name || entry?.title || this.myNode.username} replies`;
      const chat = await this.td.send({
        '@type': 'createNewSupergroupChat',
        title,
        is_forum: false,
        is_channel: true,
        description: `${MARKER} replies · @${this.myNode.username}`,
        message_auto_delete_time: 0,
        for_import: false,
      });
      try {
        await this.td.send({ '@type': 'setSupergroupUsername', supergroup_id: chat.type?.supergroup_id, username: u });
      } catch (e) {
        await this.td.trySend({ '@type': 'deleteChat', chat_id: chat.id });
        throw e;
      }
      this.chatsById.set(chat.id, chat);
      this.chatIdByUsername.set(usernameKey(u), chat.id);
      await this.writeCard((card) => ({ ...card, replies: u }));
      return u;
    });
  }

  /** §6.4: send the comment into my own comments channel. Returns the comment model. */
  async postComment(targetLink, text) {
    if (!this.myNode) throw new Error('No node.');
    this.assertOnline();
    const channel = this.myCard?.replies;
    if (!channel) throw new PlainError('Make your comments channel first.');
    return this.track('Writing a comment', async () => {
      const chat = await this.chatByUsername(channel);
      const msg = await this.sendAndWait(chat.id, inputText(serialiseComment(targetLink, text)));
      const comment = this.toComment(msg, { channel, node: this.myNode.username });
      const k = usernameKey(channel);
      const entry = this.comments[k] ?? { channel, node: this.myNode.username, comments: [], fetchedAt: 0 };
      if (comment) entry.comments.unshift(comment);
      this.comments[k] = entry;
      saveVersioned(LS.comments, this.comments);
      this.notify('comments');
      return comment;
    });
  }

  /** Delete my own comment: the message in my channel is the comment. */
  async deleteComment(comment) {
    this.assertOnline();
    return this.track('Deleting your comment', async () => {
      await this.td.send({ '@type': 'deleteMessages', chat_id: comment.chatId, message_ids: [comment.id], revoke: true });
      const k = usernameKey(comment.channel);
      const entry = this.comments[k];
      if (entry) {
        entry.comments = entry.comments.filter((c) => c.key !== comment.key);
        saveVersioned(LS.comments, this.comments);
      }
      this.notify('comments');
    });
  }

  /** Resolve a post by its deep link (for a thread opened without a seed). */
  async postByLink(username, serverId) {
    const chat = await this.chatByUsername(username);
    const sg = await this.supergroup(chat);
    const source = { key: usernameKey(username), username: supergroupUsername(sg) || username, chatId: chat.id, title: chat.title, photo: slimFile(chat.photo?.small) };
    const msg = await this.td.send({ '@type': 'getMessage', chat_id: chat.id, message_id: serverId * 1048576 });
    if (!isPost(msg)) throw new Error('Post not found.');
    return this.toPost(msg, source);
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

/** One media item of a post (PRODUCT §2.11). Serialisable; files are slimmed. */
export function mediaItem(c) {
  const t = c?.['@type'];
  if (t === 'messagePhoto' && c.photo?.sizes?.length) {
    return {
      kind: 'photo',
      sizes: c.photo.sizes.map((s) => ({ w: s.width, h: s.height, file: slimFile(s.photo) })),
      mini: miniUri(c.photo.minithumbnail),
    };
  }
  if (t === 'messageVideo' && c.video) {
    return {
      kind: 'video',
      file: slimFile(c.video.video),
      duration: c.video.duration,
      w: c.video.width,
      h: c.video.height,
      thumb: thumb(c.video.thumbnail),
      mini: miniUri(c.video.minithumbnail),
      mime: c.video.mime_type || 'video/mp4',
      fileName: c.video.file_name || 'Video',
      streamable: !!c.video.supports_streaming,
    };
  }
  if (t === 'messageAnimation' && c.animation) {
    return {
      kind: 'animation',
      file: slimFile(c.animation.animation),
      duration: c.animation.duration,
      w: c.animation.width,
      h: c.animation.height,
      thumb: thumb(c.animation.thumbnail),
      mini: miniUri(c.animation.minithumbnail),
      mime: c.animation.mime_type || 'video/mp4',
      fileName: c.animation.file_name || 'GIF',
    };
  }
  if (t === 'messageAudio' && c.audio) {
    return {
      kind: 'audio',
      file: slimFile(c.audio.audio),
      duration: c.audio.duration,
      title: c.audio.title || c.audio.file_name || 'Audio',
      performer: c.audio.performer || '',
      mime: c.audio.mime_type || 'audio/mpeg',
      fileName: c.audio.file_name || 'Audio',
      cover: thumb(c.audio.album_cover_thumbnail),
    };
  }
  if (t === 'messageVoiceNote' && c.voice_note) {
    return {
      kind: 'voice',
      file: slimFile(c.voice_note.voice),
      duration: c.voice_note.duration,
      waveform: c.voice_note.waveform || null,
      mime: c.voice_note.mime_type || 'audio/ogg',
    };
  }
  if (t === 'messageVideoNote' && c.video_note) {
    return {
      kind: 'videoNote',
      file: slimFile(c.video_note.video),
      duration: c.video_note.duration,
      length: c.video_note.length,
      thumb: thumb(c.video_note.thumbnail),
      mini: miniUri(c.video_note.minithumbnail),
      mime: 'video/mp4',
    };
  }
  if (t === 'messageDocument' && c.document) {
    return {
      kind: 'document',
      file: slimFile(c.document.document),
      fileName: c.document.file_name || 'File',
      mime: c.document.mime_type || '',
      thumb: thumb(c.document.thumbnail),
      mini: miniUri(c.document.minithumbnail),
    };
  }
  if (t === 'messageSticker' && c.sticker) {
    const format = c.sticker.format?.['@type'] ?? '';
    return {
      kind: 'sticker',
      file: slimFile(c.sticker.sticker),
      w: c.sticker.width,
      h: c.sticker.height,
      animated: format !== 'stickerFormatWebp',
      thumb: thumb(c.sticker.thumbnail),
    };
  }
  if (t === 'messagePoll' && c.poll) {
    const n = c.poll.options?.length ?? 0;
    return { kind: 'summary', text: `Poll · ${n} ${n === 1 ? 'option' : 'options'}` };
  }
  if (t === 'messageLocation' || t === 'messageVenue') {
    return { kind: 'summary', text: 'Location' };
  }
  if (t === 'messageContact') {
    return { kind: 'summary', text: 'Contact' };
  }
  return null;
}

/** messageText link preview (TDLib ≥1.8.44 `link_preview`, older `web_page`). */
export function linkPreviewOf(c) {
  if (c?.['@type'] !== 'messageText') return null;
  const lp = c.link_preview ?? c.web_page;
  if (!lp?.url) return null;
  const photo = lp.type?.photo ?? lp.photo ?? null;
  const sizes = photo?.sizes?.length ? photo.sizes.map((s) => ({ w: s.width, h: s.height, file: slimFile(s.photo) })) : null;
  return {
    url: lp.url,
    siteName: lp.site_name || '',
    title: lp.title || lp.site_name || lp.display_url || lp.url,
    description: lp.description?.text ?? (typeof lp.description === 'string' ? lp.description : ''),
    thumb: sizes,
    mini: miniUri(photo?.minithumbnail),
  };
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
      msgs = await this.repo.track(`Loading @${src.username}`, () => this.repo.history(src.chatId, from, PAGE));
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

  /**
   * Returns up to `count` post models in strict date-desc order (an album counts
   * as one post: its remaining items are drained off the buffer so a page
   * boundary never splits it in two).
   */
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
    if (out.length) out.push(...takeAlbumRest(this.merge, out[out.length - 1]));
    const posts = [];
    for (const group of groupAlbums(out)) {
      const src = this.sources.get(group.key);
      if (!src) continue;
      // items are in posting order (id asc); the album's newest message anchors the post
      const [head, ...rest] = [...group.items].sort((a, b) => b.id - a.id);
      posts.push(await this.repo.toPost(head.message, src, rest.map((i) => i.message)));
    }
    return posts;
  }

  /** Resolved source for a chat id, or null — for live inserts (PRODUCT §2.3). */
  sourceForChat(chatId) {
    for (const src of this.sources.values()) {
      if (src && src.chatId === chatId) return src;
    }
    return null;
  }
}

export { entityRuns, channelLink, descriptionLooksLikeNode };
