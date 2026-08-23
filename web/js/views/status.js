/* PRODUCT §2.10 Status sheet — opened by tapping the status pill.
 *
 * A House Pour modal with live rows: Connection (TDLib updateConnectionState),
 * Telegram (signed in + masked phone), Node, Feed stats, Pending (the live
 * activity registry), Last error, TDLib version, Refresh Now + Close.
 * The sheet repaints while open and stops when it closes.
 */
import { h, button, modal, replace, sectionMark } from '../../vendor/house-pour.js';
import { connectionCopy } from '../td.js';
import { collapseLabels } from '../activity.js';
import { formatTime } from '../protocol.js';

/** `+16045550199` → `+1 604 ••• 0199` (country, area, masked middle, last four). */
export function maskPhone(phone) {
  const d = String(phone ?? '').replace(/\D/g, '');
  if (d.length < 8) return d ? `+${d}` : '';
  const last = d.slice(-4);
  const head = d.slice(0, d.length - 7);
  const country = head.slice(0, head.length > 3 ? head.length - 3 : 1);
  const area = head.slice(country.length);
  return `+${country}${area ? ` ${area}` : ''} ••• ${last}`;
}

function relAgo(ms) {
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return 'just now';
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const hs = Math.round(m / 60);
  if (hs < 24) return `${hs} h ago`;
  return `${Math.round(hs / 24)} d ago`;
}

export function openStatusSheet(app) {
  const rows = new Map();
  const row = (label) => {
    const value = h('div.status-value');
    rows.set(label, value);
    return h('div.status-row', h('div.status-label', label), value);
  };

  const refreshBtn = button('Refresh Now', { style: 'accent' });
  let m;
  const closeBtn = button('Close', { style: 'ghost', onClick: () => m.close() });
  const content = h('div.status-sheet',
    sectionMark('Status'),
    row('Connection'),
    row('Telegram'),
    row('Node'),
    row('Feed'),
    row('Pending'),
    row('Last error'),
    row('TDLib'),
    refreshBtn,
    closeBtn,
  );

  let phone = null;
  if (app.td.isReady && app.repo) {
    app.repo.getMe().then((me) => {
      phone = me?.phone_number ?? null;
      paint();
    }).catch(() => null);
  }

  function paint() {
    const set = (label, value) => replace(rows.get(label), value);

    set('Connection', app.td.isReady || app.td.connectionState ? connectionCopy(app.td.connectionState) : 'Starting');
    set('Telegram', app.td.isReady ? (phone ? `Signed in · ${maskPhone(phone)}` : 'Signed in') : 'Signed out');

    const node = app.repo?.myNode;
    if (node) {
      const entry = app.repo.cachedCard(node.username);
      set('Node', entry?.fetchedAt ? `@${node.username} · card ${relAgo(entry.fetchedAt)}` : `@${node.username}`);
    } else set('Node', 'None');

    const stats = app.feedStats;
    if (stats) {
      const src = `${stats.sources} ${stats.sources === 1 ? 'source' : 'sources'}`;
      const posts = `${stats.posts} ${stats.posts === 1 ? 'post' : 'posts'}`;
      set('Feed', `${src} · ${posts} · refreshed ${formatTime(new Date(stats.at))}`);
    } else set('Feed', 'None');

    const pending = collapseLabels(app.activity.list());
    set('Pending', pending.length ? pending.map((l) => h('span.pending-item', `${l}…`)) : 'Nothing');

    set('Last error', app.lastError ? `${app.lastError.text} at ${formatTime(new Date(app.lastError.at))}` : 'None');
    set('TDLib', app.td.tdlibVersion ?? 'Unknown');
  }

  refreshBtn.addEventListener('click', () => {
    app.refreshNow();
    paint();
  });

  paint();
  const timer = setInterval(paint, 500);
  m = modal(content, { label: 'Status', onClose: () => clearInterval(timer) });
  return m;
}
