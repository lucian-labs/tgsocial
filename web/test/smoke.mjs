/* Smoke test — serves web/ with python3 -m http.server, drives headless
 * Chromium against it, and asserts:
 *   - the page loads with zero console errors and no failed requests
 *   - the wordmark renders in Kaushan Script (computed font-family)
 *   - config.json loaded (or the "Missing config.json." card renders when absent)
 *   - TdClient reaches authorizationStateWaitPhoneNumber within 60 s
 *   - PRODUCT §2.13's premise: real TDLib refuses chat reads before
 *     authorization (searchPublicChat → 401) while getOption answers
 *   - PRODUCT §2.22.4: the demo, entered from a real sign-in screen with a
 *     real TDLib client running, makes no request to any origin but the page's
 *     own and constructs no client of its own
 *
 *   node test/smoke.mjs
 *
 * Chromium: the Playwright browser at /opt/pw-browsers if present, else
 * PLAYWRIGHT_BROWSERS_PATH, else ~/.cache/tgsocial-pw/browsers. The
 * `playwright` package resolves from PW_MODULE_DIR, then
 * ~/.cache/tgsocial-pw, then normal node resolution — never from a
 * node_modules inside this repo. When neither is present the test installs
 * both into ~/.cache/tgsocial-pw (one-off, ~100 MB download).
 */
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import { existsSync, readdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';
import { PREAUTH_QUERIES } from '../js/td.js';

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, '..');
const hasConfig = existsSync(join(web, 'config.json'));

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
    srv.on('error', reject);
  });
}

function waitFor(url, ms) {
  const end = Date.now() + ms;
  return new Promise((resolve, reject) => {
    const tick = async () => {
      try {
        const r = await fetch(url);
        if (r.ok) return resolve();
      } catch {}
      if (Date.now() > end) return reject(new Error('server did not start'));
      setTimeout(tick, 150);
    };
    tick();
  });
}

const PW_HOME = join(process.env.HOME ?? '', '.cache', 'tgsocial-pw');

function findPlaywright() {
  const candidates = [process.env.PW_MODULE_DIR, PW_HOME].filter(Boolean);
  for (const dir of candidates) {
    try {
      const req = createRequire(join(dir, 'package.json'));
      return req('playwright');
    } catch {}
  }
  try {
    return createRequire(import.meta.url)('playwright');
  } catch {}
  return null;
}

/** One-off install of playwright + chromium into ~/.cache/tgsocial-pw (outside the repo). */
function installPlaywright() {
  console.log(`# installing playwright + chromium into ${PW_HOME} (one-off)`);
  const env = { ...process.env, PLAYWRIGHT_BROWSERS_PATH: join(PW_HOME, 'browsers') };
  const a = spawnSync('npm', ['install', '--prefix', PW_HOME, '--no-audit', '--no-fund', 'playwright@1.62.1'], { stdio: 'inherit', env });
  if (a.status !== 0) return null;
  const b = spawnSync('npx', ['--prefix', PW_HOME, 'playwright', 'install', 'chromium'], { stdio: 'inherit', env, cwd: PW_HOME });
  if (b.status !== 0) return null;
  return findPlaywright();
}

