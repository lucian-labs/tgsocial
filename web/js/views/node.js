/* PRODUCT §2.5 Node profile. */
import { h, button, replace, sectionMark } from '../../vendor/house-pour.js';
import { hasBacklink, usernameKey, isFollowing } from '../protocol.js';
import { avatarFor, feedRow, nodeRow, emptyCard, openExternal } from './shared.js';
import { userMessage } from '../repo.js';

export function render(app, { username }) {
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
    if (!card.follows.length) follows.append(h('p.muted', 'Follows no one yet.'));
    for (const u of card.follows) {
      const cachedU = app.repo.cachedCard(u);
      const row = nodeRow(app, cachedU?.card ? cachedU : { username: u, title: null, card: null, photo: null }, { showFollow: false });
      follows.append(row);
      if (!cachedU?.card) {
        app.repo.readNode(u).then((e) => {
          if (e?.card && row.isConnected) row.replaceWith(nodeRow(app, e, { showFollow: false }));
        }).catch(() => null);
      }
    }

    replace(root, head, sectionMark('Feeds'), feeds, sectionMark('Follows', card.follows.length), follows);
  }

  return root;
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
