/* PRODUCT §2.20 Settings — the safety lists, the contact card, and the two
 * destructive actions.
 *
 * The lists are the whole of the filter (§2.18) and there is no switch beside
 * them: the only reverse is per item, here. Everything on this screen reads and
 * writes `js/moderation.js` and nothing else — no card write, no Telegram call
 * — except `Delete My Node`, which is the one place in the app that can remove
 * the two channels Setup made (§2.21).
 */
import { h, button, confirm, field, modal, replace, sectionMark } from '../../vendor/house-pour.js';
import { CONTACT_ADDRESS } from '../moderation.js';
import { channelLink } from '../protocol.js';
import { userMessage } from '../repo.js';
import { avatarFor, openExternal } from './shared.js';
import { unblock } from './safety.js';

export function render(app) {
  const root = h('div');
  if (!app.repo) return root;

  const blockedCard = h('div.card');
  const mutedCard = h('div.card');
  const hiddenCard = h('div.card');
  const blockedMark = sectionMark('Blocked', app.safety.blocked.length);
  const mutedMark = sectionMark('Muted', app.safety.mutedFeeds.length);
  const hiddenMark = sectionMark('Hidden', app.safety.hidden.length);

  paintBlocked();
  paintMuted();
  paintHidden();

  root.append(
    sectionMark('Safety'),
    h('div.card', h('p.muted', 'Blocked and reported content is hidden everywhere in the app. The filter is always on; there is no switch. These lists live on this device only and nobody else can read them.')),
    blockedMark, blockedCard,
    mutedMark, mutedCard,
    hiddenMark, hiddenCard,
    sectionMark('Contact'),
    h('div.card',
      h('a.list-item.contact-row', { href: `mailto:${CONTACT_ADDRESS}` }, CONTACT_ADDRESS),
      h('p.muted', 'Reports are read by a person within 24 hours. Content that breaks the rules is reported to Telegram, the only party that can remove it from the network. Your copy is hidden on your device the moment you report it, whether or not anyone else acts.'),
    ),
    signOutButton(app),
  );
  // §2.21 sits directly below Sign Out — the reversible destructive action
  // first, the irreversible one second. With no node there is nothing to delete.
  if (app.repo.myNode) root.append(button('Delete My Node', { style: 'danger', onClick: () => openDelete(app) }));

  /**
   * A blocked node's row taps through to their profile, which is §2.16's one
   * deliberate way to reach them and says they are blocked.
   */
  function paintBlocked() {
    const list = app.safety.blocked;
    if (!list.length) {
      replace(blockedCard, h('p.muted', "You haven't blocked anyone."));
      return;
    }
    replace(blockedCard, list.map((username) => {
      const entry = app.repo.cachedCard(username);
      const name = entry?.card?.name || entry?.title || `@${username}`;
      const action = button('Unblock', {
        style: 'ghost',
        size: 'sm',
        onClick: (e) => {
          e.stopPropagation();
          unblock(app, username);
        },
      });
      const row = h('div.list-item.node-row', { role: 'link', tabindex: 0, 'aria-label': `Open ${name}` },
        h('div.row-main', avatarFor(app, name, entry?.photo, 'row'), h('div.row-text', h('div.row-name', name), h('div.row-sub', `@${username}`))),
        h('div.row-trail', action));
      const go = () => app.navigate(`#/node/${username}`);
      row.addEventListener('click', go);
      row.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target === row) go();
      });
      return row;
    }));
  }

  function paintMuted() {
    const list = app.safety.mutedFeeds;
    if (!list.length) {
      replace(mutedCard, h('p.muted', 'No muted feeds.'));
      return;
    }
    replace(mutedCard, list.map((username) => {
      const title = h('div.row-name', `@${username}`);
      const row = h('div.list-item.feed-row',
        h('div.row-main', h('div.row-text', title, h('div.row-sub', `@${username}`))),
        h('div.row-trail', button('Unmute', {
          style: 'ghost',
          size: 'sm',
          onClick: () => {
            app.safety.unmuteFeed(username);
            app.toast(`Unmuted ${title.textContent}.`, 'good');
          },
        })));
      // the row names the channel as soon as Telegram answers; until then the
      // handle stands in, and the toast says whatever the row says
      app.repo.feedInfo(username).then((info) => {
        if (row.isConnected && info.title) title.textContent = info.title;
      }).catch(() => null);
      return row;
    }));
  }

  /**
   * A hidden row names its channel and its message id and NOTHING else: showing
   * a preview of the thing someone reported would undo the report. The reason
   * and the date come from the record (PROTOCOL §7.1), which is why the reason
   * is stored at all.
   */
  function paintHidden() {
    const list = app.safety.hidden;
    if (!list.length) {
      replace(hiddenCard, h('p.muted', 'Nothing hidden.'));
      return;
    }
    replace(hiddenCard, list.map((entry) => {
      const [channel, messageId] = entry.key.split('/');
      const title = h('div.row-name', `@${channel} · ${messageId}`);
      const when = entry.at ? entry.at.slice(0, 10) : '';
      const row = h('div.list-item.hidden-row',
        h('div.row-main', h('div.row-text', title, h('div.row-sub', [entry.reason, when ? `reported ${when}` : ''].filter(Boolean).join(' · ')))),
        h('div.row-trail', button('Unhide', {
          style: 'ghost',
          size: 'sm',
          onClick: () => {
            app.safety.unhide(entry.key);
            app.toast("Unhidden. It's back in your feed.", 'good');
          },
        })));
      app.repo.feedInfo(channel).then((info) => {
        if (row.isConnected && info.title) title.textContent = `${info.title} · ${messageId}`;
      }).catch(() => null);
      return row;
    }));
  }

  return root;
}

