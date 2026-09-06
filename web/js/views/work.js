/* work.js — the work layer's surfaces (PRODUCT §2.23–§2.25, PROTOCOL §10).
 *
 * One module for every screen the extension touches, for the same reason
 * protocol.js keeps §10 in one block: delete this file and the four imports
 * that reach it, and the app is the app it was before — no card renders
 * differently, no feed loses a post, no route changes meaning. That is what
 * "additive" has to mean in the UI if it is going to mean anything in the
 * format.
 *
 * The one rule that is easy to lose here and expensive to lose: a claim about
 * somebody else lives in the claimant's channel and nowhere near the subject
 * (PROTOCOL §10.4). So nothing in this file writes to a node it does not own,
 * and every figure it prints is scoped to what this reader's own walk reached
 * and says so on the screen (§10.5).
 */
import { button, confirm, field, h, modal, pill, replace, sectionMark, tabs, toggle } from '../../vendor/house-pour.js';
import {
  WORK_DOES_MAX,
  WORK_ROLE_MAX,
  addDays,
  daysBetween,
  formatExactTime,
  formatUntil,
  formatVouchDate,
  formatWorkDay,
  intentLabel,
  isFollowing,
  openIsCurrent,
  sameUsername,
  todayUTC,
  usernameKey,
  workTag,
} from '../protocol.js';
import { userMessage } from '../repo.js';
import { attachSheet, avatarFor, emptyCard, followButton, openTelegram } from './shared.js';
import { isMyNode, safetyBlock, vouchSubject } from './safety.js';
import { openChannelCard } from './comments.js';

/** The horizons a writer is offered (PROTOCOL §10.3 — well inside the 180-day cap). */
const HORIZONS = [30, 60, 90];
/** §2.23's reminder window: the only nag in the app. */
const REMIND_DAYS = 7;
/** §2.24's "your network is small" line. */
const SMALL_NETWORK = 5;
/** §2.23's counter appears from here on, so the field is not permanently decorated. */
const ROLE_COUNTER_FROM = 60;

/**
 * The name a sentence about this person uses. §2.25 writes `Say one thing Ana
 * does.` from the node's `name`, so this is its first token — and `null` when
 * the card has no `name` at all, which is the branch §2.25 gives its own copy
 * to rather than inventing a pronoun the app does not know.
 */
export function firstName(entry) {
  const name = entry?.card?.name;
  if (typeof name !== 'string') return null;
  const first = name.trim().split(/\s+/)[0];
  return first || null;
}

export function displayName(entry) {
  return entry?.card?.name || entry?.title || `@${entry?.username}`;
}

/** `#/vouches/<node>/<tag>` — the tag is encoded because `c#` and `front of house` are tags (§10.2). */
export function vouchesHash(username, tag) {
  return `#/vouches/${username}/${encodeURIComponent(tag)}`;
}

// ── the work card on a profile (PRODUCT §2.23) ─────────────────────────────

/**
 * The work section of a node profile, or `[]` when the node has no work keys
 * AND no vouches this reader can reach (§2.23).
 *
 * Absent entirely, not empty: no section mark, no "not set up yet". A person
 * who never filled a work key has the profile they have today, which is the UI
 * half of the sentence PROTOCOL §10 opens with.
 *
 * The vouch half of the condition is §10.4 rather than a hedge: a vouch is the
 * voucher's sentence and the subject cannot edit it, including by editing their
 * own card. Gate on `work` alone and clearing your card deletes what somebody
 * else wrote about you — and hides it first from the person it is about, who is
 * who `VOUCHED, NOT CLAIMED` is for. §2.23 says so in as many words.
 */
