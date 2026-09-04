/* safety.js — report, block and mute (PRODUCT §2.15–§2.17), everywhere they
 * are reachable.
 *
 * There is no server to report to (PROTOCOL §1), so a report is two separate
 * things that must not be confused: an email the reader's own mail client
 * sends to the published address (§2.19), and a local hide that happens the
 * moment Send Report is tapped. The second does not wait on the first — the
 * app cannot know whether a composer sent anything, and the reader has already
 * said they do not want to see it (§2.15).
 *
 * Everything here works signed out as well as signed in, because the lists are
 * the device's and the public routes (§2.13) render the same post cards. The
 * one thing that needs an identity is Block, which needs an attributed node
 * (§2.3) — so it appears where there is one and nowhere else.
 */
import { avatar, button, confirm, h, modal, sectionMark } from '../../vendor/house-pour.js';
import { linkMessageId, sameUsername } from '../protocol.js';
import { CONTACT_ADDRESS, REPORT_REASONS, mailtoUrl, reportBody, reportSubject } from '../moderation.js';
import { APP_BUILD, APP_VERSION } from '../td.js';
import { REPORT_PREFACE } from '../demo/mode.js';

/** §2.15's `App:` line: the You footer's version string plus the platform. */
export function appVersionLine() {
  return `tgsocial ${APP_VERSION} (${APP_BUILD}) · Web`;
}

/**
 * A post as a report/block/mute subject.
 *
 * `messageId` is read out of the link, never out of `post.id`: signed in that
 * id is TDLib's shifted one, on a public route (§2.13) it is already the bare
 * server id, and §2.15 works on both. The link is the one field both paths
 * build the same way — and the one the hide is keyed by — so deriving from it
 * is what keeps the email's `Link:` and `Message:` lines about one message.
 */
export function postSubject(post) {
  return {
    kind: 'post',
    link: post.link,
    channel: post.username,
    channelTitle: post.title || `@${post.username}`,
    messageId: linkMessageId(post.link),
    node: post.node ?? null,
    mine: false,
  };
}

/** A comment as one. No feed to mute: a comment is not a channel's post (§2.17). */
export function commentSubject(comment) {
  return {
    kind: 'comment',
    link: comment.link,
    channel: comment.channel,
    channelTitle: comment.name || `@${comment.channel}`,
    messageId: linkMessageId(comment.link),
    node: comment.node ?? null,
    mine: !!comment.mine,
  };
}

/**
 * Hand the reader's own mail client a prefilled message (§2.15). A browser
 * never reports back whether a `mailto:` was handled — which is exactly why
 * hiding is unconditional — so the only failure this can see is the one the
 * DOM raises, and that is the branch §2.15 calls "the composer refuses".
 */
export function openMailComposer(url) {
  try {
    const a = h('a', { href: url, rel: 'noopener' });
    document.body.append(a);
    a.click();
    a.remove();
    return true;
  } catch {
    return false;
  }
}

/** §2.19 — the address, as a row that opens the composer. */
export function contactMailLink(text = CONTACT_ADDRESS) {
  return h('a', { href: `mailto:${CONTACT_ADDRESS}` }, text);
}

// ── report (PRODUCT §2.15) ─────────────────────────────────────────────────

/**
 * The report confirm: the seven reasons, single-select, `Send Report` disabled
 * until one is picked. Sending opens the composer, hides the thing here, and
 * closes — in that order, though only the hide is guaranteed to have happened.
 */
export function openReport(app, subject) {
  const isComment = subject.kind === 'comment';
  let chosen = null;
  let m = null;

  const send = button('Send Report', { style: 'danger', disabled: true });
  const rows = REPORT_REASONS.map((reason) => {
    const check = h('span.reason-check', { 'aria-hidden': 'true' }, '✓');
    const row = h('button.list-item.reason-row.hit-min', {
      type: 'button',
      role: 'radio',
      'aria-checked': 'false',
    }, h('span.reason-label', reason), check);
    row.addEventListener('click', () => {
      chosen = reason;
      for (const other of rows) other.setAttribute('aria-checked', String(other === row));
      send.disabled = false;
    });
    return row;
  });

  send.addEventListener('click', () => {
    if (!chosen) return;
    const body = reportBody({
      reason: chosen,
      link: subject.link,
      channel: subject.channel,
      messageId: subject.messageId,
      node: subject.node,
      kind: subject.kind,
      app: appVersionLine(),
    });
    // §2.22.2's one deviation from §2.15, and the only one
    const url = mailtoUrl(CONTACT_ADDRESS, reportSubject(chosen), app.demo ? `${REPORT_PREFACE}\n${body}` : body);
    const mailed = openMailComposer(url);
    // §2.15: hidden either way, and the toast names the address when the
    // composer never opened — a reader who cannot send must still know where
    app.safety.hide(subject.link, chosen);
    m.close();
    app.toast(mailed ? "Reported. It's hidden here now." : `No mail app. Write to ${CONTACT_ADDRESS}.`, mailed ? 'good' : 'bad');
  });

  m = modal([
    sectionMark('Report'),
    h('h2', isComment ? 'Report this comment.' : 'Report this post.'),
    h('p.muted', 'This sends an email from your mail app to the person who maintains tgsocial, with a link to it. It disappears from this device as soon as you send.'),
    sectionMark('Why'),
    h('div.card.reason-list', { role: 'radiogroup', 'aria-label': 'Why' }, rows),
    send,
    button('Cancel', { style: 'ghost', onClick: () => m.close() }),
  ], { label: 'Report' });
  return m;
}