/** §4 — Sign Out moved here from You (§2.8) and kept its confirm word for word. */
function signOutButton(app) {
  return button('Sign Out', {
    style: 'danger',
    onClick: async () => {
      const ok = await confirm({ title: 'Sign out of tgsocial?', body: 'Your node stays on Telegram.', okLabel: 'Sign Out', okStyle: 'danger' });
      if (!ok) return;
      await app.signOut();
    },
  });
}

// ── delete my node (PRODUCT §2.21) ─────────────────────────────────────────

/**
 * Type-the-username, because this destroys two public channels and releases
 * their names — a tap-to-confirm is not proportional to that. The match is
 * case-insensitive and forgives a missing `@`; nothing else counts.
 */
export function openDelete(app) {
  const node = app.repo.myNode.username;
  const replies = app.repo.myCard?.replies ?? null;
  const stage = h('div');
  // §2.21: while the delete runs the modal cannot be dismissed. It is built
  // undismissable outright rather than switched mid-run, because every stage
  // here already carries its own exit — Cancel, or Close on a failure — and a
  // scrim tap during a two-step channel delete is the one input that has no
  // defined meaning.
  const m = modal(stage, { label: 'Delete My Node', dismissible: false });
  showForm();

  function showForm() {
    const { wrap, input } = field(`Type @${node} to confirm`, {
      type: 'text',
      autocomplete: 'off',
      autocapitalize: 'off',
      autocorrect: 'off',
      spellcheck: false,
      maxlength: 40,
    });
    input.classList.add('mono');
    const del = button('Delete My Node', { style: 'danger', type: 'submit', disabled: true });
    const cancel = button('Cancel', { style: 'ghost', onClick: () => m.close() });
    const matches = () => input.value.trim().replace(/^@/, '').toLowerCase() === node.toLowerCase();
    input.addEventListener('input', () => {
      del.disabled = !matches();
    });
    const form = h('form', wrap, del, cancel);
    replace(stage,
      sectionMark('Delete my node'),
      h('h2', 'Delete my node.'),
      h('p.muted', `This deletes the channel @${node}${replies ? ` and your comments channel @${replies}` : ''} from Telegram. The public card other people read disappears, every post and comment in ${replies ? 'those two channels goes' : 'that channel go'} with it, and the ${replies ? 'names are' : 'name is'} released for anyone to take. This cannot be undone.`),
      h('p.muted', 'Your feed channels are not touched.'),
      form,
    );

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      if (!matches()) return;
      del.disabled = true;
      del.textContent = 'Deleting…';
      cancel.disabled = true;
      let result;
      try {
        result = await app.repo.deleteMyNode();
      } catch (err) {
        // offline is the only refusal that never runs anything (§2.21)
        m.close();
        app.toast(userMessage(err), 'bad');
        return;
      }
      if (result.ok) {
        m.close();
        app.toast('Your node is gone.', 'good');
        app.nodeLookupDone = true;
        app.feedDirty = true;
        app.navigate('#/setup');
        return;
      }
      showFailure(result);
    });
  }

  function showFailure(result) {
    if (result.stage === 'not-owner') {
      replace(stage,
        sectionMark('Delete my node'),
        h('p.muted', `Telegram won't let you delete @${result.channel} — only the channel's owner can. Open it in Telegram to see who owns it.`),
        button('Open in Telegram', { onClick: () => openExternal(channelLink(result.channel)) }),
        button('Close', { style: 'ghost', onClick: () => m.close() }),
      );
      return;
    }
    const body = result.stage === 'replies'
      ? `Couldn't delete @${result.channel} — Telegram said: ${result.message}. Nothing was deleted.`
      : `Your comments channel is gone. @${result.channel} is still there — Telegram said: ${result.message}.`;
    replace(stage,
      sectionMark('Delete my node'),
      h('p.muted', body),
      button('Try Again', { style: 'danger', onClick: () => showForm() }),
      button('Close', { style: 'ghost', onClick: () => m.close() }),
    );
  }

  return m;
}
