/* PRODUCT §2.6 Feed channel — header + that channel's posts, newest first.
 *
 * Doubles as the public-link screen (PRODUCT §2.13): the same screen, with a
 * `Copy Link` ghost sm in the header when the route came in as /f/<channel>.
 */
import { h, button, pill, replace } from '../../vendor/house-pour.js';
import { hasBacklink, publicFeedUrl } from '../protocol.js';
import { avatarFor, postCard, emptyCard, openInTelegramButton } from './shared.js';

const PAGE = 20;

export function render(app, { username }) {
  // the public lens: reached through /f/<channel> rather than a hash route
  const isPublic = !!app.route?.viaPath;
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
  });

  (async () => {
    let info;
    try {
      info = await app.busy(app.repo.feedInfo(username));
    } catch (e) {
      replace(root, emptyCard('Channel not found.', `@${username} is not a public channel.`));
      return;
    }
    if (!alive) return;
    // verified for any node that lists it: check my card and the cards I have cached
    const nodes = Object.values(app.repo.cards).filter((c) => c.card?.feeds?.some((f) => f.toLowerCase() === info.username.toLowerCase()));
    const verified = nodes.some((n) => hasBacklink(info.description, n.username));
    replace(head,
      avatarFor(app, info.title, info.photo, 'profile'),
      h('h2', info.title),
      h('span.mono', `@${info.username}`),
      info.description ? h('p.muted', info.description) : null,
      h('div.row',
        openInTelegramButton(info.username),
        isPublic ? copyLinkButton(app, info.username) : null,
        verified ? pill('Verified', 'gold') : null),
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

/** PRODUCT §2.13 Sharing — copies the tgsocial public link, not the t.me one. */
function copyLinkButton(app, username) {
  return button('Copy Link', {
    style: 'ghost',
    size: 'sm',
    ariaLabel: `Copy the link to @${username}`,
    onClick: async () => {
      try {
        await navigator.clipboard.writeText(publicFeedUrl(username));
        app.toast('Link copied.', 'good');
      } catch {
        app.toast("Couldn't copy the link.", 'bad');
      }
    },
  });
}
