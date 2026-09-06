/* PRODUCT §2.4 Explore — find a node, Nearby (+1), Directory. */
import { h, button, replace, sectionMark } from '../../vendor/house-pour.js';
import { normaliseUsername, usernameKey } from '../protocol.js';
import { nodeRow } from './shared.js';
import { capabilityMatches, capabilityRow } from './work.js';
import { userMessage } from '../repo.js';

export function render(app) {
  const root = h('div');

  const input = h('input', { type: 'search', placeholder: 'Find a node', 'aria-label': 'Find a node', autocomplete: 'off', spellcheck: false });
  const form = h('form', input);
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const u = normaliseUsername(input.value);
    if (!u) {
      app.toast('Not a tgsocial node.', 'bad');
      return;
    }
    input.disabled = true;
    try {
      const entry = await app.busy(app.repo.readNode(u, { force: true }));
      if (entry?.card) app.navigate(`#/node/${entry.username}`);
      else if (entry?.newer) app.toast('Newer card. Update the app.', 'bad');
      else app.toast('Not a tgsocial node.', 'bad');
    } catch (err) {
      // a read that failed is not a verdict on the node
      app.toast(userMessage(err), 'bad');
    } finally {
      input.disabled = false;
    }
  });
  root.append(form);

  /**
   * PRODUCT §2.24 — the same one search field, now also matching `work.does`
   * across every card this client has read. It is a local filter over a network
   * the reader assembled themselves, not search: `searchPublicChats` indexes
   * usernames and titles, never the contents of a pinned message
   * (PROTOCOL §10.7.2). The faint line under the section says exactly that,
   * permanently, because a search box that stays quiet about its reach is a
   * search box that lies about it.
   */
  const capHost = h('div');
  const paintCapabilities = () => {
    const q = input.value.trim();
    if (!q) {
      replace(capHost);
      return;
    }
    const rows = capabilityMatches(app, q);
    replace(capHost,
      sectionMark('What they do'),
      rows.length ? h('div.card', rows.map((r) => capabilityRow(app, r))) : h('div.card', h('p.muted', 'Nobody you can reach lists that.')),
      h('p.faint.small.cap-scope', 'Searches the cards you can reach — your network and the directory. There is no global search.'),
    );
  };
  input.addEventListener('input', paintCapabilities);

  const nearbyList = h('div.card', h('p.muted', 'Loading…'));
  const dirList = h('div.card', h('p.muted', 'Loading…'));
  root.append(capHost, sectionMark('Nearby'), nearbyList, sectionMark('Directory'), dirList);

  (async () => {
    const shown = new Set();
    if (!app.repo.myNode) {
      replace(nearbyList, h('p.muted', 'Follow someone and their people appear here.'));
    } else {
      try {
        const nearby = await app.busy(app.repo.nearby());
        if (!nearby.length) replace(nearbyList, h('p.muted', 'Follow someone and their people appear here.'));
        else {
          replace(nearbyList, nearby.map((r) => nodeRow(app, r.entry, { mutual: r.mutual })));
          for (const r of nearby) shown.add(usernameKey(r.username));
        }
      } catch (e) {
        replace(nearbyList, h('p.muted', 'Follow someone and their people appear here.'));
      }
    }
    try {
      const dir = await app.busy(app.repo.directory({ exclude: shown }));
      if (!dir.length) replace(dirList, h('p.muted', 'No nodes found. Be the first: make yours public.'));
      else replace(dirList, dir.map((entry) => nodeRow(app, entry)));
    } catch (e) {
      replace(dirList, h('p.muted', 'No nodes found. Be the first: make yours public.'));
    }
  })();

  return root;
}
