/* PRODUCT §2.12 Thread — the post, its comment tree from my network, and the
 * comment composer (PROTOCOL §6). Comments live in each commenter's own
 * comments channel and point at their target with a `re:` link; the tree is
 * exactly the `re:` chains, depth capped at 5 (deeper renders flat).
 */
import { h, button, field, modal, confirm, pill, replace, sectionMark } from '../../vendor/house-pour.js';
import { normaliseUsername, sameUsername, isFollowing, formatTime, serverMessageId } from '../protocol.js';
import { userMessage } from '../repo.js';
import { postCard, avatarFor, renderEntities, emptyCard, openExternal } from './shared.js';
import { mediaBlocks, releaseMedia } from '../media.js';

const MAX_DEPTH = 5;

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
  const mark = h('div');
  const commentsHost = h('div');
  const actions = h('div');
  root.append(toolbar, postHost, mark, commentsHost, actions);
  replace(postHost, h('div.card', h('p.muted', 'Loading…')));

  let post = null;
  let pending = [];
  let alive = true;
  app.onLeave(() => {
    alive = false;
    // players and picture bindings go with the screen (js/media.js)
    releaseMedia(root);
  });

  const seed = app.threadSeed;
  app.threadSeed = null;
  const seedMatches = seed && sameUsername(seed.username, username) && serverMessageId(seed.id) === serverId;

  (async () => {
    try {
      post = seedMatches ? seed : await app.busy(app.repo.postByLink(username, serverId), `Loading @${username}`);
    } catch (e) {
      if (alive) replace(postHost, emptyCard('Post not found.', e.message));
      return;
    }
    if (!alive) return;
    replace(postHost, postCard(app, post, { thread: false }));
    paintComments();
    // §6.3: the thread refreshes its comment index when opened (each channel
    // read reports itself into the activity registry)
    app.repo.refreshComments({ force: true }).catch(() => null);
    if (compose && app.repo.myNode) openComposer(app, threadTarget(post), onOptimistic);
  })();

  function onOptimistic(temp) {
    pending.push(temp);
    paintComments();
    return {
      settle: () => {
        pending = pending.filter((p) => p !== temp);
        paintComments();
      },
    };
  }

  function paintComments() {
    if (!alive || !post) return;
    const { tree, count } = app.repo.commentThread(post.link);
    const total = count + pending.length;
    replace(mark, sectionMark('Comments', total));
    const parts = [];
    for (const nodeEl of tree.map((n) => commentEl(n, 0))) parts.push(nodeEl);
    for (const temp of pending) parts.push(commentBody(temp, 0, []));
    if (!parts.length) {
      replace(commentsHost, h('div.card', h('p.muted', 'No comments from your network yet.')));
    } else {
      replace(commentsHost, h('div.card.thread-card', parts));
    }
    const commentBtn = app.repo.myNode
      ? button('Comment', { style: 'primary', onClick: () => openComposer(app, threadTarget(post), onOptimistic) })
      : h('p.muted.small', 'Make your node to comment.');
    replace(actions, commentBtn);
  }

  function commentEl({ comment, children }, depth) {
    return commentBody(comment, depth, children);
  }

  function commentBody(comment, depth, children) {
    const header = h('div.post-head',
      avatarFor(app, comment.name, comment.avatar, 'row'),
      h('div.post-head-text',
        h('button.post-title.hit-min', {
          type: 'button',
          'aria-label': `Open ${comment.name}`,
          onclick: () => app.navigate(`#/node/${comment.node}`),
          // same shape as the post card's name (js/views/shared.js): the label
          // truncates in its span, the control keeps its 40pt overlay
        }, h('span', comment.name)),
        h('div.post-user', `@${comment.node}`),
      ),
      h('div.post-time', comment.pending ? '' : formatTime(new Date(comment.date * 1000))),
    );
    const parts = [header];
    // comments from nodes I don't follow (found via +1) carry a +1 pill
    if (!comment.pending && !comment.mine && !isFollowing(app.repo.myCard, comment.node)) {
      header.append(pill('+1'));
    }
    if (comment.text) parts.push(h('div.post-body', renderEntities(app, comment.text, comment.entities)));
    if (comment.media) parts.push(...mediaBlocks(app, comment, { openExternal }));

    const meta = h('div.comment-meta');
    if (comment.pending) {
      meta.append(h('span.comment-pending', 'Posting…'));
    } else {
      if (children.length) meta.append(h('span.comment-replies', `${children.length} ${children.length === 1 ? 'reply' : 'replies'}`));
      meta.append(button('Reply', {
        style: 'ghost',
        size: 'sm',
        ariaLabel: `Reply to ${comment.name}`,
        onClick: () => openComposer(app, commentTarget(comment), onOptimistic),
      }));
      if (comment.mine) {
        meta.append(button('Delete', {
          style: 'ghost',
          size: 'sm',
          ariaLabel: 'Delete this comment',
          onClick: async () => {
            const ok = await confirm({ title: 'Delete this comment?', okLabel: 'Delete', okStyle: 'danger' });
            if (!ok) return;
            try {
              await app.repo.deleteComment(comment);
            } catch (e) {
              app.toast(userMessage(e, "Couldn't delete this comment."), 'bad');
            }
          },
        }));
      }
    }
    parts.push(meta);

    const el = h('div.comment', parts);
    if (children.length) {
      // replies indent one level; depth caps at 5, deeper shows flat (§2.12)
      const kids = h(depth + 1 < MAX_DEPTH ? 'div.comment-children' : 'div.comment-children.flat',
        children.map((c) => commentEl(c, Math.min(depth + 1, MAX_DEPTH - 1))));
      el.append(kids);
    }
    return el;
  }

  app.onLeave(app.repo.subscribe((what) => {
    if (what === 'comments') paintComments();
  }));

  return root;
}

