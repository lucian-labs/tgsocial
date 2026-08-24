/* app.js — boot, shell, router, app-wide state.
 *
 * Routes: #/feed #/explore #/graph #/you #/setup #/node/<username>
 *         #/feed/<username> #/compose[?feed=<username>]
 *
 * Public links (PRODUCT §2.13) are pathnames, not hashes: /f/<channel> and
 * /n/<node>. nginx falls back to index.html for them, so the router reads
 * location.pathname when there is no hash route. TDLib refuses every chat
 * read before authorization, so a visitor with no session gets Sign in with
 * the destination named, and lands on it once TDLib reports Ready.
 */
import { h, button, tabs, toast, replace } from '../vendor/house-pour.js';
import { Td } from './td.js';
import { Repo } from './repo.js';
import { Activity } from './activity.js';
import { normaliseUsername, parsePublicPath, usernameKey } from './protocol.js';
import { audioRowStats, closeViewer, currentAudio, watchMedia } from './media.js';
import { openStatusSheet } from './views/status.js';
import * as signin from './views/signin.js';
import * as setup from './views/setup.js';
import * as feed from './views/feed.js';
import * as explore from './views/explore.js';
import * as node from './views/node.js';
import * as channel from './views/channel.js';
import * as graph from './views/graph.js';
import * as you from './views/you.js';
import * as thread from './views/thread.js';
import { openCompose } from './views/compose.js';

const MAIN_TABS = [
  { id: 'feed', label: 'Feed' },
  { id: 'explore', label: 'Explore' },
  { id: 'graph', label: 'Graph' },
  { id: 'you', label: 'You' },
];

const CONFIG_EXAMPLE = `{
  "apiId": 0,
  "apiHash": "replace_me",
  "indexGroup": "tgsocial_index"
}`;

class App {
  constructor() {
    this.config = null;
    this.td = new Td();
    this.repo = null;
    this.route = null;
    this.lastMain = '#/feed';
    this.leaveFns = [];
    this.feedDirty = false;
    this.nodeLookupDone = false;
    /** Written by the feed view for the Status sheet (PRODUCT §2.10). */
    this.feedStats = null;
    /** Override for the feed's in-memory window (diagnostics and test/flows.mjs); null uses the default. */
    this.feedWindow = null;
    this.feedRefresh = null;
    this.lastError = null;
    /** The public link this visit arrived on, until it is spent (§2.13). */
    this.pendingDest = null;
    /** Every in-flight operation lives here; the pill derives from it (PRODUCT §2.10). */
    this.activity = new Activity({ onChange: () => this.paintStatus() });
    this.td.activity = this.activity;
    this.els = {
      app: document.getElementById('app'),
      lead: document.getElementById('topbar-lead'),
      status: document.getElementById('status'),
      dock: document.getElementById('dock'),
      view: document.getElementById('view'),
    };
    this.tabs = tabs(MAIN_TABS, 'feed', (id) => this.navigate(`#/${id}`));
    this.tabs.classList.add('floating');
    this.els.dock.append(this.tabs);
    this.els.status.addEventListener('click', () => openStatusSheet(this));
    this.toast = (message, tone, opts) => {
      if (tone === 'bad') this.lastError = { text: message, at: Date.now() };
      return toast(message, tone, opts);
    };
  }

  // ── status pill ──────────────────────────────────────────────────────────

  /**
   * PRODUCT §2.10: Syncing exactly while the activity registry is non-empty or
   * TDLib is connecting/updating; Synced when the registry is empty and the
   * connection is Connected; Offline while TDLib waits for network. The
   * registry cannot wedge the pill: every entry ends in `finally` and expires
   * after 30 s regardless (js/activity.js).
   */
  status() {
    // A fatal boot (missing config, tdweb absent, td.init threw) has nothing
    // in flight and no auth events coming: never report Syncing behind the
    // fatal card — the cold-start heuristic below would wedge the pill.
    if (this.fatal) return 'Signed out';
    if (!this.td.isReady) {
      const booting = !this.td.authState || this.td.authState['@type'] === 'authorizationStateWaitTdlibParameters';
      return booting && this.repo?.myNode ? 'Syncing' : 'Signed out';
    }
    const c = this.td.connectionState;
    if (!navigator.onLine || c === 'connectionStateWaitingForNetwork') return 'Offline';
    if (this.activity.size > 0 || c === 'connectionStateConnecting' || c === 'connectionStateConnectingToProxy' || c === 'connectionStateUpdating') return 'Syncing';
    return 'Synced';
  }

