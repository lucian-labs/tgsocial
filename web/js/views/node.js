/* PRODUCT §2.5 Node profile. */
import { h, button, kebabMenu, replace, sectionMark } from '../../vendor/house-pour.js';
import { channelLink, hasBacklink, publicNodeUrl, usernameKey, isFollowing } from '../protocol.js';
import { avatarFor, copyLink, feedRow, nodeRow, emptyCard, openExternal, openTelegram } from './shared.js';
import { blockedProfile, confirmBlock, isMyNode } from './safety.js';
import { userMessage } from '../repo.js';

export function render(app, { username }) {
  // PRODUCT §2.16 — a blocked node is nothing anywhere else, but a profile
  // reached deliberately (a t.me link, a public URL, an exact-username search)
  // would read as a broken app if it were empty, so it says what happened.
  if (app.safety.isBlocked(username)) return blockedProfile(app, username);
  const root = h('div');
  const cached = app.repo.cachedCard(username);
  if (cached?.card) paint(cached);
  else root.append(h('div.card', h('p.muted', 'Loading…')));

  app.busy(app.repo.readNode(username, { force: true })).then((entry) => {
    if (!entry?.card) {
      replace(root, emptyCard(entry?.newer ? 'Newer card. Update the app.' : 'Not a tgsocial node.', `@${username} has no tgsocial card pinned.`));
      return;
    }
    paint(entry);
  }).catch((e) => {
    // a failed read is not a verdict on the node; the cached profile (if any) stays painted
    if (!cached?.card) replace(root, emptyCard("Couldn't read this node.", e.message));
  });

  function paint(entry) {
    const card = entry.card;
    const name = card.name || entry.title || `@${entry.username}`;
    const isMe = app.repo.myNode && usernameKey(entry.username) === usernameKey(app.repo.myNode.username);
    const head = h('div.card.profile-head',
      h('div.head-actions', nodeMenu(app, entry.username)),
      avatarFor(app, name, entry.photo, 'profile'),
      h('h1', name),
      h('span.mono', `@${entry.username}`),
      card.bio ? h('p.muted', card.bio) : null,
      card.link ? h('p', h('a', { href: safeUrl(card.link), target: '_blank', rel: 'noopener noreferrer' }, displayUrl(card.link))) : null,
    );
    if (!isMe && app.repo.myNode) head.append(followToggle(app, entry.username));
    else if (!app.repo.myNode) head.append(h('p.muted.small', 'Make your node to follow people.'));

    const feeds = h('div.card');
    if (!card.feeds.length) feeds.append(h('p.muted', 'No feeds listed.'));
    for (const f of card.feeds) {
      const row = feedRow(app, { title: `@${f}`, username: f });
      feeds.append(row);
      // resolve title + Verified pill lazily
      app.repo.feedInfo(f).then((info) => {
        const verified = hasBacklink(info.description, entry.username);
        row.replaceWith(feedRow(app, { title: info.title, username: info.username, verified }));
      }).catch(() => null);
    }

    const follows = h('div.card');
    // §2.18: a blocked node leaves no gap and no residue in a count, so the
    // list and the mark below are both drawn from what survives the filter
    const shownFollows = card.follows.filter((u) => !app.safety.isBlocked(u));
    if (!shownFollows.length) follows.append(h('p.muted', 'Follows no one yet.'));
    for (const u of shownFollows) {
      const cachedU = app.repo.cachedCard(u);
      const row = nodeRow(app, cachedU?.card ? cachedU : { username: u, title: null, card: null, photo: null }, { showFollow: false });
      follows.append(row);
      if (!cachedU?.card) {
        app.repo.readNode(u).then((e) => {
          if (e?.card && row.isConnected) row.replaceWith(nodeRow(app, e, { showFollow: false }));
        }).catch(() => null);
      }
    }

    replace(root, head, sectionMark('Feeds'), feeds, sectionMark('Follows', shownFollows.length), follows);
  }

  return root;
}

/**
 * PRODUCT §2.5's kebab, the same component as the feed channel's (§2.6), with
 * §2.16's `Block` alongside the two share actions. `Copy Link` copies the
 * public `/n/` link when this deployment configured an origin, else the t.me
 * one — the same rule as everywhere else (§2.13).
 *
 * On my own profile the menu is the two share actions and nothing else:
 * §2.16 is about someone else, so there is no `Block @me` (js/views/safety.js).
 */
function nodeMenu(app, username) {
  const items = [
    { label: 'Open in Telegram', onSelect: () => openTelegram(app, channelLink(username)) },
    { label: 'Copy Link', onSelect: () => copyLink(app, publicNodeUrl(username)) },
  ];
  if (!isMyNode(app, username)) items.push({ label: `Block @${username}`, onSelect: () => confirmBlock(app, username) });
  return kebabMenu(items, { label: `More for @${username}` });
}

function followToggle(app, username) {
  const paintBtn = () => {
    const f = isFollowing(app.repo.myCard, username);
    btn.textContent = f ? 'Unfollow' : 'Follow';
    btn.classList.toggle('primary', !f);
    btn.classList.toggle('ghost', f);
  };
  const btn = button('Follow', {
    style: 'primary',
    onClick: async () => {
      const was = isFollowing(app.repo.myCard, username);
      btn.disabled = true;
      try {
        if (was) await app.repo.unfollow(username);
        else await app.repo.follow(username);
        app.feedDirty = true;
      } catch (e) {
        app.toast(userMessage(e, "Couldn't update your card."), 'bad');
      } finally {
        btn.disabled = false;
        paintBtn();
      }
    },
  });
  paintBtn();
  app.onLeave(app.repo.subscribe((what) => {
    if (what === 'card') paintBtn();
  }));
  return btn;
}

function safeUrl(u) {
  return /^https?:\/\//i.test(u) ? u : `https://${u}`;
}

function displayUrl(u) {
  return u.replace(/^https?:\/\//i, '').replace(/\/$/, '');
}

export { openExternal };
