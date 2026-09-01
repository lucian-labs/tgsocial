/* comments.js — the comment thread and its composer (PRODUCT §2.12).
 *
 * ONE rendering of a thread, used twice: the Thread screen (js/views/thread.js)
 * puts it under the post card, and the full-screen carousel (js/media.js) puts
 * it under the media once `Comments` is tapped. The carousel does not get a
 * second thread — it hosts this one, which is why paging can hand it a new post
 * with `setPost` instead of tearing anything down.
 *
 * Comments follow PROTOCOL §6: a comment lives in the commenter's own public
 * comments channel and points at its target with a `re:` link, so the tree IS
 * the `re:` chains. §2.12 makes that chain direct — "the target is whatever you
 * tapped":
 *
 *   tap a comment  → it is the reply target: the quoted line above the composer,
 *                    the placeholder `Reply to <name>.`, and `re: <that
 *                    comment's own t.me link>` as the first line of what gets
 *                    written.
 *   tap it again,
 *   or the quote's × → no target: the reply goes to the post, and the first line
 *                    is `re: <the post's link>`.
 *
 * Nothing here formats that line itself — `repo.postComment(link, text)` hands
 * it to `serialiseComment` (js/protocol.js §6.5). This module's whole job on
 * that path is deciding WHICH link.
 */
import { h, button, field, modal, confirm, pill, replace, sectionMark } from '../../vendor/house-pour.js';
import { normaliseUsername, isFollowing, formatTime } from '../protocol.js';
import { userMessage } from '../repo.js';
import { avatarFor, renderEntities, openExternal } from './shared.js';
import { mediaBlocks, releaseMedia } from '../media.js';

const MAX_DEPTH = 5;

function snippet(text, max = 64) {
  const t = String(text ?? '').replace(/\s+/g, ' ').trim();
  if (!t) return '';
  return t.length > max ? `${t.slice(0, max).trimEnd()}…` : t;
}

/** The post as a reply target: the `re:` line points at the post's own link. */
export function threadTarget(post) {
  return { link: post.link, title: post.title || `@${post.username}`, text: post.text, name: post.title || `@${post.username}` };
}

/** A comment as a reply target: the `re:` line points at THAT comment's link. */
export function commentTarget(comment) {
  return { link: comment.link, title: comment.name, text: comment.text, name: comment.name };
}

/**
 * §2.12's rule in one function, so both screens and the tests agree on it: the
 * reply target is the selected comment when there is one, and the post
 * otherwise. Its `link` is what becomes `re: <link>`.
 */
export function replyTarget(post, selected) {
  return selected ? commentTarget(selected) : threadTarget(post);
}

/**
 * The comment thread for one post: the section mark, the tree, the reply-target
 * quote, and the screen's one gold `Comment` action.
 *
 * commentsPanel(app, post) → el with
 *   el.setPost(post) · el.paint() · el.release() · el.openComposer() ·
 *   el.selected (the reply target, or null — state introspection / tests)
 */