function snippet(text, max = 64) {
  const t = String(text ?? '').replace(/\s+/g, ' ').trim();
  if (!t) return '';
  return t.length > max ? `${t.slice(0, max).trimEnd()}…` : t;
}

function threadTarget(post) {
  return { link: post.link, title: post.title || `@${post.username}`, text: post.text };
}

function commentTarget(comment) {
  return { link: comment.link, title: comment.name, text: comment.text };
}

/**
 * The comment composer (PRODUCT §2.12): a muted quote line of the target,
 * `Say it.`, Post + Cancel. First comment ever, the modal first shows the
 * comments-channel card; on success the composer proceeds. `onOptimistic`
 * receives the temporary comment and returns { settle } to remove it.
 */
export function openComposer(app, target, onOptimistic) {
  const stage = h('div');
  const m = modal(stage, { label: 'Comment' });
  if (!app.repo.myCard?.replies) showChannelCard();
  else showComposer();

  function showChannelCard() {
    const suggested = `${app.repo.myNode.username}_r`.slice(0, 32);
    const { wrap, input } = field('Channel name', { type: 'text', autocomplete: 'off', spellcheck: false, value: suggested, maxlength: 32 });
    const status = h('div.inline-status');
    const make = button('Make Channel', { style: 'primary', type: 'submit' });
    const cancel = button('Cancel', { style: 'ghost', onClick: () => m.close() });
    const form = h('form', wrap, status, make, cancel);
    replace(stage,
      sectionMark('Your comments channel'),
      h('p.muted', 'Your comments live in a public channel you own. Anyone can read it on Telegram; you can edit or delete anything there.'),
      form,
    );

    let timer = null;
    let seq = 0;
    const check = () => {
      const u = normaliseUsername(input.value);
      replace(status);
      if (!u) return;
      const mine = ++seq;
      timer = setTimeout(async () => {
        try {
          const r = await app.repo.checkUsername(u);
          if (mine !== seq) return;
          if (r === 'available') replace(status, pill('Available', 'gold'));
          else if (r === 'invalid') replace(status);
          else replace(status, pill('Taken', 'bad'));
        } catch {
          if (mine === seq) replace(status);
        }
      }, 350);
    };
    input.addEventListener('input', () => {
      if (timer) clearTimeout(timer);
      check();
    });
    check();

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const u = normaliseUsername(input.value);
      if (!u) {
        app.toast('Channel names are 5 to 32 letters, digits, or underscores.', 'bad');
        return;
      }
      make.disabled = true;
      try {
        await app.repo.createRepliesChannel(u);
        showComposer();
      } catch (err) {
        app.toast(userMessage(err, "Couldn't make the channel."), 'bad');
        make.disabled = false;
      }
    });
  }

  function showComposer() {
    const quoteText = snippet(target.text);
    const quote = h('p.muted.comment-quote', `re: ${target.title}${quoteText ? ` — '${quoteText}'` : ''}`);
    const textarea = h('textarea', { rows: 6, placeholder: 'Say it.', 'aria-label': 'Comment text', maxlength: 4000 });
    const post = button('Post', { style: 'primary', type: 'submit' });
    const cancel = button('Cancel', { style: 'ghost', onClick: () => m.close() });
    const form = h('form.compose', quote, textarea, h('div.btn-row', post, cancel));
    replace(stage, form);
    setTimeout(() => textarea.focus(), 40);

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const text = textarea.value.trim();
      if (!text) return;
      post.disabled = true;
      const node = app.repo.myNode.username;
      const entry = app.repo.cachedCard(node);
      const temp = {
        key: `tmp:${Date.now()}`,
        pending: true,
        mine: true,
        node,
        name: entry?.card?.name || entry?.title || `@${node}`,
        avatar: entry?.photo ?? null,
        date: Math.floor(Date.now() / 1000),
        text,
        entities: [],
        media: null,
        album: [],
      };
      const optimistic = onOptimistic ? onOptimistic(temp) : { settle: () => {} };
      m.close();
      try {
        await app.repo.postComment(target.link, text);
        optimistic.settle();
      } catch (err) {
        optimistic.settle();
        app.toast(userMessage(err, "Couldn't post your comment."), 'bad');
      }
    });
  }

  return m;
}