export function workSection(app, entry) {
  const work = entry?.card?.work;
  const vouchTags = app.repo.vouchTags ? app.repo.vouchTags(entry.username) : new Map();
  if (!work && !vouchTags.size) return [];
  const isMe = isMyNode(app, entry.username);
  const claimed = work?.does ?? [];
  const parts = [sectionMark('Work')];

  const claim = h('div.work-claim');
  if (work?.role) claim.append(h('p.work-role', work.role));
  // §10.3 — the pill is drawn only while the intent is a statement about now.
  // An expired or over-the-horizon one is not greyed and not "was open until";
  // it is simply not there.
  if (openIsCurrent(work?.open, todayUTC())) {
    claim.append(h('div.work-open',
      // the one gold thing on this card. `Verified` means a feed backlink and
      // nothing else (PROTOCOL §10.8), so it never appears here.
      pill(intentLabel(work.open.intent), 'gold'),
      h('span.mono-small.faint', formatUntil(work.open.until)),
    ));
  }
  if (claim.childElementCount) parts.push(claim);

  if (claimed.length) parts.push(h('div.card', claimed.map((tag) => tagRow(app, entry, tag, vouchTags.get(tag) ?? 0))));

  // §10.4 — a vouch is the voucher's sentence and the subject cannot edit it,
  // including by editing their own card. So a tag nobody claimed still renders,
  // under its own heading, which is how a person finds out what they are known
  // for.
  const unclaimed = [...vouchTags.keys()].filter((tag) => !claimed.some((c) => c === tag));
  if (unclaimed.length) {
    parts.push(sectionMark('Vouched, not claimed'));
    parts.push(h('div.card', unclaimed.map((tag) => tagRow(app, entry, tag, vouchTags.get(tag) ?? 0))));
  }

  if (claimed.length && !vouchTags.size) {
    parts.push(isMe
      ? h('div.work-empty',
        h('p.muted', 'No vouches from your network yet.'),
        // uncomfortable and true (PROTOCOL §10.5): a client that omits this
        // implies a completeness it does not have
        h('p.faint.small', "Someone may have vouched for you outside it. You'd only see it if you can reach them."))
      : h('p.muted.work-empty', 'No vouches from your network.'));
  }

  if (!isMe && app.repo.myNode && !app.safety.isBlocked(entry.username)) {
    const short = firstName(entry);
    parts.push(button(`Vouch for ${short ?? `@${entry.username}`}`, { size: 'sm', onClick: () => openVouchModal(app, entry) }));
  }
  return parts;
}

/**
 * One capability row. A row with vouches taps through to §2.25; a row with
 * none is not a control at all — no chevron, no hit target, no press state,
 * because there is nothing behind it.
 */
function tagRow(app, entry, tag, count) {
  const text = h('div.row-text', h('div.row-name.work-tag-name', tag));
  const trail = h('div.row-trail');
  if (count > 0) {
    // §10.5 — a figure is allowed only when the reader can resolve it into
    // names in one step and it is labelled with its scope. `Vouched by 2` above
    // two names describes what this reader can see; `2 endorsements` would be a
    // claim about a world that does not exist here.
    trail.append(h('span.small.muted', `Vouched by ${count}`), h('span.chevron', { 'aria-hidden': 'true' }, '›'));
  }
  const row = h('div.list-item.work-tag', h('div.row-main', text), trail);
  if (count <= 0) return row;
  const go = () => app.navigate(vouchesHash(entry.username, tag));
  row.setAttribute('role', 'link');
  row.setAttribute('tabindex', '0');
  row.setAttribute('aria-label', `${tag} — vouched by ${count}`);
  row.classList.add('work-tag-link');
  row.addEventListener('click', go);
  row.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') go();
  });
  return row;
}

// ── OPEN NOW (PRODUCT §2.24) ───────────────────────────────────────────────

/**
 * Work mode leads with expiring intent, which is the mode's whole reason to
 * exist: the filter is the cheap half, and "who is open, soonest first" is the
 * half a chronological column cannot produce.
 */
export function openNowSection(app, rows, { follows = 0 } = {}) {
  const parts = [sectionMark('Open now', rows.length)];
  if (!rows.length) {
    const card = h('div.card', h('p.muted', 'Nobody in your network is open right now.'));
    if (follows < SMALL_NETWORK) card.append(h('p.faint.small', 'Your network is small. This reads the people you follow, and theirs.'));
    parts.push(card);
    return parts;
  }
  parts.push(h('div.card', rows.map((row) => openRow(app, row))));
  return parts;
}

