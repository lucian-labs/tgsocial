/* PRODUCT §2.12 Thread — the post, its comment tree from my network, and the
 * comment composer (PROTOCOL §6).
 *
 * The tree, the reply-target selection and the composer all live in
 * js/views/comments.js, because §2.12 says "the same selection behaviour
 * applies on the Thread screen; the carousel just hosts it over the media" —
 * there is one thread rendering, and this screen is one of its two hosts.
 * What belongs to this screen alone is the post card above it, the Refresh
 * ghost, and resolving the deep link that got here.
 */
import { h, button, replace } from '../../vendor/house-pour.js';
import { sameUsername, serverMessageId } from '../protocol.js';
import { postCard, emptyCard } from './shared.js';
import { commentsPanel } from './comments.js';
import { releaseMedia } from '../media.js';

export function render(app, { username, serverId, compose = false }) {
  const root = h('div');
  // web substitute for §2.12's pull-to-refresh re-scan, same Refresh ghost
  // pattern as the feed (§2.3); the repaint arrives via the 'comments' notification
  const toolbar = h('div.toolbar',
    button('Refresh', {
      style: 'ghost',
      size: 'sm',
      ariaLabel: 'Refresh comments',
      onClick: () => app.repo.refreshComments({ force: true }).catch(() => null),
    }));
  const postHost = h('div');
  const panelHost = h('div');
  root.append(toolbar, postHost, panelHost);
  replace(postHost, h('div.card', h('p.muted', 'Loading…')));

  let panel = null;
  let alive = true;
  app.onLeave(() => {
    alive = false;
    if (panel) panel.release();
    // players and picture bindings go with the screen (js/media.js)
    releaseMedia(root);
  });

  const seed = app.threadSeed;
  app.threadSeed = null;
  const seedMatches = seed && sameUsername(seed.username, username) && serverMessageId(seed.id) === serverId;

  (async () => {
    let post;
    try {
      post = seedMatches ? seed : await app.busy(app.repo.postByLink(username, serverId), `Loading @${username}`);
    } catch (e) {
      if (alive) replace(postHost, emptyCard('Post not found.', e.message));
      return;
    }
    if (!alive) return;
    replace(postHost, postCard(app, post, { thread: false }));
    panel = commentsPanel(app, post);
    replace(panelHost, panel);
    // §6.3: the thread refreshes its comment index when opened (each channel
    // read reports itself into the activity registry)
    app.repo.refreshComments({ force: true }).catch(() => null);
    if (compose && app.repo.myNode) panel.openComposer();
  })();

  return root;
}