// ── block (PRODUCT §2.16) ──────────────────────────────────────────────────

/**
 * §2.16 is written about somebody else — "Their posts and their comments
 * disappear… They are not told" — and there is no second party in blocking
 * yourself: it would empty your own feed and your own `DIRECT` list, tell
 * nobody, and mean nothing. So the row is not offered on your own posts, your
 * own comments or your own profile; there is nothing there to decide.
 *
 * A public page (§2.13) has no session and no node, so nothing is suppressed
 * there — which is right: a visitor reading /u/ is never their own node.
 */
export function isMyNode(app, username) {
  const mine = app.repo?.myNode?.username;
  return !!mine && !!username && sameUsername(mine, username);
}

/**
 * The block confirm. Nothing is written to the card and nothing is sent: a
 * tgsocial block is a line in a file on this device, which is why it can
 * promise the blocked node is not told.
 */
export async function confirmBlock(app, username) {
  const ok = await confirm({
    title: `Block @${username}?`,
    body: 'Their posts and their comments disappear from your feed, your threads, your graph, and search. They are not told. Undo it in Settings.',
    okLabel: 'Block',
    okStyle: 'danger',
  });
  if (!ok) return false;
  app.safety.block(username);
  app.toast(`Blocked @${username}.`, 'good');
  return true;
}

export function unblock(app, username) {
  app.safety.unblock(username);
  app.toast(`Unblocked @${username}.`, 'good');
}

// ── mute (PRODUCT §2.17) ───────────────────────────────────────────────────

/** No confirm: it is one tap to undo in the same two places. */
export function toggleMute(app, { username, title }) {
  const name = title || `@${username}`;
  if (app.safety.isMutedFeed(username)) {
    app.safety.unmuteFeed(username);
    app.toast(`Unmuted ${name}.`, 'good');
    return false;
  }
  app.safety.muteFeed(username);
  app.toast(`Muted ${name}.`, 'good');
  return true;
}

// ── the SAFETY block (PRODUCT §2.15) ───────────────────────────────────────

/**
 * The rows both sheets carry. `Report Post` / `Report Comment`, becoming
 * `Delete` on your own comment (§2.12 — you do not report yourself, you remove
 * it); `Block @node` only where the thing is attributed and the node is not
 * your own (§2.16); `Mute <feed>` on posts only.
 *
 * `onDelete` is supplied by the comment sheet, which owns the delete path.
 */
export function safetyBlock(app, subject, { close, onDelete = null } = {}) {
  const parts = [sectionMark('Safety')];
  if (subject.mine && onDelete) {
    parts.push(button('Delete', {
      style: 'danger',
      size: 'sm',
      onClick: () => {
        close?.();
        onDelete();
      },
    }));
  } else {
    parts.push(button(subject.kind === 'comment' ? 'Report Comment' : 'Report Post', {
      style: 'danger',
      size: 'sm',
      onClick: () => {
        close?.();
        openReport(app, subject);
      },
    }));
  }
  if (subject.node && !isMyNode(app, subject.node)) {
    parts.push(button(`Block @${subject.node}`, {
      style: 'ghost',
      size: 'sm',
      onClick: () => {
        close?.();
        confirmBlock(app, subject.node);
      },
    }));
  }
  if (subject.kind === 'post') {
    const muted = app.safety.isMutedFeed(subject.channel);
    parts.push(button(`${muted ? 'Unmute' : 'Mute'} ${subject.channelTitle}`, {
      style: 'ghost',
      size: 'sm',
      onClick: () => {
        close?.();
        toggleMute(app, { username: subject.channel, title: subject.channelTitle });
      },
    }));
  }
  return parts;
}

// ── the blocked node's own profile (PRODUCT §2.16) ─────────────────────────

/**
 * The one place a blocked node is drawn at all. Everywhere else they are
 * nothing — no tombstone, because a tombstone still reports how often they
 * post — but a profile reached deliberately (a t.me link, a public URL, an
 * exact-username search) would read as a broken app if it were empty.
 *
 * Their photo is not loaded: the avatar is the initial only.
 */
export function blockedProfile(app, username) {
  return h('div', h('div.card.profile-head.blocked-head',
    // the initial only: their photo is not loaded, which is the point
    avatar(`@${username}`, null, 'profile'),
    h('span.mono.muted', `@${username}`),
    h('h2', 'You blocked this node.'),
    h('p.muted', 'Nothing they post reaches you.'),
    button('Unblock', {
      style: 'ghost',
      // one tap, no confirm — and the profile it was standing in for paints on
      // the next render, which the list change triggers on its own
      onClick: () => unblock(app, username),
    }),
  ));
}