  get isOffline() {
    return this.status() === 'Offline';
  }

  paintStatus() {
    const el = this.els.status;
    const s = this.status();
    el.textContent = s;
    el.classList.toggle('gold', s === 'Synced');
    el.setAttribute('aria-label', 'Status. Opens the status sheet');
  }

  /**
   * Register work with the activity registry so the pill reads Syncing while
   * it runs and the Status sheet can name it. Ends on settle or 30 s timeout.
   */
  busy(promise, label = 'Refreshing the feed') {
    return this.activity.run(label, promise);
  }

  /** Status sheet's Refresh Now: re-run the feed refresh and re-read my card. */
  refreshNow() {
    if (!this.repo?.myNode) return Promise.resolve();
    this.feedDirty = true;
    const read = this.repo.readNode(this.repo.myNode.username, { force: true }).catch(() => null);
    // The feed session lives inside the Feed view, so off-feed there is no
    // live refresh to re-run: mark the feed dirty (it refreshes on the next
    // visit) and re-scan the comment index so the sheet's action always does
    // visible work (§2.10). On the feed, start() already refreshes both.
    if (this.route?.name === 'feed' && this.feedRefresh) this.feedRefresh();
    else this.repo.refreshComments({ force: true }).catch(() => null);
    return read;
  }

  /**
   * The dock hosts the floating tab bar and, above it, whatever else is docked
   * for the moment: the now-playing row while audio plays (PRODUCT §1). It
   * shows while any of them is live — audio keeps its dock even where the tab
   * bar is hidden (Setup, screens pushed from a viewer). The column's bottom
   * inset tracks them dynamically: --dock-extra is the measured height + the
   * dock gap of every docked extra, and it is removed when the last one
   * unmounts, so every scroll surface's last element clears the tab bar AND
   * everything stacked over it, exactly while they are there.
   */
  updateDock() {
    const extras = [...this.els.dock.children].filter((el) => el !== this.tabs && !el.hidden);
    this.els.dock.hidden = this.tabs.hidden && extras.length === 0;
    if (extras.length) {
      const gap = parseFloat(getComputedStyle(this.els.dock).rowGap) || 0;
      const total = extras.reduce((sum, el) => sum + el.getBoundingClientRect().height + gap, 0);
      this.els.app.style.setProperty('--dock-extra', `${Math.ceil(total)}px`);
    } else {
      this.els.app.style.removeProperty('--dock-extra');
    }
  }

  /**
   * PRODUCT §2.13 — the public link this visit arrived on, spent once. The
   * URL is the only memory: the pathname stays `/f/<name>` through Sign in
   * and Setup, so this is read from it in boot() and nothing is written down.
   */
  takePendingDest() {
    const dest = this.pendingDest;
    this.pendingDest = null;
    return dest;
  }

  // ── navigation ───────────────────────────────────────────────────────────

  navigate(hash, { replace: rep = false } = {}) {
    if (rep) {
      history.replaceState(null, '', hash);
      this.render();
      return;
    }
    if (location.hash === hash) this.render();
    else location.hash = hash;
  }

  back() {
    if (history.length > 1) history.back();
    else this.navigate(this.lastMain);
  }

  onLeave(fn) {
    if (typeof fn === 'function') this.leaveFns.push(fn);
  }