function openRow(app, { entry, work, plusOne }) {
  const name = displayName(entry);
  const trail = h('div.row-trail', pill(intentLabel(work.open.intent), 'gold'));
  // the neutral +1 pill §2.12 uses, for the one hop this surface reaches past
  // the reader's own follows
  if (plusOne) trail.append(pill('+1'));
  trail.append(h('span.chevron', { 'aria-hidden': 'true' }, '›'));
  const tags = (work.does ?? []).slice(0, 3).join(', ');
  const sub = h('div.row-sub.work-open-sub', h('span.mono-small.faint', formatUntil(work.open.until)));
  if (tags) sub.append(h('span.work-open-tags', ` · ${tags}`));
  const row = h('div.list-item.node-row.work-open-row', { role: 'link', tabindex: 0, 'aria-label': `Open ${name}` },
    h('div.row-main', avatarFor(app, name, entry.photo, 'row'), h('div.row-text', h('div.row-name', name), sub)),
    trail,
  );
  const go = () => app.openNode(entry.username);
  row.addEventListener('click', go);
  row.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target === row) go();
  });
  return row;
}

// ── capability search in Explore (PRODUCT §2.24) ───────────────────────────

/**
 * A local filter over the cards this client has already read — the reader's
 * follows, their +1, and the directory §5 handed over. It is not search and
 * the screen says so: `searchPublicChats` indexes usernames and titles, never
 * the contents of a pinned message (PROTOCOL §10.7.2), so no client can honestly
 * offer capability search over the whole network.
 */
export function capabilityMatches(app, query) {
  const q = String(query ?? '').trim().toLowerCase();
  if (!q) return [];
  const me = app.repo.myNode?.username ?? null;
  const follows = app.repo.myCard?.follows ?? [];
  const out = [];
  for (const entry of Object.values(app.repo.cards ?? {})) {
    if (!entry?.card?.work?.does?.length) continue;
    if (me && sameUsername(entry.username, me)) continue;
    if (entry.card.public === false) continue; // rule 4: respected in every directory surface
    if (app.safety.isBlocked(entry.username)) continue;
    const hits = entry.card.work.does.filter((tag) => tag.includes(q));
    if (!hits.length) continue;
    const mutual = follows.filter((u) => app.repo.cachedCard(u)?.card?.follows?.some((f) => sameUsername(f, entry.username))).length;
    out.push({ entry, hits, mutual });
  }
  return out.sort((a, b) => b.mutual - a.mutual || usernameKey(a.entry.username).localeCompare(usernameKey(b.entry.username)));
}

export function capabilityRow(app, { entry, hits, mutual }) {
  const name = displayName(entry);
  const bits = [`@${entry.username}`, hits.join(', ')];
  if (mutual > 0) bits.push(`Followed by ${mutual} of yours`);
  const trail = h('div.row-trail');
  if (app.repo.myNode && !isMyNode(app, entry.username)) trail.append(followButton(app, entry.username));
  else trail.append(h('span.chevron', { 'aria-hidden': 'true' }, '›'));
  const row = h('div.list-item.node-row', { role: 'link', tabindex: 0, 'aria-label': `Open ${name}` },
    h('div.row-main', avatarFor(app, name, entry.photo, 'row'), h('div.row-text', h('div.row-name', name), h('div.row-sub', bits.join(' · ')))),
    trail,
  );
  const go = () => app.openNode(entry.username);
  row.addEventListener('click', go);
  row.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target === row) go();
  });
  return row;
}

// ── the Vouches screen (PRODUCT §2.25) ─────────────────────────────────────

