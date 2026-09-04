/* PRODUCT §2.7 Graph — Your network canvas + Direct + +1 lists. */
import { h, replace, sectionMark } from '../../vendor/house-pour.js';
import { mount } from '../graph.js';
import { nodeRow, emptyCard } from './shared.js';

export function render(app) {
  const root = h('div');
  if (!app.repo.myNode) {
    root.append(emptyCard('Nothing here yet.', 'Make your node and follow people to see your network.', { label: 'Set Up', onClick: () => app.navigate('#/setup') }));
    return root;
  }
  const canvas = h('canvas.graph-canvas', { tabindex: 0, 'aria-label': 'Your network graph. Enter opens the first node you follow.' });
  const graphCard = h('div.card.graph-card', canvas);
  // §2.18 — a blocked node is not in `DIRECT · 12`, not in the list under it and
  // not a dot on the canvas. Blocking never touches the card (§2.16), so they
  // are still followed publicly; they are simply not drawn here.
  const following = (app.repo.myCard?.follows ?? []).filter((u) => !app.safety.isBlocked(u));
  const directMark = sectionMark('Direct', following.length);
  const directList = h('div.card');
  const plusMark = sectionMark('+1', 0);
  const plusList = h('div.card', h('p.muted', 'Loading…'));
  root.append(sectionMark('Your network'), graphCard, directMark, directList, plusMark, plusList);

  const me = { username: app.repo.myNode.username, name: app.repo.myCard?.name || app.repo.myNode.username };
  const follows = following.map((u) => ({ username: u, name: app.repo.cachedCard(u)?.card?.name || u }));
  const graph = mount(canvas, {
    me,
    follows,
    plus: [],
    onTap: (n) => app.navigate(`#/node/${n.username}`),
  });
  app.onLeave(() => graph.destroy());

  if (!follows.length) replace(directList, h('p.muted', 'Follow someone and they appear here.'));
  else {
    replace(directList, follows.map((f) => {
      const cached = app.repo.cachedCard(f.username);
      return nodeRow(app, cached?.card ? cached : { username: f.username, title: null, card: null, photo: null });
    }));
  }

  app.busy(app.repo.nearby()).then((ranked) => {
    if (!root.isConnected) return;
    plusMark.querySelector('.mark-count').textContent = String(ranked.length);
    if (!ranked.length) replace(plusList, h('p.muted', 'Follow someone and their people appear here.'));
    else replace(plusList, ranked.map((r) => nodeRow(app, r.entry, { mutual: r.mutual })));
    // re-render direct rows now that cards are cached (names, feed counts)
    if (follows.length) {
      replace(directList, follows.map((f) => {
        const cached = app.repo.cachedCard(f.username);
        return nodeRow(app, cached?.card ? cached : { username: f.username, title: null, card: null, photo: null });
      }));
    }
    graph.update({
      follows: follows.map((f) => ({ ...f, name: app.repo.cachedCard(f.username)?.card?.name || f.name })),
      plus: ranked.map((r) => ({ username: r.username, name: r.entry?.card?.name || r.username, via: r.via })),
    });
  }).catch(() => {
    if (root.isConnected) replace(plusList, h('p.muted', 'Follow someone and their people appear here.'));
  });

  return root;
}
