/* app.js — boot, shell, hash router, app-wide state.
 *
 * Routes: #/feed #/explore #/graph #/you #/setup #/node/<username>
 *         #/feed/<username> #/compose[?feed=<username>]
 */
import { h, button, tabs, toast, replace } from '../vendor/house-pour.js';
import { Td } from './td.js';
import { Repo } from './repo.js';
import { normaliseUsername } from './protocol.js';
import * as signin from './views/signin.js';
import * as setup from './views/setup.js';
import * as feed from './views/feed.js';
import * as explore from './views/explore.js';
import * as node from './views/node.js';
import * as channel from './views/channel.js';
import * as graph from './views/graph.js';
import * as you from './views/you.js';
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
    this.busyCount = 0;
    this.feedDirty = false;
    this.nodeLookupDone = false;
    this.els = {
      head: document.getElementById('head'),
      lead: document.getElementById('topbar-lead'),
      status: document.getElementById('status'),
      tabsSlot: document.getElementById('tabs-slot'),
      view: document.getElementById('view'),
    };
    this.tabs = tabs(MAIN_TABS, 'feed', (id) => this.navigate(`#/${id}`));
    this.els.tabsSlot.append(this.tabs);
    this.toast = toast;
  }

  // ── status pill ──────────────────────────────────────────────────────────

  status() {
    if (!this.td.isReady) {
      const booting = !this.td.authState || this.td.authState['@type'] === 'authorizationStateWaitTdlibParameters';
      return booting && this.repo?.myNode ? 'Syncing' : 'Signed out';
    }
    const c = this.td.connectionState;
    if (!navigator.onLine || c === 'connectionStateWaitingForNetwork') return 'Offline';
    if (this.busyCount > 0 || c === 'connectionStateConnecting' || c === 'connectionStateConnectingToProxy' || c === 'connectionStateUpdating') return 'Syncing';
    return 'Synced';
  }

  get isOffline() {
    return this.status() === 'Offline';
  }

  paintStatus() {
    const s = this.status();
    const el = this.els.status;
    el.textContent = s;
    el.classList.toggle('gold', s === 'Synced');
  }

  /** Wrap a promise so the pill reads Syncing while it runs. */
  busy(promise) {
    this.busyCount += 1;
    this.paintStatus();
    const done = () => {
      this.busyCount = Math.max(0, this.busyCount - 1);
      this.paintStatus();
    };
    return Promise.resolve(promise).then(
      (v) => {
        done();
        return v;
      },
      (e) => {
        done();
        throw e;
      },
    );
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
    const raw = location.hash || '#/feed';
    const [path, query = ''] = raw.split('?');
    const parts = path.replace(/^#\/?/, '').split('/').filter(Boolean);
    const params = Object.fromEntries(new URLSearchParams(query));
    const name = parts[0] || 'feed';
    if ((name === 'node' || name === 'feed') && parts[1]) {
      const username = normaliseUsername(parts[1]);
      return { name: name === 'node' ? 'node' : 'channel', username: username || parts[1], params };
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
    const { head, lead, view } = this.els;
    this.paintStatus();

    const setLead = (back) => {
      replace(lead, back
        ? button('‹ Back', { style: 'ghost', size: 'sm', ariaLabel: 'Back', onClick: () => this.back() })
        : h('a.brand', { href: '#/feed', 'aria-label': 'tgsocial home' }, 'tgsocial'));
    };

    if (this.fatal) {
      this.currentView = 'fatal';
      head.dataset.tabs = 'off';
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
        head.dataset.tabs = 'on';
        this.tabs.select('feed');
        setLead(false);
        replace(view, feed.render(this, { cacheOnly: true }));
        return;
      }
      head.dataset.tabs = 'off';
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
      head.dataset.tabs = 'off';
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

    const main = MAIN_TABS.some((t) => t.id === route.name);
    if (main) {
      this.lastMain = `#/${route.name}`;
      head.dataset.tabs = 'on';
      this.tabs.select(route.name);
      setLead(false);
    } else {
      head.dataset.tabs = 'off';
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
      case 'compose': {
        // modal over the last main view
        head.dataset.tabs = 'on';
        const under = this.lastMain.replace('#/', '');
        this.tabs.select(under);
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
    this.repo = new Repo(this.td, this.config);
    this.td.onFloodWait = (s) => this.toast(`Telegram asked us to wait ${s} s.`);
    this.td.on('auth', (state) => {
      const t = state?.['@type'];
      if (t === 'authorizationStateReady') this.nodeLookupDone = false;
      if (t === 'authorizationStateClosed' && !this.fatal) {
        localStorage.clear();
      }
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
window.__tgsocial = { app, td: app.td, get repo() { return app.repo; } };
app.boot();
