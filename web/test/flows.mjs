/* Flow test — every screen in PRODUCT.md §2 against the mock TDLib
 * (test/mock-tdweb.js, served in place of vendor/tdweb/tdweb.js by route
 * interception) and, for the public pages (§2.13), against real t.me/s/ pages
 * saved in test/fixtures/ and served at `/tg/s/`. No network either way.
 * Not part of `npm test`; run on demand:
 *
 *   node test/flows.mjs [--shots <dir>]
 *
 * Asserts the copy on each screen, optimistic follow + rollback, FLOOD_WAIT
 * toast, compose → Posted., sign-out wipe, the public reader (parser, routes,
 * merge, refusals, XSS) and zero console errors overall.
 */
import { createServer } from 'node:net';
import { createServer as createHttpServer } from 'node:http';
import { createReadStream, existsSync, readdirSync, readFileSync, mkdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, extname, join, normalize } from 'node:path';
import { createRequire } from 'node:module';

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, '..');
const shotsDir = process.argv.includes('--shots') ? process.argv[process.argv.indexOf('--shots') + 1] : null;
if (shotsDir) mkdirSync(shotsDir, { recursive: true });
const PW_HOME = join(process.env.HOME ?? '', '.cache', 'tgsocial-pw');

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
        if ((await fetch(url)).ok) return resolve();
      } catch {}
      if (Date.now() > end) return reject(new Error('server did not start'));
      setTimeout(tick, 150);
    };
    tick();
  });
}
/**
 * The deploy host serves web/ with `try_files $uri $uri/ /index.html`, which is
 * what makes a public link (/f/<channel>, PRODUCT §2.13) load the app. This
 * server does the same so the flow test exercises the real thing: existing
 * files as themselves, extensionless paths as index.html, everything else 404.
 */
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.wasm': 'application/wasm',
  '.txt': 'text/plain; charset=utf-8',
};

/**
 * PUBLIC.md §1's `/tg/s/` proxy, served from web/test/fixtures/ so this test
 * stays offline. Production is nginx (web/nginx-public.conf); local runs are
 * web/scripts/dev-proxy.mjs. Same rules as both: only `/s/`, only a bare
 * channel with an optional `?before=<id>`, anything else 404.
 *
 * A `?before=` page with no fixture of its own serves `_end.html` — a 200 with
 * an empty history, which is what Telegram returns once there is nothing
 * older. That is also why it is a 200 and not a 404: a failed request would
 * be a console error, and this test asserts there are none.
 *
 * The headers are the shipped ones: the preview body is Telegram's HTML, read
 * by the parser as a string, so it leaves as inert `text/plain` and never as a
 * document that could run Telegram's scripts on our origin.
 */
const PREVIEW_HEADERS = {
  'content-type': 'text/plain; charset=utf-8',
  'x-content-type-options': 'nosniff',
  'content-security-policy': "sandbox; default-src 'none'",
  'access-control-allow-origin': '*',
  'cache-control': 'no-store',
};

function servePreview(url, res) {
  const m = /^\/tg\/s\/([A-Za-z0-9_]{4,32})\/?$/.exec(url.pathname);
  const before = url.searchParams.get('before');
  // the whole query is checked, as nginx does (`if ($args !~ "^(before=[0-9]+)?$")`)
  const legal = m && /^(\?before=[0-9]+)?$/.test(url.search) && (before === null || /^\d+$/.test(before));
  if (!legal) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
    return;
  }
  const dir = join(here, 'fixtures');
  const candidates = before
    ? [join(dir, `${m[1]}.before-${before}.html`), join(dir, '_end.html')]
    : [join(dir, `${m[1]}.html`), join(dir, '_end.html')];
  const file = candidates.find((f) => existsSync(f));
  res.writeHead(200, PREVIEW_HEADERS);
  createReadStream(file).pipe(res);
}

function serveStatic(root, port) {
  const srv = createHttpServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname.startsWith('/tg/')) {
      servePreview(url, res);
      return;
    }
    // nginx serves a malformed escape (/f/%zz) through try_files without
    // complaint; decodeURIComponent throws on it, so this must not either
    const raw = url.pathname;
    let decoded;
    try {
      decoded = decodeURIComponent(raw);
    } catch {
      decoded = raw;
    }
    let rel = normalize(decoded);
    if (rel.endsWith('/')) rel = join(rel, 'index.html');
    let file = join(root, rel);
    const inside = file === root || file.startsWith(root + '/');
    if (!inside || !existsSync(file) || statSync(file).isDirectory()) {
      file = extname(rel) ? null : join(root, 'index.html');
    }
    if (!file) {
      res.writeHead(404, { 'content-type': 'text/plain' });
      res.end('not found');
      return;
    }
    res.writeHead(200, { 'content-type': MIME[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
    createReadStream(file).pipe(res);
  });
  return new Promise((resolve, reject) => {
    srv.on('error', reject);
    srv.listen(port, '127.0.0.1', () => resolve(srv));
  });
}

