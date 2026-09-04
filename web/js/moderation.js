/* moderation.js — the reader's safety lists (PROTOCOL §7.1, PRODUCT §2.15–§2.18).
 *
 * One record, stored apart from every cache, holding who this reader blocked,
 * which feeds they muted and what they reported. It is the whole of the
 * filter: there is no server to ask and nothing here is ever published — not
 * to the card, not to Telegram, not to anyone. The only thing that leaves the
 * device is the report email in §2.15, which the reader's own mail client
 * sends.
 *
 * Two halves, deliberately: pure functions (record shape, the filter
 * predicates, the email) that node can unit-test with no DOM, and one class
 * that owns the storage and the notification. `js/repo.js` and the views ask
 * the class; `test/protocol.test.mjs` asserts the functions.
 */
import { targetKey, usernameKey } from './protocol.js';

/**
 * localStorage key, deliberately outside the `LS` map in js/repo.js and
 * outside the versioned-cache path: sign-out loops over that map, and a cache
 * bump discards what it wrote. Neither may take a block list with it
 * (PROTOCOL §7.1).
 */
export const MODERATION_KEY = 'tgs.moderation';

/**
 * The record's OWN version — not the cache schema (PRODUCT §2.3). A cache bump
 * throws caches away and must never throw a block list away, so this number
 * moves for its own reasons and an unknown one is read as best it can be
 * rather than dropped.
 */
export const SAFETY_VERSION = 1;

/** §2.19 — the published address, the one thing a serverless client can offer. */
export const CONTACT_ADDRESS = 'elijah@lucianlabs.ca';

/**
 * §2.15's seven reasons, in order, on every platform. They are the email's
 * subject line verbatim, which is what stops them being reworded per build and
 * what gives the operator a sortable inbox.
 */
export const REPORT_REASONS = [
  'Spam',
  'Nudity or sexual content',
  'Violence or threats',
  'Hate or harassment',
  'Child safety',
  'Illegal content',
  'Something else',
];

export function emptyRecord(userId = null) {
  return { v: SAFETY_VERSION, userId: userId ?? null, blocked: [], mutedFeeds: [], hidden: [] };
}

function keyList(value) {
  if (!Array.isArray(value)) return [];
  const out = [];
  const seen = new Set();
  for (const item of value) {
    const k = usernameKey(typeof item === 'string' ? item.replace(/^@/, '') : '');
    if (!k || seen.has(k)) continue;
    seen.add(k);
    out.push(k);
  }
  return out;
}

function hiddenList(value) {
  if (!Array.isArray(value)) return [];
  const out = [];
  const seen = new Set();
  for (const item of value) {
    const key = typeof item?.key === 'string' ? item.key.trim().toLowerCase() : '';
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push({
      key,
      reason: typeof item.reason === 'string' ? item.reason : '',
      at: typeof item.at === 'string' ? item.at : '',
    });
  }
  return out;
}

/**
 * Any stored shape → a record this build can use. Unknown `v` keeps whatever
 * fields it recognises (§7.1: read as best it can be, never dropped), and a
 * record written by ANOTHER Telegram account is replaced by empty lists rather
 * than inherited — on a shared device that list is someone else's judgement.
 * A record with no `userId` yet (written before the account was known) is
 * adopted by the first account that reads it.
 */
export function normaliseRecord(raw, userId = null) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return emptyRecord(userId);
  const stored = typeof raw.userId === 'number' ? raw.userId : null;
  if (userId !== null && stored !== null && stored !== userId) return emptyRecord(userId);
  return {
    v: Number.isFinite(raw.v) ? raw.v : SAFETY_VERSION,
    userId: userId ?? stored,
    blocked: keyList(raw.blocked),
    mutedFeeds: keyList(raw.mutedFeeds),
    hidden: hiddenList(raw.hidden),
  };
}

// ── the filter (PRODUCT §2.18) ─────────────────────────────────────────────

/**
 * §2.18 — a post is dropped when its attributed node (§2.3) is blocked, when a
 * report hid it, or — on the main feed only — when its source channel is
 * muted. `applyMute` is that "only": a muted feed stays complete on its own
 * screen (§2.17), so the channel screen and the public routes pass false.
 */
export function keepsPost(post, lists, { applyMute = false } = {}) {
  if (!lists) return true;
  if (post?.node && lists.isBlocked(post.node)) return false;
  if (lists.isHidden(targetKey(post?.link))) return false;
  if (applyMute && lists.isMutedFeed(post?.username)) return false;
  return true;
}

/** §2.18 — a comment goes with its commenter's block and with its own report. */
export function keepsComment(comment, lists) {
  if (!lists) return true;
  if (comment?.node && lists.isBlocked(comment.node)) return false;
  return !lists.isHidden(targetKey(comment?.link));
}

// ── the report email (PRODUCT §2.15) ───────────────────────────────────────

export function reportSubject(reason) {
  return `tgsocial report — ${reason}`;
}

/**
 * The body, exactly as §2.15 prints it. It ends on a blank line on purpose:
 * that is where the composer's cursor lands, under the prompt. The app adds
 * nothing else — no device id, no node of the reporter, no list; the address
 * it is sent from is whatever their own mail client uses, and every line is
 * editable before they send.
 */