  parseRoute() {
    // A public link is a pathname (PRODUCT §2.13). The hash wins whenever
    // there is one, so the signed-in app keeps routing exactly as before and
    // navigating away from a public URL works without a page load.
    if (!location.hash.startsWith('#/')) {
      const pub = parsePublicPath(location.pathname);
      if (pub) return { ...pub, params: {}, viaPath: true };
    }
    const raw = location.hash || '#/feed';
    const [path, query = ''] = raw.split('?');
    const parts = path.replace(/^#\/?/, '').split('/').filter(Boolean);
    const params = Object.fromEntries(new URLSearchParams(query));
    const name = parts[0] || 'feed';
    if ((name === 'node' || name === 'feed') && parts[1]) {
      const username = normaliseUsername(parts[1]);
      return { name: name === 'node' ? 'node' : 'channel', username: username || parts[1], params };
    }
    if (name === 'thread' && parts[1] && parts[2]) {
      const username = normaliseUsername(parts[1]);
      return { name: 'thread', username: username || parts[1], serverId: Number(parts[2]) || 0, params };
    }
    return { name, params };
  }

  // ── render ───────────────────────────────────────────────────────────────

  render() {
    const route = this.parseRoute();
    const stayOnSignin = !this.td.isReady && this.currentView === 'signin' && !this.fatal
      && !(this.repo?.myNode && (!this.td.authState || this.td.authState['@type'] === 'authorizationStateWaitTdlibParameters'));
    if (!stayOnSignin) {
      for (const fn of this.leaveFns.splice(0)) {
        try {
          fn();
        } catch (e) {
          console.warn('[app] leave', e);
        }
      }
    }
    this.route = route;
    const { lead, view } = this.els;
    this.paintStatus();
    closeViewer();

    const setLead = (back) => {
      replace(lead, back
        ? button('‹ Back', { style: 'ghost', size: 'sm', ariaLabel: 'Back', onClick: () => this.back() })
        : h('a.brand', { href: '#/feed', 'aria-label': 'tgsocial home' }, 'tgsocial'));
    };
    // The floating tab bar: hidden on Sign in, Setup, and inside full-screen
    // viewers; present on pushed screens (PRODUCT §1). Hiding the tab bar
    // never hides the dock while the now-playing row lives there.
    const setTabs = (on, selected = null) => {
      this.tabs.hidden = !on;
      if (on && selected) this.tabs.select(selected);
      this.updateDock();
    };

    if (this.fatal) {
      this.currentView = 'fatal';
      setTabs(false);
      setLead(false);
      replace(view, this.fatal);
      return;
    }

    if (!this.td.isReady) {
      // Cold start with a known node: TDLib is still booting but we were signed in last time.
      // Paint the cached feed behind a Syncing pill instead of flashing the sign-in screen (PRODUCT §4).
      const booting = !this.td.authState || this.td.authState['@type'] === 'authorizationStateWaitTdlibParameters';
      if (booting && this.repo?.myNode && !this.fatal) {
        this.currentView = 'boot';
        setTabs(true, 'feed');
        setLead(false);
        replace(view, feed.render(this, { cacheOnly: true }));
        return;
      }
      setTabs(false);
      setLead(false);
      // the sign-in view repaints itself on auth updates; re-rendering it here would wipe a half-typed form
      if (this.currentView !== 'signin') {
        this.currentView = 'signin';
        replace(view, signin.render(this));
        window.scrollTo(0, 0);
      }
      return;
    }
    this.currentView = route.name;

    // first time after sign-in: find my node; show Setup when none (unless skipped)
    if (!this.repo.myNode && !this.nodeLookupDone) {
      this.nodeLookupDone = true;
      setTabs(false);
      setLead(false);
      replace(view, h('div.card', h('p.muted', 'Looking for your node…')));
      this.busy(this.repo.findMyNode()).then(() => {
        // a node with a newer card is still a node: no Setup, no second channel (PROTOCOL §8)
        if (this.repo.newerNode) this.toast('Newer card. Update the app.', 'bad');
        if (!this.repo.myNode && !this.repo.newerNode && !this.repo.prefs.setupSkipped && route.name !== 'setup') this.navigate('#/setup', { replace: true });
        else this.render();
      }, (e) => {
        // the lookup failed, which is not the same as "no node": never offer Setup off a failed read
        this.nodeLookupDone = false;
        this.toast(e.message, 'bad');
        replace(view, h('div.card',
          h('h2', "Couldn't look for your node."),
          h('p.muted', e.message),
          button('Try Again', { style: 'primary', onClick: () => this.render() }),
        ));
      });
      return;
    }

    // PRODUCT §2.13 — land on the link this visit came in on. The pathname
    // still reads /f/<name> unless Setup rewrote the hash on the way, so this
    // is usually a no-op that only spends the token; after a Setup detour it
    // is the navigation that puts the visitor where they were going.
    if (this.pendingDest && route.name !== 'setup') {
      const dest = this.takePendingDest();
      const there = route.name === dest.name && usernameKey(route.username) === usernameKey(dest.username);
      if (!there) {
        this.navigate(dest.name === 'node' ? `#/node/${dest.username}` : `#/feed/${dest.username}`, { replace: true });
        return;
      }
    }

    const main = MAIN_TABS.some((t) => t.id === route.name);
    if (main) {
      this.lastMain = `#/${route.name}`;
      setTabs(true, route.name);
      setLead(false);
    } else {
      // pushed screens keep the floating tab bar; Setup does not (PRODUCT §1)
      const pushed = route.name === 'node' || route.name === 'channel' || route.name === 'thread';
      setTabs(pushed, this.lastMain.replace('#/', ''));
      setLead(true);
    }

    let el;
    switch (route.name) {
      case 'feed':
        el = feed.render(this);
        break;
      case 'explore':
        el = explore.render(this);
        break;
      case 'graph':
        el = graph.render(this);
        break;
      case 'you':
        el = you.render(this);
        break;
      case 'setup':
        el = setup.render(this, { manage: route.params.manage === '1' });
        break;
      case 'node':
        el = node.render(this, { username: route.username });
        break;
      case 'channel':
        el = channel.render(this, { username: route.username });
        break;
      case 'thread':
        el = thread.render(this, { username: route.username, serverId: route.serverId, compose: route.params.compose === '1' });
        break;
      case 'compose': {
        // modal over the last main view
        const under = this.lastMain.replace('#/', '');
        setTabs(true, under);
        setLead(false);
        el = ({ feed, explore, graph, you })[under]?.render(this) ?? feed.render(this);
        setTimeout(() => openCompose(this, { feed: route.params.feed || null }), 0);
        break;
      }
      default:
        this.navigate('#/feed', { replace: true });
        return;
    }
    replace(view, el);
    window.scrollTo(0, 0);
  }

  // ── sign out ─────────────────────────────────────────────────────────────

  async signOut() {
    this.fatal = h('div.card', h('p.muted', 'Signing out…'));
    this.render();
    try {
      await this.repo.signOut();
    } finally {
      localStorage.clear();
      // TDLib closes after logOut; a fresh page gets a fresh client
      location.hash = '';
      location.reload();
    }
  }

  // ── boot ─────────────────────────────────────────────────────────────────

  async boot() {
    const bg = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim();
    const meta = document.getElementById('theme-color');
    if (meta && bg) meta.setAttribute('content', bg);

    window.addEventListener('hashchange', () => this.render());
    window.addEventListener('online', () => this.paintStatus());
    window.addEventListener('offline', () => this.paintStatus());

    try {
      const res = await fetch('/config.json', { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      this.config = await res.json();
      if (!this.config.apiId || !this.config.apiHash || this.config.apiHash === 'replace_me') throw new Error('placeholder');
    } catch (e) {
      this.config = null;
      this.fatal = h('div.card',
        h('h2', 'Missing config.json.'),
        h('p.muted', 'Copy config.json.example to config.json next to index.html and fill in your Telegram api_id and api_hash from my.telegram.org.'),
        h('div.pre', CONFIG_EXAMPLE),
      );
      this.render();
      return;
    }
    // PRODUCT §2.13: a public link is a destination, not a mode. TDLib
    // refuses every chat read before authorization, so a visitor with no
    // session signs in first; this remembers where they were going, and the
    // sign-in screen names it.
    this.pendingDest = parsePublicPath(location.pathname);
    this.repo = new Repo(this.td, this.config);
    // a memory-pressure flush revokes every decoded picture the app is
    // holding; this is what paints them back afterwards (js/media.js)
    watchMedia(this);
    this.td.onFloodWait = (s) => this.toast(`Telegram asked us to wait ${s} s.`);
    this.td.on('auth', (state) => {
      const t = state?.['@type'];
      if (t === 'authorizationStateReady') this.nodeLookupDone = false;
      if (t === 'authorizationStateClosed' && !this.fatal) localStorage.clear();
      this.render();
    });
    this.td.on('connection', () => this.paintStatus());
    this.render();
    if (!Td.available()) {
      this.fatal = h('div.card', h('h2', "TDLib didn't load."), h('p.muted', 'vendor/tdweb/tdweb.js is missing. Run web/scripts/install-tdweb.sh with a tdweb dist.'));
      this.render();
      return;
    }
    try {
      await this.td.init(this.config);
    } catch (e) {
      this.fatal = h('div.card', h('h2', "TDLib didn't start."), h('p.muted', e.message));
      this.render();
    }
  }
}

const app = new App();
window.__tgsocial = {
  app,
  td: app.td,
  get repo() { return app.repo; },
  currentAudio,
  /** Player rows the audio dock is tracking vs. still in the document (test/flows.mjs). */
  audioRows: () => audioRowStats(),
  /** Media-memory introspection for the Status sheet and test/flows.mjs. */
  media: {
    stats: () => app.td.mediaStats(),
    flush: (reason = 'test') => app.td.flushMedia(reason),
    configure: (opts) => app.td.media.configure(opts),
    wasRevoked: (url) => app.td.media.wasRevoked(url),
  },
};
// boot() paints every failure it knows about; anything it does not know about
// still has to become a card, never a blank page.
app.boot().catch((e) => {
  console.error('[app] boot', e);
  app.fatal = h('div.card', h('h2', "tgsocial didn't start."), h('p.muted', e.message));
  app.render();
});