export function renderVouches(app, { username, tag }) {
  const root = h('div');
  const paint = () => {
    const entry = app.repo.cachedCard(username) ?? { username, card: null, title: null, photo: null };
    const vouches = app.repo.vouchesFor(username, tag);
    const head = h('div.card.vouch-head', h('h1', tag), h('span.mono.muted', displayName(entry)));
    if (!vouches.length) {
      replace(root, head, emptyCard('No vouches from your network.', 'You see vouches written by people you can reach — you, who you follow, and theirs.'));
      return;
    }
    replace(root,
      head,
      sectionMark('Vouches', vouches.length),
      h('div.card.vouch-card', vouches.map((v) => vouchRow(app, v, entry))),
      // permanent, not an empty state: the scope is the thing a reader has to
      // know to weigh what they are looking at (PROTOCOL §10.5)
      h('p.faint.small.vouch-scope', 'Vouches from your network — you, who you follow, and theirs.'),
    );
  };
  paint();
  app.onLeave(app.repo.subscribe((what) => {
    if ((what === 'comments' || what === 'safety') && root.isConnected) paint();
  }));
  return root;
}

function vouchRow(app, vouch, subjectEntry) {
  const head = h('div.post-head',
    avatarFor(app, vouch.name, vouch.avatar, 'row'),
    h('div.post-head-text',
      h('button.post-title.hit-min', {
        type: 'button',
        'aria-label': `Open ${vouch.name}`,
        onclick: (e) => {
          e.stopPropagation();
          app.openNode(vouch.node);
        },
      }, h('span', vouch.name)),
      h('div.post-user', `@${vouch.node}`),
    ),
    // §2.25 — a month and a year, not a relative time. `2y ago` buries exactly
    // the thing the reader is weighing.
    h('div.post-time.vouch-date', formatVouchDate(new Date(vouch.date * 1000))),
  );
  if (!vouch.mine && !isFollowing(app.repo.myCard, vouch.node)) head.append(pill('+1'));
  const el = h('div.vouch', head);
  // an empty body renders the row alone (§2.25)
  if (vouch.body) el.append(h('div.post-body', vouch.body));
  attachSheet(el, () => openVouchSheet(app, vouch, subjectEntry));
  return el;
}

/**
 * §2.12's comment sheet with two strings changed. The muted line above SAFETY
 * appears on my own work card and says the true, uncomfortable thing: the
 * vouch is in somebody else's channel and I cannot reach it. That is the cost
 * of the guarantee that makes a vouch worth anything (PROTOCOL §10.4), and the
 * person paying it is the person who should be told.
 */
export function openVouchSheet(app, vouch, subjectEntry) {
  const row = (label, value) => h('div.list-item.sheet-row', h('span.sheet-label', label), h('span.sheet-value', value));
  const aboutMe = isMyNode(app, vouch.subject ?? subjectEntry?.username);
  let m = null;
  const remove = async () => {
    const ok = await confirm({ title: 'Delete this vouch?', okLabel: 'Delete', okStyle: 'danger' });
    if (!ok) return;
    try {
      await app.repo.deleteVouch(vouch);
    } catch (e) {
      app.toast(userMessage(e, "Couldn't delete this vouch."), 'bad');
    }
  };
  m = modal([
    sectionMark('Vouch'),
    h('div.sheet-rows',
      row('Posted', formatExactTime(new Date(vouch.date * 1000))),
      row('Node', `${vouch.name} · @${vouch.node}`),
      row('Feed', `@${vouch.channel}`),
    ),
    aboutMe && !vouch.mine ? h('p.muted.small', "You can't remove a vouch someone wrote. Report it or block them.") : null,
    ...safetyBlock(app, vouchSubject(vouch), { close: () => m.close(), onDelete: vouch.mine ? remove : null }),
    button('Open in Telegram', { onClick: () => openTelegram(app, vouch.link) }),
    button('Close', { style: 'ghost', onClick: () => m.close() }),
  ], { label: 'Vouch' });
  return m;
}

// ── writing one (PRODUCT §2.25) ────────────────────────────────────────────

