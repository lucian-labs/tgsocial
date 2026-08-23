/* PRODUCT §2.8 You — profile summary, feeds, compose, listing, sign out. */
import { h, button, pill, field, modal, confirm, toggle, sectionMark } from '../../vendor/house-pour.js';
import { APP_VERSION, APP_BUILD } from '../td.js';
import { avatarFor, feedRow, emptyCard } from './shared.js';
import { userMessage } from '../repo.js';
import { openCompose } from './compose.js';

export function render(app) {
  const root = h('div');
  const node = app.repo.myNode;
  if (!node) {
    if (app.repo.newerNode) root.append(emptyCard('Newer card. Update the app.', `@${app.repo.newerNode.username} is your node, but its card is a newer version than this app reads.`));
    else root.append(emptyCard('No node yet.', 'Your node is a public channel that holds your feeds and who you follow.', { label: 'Make Your Node', onClick: () => app.navigate('#/setup') }));
    root.append(signOutButton(app));
    root.append(footer(app));
    return root;
  }
  const card = app.repo.myCard ?? { name: null, feeds: [], follows: [], public: true };
  const entry = app.repo.cachedCard(node.username);
  const name = card.name || entry?.title || node.username;

  const head = h('div.card.you-head',
    avatarFor(app, name, entry?.photo, 'profile'),
    h('div.row-text', h('h2', name), h('span.mono', `@${node.username}`)),
    button('Edit Card', { size: 'sm', onClick: () => editCard(app) }),
  );

  const feeds = h('div.card');
  if (!card.feeds.length) feeds.append(h('p.muted', 'No feeds yet. Manage picks the channels that post as you.'));
  for (const f of card.feeds) {
    const row = feedRow(app, { title: `@${f}`, username: f, onClick: () => openCompose(app, { feed: f }) });
    feeds.append(row);
    app.repo.feedInfo(f).then((info) => {
      if (row.isConnected) row.replaceWith(feedRow(app, { title: info.title, username: info.username, onClick: () => openCompose(app, { feed: info.username }) }));
    }).catch(() => null);
  }
  const feedsMark = h('div.mark-row', sectionMark('Your feeds'), button('Manage', { size: 'sm', onClick: () => app.navigate('#/setup?manage=1') }));

  const compose = button('Compose', { style: 'primary', onClick: () => openCompose(app, {}) });

  // neutral in both states: Compose is the one gold action on this screen (PRODUCT §2.8)
  const listedPill = pill(card.public === false ? 'Unlisted' : 'Listed');
  const announce = button('Announce in Directory', { size: 'sm', disabled: card.public === false });
  const paintListing = (on) => {
    listedPill.textContent = on ? 'Listed' : 'Unlisted';
    announce.disabled = !on;
  };
  const listingToggle = toggle(card.public !== false, async (next) => {
    paintListing(next);
    try {
      await app.repo.setPublic(next);
    } catch (e) {
      app.toast(userMessage(e, "Couldn't update your card."), 'bad');
      const back = app.repo.myCard?.public !== false;
      listingToggle.set(back);
      paintListing(back);
    }
  }, { label: 'Public listing' });
  announce.addEventListener('click', async () => {
    announce.disabled = true;
    try {
      const posted = await app.busy(app.repo.announce());
      app.toast(posted ? 'Announced.' : 'Already announced.', posted ? 'good' : undefined);
    } catch (e) {
      app.toast(e.message, 'bad');
    } finally {
      announce.disabled = app.repo.myCard?.public === false;
    }
  });
  const listing = h('div.card',
    h('div.listing-row', h('div', 'Public listing'), h('div.row-trail', listedPill, listingToggle)),
    announce,
  );

  const viewAs = button('View as others see it', { style: 'ghost', onClick: () => app.navigate(`#/node/${node.username}`) });

  root.append(head, feedsMark, feeds, compose, sectionMark('Listing'), listing, viewAs, signOutButton(app), footer(app));
  return root;
}

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

function footer(app) {
  const node = app.repo.myNode ? ` · node @${app.repo.myNode.username}` : '';
  const td = app.td.tdlibVersion ? `TDLib ${app.td.tdlibVersion}` : 'TDLib';
  return h('div.footer-meta', `tgsocial ${APP_VERSION} (${APP_BUILD}) · ${td}${node}`);
}

function editCard(app) {
  const card = app.repo.myCard ?? { name: null, bio: null, link: null };
  const name = field('Name', { type: 'text', value: card.name ?? '', maxlength: 128, autocomplete: 'name' });
  const bio = field('Bio', { type: 'text', value: card.bio ?? '', maxlength: 255 });
  const link = field('Link', { type: 'url', value: card.link ?? '', placeholder: 'https://', inputmode: 'url' });
  let m;
  const save = button('Save', { style: 'primary', type: 'submit' });
  const form = h('form', name.wrap, bio.wrap, link.wrap, save);
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    save.disabled = true;
    try {
      await app.repo.editProfile({ name: name.input.value.trim(), bio: bio.input.value.trim(), link: link.input.value.trim() });
      app.toast('Card updated.', 'good');
      m.close();
      app.render();
    } catch (err) {
      app.toast(userMessage(err, "Couldn't update your card."), 'bad');
      save.disabled = false;
    }
  });
  m = modal([h('h2', 'Edit Card'), form], { label: 'Edit Card' });
}
