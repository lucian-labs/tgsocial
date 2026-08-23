/* PRODUCT §2.9 Compose — modal card; web v1 is text only. */
import { h, button, modal, tabs } from '../../vendor/house-pour.js';

let open = null;

/** Open the compose modal. opts.feed preselects a feed username. */
export function openCompose(app, { feed = null } = {}) {
  if (open) return open;
  const feeds = app.repo.myCard?.feeds ?? [];
  if (!app.repo.myNode || !feeds.length) {
    app.toast('Pick a feed first.', 'bad');
    app.navigate('#/setup?manage=1');
    return null;
  }
  let selected = feed && feeds.some((f) => f.toLowerCase() === feed.toLowerCase()) ? feed : feeds[0];
  const items = feeds.map((f) => ({ id: f, label: `@${f}` }));
  const picker = tabs(items, selected, (id) => {
    selected = id;
  });
  // resolve titles for the tab labels
  for (const f of feeds) {
    app.repo.feedInfo(f).then((info) => {
      const idx = feeds.indexOf(f);
      const btn = picker.children[idx];
      if (btn && info.title) btn.textContent = info.title;
    }).catch(() => null);
  }
  const textarea = h('textarea', { rows: 6, placeholder: 'Say it.', 'aria-label': 'Post text', maxlength: 4096 });
  const post = button('Post', { style: 'primary', type: 'submit' });
  const cancel = button('Cancel', { style: 'ghost', onClick: () => m.close() });
  const form = h('form.compose', h('label.field', 'Post to'), picker, textarea, h('div.btn-row', post, cancel));
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const text = textarea.value.trim();
    if (!text) return;
    post.disabled = true;
    try {
      await app.busy(app.repo.post(selected, text));
      app.toast('Posted.', 'good');
      app.feedDirty = true;
      m.close();
      if (app.route?.name === 'feed') app.render();
    } catch (err) {
      app.toast(err.message, 'bad');
      post.disabled = false;
    }
  });
  const m = modal(form, {
    label: 'Compose',
    onClose: () => {
      open = null;
      if (location.hash.startsWith('#/compose')) app.navigate(app.lastMain || '#/feed', { replace: true });
    },
  });
  open = m;
  setTimeout(() => textarea.focus(), 40);
  return m;
}