export function openVouchModal(app, entry) {
  if (isMyNode(app, entry.username)) {
    // reachable only by a deep link, because the control does not exist on my
    // own profile — but the format's whole guarantee is this rule, so the
    // refusal is here and not only in the layout (PROTOCOL §10.4)
    app.toast("You can't vouch for yourself.", 'bad');
    return null;
  }
  const stage = h('div');
  const m = modal(stage, { label: 'Vouch' });
  // §2.25: the same channel as a comment, so the same card — not a second one
  // that says nearly the same thing (PROTOCOL §10.4)
  if (!app.repo.myCard?.replies) openChannelCard(app, m, stage, showForm);
  else showForm();

  function showForm() {
    const short = firstName(entry);
    const claimed = entry?.card?.work?.does ?? [];
    let selected = null;
    let custom = false;

    const chipRow = h('div.chip-row');
    const other = field(short ? `What ${short} does` : 'What they do', { type: 'text', autocomplete: 'off', spellcheck: false, maxlength: 24, placeholder: 'front of house' });
    other.wrap.hidden = true;
    const note = h('p.faint.small.vouch-note');
    const body = h('textarea', { rows: 4, placeholder: 'Why.', 'aria-label': 'Why', maxlength: 900 });
    const post = button('Post Vouch', { style: 'primary', type: 'submit', disabled: true });
    const cancel = button('Cancel', { style: 'ghost', onClick: () => m.close() });

    const repaint = () => {
      const tag = custom ? workTag(other.input.value) : selected;
      const already = tag ? app.repo.myVouch(entry.username, tag) : null;
      post.disabled = !tag || !!already;
      if (!tag && custom && other.input.value.trim()) note.textContent = 'Letters, numbers, spaces, and + # . - only.';
      else if (already) note.textContent = `You already vouched ${short ?? 'them'} for ${tag}.`;
      else if (!tag) note.textContent = 'Pick one thing.';
      else note.textContent = 'People who follow you will see it, and the people who follow them.';
    };

    const chips = [];
    const paintChips = () => {
      for (const chip of chips) {
        const mine = chip.tag ? app.repo.myVouch(entry.username, chip.tag) : null;
        const on = !mine && (chip.tag ? selected === chip.tag && !custom : custom);
        chip.el.textContent = mine ? 'Vouched' : chip.label;
        chip.el.classList.toggle('on', on);
        chip.el.classList.toggle('ghost', !!mine);
        chip.el.disabled = !!mine;
        chip.el.setAttribute('aria-pressed', String(on));
      }
    };
    const addChip = (label, tag) => {
      const el = h('button.pill.chip.hit-min', { type: 'button', 'aria-pressed': 'false' }, label);
      el.addEventListener('click', () => {
        if (tag) {
          selected = tag;
          custom = false;
          other.wrap.hidden = true;
        } else {
          custom = true;
          selected = null;
          other.wrap.hidden = false;
          setTimeout(() => other.input.focus(), 20);
        }
        paintChips();
        repaint();
      });
      chips.push({ el, label, tag });
      chipRow.append(el);
    };
    for (const tag of claimed) addChip(tag, tag);
    addChip('Something else', null);
    // §2.25 — a node with no `work.does` shows only `Something else`, with the
    // input already revealed: you can vouch for someone who has claimed nothing.
    if (!claimed.length) {
      custom = true;
      other.wrap.hidden = false;
    }
    other.input.addEventListener('input', repaint);
    paintChips();
    repaint();

    const form = h('form.compose', chipRow, other.wrap, body, h('div.btn-row', post, cancel), note);
    replace(stage,
      sectionMark('Vouch'),
      h('h2', short ? `Say one thing ${short} does.` : 'Say one thing they do.'),
      h('p.muted', `This goes in your comments channel, under your name. ${short ?? 'They'} can't edit it or take it down.`),
      form,
    );

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const tag = custom ? workTag(other.input.value) : selected;
      if (!tag) return;
      post.disabled = true;
      m.close();
      try {
        await app.repo.postVouch(entry.username, tag, body.value.trim());
        app.toast('Vouched.', 'good');
      } catch (err) {
        app.toast(userMessage(err, "Couldn't post your vouch."), 'bad');
      }
    });
  }
  return m;
}