export function commentsPanel(app, post) {
  const mark = h('div');
  const commentsHost = h('div');
  const quoteHost = h('div');
  const actions = h('div');
  const root = h('div.comments', mark, commentsHost, quoteHost, actions);

  let current = post;
  /** §2.12 — the comment tapped as the reply target, or null for the post. */
  let selected = null;
  let pending = [];

  function onOptimistic(temp) {
    pending.push(temp);
    paint();
    return {
      settle: () => {
        pending = pending.filter((p) => p !== temp);
        paint();
      },
    };
  }

  function open() {
    if (!app.repo.myNode) return;
    openComposer(app, replyTarget(current, selected), onOptimistic, { reply: !!selected });
  }

  /**
   * Tapping a comment selects it; tapping the selected one clears it. The
   * quote's × clears it too, and so does moving to another post — a target from
   * the previous item would write a `re:` line into a thread it does not belong
   * to.
   */
  function select(comment) {
    selected = selected && selected.key === comment.key ? null : comment;
    paint();
  }

  function paintQuote() {
    if (!selected) {
      replace(quoteHost);
      return;
    }
    const body = snippet(selected.text);
    const clear = h('button.comment-quote-clear.hit-min', {
      type: 'button',
      'aria-label': `Reply to the post instead of ${selected.name}`,
      onclick: () => {
        selected = null;
        paint();
      },
    }, '×');
    replace(quoteHost, h('div.comment-quote-row',
      h('p.muted.comment-quote', `re: ${selected.name}${body ? ` — '${body}'` : ''}`),
      clear,
    ));
  }

  function paint() {
    if (!alive) return;
    const { tree, count } = app.repo.commentThread(current.link);
    const total = count + pending.length;
    // the selection is a comment in THIS thread; a refresh that drops it (a
    // delete, a re-scan) must not leave the composer pointing at a ghost
    if (selected && !containsKey(tree, selected.key)) selected = null;
    replace(mark, sectionMark('Comments', total));
    const parts = tree.map((n) => commentEl(n, 0));
    for (const temp of pending) parts.push(commentBody(temp, 0, []));
    if (!parts.length) {
      replace(commentsHost, h('div.card', h('p.muted', 'No comments from your network yet.')));
    } else {
      replace(commentsHost, h('div.card.thread-card', parts));
    }
    paintQuote();
    replace(actions, app.repo.myNode
      ? button('Comment', { style: 'primary', onClick: open })
      : h('p.muted.small', 'Make your node to comment.'));
  }

  function containsKey(tree, key) {
    for (const { comment, children } of tree) {
      if (comment.key === key) return true;
      if (containsKey(children, key)) return true;
    }
    return false;
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
          onclick: (e) => {
            e.stopPropagation();
            app.navigate(`#/node/${comment.node}`);
          },
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
        onClick: (e) => {
          e?.stopPropagation?.();
          // Reply is the same act as tapping the comment, then composing — one
          // path, so the `re:` line cannot differ between the two.
          selected = comment;
          paint();
          open();
        },
      }));
      if (comment.mine) {
        meta.append(button('Delete', {
          style: 'ghost',
          size: 'sm',
          ariaLabel: 'Delete this comment',
          onClick: async (e) => {
            e?.stopPropagation?.();
            const ok = await confirm({ title: 'Delete this comment?', okLabel: 'Delete', okStyle: 'danger' });
            if (!ok) return;
            try {
              await app.repo.deleteComment(comment);
            } catch (err) {
              app.toast(userMessage(err, "Couldn't delete this comment."), 'bad');
            }
          },
        }));
      }
    }
    parts.push(meta);

    const el = h('div.comment', parts);
    if (!comment.pending) {
      // §2.12: tapping any comment selects it as the reply target. The row's own
      // drawn shape is well past touchMin, so rule 6 wants no overlay here — and
      // every control INSIDE it (the name, Reply, Delete) is a descendant, so it
      // paints later and keeps its own region out of this one.
      el.setAttribute('role', 'button');
      el.setAttribute('tabindex', '0');
      el.setAttribute('aria-pressed', String(selected?.key === comment.key));
      el.setAttribute('aria-label', `Reply to ${comment.name}`);
      if (selected?.key === comment.key) el.setAttribute('data-selected', '');
      el.addEventListener('click', (e) => {
        // the innermost comment wins: a reply's row must not select its parent
        e.stopPropagation();
        select(comment);
      });
      el.addEventListener('keydown', (e) => {
        if (e.key !== 'Enter' && e.key !== ' ') return;
        e.preventDefault();
        e.stopPropagation();
        select(comment);
      });
    }
    if (children.length) {
      // replies indent one level; depth caps at 5, deeper shows flat (§2.12)
      const kids = h(depth + 1 < MAX_DEPTH ? 'div.comment-children' : 'div.comment-children.flat',
        children.map((c) => commentEl(c, Math.min(depth + 1, MAX_DEPTH - 1))));
      el.append(kids);
    }
    return el;
  }

  let alive = true;
  const unsubscribe = app.repo.subscribe((what) => {
    if (what === 'comments' && alive) paint();
  });

  root.setPost = (next) => {
    if (!next || next.link === current.link) return;
    current = next;
    // a target from the item you just paged away from is not a target here
    selected = null;
    pending = [];
    paint();
  };
  root.paint = paint;
  root.openComposer = open;
  root.release = () => {
    alive = false;
    unsubscribe();
    // players and picture bindings inside the comments go with the panel
    releaseMedia(root);
  };
  Object.defineProperty(root, 'selected', { get: () => selected });
  Object.defineProperty(root, 'post', { get: () => current });

  paint();
  return root;
}

/**
 * The comment composer (PRODUCT §2.12): a muted quote line of the target,
 * `Say it.`, Post + Cancel. With a comment selected the placeholder becomes
 * `Reply to <name>.` — §2.12's "the composer's placeholder becomes Reply to
 * <name>." First comment ever, the modal first shows the comments-channel card;
 * on success the composer proceeds. `onOptimistic` receives the temporary
 * comment and returns { settle } to remove it.
 */
export function openComposer(app, target, onOptimistic, { reply = false } = {}) {
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
    const textarea = h('textarea', {
      rows: 6,
      placeholder: reply ? `Reply to ${target.name || target.title}.` : 'Say it.',
      'aria-label': 'Comment text',
      maxlength: 4000,
    });
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
        // §6.5 writes `re: <target.link>` as the first line — the target is
        // whatever §2.12's selection resolved to, and nothing else decides it.
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