function findPlaywright() {
  for (const dir of [process.env.PW_MODULE_DIR, PW_HOME].filter(Boolean)) {
    try {
      return createRequire(join(dir, 'package.json'))('playwright');
    } catch {}
  }
  try {
    return createRequire(import.meta.url)('playwright');
  } catch {}
  return null;
}
function findExecutable() {
  if (process.env.PW_CHROMIUM) return process.env.PW_CHROMIUM;
  for (const root of ['/opt/pw-browsers', process.env.PLAYWRIGHT_BROWSERS_PATH, join(PW_HOME, 'browsers')].filter(Boolean)) {
    if (!existsSync(root)) continue;
    for (const dir of readdirSync(root)) {
      if (!/^chromium(_headless_shell)?-\d+/.test(dir)) continue;
      for (const p of [
        join(root, dir, 'chrome-mac', 'Chromium.app', 'Contents', 'MacOS', 'Chromium'),
        join(root, dir, 'chrome-mac-arm64', 'Chromium.app', 'Contents', 'MacOS', 'Chromium'),
        join(root, dir, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell'),
        join(root, dir, 'chrome-headless-shell-mac-x64', 'chrome-headless-shell'),
        join(root, dir, 'chrome-headless-shell-linux64', 'chrome-headless-shell'),
        join(root, dir, 'chrome-linux', 'chrome'),
      ]) if (existsSync(p)) return p;
    }
  }
  return null;
}

const failures = [];
const ok = (cond, label) => {
  console.log(`${cond ? 'ok' : 'not ok'} - ${label}`);
  if (!cond) failures.push(label);
};

/** 1×1 transparent PNG — stands in for every Telegram CDN picture a fixture points at. */
const PIXEL = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');

const port = await freePort();
const base = `http://127.0.0.1:${port}`;
const server = await serveStatic(web, port);
const mock = readFileSync(join(here, 'mock-tdweb.js'), 'utf8');
let shot = 0;

try {
  await waitFor(`${base}/index.html`, 10000);
  const pw = findPlaywright();
  if (!pw) throw new Error('playwright not found (run test/smoke.mjs once to install it)');
  const browser = await pw.chromium.launch({ headless: true, executablePath: findExecutable() || undefined });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, permissions: ['clipboard-read', 'clipboard-write'] });
  await ctx.route('**/vendor/tdweb/tdweb.js', (route) => route.fulfill({ status: 200, contentType: 'application/javascript', body: mock }));
  const page = await ctx.newPage();
  globalThis.__page = page;
  const errors = [];
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text());
  });
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  const snapPage = async (p, name) => {
    if (!shotsDir) return;
    shot += 1;
    await p.screenshot({ path: join(shotsDir, `${String(shot).padStart(2, '0')}-${name}.png`), fullPage: true });
  };
  const snap = (name) => snapPage(page, name);
  const text = () => page.evaluate(() => document.getElementById('view').innerText);
  const toastText = () => page.evaluate(() => document.getElementById('toast').textContent);
  const status = () => page.evaluate(() => document.getElementById('status').textContent);
  // innerText applies CSS text-transform, so anything in a pill/button/label/h3 reads uppercase
  const waitText = async (re, ms = 8000) => {
    await page.waitForFunction(([src, flags]) => new RegExp(src, flags).test(document.getElementById('view').innerText), [re.source, re.flags], { timeout: ms });
  };
  const waitToast = async (re, ms = 6000) => {
    await page.waitForFunction(([src, flags]) => new RegExp(src, flags).test(document.getElementById('toast').textContent) && document.getElementById('toast').classList.contains('show'), [re.source, re.flags], { timeout: ms });
  };

  // ── fresh account: sign in → setup → create node → feeds ────────────────
  await page.goto(`${base}/?mock=fresh&mockflood=1`, { waitUntil: 'load' });
  await waitText(/Your Telegram, as a feed\./);
  await page.waitForSelector('input[type="tel"]', { timeout: 15000 });
  ok(/PHONE NUMBER/i.test(await text()), 'sign-in: phone step');
  ok((await status()) === 'Signed out', 'status pill: Signed out');
  ok(await page.evaluate(() => document.getElementById('dock').hidden), 'shell: tab bar hidden on Sign in');
  await snap('signin-phone');
  await page.fill('input[type="tel"]', '123');
  await page.click('button.btn.primary');
  await waitToast(/Telegram didn't accept that number\./);
  ok(true, 'sign-in: invalid number toast');
  await page.fill('input[type="tel"]', '+16045550199');
  await page.click('button.btn.primary');
  // innerText uppercases the SEND CODE button, so wait for the code input rather than the word CODE
  await page.waitForSelector('input[inputmode="numeric"]', { timeout: 10000 });
  await snap('signin-code');
  ok(/Use another number/i.test(await text()), 'sign-in: code step with Use another number');
  await page.fill('input[inputmode="numeric"]', '99999');
  await page.click('button.btn.primary');
  await waitToast(/That code didn't match\./);
  ok(true, 'sign-in: wrong code toast');
  await page.fill('input[inputmode="numeric"]', '22222');
  await page.click('button.btn.primary');
  await waitText(/PASSWORD/);
  ok(/the usual/.test(await text()), 'sign-in: password hint shown');
  await snap('signin-password');
  await page.fill('input[type="password"]', 'nope');
  await page.click('button.btn.primary');
  await waitToast(/That password didn't match\./);
  await page.fill('input[type="password"]', 'hunter2');
  await page.click('button.btn.primary');

  await waitText(/Make your node\./);
  ok(true, 'setup: shown when no node');
  ok(await page.evaluate(() => document.getElementById('dock').hidden), 'shell: tab bar hidden on Setup');
  await page.waitForFunction(() => /Available|Taken/i.test(document.getElementById('view').innerText), null, { timeout: 8000 });
  ok(/tgs_elijah/.test(await page.inputValue('#view input[type="text"]')), 'setup: suggested username tgs_<username>');
  ok(/Available|Taken/i.test(await text()), 'setup: availability pill');
  await snap('setup-node');
  await page.fill('#view input[type="text"]', 'tgs_ana');
  await page.waitForFunction(() => /Taken/i.test(document.getElementById('view').innerText), null, { timeout: 8000 });
  ok(true, 'setup: Taken pill for an existing username');
  await page.fill('#view input[type="text"]', 'tgs_newbie');
  await page.waitForFunction(() => /Available/i.test(document.getElementById('view').innerText), null, { timeout: 8000 });
  await page.click('button.btn.primary');
  await waitText(/Pick the channels that post as you\./);
  ok((await status()) !== 'Signed out', 'status pill after sign-in');
  await page.waitForFunction(() => /WaveLoop devlog/.test(document.getElementById('view').innerText), null, { timeout: 8000 });
  const feedsText = await text();
  ok(/Needs a public link/.test(feedsText), 'setup: private channel shows Needs a public link');
  ok(/Très Buchet/.test(feedsText), 'setup: admin channel listed');
  await snap('setup-feeds');
  const toggles = page.locator('#view .toggle:not([disabled])');
  await toggles.nth(0).click();
  await page.waitForFunction(() => /Verified|verify it's yours/i.test(document.getElementById('view').innerText), null, { timeout: 8000 });
  const afterToggle = await text();
  ok(/Verified|verify it's yours\?/i.test(afterToggle), 'setup: verify prompt or Verified pill after toggle');
  await toggles.nth(1).click();
  await page.waitForFunction(() => /verify it's yours\?/.test(document.getElementById('view').innerText), null, { timeout: 8000 });
  await snap('setup-verify');
  for (let i = 0; i < 3 && (await page.locator('#view .verify-hint button.btn:has-text("Verify")').count()) > 0; i += 1) {
    await page.locator('#view .verify-hint button.btn:has-text("Verify")').first().click();
    await page.waitForTimeout(200);
  }
  await page.waitForFunction(() => (document.getElementById('view').innerText.match(/VERIFIED/g) || []).length >= 2, null, { timeout: 8000 });
  ok(true, 'setup: Verify appends backlink and shows Verified');
  await page.click('button.btn.primary:has-text("Save Feeds")');
  // first editMessageText hits the mocked FLOOD_WAIT → toast, then retries
  await waitToast(/Telegram asked us to wait 1 s\./);
  ok(true, 'FLOOD_WAIT toast with seconds');
  await waitToast(/Feeds saved\./, 10000);
  ok(true, 'setup: Save Feeds writes the card');
  await page.waitForFunction(() => location.hash === '#/feed', null, { timeout: 8000 });

  // ── feed (fresh node: two own feeds, no follows) ─────────────────────────
  await page.waitForSelector('#view article.post', { timeout: 15000 });
  ok(await page.evaluate(() => !document.getElementById('dock').hidden && !!document.querySelector('#dock .tabs.floating')), 'shell: floating tab bar docked over the feed');
  const posts = await page.locator('#view article.post').count();
  ok(posts >= 5, `feed: ${posts} posts rendered from own feeds`);
  await page.waitForFunction(() => /That's everything\./.test(document.getElementById('view').innerText), null, { timeout: 15000 });
  ok(true, "feed: That's everything. once sources are exhausted");
  await snap('feed-fresh');

  // ── explore ──────────────────────────────────────────────────────────────
  await page.click('.tabs button:has-text("Explore")');
  await waitText(/NEARBY/);
  await page.waitForFunction(() => /Followed by|Follow someone/.test(document.getElementById('view').innerText), null, { timeout: 10000 });
  await page.waitForFunction(() => !/Loading…/.test(document.getElementById('view').innerText), null, { timeout: 10000 });
  const exploreText = await text();
  ok(/No nodes found|Zed|Carol/.test(exploreText), 'explore: directory populated (prefix + index group)');
  ok(!/Dave/.test(exploreText), 'explore: public: no node hidden');
  ok(!/Future/.test(exploreText), 'explore: v2 card not listed as a node');
  await snap('explore-fresh');
  await page.fill('#view input[type="search"]', 'nobody_here_x');
  await page.press('#view input[type="search"]', 'Enter');
  await waitToast(/Not a tgsocial node\./);
  ok(true, 'explore: Not a tgsocial node. toast');
  await page.fill('#view input[type="search"]', '@tgs_future');
  await page.press('#view input[type="search"]', 'Enter');
  await waitToast(/Newer card\. Update the app\./);
  ok(true, 'explore: v2 → Newer card. Update the app.');
  await page.fill('#view input[type="search"]', 'https://t.me/tgs_ana');
  await page.press('#view input[type="search"]', 'Enter');
  await waitText(/Voice, product, Vancouver\./);

  // ── node profile + follow (optimistic) ───────────────────────────────────
  const profile = await text();
  ok(/Ana Iliovic/.test(profile) && /@tgs_ana/.test(profile) && /anailiovic\.com/.test(profile), 'profile: name, username, link');
  ok(/FEEDS/.test(profile) && (await page.evaluate(() => [...document.querySelectorAll('#view h3')].some((x) => /FOLLOWS/.test(x.innerText) && x.querySelector('.mark-count')?.textContent === '3'))), 'profile: feeds + follows count');
  await page.waitForFunction(() => /VERIFIED/.test(document.getElementById('view').innerText), null, { timeout: 8000 });
  ok(true, 'profile: Verified pill on backlinked feed');
  ok(await page.evaluate(() => document.querySelector('#topbar-lead .btn')?.textContent.includes('Back')), 'push screen: ‹ Back in the topbar');
  await snap('profile');
  await page.click('#view .profile-head button.btn.primary:has-text("Follow")');
  await page.waitForFunction(() => /UNFOLLOW/i.test(document.getElementById('view').innerText), null, { timeout: 8000 });
  ok(await page.evaluate(() => window.__tgsocial.repo.myCard.follows.includes('tgs_ana')), 'follow: card updated');
  await page.waitForFunction(() => /^follows: @tgs_ana$/m.test(window.__mock.pinned[window.__tgsocial.repo.myNode.chatId].content.text.text), null, { timeout: 8000 });
  ok(true, 'follow: pinned card on Telegram updated');
  // rollback: make the next edit fail
  await page.evaluate(() => {
    const c = window.__mock.client;
    const orig = c.handle.bind(c);
    c.handle = (q) => {
      if (q['@type'] === 'editMessageText') {
        c.handle = orig;
        throw { '@type': 'error', code: 400, message: 'CHAT_WRITE_FORBIDDEN' };
      }
      return orig(q);
    };
  });
  await page.click('#view .profile-head button.btn:has-text("Unfollow")');
  await waitToast(/Couldn't update your card\. CHAT_WRITE_FORBIDDEN/);
  await page.waitForFunction(() => /UNFOLLOW/i.test(document.getElementById('view').innerText), null, { timeout: 8000 });
  ok(await page.evaluate(() => window.__tgsocial.repo.myCard.follows.includes('tgs_ana')), 'follow: rolled back on failure with toast');

  // PROTOCOL §4.4: a write starts from the pinned message as Telegram holds it now, not the local copy.
  // Simulate another device having added follows and a bio since we last read our card.
  const merged = await page.evaluate(async () => {
    const repo = window.__tgsocial.repo;
    const m = window.__mock.pinned[repo.myNode.chatId];
    window.__before = m.content.text.text;
    m.content.text.text = m.content.text.text.replace(/^bio:.*$/m, 'bio: From the phone').replace(/^follows:.*$/m, (l) => `${l} @tgs_bob @tgs_carol`);
    if (!/^bio:/m.test(m.content.text.text)) m.content.text.text = m.content.text.text.replace('public:', 'bio: From the phone\npublic:');
    await repo.follow('tgs_dave');
    return { server: m.content.text.text, local: repo.myCard };
  });
  ok(/follows: @tgs_ana @tgs_bob @tgs_carol @tgs_dave$/m.test(merged.server) && /^bio: From the phone$/m.test(merged.server), 'write: rebased on the fresh pinned card (other-device edits kept)');
  ok(merged.local.follows.join(' ') === 'tgs_ana tgs_bob tgs_carol tgs_dave' && merged.local.bio === 'From the phone', 'write: local copy replaced by the merged card');
  // put the world back as it was (the rest of the walk expects one follow and no bio)
  await page.evaluate(async () => {
    const repo = window.__tgsocial.repo;
    window.__mock.pinned[repo.myNode.chatId].content.text.text = window.__before;
    await repo.readNode(repo.myNode.username, { force: true });
  });

  // PROTOCOL §4.5 / PRODUCT §4: a read that fails keeps the cached card; only a definite answer replaces it.
  const kept = await page.evaluate(async () => {
    const repo = window.__tgsocial.repo;
    const c = window.__mock.client;
    const orig = c.handle.bind(c);
    repo.chatIdByUsername.clear();
    c.handle = (q) => {
      if (q['@type'] === 'searchPublicChat' || q['@type'] === 'getChatPinnedMessage') throw { '@type': 'error', code: 500, message: 'Request aborted' };
      return orig(q);
    };
    let threw = false;
    try {
      await repo.readNode('tgs_ana', { force: true });
    } catch (e) {
      threw = true;
    }
    const ana = repo.cachedCard('tgs_ana');
    let mineThrew = false;
    try {
      await repo.readNode(repo.myNode.username, { force: true });
    } catch (e) {
      mineThrew = true;
    }
    const mine = repo.myCard;
    let writeFailed = false;
    try {
      await repo.follow('tgs_dave');
    } catch (e) {
      writeFailed = true;
    }
    c.handle = orig;
    const server = window.__mock.pinned[repo.myNode.chatId].content.text.text;
    return { threw, anaFeeds: ana?.card?.feeds ?? [], mineThrew, mineFollows: mine?.follows ?? [], writeFailed, server, localFollows: repo.myCard?.follows ?? [] };
  });
  ok(kept.threw && kept.anaFeeds.includes('ana_notes'), 'read: transient failure rejects and keeps the cached card');
  ok(kept.mineThrew && kept.mineFollows.includes('tgs_ana'), 'read: my own card survives a failed refresh');
  ok(kept.writeFailed && /follows: @tgs_ana$/m.test(kept.server) && !/tgs_dave/.test(kept.server), 'write: no fresh read, no write (server card untouched)');
  ok(kept.localFollows.join(' ') === 'tgs_ana', 'write: optimistic follow rolled back after the failed read');

  // feed channel (PRODUCT §2.6): Verified pill top right, kebab beside it
  await page.click('#view .feed-row:has-text("ana_notes")');
  await waitText(/@ana_notes/);
  await page.waitForSelector('#view article.post', { timeout: 10000 });
  const chText = await text();
  ok(/Ana's notes/.test(chText) && /VERIFIED/.test(chText), 'channel: header with the Verified pill');
  ok(await page.evaluate(() => {
    const head = document.querySelector('#view .profile-head');
    const corner = head?.querySelector('.head-actions');
    if (!corner) return false;
    const pillEl = corner.querySelector('.pill.gold');
    const kebab = corner.querySelector('button.kebab');
    if (!pillEl || !kebab) return false;
    // the pill sits in the header's top-right corner, and the kebab is right of it
    const h = head.getBoundingClientRect();
    const p = pillEl.getBoundingClientRect();
    const k = kebab.getBoundingClientRect();
    return p.top < h.top + h.height / 2 && p.right > h.left + h.width / 2 && k.left >= p.right;
  }), 'channel: Verified pill top-right, kebab immediately right of it');
  // …and it reserves its own space: the corner never paints over the centred
  // 72pt avatar. The 390pt default clears it by 2px, so the narrow widths that
  // actually collide have to be measured explicitly.
  const cornerClearsAvatar = async (w) => {
    await page.setViewportSize({ width: w, height: 844 });
    await page.waitForFunction(() => !!document.querySelector('#view .profile-head .head-actions'), null, { timeout: 5000 });
    return page.evaluate(() => {
      const head = document.querySelector('#view .profile-head');
      const hits = (a, b) => Math.min(a.right, b.right) - Math.max(a.left, b.left) > 0 &&
        Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 0;
      const av = head.querySelector('.avatar').getBoundingClientRect();
      return [...head.querySelectorAll('.head-actions .pill, .head-actions button.kebab')]
        .every((el) => !hits(el.getBoundingClientRect(), av));
    });
  };
  ok(await cornerClearsAvatar(320), 'channel: at 320pt the header corner clears the avatar');
  ok(await cornerClearsAvatar(375), 'channel: at 375pt the header corner clears the avatar');
  await page.setViewportSize({ width: 390, height: 844 });
  ok(await page.evaluate(() => {
    const head = document.querySelector('#view .profile-head');
    return ![...head.querySelectorAll('button')].some((b) => /Open in Telegram/i.test(b.textContent));
  }), 'channel: Open in Telegram is no longer a standalone header button');
  // the dots are drawn from tokens, not a glyph: three boxes in `faint`
  ok(await page.evaluate(() => {
    const dots = [...document.querySelectorAll('#view .head-actions button.kebab i')];
    if (dots.length !== 3) return false;
    const faint = getComputedStyle(document.documentElement).getPropertyValue('--faint').trim();
    const probe = document.createElement('span');
    probe.style.color = faint;
    document.body.append(probe);
    const want = getComputedStyle(probe).color;
    probe.remove();
    return dots.every((d) => getComputedStyle(d).backgroundColor === want) &&
      document.querySelector('#view .head-actions button.kebab').textContent === '';
  }), 'channel: the kebab is three faint token dots, no glyph');

  // the menu: a panel card at the card radius with the one card shadow
  await page.click('#view .head-actions button.kebab');
  await page.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
  ok(await page.evaluate(() => {
    const m = document.querySelector('.menu[role="menu"]');
    const rows = [...m.querySelectorAll('button.list-item')];
    const cs = getComputedStyle(m);
    const radius = getComputedStyle(document.documentElement).getPropertyValue('--radius').trim();
    return rows.map((r) => r.textContent).join('|') === 'Open in Telegram|Copy Link' &&
      cs.borderTopLeftRadius === radius &&
      cs.boxShadow !== 'none' &&
      rows.every((r) => r.getBoundingClientRect().height >= 40);
  }), 'channel: kebab opens the House Pour menu — Open in Telegram, Copy Link, 40pt rows');
  // the only thing that animates on appear is the fade, and it settles opaque
  await page.waitForFunction(() => {
    const m = document.querySelector('.menu[role="menu"]');
    const fading = m.closest('.menu-scrim') ?? m;
    return getComputedStyle(fading).opacity === '1';
  }, null, { timeout: 5000 });
  ok(true, 'channel: the menu fades in and settles opaque');
  await snap('channel-menu');

  // outside click dismisses
  await page.mouse.click(4, 4);
  await page.waitForFunction(() => !document.querySelector('.menu[role="menu"]'), null, { timeout: 5000 });
  ok(true, 'channel: outside click dismisses the menu');

  // Escape dismisses
  await page.click('#view .head-actions button.kebab');
  await page.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('.menu[role="menu"]'), null, { timeout: 5000 });
  ok(true, 'channel: Escape dismisses the menu');

  // §2.13 Copy Link — the tgsocial URL, not the t.me one, signed in as well
  await page.click('#view .head-actions button.kebab');
  await page.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
  await page.click('.menu[role="menu"] button.list-item:has-text("Copy Link")');
  await waitToast(/Link copied\./);
  ok((await page.evaluate(() => navigator.clipboard.readText())) === 'https://tgsocial.lucianlabs.ca/f/ana_notes', 'channel: Copy Link copies the tgsocial URL and toasts');

  await snap('channel');
  await page.click('#topbar-lead .btn');
  await waitText(/Ana Iliovic/);
  ok(true, 'back returns to the profile');

  // ── graph ────────────────────────────────────────────────────────────────
  await page.goto(`${base}/?mock=fresh#/graph`, { waitUntil: 'load' });
  await waitText(/YOUR NETWORK/, 15000);
  await page.waitForFunction(() => /\+1 · \d+/.test(document.getElementById('view').innerText) && !/Loading…/.test(document.getElementById('view').innerText), null, { timeout: 10000 });
  const gText = await text();
  ok(/DIRECT · 1/.test(gText), 'graph: DIRECT count');
  ok(/\+1 · 2/.test(gText) && /Followed by 1 of yours/.test(gText), 'graph: +1 ranked list (Bob, Carol; Dave unlisted, me excluded)');
  ok(await page.evaluate(() => document.querySelector('#view canvas.graph-canvas')?.width > 0), 'graph: canvas drawn');
  await snap('graph');
  // tap the first follow dot (ring 1, top) → profile
  await page.evaluate(() => {
    const c = document.querySelector('#view canvas.graph-canvas');
    const r = c.getBoundingClientRect();
    const base = Math.min(r.width, r.height);
    const x = r.left + r.width / 2;
    const y = r.top + r.height / 2 - base * 0.27;
    const opts = { bubbles: true, clientX: x, clientY: y, pointerId: 1, pointerType: 'mouse', isPrimary: true };
    c.dispatchEvent(new PointerEvent('pointerdown', opts));
    c.dispatchEvent(new PointerEvent('pointerup', opts));
  });
  await page.waitForFunction(() => location.hash === '#/node/tgs_ana', null, { timeout: 5000 });
  ok(true, 'graph: tapping a dot opens the profile');

  // ── you ──────────────────────────────────────────────────────────────────
  await page.goto(`${base}/?mock=fresh#/you`, { waitUntil: 'load' });
  await waitText(/YOUR FEEDS/, 15000);
  const youText = await text();
  ok(/@tgs_newbie/.test(youText) && /EDIT CARD/.test(youText) && /MANAGE/.test(youText), 'you: header + Edit Card + Manage');
  ok(/LISTED/.test(youText) && /ANNOUNCE IN DIRECTORY/.test(youText), 'you: listing row');
  ok(/tgsocial 1\.0\.0 \(1\) · TDLib mock-1\.8\.49 · node @tgs_newbie/.test(youText), 'you: footer version line');
  ok(await page.evaluate(() => document.querySelectorAll('#view .btn.primary').length === 1), 'you: exactly one primary button');
  await snap('you');
  await page.click('#view button.btn:has-text("Edit Card")');
  await page.waitForSelector('#modal .modal-card', { timeout: 5000 });
  await page.fill('#modal input[type="text"] >> nth=0', 'Newbie Lucian');
  await page.fill('#modal input[type="text"] >> nth=1', 'Fresh node.');
  await snap('you-edit');
  await page.click('#modal button.btn.primary');
  await waitToast(/Card updated\./);
  await page.waitForFunction(() => /Newbie Lucian/.test(document.getElementById('view').innerText), null, { timeout: 5000 });
  ok(true, 'you: Edit Card saves name + bio');
  ok(await page.evaluate(() => /Fresh node\./.test(window.__mock.fulls[2000].description)), 'you: description updated with bio');
  // listing toggle → unlisted disables announce
  await page.click('#view .listing-row .toggle');
  await page.waitForFunction(() => window.__tgsocial.repo.myCard.public === false, null, { timeout: 5000 });
  ok(await page.evaluate(() => [...document.querySelectorAll('#view button.btn')].find((b) => /Announce/i.test(b.textContent))?.disabled === true), 'you: Announce disabled when unlisted');
  await page.click('#view .listing-row .toggle');
  await page.waitForFunction(() => window.__tgsocial.repo.myCard.public === true, null, { timeout: 5000 });
  await page.click('#view button.btn.sm:has-text("Announce in Directory")');
  await waitToast(/Announced\./);
  ok(await page.evaluate(() => window.__mock.history[-1060][0].content.text.text === 'node: @tgs_newbie'), 'you: announce posts node line to the index group');

  // compose
  await page.click('#view button.btn.primary:has-text("Compose")');
  await page.waitForSelector('#modal textarea', { timeout: 5000 });
  ok(await page.evaluate(() => document.querySelectorAll('#modal .tabs button').length === 2), 'compose: feed picker tabs');
  await page.fill('#modal textarea', 'Hello from the web build.');
  await snap('compose');
  await page.click('#modal button.btn.primary:has-text("Post")');
  await waitToast(/Posted\./);
  ok(await page.evaluate(() => Object.values(window.__mock.history).some((h) => h[0]?.content?.text?.text === 'Hello from the web build.')), 'compose: message sent to the selected feed');

  // view as others
  await page.click('#view button.btn:has-text("View as others see it")');
  await waitText(/Newbie Lucian/);
  ok(!(await page.evaluate(() => !!document.querySelector('#view .profile-head .btn'))), 'own profile: no Follow button');

  // ── candidates are re-queried live (Setup card 2 / You → Manage) ─────────
  // a channel created in plain Telegram after Setup ran: no update is emitted,
  // so only a live re-query on opening Manage can surface it
  await page.evaluate(() => {
    const m = window.__mock;
    m.chats[-1080] = { '@type': 'chat', id: -1080, type: { '@type': 'chatTypeSupergroup', supergroup_id: 1080, is_channel: true }, title: 'Brand New', photo: null };
    m.supergroups[1080] = { '@type': 'supergroup', id: 1080, usernames: { editable_username: 'brand_new', active_usernames: ['brand_new'] }, status: { '@type': 'chatMemberStatusCreator' }, is_channel: true, member_count: 1 };
    m.fulls[1080] = { '@type': 'supergroupFullInfo', description: '' };
    m.history[-1080] = [];
  });
  await page.click('.tabs button:has-text("You")');
  await waitText(/YOUR FEEDS/);
  await page.click('#view button.btn.sm:has-text("Manage")');
  await waitText(/Pick the channels that post as you\./);
  await page.waitForFunction(() => /@brand_new/.test(document.getElementById('view').innerText), null, { timeout: 8000 });
  ok(true, 'manage: opening re-queries live — a channel made public after Setup appears');
  // a candidacy-changing TDLib update while the card is open triggers the same
  // re-query (debounced ~1 s): a channel made public appears with no user action
  await page.evaluate(() => {
    const m = window.__mock;
    m.supergroups[1004].usernames = { editable_username: 'notes_to_self', active_usernames: ['notes_to_self'] };
    m.client.emit({ '@type': 'updateSupergroup', supergroup: m.supergroups[1004] });
  });
  await page.waitForFunction(() => /@notes_to_self/.test(document.getElementById('view').innerText), null, { timeout: 8000 });
  ok(true, 'manage: updateSupergroup while open re-queries — channel made public appears live');

  // ── sign out ─────────────────────────────────────────────────────────────
  await page.goto(`${base}/?mock=fresh#/you`, { waitUntil: 'load' });
  await waitText(/SIGN OUT/, 15000);
  await page.click('#view button.btn.danger');
  await page.waitForSelector('#modal .modal-card', { timeout: 5000 });
  ok(/Sign out of tgsocial\?/.test(await page.evaluate(() => document.getElementById('modal').innerText)), 'sign out: confirm modal copy');
  await snap('signout');
  await page.click('#modal button.btn.danger');
  await page.waitForFunction(() => /Your Telegram, as a feed\./.test(document.getElementById('view').innerText) && Object.keys(localStorage).length === 0, null, { timeout: 15000 });
  ok(true, 'sign out: local state wiped, back at sign-in');

  // ── node scenario: existing node found, cold-start cache ─────────────────
  await page.goto(`${base}/?mock=node`, { waitUntil: 'load' });
  await waitText(/PHONE NUMBER/i, 15000);
  await page.fill('input[type="tel"]', '+16045550199');
  await page.click('button.btn.primary');
  await page.waitForSelector('input[inputmode="numeric"]', { timeout: 10000 });
  await page.fill('input[inputmode="numeric"]', '12345');
  await page.click('button.btn.primary');
  await page.waitForSelector('#view article.post', { timeout: 20000 });
  ok(await page.evaluate(() => window.__tgsocial.repo.myNode?.username === 'tgs_elijah'), 'node scenario: existing node found via getCreatedPublicChats');
  ok(await page.evaluate(() => window.__tgsocial.repo.cachedFeed().length > 0), 'node scenario: feed cache written');
  const posts2 = await page.locator('#view article.post').count();
  ok(posts2 >= 15, `feed: ${posts2} posts merged across 5 sources`);
  const order = await page.evaluate(() => window.__tgsocial.repo.cachedFeed().map((p) => p.date));
  ok(order.every((d, i) => i === 0 || order[i - 1] >= d), 'feed: strictly chronological (date desc)');
  const feedText = await text();
  ok(/Forwarded from Ana's notes/.test(feedText), 'feed: forwarded line resolves the origin chat title');
  // §2.3 attribution: the node the post reaches me through leads, the channel is the subheading
  ok(await page.evaluate(() => [...document.querySelectorAll('#view article.post')].some((a) => a.querySelector('.post-title')?.textContent === 'Elijah Lucian' && a.querySelector('.post-sub')?.textContent === 'WaveLoop devlog')), 'feed: my feed attributes to me with the channel subheading');
  ok(await page.evaluate(() => [...document.querySelectorAll('#view article.post')].some((a) => a.querySelector('.post-title')?.textContent === 'Ana Iliovic' && a.querySelector('.post-sub')?.textContent === "Ana's notes")), 'feed: followed node leads their feed\'s posts');
  // §2.3 the avatar is the SOURCE CHANNEL: a node is an aggregate, so the face
  // is the only thing telling two posts by the same person from different
  // feeds apart. Same name, different channel ⇒ different face.
  await page.waitForFunction(() => [...document.querySelectorAll('#view article.post .post-head .avatar')].every((a) => !!a.querySelector('img')), null, { timeout: 15000 });
  const mineByFeed = await page.evaluate(() => {
    const byFeed = {};
    for (const a of document.querySelectorAll('#view article.post')) {
      if (a.querySelector('.post-title')?.textContent !== 'Elijah Lucian') continue;
      const feed = a.querySelector('.post-sub')?.textContent ?? '';
      byFeed[feed] = a.querySelector('.post-head .avatar img')?.src ?? null;
    }
    return byFeed;
  });
  const feedFaces = Object.values(mineByFeed);
  ok(Object.keys(mineByFeed).length >= 2 && feedFaces.every(Boolean) && new Set(feedFaces).size === feedFaces.length,
    `feed: one person, ${Object.keys(mineByFeed).length} feeds, ${new Set(feedFaces).size} faces — the avatar is the source channel (${Object.keys(mineByFeed).join(', ')})`);
  ok(await page.evaluate(() => [...document.querySelectorAll('#view article.post .post-time')].every((t) => /^(now|\d+(m|h|d|w|mo|y) ago)$/.test(t.textContent))), 'feed: relative time, largest unit only');
  ok(/❤ 14/.test(feedText) && /\d+ comments/.test(feedText), 'feed: footer counts — reactions · comments');
  ok(!/views/.test(feedText), 'feed: no views on the card face');
  ok(await page.evaluate(() => [...document.querySelectorAll('#view article.post')].every((a) => !/Open in Telegram/i.test(a.innerText))), 'feed: no Open in Telegram on the card face');
  ok(await page.evaluate(() => [...document.querySelectorAll('#view article.post .post-foot .btn')].every((b) => /Comment/i.test(b.textContent))), 'feed: footer keeps only the Comment ghost');

  // §2.3 Share: no navigator.share in this Chromium → copy the link + toast
  await page.evaluate(() => Object.defineProperty(navigator, 'share', { value: undefined, configurable: true }));
  await page.locator('#view article.post >> nth=0').locator('button:has-text("Share")').click();
  await waitToast(/^Link copied\.$/);
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  ok(/^https:\/\/t\.me\/waveloop_devlog\/\d+$/.test(copied), `share: post link copied (${copied})`);

  // §2.3 long-press (500 ms hold on the text, clear of buttons/media) → post
  // sheet. The hold jitters a few px mid-press: real fingers micro-move and
  // WebKit dispatches pointermove for sub-slop touch movement, so the gesture
  // must tolerate movement inside the slop radius rather than cancelling on
  // the first pointermove.
  {
    const body = page.locator('#view article.post .post-body').first();
    const bb = await body.boundingBox();
    const x = bb.x + 8; const y = bb.y + 8;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.waitForTimeout(150);
    await page.mouse.move(x + 3, y + 2);
    await page.waitForTimeout(150);
    await page.mouse.move(x - 2, y + 4);
    await page.waitForTimeout(400);
    await page.mouse.up();
  }
  await page.waitForSelector('#modal .modal-card', { timeout: 5000 });
  const sheetText2 = await page.evaluate(() => document.getElementById('modal').innerText);
  ok(/POST/.test(sheetText2) && /Posted\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(sheetText2), 'post sheet: POST mark + exact Posted row');
  ok(/Views\s+[\d.]+[kmb]?/.test(sheetText2), 'post sheet: Views row moved off the footer');
  ok(/Feed\s+.+ · @[a-z_]+/.test(sheetText2), 'post sheet: Feed row title · @username');
  ok(/Open in Telegram/i.test(sheetText2), 'post sheet: Open in Telegram lives here now');
  await snap('post-sheet');
  await page.click('#modal button.btn.ghost:has-text("Close")');
  await page.waitForFunction(() => !document.querySelector('#modal .modal-card'), null, { timeout: 5000 });
  ok(await page.evaluate(() => !location.hash.startsWith('#/thread')), 'post sheet: long-press did not open the thread');
  ok(await page.evaluate(() => !!document.querySelector('#view .post-body b') && !!document.querySelector('#view .post-body code') && !!document.querySelector('#view .post-body a')), 'feed: entities rendered as b/code/a');
  await page.waitForFunction(() => [...document.querySelectorAll('#view .post-media img')].some((i) => i.src.startsWith('blob:')), null, { timeout: 10000 });
  ok(true, 'feed: media loaded via readFile blob');
  ok(/release-notes-\d+\.pdf/.test(feedText), 'feed: document file name');
  ok(/Bench loop/.test(feedText) && /3:32/.test(feedText), 'feed: audio title + duration');
  ok(await page.evaluate(() => !!document.querySelector('#view .player .player-btn')), 'feed: audio renders as a House Pour player row');
  ok(await page.evaluate(() => !!document.querySelector('#view .waveform i')), 'feed: voice waveform bars');
  ok(/Poll · 3 options/.test(feedText), 'feed: poll summary');
  ok(/Lucian Labs/.test(feedText), 'feed: link preview row');
  ok(await page.evaluate(() => [...document.querySelectorAll('#view article.post')].every((a) => !/Pinned a message/.test(a.textContent))), 'feed: service messages skipped');
  await snap('feed');

  // ── §2.11 media: viewer, album swipe, now-playing dock ───────────────────
  // scroll until the animation post enters the visibility observer's range
  const gifMounted = () => page.evaluate(() => [...document.querySelectorAll('#view video')].some((v) => v.loop && v.muted));
  for (let i = 0; i < 15 && !(await gifMounted()); i += 1) {
    await page.evaluate(() => window.scrollBy(0, window.innerHeight));
    await page.waitForTimeout(300);
  }
  ok(await gifMounted(), 'feed: GIF autoplays muted and looped');
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.locator('#view .player .player-btn').first().click();
  await page.waitForSelector('#dock .now-playing', { timeout: 8000 });
  ok(true, 'audio: now-playing row docks above the tab bar');

  // ── bottom inset while the now-playing dock is live (PRODUCT §1) ─────────
  await page.click('.tabs button:has-text("You")');
  await waitText(/YOUR FEEDS/);
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
  await page.waitForTimeout(250);
  const inset = await page.evaluate(() => {
    const dock = document.getElementById('dock');
    const last = document.getElementById('view').lastElementChild;
    return {
      np: !!dock.querySelector('.now-playing'),
      extra: document.getElementById('app').style.getPropertyValue('--dock-extra'),
      lastBottom: last.getBoundingClientRect().bottom,
      dockTop: dock.getBoundingClientRect().top,
    };
  });
  ok(inset.np && inset.extra !== '' && inset.lastBottom <= inset.dockTop + 0.5,
    `you: last element clears the now-playing dock (bottom ${Math.round(inset.lastBottom)} <= dock top ${Math.round(inset.dockTop)}, --dock-extra ${inset.extra})`);
  // tab bar hidden (Setup via Manage) but audio still playing: the dock stays
  // for the now-playing row and the inset stays with it
  await page.click('#view button.btn.sm:has-text("Manage")');
  await waitText(/Pick the channels that post as you\./);
  const managed = await page.evaluate(() => ({
    dockHidden: document.getElementById('dock').hidden,
    tabsHidden: document.querySelector('#dock .tabs').hidden,
    np: !!document.querySelector('#dock .now-playing'),
    extra: document.getElementById('app').style.getPropertyValue('--dock-extra'),
  }));
  ok(!managed.dockHidden && managed.tabsHidden && managed.np && managed.extra !== '', 'manage: tab bar hidden, now-playing dock stays, inset kept');
  // playback ends: the row unmounts, the extra inset goes away, the dock
  // hides with the tab bar
  await page.evaluate(() => {
    const el = window.__tgsocial.currentAudio();
    Object.defineProperty(el, 'ended', { value: true, configurable: true });
    el.dispatchEvent(new Event('ended'));
  });
  await page.waitForFunction(() => !document.querySelector('#dock .now-playing'), null, { timeout: 5000 });
  ok(await page.evaluate(() => document.getElementById('app').style.getPropertyValue('--dock-extra') === '' && document.getElementById('dock').hidden),
    'audio end: --dock-extra removed and dock hidden with the tab bar');
  await page.click('#topbar-lead .btn');
  await waitText(/YOUR FEEDS/);
  await page.click('.tabs button:has-text("Feed")');
  await page.waitForSelector('#view .post-media[role="button"]', { timeout: 15000 });

  await page.locator('#view .post-media[role="button"]').first().click();
  await page.waitForSelector('#viewer-root .viewer', { timeout: 8000 });
  ok(await page.evaluate(() => document.body.hasAttribute('data-viewer') && getComputedStyle(document.getElementById('dock')).display === 'none' && getComputedStyle(document.getElementById('head')).display === 'none'), 'viewer: hides the topbar and the tab bar');
  ok(await page.evaluate(() => document.querySelector('.viewer-counter')?.textContent === '1 / 2'), 'viewer: album counter 1 / 2');
  await page.keyboard.press('ArrowRight');
  await page.waitForFunction(() => document.querySelector('.viewer-counter')?.textContent === '2 / 2', null, { timeout: 5000 });
  ok(true, 'viewer: arrow key swipes to the next album item');
  await snap('viewer');
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('#viewer-root .viewer'), null, { timeout: 5000 });
  ok(await page.evaluate(() => !document.body.hasAttribute('data-viewer')), 'viewer: Escape dismisses and restores the chrome');

  // ── §2.12 comments and threads ───────────────────────────────────────────
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForFunction(() => /2 comments/.test(document.querySelector('#view article.post')?.innerText ?? ''), null, { timeout: 15000 });
  ok(true, 'feed: comment count from my network on the newest post');
  await page.locator('#view article.post').first().locator('.post-comments-count').click();
  await page.waitForFunction(() => location.hash.startsWith('#/thread/waveloop_devlog/'), null, { timeout: 8000 });
  await waitText(/COMMENTS · 2/);
  const threadText = await text();
  ok(/Nice one\. The bass is huge\./.test(threadText), 'thread: comment from Ana');
  ok(/1 reply/.test(threadText) && /Agreed\./.test(threadText), 'thread: reply chain via re: link');
  ok(await page.evaluate(() => !!document.querySelector('#view .comment-children .comment')), 'thread: replies indent one level');
  ok(await page.evaluate(() => !document.getElementById('dock').hidden), 'thread: floating tab bar stays on pushed screens');
  await snap('thread');
  await page.click('#view button.btn.primary:has-text("Comment")');
  await page.waitForSelector('#modal .modal-card', { timeout: 5000 });
  ok(/YOUR COMMENTS CHANNEL/.test(await page.evaluate(() => document.getElementById('modal').innerText)), 'composer: first run shows the channel card');
  ok(await page.evaluate(() => document.querySelector('#modal input').value === 'tgs_elijah_r'), 'composer: prefilled <node>_r');
  await page.waitForFunction(() => /AVAILABLE/i.test(document.getElementById('modal').innerText), null, { timeout: 8000 });
  await snap('comments-channel');
  await page.click('#modal button.btn.primary:has-text("Make Channel")');
  await page.waitForSelector('#modal textarea', { timeout: 10000 });
  ok(/re: WaveLoop devlog/.test(await page.evaluate(() => document.getElementById('modal').innerText)), 'composer: quote line of the target');
  await page.fill('#modal textarea', 'From the web thread.');
  await snap('composer');
  await page.click('#modal button.btn.primary:has-text("Post")');
  await page.waitForFunction(() => /From the web thread\./.test(document.getElementById('view').innerText) && !/Posting…/.test(document.getElementById('view').innerText), null, { timeout: 10000 });
  await waitText(/COMMENTS · 3/);
  ok(true, 'composer: optimistic comment settles in the thread');
  ok(await page.evaluate(() => /^replies: @tgs_elijah_r$/m.test(window.__mock.pinned[window.__tgsocial.repo.myNode.chatId].content.text.text)), 'composer: replies: added to the card');
  ok(await page.evaluate(() => {
    const sg = Object.values(window.__mock.supergroups).find((s) => s.usernames?.editable_username === 'tgs_elijah_r');
    const chat = Object.values(window.__mock.chats).find((c) => c.type.supergroup_id === sg?.id);
    return chat && /^re: https:\/\/t\.me\/waveloop_devlog\/\d+\nFrom the web thread\.$/.test(window.__mock.history[chat.id]?.[0]?.content?.text?.text ?? '');
  }), 'composer: comment lands in my channel with the re: pointer');
  await page.locator('#view .comment', { hasText: 'From the web thread.' }).first().locator('button:has-text("Delete")').click();
  await page.waitForSelector('#modal .modal-card', { timeout: 5000 });
  ok(/Delete this comment\?/.test(await page.evaluate(() => document.getElementById('modal').innerText)), 'delete: confirm copy');
  await page.click('#modal button.btn.danger');
  await waitText(/COMMENTS · 2/);
  ok(true, 'delete: my comment removed from my channel');
  await page.click('#topbar-lead .btn');
  await page.waitForFunction(() => location.hash === '#/feed' || location.hash === '', null, { timeout: 8000 });
  await page.waitForSelector('#view article.post', { timeout: 15000 });
  const beforeMore = await page.locator('#view article.post').count();
  for (let i = 0; i < 10 && (await page.locator('#view article.post').count()) <= beforeMore; i += 1) {
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await page.waitForTimeout(400);
  }
  ok((await page.locator('#view article.post').count()) > beforeMore, 'feed: load more on scroll');
  for (let i = 0; i < 10 && !/That's everything\./.test(await text()); i += 1) {
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await page.waitForTimeout(500);
  }
  ok(/That's everything\./.test(await text()), "feed: That's everything. at the end");
  const total = await page.locator('#view article.post').count();
  ok(total >= 40, `feed: ${total} posts after exhausting sources`);
  const linkOk = await page.evaluate(() => window.__tgsocial.repo.cachedFeed()[0].link);
  ok(/^https:\/\/t\.me\/[a-z_]+\/\d+$/.test(linkOk), `feed: deep link ${linkOk}`);

  // ── media memory: the object-URL registry is bounded (js/blobcache.js) ────
  // Every picture the feed paints used to mint a blob: URL that was never
  // revoked and lived in an unbounded Map. It is now an LRU bounded by bytes
  // first and entries second. The real budget is tens of MB and the mock's
  // pictures are a few hundred bytes each, so the bounds are shrunk here to
  // something this feed can actually overflow — the mechanism is the same one
  // that runs on a phone.
  const mediaDefaults = await page.evaluate(() => window.__tgsocial.media.stats());
  ok(mediaDefaults.maxBytes >= 12 * 1024 * 1024 && mediaDefaults.maxBytes <= 48 * 1024 * 1024,
    `media: derived budget ${Math.round(mediaDefaults.maxBytes / 1048576)} MB, in the tens of MB`);
  // the downsampling decode path, on a real photo rather than the mock's SVGs:
  // a 2000 px JPEG must come back at the width the card paints, and smaller
  const decoded = await page.evaluate(async () => {
    const { downscale, cardWidthPx } = await import('/js/decode.js');
    const c = document.createElement('canvas');
    c.width = 2000;
    c.height = 1500;
    const ctx = c.getContext('2d');
    const grad = ctx.createLinearGradient(0, 0, 2000, 1500);
    grad.addColorStop(0, '#8a6a2f');
    grad.addColorStop(1, '#101014');
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, 2000, 1500);
    const big = await new Promise((r) => c.toBlob(r, 'image/jpeg', 0.92));
    const target = cardWidthPx(window);
    const out = await downscale(big, target);
    return { target, srcBytes: big.size, outBytes: out.blob.size, w: out.width, h: out.height, downsampled: out.downsampled };
  });
  ok(decoded.downsampled && decoded.w === decoded.target && decoded.h === Math.round((1500 * decoded.target) / 2000),
    `media: a 2000 px photo decodes to ${decoded.w}×${decoded.h}, the size the card paints`);
  ok(decoded.outBytes < decoded.srcBytes,
    `media: the cached rendition is smaller than the original (${decoded.outBytes} B vs ${decoded.srcBytes} B)`);

  // the transient cost of decoding is bounded too: the visibility observer arms
  // every card within ~3 screens at once, and each decode holds a surface the
  // byte budget cannot see (nothing is charged until the decode has finished)
  const decodeCap = await page.evaluate(async () => {
    const { downscale, decodeLoad } = await import('/js/decode.js');
    const c = document.createElement('canvas');
    c.width = 1400;
    c.height = 1050;
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#8a6a2f';
    ctx.fillRect(0, 0, 1400, 1050);
    const big = await new Promise((r) => c.toBlob(r, 'image/jpeg', 0.9));
    let peak = 0;
    let sampling = true;
    const sample = () => {
      peak = Math.max(peak, decodeLoad().running);
      if (sampling) requestAnimationFrame(sample);
    };
    sample();
    const outs = await Promise.all(Array.from({ length: 8 }, () => downscale(big, 320)));
    sampling = false;
    const after = decodeLoad();
    // the slot has to come back, or the next photo the feed wants waits forever
    const oneMore = await downscale(big, 320);
    return { peak, max: after.max, running: after.running, waiting: after.waiting, done: outs.every((o) => o.width === 320), oneMore: oneMore.width === 320 };
  });
  ok(decodeCap.peak <= decodeCap.max,
    `media: eight decodes at once never exceed ${decodeCap.max} in flight (peak ${decodeCap.peak})`);
  ok(decodeCap.running === 0 && decodeCap.waiting === 0 && decodeCap.done && decodeCap.oneMore,
    'media: every decode slot is handed back, and the queue drains');

  await page.evaluate(() => window.__tgsocial.media.configure({ maxBytes: 1200, maxEntries: 6 }));
  const walkFeed = async (passes) => {
    for (let i = 0; i < passes; i += 1) {
      await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
      await page.waitForTimeout(220);
      await page.evaluate(() => window.scrollTo(0, 0));
      await page.waitForTimeout(220);
    }
    return page.evaluate(() => window.__tgsocial.media.stats());
  };
  const oneWalk = await walkFeed(2);
  const twoWalks = await walkFeed(3);
  ok(twoWalks.entries <= 6 && twoWalks.bytes <= 1200,
    `media: scrolling a long feed stays inside the bound (${twoWalks.entries} files, ${twoWalks.bytes} B of 1200)`);
  ok(twoWalks.entries <= 6 && twoWalks.entries <= oneWalk.entries + 0,
    `media: the registry does not grow with the number of scrolls (${oneWalk.entries} → ${twoWalks.entries})`);
  ok(oneWalk.revoked > 0 && twoWalks.revoked >= oneWalk.revoked,
    `media: eviction revokes what it drops (${twoWalks.revoked} revoked)`);
  await page.evaluate((d) => window.__tgsocial.media.configure({ maxBytes: d.maxBytes, maxEntries: d.maxEntries }), mediaDefaults);

  // a revoked URL is never handed out again, and the picture comes back
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForSelector('#view .post-media img[src^="blob:"]', { timeout: 10000 });
  const before = await page.evaluate(() => document.querySelector('#view .post-media img[src^="blob:"]').src);
  await page.evaluate(() => window.__tgsocial.media.flush('test'));
  ok(await page.evaluate((u) => window.__tgsocial.media.wasRevoked(u), before), 'media: a flush revokes the URLs it was holding');
  await page.waitForFunction((u) => {
    const img = document.querySelector('#view .post-media img[src^="blob:"]');
    return !!img && img.src !== u;
  }, before, { timeout: 10000 });
  const repainted = await page.evaluate((u) => {
    const img = document.querySelector('#view .post-media img[src^="blob:"]');
    return { src: img.src, reused: window.__tgsocial.media.wasRevoked(img.src), painted: img.complete && img.naturalWidth > 0, same: img.src === u };
  }, before);
  ok(!repainted.same && !repainted.reused, 'media: the repaint uses a fresh URL, never a revoked one');
  ok(repainted.painted, 'media: the feed repaints after a memory-pressure flush instead of showing blanks');

  // the in-memory feed window and the persisted cache are both capped, and the
  // cards on screen still match the posts held in memory one for one
  const windowState = await page.evaluate(() => ({
    cards: document.querySelectorAll('#view article.post').length,
    posts: window.__tgsocial.app.feedStats.posts,
    cached: window.__tgsocial.repo.cachedFeed().length,
  }));
  ok(windowState.cards === windowState.posts && windowState.posts <= 240 && windowState.cached <= 40,
    `feed: window capped (${windowState.posts} posts, ${windowState.cards} cards, ${windowState.cached} cached)`);

  // ── the window trims, and loading more still works after it has ──────────
  // The shipped window is 240 posts — more scrollback than this mock has — so
  // it is lowered here to exercise the trim itself: the head comes off, the
  // cards go with the models, and the pages keep coming.
  const newest = await page.evaluate(() => window.__tgsocial.repo.cachedFeed()[0].key);
  await page.evaluate(() => {
    window.__tgsocial.app.feedWindow = 12;
  });
  await page.click('.tabs button:has-text("Explore")');
  await waitText(/NEARBY/);
  await page.click('.tabs button:has-text("Feed")');
  await page.waitForSelector('#view article.post', { timeout: 15000 });
  for (let i = 0; i < 14 && !/That's everything\./.test(await text()); i += 1) {
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await page.waitForTimeout(400);
  }
  const trimmed = await page.evaluate(() => {
    const cards = [...document.querySelectorAll('#view article.post')];
    const times = cards.map((c) => c.querySelector('.post-time')?.textContent ?? '');
    return {
      cards: cards.length,
      posts: window.__tgsocial.app.feedStats.posts,
      end: /That's everything\./.test(document.getElementById('view').innerText),
      cachedFirst: window.__tgsocial.repo.cachedFeed()[0]?.key,
      cached: window.__tgsocial.repo.cachedFeed().length,
      times,
    };
  });
  const trimmedCards = trimmed.cards;
  ok(trimmed.cards <= 12 && trimmed.posts <= 12 && trimmed.cards === trimmed.posts,
    `feed: the window holds at 12 while scrolling (${trimmed.posts} posts, ${trimmed.cards} cards)`);
  ok(trimmed.end, 'feed: pagination still reaches the end after the window has trimmed');
  // the audio dock's row registry is pruned by the same trim. It used to be
  // swept only while something was playing, so a scroll through a feed of voice
  // notes retained one detached card — and every picture in it — per audio post.
  const audioRows = await page.evaluate(() => window.__tgsocial.audioRows());
  ok(audioRows.rows === audioRows.connected && audioRows.rows <= trimmedCards,
    `media: the audio row registry holds only rows still on screen (${audioRows.rows} tracked, ${audioRows.connected} connected)`);
  ok(trimmed.cachedFirst === newest && trimmed.cached <= 40,
    'feed: the cold-start cache still holds the newest post the trim dropped');
  ok(await page.evaluate(() => window.__tgsocial.repo.cachedFeed().every((p, i, a) => i === 0 || a[i - 1].date >= p.date)),
    'feed: still newest-first after trimming');
  // a live post arriving at a full window trims the far end, not itself
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.evaluate(() => {
    const msg = {
      '@type': 'message',
      id: 901 << 20,
      chat_id: -1002,
      date: Math.floor(Date.now() / 1000) + 9,
      content: { '@type': 'messageText', text: { '@type': 'formattedText', text: 'Live insert into a full window.', entities: [] } },
      interaction_info: null,
      forward_info: null,
    };
    window.__mock.history[-1002].unshift(msg);
    window.__mock.client.emit({ '@type': 'updateNewMessage', message: msg });
  });
  await page.waitForFunction(() => /Live insert into a full window\./.test(document.querySelector('#view article.post')?.innerText ?? ''), null, { timeout: 8000 });
  ok(await page.evaluate(() => document.querySelectorAll('#view article.post').length <= 12),
    'feed: a live insert at a full window keeps the window bounded and keeps itself');
  await page.evaluate(() => {
    window.__tgsocial.app.feedWindow = null;
  });
  await page.goto(`${base}/?mock=node&mockslow=1`, { waitUntil: 'load' });
  await page.waitForFunction(() => document.querySelectorAll('#view article.post').length > 0 && document.getElementById('status').textContent === 'Syncing', null, { timeout: 3000 });
  ok(true, 'cold start paints cached feed (pill Syncing) before TDLib is ready');
  await page.waitForFunction(() => document.getElementById('status').textContent === 'Synced', null, { timeout: 15000 });
  await page.waitForSelector('#view article.post', { timeout: 15000 });
  await page.waitForFunction(() => window.__tgsocial.td.isReady, null, { timeout: 15000 });

  // ── §2.10 status sheet ───────────────────────────────────────────────────
  await page.waitForFunction(() => !!window.__tgsocial.app.feedStats, null, { timeout: 15000 });
  await page.click('#status');
  await page.waitForSelector('#modal .status-sheet', { timeout: 5000 });
  await page.waitForFunction(() => /Signed in · \+1 604 ••• 0199/.test(document.getElementById('modal').innerText), null, { timeout: 8000 });
  ok(true, 'status sheet: masked phone');
  const sheet = await page.evaluate(() => document.getElementById('modal').innerText);
  ok(/Connection\s+Connected/.test(sheet), 'status sheet: Connection mirrors updateConnectionState');
  ok(/@tgs_elijah · card /.test(sheet), 'status sheet: node row with card age');
  ok(/\d+ sources · \d+ posts · refreshed \d\d:\d\d/.test(sheet), 'status sheet: feed stats row');
  ok(/Pending/.test(sheet) && /TDLib\s+mock-1\.8\.49/.test(sheet), 'status sheet: Pending + TDLib rows');
  ok(/Last error/.test(sheet), 'status sheet: Last error row');
  await snap('status-sheet');
  await page.click('#modal .status-sheet button.btn.accent');
  await page.waitForFunction(() => /Nothing|…/.test(document.querySelector('#modal .status-sheet')?.innerText ?? ''), null, { timeout: 8000 });
  await page.click('#modal .status-sheet button.btn.ghost');
  await page.waitForFunction(() => !document.querySelector('#modal .modal-card'), null, { timeout: 5000 });
  ok(true, 'status sheet: Refresh Now runs and Close dismisses');
  // the pill settles back to Synced — the registry cannot wedge it (PRODUCT §2.10)
  await page.waitForFunction(() => document.getElementById('status').textContent === 'Synced', null, { timeout: 15000 });
  ok(true, 'status pill: returns to Synced after Refresh Now');

  // ── live insert: a new post lands on top (PRODUCT §2.3) ──────────────────
  await page.evaluate(() => {
    const msg = {
      '@type': 'message',
      id: 900 << 20,
      chat_id: -1002,
      date: Math.floor(Date.now() / 1000) + 5,
      content: { '@type': 'messageText', text: { '@type': 'formattedText', text: 'Live insert lands on top.', entities: [] } },
      interaction_info: null,
      forward_info: null,
    };
    window.__mock.history[-1002].unshift(msg);
    window.__mock.client.emit({ '@type': 'updateNewMessage', message: msg });
  });
  await page.waitForFunction(() => /Live insert lands on top\./.test(document.querySelector('#view article.post')?.innerText ?? ''), null, { timeout: 8000 });
  ok(true, 'feed: live post inserts at the top, newest first');

  await page.click('.tabs button:has-text("Explore")');
  await page.waitForFunction(() => /Followed by 2 of yours/.test(document.getElementById('view').innerText), null, { timeout: 10000 });
  ok(true, 'explore: Nearby ranks Carol (followed by 2 of yours)');
  await snap('explore-node');
  await page.click('.tabs button:has-text("Graph")');
  await page.waitForFunction(() => /\+1 · \d+/.test(document.getElementById('view').innerText) && !/Loading…/.test(document.getElementById('view').innerText), null, { timeout: 10000 });
  await snap('graph-node');
  await page.click('.tabs button:has-text("You")');
  await waitText(/YOUR FEEDS/);
  await snap('you-node');
  // offline pill
  await ctx.setOffline(true);
  await page.waitForFunction(() => document.getElementById('status').textContent === 'Offline', null, { timeout: 5000 });
  ok(true, 'status pill: Offline when the network drops');
  await page.click('.tabs button:has-text("Explore")');
  await page.waitForSelector('#view .node-row .btn', { timeout: 10000 });
  await page.click('#view .node-row .btn >> nth=0');
  await waitToast(/^You're offline\.$/);
  ok(true, "offline write toasts You're offline.");
  await ctx.setOffline(false);
  await page.waitForFunction(() => document.getElementById('status').textContent === 'Synced', null, { timeout: 5000 });

  // ── §2.3 stale cache guard ───────────────────────────────────────────────
  // an old build's cache (pre-versioning: a raw array, oldest-first) must be
  // discarded on boot — never painted
  await page.evaluate(() => {
    const posts = window.__tgsocial.repo.cachedFeed();
    const oldestFirst = [...posts].sort((a, b) => a.date - b.date || a.id - b.id).map((p) => ({ ...p, text: `Stale cache ${p.key}` }));
    localStorage.setItem('tgs.feed', JSON.stringify(oldestFirst));
  });
  await page.goto(`${base}/?mock=node&mockslow=1`, { waitUntil: 'load' });
  await page.waitForFunction(() => !!window.__tgsocial?.repo, null, { timeout: 10000 });
  const stale = await page.evaluate(() => ({
    cached: window.__tgsocial.repo.cachedFeed().length,
    painted: [...document.querySelectorAll('#view article.post')].filter((a) => /Stale cache /.test(a.innerText)).length,
  }));
  ok(stale.cached === 0 && stale.painted === 0, 'stale cache: old-schema feed discarded on boot, never painted');
  await page.waitForFunction(() => window.__tgsocial.td.isReady && window.__tgsocial.repo.cachedFeed().length > 0, null, { timeout: 20000 });
  // a current-schema payload persisted oldest-first (defensive case) is
  // re-sorted newest-first on load and painted that way on cold start
  await page.evaluate(() => {
    const raw = JSON.parse(localStorage.getItem('tgs.feed'));
    raw.data.sort((a, b) => a.date - b.date || a.id - b.id);
    localStorage.setItem('tgs.feed', JSON.stringify(raw));
  });
  await page.goto(`${base}/?mock=node&mockslow=1`, { waitUntil: 'load' });
  await page.waitForFunction(() => document.querySelectorAll('#view article.post').length > 0 && document.getElementById('status').textContent === 'Syncing', null, { timeout: 3000 });
  const resort = await page.evaluate(() => {
    const dates = window.__tgsocial.repo.cachedFeed().map((p) => p.date);
    return {
      sorted: dates.every((d, i) => i === 0 || dates[i - 1] >= d),
      n: dates.length,
      painted: document.querySelectorAll('#view article.post').length,
    };
  });
  ok(resort.sorted && resort.n > 1 && resort.painted > 0, `stale cache: ${resort.n} cached posts re-sorted newest-first on cold start`);
  await page.waitForFunction(() => document.getElementById('status').textContent === 'Synced', null, { timeout: 20000 });

  // ── §2.13 /u/<name> signed in ────────────────────────────────────────────
  // The same resolution PUBLIC §4 does, with TDLib instead of the preview:
  // @waveloop_devlog is a feed whose description backlinks @tgs_elijah, so
  // /u/ lands on that person's node profile; a node resolves directly.
  await page.goto(`${base}/u/waveloop_devlog?mock=node`, { waitUntil: 'load' });
  await page.waitForFunction(() => location.hash === '#/node/tgs_elijah', null, { timeout: 25000 });
  ok(/Elijah Lucian/.test(await text()), 'signed in: /u/<feed> follows the backlink to the person’s node profile');
  await page.goto(`${base}/u/tgs_ana?mock=node`, { waitUntil: 'load' });
  await page.waitForFunction(() => location.hash === '#/node/tgs_ana', null, { timeout: 25000 });
  ok(/Ana Iliovic/.test(await text()), 'signed in: /u/<node> opens that node directly');
  ok(await page.evaluate(() => !window.__tgsocial.app.publicMode && !document.querySelector('#dock .nag')),
    'signed in: a public URL is never the public page on a browser that has signed in');

  // ── §2.13 public pages ───────────────────────────────────────────────────
  // A visitor with no session reads the page itself — no sign-in wall, no
  // TDLib. The posts come from Telegram's own preview (PUBLIC.md) through the
  // `/tg/s/` proxy, which this test serves from web/test/fixtures/ (real
  // fetched pages: tastycrow, tgs_dankcoin, telegram) so a Telegram markup
  // change fails here instead of on the page.
  {
    const pubCtx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, permissions: ['clipboard-read', 'clipboard-write'] });
    await pubCtx.route('**/vendor/tdweb/tdweb.js', (route) => route.fulfill({ status: 200, contentType: 'application/javascript', body: mock }));
    // the fixtures carry real CDN URLs; this test is offline, so the pictures
    // they point at are answered locally rather than left to fail
    await pubCtx.route(/telesco\.pe|telegram-cdn\.org/, (route) => route.fulfill({ status: 200, contentType: 'image/png', body: PIXEL }));
    // the destination a hostile document row would aim at, answered locally so
    // the assertion below is offline and deterministic
    await pubCtx.route(/evil\.example/, (route) => route.fulfill({ status: 200, contentType: 'text/plain', body: 'ATTACKER PAGE' }));
    const pub = await pubCtx.newPage();
    pub.on('console', (m) => {
      if (m.type() === 'error') errors.push(`public: ${m.text()}`);
    });
    pub.on('pageerror', (e) => errors.push(`public pageerror: ${e.message}`));
    const pubText = () => pub.evaluate(() => document.getElementById('view').innerText);

    // ── the parser, against the fixtures (PUBLIC §3) ───────────────────────
    await pub.goto(`${base}/f/tastycrow`, { waitUntil: 'load' });
    await pub.waitForSelector('#view article.post', { timeout: 20000 });
    const parsed = await pub.evaluate(async () => {
      const { parsePreview } = await import('/js/public/preview.js');
      const get = async (name) => parsePreview(await (await fetch(`/tg/s/${name}`)).text(), name);
      const crow = await get('tastycrow');
      const dank = await get('tgs_dankcoin');
      const tg = await get('telegram');
      const blank = await get('tgs_blank');
      const xss = await get('tgs_xss');
      const kinds = (r) => [...new Set(r.posts.flatMap((p) => p.album.map((i) => i.kind)))];
      const post = (r, id) => r.posts.find((p) => p.id === id) ?? null;
      return {
        crow: {
          n: crow.posts.length,
          ids: crow.posts.map((p) => p.id),
          title: crow.channel.title,
          username: crow.channel.username,
          backlink: crow.channel.verifiedFor,
          nextBefore: crow.nextBefore,
          unavailable: crow.unavailable,
          three: post(crow, 3),
          videoItem: post(crow, 6)?.album[0] ?? null,
          videoText: post(crow, 6)?.text ?? null,
          kinds: kinds(crow),
          gif: post(crow, 3)?.album[0] ?? null,
          photo: post(crow, 4)?.album[0] ?? null,
          summary: post(crow, 5)?.album[0] ?? null,
          // §2.3: the source channel's photo travels with every post it parses
          face: crow.channel.photo?.url ?? null,
          postFace: crow.posts[0]?.avatar?.url ?? null,
        },
        dank: {
          n: dank.posts.length,
          card: dank.card,
          isCard: dank.posts[0]?.isCard ?? null,
          title: dank.channel.title,
          // no photo of its own: t.me answers with a GENERATED letter avatar,
          // which is not a photo (§2.3)
          face: dank.channel.photo,
          postFace: dank.posts[0]?.avatar ?? null,
        },
        tg: {
          n: tg.posts.length,
          nextBefore: tg.nextBefore,
          username: tg.channel.username,
          kinds: kinds(tg),
          maxViews: Math.max(...tg.posts.map((p) => p.views)),
          previews: tg.posts.filter((p) => p.preview).map((p) => p.preview.url),
          newestFirst: tg.posts.every((p, i) => i === 0 || tg.posts[i - 1].date >= p.date),
        },
        blank: { n: blank.posts.length, unavailable: blank.unavailable },
        // a document row is the one media kind whose action hands the reader a
        // URL to GO TO, so its host decides whether the row can honestly exist
        docHosts: (() => {
          const page = (href) => `<html><body><main class="tgme_main"><div class="tgme_container">`
            + `<section class="tgme_channel_history"><div class="tgme_widget_message" data-post="probe/1">`
            + `<div class="tgme_widget_message_bubble">`
            + `<a class="tgme_widget_message_document_wrap" href="${href}">`
            + `<div class="tgme_widget_message_document_title">invoice.pdf</div>`
            + `<div class="tgme_widget_message_document_extra">1.2 MB</div></a>`
            + `<div class="tgme_widget_message_footer"><div class="tgme_widget_message_info">`
            + `<span class="tgme_widget_message_views">1</span><span class="tgme_widget_message_meta">`
            + `<a class="tgme_widget_message_date" href="https://t.me/probe/1">`
            + `<time datetime="2026-08-20T10:00:00+00:00">10:00</time></a></span>`
            + `</div></div></div></div></section></div></main></body></html>`;
          const item = (href) => parsePreview(page(href), 'probe').posts[0]?.album[0] ?? null;
          return {
            hostile: item('https://evil.example/pwn.exe'),
            tme: item('https://t.me/probe/1'),
            cdn: item('https://cdn4.telesco.pe/file/invoice.pdf'),
          };
        })(),
        // Telegram serves a channel with no photo a GENERATED letter avatar —
        // a data:image/svg+xml on a bgcolorN element — so photographed and
        // unphotographed channels differ only in the src. Read as a photo it
        // would win §2.3's fallback chain and paint Telegram's letter where
        // ours belongs, so it has to parse as ABSENT, by both routes.
        letterAvatar: (() => {
          const LETTER = 'data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMTYwIi8+';
          const REAL = 'https://cdn1.telesco.pe/file/real.jpg';
          const page = (img, og) => `<html><head><meta property="og:image" content="${og}"></head><body>`
            + `<main class="tgme_main"><div class="tgme_channel_info"><div class="tgme_page_photo">`
            + `<i class="tgme_page_photo_image bgcolor1" data-content="E"><img src="${img}"></i>`
            + `</div><div class="tgme_channel_info_header_title">Probe</div></div></main></body></html>`;
          const face = (img, og) => parsePreview(page(img, og), 'probe').channel.photo?.url ?? null;
          return { generated: face(LETTER, LETTER), real: face(REAL, ''), ogOnly: face(LETTER, REAL) };
        })(),
        garbage: parsePreview('<html><body>not telegram at all</body></html>', 'nope').unavailable
          && parsePreview('', 'nope').unavailable && parsePreview(null, 'nope').unavailable,
        xss: {
          json: JSON.stringify(xss),
          n: xss.posts.length,
          unknownBlock: post(xss, 15)?.text ?? null,
          twelve: post(xss, 12) ?? null,
          media: kinds(xss),
          photo: xss.channel.photo,
        },
      };
    });
    const crow = parsed.crow;
    ok(crow.n === 4 && crow.ids.join(',') === '6,5,4,3',
      `preview: tastycrow parses 4 posts newest-first, service messages skipped (${crow.ids.join(',')})`);
    ok(crow.three?.text === 'chill, bro' && crow.three.views === 1
      && crow.three.date === Math.floor(Date.parse('2026-08-23T23:09:48+00:00') / 1000)
      && crow.three.link === 'https://t.me/tastycrow/3',
      'preview: post text, views, <time datetime> and the t.me link');
    ok(crow.title === 'tastycrow' && crow.username === 'tastycrow' && crow.backlink === 'tgs_dankcoin',
      `preview: channel header + backlink (tgsocial: @${crow.backlink})`);
    ok(crow.videoItem?.kind === 'video' && crow.videoItem.duration === 55
      && /^https:\/\//.test(crow.videoItem.file?.url ?? '') && /^https:\/\//.test(crow.videoItem.thumb?.file?.url ?? '')
      && crow.videoText === 'nobigdeal.mp4',
      'preview: video with duration, file URL, thumbnail and caption');
    ok(crow.gif?.kind === 'animation' && crow.photo?.kind === 'photo' && /^https:\/\//.test(crow.photo.sizes[0].file.url)
      && crow.photo.sizes[0].w > 0 && crow.photo.sizes[0].h > 0,
      'preview: a looping muted video is a GIF, a photo wrap is a photo with its size');
    ok(crow.summary?.kind === 'summary' && crow.summary.text === 'Audio'
      && crow.kinds.sort().join('+') === 'animation+photo+summary+video',
      `preview: a file Telegram only serves in the app degrades to a summary (${crow.kinds.join('+')})`);
    ok(crow.nextBefore === 3 && !crow.unavailable, `preview: ?before= cursor for the next page (${crow.nextBefore})`);
    ok(parsed.dank.card?.name === 'Elijah' && parsed.dank.card.public === true
      && parsed.dank.card.feeds.join(',') === 'tastycrow' && parsed.dank.card.replies === 'tgs_dankcoin_r',
      'preview: the card is extracted from the channel and parsed by parseCard');
    ok(parsed.dank.n === 1 && parsed.dank.isCard === true && parsed.dank.title === 'Elijah',
      'preview: the pinned-message service block is skipped, the card message is flagged');
    ok(/^https:\/\/cdn\d*\.telesco\.pe\//.test(crow.face ?? '') && crow.postFace === crow.face,
      'preview: the channel photo is parsed and carried onto every post as its source-channel face');
    ok(parsed.dank.face === null && parsed.dank.postFace === null,
      "preview: @tgs_dankcoin's generated letter avatar parses as no photo at all");
    ok(parsed.letterAvatar.generated === null
      && parsed.letterAvatar.real === 'https://cdn1.telesco.pe/file/real.jpg'
      && parsed.letterAvatar.ogOnly === 'https://cdn1.telesco.pe/file/real.jpg',
      'preview: a data: letter avatar is absent by either route; a real CDN photo is not');
    ok(parsed.tg.n === 20 && parsed.tg.nextBefore === 435 && parsed.tg.newestFirst,
      `preview: telegram parses 20 posts newest-first, next page before=${parsed.tg.nextBefore}`);
    ok(parsed.tg.kinds.includes('photo') && parsed.tg.kinds.includes('video') && parsed.tg.previews.length > 0
      && parsed.tg.maxViews > 1000000,
      `preview: media kinds ${parsed.tg.kinds.join('+')}, link previews, compacted views (${parsed.tg.maxViews})`);
    ok(parsed.blank.n === 0 && parsed.blank.unavailable === true,
      'preview: a page with no messages is unavailable, not an empty channel');
    ok(parsed.garbage === true, 'preview: garbage, empty and null input are unavailable, never a throw');
    ok(parsed.docHosts.hostile?.kind === 'summary' && parsed.docHosts.hostile.text === 'invoice.pdf'
      && parsed.docHosts.tme?.kind === 'summary',
      `public: a document row on a host that is not Telegram degrades to a summary, never a Download (${parsed.docHosts.hostile?.kind})`);
    ok(parsed.docHosts.cdn?.kind === 'document' && parsed.docHosts.cdn.file?.url === 'https://cdn4.telesco.pe/file/invoice.pdf',
      'public: a document on Telegram’s own CDN is still a real document row');

    // …and the wall behind that one: `download` is ignored cross-origin, so a
    // plain click would FOLLOW the link and take the reader's tab with it
    const stayed = await pub.evaluate(async () => {
      const media = await import('/js/media.js');
      const before = location.href;
      media.triggerDownload('https://evil.example/pwn.exe', 'invoice.pdf');
      await new Promise((r) => setTimeout(r, 300));
      return { before, after: location.href, title: document.title };
    });
    ok(stayed.before === stayed.after,
      `public: handing over a foreign file never navigates the reader's own tab (${stayed.after})`);
    ok(parsed.xss.unknownBlock === 'a shape this parser has never seen',
      'preview: an unrecognised block degrades to a text post');

    // ── XSS: nothing hostile survives the parser ───────────────────────────
    const json = parsed.xss.json;
    ok(!/javascript:/i.test(json) && !/onerror/i.test(json) && !/<script/i.test(json) && !/data:text\/html/i.test(json),
      'xss: the parsed model carries no javascript:/data: URL, no handler, no markup');
    ok(parsed.xss.media.length === 0 && parsed.xss.photo === null,
      'xss: media behind a javascript:/data: URL is dropped, not rendered');
    ok(parsed.xss.twelve?.entities?.some((e) => e.type.url === 'https://example.com/ok')
      && !parsed.xss.twelve.entities.some((e) => /^(javascript|data):/i.test(e.type.url ?? '')),
      'xss: the real link keeps its entity, the javascript: and data: links become plain text');

    // ── XSS: nothing hostile survives the renderer either ──────────────────
    await pub.goto(`${base}/f/tgs_xss`, { waitUntil: 'load' });
    await pub.waitForSelector('#view article.post', { timeout: 20000 });
    await pub.waitForTimeout(300);
    const inert = await pub.evaluate(() => ({
      fired: window.__xss ?? null,
      handlers: document.querySelectorAll('[onerror], [onclick], [onload], [onmouseover]').length,
      scripts: document.querySelectorAll('#view script, #view iframe, #view object, #view embed').length,
      badLinks: [...document.querySelectorAll('#view a')].filter((a) => /^\s*(javascript|data):/i.test(a.getAttribute('href') || '')).length,
      rels: [...document.querySelectorAll('#view .post-body a')].map((a) => a.getAttribute('rel')),
      realLink: [...document.querySelectorAll('#view .post-body a')].some((a) => a.href === 'https://example.com/ok'),
      posts: document.querySelectorAll('#view article.post').length,
      text: document.getElementById('view').innerText,
    }));
    ok(inert.fired === null, `xss: nothing executed (window.__xss is ${inert.fired})`);
    ok(inert.handlers === 0 && inert.scripts === 0, 'xss: no handler attribute, script, iframe or object in the document');
    ok(inert.badLinks === 0 && inert.realLink, 'xss: no javascript:/data: href in the DOM; the real link is there');
    ok(inert.rels.length > 0 && inert.rels.every((r) => /noopener/.test(r) && /nofollow/.test(r) && /ugc/.test(r)),
      `xss: preview links carry rel="noopener nofollow ugc" (${inert.rels[0]})`);
    ok(inert.posts === 5 && /payload one/.test(inert.text) && !/__xss/.test(inert.text),
      'xss: the hostile page still renders its posts, with the payloads as nothing at all');
    await snapPage(pub, 'public-xss');

    // ── a signed-out visit renders the page (§2.13) ────────────────────────
    await pub.goto(`${base}/f/tastycrow`, { waitUntil: 'load' });
    await pub.waitForSelector('#view article.post', { timeout: 20000 });
    const shell = await pub.evaluate(() => ({
      publicMode: window.__tgsocial.app.publicMode,
      repo: !!window.__tgsocial.repo,
      signin: !!document.querySelector('#view input[type="tel"]'),
      posts: document.querySelectorAll('#view article.post').length,
      comment: [...document.querySelectorAll('#view article.post .btn')].some((b) => /Comment/i.test(b.textContent)),
      counts: document.querySelectorAll('#view .post-comments-count').length,
      follow: [...document.querySelectorAll('#view .btn')].some((b) => /^Follow/i.test(b.textContent)),
      tabs: document.querySelector('#dock .tabs').hidden,
      dock: document.getElementById('dock').hidden,
      status: document.getElementById('status').textContent,
      gold: document.getElementById('status').classList.contains('gold'),
      time: document.querySelector('#view .post-time')?.textContent ?? '',
      text: document.getElementById('view').innerText,
      kebab: document.querySelectorAll('#view .head-actions button.kebab').length,
    }));
    ok(shell.publicMode && !shell.repo, 'public: a visitor with no session gets the public page — no TDLib, no repo');
    ok(!shell.signin && shell.posts === 4, `public: ${shell.posts} posts render with no sign-in wall`);
    ok(!shell.comment && shell.counts === 0 && !shell.follow, 'public: no Comment button, no comment counts, no Follow');
    ok(shell.tabs && !shell.dock, 'public: the floating tab bar is hidden, the dock stays for the nag');
    ok(shell.status === 'Public' && !shell.gold, 'public: a neutral Public pill, never gold');
    ok(/ago$|^now$/.test(shell.time), `public: relative time on the card (${shell.time})`);
    ok(/chill, bro/.test(shell.text) && shell.kebab === 1, 'public: the posts and the §2.6 header kebab');
    await snapPage(pub, 'public-channel');

    // the long-press sheet (§2.3) is on a public card too
    await pub.click('#view article.post .post-body >> nth=0', { button: 'right' });
    await pub.waitForSelector('#modal .modal-card', { timeout: 5000 });
    const sheet = await pub.evaluate(() => document.getElementById('modal').innerText);
    ok(/POST/i.test(sheet) && /Open in Telegram/i.test(sheet) && /Views/i.test(sheet), 'public: the long-press post sheet');
    await pub.click('#modal .modal-card button.btn.ghost');
    await pub.waitForFunction(() => !document.querySelector('#modal .modal-card'), null, { timeout: 5000 });

    // ── the nag (§2.13), verbatim ──────────────────────────────────────────
    const nag = await pub.evaluate(() => {
      const el = document.querySelector('#dock .nag');
      return el ? { text: el.querySelector('.nag-text').textContent, action: el.querySelector('.btn').textContent, close: !!el.querySelector('.nag-close') } : null;
    });
    ok(nag && nag.text === 'Follow this feed in tgsocial.' && nag.action === 'Get It' && nag.close,
      'public: the nag reads "Follow this feed in tgsocial." with Get It and a dismiss');
    await pub.click('#dock .nag .nag-close');
    ok(await pub.evaluate(() => !document.querySelector('#dock .nag')), 'public: the nag dismisses');
    await pub.goto(`${base}/n/tgs_dankcoin`, { waitUntil: 'load' });
    await pub.waitForFunction(() => /FEEDS/i.test(document.getElementById('view').innerText), null, { timeout: 20000 });
    ok(await pub.evaluate(() => !document.querySelector('#dock .nag')), 'public: it stays dismissed for the session');

    // ── /n/<node> — the card ───────────────────────────────────────────────
    const nodeText = await pubText();
    ok(/Elijah/.test(nodeText) && /@tgs_dankcoin/.test(nodeText) && /FEEDS/i.test(nodeText) && /FOLLOWS/i.test(nodeText),
      'public: /n/<node> renders the card — bio, feeds, follows');
    ok(/tastycrow/.test(nodeText), 'public: the node page resolves its feed rows from their own previews');
    await snapPage(pub, 'public-node');

    // ── /u/<name> — the person, resolved through the backlink (PUBLIC §4) ──
    await pub.goto(`${base}/u/tastycrow`, { waitUntil: 'load' });
    await pub.waitForSelector('#view article.post', { timeout: 20000 });
    const person = await pub.evaluate(() => ({
      head: document.querySelector('#view .profile-head').innerText,
      title: document.querySelector('#view .post-title')?.textContent ?? '',
      sub: document.querySelector('#view .post-sub')?.textContent ?? '',
      posts: document.querySelectorAll('#view article.post').length,
      text: document.getElementById('view').innerText,
    }));
    ok(/Elijah/.test(person.head) && /@tgs_dankcoin/.test(person.head),
      'public: /u/tastycrow follows the feed\'s backlink to @tgs_dankcoin');
    ok(person.posts === 4 && /chill, bro/.test(person.text),
      `public: it merges the node's feeds: (${person.posts} posts from @tastycrow)`);
    ok(person.title === 'Elijah' && person.sub === 'tastycrow',
      `public: attribution — the person leads (${person.title}), the channel follows (${person.sub})`);
    await snapPage(pub, 'public-person');

    // ── §2.3 the avatar is the SOURCE CHANNEL, and the header is one row ────
    // @tgs_dankcoin has no photo of its own, so the only face that can appear
    // on these cards is @tastycrow's: the node's own head below shows the
    // fallback initial, the post's shows the channel's CDN photo.
    const faces = await pub.evaluate(() => {
      const face = (av) => ({
        img: av?.querySelector('img')?.getAttribute('src') ?? null,
        initial: av?.querySelector('span')?.textContent ?? null,
      });
      return {
        node: face(document.querySelector('#view .profile-head .avatar')),
        post: face(document.querySelector('#view article.post .post-head .avatar')),
      };
    });
    ok(faces.node.img === null && faces.node.initial === 'E',
      'public: @tgs_dankcoin has no photo — its head falls through to the initial');
    ok(/^https:\/\/cdn\d*\.telesco\.pe\//.test(faces.post.img ?? '') && faces.post.initial === null,
      `public: the post avatar is the source channel's photo, not the node's letter (${faces.post.img?.slice(8, 28)}…)`);

    /**
     * The header, measured rather than eyeballed. Two things are being held
     * apart here (§2.3): the ROW must be as tall as the name/channel stack
     * needs and no taller, and every control in it must still expose a 40pt
     * target. Those pull against each other, which is exactly why the target
     * is an overlay — so the check for it cannot be `getBoundingClientRect` on
     * the painted box. It walks out from each control's centre with
     * elementFromPoint until a point stops resolving to that control, and
     * bisects the last pixel; what comes back is the area a thumb actually
     * lands on, overlaps with neighbours already resolved.
     */
    const header = await pub.evaluate(() => {
      const post = document.querySelector('#view article.post');
      post.scrollIntoView({ block: 'center' });
      const head = post.querySelector('.post-head');
      const box = (el) => el.getBoundingClientRect();
      const line = (el) => Number.parseFloat(getComputedStyle(el).lineHeight);
      const reach = (el, axis, dir) => {
        const b = box(el);
        const cx = b.left + b.width / 2;
        const cy = b.top + b.height / 2;
        const owns = (d) => {
          const hit = axis === 'y'
            ? document.elementFromPoint(cx, cy + dir * d)
            : document.elementFromPoint(cx + dir * d, cy);
          return !!hit && (hit === el || el.contains(hit));
        };
        if (!owns(0)) return 0;
        let lo = 0;
        while (lo < 80 && owns(lo + 1)) lo += 1;
        let hi = lo + 1;
        for (let i = 0; i < 14; i += 1) {
          const mid = (lo + hi) / 2;
          if (owns(mid)) lo = mid; else hi = mid;
        }
        return lo;
      };
      const hit = (el) => ({
        v: +(reach(el, 'y', -1) + reach(el, 'y', 1)).toFixed(2),
        h: +(reach(el, 'x', -1) + reach(el, 'x', 1)).toFixed(2),
      });
      const av = head.querySelector('.avatar');
      const title = head.querySelector('.post-title');
      const sub = head.querySelector('.post-sub');
      const time = head.querySelector('.post-time');
      const share = [...head.querySelectorAll('button.btn')].find((b) => /Share/i.test(b.textContent));
      const n = (x) => +x.toFixed(2);
      return {
        head: n(box(head).height),
        avatar: n(box(av).height),
        stack: n(line(title) + line(sub)),
        titleBox: n(box(title).height),
        titleLine: n(line(title)),
        subBox: n(box(sub).height),
        subLine: n(line(sub)),
        timeBox: n(box(time).height),
        gap: n(box(sub).top - box(title).bottom),
        offCentre: n(Math.abs((box(av).top + box(av).bottom) / 2 - (box(head).top + box(head).bottom) / 2)),
        hits: { title: hit(title), sub: hit(sub), time: hit(time), share: hit(share) },
      };
    });
    ok(Math.abs(header.head - header.stack) <= 1 && header.head - header.avatar <= 8,
      `§2.3 header: ${header.head}px for a ${header.avatar}px avatar — the stack's own two lines (${header.stack}), about one avatar tall`);
    ok(Math.abs(header.titleBox - header.titleLine) < 0.5 && Math.abs(header.subBox - header.subLine) < 0.5
      && Math.abs(header.timeBox - header.subLine) < 0.5,
      `§2.3 header: no inflated line boxes — name ${header.titleBox}/${header.titleLine}, channel ${header.subBox}/${header.subLine}, time ${header.timeBox}`);
    ok(Math.abs(header.gap) < 0.5, `§2.3 header: the channel sits directly under the name, no extra leading (${header.gap}px)`);
    ok(header.offCentre < 0.5, `§2.3 header: the avatar is centred against the stack, not pinned to its top (${header.offCentre}px off)`);
    for (const [what, area] of Object.entries(header.hits)) {
      ok(area.v >= 40 && area.h >= 40, `rule 6: ${what} still exposes a ${area.h}×${area.v} hit area past its painted bounds`);
    }

    // Copy Link: /u/<name> on a person page, /f/<channel> on a channel page
    await pub.click('#view .head-actions button.kebab');
    await pub.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
    await pub.locator('.menu[role="menu"] button.list-item:has-text("Copy Link")').click();
    await pub.waitForFunction(() => /Link copied\./.test(document.getElementById('toast').textContent), null, { timeout: 6000 });
    ok((await pub.evaluate(() => navigator.clipboard.readText())) === 'https://tgsocial.lucianlabs.ca/u/tastycrow',
      'public: Copy Link on a person page copies /u/<name>');

    // tapping the channel subheading pushes the channel page, with ‹ Back
    await pub.click('#view .post-sub >> nth=0');
    await pub.waitForFunction(() => location.pathname === '/f/tastycrow', null, { timeout: 10000 });
    await pub.waitForSelector('#view article.post', { timeout: 20000 });
    ok(await pub.evaluate(() => /Back/.test(document.getElementById('topbar-lead').textContent)),
      'public: a pushed public screen carries ‹ Back');
    await pub.click('#view .head-actions button.kebab');
    await pub.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
    await pub.locator('.menu[role="menu"] button.list-item:has-text("Copy Link")').click();
    await pub.waitForFunction(() => /Link copied\./.test(document.getElementById('toast').textContent), null, { timeout: 6000 });
    ok((await pub.evaluate(() => navigator.clipboard.readText())) === 'https://tgsocial.lucianlabs.ca/f/tastycrow',
      'public: Copy Link on a channel page copies /f/<channel>');

    // ── the merge is the app's own, across two feeds, newest first ─────────
    await pub.goto(`${base}/u/tgs_merge`, { waitUntil: 'load' });
    await pub.waitForSelector('#view article.post', { timeout: 20000 });
    await pub.waitForFunction(() => document.querySelectorAll('#view article.post').length >= 20, null, { timeout: 20000 });
    const merged = await pub.evaluate(() => {
      const subs = [...document.querySelectorAll('#view .post-sub')].map((s) => s.textContent);
      return { subs, first: subs.slice(0, 4), fifth: subs[4], n: subs.length };
    });
    ok(merged.first.every((s) => s === 'tastycrow') && merged.fifth === 'Telegram News',
      `public: two feeds merge strictly newest-first (${merged.first[0]} ×4 then ${merged.fifth})`);
    // endless scroll: the older ?before= page appends
    await pub.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await pub.waitForFunction(() => document.querySelectorAll('#view article.post').length > 24, null, { timeout: 20000 });
    const scrolled = await pub.evaluate(() => ({
      n: document.querySelectorAll('#view article.post').length,
      end: /That's everything\./.test(document.getElementById('view').innerText),
    }));
    ok(scrolled.n > 24, `public: endless scroll pages each source with ?before= (${scrolled.n} posts)`);

    // ── refusals ───────────────────────────────────────────────────────────
    for (const path of ['/u/tgs_hidden', '/f/tgs_hidden', '/n/tgs_hidden']) {
      await pub.goto(`${base}${path}`, { waitUntil: 'load' });
      await pub.waitForFunction(() => /Not listed\.|Channel not found\./.test(document.getElementById('view').innerText), null, { timeout: 20000 });
      const t = await pubText();
      ok(/Not listed\./.test(t) && /asked to stay out of directories/.test(t) && !/A post nobody outside/.test(t),
        `public: ${path} — a node with public: no is not served at all`);
    }

    // The three routes are not the only door. @tgs_seen is an ordinary public
    // node that lists @tgs_hidden in its `feeds:` and follows them — which
    // needs nobody's consent — so the refusal has to hold one hop out too: no
    // merged posts on /u/, and no name, face or feed count filled into a row
    // on /n/. What stays is the bare handle @tgs_seen's own card published.
    await pub.goto(`${base}/n/tgs_seen`, { waitUntil: 'load' });
    await pub.waitForFunction(() => [...document.querySelectorAll('#view .feed-row .row-name')].some((e) => e.textContent === 'tastycrow'),
      null, { timeout: 20000 });
    await pub.waitForTimeout(400);
    const hop = await pub.evaluate(() => ({
      feeds: [...document.querySelectorAll('#view .feed-row .row-name')].map((e) => e.textContent),
      follows: [...document.querySelectorAll('#view .node-row .row-name')].map((e) => e.textContent),
      subs: [...document.querySelectorAll('#view .node-row .row-sub')].map((e) => e.textContent),
      text: document.getElementById('view').innerText,
    }));
    ok(hop.feeds.join(',') === 'tastycrow,@tgs_hidden',
      `public: an unlisted node's feed row keeps the bare handle, the listed one fills in (${hop.feeds.join(', ')})`);
    ok(hop.follows.join(',') === '@tgs_hidden' && hop.subs.join(',') === '@tgs_hidden · 0 feeds' && !/Quiet/.test(hop.text),
      `public: a follows row never republishes an unlisted node's name or feed count (${hop.follows.join(', ')})`);

    await pub.goto(`${base}/u/tgs_seen`, { waitUntil: 'load' });
    await pub.waitForSelector('#view article.post', { timeout: 20000 });
    await pub.waitForFunction(() => /That's everything\./.test(document.getElementById('view').innerText), null, { timeout: 20000 });
    const hopFeed = await pub.evaluate(() => ({
      posts: document.querySelectorAll('#view article.post').length,
      subs: [...new Set([...document.querySelectorAll('#view .post-sub')].map((s) => s.textContent))],
      text: document.getElementById('view').innerText,
    }));
    ok(!/A post nobody outside/.test(hopFeed.text) && !hopFeed.subs.includes('tgs_hidden'),
      'public: /u/<node> never merges a feed that is an unlisted node');
    ok(hopFeed.posts === 4 && /chill, bro/.test(hopFeed.text),
      `public: the listed feed on the same card still renders (${hopFeed.posts} posts)`);
    // PUBLIC §1 — the proxy body is data, not a document. Telegram's preview
    // carries nine <script> tags (six of them telegram.org's), and this origin
    // is where the TDLib session lives, so a reader who opens /tg/s/<channel>
    // directly must get inert characters and nothing that runs.
    {
      const res = await pub.goto(`${base}/tg/s/tastycrow`, { waitUntil: 'load' });
      const headers = res.headers();
      const raw = await pub.evaluate(() => ({
        scripts: document.scripts.length,
        widgets: document.querySelectorAll('.tgme_widget_message').length,
        tbase: typeof window.TBaseUrl,
      }));
      ok(/^text\/plain/.test(headers['content-type'] ?? '') && headers['x-content-type-options'] === 'nosniff'
        && /sandbox/.test(headers['content-security-policy'] ?? ''),
        `public proxy: the preview is served as inert text (${headers['content-type']})`);
      ok(raw.scripts === 0 && raw.widgets === 0 && raw.tbase === 'undefined',
        `public proxy: a direct visit runs nothing — ${raw.scripts} scripts, ${raw.widgets} parsed message nodes`);
    }

    await pub.goto(`${base}/f/tgs_blank`, { waitUntil: 'load' });
    await pub.waitForFunction(() => /Channel not found\./.test(document.getElementById('view').innerText), null, { timeout: 20000 });
    ok(/@tgs_blank is not a public channel\./.test(await pubText()),
      'public: a page that parses to nothing gets the §2.6 empty card, not an empty feed');
    await snapPage(pub, 'public-empty');

    // a malformed escape is a bad username, never a blank page (§2.13)
    for (const bad of ['/f/%zz', '/f/%E0%A4%A', '/f/bad-name']) {
      await pub.goto(`${base}${bad}?mock=node`, { waitUntil: 'load' });
      await pub.waitForSelector('#view .card', { timeout: 25000 });
      const fell = await pub.evaluate(() => ({
        publicMode: window.__tgsocial.app.publicMode,
        view: document.getElementById('view').textContent.trim().length,
      }));
      ok(!fell.publicMode && fell.view > 0, `public: ${bad} is not a public route and never a blank page`);
    }
    await pubCtx.close();
  }

  // ── §2.13 signed in on the same URLs ──────────────────────────────────────
  // A reader who has signed in on this device gets the app on a public link,
  // not the public page: the tab bar, Comment, Follow, and no nag. The
  // destination survives the Sign in and Setup detour — Setup rewrites the
  // hash, and the link outlives it. The premise underneath is still true and
  // still guarded: TDLib refuses every chat read before authorization.
  {
    const newCtx = await browser.newContext({ viewport: { width: 390, height: 844 }, permissions: ['clipboard-read', 'clipboard-write'] });
    await newCtx.route('**/vendor/tdweb/tdweb.js', (route) => route.fulfill({ status: 200, contentType: 'application/javascript', body: mock }));
    // local state is what says "this browser has signed in here" (js/app.js)
    await newCtx.addInitScript(() => {
      try {
        localStorage.setItem('tgs.prefs', '{}');
      } catch {}
    });
    const fresh = await newCtx.newPage();
    fresh.on('console', (m) => {
      if (m.type() === 'error') errors.push(`public-setup: ${m.text()}`);
    });
    fresh.on('pageerror', (e) => errors.push(`public-setup pageerror: ${e.message}`));
    await fresh.goto(`${base}/f/waveloop_devlog?mock=fresh`, { waitUntil: 'load' });
    await fresh.waitForSelector('input[type="tel"]', { timeout: 20000 });
    ok(await fresh.evaluate(() => !window.__tgsocial.app.publicMode && /Sign in to see @waveloop_devlog\./.test(document.getElementById('view').innerText)),
      'signed in: a known browser on a public link gets Sign in, destination named');
    ok(await fresh.evaluate(() => window.__tgsocial.app.pendingDest?.username === 'waveloop_devlog'),
      'signed in: the destination is held for the sign-in detour');

    // the premise, asserted rather than assumed
    const refused = await fresh.evaluate(async () => {
      try {
        await window.__tgsocial.td.send({ '@type': 'searchPublicChat', username: 'waveloop_devlog' });
        return 'resolved';
      } catch (e) {
        return `${e.code} ${e.message}`;
      }
    });
    ok(/^401 /.test(refused), `signed in: a chat read before authorization is still refused (${refused})`);

    await fresh.fill('input[type="tel"]', '+16045550199');
    await fresh.click('button.btn.primary');
    await fresh.waitForSelector('input[inputmode="numeric"]', { timeout: 10000 });
    await fresh.fill('input[inputmode="numeric"]', '12345');
    await fresh.click('button.btn.primary');
    await fresh.waitForFunction(() => /Make your node\./.test(document.getElementById('view').innerText), null, { timeout: 25000 });
    ok(await fresh.evaluate(() => location.hash === '#/setup' && window.__tgsocial.app.pendingDest?.username === 'waveloop_devlog'),
      'signed in: Setup takes the hash, and the destination is still held');
    await fresh.click('#view button.btn.ghost:has-text("Skip for now")');
    await fresh.waitForFunction(() => /@waveloop_devlog/.test(document.getElementById('view').innerText), null, { timeout: 25000 });
    ok(await fresh.evaluate(() => location.hash === '#/feed/waveloop_devlog' && window.__tgsocial.app.pendingDest === null),
      'signed in: leaving Setup lands on the linked channel, and the link is spent');

    await fresh.waitForSelector('#view article.post', { timeout: 25000 });
    const landed = await fresh.evaluate(() => ({
      publicMode: window.__tgsocial.app.publicMode,
      tabs: !document.querySelector('#dock .tabs').hidden,
      status: document.getElementById('status').textContent,
      nag: !!document.querySelector('#dock .nag'),
      comments: document.querySelectorAll('#view article.post .post-foot .btn').length,
      counts: document.querySelectorAll('#view .post-comments-count').length,
      kebab: !![...document.querySelectorAll('#view .head-actions button.kebab')].length,
      headerTelegram: [...document.querySelectorAll('#view .profile-head button')].some((b) => /Open in Telegram/i.test(b.textContent)),
    }));
    ok(!landed.publicMode && landed.tabs && landed.status !== 'Public' && !landed.nag,
      'signed in: the same URL is the normal screen — tab bar, real status pill, no nag');
    ok(landed.comments > 0 && landed.counts > 0, 'signed in: the Comment button and comment counts are on the card');
    ok(landed.kebab && !landed.headerTelegram, 'signed in: the header carries the kebab, not a standalone Open in Telegram');
    await snapPage(fresh, 'public-signedin');

    // §2.13 Sharing — Copy Link copies the tgsocial URL, not the t.me one
    await fresh.click('#view .head-actions button.kebab');
    await fresh.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
    await fresh.locator('.menu[role="menu"] button.list-item:has-text("Copy Link")').click();
    await fresh.waitForFunction(() => /Link copied\./.test(document.getElementById('toast').textContent), null, { timeout: 6000 });
    ok((await fresh.evaluate(() => navigator.clipboard.readText())) === 'https://tgsocial.lucianlabs.ca/f/waveloop_devlog',
      'signed in: Copy Link copies the tgsocial URL');

    await newCtx.close();
  }

  ok(errors.length === 0, `zero console errors${errors.length ? `: ${errors.join(' | ')}` : ''}`);
  await browser.close();
} catch (e) {
  failures.push(e.message);
  console.log(`not ok - ${e.message}`);
  console.log(e.stack);
  try {
    if (shotsDir && globalThis.__page) await globalThis.__page.screenshot({ path: join(shotsDir, 'zz-failure.png'), fullPage: true });
  } catch {}
} finally {
  server.close();
}

if (failures.length) {
  console.log(`# flows: ${failures.length} failure(s)`);
  process.exit(1);
}
console.log('# flows: all checks passed');
