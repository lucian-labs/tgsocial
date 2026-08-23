/* PRODUCT §2.2 Setup — Your node (create / find) and Your feeds (pick + verify). */
import { h, button, field, pill, toggle, replace, sectionMark } from '../../vendor/house-pour.js';
import { emptyCard } from './shared.js';
import { normaliseUsername, usernameKey, hasBacklink } from '../protocol.js';
import { userMessage } from '../repo.js';

export function render(app, { manage = false } = {}) {
  const root = h('div');
  if (app.repo.myNode) root.append(feedsCard(app));
  else if (app.repo.newerNode) root.append(newerCard(app));
  else root.append(nodeCard(app, root));
  if (!manage) {
    root.append(button('Skip for now', {
      style: 'ghost',
      onClick: () => {
        app.repo.setPref('setupSkipped', true);
        app.navigate('#/feed');
      },
    }));
  }
  return root;
}

function nodeCard(app, root) {
  const { wrap, input } = field('Node name', { type: 'text', autocomplete: 'off', spellcheck: false, placeholder: 'tgs_yourname', maxlength: 32 });
  const status = h('div.inline-status');
  const create = button('Create Node', { style: 'primary', type: 'submit' });
  const have = button('I already have one', {
    style: 'ghost',
    onClick: async () => {
      have.disabled = true;
      try {
        const node = await app.busy(app.repo.findMyNode());
        if (app.repo.newerNode) {
          app.toast('Newer card. Update the app.', 'bad');
          replace(root, newerCard(app), skipButton(app));
        } else if (!node) app.toast('No node found.');
        else {
          app.toast(`Found @${node.username}.`, 'good');
          replace(root, feedsCard(app), skipButton(app));
        }
      } catch (e) {
        app.toast(e.message, 'bad');
      } finally {
        have.disabled = false;
      }
    },
  });
  const form = h('form', wrap, status, create, have);
  const card = h('div.card',
    sectionMark('Your node'),
    h('h2', 'Make your node.'),
    h('p.muted', 'A public channel that holds your feeds and who you follow. It lives on Telegram, and anyone can read it there.'),
    form,
  );

  // live availability check (debounced)
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
        else if (r === 'toomany') replace(status, pill('Too many public channels', 'bad'));
        else if (r === 'invalid') replace(status);
        else replace(status, pill('Taken', 'bad'));
      } catch (e) {
        if (mine === seq) replace(status);
      }
    }, 350);
  };
  input.addEventListener('input', () => {
    if (timer) clearTimeout(timer);
    check();
  });
  app.repo.suggestedUsername().then((u) => {
    if (!input.value) {
      input.value = u;
      check();
    }
  }).catch(() => null);

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const u = normaliseUsername(input.value);
    if (!u) {
      app.toast('Node names are 5 to 32 letters, digits, or underscores.', 'bad');
      return;
    }
    create.disabled = true;
    try {
      const r = await app.repo.checkUsername(u);
      if (r === 'taken') throw new Error('That name is taken.');
      if (r === 'invalid') throw new Error('Telegram did not accept that name.');
      if (r === 'toomany') throw new Error('Too many public channels.');
      await app.busy(app.repo.createNode(u));
      app.toast(`@${u} is your node.`, 'good');
      replace(root, feedsCard(app), skipButton(app));
    } catch (err) {
      app.toast(err.message, 'bad');
    } finally {
      create.disabled = false;
    }
  });
  return card;
}

/** PROTOCOL §8: my own node carries a card this version cannot read — never offer to make a second one. */
function newerCard(app) {
  return emptyCard('Newer card. Update the app.', `@${app.repo.newerNode.username} is your node, but its card is a newer version than this app reads.`);
}

function skipButton(app) {
  return button('Skip for now', {
    style: 'ghost',
    onClick: () => {
      app.repo.setPref('setupSkipped', true);
      app.navigate('#/feed');
    },
  });
}