export function reportBody({ reason, link, channel, messageId, node, kind, app }) {
  return [
    `Reason: ${reason}`,
    `Link: ${link}`,
    `Channel: @${channel}`,
    `Message: ${messageId}`,
    `Node: ${node ? `@${node}` : 'unattributed'}`,
    `Kind: ${kind}`,
    `App: ${app}`,
    '',
    'Anything you want to add:',
    '',
    '',
  ].join('\n');
}

export function mailtoUrl(address, subject, body) {
  return `mailto:${address}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
}

// ── the store ──────────────────────────────────────────────────────────────

/**
 * The lists, and the only thing allowed to write them.
 *
 * `storage` is injected so this is constructible in node (the unit tests build
 * one over a Map); in the browser it is localStorage. Every mutation persists
 * immediately and calls `onChange` — the surfaces repaint off that, which is
 * how a block empties the feed on the next render with no filter toggle
 * anywhere (§2.18).
 */
export class SafetyLists {
  constructor({ storage = null, onChange = null, key = MODERATION_KEY } = {}) {
    this.storage = storage ?? defaultStorage();
    this.onChange = onChange;
    this.key = key;
    this.record = normaliseRecord(this.readRaw());
  }

  readRaw() {
    try {
      const raw = this.storage?.getItem(this.key);
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  }

  persist() {
    try {
      this.storage?.setItem(this.key, JSON.stringify(this.record));
    } catch (e) {
      console.warn('[moderation] save', e.message);
    }
  }

  changed() {
    this.persist();
    if (this.onChange) this.onChange();
  }

  /**
   * PROTOCOL §7.1 — on `authorizationStateReady`, the account that owns this
   * record. A record written by a different account is replaced by empty
   * lists; the same account (or a record that never learned an id) keeps
   * everything, which is what "survives Sign Out" means.
   */
  adopt(userId) {
    if (typeof userId !== 'number') return;
    const before = this.record;
    if (before.userId === userId) return;
    const next = normaliseRecord(before, userId);
    this.record = next;
    this.persist();
    // Stamping the id on a record that never had one changes nothing anyone can
    // see, and this runs on every sign-in — so only the case that actually
    // replaces someone else's lists repaints. A repaint here would land in the
    // middle of the post-authorization boot (PRODUCT §2.13's held destination).
    const replaced = next.blocked.length !== before.blocked.length
      || next.mutedFeeds.length !== before.mutedFeeds.length
      || next.hidden.length !== before.hidden.length;
    if (replaced && this.onChange) this.onChange();
  }

  get blocked() {
    return this.record.blocked;
  }

  get mutedFeeds() {
    return this.record.mutedFeeds;
  }

  get hidden() {
    return this.record.hidden;
  }

  isBlocked(username) {
    const k = usernameKey(String(username ?? '').replace(/^@/, ''));
    return !!k && this.record.blocked.includes(k);
  }

  isMutedFeed(username) {
    const k = usernameKey(String(username ?? '').replace(/^@/, ''));
    return !!k && this.record.mutedFeeds.includes(k);
  }

  isHidden(key) {
    return typeof key === 'string' && key !== '' && this.record.hidden.some((h) => h.key === key.toLowerCase());
  }

  hiddenEntry(key) {
    return this.record.hidden.find((h) => h.key === String(key ?? '').toLowerCase()) ?? null;
  }

  block(username) {
    const k = usernameKey(String(username ?? '').replace(/^@/, ''));
    if (!k || this.record.blocked.includes(k)) return false;
    this.record.blocked = [...this.record.blocked, k];
    this.changed();
    return true;
  }

  unblock(username) {
    const k = usernameKey(String(username ?? '').replace(/^@/, ''));
    if (!this.record.blocked.includes(k)) return false;
    this.record.blocked = this.record.blocked.filter((u) => u !== k);
    this.changed();
    return true;
  }

  muteFeed(username) {
    const k = usernameKey(String(username ?? '').replace(/^@/, ''));
    if (!k || this.record.mutedFeeds.includes(k)) return false;
    this.record.mutedFeeds = [...this.record.mutedFeeds, k];
    this.changed();
    return true;
  }

  unmuteFeed(username) {
    const k = usernameKey(String(username ?? '').replace(/^@/, ''));
    if (!this.record.mutedFeeds.includes(k)) return false;
    this.record.mutedFeeds = this.record.mutedFeeds.filter((u) => u !== k);
    this.changed();
    return true;
  }

  /**
   * §2.15 — hiding is immediate and unconditional: it happens when Send Report
   * is tapped, not when a mail is proved sent, because the app cannot know
   * that and the reader has already said they do not want to see it. `link` is
   * the thing's own t.me link, so a post and a comment hide by the same key
   * (PROTOCOL §6.2).
   */
  hide(link, reason) {
    const key = targetKey(link);
    if (!key) return false;
    const at = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    this.record.hidden = [{ key, reason: String(reason ?? ''), at }, ...this.record.hidden.filter((h) => h.key !== key)];
    this.changed();
    return true;
  }

  unhide(key) {
    const k = String(key ?? '').toLowerCase();
    if (!this.record.hidden.some((h) => h.key === k)) return false;
    this.record.hidden = this.record.hidden.filter((h) => h.key !== k);
    this.changed();
    return true;
  }

  keepsPost(post, opts) {
    return keepsPost(post, this, opts);
  }

  keepsComment(comment) {
    return keepsComment(comment, this);
  }

  /** Drop blocked nodes out of a list of usernames (Explore rows, both graph lists). */
  keepsNode(username) {
    return !this.isBlocked(username);
  }
}

function defaultStorage() {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage;
  } catch {
    return null;
  }
}
