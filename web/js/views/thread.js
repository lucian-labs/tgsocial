/* PRODUCT §2.12 Thread — the post, its comment tree from my network, and the
 * comment composer (PROTOCOL §6).
 *
 * The tree, the reply-target selection and the composer all live in
 * js/views/comments.js, because §2.12 says "the same selection behaviour
 * applies on the Thread screen; the carousel just hosts it over the media" —
 * there is one thread rendering, and this screen is one of its two hosts.
 * What belongs to this screen alone is the post card above it, the Refresh
 * ghost, resolving the deep link that got here, and leaving when the filter
 * takes the post out from under it (§2.18).
 */
import { h, button, replace } from '../../vendor/house-pour.js';
import { sameUsername, serverMessageId, targetKey } from '../protocol.js';
import { postCard, emptyCard } from './shared.js';
import { commentsPanel } from './comments.js';
import { releaseMedia } from '../media.js';

export function render(app, { username, serverId, compose = false }) {
  const root = h('div');
  // §2.18 names Thread among the screens that drop a reported or blocked post,
  // and §2.16 forbids putting anything in its place — a "content hidden" row is
  // the tombstone that section exists to refuse. A screen that is ABOUT one
  // post therefore has nothing left to be, so it leaves: report or block from
  // the sheet here and the repaint that follows (app.onSafetyChange) walks
  // back, exactly as it empties the feed behind the sheet everywhere else.
  //
  // Reported is decided from the route alone, before anything is fetched, so a
  // cold visit to a hidden thread never paints it at all. Blocked needs the
  // post's attributed node (§2.3), so it is asked again once the post is here.
  if (app.safety.isHidden(targetKey(`https://t.me/${username}/${serverId}`))) {
    // the seed belongs to the visit that is not happening; leaving it set
    // would hand it to whatever thread opens next
    app.threadSeed = null;
    app.back();
    return root;
  }
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
    // no `applyMute`: §2.18 mutes the main feed only, so a muted feed's post
    // still opens here, complete, exactly as it does on its channel screen
    if (!app.safety.keepsPost(post)) {
      app.back();
      return;
    }
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