function findExecutable() {
  if (process.env.PW_CHROMIUM) return process.env.PW_CHROMIUM;
  const roots = ['/opt/pw-browsers', process.env.PLAYWRIGHT_BROWSERS_PATH, join(PW_HOME, 'browsers')].filter(Boolean);
  for (const root of roots) {
    if (!existsSync(root)) continue;
    for (const dir of readdirSync(root)) {
      if (!/^chromium(_headless_shell)?-\d+/.test(dir)) continue;
      const paths = [
        join(root, dir, 'chrome-mac', 'Chromium.app', 'Contents', 'MacOS', 'Chromium'),
        join(root, dir, 'chrome-mac-arm64', 'Chromium.app', 'Contents', 'MacOS', 'Chromium'),
        join(root, dir, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell'),
        join(root, dir, 'chrome-headless-shell-mac-x64', 'chrome-headless-shell'),
        join(root, dir, 'chrome-headless-shell-linux64', 'chrome-headless-shell'),
        join(root, dir, 'chrome-mac', 'headless_shell'),
        join(root, dir, 'chrome-mac-arm64', 'headless_shell'),
        join(root, dir, 'chrome-linux', 'chrome'),
        join(root, dir, 'chrome-linux', 'headless_shell'),
      ];
      for (const p of paths) if (existsSync(p)) return p;
    }
  }
  return null; // let playwright use its own default
}

const port = await freePort();
const base = `http://127.0.0.1:${port}`;
const server = spawn('python3', ['-m', 'http.server', String(port), '--bind', '127.0.0.1'], { cwd: web, stdio: ['ignore', 'ignore', 'pipe'] });
let serverErr = '';
server.stderr.on('data', (d) => {
  serverErr += d.toString();
});

const failures = [];
const notes = [];
const ok = (cond, label) => {
  if (cond) console.log(`ok - ${label}`);
  else {
    console.log(`not ok - ${label}`);
    failures.push(label);
  }
};

try {
  await waitFor(`${base}/index.html`, 10000);
  const pw = findPlaywright() || installPlaywright();
  if (!pw) throw new Error('playwright package not found (set PW_MODULE_DIR to a directory containing node_modules/playwright)');
  const executablePath = findExecutable();
  const browser = await pw.chromium.launch({ headless: true, executablePath: executablePath || undefined });
  const page = await browser.newPage();
  const consoleErrors = [];
  const failedRequests = [];
  page.on('console', (m) => {
    if (m.type() === 'error') consoleErrors.push(m.text());
  });
  page.on('pageerror', (e) => consoleErrors.push(`pageerror: ${e.message}`));
  page.on('requestfailed', (r) => failedRequests.push(`${r.url()} ${r.failure()?.errorText ?? ''}`));
  page.on('response', (r) => {
    if (r.status() >= 400 && !r.url().endsWith('/config.json')) failedRequests.push(`${r.url()} ${r.status()}`);
  });

  await page.goto(`${base}/`, { waitUntil: 'load' });
  await page.waitForSelector('#view .card', { timeout: 15000 });

  const brandFont = await page.evaluate(() => {
    const el = document.querySelector('.brand, .wordmark');
    return el ? getComputedStyle(el).fontFamily : '';
  });
  ok(/Kaushan Script/.test(brandFont), `wordmark font-family is Kaushan Script (${brandFont})`);
  const fontLoaded = await page.evaluate(async () => {
    await document.fonts.ready;
    return document.fonts.check("16px 'Kaushan Script'");
  });
  ok(fontLoaded, 'Kaushan Script face is loaded (document.fonts.check)');

  const viewText = await page.evaluate(() => document.getElementById('view').textContent);
  if (hasConfig) {
    const configLoaded = await page.evaluate(() => !!window.__tgsocial?.app?.config?.apiId);
    ok(configLoaded, 'config.json loaded');
    ok(!/Missing config\.json/.test(viewText), 'no missing-config card');
    ok(await page.evaluate(() => !!(window.tdweb && window.tdweb.default)), 'tdweb UMD exposes window.tdweb.default');

    const state = await page.evaluate(
      () =>
        new Promise((resolve) => {
          const td = window.__tgsocial.td;
          const want = (s) => s && ['authorizationStateWaitPhoneNumber', 'authorizationStateReady', 'authorizationStateWaitCode', 'authorizationStateWaitPassword'].includes(s['@type']);
          if (want(td.authState)) return resolve(td.authState['@type']);
          const timer = setTimeout(() => resolve(td.authState?.['@type'] ?? 'none'), 60000);
          td.on('auth', (s) => {
            if (want(s)) {
              clearTimeout(timer);
              resolve(s['@type']);
            }
          });
        }),
      { timeout: 65000 },
    );
    ok(['authorizationStateWaitPhoneNumber', 'authorizationStateReady', 'authorizationStateWaitCode', 'authorizationStateWaitPassword'].includes(state), `TdClient reached ${state} within 60s`);
    const version = await page.evaluate(
      () => new Promise((resolve) => {
        const end = Date.now() + 8000;
        const tick = () => {
          const v = window.__tgsocial.td.tdlibVersion;
          if (v || Date.now() > end) return resolve(v);
          setTimeout(tick, 100);
        };
        tick();
      }),
    );
    notes.push(`TDLib version: ${version}`);
    if (state === 'authorizationStateWaitPhoneNumber') {
      const signin = await page.evaluate(() => document.querySelector('#view input[type="tel"]') !== null);
      ok(signin, 'sign-in screen shows the phone field');
    }
    // connection state tells us whether Telegram is reachable from this environment
    const conn = await page.evaluate(
      () =>
        new Promise((resolve) => {
          const td = window.__tgsocial.td;
          if (td.connectionState === 'connectionStateReady') return resolve(td.connectionState);
          const timer = setTimeout(() => resolve(td.connectionState ?? 'unknown'), 20000);
          td.on('connection', (c) => {
            if (c === 'connectionStateReady') {
              clearTimeout(timer);
              resolve(c);
            }
          });
        }),
      { timeout: 25000 },
    );
    if (conn === 'connectionStateReady') console.log('ok - Telegram reachable (connectionStateReady)');
    else notes.push(`environment: Telegram network not confirmed (connection state ${conn}); auth state machine still reached WaitPhoneNumber`);

    /* PRODUCT §2.13 / PUBLIC §intro — the finding that sent the public pages
     * to Telegram's preview instead of TDLib, held against the real bundled
     * library rather than a mock: a connected but unauthorized client answers
     * preauthentication requests and refuses every chat request. Still true,
     * still worth guarding — if it ever starts resolving, a public page could
     * be served by TDLib and the preview reader becomes a fallback rather than
     * the only door. Needs a live connection to mean anything, so it only
     * asserts once Telegram is reachable. */
    if (conn === 'connectionStateReady' && state === 'authorizationStateWaitPhoneNumber') {
      const preauth = await page.evaluate(async () => {
        const td = window.__tgsocial.td;
        const probe = async (query) => {
          try {
            const r = await td.send(query);
            return { ok: true, type: r?.['@type'] ?? null };
          } catch (e) {
            return { ok: false, code: e.code ?? 0, message: e.message };
          }
        };
        return {
          getOption: await probe({ '@type': 'getOption', name: 'version' }),
          searchPublicChat: await probe({ '@type': 'searchPublicChat', username: 'telegram' }),
        };
      }, { timeout: 30000 });
      ok(preauth.getOption.ok, `preauth: getOption answers before authorization (${preauth.getOption.type ?? preauth.getOption.message})`);
      ok(PREAUTH_QUERIES.has('getOption') && !PREAUTH_QUERIES.has('searchPublicChat'),
        'td.js PREAUTH_QUERIES lists what TDLib answers pre-auth, and no chat read');
      ok(preauth.searchPublicChat.ok === false && preauth.searchPublicChat.code === 401,
        `PRODUCT §2.13: searchPublicChat is refused before authorization (${preauth.searchPublicChat.ok ? 'RESOLVED — anonymous reads are possible now' : `${preauth.searchPublicChat.code} ${preauth.searchPublicChat.message}`})`);
    } else {
      notes.push('§2.13 preauth check skipped: needs connectionStateReady at WaitPhoneNumber');
    }
  } else {
    ok(/Missing config\.json\./.test(viewText), 'renders the Missing config.json. card without config');
    notes.push('config.json absent: TDLib boot assertion skipped');
  }

  // privacy page
  const p2 = await browser.newPage();
  p2.on('pageerror', (e) => consoleErrors.push(`privacy pageerror: ${e.message}`));
  const pr = await p2.goto(`${base}/privacy.html`, { waitUntil: 'load' });
  ok(pr.ok(), 'privacy.html serves');
  ok(await p2.evaluate(() => /Privacy policy/.test(document.body.textContent)), 'privacy.html renders the policy');
  await p2.close();

  /* PRODUCT §2.13 / PUBLIC §1 — the public reader, end to end and live.
   *
   * `python3 -m http.server` can neither proxy nor fall back to index.html, so
   * this stretch runs against web/scripts/dev-proxy.mjs — the development
   * stand-in for web/nginx-public.conf, doing what nginx does: the SPA
   * fallback, and `/tg/s/<channel>` proxied to the real t.me with the same
   * rules (only `/s/`, only a bare channel with an optional numeric
   * `?before=`). The refusals are local and always asserted; the parts that
   * need Telegram are asserted only when Telegram answered earlier in this
   * run, and reported as an environment note otherwise.
   *
   * When this fails on the live page but web/test/flows.mjs still passes on
   * the fixtures, Telegram changed its markup: refresh web/test/fixtures/. */
  {
    const devPort = await freePort();
    const proxy = spawn('node', [join(web, 'scripts', 'dev-proxy.mjs'), '--port', String(devPort)], { stdio: 'ignore' });
    try {
      const devBase = `http://127.0.0.1:${devPort}`;
      await waitFor(`${devBase}/index.html`, 10000);
      const get = async (path) => {
        const r = await fetch(`${devBase}${path}`);
        return { status: r.status, headers: r.headers, body: await r.text() };
      };
      // NOTE — everything in this block runs against web/scripts/dev-proxy.mjs,
      // never against web/nginx-public.conf, which nothing in this repo can
      // apply. It asserts that the two agree on the rules, not that the shipped
      // config obeys them: the nginx side of `?before=<digits>` is the
      // `if ($args !~ …)` guard (a location regex cannot see a query string at
      // all), and its cache needs `proxy_ignore_headers` because t.me sends
      // `Set-Cookie` and `Cache-Control: no-store` on every response. Both are
      // in the file; verifying them wants a real nginx in the loop.
      const refused = await Promise.all(['/tg/s/bad-name', '/tg/s/x', '/tg/tastycrow', '/tg/s/tastycrow?before=abc', '/tg/s/tastycrow?q=x', '/tg/s/tastycrow/extra'].map((p) => get(p)));
      ok(refused.every((r) => r.status === 404), 'public proxy: anything that is not a bare channel with an optional ?before=<digits> is refused');
      ok((await get('/f/tastycrow')).body.includes('<div class="app" id="app">'), 'public proxy: the SPA fallback serves index.html for a public link');

      const live = await get('/tg/s/tastycrow');
      if (live.status === 200 && /tgme_widget_message/.test(live.body)) {
        ok(/data-post="tastycrow\/\d+"/.test(live.body) && /<time datetime=/.test(live.body),
          'public proxy: the live t.me preview still carries data-post and <time datetime>');
        // Telegram's HTML reaches the reader as a string, never as a document:
        // relabelled and sandboxed, and its Set-Cookie dropped (PUBLIC §1)
        ok(/^text\/plain/.test(live.headers.get('content-type') ?? '')
          && live.headers.get('x-content-type-options') === 'nosniff'
          && /sandbox/.test(live.headers.get('content-security-policy') ?? '')
          && !live.headers.get('set-cookie'),
          `public proxy: the preview leaves as inert text (${live.headers.get('content-type')})`);
        const p3 = await browser.newPage();
        p3.on('console', (m) => {
          if (m.type() === 'error') consoleErrors.push(`public: ${m.text()}`);
        });
        p3.on('pageerror', (e) => consoleErrors.push(`public pageerror: ${e.message}`));
        await p3.goto(`${devBase}/f/tastycrow`, { waitUntil: 'load' });
        await p3.waitForSelector('#view article.post', { timeout: 25000 });
        const pub = await p3.evaluate(() => ({
          publicMode: window.__tgsocial.app.publicMode,
          repo: !!window.__tgsocial.repo,
          status: document.getElementById('status').textContent,
          posts: document.querySelectorAll('#view article.post').length,
          comment: [...document.querySelectorAll('#view article.post .btn')].some((b) => /Comment/i.test(b.textContent)),
          nag: document.querySelector('#dock .nag .nag-text')?.textContent ?? null,
        }));
        ok(pub.publicMode && !pub.repo && pub.status === 'Public', 'public: a real anonymous read — public page, no TDLib, Public pill');
        ok(pub.posts > 0 && !pub.comment, `public: ${pub.posts} live posts render with no Comment button`);
        ok(pub.nag === 'Follow this feed in tgsocial.', 'public: the nag is docked');
        await p3.close();
      } else {
        notes.push(`environment: t.me not reachable through the proxy (status ${live.status}); the live public-page assertions were skipped`);
      }

      /* PRODUCT §2.22.4 — "Web asserts it end to end", and this is that end.
       *
       * It runs here rather than in test/flows.mjs because flows drives
       * test/mock-tdweb.js, which makes no request whatever the demo does: a
       * no-network assertion against a mock still passes with the property
       * removed. This tab boots the real bundled tdweb, waits until a real
       * TdClient has been constructed — asserted, so the counter below is
       * known to be measuring something — and only then taps `Look Around
       * First`. From the tap on, every request the tab makes is recorded.
       *
       * The visit arrives on a public link (§2.13) with an ordinary `tgs.*`
       * leftover in local storage — the shape whose destination the demo used
       * to spend on its way in, landing on a real channel the fixture world
       * has never heard of, or swallowing the link quietly depending on which
       * render got there first. §2.1 enters at Feed, the destination is parked
       * rather than spent, and it is named on the sign-in screen again after
       * `Leave Demo`.
       */
      if (hasConfig) {
        const demoCtx = await browser.newContext();
        const d = await demoCtx.newPage();
        await d.addInitScript(() => {
          // tdweb is a UMD bundle that assigns window.tdweb; this wraps its
          // TdClient on the way in and counts constructions
          let real;
          window.__tdBuilds = 0;
          Object.defineProperty(window, 'tdweb', {
            configurable: true,
            get: () => real,
            set: (v) => {
              real = v;
              if (v && typeof v.default === 'function') {
                const Client = v.default;
                v.default = function (...args) {
                  window.__tdBuilds += 1;
                  return new Client(...args);
                };
                v.default.prototype = Client.prototype;
              }
            },
          });
          // window/document listeners, net of removals: §2.22 makes enter →
          // leave a loop a reader can run any number of times
          window.__lcount = {};
          for (const [name, target] of [['win', window], ['doc', document]]) {
            const add = target.addEventListener.bind(target);
            const remove = target.removeEventListener.bind(target);
            target.addEventListener = (type, ...rest) => {
              window.__lcount[`${name}:${type}`] = (window.__lcount[`${name}:${type}`] ?? 0) + 1;
              return add(type, ...rest);
            };
            target.removeEventListener = (type, ...rest) => {
              window.__lcount[`${name}:${type}`] = (window.__lcount[`${name}:${type}`] ?? 0) - 1;
              return remove(type, ...rest);
            };
          }
          // §2.13's `hasLocalSession`: any leftover tgs.* key is a reader
          // coming back to their own app, so this URL is the app, not a
          // public page — and the sign-in screen names the destination
          try {
            localStorage.setItem('tgs.nagDismissed', '1');
          } catch {}
        });
        let phase = 'boot';
        d.on('console', (m) => {
          if (m.type() === 'error') consoleErrors.push(`demo[${phase}]: ${m.text()}`);
        });
        d.on('pageerror', (e) => consoleErrors.push(`demo[${phase}] pageerror: ${e.message}`));
        let watching = false;
        const offsite = [];
        d.on('request', (r) => {
          const url = r.url();
          if (!watching || url.startsWith(devBase) || url.startsWith('data:') || url.startsWith('blob:')) return;
          offsite.push(url);
        });
        /**
         * TDLib's transport is a socket, not a fetch, so `request` alone would
         * never see it. Every socket this tab has ever opened is checked at the
         * end of the walk: a demo that left the client running is a demo with
         * `wss://…/apiws` still open, whatever it did or did not send down it.
         * Which side of the tap a socket opened on is not asked, because the
         * event arrives asynchronously and the answer would be a coin toss.
         */
        const sockets = [];
        d.on('websocket', (ws) => sockets.push(ws));

        try {
          await d.goto(`${devBase}/f/tastycrow`, { waitUntil: 'load' });
          await d.waitForFunction(
            () => window.__tgsocial?.td?.authState?.['@type'] === 'authorizationStateWaitPhoneNumber',
            null, { timeout: 120000 },
          );
          const built = await d.evaluate(() => window.__tdBuilds);
          ok(built >= 1, `demo: a real TdClient was constructed at boot (${built}) — the count below is measuring something`);
          ok(await d.evaluate(() => /Sign in to see @tastycrow\./.test(document.getElementById('view').innerText)),
            '§2.13: the visit arrived on a public link and sign-in names where it was going');

          watching = true;
          phase = 'enter';
          await d.click('#view .signin-demo button.btn:has-text("Look Around First")');
          await d.waitForSelector('#view article.post', { timeout: 30000 });
          const entered = await d.evaluate(() => ({
            hash: location.hash,
            posts: document.querySelectorAll('#view article.post').length,
            text: document.getElementById('view').innerText.slice(0, 120),
            pill: document.getElementById('status').textContent,
            gold: document.getElementById('status').classList.contains('gold'),
            strip: document.querySelector('#head .demo-strip')?.textContent ?? null,
            noClient: window.__tgsocial.td.client === null,
            repo: window.__tgsocial.app.repo.constructor.name,
          }));
          ok(entered.hash === '#/feed' && entered.posts > 0 && !/Channel not found\./.test(entered.text),
            `§2.1: Look Around First enters at Feed, public link or not (${entered.hash}, ${entered.posts} posts)`);
          ok(entered.pill === 'Demo' && !entered.gold && entered.strip === 'Demo. Everyone here is invented. Nothing leaves this device.',
            `§2.22: the neutral Demo pill and the strip are up (${entered.pill}, ${entered.strip})`);
          ok(entered.noClient && entered.repo === 'DemoRepo',
            `§2.22.4: the TDLib handle is closed and the repo is a different object (${entered.repo})`);

          // the walk §2.22.4 names: Feed, a thread, a profile, a full-screen photo
          phase = 'walk';
          await d.evaluate(() => { location.hash = '#/thread/demo_tidewright/144'; });
          await d.waitForFunction(() => /COMMENTS · 5/.test(document.getElementById('view').innerText), null, { timeout: 20000 });
          await d.evaluate(() => { location.hash = '#/node/tgs_demo_wren'; });
          await d.waitForFunction(() => /Wren Alderiss/.test(document.getElementById('view').innerText), null, { timeout: 20000 });
          await d.evaluate(() => { location.hash = '#/feed'; });
          await d.waitForSelector('#view .post-mosaic-tile', { timeout: 20000 });
          await d.locator('#view .post-mosaic-tile').first().click();
          await d.waitForSelector('.viewer', { timeout: 15000 });
          ok(await d.evaluate(() => document.querySelector('.demo-strip')?.getBoundingClientRect().height > 0),
            '§2.22: the strip stays painted in the full-screen viewer, where the topbar hides');
          await d.click('.viewer button.btn.ghost');
          await d.waitForFunction(() => !document.querySelector('.viewer'), null, { timeout: 10000 });

          phase = 'checks';
          // the socket closes a fraction of a second after the tap; give a slow
          // machine ten of them before calling it open
          for (let i = 0; i < 40 && sockets.some((ws) => !ws.isClosed()); i += 1) await d.waitForTimeout(250);
          const open = sockets.filter((ws) => !ws.isClosed()).map((ws) => ws.url());
          ok(offsite.length === 0, `§2.22.4: the demo made no request to any origin but this page's own${offsite.length ? `: ${offsite.slice(0, 4).join(' | ')}` : ''}`);
          ok(open.length === 0,
            `§2.22.4: every socket the client had is closed while the demo runs (${sockets.length} opened${open.length ? `, still open: ${open.join(' | ')}` : ''})`);
          ok(await d.evaluate(() => window.__tdBuilds) === built && await d.evaluate(() => window.__tgsocial.td.client === null),
            `§2.22.4: no TDLib client was constructed while the demo ran, and the handle stayed closed (${built} in all)`);
          watching = false;

          // §2.22 — leaving, and coming back: the destination is still there,
          // and the cycle leaves nothing behind (td.js used to leak five
          // window/document listeners per pass)
          const before = await d.evaluate(() => ({ ...window.__lcount }));
          phase = 'leave';
          await d.evaluate(() => window.__tgsocial.app.leaveDemo());
          await d.waitForSelector('#view input[type="tel"]', { timeout: 30000 });
          const left = await d.evaluate(() => ({
            demo: window.__tgsocial.demo,
            strip: !!document.querySelector('.demo-strip'),
            names: /Sign in to see @tastycrow\./.test(document.getElementById('view').innerText),
          }));
          ok(left.demo === null && !left.strip && left.names,
            '§2.22 / §2.13: Leave Demo returns to sign-in with the public link still waiting');
          await d.waitForFunction(
            () => window.__tgsocial?.td?.authState?.['@type'] === 'authorizationStateWaitPhoneNumber',
            null, { timeout: 120000 },
          );
          phase = 'reenter';
          await d.click('#view .signin-demo button.btn:has-text("Look Around First")');
          await d.waitForSelector('#view article.post', { timeout: 30000 });
          const after = await d.evaluate(() => ({ ...window.__lcount }));
          const drift = ['win:online', 'win:pagehide', 'doc:visibilitychange', 'doc:freeze']
            .filter((k) => (after[k] ?? 0) !== (before[k] ?? 0))
            .map((k) => `${k} ${before[k] ?? 0}→${after[k] ?? 0}`);
          ok(drift.length === 0, `§2.22: an enter → leave → enter cycle leaves no listener behind${drift.length ? `: ${drift.join(', ')}` : ''}`);
        } finally {
          await demoCtx.close();
        }
      } else {
        notes.push('config.json absent: the §2.22.4 demo walk was skipped (it needs a real TDLib boot to close)');
      }
    } finally {
      proxy.kill();
    }
  }

  const realFailures = failedRequests.filter((f) => !/favicon\.ico/.test(f));
  ok(consoleErrors.length === 0, `zero console errors${consoleErrors.length ? `: ${consoleErrors.join(' | ')}` : ''}`);
  ok(realFailures.length === 0, `zero failed requests${realFailures.length ? `: ${realFailures.join(' | ')}` : ''}`);

  await browser.close();
} catch (e) {
  failures.push(e.message);
  console.log(`not ok - ${e.message}`);
} finally {
  server.kill();
}

for (const n of notes) console.log(`# ${n}`);
if (serverErr && failures.length) console.log(`# server stderr: ${serverErr.trim().split('\n').slice(-3).join(' / ')}`);
if (failures.length) {
  console.log(`# smoke: ${failures.length} failure(s)`);
  process.exit(1);
}
console.log('# smoke: all checks passed');