/** Card 2 — Your feeds. Reused by You → Manage. */
export function feedsCard(app) {
  const list = h('div', h('p.muted', 'Loading your channels…'));
  const save = button('Save Feeds', { style: 'primary', disabled: true });
  const card = h('div.card',
    sectionMark('Your feeds'),
    h('p.muted', 'Pick the channels that post as you.'),
    list,
    save,
  );
  const selected = new Set((app.repo.myCard?.feeds ?? []).map(usernameKey));
  const casing = new Map((app.repo.myCard?.feeds ?? []).map((u) => [usernameKey(u), u]));
  const descriptions = new Map();

  let painted = false;
  const paint = (candidates) => {
    if (painted && !list.isConnected) return;
    painted = true;
    const rows = [...candidates];
    // feeds listed on the card that are not among the candidates still show (co-admin edge cases)
    for (const u of app.repo.myCard?.feeds ?? []) {
      if (!rows.some((c) => c.username && usernameKey(c.username) === usernameKey(u))) {
        rows.push({ chatId: null, title: `@${u}`, username: u, canPost: true, listedOnly: true });
      }
    }
    if (!rows.length) {
      replace(list, h('p.muted', 'No channels you can post to yet. Make one in Telegram, then come back.'));
      save.disabled = true;
      return;
    }
    replace(list, rows.map((c) => row(c)));
    save.disabled = false;
  };

  const refresh = () => app.repo.refreshCandidates().then(paint).catch((e) => {
    if (!painted) replace(list, h('p.muted', `Couldn't list your channels. ${e.message}`));
  });

  // opening this card ALWAYS re-queries live: the cached list paints
  // instantly, the fresh scan replaces it ("Syncing" via the activity
  // registry while in flight)
  const cached = app.repo.cachedCandidates();
  if (cached) paint(cached);
  refresh();

  // a TDLib update that can change candidacy (repo 'candidates-dirty')
  // re-queries while this card is visible, debounced ~1 s — never on a timer
  let dirtyTimer = null;
  const offDirty = app.repo.subscribe((what) => {
    if (what !== 'candidates-dirty' || !list.isConnected) return;
    if (dirtyTimer) clearTimeout(dirtyTimer);
    dirtyTimer = setTimeout(() => {
      dirtyTimer = null;
      if (list.isConnected) refresh();
    }, 1000);
  });
  app.onLeave(() => {
    offDirty();
    if (dirtyTimer) clearTimeout(dirtyTimer);
  });

  function row(c) {
    const hasUsername = !!c.username;
    const key = hasUsername ? usernameKey(c.username) : null;
    const sub = h('div.row-sub', hasUsername ? `@${c.username}` : 'Needs a public link.');
    const hint = h('div.verify-hint');
    const onToggle = async (on) => {
      if (on) {
        selected.add(key);
        casing.set(key, c.username);
        await offerVerify(c, hint);
      } else {
        selected.delete(key);
        replace(hint);
      }
    };
    const pick = toggle(hasUsername && selected.has(key), onToggle, { label: `Use ${c.title} as a feed`, disabled: !hasUsername });
    const item = h('div.list-item', { class: hasUsername ? '' : 'disabled' },
      h('div.row-main', h('div.row-text', h('div.row-name', c.title), sub)),
      h('div.row-trail', pick),
    );
    return h('div.feed-pick', item, hint);
  }

  async function offerVerify(c, hint) {
    if (!app.repo.myNode) return;
    let description = descriptions.get(c.username);
    if (description === undefined) {
      try {
        const info = await app.repo.feedInfo(c.username);
        description = info.description ?? '';
      } catch {
        description = '';
      }
      descriptions.set(c.username, description);
    }
    if (hasBacklink(description, app.repo.myNode.username)) {
      replace(hint, h('div', pill('Verified', 'gold')));
      return;
    }
    const verify = button('Verify', {
      size: 'sm',
      onClick: async () => {
        verify.disabled = true;
        try {
          await app.repo.addBacklink(c.username);
          descriptions.set(c.username, `${description}\ntgsocial: @${app.repo.myNode.username}`);
          replace(hint, h('div', pill('Verified', 'gold')));
        } catch (e) {
          app.toast(e.message, 'bad');
          verify.disabled = false;
        }
      },
    });
    const skip = button('Skip', { size: 'sm', style: 'ghost', onClick: () => replace(hint) });
    replace(hint,
      "Add a line to this channel's description so readers can verify it's yours?",
      h('div.btn-row', verify, skip),
    );
  }

  save.addEventListener('click', async () => {
    if (!app.repo.myNode) {
      app.toast('Make your node first.', 'bad');
      return;
    }
    save.disabled = true;
    try {
      const feeds = [...selected].map((k) => casing.get(k) ?? k);
      await app.repo.setFeeds(feeds);
      app.toast('Feeds saved.', 'good');
      app.feedDirty = true;
      app.navigate('#/feed');
    } catch (e) {
      app.toast(userMessage(e, "Couldn't update your card."), 'bad');
    } finally {
      save.disabled = false;
    }
  });

  return card;
}
