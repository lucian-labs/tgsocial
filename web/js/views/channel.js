/* PRODUCT §2.6 Feed channel — header + that channel's posts, newest first.
 *
 * The header's top-right corner carries the `Verified` gold pill (only when
 * the feed is backlinked, PROTOCOL §3) and, right of it, the kebab menu —
 * `Open in Telegram` and `Copy Link` (§2.13) live in there and nowhere else
 * on this screen.
 */
import { h, kebabMenu, pill, replace } from '../../vendor/house-pour.js';
import { hasBacklink, publicFeedUrl, channelLink } from '../protocol.js';
import { avatarFor, postCard, emptyCard, notFoundCard, openExternal } from './shared.js';
import { toggleMute } from './safety.js';
import { releaseMedia } from '../media.js';

const PAGE = 20;

export function render(app, { username }) {
  const root = h('div');
  const head = h('div.card.profile-head', h('p.muted', 'Loading…'));
  const list = h('div');
  const tail = h('div');
  root.append(head, list, tail);

  let session = null;
  let loading = false;
  let done = false;
  let alive = true;
  app.onLeave(() => {
    alive = false;
    // players and picture bindings go with the screen (js/media.js)
    releaseMedia(root);
  });

  (async () => {
    let info;
    try {
      info = await app.busy(app.repo.feedInfo(username));
    } catch (e) {
      replace(root, notFoundCard(username));
      return;
    }
    if (!alive) return;
    // verified for any node that lists it: check my card and the cards I have cached
    const nodes = Object.values(app.repo.cards).filter((c) => c.card?.feeds?.some((f) => f.toLowerCase() === info.username.toLowerCase()));
    const verified = nodes.some((n) => hasBacklink(info.description, n.username));
    replace(head,
      h('div.head-actions',
        verified ? pill('Verified', 'gold') : null,
        channelMenu(app, info)),
      avatarFor(app, info.title, info.photo, 'profile'),
      h('h2', info.title),
      h('span.mono', `@${info.username}`),
      info.description ? h('p.muted', info.description) : null,
    );

    session = app.repo.feedSession([info.username]);
    await more();
  })();

  async function more() {
    if (loading || done || !session) return;
    loading = true;
    replace(tail, h('div.loading-row.muted', 'Loading…'));
    try {
      const next = await session.loadMore(PAGE);
      if (!alive) return;
      for (const p of next) list.append(postCard(app, p));
      done = session.exhausted || next.length === 0;
      if (!list.childElementCount) replace(list, emptyCard('Nothing here yet.', 'This channel has no posts.'));
      replace(tail, done ? h('div.end-row.muted', "That's everything.") : h('div.loading-row.muted', 'Loading…'));
      if (!done) requestAnimationFrame(onScroll);
    } catch (e) {
      replace(tail, h('div.end-row.muted', `Couldn't load more. ${e.message}`));
    } finally {
      loading = false;
    }
  }

  const onScroll = () => {
    if (done || loading || !session) return;
    if (tail.getBoundingClientRect().top < window.innerHeight * 3) more();
  };
  window.addEventListener('scroll', onScroll, { passive: true });
  app.onLeave(() => window.removeEventListener('scroll', onScroll));

  return root;
}

/**
 * PRODUCT §2.6 — the header kebab. `Copy Link` copies the public link (§2.13),
 * the same one on public routes and signed-in alike: this deployment's
 * `/f/<channel>` when config.json names a `publicOrigin`, and the t.me link
 * when it does not — which is the default, since a clone of this repo is not
 * a web host until somebody makes it one.
 */
function channelMenu(app, { username, title }) {
  return kebabMenu([
    { label: 'Open in Telegram', onSelect: () => openExternal(channelLink(username)) },
    {
      label: 'Copy Link',
      onSelect: async () => {
        try {
          await navigator.clipboard.writeText(publicFeedUrl(username));
          app.toast('Link copied.', 'good');
        } catch {
          app.toast("Couldn't copy the link.", 'bad');
        }
      },
    },
    // §2.17 — the label reads the state, because the undo is the same tap in
    // the same place. This screen itself never changes: a muted feed stays
    // complete here, it just leaves the merged feed.
    {
      label: app.safety.isMutedFeed(username) ? 'Unmute Feed' : 'Mute Feed',
      onSelect: () => toggleMute(app, { username, title }),
    },
  ], { label: `More for @${username}` });
}
