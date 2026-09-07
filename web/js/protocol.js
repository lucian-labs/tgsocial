/* tgsocial protocol v1 — pure module (PROTOCOL.md).
 *
 * No DOM, no TDLib, no platform imports. Everything here is unit-tested
 * against docs/card-vectors.json by test/protocol.test.mjs.
 */

export const MARKER = 'tgsocial v1';
export const CARD_MAX = 4096;
export const USERNAME_RE = /^[A-Za-z_][A-Za-z0-9_]{4,31}$/;
export const DEFAULT_INDEX_GROUP = 'tgsocial_index';

const KEYS = new Set(['name', 'bio', 'link', 'public', 'feeds', 'follows', 'replies']);

// ── usernames ──────────────────────────────────────────────────────────────

/** `@name`, `name`, `https://t.me/name`, `t.me/name/` → `name`; invalid → null. */
export function normaliseUsername(input) {
  if (typeof input !== 'string') return null;
  let s = input.trim();
  s = s.replace(/^https?:\/\//i, '');
  s = s.replace(/^(www\.)?t\.me\//i, '');
  s = s.replace(/^@/, '');
  s = s.replace(/\/+$/, '');
  if (!USERNAME_RE.test(s)) return null;
  return s;
}

export function usernameKey(u) {
  return typeof u === 'string' ? u.toLowerCase() : '';
}

export function sameUsername(a, b) {
  return usernameKey(a) === usernameKey(b);
}

/** A list token must carry its `@` or be a t.me link (PROTOCOL §2); bare names are not accepted in lists. */
export function isListToken(token) {
  return /^@/.test(token) || /^(https?:\/\/)?(www\.)?t\.me\//i.test(token);
}

/** Split a whitespace-separated list of usernames; drop invalid; collapse duplicates (first wins, casing kept). */
export function parseUsernameList(value) {
  const out = [];
  const seen = new Set();
  for (const token of String(value ?? '').split(/\s+/)) {
    if (!token || !isListToken(token)) continue;
    const u = normaliseUsername(token);
    if (!u) continue;
    const k = usernameKey(u);
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(u);
  }
  return out;
}

// ── card ───────────────────────────────────────────────────────────────────

/** Version number from the marker line, or null if the text is not a tgsocial card of any version. */
export function cardVersion(text) {
  if (typeof text !== 'string') return null;
  const first = text.split(/\r?\n/, 1)[0].replace(/\s+$/, '');
  const m = /^tgsocial v(\d+)$/.exec(first);
  return m ? Number(m[1]) : null;
}

export function isNewerCard(text) {
  const v = cardVersion(text);
  return v !== null && v > 1;
}

export function emptyCard() {
  return { name: null, bio: null, link: null, public: true, feeds: [], follows: [], replies: null };
}

/** Parse a pinned-message text. Returns the card or null (not a v1 card). */
export function parseCard(text) {
  if (cardVersion(text) !== 1) return null;
  const lines = text.split(/\r?\n/);
  const raw = {};
  for (let i = 1; i < lines.length; i += 1) {
    const line = lines[i];
    const colon = line.indexOf(':');
    if (colon < 0) continue;
    const key = line.slice(0, colon).trim().toLowerCase();
    const value = line.slice(colon + 1).trim();
    if (!KEYS.has(key)) continue;
    raw[key] = raw[key] === undefined ? value : `${raw[key]} ${value}`;
  }
  const card = emptyCard();
  card.name = raw.name ? raw.name : null;
  card.bio = raw.bio ? raw.bio : null;
  card.link = raw.link ? raw.link : null;
  card.public = raw.public === undefined ? true : raw.public.trim().toLowerCase() !== 'no';
  card.feeds = parseUsernameList(raw.feeds);
  card.follows = parseUsernameList(raw.follows);
  card.replies = parseUsernameList(raw.replies)[0] ?? null;
  return card;
}

/** Exact wire text for a card. Throws RangeError('Card is full.') past 4096 chars. */
export function serialiseCard(card) {
  const lines = [MARKER];
  const one = (v) => (typeof v === 'string' ? v.replace(/\s+/g, ' ').trim() : '');
  if (one(card.name)) lines.push(`name: ${one(card.name)}`);
  if (one(card.bio)) lines.push(`bio: ${one(card.bio)}`);
  if (one(card.link)) lines.push(`link: ${one(card.link)}`);
  lines.push(`public: ${card.public === false ? 'no' : 'yes'}`);
  const feeds = parseUsernameList((card.feeds ?? []).map((u) => `@${String(u).replace(/^@/, '')}`).join(' '));
  const follows = parseUsernameList((card.follows ?? []).map((u) => `@${String(u).replace(/^@/, '')}`).join(' '));
  if (feeds.length) lines.push(`feeds: ${feeds.map((u) => `@${u}`).join(' ')}`);
  if (follows.length) lines.push(`follows: ${follows.map((u) => `@${u}`).join(' ')}`);
  const replies = card.replies ? normaliseUsername(`@${String(card.replies).replace(/^@/, '')}`) : null;
  if (replies) lines.push(`replies: @${replies}`);
  // §10.2: the extension's lines come after every §2 key, so a card written
  // before the extension and one written after differ by an append — a diff a
  // person reading their own channel on Telegram can follow. `card.work` is
  // absent for a client that does not implement §10, and then this is §2's
  // serialiser unchanged, character for character.
  for (const line of workLines(card.work, feeds)) lines.push(line);
  // §11.2: the private extension's lines come last, after §10's, by the same
  // argument — absent `privateId` / `private`, this is the serialiser above.
  for (const line of privateLines(card)) lines.push(line);
  const text = lines.join('\n');
  if (text.length > CARD_MAX) throw new RangeError('Card is full.');
  return text;
}

export function cardFits(card) {
  try {
    serialiseCard(card);
    return true;
  } catch {
    return false;
  }
}

/** `tgsocial v1 · <bio>` for the channel description (255 chars max). */
export function nodeDescription(card) {
  const bio = typeof card?.bio === 'string' ? card.bio.trim() : '';
  const text = bio ? `${MARKER} · ${bio}` : MARKER;
  return text.length > 255 ? text.slice(0, 255) : text;
}

export function descriptionLooksLikeNode(description) {
  return typeof description === 'string' && description.trimStart().startsWith(MARKER);
}

export function isFollowing(card, username) {
  return !!card && card.follows.some((u) => sameUsername(u, username));
}

export function withFollow(card, username) {
  if (isFollowing(card, username)) return card;
  return { ...card, follows: [...card.follows, username] };
}

export function withoutFollow(card, username) {
  return { ...card, follows: card.follows.filter((u) => !sameUsername(u, username)) };
}

// ── backlink ───────────────────────────────────────────────────────────────

/** `tgsocial: @node` anywhere in a feed's description → verified for that node. */
export function hasBacklink(description, node) {
  if (typeof description !== 'string' || !node) return false;
  const want = usernameKey(normaliseUsername(node) ?? node);
  const re = /tgsocial:\s*@([A-Za-z0-9_]+)/gi;
  let m;
  while ((m = re.exec(description)) !== null) {
    if (usernameKey(m[1]) === want) return true;
  }
  return false;
}

export function backlinkLine(node) {
  return `tgsocial: @${node}`;
}

/** Description with the backlink appended (no-op if present). Keeps 255 cap. */
export function withBacklink(description, node) {
  const base = typeof description === 'string' ? description.trimEnd() : '';
  if (hasBacklink(base, node)) return base;
  const line = backlinkLine(node);
  const joined = base ? `${base}\n${line}` : line;
  if (joined.length <= 255) return joined;
  const room = 255 - line.length - 1;
  return room > 0 ? `${base.slice(0, room).trimEnd()}\n${line}` : line;
}

/** `node: @tgs_x` lines in the index group (PROTOCOL §5.3). */
export function parseIndexLine(text) {
  if (typeof text !== 'string') return null;
  const m = /^\s*node:\s*(\S+)\s*$/im.exec(text);
  return m ? normaliseUsername(m[1]) : null;
}

export function indexLine(node) {
  return `node: @${node}`;
}

// ── comments (PROTOCOL §6) ─────────────────────────────────────────────────

/** §6.2: `re: ` + one space + a full https t.me post link. Byte-compatible across clients. */
export const COMMENT_TARGET_RE = /^re: (https:\/\/t\.me\/[A-Za-z0-9_]+\/\d+)\s*$/;

/**
 * Parse a comments-channel message text. `{ target, body }` when the first
 * line is a `re:` pointer, else null (owners may post anything else in their
 * channel; readers skip it).
 */
export function parseComment(text) {
  if (typeof text !== 'string') return null;
  const nl = text.indexOf('\n');
  const first = nl < 0 ? text : text.slice(0, nl);
  const m = COMMENT_TARGET_RE.exec(first.replace(/\r$/, ''));
  if (!m) return null;
  return { target: m[1], body: nl < 0 ? '' : text.slice(nl + 1) };
}

/** §6.5: `re: ` prefix, one space, full link, newline, body. */
export function serialiseComment(target, body) {
  const b = typeof body === 'string' ? body : '';
  return b ? `re: ${target}\n${b}` : `re: ${target}`;
}

/**
 * Canonical index key for a t.me post link: `<username lowercase>/<id>`.
 * Usernames are case-insensitive (PROTOCOL §2); the message id is not.
 */
export function targetKey(link) {
  if (typeof link !== 'string') return null;
  const m = /^https?:\/\/(?:www\.)?t\.me\/([A-Za-z0-9_]+)\/(\d+)\/?$/.exec(link.trim());
  return m ? `${m[1].toLowerCase()}/${m[2]}` : null;
}

// ── work (PROTOCOL §10) ────────────────────────────────────────────────────

/*
 * §10 is an extension, and the shape of this file is the argument for it.
 * `parseCard` above is §2 and knows nothing about anything below: delete this
 * whole block and every card on the network still parses byte-identically,
 * work keys included, because §2 already says unknown keys are ignored. §10 is
 * read by a SECOND pass over the same text.
 *
 * The two meet in exactly one place — `serialiseCard` emits work lines when,
 * and only when, the caller hands it a `work`. That is §10.6: a client that
 * read the keys has to write them back, or a follow would quietly delete
 * somebody's work card.
 */

export const WORK_ROLE_MAX = 80;
export const WORK_DOES_MAX = 12;
export const WORK_OPEN_HORIZON_DAYS = 180;
/** Lowercase, 2–24, and the punctuation real trades carry: `c++`, `c#`, `node.js`, `front of house`. */
export const WORK_TAG_RE = /^[a-z0-9][a-z0-9 +#.-]{0,22}[a-z0-9+#]$/;
export const WORK_INTENTS = ['work', 'contract', 'hiring', 'collab'];

const WORK_KEYS = new Set(['work.role', 'work.does', 'work.open', 'work.feeds']);

/** One capability tag, normalised: trimmed, inner whitespace collapsed, lowercased. Invalid → null. */
export function workTag(input) {
  if (typeof input !== 'string') return null;
  const s = input.trim().replace(/\s+/g, ' ').toLowerCase();
  return WORK_TAG_RE.test(s) ? s : null;
}

/** `a, b, c` → up to WORK_DOES_MAX tags. Invalid tags are dropped, never fatal (§10.2). */
export function parseWorkDoes(value) {
  const out = [];
  const seen = new Set();
  for (const part of String(value ?? '').split(',')) {
    const tag = workTag(part);
    if (!tag || seen.has(tag)) continue;
    seen.add(tag);
    out.push(tag);
    if (out.length === WORK_DOES_MAX) break;
  }
  return out;
}

/** A real calendar day in `YYYY-MM-DD` — `2026-02-30` is not one. */
export function isCalendarDay(s) {
  if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

/** Whole days from `a` to `b`, both `YYYY-MM-DD`. Negative when `b` is behind `a`. */
export function daysBetween(a, b) {
  const ms = Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`);
  return Math.round(ms / 86400000);
}

/** `<intent> until <YYYY-MM-DD>` → `{intent, until}`; anything else → null (§10.3). */
export function parseWorkOpen(value) {
  const m = /^([A-Za-z]+)\s+until\s+(\S+)$/.exec(String(value ?? '').trim());
  if (!m) return null;
  const intent = m[1].toLowerCase();
  if (!WORK_INTENTS.includes(intent)) return null;
  if (!isCalendarDay(m[2])) return null;
  return { intent, until: m[2] };
}

export function serialiseWorkOpen(open) {
  return open ? `${open.intent} until ${open.until}` : '';
}

/**
 * Is this intent a statement about now? Expired is obvious; the far-future
 * cap is the other half — `until 2099-01-01` is a claim nobody has to renew,
 * which is the same as no expiry at all (§10.3). `today` is `YYYY-MM-DD`.
 */
export function openIsCurrent(open, today) {
  if (!open || !isCalendarDay(open.until) || !isCalendarDay(today)) return false;
  const days = daysBetween(today, open.until);
  return days >= 0 && days <= WORK_OPEN_HORIZON_DAYS;
}

export function emptyWork() {
  return { role: null, does: [], open: null, feeds: [] };
}

/**
 * The §10 pass over a card's text. Returns the work card, or null when the
 * text is not a v1 card or carries nothing §10 can use — so "has a work card"
 * is one truthy check, and a card whose every work line is malformed is the
 * same as a card with none.
 *
 * `work.feeds` is intersected with `feeds:` here rather than trusted: `feeds:`
 * is the ownership claim (§3, which needs post rights), and a marking line has
 * no business introducing a channel the owner never claimed.
 */
export function parseWork(text) {
  const card = parseCard(text);
  if (!card) return null;
  const raw = {};
  const lines = text.split(/\r?\n/);
  for (let i = 1; i < lines.length; i += 1) {
    const colon = lines[i].indexOf(':');
    if (colon < 0) continue;
    const key = lines[i].slice(0, colon).trim().toLowerCase();
    const value = lines[i].slice(colon + 1).trim();
    if (!WORK_KEYS.has(key)) continue;
    raw[key] = raw[key] === undefined ? value : `${raw[key]} ${value}`;
  }
  const work = emptyWork();
  const role = (raw['work.role'] ?? '').replace(/\s+/g, ' ').trim();
  work.role = role ? role.slice(0, WORK_ROLE_MAX) : null;
  work.does = parseWorkDoes(raw['work.does']);
  work.open = parseWorkOpen(raw['work.open']);
  work.feeds = parseUsernameList(raw['work.feeds']).filter((f) => card.feeds.some((g) => sameUsername(f, g)));
  const empty = !work.role && !work.does.length && !work.open && !work.feeds.length;
  return empty ? null : work;
}

/**
 * §10.2 — `work.feeds` is a marking on channels `feeds:` already claims, so it
 * never outlives them. Dropping a channel from `feeds:` drops its marking with
 * it; a stale entry is a line §10.2 forbids on the wire, and it is latent
 * rather than harmless — readers ignore it today and it re-marks the channel
 * as work the moment the owner lists it again, with nobody having touched the
 * toggle.
 */
export function pruneWorkFeeds(work, feeds) {
  if (!work) return null;
  const list = work.feeds ?? [];
  const kept = list.filter((f) => (feeds ?? []).some((g) => sameUsername(f, g)));
  return kept.length === list.length ? work : { ...work, feeds: kept };
}

/**
 * The §10 lines, in §10.2 order, for `serialiseCard` to append after `replies`.
 *
 * `feeds` is the card's own `feeds:` and is not optional in practice: the
 * intersection §10.2 requires is enforced on the write side here, the same way
 * `parseWork` enforces it on the read side, so no caller can put a `work.feeds`
 * entry on the wire that the card does not claim.
 */
export function workLines(work, feeds = []) {
  const pruned = pruneWorkFeeds(work, feeds);
  if (!pruned) return [];
  const lines = [];
  const role = typeof pruned.role === 'string' ? pruned.role.replace(/\s+/g, ' ').trim().slice(0, WORK_ROLE_MAX) : '';
  if (role) lines.push(`work.role: ${role}`);
  const does = parseWorkDoes((pruned.does ?? []).join(','));
  if (does.length) lines.push(`work.does: ${does.join(', ')}`);
  const open = parseWorkOpen(serialiseWorkOpen(pruned.open));
  if (open) lines.push(`work.open: ${serialiseWorkOpen(open)}`);
  const marked = parseUsernameList((pruned.feeds ?? []).map((u) => `@${String(u).replace(/^@/, '')}`).join(' '));
  if (marked.length) lines.push(`work.feeds: ${marked.map((u) => `@${u}`).join(' ')}`);
  return lines;
}

// ── PROTOCOL §11, the private extension ─────────────────────────────────────

/** §11.2 — an invite link's hash: base64url, and Telegram has issued 16- and 22-character ones. */
export const INVITE_HASH_RE = /^[A-Za-z0-9_-]{8,64}$/;
const PRIVATE_KEYS = new Set(['private.node', 'private.feeds']);

/**
 * `https://t.me/+HASH`, `t.me/joinchat/HASH`, `tg://join?invite=HASH` → the
 * canonical `https://t.me/+HASH`; anything else → null. The hash keeps its
 * case: it is a token, not a username, and §11.2 compares it byte for byte.
 */
export function normaliseInviteLink(input) {
  if (typeof input !== 'string') return null;
  const s = input.trim();
  let hash = null;
  let m = /^tg:\/\/join\?invite=([^&\s]+)$/i.exec(s);
  if (m) hash = m[1];
  if (!hash) {
    m = /^(?:https?:\/\/)?(?:www\.)?t\.me\/(?:\+|joinchat\/)([^/?#\s]+)\/?$/i.exec(s);
    if (m) hash = m[1];
  }
  if (!hash || !INVITE_HASH_RE.test(hash)) return null;
  return `https://t.me/+${hash}`;
}

/** The hash alone — what §7.2's pending list and the safety lists key on. */
export function inviteHash(link) {
  const l = normaliseInviteLink(link);
  return l ? l.slice('https://t.me/+'.length) : null;
}

/** Whitespace-separated invite links; invalid dropped, duplicates collapse to the first (§11.2). */
export function parseInviteList(value) {
  const out = [];
  const seen = new Set();
  for (const token of String(value ?? '').split(/\s+/)) {
    const link = normaliseInviteLink(token);
    if (!link || seen.has(link)) continue;
    seen.add(link);
    out.push(link);
  }
  return out;
}

function privateRaw(text, keys) {
  const raw = {};
  const lines = text.split(/\r?\n/);
  for (let i = 1; i < lines.length; i += 1) {
    const colon = lines[i].indexOf(':');
    if (colon < 0) continue;
    const key = lines[i].slice(0, colon).trim().toLowerCase();
    const value = lines[i].slice(colon + 1).trim();
    if (!keys.has(key)) continue;
    raw[key] = raw[key] === undefined ? value : `${raw[key]} ${value}`;
  }
  return raw;
}

/**
 * The §11 pass over a PRIVATE card's text: `{ node, feeds }` or null.
 *
 * `private.node` is what makes a pinned message a private card — a card
 * without it is a card (§2 decides that alone) but not a private one, and a
 * reader that found it in a private channel has found nothing §11 can use.
 * `feeds` are invite links, never usernames: nothing here has a username.
 */
export function parsePrivate(text) {
  const card = parseCard(text);
  if (!card) return null;
  const raw = privateRaw(text, PRIVATE_KEYS);
  const node = parseUsernameList(raw['private.node'])[0] ?? null;
  if (!node) return null;
  return { node, feeds: parseInviteList(raw['private.feeds']) };
}

/**
 * The one §11 key a PUBLIC card carries: the private node's supergroup id,
 * as a string of digits (the number in a `t.me/c/<id>/…` link). Not a
 * capability — nothing can be joined or read with it — which is why it is
 * the thing that may be published (§11.3). Absent or malformed → null.
 */
export function privateIdOf(text) {
  if (!parseCard(text)) return null;
  const raw = privateRaw(text, new Set(['private.id']));
  const v = String(raw['private.id'] ?? '').trim().split(/\s+/)[0] ?? '';
  return /^[1-9]\d{0,19}$/.test(v) ? v : null;
}

/**
 * §11.3 — is this private card the private half of the node it names?
 *
 * Only the direction public → private is provable: the public card is the
 * one message only that node's owner can write, so the check is that the
 * public card of the node the private card names carries the private
 * channel's own id. The private card's claim on its own is worth nothing.
 */
export function privateVerified(privateText, supergroupId, publicText, publicNode) {
  const priv = parsePrivate(privateText);
  if (!priv || !publicNode || !sameUsername(priv.node, publicNode)) return false;
  const id = privateIdOf(publicText);
  return id !== null && id === String(supergroupId);
}

/** The §11 lines, in §11.2 order, for `serialiseCard` to append after the §10 lines. */
export function privateLines(card) {
  const lines = [];
  const id = String(card?.privateId ?? '').trim();
  if (/^[1-9]\d{0,19}$/.test(id)) lines.push(`private.id: ${id}`);
  const priv = card?.private;
  const node = priv ? normaliseUsername(`@${String(priv.node ?? '').replace(/^@/, '')}`) : null;
  if (node) {
    lines.push(`private.node: @${node}`);
    const feeds = parseInviteList((priv.feeds ?? []).join(' '));
    if (feeds.length) lines.push(`private.feeds: ${feeds.join(' ')}`);
  }
  return lines;
}

/** §10.4: `vouch: ` + one space + a node's channel link. A post link is a comment (§6.2), not a vouch. */
export const VOUCH_TARGET_RE = /^vouch: https:\/\/t\.me\/([A-Za-z0-9_]+)\s*$/;
const VOUCH_DOES_RE = /^does: (.+)$/;

/**
 * Parse a comments-channel message as a vouch: `{ node, does, body }`, or null.
 *
 * Both lines are mandatory. A `vouch:` with no `does:` under it would be "I
 * vouch for this person", which asserts nothing anyone can weigh and would
 * decay into a like button the first week — §10.4 makes the claim specific or
 * makes it nothing.
 */
export function parseVouch(text) {
  if (typeof text !== 'string') return null;
  const lines = text.split('\n');
  const m = VOUCH_TARGET_RE.exec((lines[0] ?? '').replace(/\r$/, ''));
  if (!m || !USERNAME_RE.test(m[1])) return null;
  const d = VOUCH_DOES_RE.exec((lines[1] ?? '').replace(/\r$/, ''));
  if (!d) return null;
  const does = workTag(d[1]);
  if (!does) return null;
  return { node: m[1], does, body: lines.slice(2).join('\n') };
}

/** §10.4, exact bytes. Throws RangeError('Pick one thing.') on a tag §10.2 would drop. */
export function serialiseVouch(node, does, body) {
  const tag = workTag(does);
  if (!tag) throw new RangeError('Pick one thing.');
  const head = `vouch: ${channelLink(normaliseUsername(node) ?? node)}\ndoes: ${tag}`;
  const b = typeof body === 'string' ? body : '';
  return b ? `${head}\n${b}` : head;
}

/**
 * §10.4: a vouch for the channel's own owner is not a vouch. Unforgeable-by-
 * construction is the whole value of the format, and it holds only because the
 * one channel a person can write is the one that cannot speak about them.
 */
export function keepsVouch(vouch, voucherNode) {
  return !!vouch && !!voucherNode && !sameUsername(vouch.node, voucherNode);
}

// ── work, rendered (PRODUCT §2.23–§2.25) ───────────────────────────────────

/*
 * The three §10 surfaces print dates, and three platforms have to print them
 * the same way, so the strings are derived here beside `formatTime` rather
 * than in each client's view layer. Nothing below parses anything: give it a
 * §10 value and it hands back the words PRODUCT names.
 */

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** Today as §10.3 counts it: `YYYY-MM-DD`, UTC. */
export function todayUTC(now = new Date()) {
  return new Date(now).toISOString().slice(0, 10);
}

/** `day` shifted by whole days, still `YYYY-MM-DD` UTC — the writer's 30/60/90 (§2.23). */
export function addDays(day, n) {
  if (!isCalendarDay(day)) return null;
  return new Date(Date.parse(`${day}T00:00:00Z`) + n * 86400000).toISOString().slice(0, 10);
}

/** `5 Dec 2026` — the Edit Card modal's derived end date (§2.23). */
export function formatWorkDay(day) {
  if (!isCalendarDay(day)) return '';
  const [y, m, d] = day.split('-').map(Number);
  return `${d} ${MONTHS[m - 1]} ${y}`;
}

/**
 * `until 1 Dec` beside the intent pill (§2.23) — day and month, the year
 * appended only when it is not this one. §10.3 caps the horizon at 180 days,
 * so the year is a boundary case rather than the usual one.
 */
export function formatUntil(until, today = todayUTC()) {
  if (!isCalendarDay(until)) return '';
  const [y, m, d] = until.split('-').map(Number);
  const sameYear = isCalendarDay(today) && today.slice(0, 4) === until.slice(0, 4);
  return `until ${d} ${MONTHS[m - 1]}${sameYear ? '' : ` ${y}`}`;
}

/**
 * `Mar 2026` on a vouch (§2.25). Every other time in this app is relative
 * because a post's recency is what matters; a vouch is the opposite — `2y ago`
 * buries the thing the reader is weighing.
 */
export function formatVouchDate(date) {
  const d = date instanceof Date ? date : new Date(date);
  if (Number.isNaN(d.getTime())) return '';
  return `${MONTHS[d.getMonth()]} ${d.getFullYear()}`;
}

/** §2.23's four verbatim intent strings. An intent outside §10.3's set has no copy and no pill. */
export const WORK_INTENT_LABELS = {
  work: 'Open to work',
  contract: 'Open to contract',
  hiring: 'Hiring',
  collab: 'Open to collaborate',
};

export function intentLabel(intent) {
  return WORK_INTENT_LABELS[intent] ?? '';
}

/**
 * §2.24's OPEN NOW order: end date ascending — soonest first — ties by
 * username ascending. Written down because three platforms otherwise produce
 * three orders, and because "what expires first" is derived from the data
 * rather than scored.
 */
export function orderByExpiry(rows) {
  return [...rows].sort((a, b) => {
    const byDate = String(a.work?.open?.until ?? '').localeCompare(String(b.work?.open?.until ?? ''));
    if (byDate) return byDate;
    return usernameKey(a.username).localeCompare(usernameKey(b.username));
  });
}

// ── attribution (PRODUCT §2.3) ─────────────────────────────────────────────

/**
 * The node a feed's posts reach me through: me when the feed is on my card,
 * else the earliest node in my `follows:` order whose card lists it, else
 * null (unattributed — the card falls back to the channel itself).
 * `cardFor(username)` returns a parsed card or null; pure, cache-agnostic.
 */
export function attributionNode(feedUsername, myUsername, myCard, cardFor) {
  if (!myCard) return null;
  const lists = (card) => card?.feeds?.some((f) => sameUsername(f, feedUsername)) ?? false;
  if (lists(myCard)) return myUsername;
  for (const u of myCard.follows ?? []) {
    if (lists(cardFor(u))) return u;
  }
  return null;
}

// ── links, counts, time ────────────────────────────────────────────────────

/** TDLib message ids are server ids shifted left 20 bits. */
export function serverMessageId(messageId) {
  return Math.floor(Number(messageId) / 1048576);
}

export function deepLink(username, messageId) {
  return `https://t.me/${username}/${serverMessageId(messageId)}`;
}

/**
 * The server id inside a t.me post link. `post.id` is NOT one thing across
 * this app — TDLib hands us a shifted id, the public preview parser hands us
 * the bare server id already (js/public/preview.js) — but `link` is built the
 * same way on both paths, so it is the only id the two agree on. §2.15's
 * `Message:` line and PROTOCOL §7's hidden key both come from here, which is
 * what stops one report naming two different messages.
 */
export function linkMessageId(link) {
  const key = targetKey(link);
  return key ? Number(key.slice(key.indexOf('/') + 1)) : null;
}

export function channelLink(username) {
  return `https://t.me/${username}`;
}

// ── public links (PRODUCT §2.13) ───────────────────────────────────────────

/**
 * The origin the public pages are served from — `publicOrigin` in
 * config.json, handed here once by boot() (js/app.js). Unset is the default
 * and the only state a fresh clone has: tgsocial is source you run, not a
 * service anyone hosts, so there is no canonical web host to hardcode and no
 * server every reader is guaranteed to have.
 *
 * With none configured, sharing hands out the t.me link instead. That link
 * works for everybody, costs nobody a deploy, and points at where the post
 * actually is — Telegram is the storage layer (PROTOCOL §1), so it is the
 * honest default rather than a degraded one.
 *
 * This is the one piece of mutable state in an otherwise pure module. The
 * alternative is threading an origin through every screen that has a `Copy
 * Link`, and the public screens have no config object to thread it from:
 * boot() enters public mode without building one (PRODUCT §2.13).
 */
let configuredOrigin = null;

/**
 * Take the origin from config, or refuse it. Scheme and host only — the public
 * routes are root-anchored (`parsePublicPath`, and nginx's SPA fallback under
 * them), so an origin carrying a path would mint links this very module cannot
 * read back. Absent, blank, a bare host, a `javascript:` URL: all refused, and
 * a refusal is not fatal, it just leaves sharing on t.me. Returns what it
 * accepted so the caller can say which of the two it got.
 */
export function setPublicOrigin(origin) {
  const s = typeof origin === 'string' ? origin.trim().replace(/\/+$/, '') : '';
  configuredOrigin = /^https?:\/\/[^/?#\s]+$/.test(s) ? s : null;
  return configuredOrigin;
}

/** The configured origin, or null when public links are t.me links. */
export function publicOrigin() {
  return configuredOrigin;
}

/** `<origin>/f/<channel>`, or `https://t.me/<channel>` — the link `Copy Link` copies for a channel. */
export function publicFeedUrl(username) {
  return configuredOrigin ? `${configuredOrigin}/f/${username}` : channelLink(username);
}

/** `<origin>/n/<node>`, or the node's own channel on t.me. */
export function publicNodeUrl(username) {
  return configuredOrigin ? `${configuredOrigin}/n/${username}` : channelLink(username);
}

/**
 * `<origin>/u/<name>` — the link `Copy Link` copies for a person — or the
 * person's node channel on t.me.
 *
 * Two usernames because the two branches answer different questions. `name` is
 * the handle the visitor arrived by, which may be a feed the resolver followed
 * a backlink from (PUBLIC §4); with an origin that is the right thing to mint,
 * because the reader on the other end resolves it again. With no origin there
 * is no reader to do that resolving, so the link has to name the person
 * itself, and the t.me analogue of a person is the node channel — its pinned
 * message *is* the card (PROTOCOL §3). Falling back to the arrival handle
 * would hand out one feed's channel, which is a different thing, and the exact
 * string `publicFeedUrl` already mints for it.
 */
export function publicPersonUrl(username, node = username) {
  return configuredOrigin ? `${configuredOrigin}/u/${username}` : channelLink(node);
}

/** Route name ↔ public path prefix (PRODUCT §2.13). */
const PUBLIC_PREFIX = { person: 'u', channel: 'f', node: 'n' };

/** `{ name, username }` → the pathname it lives at, e.g. `/u/tastycrow`. */
export function publicPath({ name, username }) {
  const prefix = PUBLIC_PREFIX[name];
  return prefix ? `/${prefix}/${username}` : '/';
}

/**
 * A `location.pathname` served by the SPA off nginx's index.html fallback:
 * `/u/<name>` → a person, `/f/<channel>` → the feed channel screen,
 * `/n/<node>` → the node profile. Anything else (including `/` and
 * `/index.html`) → null, and the hash router keeps the signed-in app exactly
 * as it was.
 *
 * Deliberately blind to the origin, and stays that way whatever
 * `setPublicOrigin` holds: a link minted by somebody else's deployment is
 * still a tgsocial link, and it has to open on the screen it names here.
 * Recognising a link and minting one are not the same question.
 *
 * Total on any string: a malformed percent-escape (`/f/%zz`) is a bad
 * username, not an exception. `decodeURIComponent` throws URIError on those,
 * and this is called from boot() before the app has a repo — a throw here is
 * a blank page — so the raw segment falls through to normaliseUsername and
 * routes exactly like `/f/bad-name`.
 */
export function parsePublicPath(pathname) {
  const m = /^\/(u|f|n)\/([^/?#]+)\/?$/.exec(String(pathname ?? ''));
  if (!m) return null;
  let raw;
  try {
    raw = decodeURIComponent(m[2]);
  } catch {
    raw = m[2];
  }
  const username = normaliseUsername(raw);
  if (!username) return null;
  return { name: { u: 'person', f: 'channel', n: 'node' }[m[1]], username };
}

/** 0 → "0", 1200 → "1.2k", 15000 → "15k", 2400000 → "2.4m". */
export function compactCount(n) {
  const v = Math.max(0, Math.floor(Number(n) || 0));
  const unit = (x, suffix) => {
    const s = x < 10 ? (Math.round(x * 10) / 10).toString() : Math.round(x).toString();
    return `${s}${suffix}`;
  };
  if (v < 1000) return String(v);
  if (v < 999500) return unit(v / 1000, 'k');
  if (v < 999500000) return unit(v / 1e6, 'm');
  return unit(v / 1e9, 'b');
}

const pad2 = (n) => String(n).padStart(2, '0');

/**
 * Relative time (PRODUCT §2.3): now (<60 s), Nm ago, Nh ago, Nd ago (<7 d),
 * Nw ago (<8 w), Nmo ago (<12 mo, 30-day months), Ny ago (365-day years).
 * Largest unit only, floor rounding. Derived, never hand-formatted.
 */
export function formatTime(date, now = new Date()) {
  const d = date instanceof Date ? date : new Date(date);
  const n = now instanceof Date ? now : new Date(now);
  const s = Math.max(0, Math.floor((n.getTime() - d.getTime()) / 1000));
  if (s < 60) return 'now';
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(s / 3600);
  if (h < 24) return `${h}h ago`;
  const days = Math.floor(s / 86400);
  if (days < 7) return `${days}d ago`;
  const w = Math.floor(days / 7);
  if (w < 8) return `${w}w ago`;
  const mo = Math.floor(days / 30);
  if (mo < 12) return `${mo}mo ago`;
  return `${Math.max(1, Math.floor(days / 365))}y ago`;
}

/** The exact timestamp for the post sheet (PRODUCT §2.3): yyyy-MM-dd HH:mm, local. */
export function formatExactTime(date) {
  const d = date instanceof Date ? date : new Date(date);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** Wall-clock HH:mm, local — status sheet rows (PRODUCT §2.10). */
export function formatClock(date) {
  const d = date instanceof Date ? date : new Date(date);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** Seconds → m:ss or h:mm:ss for media durations. */
export function formatDuration(seconds) {
  const s = Math.max(0, Math.floor(Number(seconds) || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  return h > 0 ? `${h}:${pad2(m)}:${pad2(r)}` : `${m}:${pad2(r)}`;
}

/** Extract FLOOD_WAIT seconds from a TDLib error, or null. */
export function floodWaitSeconds(error) {
  const msg = typeof error === 'string' ? error : error?.message ?? '';
  let m = /FLOOD_WAIT_(\d+)/.exec(msg);
  if (m) return Number(m[1]);
  m = /retry after (\d+)/i.exec(msg);
  if (m) return Number(m[1]);
  if (error && error.code === 429) return 5;
  return null;
}

// ── text entities ──────────────────────────────────────────────────────────

const ENTITY_FLAGS = {
  textEntityTypeBold: 'bold',
  textEntityTypeItalic: 'italic',
  textEntityTypeCode: 'code',
  textEntityTypePre: 'code',
  textEntityTypePreCode: 'code',
  textEntityTypeUrl: 'url',
  textEntityTypeTextUrl: 'textUrl',
  textEntityTypeMention: 'mention',
  textEntityTypeMentionName: 'mentionName',
};

/**
 * Flatten TDLib text entities into runs: [{ text, bold, italic, code, href, mention }].
 * Offsets are UTF-16 code units, which is what TDLib emits and what JS strings index.
 * Unknown entity types render as plain text.
 */
export function entityRuns(text, entities) {
  const s = typeof text === 'string' ? text : '';
  const list = Array.isArray(entities) ? entities : [];
  const known = list
    .map((e) => ({ e, flag: ENTITY_FLAGS[e?.type?.['@type']] }))
    .filter((x) => x.flag && Number.isFinite(x.e.offset) && Number.isFinite(x.e.length) && x.e.length > 0);
  if (!known.length) return s ? [{ text: s }] : [];
  const cuts = new Set([0, s.length]);
  for (const { e } of known) {
    cuts.add(Math.max(0, Math.min(s.length, e.offset)));
    cuts.add(Math.max(0, Math.min(s.length, e.offset + e.length)));
  }
  const points = [...cuts].sort((a, b) => a - b);
  const runs = [];
  for (let i = 0; i < points.length - 1; i += 1) {
    const start = points[i];
    const end = points[i + 1];
    if (end <= start) continue;
    const run = { text: s.slice(start, end) };
    for (const { e, flag } of known) {
      if (e.offset <= start && e.offset + e.length >= end) {
        if (flag === 'bold') run.bold = true;
        else if (flag === 'italic') run.italic = true;
        else if (flag === 'code') run.code = true;
        else if (flag === 'url') run.href = run.text;
        else if (flag === 'textUrl') run.href = e.type.url;
        else if (flag === 'mention') run.mention = run.text.replace(/^@/, '');
        else if (flag === 'mentionName') run.mentionUserId = e.type.user_id;
      }
    }
    runs.push(run);
  }
  return runs;
}

// ── message filtering ──────────────────────────────────────────────────────

export const RENDERABLE_CONTENT = new Set([
  'messageText',
  'messagePhoto',
  'messageVideo',
  'messageAnimation',
  'messageDocument',
  'messageAudio',
  // PRODUCT §2.11: everything a post can carry renders in the app; the rest are summarised
  'messageVoiceNote',
  'messageVideoNote',
  'messageSticker',
  'messageAnimatedEmoji',
  'messagePoll',
  'messageLocation',
  'messageVenue',
  'messageContact',
]);

/** A message is a post if its content is renderable and it is not a card. */
export function isPost(message, cardMessageId = null) {
  if (!message || !message.content) return false;
  if (!RENDERABLE_CONTENT.has(message.content['@type'])) return false;
  if (cardMessageId !== null && message.id === cardMessageId) return false;
  if (message.content['@type'] === 'messageText' && cardVersion(message.content.text?.text) !== null) return false;
  return true;
}

// ── feed merge (PROTOCOL §4.8) ─────────────────────────────────────────────

/**
 * k-way merge by date desc across sources with independent cursors.
 *
 *   const m = createMerge(['a', 'b']);
 *   pushMessages(m, 'a', msgsFromA);   // newest-first arrays, as TDLib returns
 *   markExhausted(m, 'b');              // getChatHistory returned nothing
 *   const { items, blockedOn } = takeNext(m, 20);
 *
 * A head item is only emitted when no other live source could still produce
 * something newer: each source's `lastDate` (oldest fetched) bounds what its
 * next fetch can return. `refillCandidate` picks the empty source whose last
 * known item is newest, per the protocol's "load more" rule.
 */
export function createMerge(keys) {
  const sources = {};
  for (const key of keys) {
    sources[key] = { key, buffer: [], cursor: 0, lastDate: Infinity, fetched: false, exhausted: false };
  }
  return { sources, seen: new Set() };
}

export function pushMessages(merge, key, messages) {
  const src = merge.sources[key];
  if (!src) return;
  src.fetched = true;
  let added = 0;
  for (const msg of messages ?? []) {
    const id = `${key}:${msg.id}`;
    if (merge.seen.has(id)) continue;
    merge.seen.add(id);
    src.buffer.push({ key, id: msg.id, date: msg.date, message: msg });
    added += 1;
    if (src.cursor === 0 || msg.id < src.cursor) src.cursor = msg.id;
    if (msg.date < src.lastDate) src.lastDate = msg.date;
  }
  src.buffer.sort((a, b) => b.date - a.date || b.id - a.id);
  if (!messages || messages.length === 0 || added === 0) src.exhausted = true;
}

export function markExhausted(merge, key) {
  const src = merge.sources[key];
  if (!src) return;
  src.fetched = true;
  src.exhausted = true;
  if (src.lastDate === Infinity) src.lastDate = -Infinity;
}

/** Live = could still produce items on a refetch. */
function liveEmpty(merge) {
  return Object.values(merge.sources).filter((s) => !s.exhausted && s.buffer.length === 0);
}

export function refillCandidate(merge) {
  const empties = liveEmpty(merge);
  if (!empties.length) return null;
  empties.sort((a, b) => b.lastDate - a.lastDate);
  return empties[0].key;
}

export function isExhausted(merge) {
  return Object.values(merge.sources).every((s) => s.exhausted && s.buffer.length === 0);
}

export function takeNext(merge, count) {
  const items = [];
  while (items.length < count) {
    const empties = liveEmpty(merge);
    const bound = empties.length ? Math.max(...empties.map((s) => s.lastDate)) : -Infinity;
    let best = null;
    for (const src of Object.values(merge.sources)) {
      const head = src.buffer[0];
      if (!head) continue;
      if (!best || head.date > best.date || (head.date === best.date && head.id > best.id)) best = head;
    }
    if (!best) return { items, blockedOn: empties.length ? refillCandidate(merge) : null };
    if (best.date < bound) return { items, blockedOn: refillCandidate(merge) };
    merge.sources[best.key].buffer.shift();
    items.push(best);
  }
  return { items, blockedOn: null };
}

/** TDLib groups album items by `media_album_id` ("0" when the message is on its own). */
export function albumId(message) {
  const id = message?.media_album_id;
  if (id === undefined || id === null) return null;
  const s = String(id);
  return s === '0' || s === '' ? null : s;
}

/**
 * After takeNext emitted `item`, pull the rest of its album off the same source
 * without re-checking the date bound: album items share a source and a date
 * (within seconds), and the bound already admitted the first of them. Returns
 * the extra items, newest first, or [] when the item is not part of an album.
 */
export function takeAlbumRest(merge, item) {
  const album = albumId(item?.message);
  if (!album) return [];
  const src = merge.sources[item.key];
  const out = [];
  while (src && src.buffer.length && albumId(src.buffer[0].message) === album) out.push(src.buffer.shift());
  return out;
}

/**
 * Group consecutive merge items of one source that share an album id into
 * [{ key, items }] groups (a lone message is a group of one). Items inside a
 * group are put in posting order (id ascending) so a viewer swipes through the
 * album the way it was sent; the groups themselves keep the merge's
 * newest-first order, keyed on the album's newest message.
 */
export function groupAlbums(items) {
  const groups = [];
  for (const item of items ?? []) {
    const album = albumId(item.message);
    const last = groups[groups.length - 1];
    if (album && last && last.album === album && last.key === item.key) {
      last.items.push(item);
      continue;
    }
    groups.push({ key: item.key, album, items: [item] });
  }
  for (const g of groups) g.items.sort((a, b) => a.id - b.id);
  return groups;
}

/** Strictly newest-first: every date ≥ the next one (ties broken by id desc). */
export function isNewestFirst(list, date = (p) => p.date, id = (p) => p.id ?? 0) {
  for (let i = 1; i < (list?.length ?? 0); i += 1) {
    const a = list[i - 1];
    const b = list[i];
    if (date(a) < date(b)) return false;
    if (date(a) === date(b) && id(a) < id(b)) return false;
  }
  return true;
}

/** Index at which a new post (date, id) slots into a newest-first list. */
export function insertIndex(list, date, id = 0) {
  let i = 0;
  while (i < list.length && (list[i].date > date || (list[i].date === date && (list[i].id ?? 0) >= id))) i += 1;
  return i;
}

/**
 * Bound the in-memory feed window (PRODUCT §2.3).
 *
 * An infinite scroll that keeps every post it has ever loaded is a memory leak
 * with a nice animation: a few hundred cards, their models, and every picture
 * bound to them stay live until the tab is killed. This keeps `max` entries of
 * a newest-first list and drops the rest off whichever end is furthest from
 * what the reader is looking at.
 *
 * `from: 'head'` (the default) is the load-more case: another page has just
 * landed at the bottom, which is where the reader is, so the oldest-held
 * entries — the newest posts, already scrolled past — come off the top.
 * `from: 'tail'` is the live-insert case: a new post has landed at the top,
 * and trimming the head there would delete the very post that just arrived,
 * so the bottom of the window goes instead.
 *
 * Order is untouched either way (the survivors are a contiguous newest-first
 * run) and pagination is unaffected: the feed session's per-source cursors
 * live outside this list, so the next page still starts where the last one
 * ended. The cold-start cache keeps its own copy of the true newest posts.
 *
 * Returns { posts, dropped }.
 */
export function trimFeedWindow(posts, max, { from = 'head' } = {}) {
  const list = Array.isArray(posts) ? posts : [];
  if (!(max > 0) || list.length <= max) return { posts: list, dropped: 0 };
  const dropped = list.length - max;
  return from === 'tail'
    ? { posts: list.slice(0, max), dropped }
    : { posts: list.slice(dropped), dropped };
}

/** Compact, serialisable cursor snapshot (PROTOCOL §6: discardable). */
export function mergeCursors(merge) {
  const out = {};
  for (const s of Object.values(merge.sources)) out[s.key] = { cursor: s.cursor, exhausted: s.exhausted };
  return out;
}

// ── discovery ranking (PROTOCOL §5.1) ──────────────────────────────────────

/**
 * cardsByUsername: Map<lowercase username, card> for the nodes I follow.
 * Returns [{ username, mutual, via: [follower usernames] }] at distance 2,
 * ranked by how many of my follows list them; excludes me and my follows.
 */
export function rankPlusOne(myUsername, myFollows, cardsByUsername) {
  const exclude = new Set([usernameKey(myUsername), ...myFollows.map(usernameKey)]);
  const tally = new Map();
  for (const follow of myFollows) {
    const card = cardsByUsername.get(usernameKey(follow));
    if (!card) continue;
    for (const u of card.follows) {
      const k = usernameKey(u);
      if (exclude.has(k)) continue;
      const entry = tally.get(k) ?? { username: u, mutual: 0, via: [] };
      entry.mutual += 1;
      entry.via.push(follow);
      tally.set(k, entry);
    }
  }
  return [...tally.values()].sort((a, b) => b.mutual - a.mutual || usernameKey(a.username).localeCompare(usernameKey(b.username)));
}