// ── the Edit Card modal's work section (PRODUCT §2.23) ─────────────────────

/**
 * Returns `{ el, read }`. `read()` hands back `{ work, refusals }` — the work
 * card to write and the lines §2.23 prints under the fields when the grammar
 * dropped something (PROTOCOL §10.2: malformed values are dropped, never
 * fatal, and never invalidate the card).
 */
export function workFields(app, card) {
  const work = card?.work ?? null;
  const today = todayUTC();

  const role = field('Role', { type: 'text', value: work?.role ?? '', maxlength: WORK_ROLE_MAX });
  const roleNote = h('p.faint.small.work-note');
  const does = field('What you do', { type: 'text', value: (work?.does ?? []).join(', '), placeholder: 'swift, product architecture' });
  const doesNote = h('p.faint.small.work-note');

  const paintRoleCounter = () => {
    const n = role.input.value.length;
    roleNote.textContent = n >= ROLE_COUNTER_FROM ? `${n} / ${WORK_ROLE_MAX}` : '';
  };
  role.input.addEventListener('input', () => {
    // a paste over the cap keeps its first 80 and says so (§10.2's rule, on a
    // screen): the field is the cap, not a validator that fires later
    if (role.input.value.length > WORK_ROLE_MAX) {
      role.input.value = role.input.value.slice(0, WORK_ROLE_MAX);
      roleNote.textContent = 'Trimmed to 80.';
      return;
    }
    paintRoleCounter();
  });
  paintRoleCounter();

  const forHost = h('div');
  const storedIntent = work?.open?.intent ?? null;
  // The date the owner actually chose, kept so an unrelated edit writes it back
  // rather than a fresh one. PROTOCOL §10.3 is built on intent being re-asserted
  // or lapsing, and a Save that renews it silently — a bio typo, a feed toggle —
  // is `until 2099-01-01` arriving through the writer instead of the reader.
  const storedUntil = work?.open?.until ?? null;
  let intent = storedIntent;
  let horizon = HORIZONS[0];
  // touched only by a tap on FOR; the bucket below is the offer, not the answer
  let renewed = false;
  if (storedUntil) {
    const left = daysBetween(today, storedUntil);
    horizon = HORIZONS.find((d) => d >= left) ?? HORIZONS[HORIZONS.length - 1];
  }
  /**
   * The date this modal will write: the stored one while the intent is
   * untouched and no horizon was picked, and a fresh window as soon as either
   * changes. A new intent is a new claim and gets a new window; the same intent
   * left alone keeps the end date its owner set, expired or not (§10.6 — write
   * back what you read, which for an expired line means not resurrecting it).
   */
  const effectiveUntil = () => (
    !renewed && intent === storedIntent && storedUntil ? storedUntil : addDays(today, horizon)
  );
  const endsNote = h('p.faint.small.work-note');
  const paintEnds = () => {
    endsNote.textContent = intent ? `Ends ${formatWorkDay(effectiveUntil())}. After that it stops showing.` : '';
  };
  const paintFor = () => {
    if (!intent) {
      replace(forHost);
      paintEnds();
      return;
    }
    const bar = tabs(HORIZONS.map((d) => ({ id: String(d), label: `${d} days` })), String(horizon), (id) => {
      horizon = Number(id);
      renewed = true;
      paintEnds();
    });
    replace(forHost, h('label.field', 'For'), bar);
    paintEnds();
  };
  const openTabs = tabs([
    { id: 'none', label: 'Nothing' },
    { id: 'work', label: 'Work' },
    { id: 'contract', label: 'Contract' },
    { id: 'hiring', label: 'Hiring' },
    { id: 'collab', label: 'Collab' },
  ], intent ?? 'none', (id) => {
    intent = id === 'none' ? null : id;
    paintFor();
  });
  paintFor();

  // §10.2 — `work.feeds` entries must also be in `feeds:`, so the only things
  // markable are the channels already claimed (and §3 required post rights for
  // those). There is nothing here to introduce a channel with.
  const marked = new Set((work?.feeds ?? []).map(usernameKey));
  const feedsCard = h('div.card');
  const myFeeds = card?.feeds ?? [];
  if (!myFeeds.length) feedsCard.append(h('p.muted', 'You have no feeds yet.'));
  for (const f of myFeeds) {
    const t = toggle(marked.has(usernameKey(f)), (on) => {
      if (on) marked.add(usernameKey(f));
      else marked.delete(usernameKey(f));
    }, { label: `Mark @${f} as work` });
    feedsCard.append(h('div.list-item.work-feed-row', h('div.row-main', h('div.row-text', h('div.row-name', `@${f}`))), h('div.row-trail', t)));
  }

  const el = h('div.work-fields',
    sectionMark('Work'),
    h('p.muted', 'Optional. All of this is your own claim, the same as your bio. Nobody checks it and nothing here is verified.'),
    role.wrap,
    roleNote,
    does.wrap,
    h('p.faint.small.work-note', 'Up to twelve, separated by commas.'),
    doesNote,
    h('label.field', 'Open to'),
    openTabs,
    forHost,
    endsNote,
    sectionMark('Work feeds'),
    h('p.muted', 'Which of your feeds is work. The rest stay where they are.'),
    feedsCard,
  );

  const read = () => {
    const refusals = [];
    const kept = [];
    const seen = new Set();
    let dropped = null;
    for (const part of does.input.value.split(',')) {
      if (!part.trim()) continue;
      const tag = workTag(part);
      if (!tag) {
        if (!dropped) dropped = part.trim();
        continue;
      }
      if (seen.has(tag)) continue;
      seen.add(tag);
      kept.push(tag);
    }
    if (dropped) refusals.push(`Dropped "${dropped}". Letters, numbers, spaces, and + # . - only.`);
    if (kept.length > WORK_DOES_MAX) refusals.push('Twelve at most. The rest were dropped.');
    doesNote.textContent = refusals.join(' ');
    const next = {
      role: role.input.value.trim() || null,
      does: kept.slice(0, WORK_DOES_MAX),
      open: intent ? { intent, until: effectiveUntil() } : null,
      feeds: myFeeds.filter((f) => marked.has(usernameKey(f))),
    };
    const empty = !next.role && !next.does.length && !next.open && !next.feeds.length;
    return { work: empty ? null : next, refusals };
  };

  /**
   * §2.23 prints `Dropped "live/sound".` and `Twelve at most. The rest were
   * dropped.` on Save, and both were destroyed with the modal on the one path
   * that produces them — the card saved, the toast said so, and the reader
   * never learned a capability they typed is not on it. So the caller holds the
   * modal open when `read()` refused something and calls this, which rewrites
   * WHAT YOU DO to what actually went on the card: the note under the field
   * then describes the field, and a second Save has nothing left to refuse.
   */
  const settle = (written) => {
    does.input.value = (written?.does ?? []).join(', ');
  };

  return { el, read, settle };
}

// ── the expiry reminder (PRODUCT §2.23) ────────────────────────────────────

/**
 * The only nag in the app, and it nags about the one thing that goes stale on
 * its own: `work.open` expires whether or not anybody looks, and a person who
 * forgets is invisible without being told. One row, no badge, no red, on my
 * own You screen and nowhere else.
 */
export function expiryRow(app, onEdit) {
  const open = app.repo.myCard?.work?.open ?? null;
  if (!open) return null;
  const days = daysBetween(todayUTC(), open.until);
  if (days > REMIND_DAYS) return null;
  const label = intentLabel(open.intent);
  if (!label) return null;
  const text = days < 0
    ? `Your ${label} has ended.`
    : days === 0
      ? `Your ${label} ends today.`
      : `Your ${label} ends in ${days} ${days === 1 ? 'day' : 'days'}.`;
  return h('div.work-remind',
    h('span.muted', text),
    button('Edit Card', { style: 'ghost', size: 'sm', onClick: onEdit }),
  );
}
