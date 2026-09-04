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
import { analysisRate, axisMaxHz, rowForFrequency } from '../js/spectro.js';
import { MOSAIC_AREAS, mosaicPlan } from '../js/mosaic.js';

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
  /**
   * The §2.3 gesture that opens a sheet: a 500 ms hold that jitters a few px,
   * because real fingers do and the slop has to tolerate it. Used for the post
   * sheet and, since §2.12, for the comment sheet.
   */
  const longPressOn = async (p, locator) => {
    // hover() scrolls it in and picks a point nothing else covers; the press
    // then jitters inside the slop, because real fingers do (§2.3)
    await locator.hover();
    await p.mouse.down();
    await p.waitForTimeout(150);
    const bb = await locator.boundingBox();
    await p.mouse.move(bb.x + bb.width / 2 + 3, bb.y + bb.height / 2 + 2);
    await p.waitForTimeout(450);
    await p.mouse.up();
    await p.waitForSelector('#modal .modal-card', { timeout: 5000 });
  };
  const longPress = (locator) => longPressOn(page, locator);
  /**
   * The same §2.3 press, aimed at a point that is actually words.
   *
   * A post body is text with a mention and sometimes a link inside it, and the
   * sheet is deliberately suppressed on those — they keep their own gestures.
   * The corners are no safer: §2.3's controls carry 40pt hit overlays that
   * reach past their painted bounds (COMPONENTS rule 6), and the title's
   * reaches down over the top of the body. So the point is read off the
   * rendered text and then confirmed with elementFromPoint, rather than
   * guessed from the box — which is what made this press depend on how a
   * particular post happened to wrap.
   */
  const longPressTextOn = async (page, locator) => {
    // to the middle of the viewport, not merely into it: the topbar and the
    // floating dock are fixed, and a body parked under either has no point
    // that elementFromPoint will hand back
    await locator.evaluate((el) => el.scrollIntoView({ block: 'center', behavior: 'instant' }));
    await page.waitForTimeout(200);
    const at = await locator.evaluate((el) => {
      const SUP = 'button, a, input, textarea, .media, .post-media, .player, .waveform, .scrubber, video, audio';
      const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      for (let n = walk.nextNode(); n; n = walk.nextNode()) {
        if (!n.nodeValue.trim() || n.parentElement?.closest(SUP)) continue;
        const range = document.createRange();
        range.selectNodeContents(n);
        for (const rect of range.getClientRects()) {
          if (rect.width < 16 || rect.height < 8) continue;
          const x = rect.left + Math.min(20, rect.width / 2);
          const y = rect.top + rect.height / 2;
          const hit = document.elementFromPoint(x, y);
          if (hit && el.contains(hit) && !hit.closest(SUP)) return { x, y };
        }
      }
      return null;
    });
    if (!at) throw new Error('no pressable words in this body');
    await page.mouse.move(at.x, at.y);
    await page.mouse.down();
    await page.waitForTimeout(150);
    await page.mouse.move(at.x + 3, at.y + 2);
    await page.waitForTimeout(450);
    await page.mouse.up();
    await page.waitForSelector('#modal .modal-card', { timeout: 5000 });
  };
  const longPressText = (locator) => longPressTextOn(page, locator);
  const closeSheet = async () => {
    await page.click('#modal button.btn.ghost:has-text("Close")');
    await page.waitForFunction(() => !document.querySelector('#modal .modal-card'), null, { timeout: 5000 });
  };
  const modalText = () => page.evaluate(() => document.getElementById('modal').innerText);
  /**
   * The first post card on screen attributed to <name> (§2.3's title line)
   * whose body is one of the mock's plain paragraphs.
   *
   * Both halves matter. WHOSE post it is decides what §2.16 puts on its sheet —
   * `Block @node` on somebody else's, nothing on my own — and "the first post"
   * does not say which. And a press or a click has to land on words: the other
   * bodies are a caption whose middle is a URL, and a tap there opens the link
   * instead of the post.
   */
  const cardOf = async (name = null) => {
    const key = await page.evaluate((n) => {
      const c = [...document.querySelectorAll('#view article.post')].find((x) => {
        if (!/^Post \d+: /.test(x.querySelector('.post-body')?.textContent ?? '')) return false;
        return !n || x.querySelector('.post-title')?.textContent === n;
      });
      return c ? c.querySelector('.post-body').textContent.slice(0, 12) : null;
    }, name);
    if (!key) throw new Error(`no plain-text post${name ? ` attributed to ${name}` : ''} on screen`);
    // by its own words, not by an index: the feed replaces its cards on every
    // refresh, and an index read a round trip ago names a different post
    return page.locator('#view article.post').filter({ hasText: key }).first();
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
    return rows.map((r) => r.textContent).join('|') === 'Open in Telegram|Copy Link|Mute Feed' &&
      cs.borderTopLeftRadius === radius &&
      cs.boxShadow !== 'none' &&
      rows.every((r) => r.getBoundingClientRect().height >= 40);
  }), 'channel: kebab opens the House Pour menu — Open in Telegram, Copy Link, Mute Feed, 40pt rows');
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

  // §2.13 Copy Link — with no `publicOrigin` in config.json, which is the
  // default and what this repo's own config.json has, the shareable link is
  // the t.me one: it works for everyone and needs nobody's deployment
  await page.click('#view .head-actions button.kebab');
  await page.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
  await page.click('.menu[role="menu"] button.list-item:has-text("Copy Link")');
  await waitToast(/Link copied\./);
  ok((await page.evaluate(() => navigator.clipboard.readText())) === 'https://t.me/ana_notes', 'channel: Copy Link copies the t.me link and toasts');

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

  // ── §2.15–§2.20 report, block, mute, and the lists behind them ───────────
  //
  // The filter is the product here: what these assert is that reported,
  // blocked and muted things STOP PAINTING, not that a function ran.
  await page.goto(`${base}/?mock=fresh#/you`, { waitUntil: 'load' });
  await waitText(/YOUR FEEDS/, 15000);
  const youFoot = await text();
  ok(/Questions or reports: elijah@lucianlabs\.ca/.test(youFoot), 'you: §2.19 contact line above the version line');
  ok(/Reports are read by a person within 24 hours\./.test(youFoot), 'you: the response commitment');
  ok(!/SIGN OUT/.test(youFoot) && /SETTINGS/.test(youFoot), 'you: §2.8 Sign Out moved to Settings');

  await page.click('#view button.btn:has-text("Settings")');
  await waitText(/BLOCKED · 0/, 10000);
  const settings0 = await text();
  ok(/The filter is always on; there is no switch\./.test(settings0), 'settings: §2.18 — the filter has no switch');
  ok(/These lists live on this device only and nobody else can read them\./.test(settings0), 'settings: the lists are local');
  ok(/You haven't blocked anyone\./.test(settings0) && /No muted feeds\./.test(settings0) && /Nothing hidden\./.test(settings0),
    'settings: three empty states');
  ok(/MUTED · 0/.test(settings0) && /HIDDEN · 0/.test(settings0), 'settings: serif counts on all three marks');
  ok(/Content that breaks the rules is reported to Telegram, the only party that can remove it from the network\./.test(settings0),
    'settings: §2.19 says what a serverless client can and cannot promise');
  ok(await page.evaluate(() => [...document.querySelectorAll('#view button.btn.danger')].map((b) => b.textContent).join('|') === 'Sign Out|Delete My Node'),
    'settings: Sign Out, then Delete My Node — reversible before irreversible');
  await snap('settings');

  // ── §2.15 report a post: the email, and the immediate hide ───────────────
  await page.goto(`${base}/?mock=fresh#/feed`, { waitUntil: 'load' });
  await page.waitForSelector('#view article.post .post-body', { timeout: 20000 });
  /**
   * Who the feed's first page carries with empty lists. Every filter assertion
   * below is a before/after against this: "gone" is only a claim when the same
   * feed was showing them a moment ago.
   */
  const census = () => page.evaluate(() => ({
    posts: document.querySelectorAll('#view article.post').length,
    ana: [...document.querySelectorAll('#view .post-title')].filter((t) => t.textContent === 'Ana Iliovic').length,
    tres: [...document.querySelectorAll('#view .post-sub')].filter((t) => t.textContent === 'Très Buchet').length,
  }));
  /** The cold-start cache paints before the refresh lands, so read a feed that stopped moving. */
  const feedCensus = async () => {
    await page.waitForSelector('#view article.post', { timeout: 20000 });
    let prev = null;
    for (let i = 0; i < 30; i += 1) {
      const now = await census();
      if (prev && now.posts === prev.posts && now.ana === prev.ana && now.tres === prev.tres) return now;
      prev = now;
      await page.waitForTimeout(600);
    }
    return prev;
  };
  const baseline = await feedCensus();
  ok(baseline.ana > 0 && baseline.tres > 0, `feed baseline: ${baseline.ana} posts from Ana, ${baseline.tres} from Très Buchet`);
  // §2.16's `Block @node` rides on the attributed node (§2.3) and is never
  // offered on your own (js/views/safety.js), so the full block is asserted on
  // a post that is somebody else's. The absent case has its own pair below.
  await longPressText((await cardOf('Ana Iliovic')).locator('.post-body').first());
  const theirSheet = await modalText();
  ok(/SAFETY/.test(theirSheet), 'post sheet: the SAFETY block');
  ok(/Report Post/i.test(theirSheet) && /Block @tgs_ana/i.test(theirSheet) && /Mute /i.test(theirSheet),
    'post sheet: Report Post, Block @node, Mute <feed>');
  await closeSheet();
  const reported = page.locator('#view article.post:has(.post-body)').first();
  const reportedText = (await reported.locator('.post-body').first().innerText()).slice(0, 30);
  await longPress(reported.locator('.post-body').first());
  const safetySheet = await modalText();
  await page.click('#modal button.btn.danger:has-text("Report Post")');
  await page.waitForSelector('#modal .reason-list', { timeout: 5000 });
  const reportSheet = await modalText();
  ok(/REPORT/.test(reportSheet) && /Report this post\./.test(reportSheet), 'report: REPORT mark and the post heading');
  ok(/This sends an email from your mail app to the person who maintains tgsocial, with a link to it\. It disappears from this device as soon as you send\./.test(reportSheet),
    'report: the explainer, verbatim');
  ok(await page.evaluate(() => [...document.querySelectorAll('#modal .reason-row .reason-label')].map((r) => r.textContent).join('|')
    === 'Spam|Nudity or sexual content|Violence or threats|Hate or harassment|Child safety|Illegal content|Something else'),
    'report: the seven reasons, in order');
  ok(await page.evaluate(() => [...document.querySelectorAll('#modal .reason-row')].every((r) => r.getBoundingClientRect().height >= 40)),
    'report: reason rows are 40pt');
  ok(await page.evaluate(() => document.querySelector('#modal .modal-card[aria-label="Report"] button.btn.danger').disabled === true),
    'report: Send Report is disabled until a reason is picked');
  // the mail composer is the browser's; capture what we would hand it
  await page.evaluate(() => {
    const orig = HTMLAnchorElement.prototype.click;
    window.__mailto = null;
    window.__restoreClick = () => { HTMLAnchorElement.prototype.click = orig; };
    HTMLAnchorElement.prototype.click = function click(...args) {
      if (String(this.href).startsWith('mailto:')) {
        window.__mailto = this.href;
        return undefined;
      }
      return orig.apply(this, args);
    };
  });
  await page.click('#modal .reason-row:has-text("Spam")');
  ok(await page.evaluate(() => document.querySelector('#modal .reason-row[aria-checked="true"] .reason-label')?.textContent === 'Spam'
    && document.querySelector('#modal .modal-card[aria-label="Report"] button.btn.danger').disabled === false),
    'report: picking a reason checks that row and arms Send Report');
  await snap('report');
  await page.click('#modal button.btn.danger:has-text("Send Report")');
  await waitToast(/Reported\. It's hidden here now\./);
  const mail = await page.evaluate(() => window.__mailto);
  const mailUrl = new URL(mail);
  ok(mailUrl.pathname === 'elijah@lucianlabs.ca', 'report email: addressed to the published address');
  ok(mailUrl.searchParams.get('subject') === 'tgsocial report — Spam', 'report email: subject is the reason, verbatim');
  const mailBody = mailUrl.searchParams.get('body');
  ok(/^Reason: Spam\nLink: https:\/\/t\.me\/[a-z_]+\/\d+\nChannel: @[a-z_]+\nMessage: \d+\nNode: (@[a-z_]+|unattributed)\nKind: post\nApp: tgsocial 1\.0\.0 \(1\) · Web\n\nAnything you want to add:\n\n$/.test(mailBody),
    `report email: the body is §2.15's, ending on the blank line the cursor lands in`);
  const hiddenNow = await page.evaluate(() => window.__tgsocial.safety.hidden);
  ok(hiddenNow.length === 1 && hiddenNow[0].reason === 'Spam' && /^[a-z_]+\/\d+$/.test(hiddenNow[0].key),
    'report: one hidden entry, keyed <channel>/<id>, reason stored verbatim');
  ok(mailBody.includes(`Link: https://t.me/${hiddenNow[0].key}`), 'report: the email links the thing that was hidden');
  await page.waitForFunction((t) => !document.getElementById('view').innerText.includes(t), reportedText, { timeout: 15000 });
  ok(true, 'report: the post stops painting on this device at once (§2.18)');

  // §2.20 — the hidden row names the channel and the id, never the content
  await page.goto(`${base}/?mock=fresh#/settings`, { waitUntil: 'load' });
  await waitText(/HIDDEN · 1/, 15000);
  const hiddenRow = await page.evaluate(() => document.querySelector('#view .hidden-row')?.innerText ?? '');
  ok(/ · \d+/.test(hiddenRow), 'settings: the hidden row is channel · message id');
  ok(new RegExp(`Spam · reported \\d{4}-\\d{2}-\\d{2}`).test(hiddenRow), 'settings: reason · reported <date>');
  ok(!hiddenRow.includes(reportedText), 'settings: and never a preview of what was reported');
  await page.click('#view .hidden-row button.btn:has-text("Unhide")');
  await waitToast(/Unhidden\. It's back in your feed\./);
  await waitText(/HIDDEN · 0/);
  ok(await page.evaluate(() => window.__tgsocial.safety.hidden.length === 0), 'settings: Unhide clears the entry');
  await page.goto(`${base}/?mock=fresh#/feed`, { waitUntil: 'load' });
  await page.waitForFunction((t) => document.getElementById('view').innerText.includes(t), reportedText, { timeout: 20000 });
  ok(true, 'settings: and the post is back in the feed');

  // §2.15 — no mail app: hidden anyway, and the toast names the address
  await page.evaluate(() => {
    window.__restoreClick();
    const orig = HTMLAnchorElement.prototype.click;
    window.__restoreClick = () => { HTMLAnchorElement.prototype.click = orig; };
    HTMLAnchorElement.prototype.click = function click(...args) {
      if (String(this.href).startsWith('mailto:')) throw new Error('no handler for mailto:');
      return orig.apply(this, args);
    };
  });
  await longPress(page.locator('#view article.post:has(.post-body)').first().locator('.post-body').first());
  await page.click('#modal button.btn.danger:has-text("Report Post")');
  await page.waitForSelector('#modal .reason-list', { timeout: 5000 });
  await page.click('#modal .reason-row:has-text("Illegal content")');
  await page.click('#modal button.btn.danger:has-text("Send Report")');
  await waitToast(/No mail app\. Write to elijah@lucianlabs\.ca\./);
  ok(await page.evaluate(() => window.__tgsocial.safety.hidden.length === 1
    && window.__tgsocial.safety.hidden[0].reason === 'Illegal content'),
    'report: a composer that refuses to open still hides it (§2.15)');
  await page.evaluate(() => {
    window.__restoreClick();
    window.__tgsocial.safety.unhide(window.__tgsocial.safety.hidden[0].key);
  });

  // ── §2.16 block a node ───────────────────────────────────────────────────
  await page.goto(`${base}/?mock=fresh#/node/tgs_ana`, { waitUntil: 'load' });
  await waitText(/Voice, product, Vancouver\./, 20000);
  await page.click('#view .profile-head button.kebab');
  await page.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
  ok(await page.evaluate(() => [...document.querySelectorAll('.menu[role="menu"] button.list-item')].map((r) => r.textContent).join('|')
    === 'Open in Telegram|Copy Link|Block @tgs_ana'), 'profile: §2.5 kebab carries Block @node');
  await page.click('.menu[role="menu"] button.list-item:has-text("Block @tgs_ana")');
  await page.waitForSelector('#modal .modal-card', { timeout: 5000 });
  const blockModal = await modalText();
  ok(/Block @tgs_ana\?/.test(blockModal), 'block: the confirm names the node');
  ok(/Their posts and their comments disappear from your feed, your threads, your graph, and search\. They are not told\. Undo it in Settings\./.test(blockModal),
    'block: the confirm body, verbatim');
  await snap('block');
  await page.click('#modal button.btn.danger:has-text("Block")');
  await waitToast(/Blocked @tgs_ana\./);
  await waitText(/You blocked this node\./, 10000);
  const blockedProfileText = await text();
  ok(/@tgs_ana/.test(blockedProfileText) && /Nothing they post reaches you\./.test(blockedProfileText) && /UNBLOCK/.test(blockedProfileText),
    'block: the profile is the one place they are drawn, and it says so');
  ok(!/Voice, product, Vancouver\./.test(blockedProfileText) && !/FEEDS/.test(blockedProfileText),
    'block: and it carries none of their card');
  // §2.16 — blocking never edits the card: they stay followed, publicly
  await page.waitForFunction(() => !!window.__tgsocial.repo.myCard, null, { timeout: 10000, polling: 300 });
  ok(await page.evaluate(() => window.__tgsocial.repo.myCard.follows.includes('tgs_ana')
    && /^follows: @tgs_ana$/m.test(window.__mock.pinned[window.__tgsocial.repo.myNode.chatId].content.text.text)),
    'block: the card is untouched — enforcing a block would publish it');
  await page.goto(`${base}/?mock=fresh#/feed`, { waitUntil: 'load' });
  const blockedFeed = await feedCensus();
  ok(blockedFeed.ana === 0 && blockedFeed.posts > 0,
    `block: ${baseline.ana} posts from Ana became 0, with ${blockedFeed.posts} still in the feed — no tombstone, no row, no count`);
  await page.goto(`${base}/?mock=fresh#/graph`, { waitUntil: 'load' });
  await waitText(/DIRECT · 0/, 20000);
  ok(true, 'block: not in DIRECT either (§2.18)');
  await page.goto(`${base}/?mock=fresh#/settings`, { waitUntil: 'load' });
  await waitText(/BLOCKED · 1/, 15000);
  ok(/@tgs_ana/.test(await page.evaluate(() => document.querySelector('#view .node-row').innerText)), 'settings: the blocked row names them');
  await page.click('#view .node-row button.btn:has-text("Unblock")');
  await waitToast(/Unblocked @tgs_ana\./);
  await waitText(/BLOCKED · 0/);
  ok(true, 'settings: Unblock is one tap, no confirm');

  // ── §2.17 mute a feed ────────────────────────────────────────────────────
  await page.goto(`${base}/?mock=fresh#/feed/tresbuchet`, { waitUntil: 'load' });
  await page.waitForSelector('#view article.post', { timeout: 20000 });
  const channelPosts = await page.locator('#view article.post').count();
  await page.click('#view .head-actions button.kebab');
  await page.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
  await page.click('.menu[role="menu"] button.list-item:has-text("Mute Feed")');
  await waitToast(/Muted Très Buchet\./);
  await page.waitForSelector('#view article.post', { timeout: 20000 });
  ok((await page.locator('#view article.post').count()) >= channelPosts,
    'mute: the channel stays complete on its own screen (§2.17)');
  await page.click('#view .head-actions button.kebab');
  await page.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
  ok(await page.evaluate(() => [...document.querySelectorAll('.menu[role="menu"] button.list-item')].some((r) => r.textContent === 'Unmute Feed')),
    'mute: the kebab reads the state, because the undo is the same tap');
  await page.keyboard.press('Escape');
  await page.goto(`${base}/?mock=fresh#/feed`, { waitUntil: 'load' });
  const mutedFeed = await feedCensus();
  ok(mutedFeed.tres === 0 && mutedFeed.ana > 0,
    `mute: ${baseline.tres} posts from Très Buchet became 0 in the merged feed, and nobody else moved`);
  await page.goto(`${base}/?mock=fresh#/node/tgs_newbie`, { waitUntil: 'load' });
  // the profile paints its feed rows as bare handles and fills each one in from
  // its own read, twice — once off the cache, once off the forced one — so the
  // titled row can be replaced by a bare one again a moment after it appears.
  // Wait for the state, do not sample it.
  await page.waitForFunction(() => {
    const row = [...document.querySelectorAll('#view .feed-row')].find((r) => /Très Buchet/.test(r.innerText));
    return row?.querySelector('.row-name .pill')?.textContent === 'Muted';
  }, null, { timeout: 20000 });
  ok(true, 'mute: the feed keeps its row on the profile and carries a faint Muted pill');
  await page.goto(`${base}/?mock=fresh#/feed/tresbuchet`, { waitUntil: 'load' });
  await page.waitForSelector('#view .head-actions button.kebab', { timeout: 20000 });
  await page.click('#view .head-actions button.kebab');
  await page.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
  await page.click('.menu[role="menu"] button.list-item:has-text("Unmute Feed")');
  await waitToast(/Unmuted Très Buchet\./);
  ok(await page.evaluate(() => window.__tgsocial.safety.mutedFeeds.length === 0), 'mute: unmuted');

  // ── §2.21 delete my node ─────────────────────────────────────────────────
  const nodeIds = await page.evaluate(async () => {
    const repo = window.__tgsocial.repo;
    // a comments channel, so both steps of PROTOCOL §4.11 actually run
    if (!repo.myCard?.replies) await repo.createRepliesChannel('tgs_newbie_r');
    const sg = Object.values(window.__mock.supergroups).find((s) => s.usernames?.editable_username === 'tgs_newbie_r');
    const repliesChat = Object.values(window.__mock.chats).find((c) => c.type.supergroup_id === sg?.id);
    const c = window.__mock.client;
    const orig = c.handle.bind(c);
    window.__deletes = [];
    c.handle = (q) => {
      if (q['@type'] === 'deleteChat') window.__deletes.push(q.chat_id);
      return orig(q);
    };
    return { node: repo.myNode.chatId, replies: repliesChat.id };
  });
  // not the owner: nothing is deleted, and the modal says who to ask
  await page.evaluate((id) => { window.__mock.chats[id].can_be_deleted_for_all_users = false; }, nodeIds.node);
  await page.goto(`${base}/?mock=fresh#/settings`, { waitUntil: 'load' });
  await waitText(/DELETE MY NODE/, 15000);
  await page.click('#view button.btn.danger:has-text("Delete My Node")');
  await page.waitForSelector('#modal .modal-card', { timeout: 5000 });
  const deleteModal = await modalText();
  ok(/Delete my node\./.test(deleteModal), 'delete: the heading');
  ok(/This deletes the channel @tgs_newbie and your comments channel @tgs_newbie_r from Telegram\./.test(deleteModal)
    && /the names are released for anyone to take\. This cannot be undone\./.test(deleteModal), 'delete: names both channels and the consequence');
  ok(/Your feed channels are not touched\./.test(deleteModal), 'delete: and what it does not touch');
  ok(/TYPE @TGS_NEWBIE TO CONFIRM/i.test(deleteModal), 'delete: type-the-username field label');
  ok(await page.evaluate(() => document.querySelector('#modal button.btn.danger').disabled === true), 'delete: disabled before the input matches');
  await page.fill('#modal input', 'tgs_new');
  ok(await page.evaluate(() => document.querySelector('#modal button.btn.danger').disabled === true), 'delete: a near miss does not arm it');
  await page.fill('#modal input', 'TGS_NEWBIE');
  ok(await page.evaluate(() => document.querySelector('#modal button.btn.danger').disabled === false),
    'delete: the match is case-insensitive and forgives a missing @');
  await snap('delete-node');
  await page.click('#modal button.btn.danger:has-text("Delete My Node")');
  await page.waitForFunction(() => /only the channel's owner can/.test(document.getElementById('modal').innerText), null, { timeout: 10000 });
  ok(/Telegram won't let you delete @tgs_newbie — only the channel's owner can\. Open it in Telegram to see who owns it\./.test(await modalText()),
    'delete: the not-owner modal, verbatim');
  ok(await page.evaluate(() => window.__deletes.length === 0), 'delete: and nothing was deleted');
  await page.click('#modal button.btn.ghost:has-text("Close")');
  // the owner's path: comments channel first, node second (PROTOCOL §4.11)
  await page.evaluate((id) => { window.__mock.chats[id].can_be_deleted_for_all_users = true; }, nodeIds.node);
  await page.click('#view button.btn.danger:has-text("Delete My Node")');
  await page.waitForSelector('#modal input', { timeout: 5000 });
  await page.fill('#modal input', '@tgs_newbie');
  await page.click('#modal button.btn.danger:has-text("Delete My Node")');
  await waitToast(/Your node is gone\./, 15000);
  ok(await page.evaluate(([replies, node]) => window.__deletes.join(',') === `${replies},${node}`, [nodeIds.replies, nodeIds.node]),
    'delete: the comments channel goes first, the node second — a dead backlink is the one unrecoverable order');
  ok(await page.evaluate(([replies, node]) => !window.__mock.chats[replies] && !window.__mock.chats[node], [nodeIds.replies, nodeIds.node]),
    'delete: both channels are gone from Telegram');
  await page.waitForFunction(() => location.hash === '#/setup', null, { timeout: 10000 });
  ok(await page.evaluate(() => window.__tgsocial.repo.myNode === null), 'delete: nodeless, still signed in, back at Setup');

  // ── sign out (from Settings, §2.20) ──────────────────────────────────────
  //
  // The lists are what survives it (PROTOCOL §7.1): a block list that
  // evaporated on sign-out would re-expose the reader to the person they
  // blocked the next time they signed in. The UI path for blocking is measured
  // above; what is under test here is that the record outlives `logOut`.
  await page.evaluate(() => window.__tgsocial.safety.block('tgs_ana'));
  await page.goto(`${base}/?mock=fresh#/settings`, { waitUntil: 'load' });
  await waitText(/SIGN OUT/, 15000);
  await page.click('#view button.btn.danger:has-text("Sign Out")');
  await page.waitForSelector('#modal .modal-card', { timeout: 5000 });
  ok(/Sign out of tgsocial\?/.test(await page.evaluate(() => document.getElementById('modal').innerText)), 'sign out: confirm modal copy');
  await snap('signout');
  await page.click('#modal button.btn.danger');
  await page.waitForFunction(() => /Your Telegram, as a feed\./.test(document.getElementById('view').innerText)
    && Object.keys(localStorage).join() === 'tgs.moderation', null, { timeout: 15000 });
  ok(true, 'sign out: every cache wiped, back at sign-in');
  ok(await page.evaluate(() => JSON.parse(localStorage.getItem('tgs.moderation')).blocked.join() === 'tgs_ana'),
    'sign out: the safety lists survive it, for the same account (PROTOCOL §7.1)');
  await page.evaluate(() => localStorage.removeItem('tgs.moderation'));

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
  await page.waitForFunction(() => [...document.querySelectorAll('#view .post-media img, #view .post-mosaic-tile img')].some((i) => i.src.startsWith('blob:')), null, { timeout: 10000 });
  ok(true, 'feed: media loaded via readFile blob');
  ok(/release-notes-\d+\.pdf/.test(feedText), 'feed: document file name');
  ok(/Bench loop/.test(feedText) && /3:32/.test(feedText), 'feed: audio title + duration');
  ok(await page.evaluate(() => !!document.querySelector('#view .player .player-btn')), 'feed: audio renders as a House Pour player row');
  ok(/Poll · 3 options/.test(feedText), 'feed: poll summary');
  ok(/Lucian Labs/.test(feedText), 'feed: link preview row');
  ok(await page.evaluate(() => [...document.querySelectorAll('#view article.post')].every((a) => !/Pinned a message/.test(a.textContent))), 'feed: service messages skipped');
  await snap('feed');

  // ── §2.11.1 the spectrogram strip ────────────────────────────────────────
  //
  // The audio scrubber is a spectrogram of the WHOLE clip with a one-pole
  // envelope over it, and it IS the scrubber. The mock serves a real,
  // decodable WAV for every audio and voice id (test/mock-tdweb.js): a steady
  // 180 Hz tone, a sweep up to 5 kHz, then a silent last quarter — so what the
  // strip claims about frequency and about silence is checkable in pixels.
  ok(await page.evaluate(() => !!document.querySelector('#view .player .strip')),
    'strip: the audio scrubber is a strip, not a hairline');
  ok(await page.evaluate(() => !document.querySelector('#view .player .scrubber, #view .player .waveform')),
    'strip: no player row kept the old hairline or the bar waveform');

  // A voice note draws Telegram's own waveform bytes IMMEDIATELY — no decode,
  // no wait — and the spectrum fills in behind it.
  ok(await page.evaluate(() => {
    const rows = [...document.querySelectorAll('#view .post-player')].filter((p) => /Voice message/.test(p.innerText));
    return rows.length > 0 && rows.every((p) => {
      const s = p.querySelector('.strip');
      return s && s.hasEnvelope && s.dataset.fidelity !== 'hair';
    });
  }), 'strip: a voice note has its silhouette the moment the row appears, with no decode');

  // Analysis never runs for a row that has not been played or scrolled into
  // view: the count only moves when rows reach the observer.
  const startedBefore = await page.evaluate(() => window.__tgsocial.strip().started);
  const findFullStrip = () => page.evaluate(() => {
    for (const p of document.querySelectorAll('#view .post-player')) {
      const s = p.querySelector('.strip');
      if (!/Bench loop/.test(p.innerText) || s?.dataset.fidelity !== 'full') continue;
      for (const old of document.querySelectorAll('[data-test-strip]')) old.removeAttribute('data-test-strip');
      p.setAttribute('data-test-strip', '1');
      return true;
    }
    return false;
  });
  for (let i = 0; i < 16 && !(await findFullStrip()); i += 1) {
    await page.evaluate(() => window.scrollBy(0, window.innerHeight * 0.9));
    await page.waitForTimeout(350);
  }
  const painted = await findFullStrip();
  ok(painted, 'strip: the spectrum arrives and the strip paints at full fidelity');
  ok(await page.evaluate((n) => window.__tgsocial.strip().started > n, startedBefore),
    'strip: and it only started once the row was scrolled into view');

  if (painted) {
    // Read the texture back: it is a bitmap, so the assertions are pixels.
    // Image row 0 is the TOP of the strip and therefore the HIGHEST band —
    // frequency runs bottom (low) to top (high) on a log axis.
    const px = await page.evaluate(async () => {
      const el = document.querySelector('[data-test-strip] .strip');
      const img = el.querySelector('.strip-spectrum');
      await img.decode();
      const c = document.createElement('canvas');
      c.width = img.naturalWidth;
      c.height = img.naturalHeight;
      const ctx = c.getContext('2d');
      ctx.drawImage(img, 0, 0);
      const d = ctx.getImageData(0, 0, c.width, c.height).data;
      // The ramp's alpha saturates a third of the way up (transparent → line2 →
      // muted → …), so alpha alone cannot rank a bright pixel against a
      // brighter one. Premultiplied red IS monotone over the whole ramp —
      // 38·0 → 38·0.2 → 113 → 164 → 201 — so that is the intensity here.
      const lit = (x, y) => {
        const o = (y * c.width + x) * 4;
        return (d[o] * d[o + 3]) / 255;
      };
      const peakRow = (x) => {
        let best = 0;
        for (let y = 1; y < c.height; y += 1) if (lit(x, y) > lit(x, best)) best = y;
        return best;
      };
      const columnMax = (x) => {
        let m = 0;
        for (let y = 0; y < c.height; y += 1) m = Math.max(m, lit(x, y));
        return m;
      };
      const band = (from, to) => {
        let m = 0;
        for (let x = Math.round(c.width * from); x < Math.round(c.width * to); x += 1) m = Math.max(m, columnMax(x));
        return m;
      };
      const rowMax = (y) => {
        let m = 0;
        for (let x = 0; x < c.width; x += 1) m = Math.max(m, lit(x, y));
        return m;
      };
      const toneX = Math.round(c.width * 0.1);
      const box = el.getBoundingClientRect();
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      return {
        w: c.width,
        h: c.height,
        rows: [...Array(c.height).keys()].map(rowMax),
        paintedW: Math.round(box.width * dpr),
        paintedH: Math.round(box.height * dpr),
        toneRow: peakRow(toneX),
        toneAlpha: columnMax(toneX),
        sweepRow: peakRow(Math.round(c.width * 0.7)),
        tail: band(0.85, 0.98),
        clip: band(0.02, 0.7),
      };
    });
    const pixels = await page.evaluate(() => window.__tgsocial.strip());
    ok(px.w === pixels.cols && px.h === pixels.rows,
      `strip: one column per strip pixel, one row per pixel of its height (${px.w}×${px.h})`);
    ok(px.w <= px.paintedW && px.h <= px.paintedH,
      `strip: one column per pixel and NO MORE (${px.w}×${px.h} into ${px.paintedW}×${px.paintedH} device px)`);
    // Where the pure log axis says 180 Hz belongs, from the other side of the
    // app. §2.11.1's axis runs to the ANALYSIS Nyquist, and the analysis rate
    // now follows the clip's declared length (3:32 for this one), so this pins
    // both: the axis clamp and the rate the plan picked for it.
    const rate = analysisRate(212);
    const expectedRow = px.h - 1 - rowForFrequency(180, px.h, axisMaxHz(rate));
    ok(px.toneAlpha > 120 && px.toneRow > px.h / 2 && Math.abs(px.toneRow - expectedRow) <= 4,
      `strip: the 180 Hz tone lands in the LOWER rows, where the log axis puts it (row ${px.toneRow}, expected ${expectedRow} of ${px.h} at ${axisMaxHz(rate)} Hz)`);
    ok(px.sweepRow < px.toneRow,
      `strip: and the sweep climbs above it (row ${px.sweepRow} vs ${px.toneRow})`);
    // The axis ends at Nyquist rather than reserving rows above it, so the top
    // of the strip is REACHABLE: the 5 kHz sweep gets into its top eighth
    // instead of stopping a fifth of the way down a 20 kHz axis.
    ok(Math.max(0, ...px.rows.slice(0, Math.round(px.h / 8))) > 0,
      `strip: and the top of the strip carries data — no band reserved for what the decimation threw away`);
    ok(px.tail < 30 && px.clip > 150,
      `strip: the silent tail is dark (peak alpha ${px.tail}) while the clip is not (${px.clip})`);

    // Rule 6 on the ASSEMBLED card, not on the component: 40pt of region, all
    // of it actually reachable, and tiling with the play circle rather than
    // overlapping it.
    await page.evaluate(() => document.querySelector('[data-test-strip]').scrollIntoView({ block: 'center' }));
    await page.waitForTimeout(200);
    const hit = await page.evaluate(() => {
      const row = document.querySelector('[data-test-strip]');
      const s = row.querySelector('.strip');
      const btn = row.querySelector('.player-btn');
      const r = s.getBoundingClientRect();
      const b = btn.getBoundingClientRect();
      const probe = (x, y) => {
        const el = document.elementFromPoint(x, y);
        if (!el) return 'none';
        if (el.closest('.strip')) return 'strip';
        if (el.closest('.player-btn')) return 'btn';
        return el.className || el.tagName;
      };
      return {
        h: Math.round(r.height * 10) / 10,
        btn: Math.round(Math.min(b.width, b.height) * 10) / 10,
        overlaps: r.left < b.right && r.right > b.left && r.top < b.bottom && r.bottom > b.top,
        lands: [
          probe(r.left + r.width / 2, r.top + 1),
          probe(r.left + r.width / 2, r.top + r.height / 2),
          probe(r.left + r.width / 2, r.bottom - 1),
          probe(r.left + 1, r.top + r.height / 2),
          probe(r.right - 1, r.top + r.height / 2),
        ],
      };
    });
    ok(hit.h >= 40, `strip: the 40pt region is the strip's own drawn shape (${hit.h}pt tall)`);
    ok(hit.btn >= 40 && !hit.overlaps, 'strip: it tiles with the 40pt play circle instead of overlapping it');
    ok(hit.lands.every((x) => x === 'strip'), `strip: every point of the region reaches the strip (${hit.lands.join(', ')})`);

    // Tap anywhere on the strip to seek.
    // §2.11.2 rides on this play: the row's strip is analysed (fidelity `full`
    // above), so the dock must reuse THAT envelope rather than asking for one.
    const analysedBefore = await page.evaluate(() => {
      const s = window.__tgsocial.strip();
      return { started: s.started, records: s.records };
    });
    await page.locator('[data-test-strip] .player-btn').click();
    await page.waitForFunction(() => (window.__tgsocial.currentAudio()?.duration ?? 0) > 0, null, { timeout: 10000 });
    const box = await page.locator('[data-test-strip] .strip').boundingBox();
    await page.mouse.click(box.x + box.width * 0.75, box.y + box.height / 2);
    const seek = await page.evaluate(() => {
      const a = window.__tgsocial.currentAudio();
      return a && a.duration ? a.currentTime / a.duration : -1;
    });
    ok(Math.abs(seek - 0.75) < 0.06, `strip: clicking at 75% of the strip seeks to 75% of the clip (${seek.toFixed(3)})`);
    ok(await page.evaluate(() => Number(document.querySelector('[data-test-strip] .strip').getAttribute('aria-valuenow'))) === 75,
      'strip: and the slider reports it');

    // ── §2.11.2 the mini waveform in the now-playing dock ──────────────────
    //
    // "It is a view of the analysis the strip already did — the same envelope
    // array, resampled to the dock's width. Playing a clip must never trigger a
    // second analysis." That last sentence is a COUNT, so it is asserted as one:
    // the dock is up, the clip is playing, and js/strip.js started nothing and
    // keyed nothing new.
    await page.waitForSelector('#dock .now-playing .mini-wave', { timeout: 8000 });
    const shared = await page.evaluate((before) => {
      const s = window.__tgsocial.strip();
      const wave = document.querySelector('#dock .mini-wave');
      return {
        started: s.started - before.started,
        records: s.records - before.records,
        hasEnvelope: wave.hasEnvelope,
        columns: wave.columns,
      };
    }, analysedBefore);
    ok(shared.started === 0 && shared.records === 0,
      `dock: playing the clip started no second analysis (started +${shared.started}, records +${shared.records})`);
    ok(shared.hasEnvelope && shared.columns > 1,
      `dock: the mini waveform carries the strip's own envelope, resampled to ${shared.columns} columns`);

    // A LINE through the column peaks — not the strip's mirrored filled
    // silhouette and not the spectrum. Read back in pixels: every lit column is
    // a stroke a couple of pixels tall, never a filled slab, and nothing is
    // painted below the centre line the peaks rise from.
    const drawn = await page.evaluate(() => {
      const c = document.querySelector('#dock .mini-wave-line');
      const px = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
      const alpha = (x, y) => px[(y * c.width + x) * 4 + 3];
      const rgb = (x, y) => [0, 1, 2].map((k) => px[(y * c.width + x) * 4 + k]).join(',');
      let thickest = 0;
      let lit = 0;
      let belowMid = 0;
      let topmost = c.height;
      const mid = Math.floor(c.height / 2);
      for (let x = 0; x < c.width; x += 1) {
        let run = 0;
        for (let y = 0; y < c.height; y += 1) {
          if (alpha(x, y) <= 8) continue;
          run += 1;
          lit += 1;
          if (y > mid + 2) belowMid += 1;
          if (y < topmost) topmost = y;
        }
        thickest = Math.max(thickest, run);
      }
      const colourAt = (f) => {
        const x = Math.max(0, Math.min(c.width - 1, Math.round(f * (c.width - 1))));
        for (let y = 0; y < c.height; y += 1) if (alpha(x, y) > 120) return rgb(x, y);
        return null;
      };
      // The token is whatever the cascade holds (a hex, an rgb()); resolve it
      // the way the canvas did, by letting the browser compute it.
      const wave = document.querySelector('#dock .mini-wave');
      const style = getComputedStyle(wave);
      const probe = document.createElement('span');
      wave.append(probe);
      const named = (name) => {
        probe.style.color = style.getPropertyValue(name).trim();
        const m = /rgba?\(([^)]+)\)/.exec(getComputedStyle(probe).color);
        return m ? m[1].split(/[\s,\/]+/).slice(0, 3).join(',') : null;
      };
      const tokens = { played: named('--mini-wave-played'), ahead: named('--mini-wave-ahead') };
      probe.remove();
      return {
        h: c.height,
        lit,
        thickest,
        belowMid,
        rises: mid - topmost,
        behind: colourAt(0.2),
        ahead: colourAt(0.95),
        played: tokens.played,
        aheadToken: tokens.ahead,
      };
    });
    ok(drawn.lit > 0 && drawn.thickest <= Math.max(4, Math.round(drawn.h / 4)),
      `dock: one polyline, not a filled silhouette (thickest column ${drawn.thickest}px of ${drawn.h})`);
    ok(drawn.belowMid === 0 && drawn.rises > 1,
      `dock: no fill under the curve — the peaks rise off the centre line (${drawn.rises}px)`);
    // played behind the head, muted ahead of it — and the playhead is at 75%
    // because the seek above put it there
    ok(drawn.behind === drawn.played && drawn.ahead === drawn.aheadToken && drawn.played !== drawn.aheadToken,
      `dock: accent behind the playhead, muted ahead of it (${drawn.behind} vs ${drawn.ahead})`);

    // Rule 6 on the ASSEMBLED dock: it paints thinner than a target and takes
    // the 40 as an overlay that reaches past its own bounds — and tiles with
    // the play button beside it rather than swallowing its half.
    const dockHit = await page.evaluate(() => {
      const row = document.querySelector('#dock .now-playing');
      const wave = row.querySelector('.mini-wave');
      const btn = row.querySelector('.player-btn');
      const r = wave.getBoundingClientRect();
      const b = btn.getBoundingClientRect();
      const probe = (x, y) => {
        const el = document.elementFromPoint(x, y);
        if (!el) return 'none';
        if (el.closest('.mini-wave')) return 'wave';
        if (el.closest('.player-btn')) return 'btn';
        if (el.closest('.now-playing')) return 'row';
        return el.className || el.tagName;
      };
      const min = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--space-touch-min'));
      const cx = r.left + r.width / 2;
      const cy = r.top + r.height / 2;
      return {
        min,
        painted: Math.round(r.height * 10) / 10,
        btn: Math.round(Math.min(b.width, b.height) * 10) / 10,
        overlaps: r.left < b.right && r.right > b.left,
        edges: [probe(cx, cy - min / 2 + 1), probe(cx, cy), probe(cx, cy + min / 2 - 1), probe(r.left + 1, cy), probe(r.right - 1, cy)],
        beyondBtn: probe(b.left + b.width / 2, b.top + b.height / 2),
        row: probe(row.getBoundingClientRect().left + 4, cy),
      };
    });
    ok(dockHit.painted < dockHit.min,
      `dock: the waveform paints thinner than a target (${dockHit.painted}pt of ${dockHit.min})`);
    ok(dockHit.edges.every((x) => x === 'wave'),
      `dock: and still takes a full ${dockHit.min}pt region past its painted bounds (${dockHit.edges.join(', ')})`);
    ok(!dockHit.overlaps && dockHit.btn >= dockHit.min && dockHit.beyondBtn === 'btn',
      'dock: it tiles with the 40pt play circle instead of swallowing it');
    ok(dockHit.row === 'row', 'dock: the rest of the row is the row — §2.11 opens the post from there');

    // Tapping it seeks, like the strip.
    const waveBox = await page.locator('#dock .mini-wave').boundingBox();
    await page.mouse.click(waveBox.x + waveBox.width * 0.4, waveBox.y + waveBox.height / 2);
    const dockSeek = await page.evaluate(() => {
      const a = window.__tgsocial.currentAudio();
      return a && a.duration ? a.currentTime / a.duration : -1;
    });
    ok(Math.abs(dockSeek - 0.4) < 0.06, `dock: tapping the waveform seeks (${dockSeek.toFixed(3)})`);

    // "A clip whose strip degraded to the hairline shows a flat line rather
    // than nothing": the no-envelope shape, drawn by the same code path.
    const flat = await page.evaluate(() => {
      const wave = document.querySelector('#dock .mini-wave');
      wave.setEnvelope(null);
      const c = wave.querySelector('canvas');
      const px = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
      const rows = new Set();
      let lit = 0;
      for (let x = 0; x < c.width; x += 1) {
        for (let y = 0; y < c.height; y += 1) {
          if (px[(y * c.width + x) * 4 + 3] > 8) {
            rows.add(y);
            lit += 1;
          }
        }
      }
      return { lit, spread: rows.size, width: c.width, mid: Math.floor(c.height / 2), rows: [...rows] };
    });
    ok(flat.lit >= flat.width && flat.spread <= 4 && flat.rows.every((y) => Math.abs(y - flat.mid) <= 2),
      `dock: a hairline clip draws a FLAT line down the middle, not nothing (${flat.spread} rows lit across ${flat.width} columns)`);
    await page.evaluate(() => window.__tgsocial.currentAudio()?.pause());

    // §2.11: "Tapping the row anywhere but its controls opens the post the
    // audio came from." The waveform and the play circle stopped their own
    // gestures above; this is what the rest of the row is for.
    const rowBox = await page.locator('#dock .now-playing').boundingBox();
    await page.mouse.click(rowBox.x + 6, rowBox.y + rowBox.height / 2);
    await page.waitForFunction(() => location.hash.startsWith('#/thread/'), null, { timeout: 8000 });
    ok(/Bench loop/.test(await page.evaluate(() => document.getElementById('view').innerText)),
      'dock: tapping the row opens the post the audio came from');
    await page.evaluate(() => { location.hash = '#/feed'; });
    await page.waitForSelector('#view article.post', { timeout: 15000 });
  }

  // §2.11.1: "a video note keeps its circular player and gets the strip as the
  // transport underneath it." The circle stays the picture; the strip under it
  // is the scrubber, and it replaces the hairline rather than sitting beside
  // it. It arrives WITH the player, which is the gate iOS runs as well
  // (InlineVideoView: `if mode.hasTransport, started`) — before the tap there
  // is no element for a scrubber to drive, and a control that seeks nothing is
  // a control that lies.
  const findNote = () => page.evaluate(() => {
    const el = document.querySelector('#view .post-video-note');
    if (!el) return null;
    el.scrollIntoView({ block: 'center' });
    return { strip: !!el.querySelector('.strip'), play: !!el.querySelector('.media-play'), circle: !!el.querySelector('.post-media.video-note') };
  });
  let note = await findNote();
  for (let i = 0; i < 24 && !note; i += 1) {
    await page.evaluate(() => window.scrollBy(0, window.innerHeight * 0.9));
    await page.waitForTimeout(250);
    note = await findNote();
  }
  ok(!!note, 'strip: the feed carries a video note');
  if (note) {
    ok(note.circle && note.play && !note.strip,
      'strip: an unplayed video note is the circle and a play glyph — no transport that would seek nothing');
    await page.waitForTimeout(200);
    await page.locator('#view .post-video-note .media-play').first().click();
    await page.waitForSelector('#view .post-video-note .strip', { timeout: 15000 });
    await page.waitForFunction(() => {
      const v = document.querySelector('#view .post-video-note video');
      return !!v && Number.isFinite(v.duration) && v.duration > 0;
    }, null, { timeout: 15000 });
    const noteBox = await page.locator('#view .post-video-note .strip').boundingBox();
    await page.mouse.click(noteBox.x + noteBox.width * 0.75, noteBox.y + noteBox.height / 2);
    const seeked = await page.evaluate(() => {
      const v = document.querySelector('#view .post-video-note video');
      return {
        f: v.duration ? v.currentTime / v.duration : -1,
        h: Math.round(document.querySelector('#view .post-video-note .strip').getBoundingClientRect().height * 10) / 10,
        hairline: !!document.querySelector('#view .post-video-note .scrubber, #view .post-video-note .waveform'),
      };
    });
    ok(Math.abs(seeked.f - 0.75) < 0.08,
      `strip: the strip IS the video note's transport — a click at 75% seeks the player to 75% (${seeked.f.toFixed(3)})`);
    ok(!seeked.hairline, 'strip: and it replaced the hairline scrubber rather than sitting beside it');
    ok(seeked.h >= 40, `strip: the video note's strip keeps rule 6's 40pt region (${seeked.h}pt tall)`);

    // The analyser reads the note's OWN container through its audio track (iOS
    // does the same with AVAudioFile), so this is a spectrum and not a degrade.
    const noteFidelity = await page.waitForFunction(() => {
      const el = document.querySelector('#view .post-video-note .strip');
      return el && el.dataset.fidelity !== 'hair' ? el.dataset.fidelity : false;
    }, null, { timeout: 20000 }).then((handle) => handle.jsonValue()).catch(() => null);
    ok(noteFidelity === 'full',
      `strip: and the note's own audio track paints the spectrum (data-fidelity="${noteFidelity}")`);

    // Hand the blob back before the eviction tests below: an inline player that
    // keeps a src no cache is pinning is the one thing on this screen that
    // cannot repaint after a revoke.
    await page.evaluate(() => {
      const v = document.querySelector('#view .post-video-note video');
      if (!v) return;
      v.pause();
      v.removeAttribute('src');
      v.load();
    });
  }

  // §2.11.1 degrades rather than blocking. The first audio file the mock serves
  // is not audio at all, so its decode fails; that row keeps a usable scrubber —
  // the hairline of §2.11 — instead of an empty box, and nothing is logged as an
  // error, because a clip the browser cannot decode is a fact about the clip.
  await page.waitForFunction(() => (window.__tgsocial.strip().states.failed ?? 0) >= 1, null, { timeout: 20000 }).catch(() => null);
  const degraded = await page.evaluate(() => {
    const st = window.__tgsocial.strip();
    const hairs = [...document.querySelectorAll('.strip[data-fidelity="hair"]')];
    return {
      failed: st.states.failed ?? 0,
      ready: st.states.ready ?? 0,
      worker: st.worker,
      lastMs: st.lastMs,
      hairSeekable: hairs.every((el) => {
        const track = el.querySelector('.strip-track');
        return !!track && getComputedStyle(track).display !== 'none';
      }),
    };
  });
  ok(degraded.failed >= 1 && degraded.ready >= 1,
    `strip: an undecodable clip degrades while the others still paint (${degraded.failed} failed, ${degraded.ready} ready)`);
  ok(degraded.hairSeekable, 'strip: a degraded strip keeps the §2.11 hairline, so the row is still seekable');
  ok(degraded.worker === true, "strip: the analysis ran in a Worker, off the feed's thread");
  console.log(`# strip: last analysis ${degraded.lastMs} ms`);

  // §2.11.1's OTHER degrade, and the one only a real engine can answer: past
  // the duration ceiling the spectrum is skipped but the clip is still decoded
  // coarsely for the silhouette, so a 12 minute DJ set is a `wave` and not the
  // §2.11 hairline. How coarsely is up to the browser — an OfflineAudioContext
  // may refuse a rate — so the reachable band is probed here rather than
  // assumed, and a runtime that cannot decode coarsely refuses instead of
  // allocating 115 MB for one row.
  const bands = await page.evaluate(async () => {
    const spectro = await import('/js/spectro.js');
    const strip = await import('/js/strip.js');
    const envelopeRate = strip.envelopeDecodeRate();
    const plan = (d) => spectro.analysisPlan(d, { envelopeRate }).mode;
    return {
      envelopeRate,
      budget: spectro.ENVELOPE_MAX_SAMPLES,
      short: plan(212),
      long: plan(12 * 60),
      huge: plan(2 * 3600),
      // the band must also be non-empty on a runtime whose OfflineAudioContext
      // floor is the spec's own 8 kHz — this engine reaches 3 kHz, so that case
      // is forced rather than probed (protocol.test.mjs pins the arithmetic)
      spec8k: spectro.analysisPlan(12 * 60, { envelopeRate: 8000 }).mode,
    };
  });
  ok(bands.short === 'spectrum' && bands.long === 'envelope' && bands.huge === 'none',
    `strip: three bands — spectrum under the ceiling, silhouette past it, nothing past the hard cap (at ${bands.envelopeRate} Hz)`);
  ok(bands.envelopeRate * 12 * 60 < bands.budget,
    `strip: and the silhouette's own decode stays inside its working-set ceiling (${bands.envelopeRate} Hz)`);
  ok(bands.spec8k === 'envelope',
    'strip: the silhouette band survives an engine that will not decode below 8 kHz');

  // …and the band is not just planned, it runs: the real modules, a real
  // decode, the real worker. A clip that DECLARES 12 minutes takes the
  // silhouette path whatever its bytes are, which is also how the mock's audio
  // declares 3:32 and serves six seconds.
  const longClip = await page.evaluate(async () => {
    const { ensureStrip } = await import('/js/strip.js');
    const { strip } = await import('/vendor/house-pour.js');
    const rate = 16000;
    const n = rate * 2;
    const buf = new ArrayBuffer(44 + n * 2);
    const view = new DataView(buf);
    const ascii = (o, s) => { for (let i = 0; i < s.length; i += 1) view.setUint8(o + i, s.charCodeAt(i)); };
    ascii(0, 'RIFF'); view.setUint32(4, 36 + n * 2, true); ascii(8, 'WAVEfmt ');
    view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
    view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    ascii(36, 'data'); view.setUint32(40, n * 2, true);
    for (let i = 0; i < n; i += 1) {
      const loud = i > n / 4 && i < n / 2 ? 1 : 0.05;
      view.setInt16(44 + i * 2, Math.round(0.6 * 32767 * loud * Math.sin((2 * Math.PI * 440 * i) / rate)), true);
    }
    const el = strip({}); // never appended: this is the record's shape, not a screen
    const app = { td: { putDerived: () => { throw new Error('a silhouette must never paint a texture'); }, derivedUrl: () => null } };
    const record = ensureStrip(app, { file: { uniqueId: 'flows-long-set' }, duration: 12 * 60 }, el, async () => buf);
    for (let i = 0; i < 120 && record.state === 'pending'; i += 1) await new Promise((r) => setTimeout(r, 50));
    const values = record.envelope ? [...record.envelope] : [];
    return {
      state: record.state,
      mode: record.mode,
      key: record.key,
      fidelity: el.dataset.fidelity,
      columns: values.length,
      peak: values.length ? Math.max(...values) : 0,
      head: values.length ? Math.max(...values.slice(0, values.length / 8)) : 1,
    };
  });
  ok(longClip.state === 'ready' && longClip.mode === 'envelope' && longClip.key === null,
    `strip: a 12 minute clip resolves to the silhouette alone, with no texture (${longClip.state}/${longClip.mode})`);
  ok(longClip.fidelity === 'wave',
    `strip: and the row paints the §2.11.1 silhouette, not the §2.11 hairline (data-fidelity="${longClip.fidelity}")`);
  ok(longClip.columns > 1 && longClip.peak > 0.99 && longClip.head < 0.3,
    `strip: the silhouette is the shape of the take — ${longClip.columns} columns, quiet head ${longClip.head.toFixed(2)}, peak ${longClip.peak.toFixed(2)}`);

  // A failure is a moment, not a property of the clip. A download that stalled
  // or was cancelled while the row was off-screen used to pin that clip to the
  // hairline for the life of the page: every later trigger — the play tap, the
  // memory-pressure rebind — hit the same dead record and returned it.
  const retries = await page.evaluate(async () => {
    const { ensureStrip } = await import('/js/strip.js');
    const { strip } = await import('/vendor/house-pour.js');
    const rate = 16000;
    const n = Math.round(rate * 0.5);
    const buf = new ArrayBuffer(44 + n * 2);
    const view = new DataView(buf);
    const ascii = (o, s) => { for (let i = 0; i < s.length; i += 1) view.setUint8(o + i, s.charCodeAt(i)); };
    ascii(0, 'RIFF'); view.setUint32(4, 36 + n * 2, true); ascii(8, 'WAVEfmt ');
    view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
    view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    ascii(36, 'data'); view.setUint32(40, n * 2, true);
    for (let i = 0; i < n; i += 1) view.setInt16(44 + i * 2, Math.round(0.6 * 32767 * Math.sin((2 * Math.PI * 440 * i) / rate)), true);

    const app = { td: { putDerived: () => ({ size: 1 }), derivedUrl: () => null } };
    const settle = async (record) => {
      for (let i = 0; i < 120 && record.state === 'pending'; i += 1) await new Promise((r) => setTimeout(r, 50));
      return record.state;
    };

    // 1. a cancelled download, then the row comes back into view
    let calls = 0;
    const flaky = async () => {
      calls += 1;
      if (calls === 1) {
        const e = new Error('Download cancelled.');
        e.cancelled = true; // js/td.js DownloadCancelled
        throw e;
      }
      return buf.slice(0);
    };
    const el = strip({});
    const meta = { file: { uniqueId: 'flows-stalled-clip' }, duration: 10 };
    const stalled = await settle(ensureStrip(app, meta, el, flaky));
    const recovered = await settle(ensureStrip(app, meta, el, flaky));

    // 2. a clip the browser genuinely cannot decode: a re-arm does NOT keep
    //    re-downloading it, but the play tap — somebody waiting on the row —
    //    does get another go
    let junkCalls = 0;
    const junk = async () => { junkCalls += 1; return new ArrayBuffer(64); };
    const bad = { file: { uniqueId: 'flows-undecodable-clip' }, duration: 10 };
    const el2 = strip({});
    await settle(ensureStrip(app, bad, el2, junk));
    const afterRearm = junkCalls;
    await settle(ensureStrip(app, bad, el2, junk));
    const afterQuietRearm = junkCalls;
    await settle(ensureStrip(app, bad, el2, junk, { retry: true }));
    return { stalled, recovered, calls, afterRearm, afterQuietRearm, afterTap: junkCalls };
  });
  ok(retries.stalled === 'failed' && retries.recovered === 'ready' && retries.calls === 2,
    `strip: a cancelled download is retried on the next trigger, not remembered forever (${retries.stalled} → ${retries.recovered})`);
  ok(retries.afterQuietRearm === retries.afterRearm && retries.afterTap === retries.afterRearm + 1,
    `strip: an undecodable clip is not re-downloaded on every scroll, but a tap still gets another go (${retries.afterRearm} → ${retries.afterQuietRearm} → ${retries.afterTap})`);

  // The strip's bytes go through the SAME budget as every picture, so a strip
  // is evictable and the Status sheet can see it — never held outside the
  // accounting (js/blobcache.js).
  ok(await page.evaluate(() => window.__tgsocial.media.stats().bytes > 0 && window.__tgsocial.media.stats().bytes <= window.__tgsocial.media.stats().maxBytes),
    'strip: its texture is charged to the media budget and the budget still holds');
  await snap('strip');
  await page.evaluate(() => window.scrollTo(0, 0));

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
  // The mock now serves real, playable audio (test/mock-tdweb.js — the
  // spectrogram strip has to have something to analyse), so a clip left running
  // would reach its own end partway through the dock assertions below and take
  // the now-playing row with it. Pausing keeps the row docked, which is the
  // state those assertions are about; the end is dispatched deliberately later.
  await page.evaluate(() => window.__tgsocial.currentAudio()?.pause());

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
    if (!el) return;
    Object.defineProperty(el, 'ended', { value: true, configurable: true });
    el.dispatchEvent(new Event('ended'));
  });
  await page.waitForFunction(() => !document.querySelector('#dock .now-playing'), null, { timeout: 5000 });
  ok(await page.evaluate(() => document.getElementById('app').style.getPropertyValue('--dock-extra') === '' && document.getElementById('dock').hidden),
    'audio end: --dock-extra removed and dock hidden with the tab bar');
  await page.click('#topbar-lead .btn');
  await waitText(/YOUR FEEDS/);
  await page.click('.tabs button:has-text("Feed")');
  await page.waitForSelector('#view .post-mosaic-tile', { timeout: 15000 });

  // §2.11.3: the newest post is the two-photo album, so its media is a MOSAIC
  // and the way into the carousel is a tile.
  await page.locator('#view .post-mosaic-tile').first().click();
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

  // ── §2.11.3 photos: mosaic, then carousel ────────────────────────────────
  //
  // "A post with more than one photo is a mosaic, not a stack — an album is one
  // thing, and reading it as one block is the point." The layouts are measured
  // as RECTANGLES against js/mosaic.js's own table, so the stylesheet's
  // grid-template-areas and the module the app builds from cannot drift apart.
  await page.evaluate(() => { location.hash = '#/feed/mosaic_demo'; });
  await page.waitForFunction(() => document.querySelectorAll('#view .post-mosaic').length >= 3, null, { timeout: 20000 });

  const measureMosaics = () => page.evaluate(() => [...document.querySelectorAll('#view .post-mosaic')].map((m) => {
    const box = m.getBoundingClientRect();
    const style = getComputedStyle(m);
    const card = m.closest('.card').getBoundingClientRect();
    return {
      count: Number(m.dataset.count),
      w: box.width,
      h: box.height,
      radius: style.borderTopLeftRadius,
      mediaRadius: getComputedStyle(document.documentElement).getPropertyValue('--radius-media').trim(),
      tileRadius: getComputedStyle(m.querySelector('.post-mosaic-tile')).borderTopLeftRadius,
      gap: parseFloat(style.rowGap) || 0,
      border: parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--border-width')) || 0,
      more: m.querySelector('.post-mosaic-more')?.textContent ?? null,
      insideCard: box.right <= card.right + 0.5 && box.left >= card.left - 0.5,
      tiles: [...m.querySelectorAll('.post-mosaic-tile')].map((t) => {
        const r = t.getBoundingClientRect();
        return { x: r.left - box.left, y: r.top - box.top, w: r.width, h: r.height, target: Math.min(r.width, r.height) };
      }),
    };
  }));
  const mosaics = await measureMosaics();

  // The expected rectangles come from MOSAIC_AREAS, not from this file: two
  // columns, one row per row of the table, and a tile spanning every cell its
  // letter occupies.
  const expectedTiles = (m) => {
    const areas = MOSAIC_AREAS[m.count];
    const rows = areas.length;
    const cellW = (m.w - m.gap) / 2;
    const cellH = (m.h - (rows - 1) * m.gap) / rows;
    return [...new Set(areas.flat())].map((letter) => {
      const cells = [];
      areas.forEach((row, r) => row.forEach((a, c) => { if (a === letter) cells.push({ r, c }); }));
      const r0 = Math.min(...cells.map((c) => c.r));
      const c0 = Math.min(...cells.map((c) => c.c));
      const spanR = Math.max(...cells.map((c) => c.r)) - r0 + 1;
      const spanC = Math.max(...cells.map((c) => c.c)) - c0 + 1;
      return {
        x: c0 * (cellW + m.gap),
        y: r0 * (cellH + m.gap),
        w: spanC * cellW + (spanC - 1) * m.gap,
        h: spanR * cellH + (spanR - 1) * m.gap,
      };
    });
  };
  const near = (a, b) => Math.abs(a - b) <= 1.5;
  const matches = (m) => {
    const want = expectedTiles(m);
    return m.tiles.length === want.length
      && m.tiles.every((t, i) => near(t.x, want[i].x) && near(t.y, want[i].y) && near(t.w, want[i].w) && near(t.h, want[i].h));
  };
  const byCount = Object.fromEntries(mosaics.map((m) => [m.count, m]));
  ok(byCount[3] && matches(byCount[3])
    && near(byCount[3].tiles[0].h, byCount[3].h)
    && near(byCount[3].tiles[1].h, byCount[3].tiles[2].h)
    && byCount[3].tiles[1].x > byCount[3].tiles[0].x,
    `mosaic: 3 photos are one tall leading tile with two stacked beside it (${byCount[3]?.tiles.map((t) => `${Math.round(t.w)}x${Math.round(t.h)}`).join(' ')})`);
  ok(byCount[4] && matches(byCount[4])
    && new Set(byCount[4].tiles.map((t) => Math.round(t.w))).size === 1
    && new Set(byCount[4].tiles.map((t) => Math.round(t.h))).size === 1,
    `mosaic: 4 photos are two by two, equal cells (${byCount[4]?.tiles.map((t) => `${Math.round(t.w)}x${Math.round(t.h)}`).join(' ')})`);
  // the six-photo album paints the same 2×2 with the rest counted on the fourth
  const six = mosaics.find((m) => m.more);
  ok(six && six.count === 4 && six.tiles.length === 4 && six.more === '+2' && matches(six),
    `mosaic: 5+ photos are the first four with a +N over the fourth (${six?.more})`);

  const shape = byCount[4];
  ok(shape.radius === shape.mediaRadius && shape.tileRadius === '0px',
    `mosaic: radius-media on the OUTER corners only (block ${shape.radius}, tile ${shape.tileRadius})`);
  ok(shape.gap === shape.border && shape.border > 0,
    `mosaic: hairline line gutters, so it reads as one object (${shape.gap}px gap at ${shape.border}px border)`);
  ok(mosaics.every((m) => m.insideCard), 'mosaic: the block never leaves its card');
  const ratios = await page.evaluate(() => {
    const root = getComputedStyle(document.documentElement);
    const min = parseFloat(root.getPropertyValue('--ratio-mosaic-min'));
    const max = parseFloat(root.getPropertyValue('--ratio-mosaic-max'));
    return [...document.querySelectorAll('#view .post-mosaic')].map((m) => {
      const r = m.getBoundingClientRect();
      return { r: r.width / r.height, min, max };
    });
  });
  ok(ratios.every((x) => x.r >= x.min - 0.02 && x.r <= x.max + 0.02),
    `mosaic: the block keeps a sane ratio rather than letting one photo set the height (${ratios.map((x) => x.r.toFixed(2)).join(', ')} in ${ratios[0].min}…${ratios[0].max})`);

  // Aspect-aware: the tiles COVER their cells rather than letterboxing them.
  ok(await page.evaluate(() => [...document.querySelectorAll('#view .post-mosaic-tile img')].every((i) => getComputedStyle(i).objectFit === 'cover')),
    'mosaic: tiles cover their cell');

  // Rule 6 on the assembled screen: a tile is far past a target on its own
  // drawn shape, and every point of it reaches the tile and not the card.
  await page.evaluate(() => document.querySelector('#view .post-mosaic[data-count="4"]').scrollIntoView({ block: 'center' }));
  await page.waitForTimeout(250);
  const tileHits = await page.evaluate(() => {
    const min = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--space-touch-min'));
    const probe = (x, y) => {
      const el = document.elementFromPoint(x, y);
      return el && el.closest('.post-mosaic-tile') ? 'tile' : (el?.className || 'none');
    };
    return [...document.querySelectorAll('#view .post-mosaic')].flatMap((m) => [...m.querySelectorAll('.post-mosaic-tile')].map((t) => {
      const r = t.getBoundingClientRect();
      if (r.top < 0 || r.bottom > window.innerHeight) return null;
      // the block's OUTER corners are clipped by radius-media, so the region is
      // probed along its edges rather than into a rounded corner
      return {
        min,
        size: Math.min(r.width, r.height),
        corners: [
          probe(r.left + r.width / 2, r.top + 2), probe(r.left + r.width / 2, r.bottom - 2),
          probe(r.left + 2, r.top + r.height / 2), probe(r.right - 2, r.top + r.height / 2),
          probe(r.left + r.width / 2, r.top + r.height / 2),
        ],
      };
    })).filter(Boolean);
  });
  ok(tileHits.length >= 3 && tileHits.every((t) => t.size >= t.min && t.corners.every((c) => c === 'tile')),
    `mosaic: every tile is a ${tileHits[0]?.min}pt region of its own drawn shape, corner to corner (${tileHits.length} measured)`);

  // Memory (§2.11.3 + the byte-budgeted cache): a tile is a THUMBNAIL. It is
  // requested at tile size, never at the size the carousel will want.
  await page.waitForFunction(() => [...document.querySelectorAll('#view .post-mosaic img')].filter((i) => i.src).length >= 8, null, { timeout: 20000 });
  const tileWidths = await page.evaluate(() => {
    const root = getComputedStyle(document.documentElement);
    const n = (name) => parseFloat(root.getPropertyValue(name));
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const block = Math.min(window.innerWidth, n('--space-column-max')) - 2 * n('--space-column-side') - 2 * n('--space-card-pad');
    const widths = [];
    for (const [key, e] of window.__tgsocial.app.td.media.entries) {
      // this channel's photos only (seeds 300-325 in test/mock-tdweb.js)
      if (/^ph3\d\d[mx]@\d+$/.test(key)) widths.push(e.width || Number(key.split('@')[1]));
    }
    return { widths, tile: Math.round((block / 2) * dpr), full: Math.round(window.innerWidth * dpr) };
  });
  ok(tileWidths.widths.length > 0 && tileWidths.widths.every((w) => w <= tileWidths.tile + 1),
    `mosaic: tiles are decoded at tile size, not full-screen (${[...new Set(tileWidths.widths)].join(', ')} px, tile ${tileWidths.tile}, screen ${tileWidths.full})`);

  // "Tapping any tile opens the carousel AT THAT TILE'S INDEX."
  console.log('# PROBE state', JSON.stringify(await page.evaluate(async () => {
    const t = document.querySelector('#view .post-mosaic-tile');
    const out = { stats: window.__tgsocial.media.stats(), tile: !!t };
    try {
      const r = await window.__tgsocial.app.td.imageUrl({ id: 8300, remote: { unique_id: 'ph300m' }, local: {} }, { width: 322 });
      out.direct = String(r).slice(0, 24);
    } catch (e) { out.err = String(e && e.message); }
    return out;
  }))); 
  await page.locator('#view .post-mosaic[data-count="4"] .post-mosaic-tile').nth(2).click();
  await page.waitForSelector('#viewer-root .viewer', { timeout: 8000 });
  ok(await page.evaluate(() => document.querySelector('.viewer-counter')?.textContent === '3 / 4'),
    'mosaic: tapping the third tile opens the carousel at the third item');
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('#viewer-root .viewer'), null, { timeout: 5000 });
  await page.locator('#view .post-mosaic[data-count="4"] .post-mosaic-tile').first().click();
  await page.waitForSelector('#viewer-root .viewer', { timeout: 8000 });
  ok(await page.evaluate(() => document.querySelector('.viewer-counter')?.textContent === '1 / 4'),
    'mosaic: and the first tile opens it at the first');
  ok(await page.evaluate(() => {
    const w = window.__tgsocial.app.td.media;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const want = Math.round(window.innerWidth * dpr);
    return [...w.entries].some(([k]) => /^ph3\d\d[mx]@(\d+)$/.test(k) && Number(RegExp.$1) >= want);
  }), 'mosaic: the carousel is the one that asks for the full-screen rendition');
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('#viewer-root .viewer'), null, { timeout: 5000 });
  await snap('mosaic');

  // "It reflows at the narrow end rather than overflowing."
  await page.setViewportSize({ width: 320, height: 720 });
  await page.waitForTimeout(400);
  const narrow = await measureMosaics();
  ok(narrow.length >= 3 && narrow.every((m) => m.insideCard) && narrow.every((m) => matches(m)),
    `mosaic: at 320px it reflows into the card rather than overflowing (${narrow.map((m) => `${Math.round(m.w)}x${Math.round(m.h)}`).join(' ')})`);
  ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1),
    'mosaic: and the page never scrolls sideways');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForTimeout(400);
  await page.click('.tabs button:has-text("Feed")');
  await page.waitForSelector('#view article.post', { timeout: 15000 });

  // The two-photo layout is the one that lives in the feed (the newest post),
  // measured on the card it actually ships on.
  await page.waitForSelector('#view .post-mosaic[data-count="2"]', { timeout: 15000 });
  const pair = (await measureMosaics()).find((m) => m.count === 2);
  ok(pair && matches(pair) && near(pair.tiles[0].w, pair.tiles[1].w) && near(pair.tiles[0].y, pair.tiles[1].y)
    && near(pair.tiles[0].h, pair.h) && pair.tiles[1].x > pair.tiles[0].x,
    `mosaic: 2 photos are two tiles side by side, equal width (${pair?.tiles.map((t) => `${Math.round(t.w)}x${Math.round(t.h)}`).join(' ')})`);

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
  // ── §2.12 the comment sheet, and §2.15's SAFETY block on it ──────────────
  await longPress(page.locator('#view .comment', { hasText: 'Nice one. The bass is huge.' }).first().locator('.post-body').first());
  const anaSheet = await modalText();
  ok(/COMMENT/.test(anaSheet) && /@tgs_ana_r/.test(anaSheet), 'comment sheet: the comment rows, naming the channel it lives in');
  ok(/SAFETY/.test(anaSheet) && /Report Comment/i.test(anaSheet) && /Block @tgs_ana/i.test(anaSheet),
    'comment sheet: Report Comment and Block the commenter');
  ok(!/Mute /i.test(anaSheet), 'comment sheet: no Mute — mute is about a channel’s posts, and a comment is not one (§2.17)');
  await snap('comment-sheet');
  await closeSheet();
  await longPress(page.locator('#view .comment', { hasText: 'From the web thread.' }).first().locator('.post-body').first());
  const mineSheet = await modalText();
  ok(!/Report Comment/i.test(mineSheet) && /Delete/i.test(mineSheet),
    'comment sheet: on your own comment, Delete stands in for Report Comment');
  // the control is @tgs_ana's sheet above, which does carry it (§2.16)
  ok(!/Block @/i.test(mineSheet), 'comment sheet: and no Block @<yourself> on it either');
  await closeSheet();

  await page.locator('#view .comment', { hasText: 'From the web thread.' }).first().locator('button:has-text("Delete")').click();
  await page.waitForSelector('#modal .modal-card', { timeout: 5000 });
  ok(/Delete this comment\?/.test(await page.evaluate(() => document.getElementById('modal').innerText)), 'delete: confirm copy');
  await page.click('#modal button.btn.danger');
  await waitText(/COMMENTS · 2/);
  ok(true, 'delete: my comment removed from my channel');

  // ── §2.12 the reply target is whatever you tapped ────────────────────────
  //
  // "Tapping any comment in the thread selects it as the reply target: it lifts
  // into a quoted line above the composer and the composer's placeholder
  // becomes `Reply to <name>.`" — and the written comment's first line is
  // `re: ` + THAT comment's own t.me link (PROTOCOL §6.2), not the post's.
  const myChannelHistory = () => page.evaluate(() => {
    const sg = Object.values(window.__mock.supergroups).find((x) => x.usernames?.editable_username === 'tgs_elijah_r');
    const chat = Object.values(window.__mock.chats).find((c) => c.type.supergroup_id === sg?.id);
    return (window.__mock.history[chat.id] ?? []).map((m) => m.content?.text?.text ?? '');
  });
  // Ana's comment CONTAINS Bob's reply, so the body has to be its own child,
  // not any descendant's — and tapping the child selects the child (§2.12).
  const anaComment = () => page.locator('#view .comment', { hasText: 'Nice one. The bass is huge.' }).first();
  const anaBody = () => anaComment().locator(':scope > .post-body');
  await anaBody().click();
  await page.waitForSelector('#view .comment[data-selected]', { timeout: 5000 });
  const picked = await page.evaluate(() => {
    const sel = document.querySelector('#view .comment[data-selected]');
    return {
      name: sel.querySelector('.post-title span').textContent,
      pressed: sel.getAttribute('aria-pressed'),
      quote: document.querySelector('#view .comment-quote-row .comment-quote')?.textContent ?? '',
      clear: !!document.querySelector('#view .comment-quote-clear'),
    };
  });
  ok(picked.name === 'Ana Iliovic' && picked.pressed === 'true' && /^re: Ana Iliovic/.test(picked.quote) && picked.clear,
    `thread: tapping a comment lifts it into a quoted line above the composer (${picked.quote})`);

  // Rule 6 on the ASSEMBLED thread: the comment's own drawn shape is far past a
  // target, the × beside the quote takes its 40 as an overlay, and the name
  // button inside the comment keeps its own region out of the row's.
  const threadHits = await page.evaluate(() => {
    const min = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--space-touch-min'));
    const probe = (x, y) => {
      const el = document.elementFromPoint(x, y);
      if (!el) return 'none';
      if (el.closest('.comment-quote-clear')) return 'clear';
      if (el.closest('.post-title')) return 'name';
      if (el.closest('.comment-meta')) return 'meta';
      if (el.closest('.comment')) return 'comment';
      return el.className || el.tagName;
    };
    const row = document.querySelector('#view .comment[data-selected]');
    const clear = document.querySelector('#view .comment-quote-clear');
    const name = row.querySelector('.post-title');
    const r = row.getBoundingClientRect();
    const c = clear.getBoundingClientRect();
    const n = name.getBoundingClientRect();
    const body = row.querySelector('.post-body').getBoundingClientRect();
    return {
      min,
      comment: Math.min(r.width, r.height),
      commentLands: probe(body.left + body.width / 2, body.top + body.height / 2),
      clearPainted: Math.round(Math.min(c.width, c.height) * 10) / 10,
      clearLands: [
        probe(c.left + c.width / 2, c.top + c.height / 2 - min / 2 + 1),
        probe(c.left + c.width / 2, c.top + c.height / 2 + min / 2 - 1),
        probe(c.left + c.width / 2, c.top + c.height / 2),
      ],
      nameLands: [probe(n.left + n.width / 2, n.top + n.height / 2), probe(n.left + n.width / 2, n.top - min / 2 + n.height / 2 + 1)],
    };
  });
  ok(threadHits.comment >= threadHits.min && threadHits.commentLands === 'comment',
    `thread: the comment's own drawn shape is its ${threadHits.min}pt region (${Math.round(threadHits.comment)}pt)`);
  ok(threadHits.clearLands.every((x) => x === 'clear'),
    `thread: the quote's × paints at ${threadHits.clearPainted}pt and takes its ${threadHits.min} past those bounds (${threadHits.clearLands.join(', ')})`);
  ok(threadHits.nameLands.every((x) => x === 'name'),
    'thread: and the name inside the comment keeps its own region out of the row\'s');

  await page.click('#view button.btn.primary:has-text("Comment")');
  await page.waitForSelector('#modal textarea', { timeout: 8000 });
  ok(await page.evaluate(() => document.querySelector('#modal textarea').placeholder) === 'Reply to Ana Iliovic.',
    'composer: the placeholder becomes `Reply to <name>.`');
  await page.fill('#modal textarea', 'Straight at Ana.');
  await page.click('#modal button.btn.primary:has-text("Post")');
  await waitText(/Straight at Ana\./);
  await page.waitForFunction(() => !/Posting…/.test(document.getElementById('view').innerText), null, { timeout: 10000 });
  const toComment = (await myChannelHistory())[0] ?? '';
  ok(toComment.split('\n')[0] === 're: https://t.me/tgs_ana_r/600',
    `thread: the reply points at the comment that was tapped (${toComment.split('\n')[0]})`);
  ok(await page.evaluate(() => [...document.querySelectorAll('#view .comment-children .comment')].some((k) => /Straight at Ana\./.test(k.innerText))),
    'thread: and it renders as a reply under it, which is the re: chain (§6.2)');

  // Tapping it again — or the quote's × — clears the target, and the reply goes
  // to the post instead.
  await anaBody().click();
  await page.waitForFunction(() => !document.querySelector('#view .comment[data-selected]'), null, { timeout: 5000 });
  ok(await page.evaluate(() => !document.querySelector('#view .comment-quote-row')),
    'thread: tapping the selected comment again clears the target');
  await page.click('#view button.btn.primary:has-text("Comment")');
  await page.waitForSelector('#modal textarea', { timeout: 8000 });
  ok(await page.evaluate(() => document.querySelector('#modal textarea').placeholder) === 'Say it.',
    'composer: and the placeholder goes back to `Say it.`');
  await page.fill('#modal textarea', 'Straight at the post.');
  await page.click('#modal button.btn.primary:has-text("Post")');
  await waitText(/Straight at the post\./);
  await page.waitForFunction(() => !/Posting…/.test(document.getElementById('view').innerText), null, { timeout: 10000 });
  const toPost = (await myChannelHistory())[0] ?? '';
  ok(/^re: https:\/\/t\.me\/waveloop_devlog\/\d+$/.test(toPost.split('\n')[0]),
    `thread: with no target the reply points at the post (${toPost.split('\n')[0]})`);

  // The × is the other way out of a selection.
  await anaBody().click();
  await page.waitForSelector('#view .comment-quote-clear', { timeout: 5000 });
  await page.click('#view .comment-quote-clear');
  ok(await page.evaluate(() => !document.querySelector('#view .comment[data-selected]') && !document.querySelector('#view .comment-quote-row')),
    'thread: the quote\'s × clears it too');
  await snap('thread-reply-target');

  // ── §2.12 comments inside the carousel ───────────────────────────────────
  //
  // "Opening it does not leave the media: the media shrinks to a mini view
  // pinned at the top — the current item, still tappable to restore it
  // full-screen — and the thread takes the rest of the sheet."
  await page.click('#topbar-lead .btn');
  await page.waitForFunction(() => location.hash === '#/feed' || location.hash === '', null, { timeout: 8000 });
  await page.waitForSelector('#view .post-mosaic[data-count="2"] .post-mosaic-tile', { timeout: 15000 });
  await page.locator('#view .post-mosaic[data-count="2"] .post-mosaic-tile').first().click();
  await page.waitForSelector('#viewer-root .viewer', { timeout: 8000 });
  const stageBefore = await page.evaluate(() => document.querySelector('.viewer-stage').getBoundingClientRect().height);
  await page.click('.viewer-actions button:has-text("Comments")');
  await page.waitForSelector('#viewer-root .viewer.comments-open .comments', { timeout: 8000 });
  const opened = await page.evaluate(() => {
    const stage = document.querySelector('.viewer-stage').getBoundingClientRect();
    const mini = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--space-viewer-mini-height'));
    const comments = document.querySelector('.viewer-comments').getBoundingClientRect();
    return {
      stage: Math.round(stage.height),
      mini,
      stillMedia: !!document.querySelector('.viewer-slide img'),
      commentsBelow: comments.top >= stage.bottom - 0.5,
      commentsTall: comments.height > stage.height,
      counter: document.querySelector('.viewer-counter')?.textContent,
      restore: !!document.querySelector('.viewer-restore:not([hidden])'),
    };
  });
  ok(opened.stage === opened.mini && stageBefore > opened.stage && opened.stillMedia,
    `carousel: the media shrinks to a ${opened.mini}pt mini view rather than leaving it (${stageBefore} → ${opened.stage})`);
  ok(opened.commentsBelow && opened.commentsTall, 'carousel: and the thread takes the rest of the sheet');
  // item 1 of the album is its own message, and nobody has commented on it
  ok(opened.counter === '1 / 2' && /No comments from your network yet\./.test(await page.evaluate(() => document.querySelector('.viewer-comments').innerText)),
    'carousel: the thread targets the item on screen, not the album');
  await snap('carousel-comments');

  // "Paging the carousel while comments are open moves the mini view and
  // re-targets the thread to that item's post." The second item IS the post the
  // comments were left on, so the count moves with the page.
  await page.keyboard.press('ArrowRight');
  await page.waitForFunction(() => /Nice one\. The bass is huge\./.test(document.querySelector('.viewer-comments')?.innerText ?? ''), null, { timeout: 8000 });
  ok(await page.evaluate(() => document.querySelector('.viewer-counter')?.textContent === '2 / 2'),
    'carousel: paging moves the mini view and re-targets the thread to that item');

  // The same paging by the gesture it is actually done with. A swipe starts and
  // ends on the mini view's transparent restore overlay, so the browser fires a
  // `click` on it once the drag finishes — which must not be read as the tap
  // that restores full-screen. Arrow keys never produce that click, so only a
  // real drag covers it.
  const swipeStage = async (dx) => {
    const box = await page.locator('.viewer-stage').boundingBox();
    const y = box.y + box.height / 2;
    const x = box.x + box.width / 2 - dx / 2;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x + dx, y, { steps: 12 });
    await page.mouse.up();
  };
  await swipeStage(150); // → the previous item
  await page.waitForFunction(() => document.querySelector('.viewer-counter')?.textContent === '1 / 2', null, { timeout: 8000 });
  ok(await page.evaluate(() => !!document.querySelector('#viewer-root .viewer.comments-open')
    && /No comments from your network yet\./.test(document.querySelector('.viewer-comments')?.innerText ?? '')),
    'carousel: swiping back pages the mini view and keeps the thread open');
  await swipeStage(-150); // → the next item
  await page.waitForFunction(() => document.querySelector('.viewer-counter')?.textContent === '2 / 2', null, { timeout: 8000 });
  ok(await page.evaluate(() => !!document.querySelector('#viewer-root .viewer.comments-open')
    && /Nice one\. The bass is huge\./.test(document.querySelector('.viewer-comments')?.innerText ?? '')),
    'carousel: and swiping forward re-targets the thread without dismissing it');

  // The same selection behaviour, hosted over the media.
  await page.locator('.viewer-comments .comment', { hasText: 'Nice one. The bass is huge.' }).first().locator(':scope > .post-body').click();
  await page.waitForSelector('.viewer-comments .comment[data-selected]', { timeout: 5000 });
  ok(await page.evaluate(() => /^re: Ana Iliovic/.test(document.querySelector('.viewer-comments .comment-quote')?.textContent ?? '')),
    'carousel: tapping a comment selects it there too — one thread rendering, two hosts');

  // The mini view is tappable to restore it full-screen.
  await page.click('.viewer-restore');
  await page.waitForFunction(() => !document.querySelector('#viewer-root .viewer.comments-open'), null, { timeout: 5000 });
  ok(await page.evaluate(() => {
    const stage = document.querySelector('.viewer-stage').getBoundingClientRect();
    return !!document.querySelector('#viewer-root .viewer') && stage.height > parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--space-viewer-mini-height'));
  }), 'carousel: tapping the mini view restores it full-screen');
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('#viewer-root .viewer'), null, { timeout: 5000 });
  await page.waitForSelector('#view article.post', { timeout: 15000 });
  // the carousel above was opened from the feed, so this is already the feed
  await page.waitForFunction(() => location.hash === '#/feed' || location.hash === '', null, { timeout: 8000 });
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
  // `put` never evicts the entry it has just stored: "a blob bigger than the
  // whole budget still has to be reachable by the caller that just asked for
  // it — it is never its own eviction victim, and the next insert takes it
  // out" (js/blobcache.js). Against a 1.2 KB budget EVERY entry is bigger than
  // the budget, so whether the walk happens to end inside it is decided by
  // whether the last thing to finish was a 185-byte thumbnail or a 154 KB strip
  // texture — a race, not a property. What the cache actually promises is that
  // everything it is ALLOWED to evict is inside the bound, so that is what is
  // asserted; the entry count is unconditional either way.
  const bounded = await page.evaluate(() => {
    const m = window.__tgsocial.app.td.media;
    const newest = [...m.entries.keys()].pop() ?? null;
    let bytes = 0;
    for (const [k, e] of m.entries) if (k !== newest || e.bytes <= m.maxBytes) bytes += e.bytes;
    return { evictable: bytes, exempt: m.entries.size ? [...m.entries.values()].pop().bytes : 0 };
  });
  ok(twoWalks.entries <= 6 && bounded.evictable <= 1200,
    `media: scrolling a long feed stays inside the bound (${twoWalks.entries} files, ${bounded.evictable} B of 1200 evictable, ${bounded.exempt} B newest)`);
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

  // ── §2.18 the filter reaches the Thread screen ───────────────────────────
  //
  // §2.15 says the reported thing "vanishes from every surface" and §2.18
  // names Thread in the list of screens that drop it. Reporting is reachable
  // from the post card at the top of this screen, so the toast that says it is
  // gone and the post still being painted under it cannot both be true. §2.16
  // forbids a tombstone in its place, so what is asserted is that the screen
  // itself goes — and that the same URL, entered again from scratch with no
  // seed, does not bring it back.
  await page.goto(`${base}/?mock=node#/feed`, { waitUntil: 'load' });
  await page.waitForSelector('#view article.post .post-body', { timeout: 20000 });
  // the mail composer is the browser's; capture the mailto instead of handing
  // it to a handler this headless Chromium does not have
  await page.evaluate(() => {
    const orig = HTMLAnchorElement.prototype.click;
    window.__mailto = null;
    window.__restoreClick = () => { HTMLAnchorElement.prototype.click = orig; };
    HTMLAnchorElement.prototype.click = function click(...args) {
      if (String(this.href).startsWith('mailto:')) {
        window.__mailto = this.href;
        return undefined;
      }
      return orig.apply(this, args);
    };
  });
  await (await cardOf()).locator('.post-comments-count').click();
  await page.waitForFunction(() => location.hash.startsWith('#/thread/'), null, { timeout: 10000 });
  const threadRoute = await page.evaluate(() => location.hash);
  // the comment panel lands after the post card; press once the screen is whole
  await waitText(/COMMENTS/, 20000);
  await page.waitForTimeout(400);
  const threadPostText = (await page.locator('#view article.post .post-body').first().innerText()).slice(0, 30);
  await longPressText(page.locator('#view article.post .post-body').first());
  await page.click('#modal button.btn.danger:has-text("Report Post")');
  await page.waitForSelector('#modal .reason-list', { timeout: 5000 });
  await page.click('#modal .reason-row:has-text("Spam")');
  await page.click('#modal button.btn.danger:has-text("Send Report")');
  await waitToast(/Reported\. It's hidden here now\./);
  await page.waitForFunction(() => !location.hash.startsWith('#/thread/'), null, { timeout: 15000 });
  ok(true, 'thread: reporting the post leaves the screen that was about it — no tombstone (§2.15, §2.16)');
  await page.waitForFunction((t) => !document.getElementById('view').innerText.includes(t), threadPostText, { timeout: 15000 });
  ok(true, 'thread: and the post is not painted where it lands either');
  // and again with nothing in hand: the route alone decides, before any fetch
  await page.evaluate((hash) => { location.hash = hash; }, threadRoute);
  await page.waitForFunction((hash) => location.hash !== hash, threadRoute, { timeout: 10000 });
  ok(!(await text()).includes(threadPostText),
    'thread: re-entering the hidden thread from scratch never paints it');
  // the control: lift the hide and the same URL is an ordinary thread again,
  // so the two assertions above are about the filter and not about the route
  await page.evaluate(() => {
    const s = window.__tgsocial.safety;
    for (const h of [...s.hidden]) s.unhide(h.key);
  });
  await page.evaluate((hash) => { location.hash = hash; }, threadRoute);
  await page.waitForFunction((t) => document.getElementById('view').innerText.includes(t), threadPostText, { timeout: 20000 });
  ok((await page.evaluate(() => location.hash)) === threadRoute, 'thread: unhidden, the same thread opens and paints');

  // §2.16 on the same screen: a blocked node's post is dropped on Thread too.
  // Thread is not the profile the exception is about, so there is nothing here
  // for a blocked node to be either.
  await page.goto(`${base}/?mock=node#/feed`, { waitUntil: 'load' });
  await page.waitForSelector('#view article.post .post-body', { timeout: 20000 });
  await (await cardOf('Ana Iliovic')).locator('.post-comments-count').click();
  await page.waitForFunction(() => location.hash.startsWith('#/thread/'), null, { timeout: 10000 });
  await waitText(/COMMENTS/, 20000);
  await page.waitForTimeout(400);
  const anaThreadText = (await page.locator('#view article.post .post-body').first().innerText()).slice(0, 30);
  await longPressText(page.locator('#view article.post .post-body').first());
  await page.click('#modal button.btn.ghost:has-text("Block @tgs_ana")');
  await page.waitForSelector('#modal .modal-card', { timeout: 5000 });
  await page.click('#modal button.btn.danger:has-text("Block")');
  await waitToast(/Blocked @tgs_ana\./);
  await page.waitForFunction(() => !location.hash.startsWith('#/thread/'), null, { timeout: 15000 });
  ok(true, 'thread: blocking the node the post is attributed to takes the thread with it (§2.18)');
  await page.waitForFunction((t) => !document.getElementById('view').innerText.includes(t), anaThreadText, { timeout: 15000 });
  ok(true, 'thread: and their post is gone from where it lands');
  await page.evaluate(() => window.__tgsocial.safety.unblock('tgs_ana'));

  // ── §2.16 there is no Block @<yourself> ──────────────────────────────────
  //
  // The confirm is written about a second party — "Their posts and their
  // comments disappear… They are not told" — and blocking yourself empties
  // your own feed and your own DIRECT list to no end. Each assertion below has
  // its control on the same screen: the row is missing on my node and present
  // on somebody else's, so removing the feature outright fails this too.
  await page.goto(`${base}/?mock=node#/feed`, { waitUntil: 'load' });
  await page.waitForSelector('#view article.post .post-body', { timeout: 20000 });
  await longPressText((await cardOf('Elijah Lucian')).locator('.post-body').first());
  const ownPostSheet = await modalText();
  ok(/SAFETY/.test(ownPostSheet) && /Report Post/i.test(ownPostSheet) && /Mute /i.test(ownPostSheet),
    'post sheet: my own post keeps Report Post and Mute');
  ok(!/Block @/i.test(ownPostSheet), 'post sheet: and carries no Block @tgs_elijah — §2.16 is about someone else');
  await closeSheet();
  await longPressText((await cardOf('Ana Iliovic')).locator('.post-body').first());
  ok(/Block @tgs_ana/i.test(await modalText()), 'post sheet: the same sheet on a node that is not mine still carries Block');
  await closeSheet();
  await page.goto(`${base}/?mock=node#/node/tgs_elijah`, { waitUntil: 'load' });
  await waitText(/FEEDS/i, 20000);
  await page.click('#view .profile-head button.kebab');
  await page.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
  ok(await page.evaluate(() => [...document.querySelectorAll('.menu[role="menu"] button.list-item')].map((r) => r.textContent).join('|')
    === 'Open in Telegram|Copy Link'),
    'profile: my own §2.5 kebab is the two share actions and nothing else');
  await page.keyboard.press('Escape');
  await page.evaluate(() => {
    const s = window.__tgsocial.safety;
    for (const h of [...s.hidden]) s.unhide(h.key);
    for (const u of [...s.blocked]) s.unblock(u);
    window.__restoreClick?.();
  });

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
    // §2.15 works signed out against the same local lists; §2.16 needs a node,
    // and a channel page has none to attribute to (PRODUCT §2.3)
    ok(/SAFETY/.test(sheet) && /Report Post/i.test(sheet) && /Mute tastycrow/i.test(sheet) && !/Block @/i.test(sheet),
      'public: the sheet carries Report and Mute, and no Block where the post is unattributed');
    await pub.click('#modal .modal-card button.btn.ghost:has-text("Close")');
    await pub.waitForFunction(() => !document.querySelector('#modal .modal-card'), null, { timeout: 5000 });
    ok(await pub.evaluate(() => window.__tgsocial.safety.mutedFeeds.length === 0), 'public: and closing the sheet changed nothing');

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

    // Copy Link, on a deployment that set no `publicOrigin`: the page cannot
    // name itself from a config it was never given, so it shares the t.me link
    // rather than a URL only this host knows it answers on. This page was
    // reached as /u/tastycrow and resolved through the backlink, so the link
    // that names the person is @tgs_dankcoin's channel — the same chat the
    // menu's `Open in Telegram` opens, and not @tastycrow, which is one feed.
    await pub.click('#view .head-actions button.kebab');
    await pub.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
    await pub.locator('.menu[role="menu"] button.list-item:has-text("Copy Link")').click();
    await pub.waitForFunction(() => /Link copied\./.test(document.getElementById('toast').textContent), null, { timeout: 6000 });
    ok((await pub.evaluate(() => navigator.clipboard.readText())) === 'https://t.me/tgs_dankcoin',
      'public: Copy Link on a person page copies the resolved node\'s t.me link with no origin configured');

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
    // and the channel page shares the channel — a different string from the
    // person page above, which is the whole point: /u/ and /f/ are two screens
    ok((await pub.evaluate(() => navigator.clipboard.readText())) === 'https://t.me/tastycrow',
      'public: Copy Link on a channel page copies that channel\'s t.me link with no origin configured');

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

    // ── §2.15 reporting from a public route ────────────────────────────────
    //
    // "Reporting works signed out, on the public routes too; the hidden list
    // is the same list." The email is the only artifact this serverless
    // feature emits and the operator's only sortable record, so what matters
    // is that its `Message:` line names the message its `Link:` line names.
    // On this path the parser hands the app a bare server id already
    // (js/public/preview.js), so anything that shifts it a second time mails
    // `Message: 0` for every post under a million and the report is unusable.
    await pub.goto(`${base}/u/tastycrow`, { waitUntil: 'load' });
    await pub.waitForSelector('#view article.post', { timeout: 20000 });
    await pub.evaluate(() => {
      const orig = HTMLAnchorElement.prototype.click;
      window.__mailto = null;
      window.__restoreClick = () => { HTMLAnchorElement.prototype.click = orig; };
      HTMLAnchorElement.prototype.click = function click(...args) {
        if (String(this.href).startsWith('mailto:')) {
          window.__mailto = this.href;
          return undefined;
        }
        return orig.apply(this, args);
      };
    });
    const pubReported = (await pub.locator('#view article.post .post-body').first().innerText()).slice(0, 30);
    await pub.click('#view article.post .post-body >> nth=0', { button: 'right' });
    await pub.waitForSelector('#modal .modal-card', { timeout: 5000 });
    await pub.click('#modal button.btn.danger:has-text("Report Post")');
    await pub.waitForSelector('#modal .reason-list', { timeout: 5000 });
    await pub.click('#modal .reason-row:has-text("Spam")');
    await pub.click('#modal button.btn.danger:has-text("Send Report")');
    await pub.waitForFunction(() => /Reported\. It's hidden here now\./.test(document.getElementById('toast').textContent), null, { timeout: 6000 });
    const pubBody = new URL(await pub.evaluate(() => window.__mailto)).searchParams.get('body');
    const pubHidden = await pub.evaluate(() => window.__tgsocial.safety.hidden);
    const mailedId = /^Message: (\d+)$/m.exec(pubBody)?.[1];
    const linkedId = /^Link: https:\/\/t\.me\/[a-z_]+\/(\d+)$/m.exec(pubBody)?.[1];
    ok(!!mailedId && mailedId === linkedId,
      `public: a report sent from a public route names one message, not two (Link …/${linkedId}, Message: ${mailedId})`);
    ok(pubHidden.length === 1 && pubHidden[0].key === `tastycrow/${mailedId}`,
      `public: and the hidden entry written beside it carries the same id (${pubHidden[0]?.key})`);
    await pub.waitForFunction((t) => !document.getElementById('view').innerText.includes(t), pubReported, { timeout: 15000 });
    ok(true, 'public: the reported post stops painting on the public page too (§2.18)');
    await pub.evaluate(() => {
      const s = window.__tgsocial.safety;
      for (const h of [...s.hidden]) s.unhide(h.key);
      window.__restoreClick();
    });

    // ── §2.16 a blocked node on a public route ─────────────────────────────
    //
    // §2.16 names "a public URL (§2.13)" as one of the three deliberate ways
    // to reach a blocked node, and says why the exception exists: "An empty
    // screen there reads as a broken app, so it says so." /u/ is also where a
    // visitor can block — the sheet carries `Block @node` because /u/ posts
    // are attributed — and that visitor has no Settings to undo it in, so the
    // card is the only place the confirm's promise can be kept.
    await pub.goto(`${base}/u/tastycrow`, { waitUntil: 'load' });
    await pub.waitForSelector('#view article.post', { timeout: 20000 });
    await pub.click('#view article.post .post-body >> nth=0', { button: 'right' });
    await pub.waitForSelector('#modal .modal-card', { timeout: 5000 });
    ok(/Block @tgs_dankcoin/i.test(await pub.evaluate(() => document.getElementById('modal').innerText)),
      'public: /u/ attributes its posts, so the sheet offers Block @node (§2.13)');
    await pub.click('#modal button.btn.ghost:has-text("Block @tgs_dankcoin")');
    await pub.waitForSelector('#modal .modal-card', { timeout: 5000 });
    await pub.click('#modal button.btn.danger:has-text("Block")');
    await pub.waitForFunction(() => /Blocked @tgs_dankcoin\./.test(document.getElementById('toast').textContent), null, { timeout: 6000 });
    await pub.waitForFunction(() => /You blocked this node\./.test(document.getElementById('view').innerText), null, { timeout: 15000 });
    const blockedPerson = await pubText();
    ok(/@tgs_dankcoin/.test(blockedPerson) && /Nothing they post reaches you\./.test(blockedPerson) && /UNBLOCK/.test(blockedPerson),
      'public: /u/ of a blocked node is §2.16\'s card — not a head over an empty list');
    ok(await pub.evaluate(() => document.querySelectorAll('#view article.post').length === 0),
      'public: and none of their posts');
    // cold, on the same URL: the substitution is not just the repaint
    await pub.goto(`${base}/u/tastycrow`, { waitUntil: 'load' });
    await pub.waitForFunction(() => /You blocked this node\./.test(document.getElementById('view').innerText), null, { timeout: 20000 });
    ok(await pub.evaluate(() => document.querySelectorAll('#view article.post').length === 0),
      'public: still the card on a cold load of /u/<blocked>');
    await pub.goto(`${base}/n/tgs_dankcoin`, { waitUntil: 'load' });
    await pub.waitForFunction(() => /You blocked this node\./.test(document.getElementById('view').innerText), null, { timeout: 20000 });
    const blockedNodePage = await pubText();
    ok(!/FEEDS/i.test(blockedNodePage) && !/FOLLOWS/i.test(blockedNodePage) && !/tastycrow/.test(blockedNodePage),
      'public: /n/<blocked> is the same card, and carries none of their card');
    // the undo the confirm promised, reachable by the visitor who has no Settings
    await pub.click('#view button.btn:has-text("Unblock")');
    await pub.waitForFunction(() => /Unblocked @tgs_dankcoin\./.test(document.getElementById('toast').textContent), null, { timeout: 6000 });
    await pub.waitForFunction(() => /FEEDS/i.test(document.getElementById('view').innerText), null, { timeout: 20000 });
    ok(await pub.evaluate(() => window.__tgsocial.safety.blocked.length === 0),
      'public: Unblock is reachable with no Settings screen, and the card comes back');

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

  // ── §2.13 a deployment that configured an origin of its own ───────────────
  // Every assertion above reads the default: no `publicOrigin` in config.json,
  // so sharing is t.me. Someone who actually serves /u/ /f/ /n/ sets that one
  // key, and the same Copy Link becomes absolute to their host. That is the
  // whole difference, so it is asserted the same way — by answering
  // /config.json with it for this context alone.
  {
    const hostCtx = await browser.newContext({ viewport: { width: 390, height: 844 }, permissions: ['clipboard-read', 'clipboard-write'] });
    await hostCtx.route('**/config.json', (route) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      // the trailing slash is how a config file gets typed; it is not a second origin
      body: JSON.stringify({ apiId: 1, apiHash: 'flows', indexGroup: 'tgsocial_index', publicOrigin: 'https://tgs.example/' }),
    }));
    await hostCtx.route('**/vendor/tdweb/tdweb.js', (route) => route.fulfill({ status: 200, contentType: 'application/javascript', body: mock }));
    await hostCtx.route(/telesco\.pe|telegram-cdn\.org/, (route) => route.fulfill({ status: 200, contentType: 'image/png', body: PIXEL }));
    const host = await hostCtx.newPage();
    host.on('console', (m) => {
      if (m.type() === 'error') errors.push(`self-hosted: ${m.text()}`);
    });
    host.on('pageerror', (e) => errors.push(`self-hosted pageerror: ${e.message}`));
    await host.goto(`${base}/f/tastycrow`, { waitUntil: 'load' });
    await host.waitForSelector('#view article.post', { timeout: 20000 });
    await host.click('#view .head-actions button.kebab');
    await host.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
    await host.locator('.menu[role="menu"] button.list-item:has-text("Copy Link")').click();
    await host.waitForFunction(() => /Link copied\./.test(document.getElementById('toast').textContent), null, { timeout: 6000 });
    ok((await host.evaluate(() => navigator.clipboard.readText())) === 'https://tgs.example/f/tastycrow',
      'self-hosted: a configured publicOrigin makes Copy Link absolute to that host');
    // The person page keeps minting the handle the visitor arrived by, even
    // though it resolved through the backlink to @tgs_dankcoin: this host
    // serves /u/, so its own reader follows that backlink again (PUBLIC §4).
    // Only the t.me fallback has to name the node itself.
    await host.goto(`${base}/u/tastycrow`, { waitUntil: 'load' });
    await host.waitForSelector('#view article.post', { timeout: 20000 });
    await host.click('#view .head-actions button.kebab');
    await host.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
    await host.locator('.menu[role="menu"] button.list-item:has-text("Copy Link")').click();
    await host.waitForFunction(() => /Link copied\./.test(document.getElementById('toast').textContent), null, { timeout: 6000 });
    ok((await host.evaluate(() => navigator.clipboard.readText())) === 'https://tgs.example/u/tastycrow',
      'self-hosted: a person page still shares /u/<arrival handle>, which that host resolves again');
    await hostCtx.close();
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

    // §2.13 Sharing — the same link the public page copies, from the app
    await fresh.click('#view .head-actions button.kebab');
    await fresh.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
    await fresh.locator('.menu[role="menu"] button.list-item:has-text("Copy Link")').click();
    await fresh.waitForFunction(() => /Link copied\./.test(document.getElementById('toast').textContent), null, { timeout: 6000 });
    ok((await fresh.evaluate(() => navigator.clipboard.readText())) === 'https://t.me/waveloop_devlog',
      'signed in: Copy Link copies the t.me link with no origin configured');

    await newCtx.close();
  }


  // ── §2.22 the demo ────────────────────────────────────────────────────────
  // The last of the four App Store blockers: a reviewer has no phone number
  // and no code, so `Look Around First` on §2.1 step 1 is the rest of the app
  // on an invented network. Everything below is measured rather than assumed —
  // the counts a block changes, the rung a wrong rounding would land on, the
  // requests the page did NOT make, and the three refusals, each with its own
  // words (§2.22.3).
  {
    const demoCtx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, permissions: ['clipboard-read', 'clipboard-write'] });
    await demoCtx.route('**/vendor/tdweb/tdweb.js', (route) => route.fulfill({ status: 200, contentType: 'application/javascript', body: mock }));
    const d = await demoCtx.newPage();
    d.on('console', (m) => {
      if (m.type() === 'error') errors.push(`demo: ${m.text()}`);
    });
    d.on('pageerror', (e) => errors.push(`demo pageerror: ${e.message}`));
    /** Every request this tab makes from the moment the demo opens (§2.22.4). */
    let offsite = [];
    let watching = false;
    d.on('request', (r) => {
      if (!watching) return;
      const url = r.url();
      if (url.startsWith(base) || url.startsWith('data:') || url.startsWith('blob:')) return;
      offsite.push(url);
    });
    const dText = () => d.evaluate(() => document.getElementById('view').innerText);
    const dToast = (re, ms = 6000) => d.waitForFunction(
      ([src, flags]) => new RegExp(src, flags).test(document.getElementById('toast').textContent) && document.getElementById('toast').classList.contains('show'),
      [re.source, re.flags], { timeout: ms },
    );
    const dWait = (re, ms = 15000) => d.waitForFunction(
      ([src, flags]) => new RegExp(src, flags).test(document.getElementById('view').innerText), [re.source, re.flags], { timeout: ms },
    );
    const enter = async () => {
      await d.waitForSelector('#view button.btn.ghost:has-text("Look Around First")', { timeout: 20000 });
      await d.click('#view button.btn.ghost:has-text("Look Around First")');
      await d.waitForSelector('#view article.post', { timeout: 25000 });
    };

    await d.goto(`${base}/?mock=fresh`, { waitUntil: 'load' });
    await d.waitForSelector('input[type="tel"]', { timeout: 20000 });

    // §2.1 — the entry point, on step 1 only
    const entry = await d.evaluate(() => {
      const btn = [...document.querySelectorAll('#view .signin-demo button.btn')].find((b) => b.textContent === 'Look Around First');
      const card = document.querySelector('#view .card');
      return {
        label: btn?.textContent ?? null,
        ghost: !!btn?.classList.contains('ghost'),
        outsideCard: !!btn && !card.contains(btn),
        belowCard: !!btn && card.compareDocumentPosition(btn) === Node.DOCUMENT_POSITION_FOLLOWING,
        note: document.querySelector('#view .signin-demo p.muted')?.textContent ?? null,
        golds: [...document.querySelectorAll('#view button.btn.primary')].map((b) => b.textContent),
      };
    });
    ok(entry.label === 'Look Around First' && entry.note === 'Invented people, invented posts. Nothing is sent to Telegram.',
      '§2.1: the demo entry and its muted line, verbatim');
    ok(entry.ghost && entry.outsideCard && entry.belowCard && entry.golds.join() === 'Send Code',
      '§2.1: ghost, outside the card, below it — Send Code keeps the only fill on the screen');

    // step-1-only: once a number is in flight there is nothing to fall into
    await d.fill('input[type="tel"]', '+16045550199');
    await d.click('#view button.btn.primary');
    await d.waitForSelector('input[inputmode="numeric"]', { timeout: 10000 });
    ok(await d.evaluate(() => !document.querySelector('#view .signin-demo button')),
      '§2.1: the entry is gone on the code step — nobody mid-sign-in can fall into the demo');
    await d.goto(`${base}/?mock=fresh`, { waitUntil: 'load' });
    await d.waitForSelector('input[type="tel"]', { timeout: 20000 });

    watching = true;
    await enter();

    // §2.22.4 — TDLib is not merely unused, it is gone
    ok(await d.evaluate(() => window.__tgsocial.td.client === null && window.__tgsocial.app.repo.constructor.name === 'DemoRepo'),
      '§2.22.4: the TDLib handle is closed and the repo is a different object, not a mode');

    // §2.22 — the three persistent indicators
    const marks = await d.evaluate(() => ({
      pill: document.getElementById('status').textContent,
      gold: document.getElementById('status').classList.contains('gold'),
      strip: document.querySelector('#head .demo-strip')?.textContent ?? null,
      sticky: getComputedStyle(document.getElementById('head')).position,
      handles: [...document.querySelectorAll('#view .post-sub, #view .post-title')].map((e) => e.textContent),
    }));
    ok(marks.pill === 'Demo' && !marks.gold, '§2.22: the status pill reads Demo, in the neutral pill and never gold');
    ok(marks.strip === 'Demo. Everyone here is invented. Nothing leaves this device.' && marks.sticky === 'sticky',
      '§2.22: the strip is docked under the topbar and sticky with it');
    await snapPage(d, 'demo-feed');

    // §2.22.1 — the world, and the ladder a wrong rounding would fall off
    await d.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await dWait(/That's everything\./, 20000);
    const world = await d.evaluate(() => {
      const t = document.getElementById('view').innerText;
      return {
        posts: document.querySelectorAll('#view article.post').length,
        ages: [...t.matchAll(/\n(now|\d+[mhdw] ago|\d+mo ago|\d+y ago)\n/g)].map((m) => m[1]),
        counts: [...t.matchAll(/(\d+) comments?/g)].map((m) => Number(m[1])),
        demoHandles: [...document.querySelectorAll('#view article.post')].every((p) => /^Demo|^[A-Z]/.test(p.textContent)),
        stats: window.__tgsocial.demo.stats,
      };
    });
    ok(world.posts === 15, `§2.22.1: fifteen posts across six sources (${world.posts})`);
    ok(world.ages.join(' ') === 'now 6m ago 22m ago 2h ago 5h ago 9h ago 14h ago 1d ago 2d ago 3d ago 6d ago 2w ago 5w ago 4mo ago 2y ago',
      `§2.22.1: every rung of §2.3's ladder is on screen (${world.ages.join(' ')})`);
    ok(world.counts.filter((n) => n === 5).length === 1 && world.counts.filter((n) => n === 6).length === 1,
      '§2.22.1: the two threads carry five and six comments');

    // §2.22 item 3 — the fixtures name themselves, so a card cropped out of
    // context still says what it is
    const naming = await d.evaluate(() => {
      const w = window.__tgsocial.demo.world;
      return {
        nodes: Object.values(w.cards).map((c) => c.username),
        feeds: [...w.feeds.values()].map((f) => f.username),
        channels: [...new Set(w.comments.map((c) => c.channel))],
      };
    });
    ok(naming.nodes.length === 15 && naming.nodes.every((u) => u.startsWith('tgs_demo_')),
      `§2.22.1: fifteen nodes, every handle prefixed tgs_demo_ (${naming.nodes.length})`);
    ok(naming.feeds.every((u) => u.startsWith('demo_')) && naming.channels.every((u) => u.startsWith('demo_')),
      '§2.22: every channel — feeds and comments channels alike — begins demo_');

    // §2.22.1 — the media matrix, generated in-process and never bundled
    await d.evaluate(() => window.scrollTo(0, 0));
    await d.waitForSelector('#view .post-mosaic-tile.loaded', { timeout: 15000 });
    const media = await d.evaluate(() => ({
      mosaic: document.querySelectorAll('#view .post-mosaic .post-mosaic-tile').length,
      tags: [...document.querySelectorAll('#view .post-media-tag')].map((e) => e.textContent),
      players: [...document.querySelectorAll('#view .post-player .player-title, #view .post-player .player-total')].map((e) => e.textContent),
      doc: document.querySelector('#view .post-file-name')?.textContent ?? null,
      docMeta: document.querySelector('#view .post-file-meta')?.textContent ?? null,
      srcs: [...document.querySelectorAll('#view img')].map((i) => i.getAttribute('src')).filter(Boolean),
    }));
    ok(media.mosaic === 4, `§2.11.3: the four-photo album is one mosaic of four tiles (${media.mosaic})`);
    ok(media.tags.includes('0:18') && media.tags.includes('GIF'),
      `§2.22.1: the 0:18 video keeps its duration pill and the 2 s loop its GIF pill (${media.tags.join(', ')})`);
    ok(media.players.includes('3:42') && media.players.includes('0:47'),
      `§2.22.1: the 3:42 clip and the 0:47 voice note are player rows (${media.players.join(', ')})`);
    ok(media.doc === 'tide-table-1971.pdf' && /2\.4 MB/.test(media.docMeta ?? ''),
      `§2.22.1: the document row is the fixture's own name and size (${media.doc} · ${media.docMeta})`);
    ok(media.srcs.length >= 5 && media.srcs.every((u) => u.startsWith('data:')),
      `§2.22.1: every picture on the screen is generated in this page — a data: URI, never a fetch (${media.srcs.length} of them${media.srcs.filter((u) => !u.startsWith('data:')).slice(0, 2).join(', ')})`);

    // §2.22 item 2 — "it persists into the full-screen media viewers, the one
    // place the topbar hides", because an unmarked full-screen photo is exactly
    // the screenshot that could be mistaken for someone's real Telegram
    await d.locator('#view .post-mosaic-tile').first().click();
    await d.waitForSelector('.viewer', { timeout: 10000 });
    const inViewer = await d.evaluate(() => {
      const strip = document.querySelector('.demo-strip');
      const box = strip?.getBoundingClientRect();
      const viewer = document.querySelector('.viewer');
      return {
        topbar: !!document.querySelector('.topbar')?.getClientRects().length,
        text: strip?.textContent ?? null,
        painted: !!box && box.height > 0 && box.width > 0,
        above: !!strip && !!viewer && document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2) !== null,
      };
    });
    ok(!inViewer.topbar && inViewer.painted && inViewer.text === 'Demo. Everyone here is invented. Nothing leaves this device.',
      '§2.22: the topbar hides in the viewer and the strip stays, drawn over the dark surface');
    await snapPage(d, 'demo-viewer');
    await d.click('.viewer button.btn.ghost');
    await d.waitForFunction(() => !document.querySelector('.viewer'), null, { timeout: 5000 });

    // §2.22.5 — the demo sheet, in the status sheet's place
    await d.click('#status');
    await d.waitForSelector('#modal .modal-card[aria-label="Demo"]', { timeout: 5000 });
    const sheet = await d.evaluate(() => document.getElementById('modal').innerText.replace(/\n+/g, '\n'));
    ok(/DEMO\nYou're in the demo\./.test(sheet), '§2.22.5: the sheet is DEMO / You’re in the demo.');
    ok(/Nodes\n15\n/.test(sheet) && /Feeds\n6 sources · 15 posts\n/.test(sheet) && /Network\n4 direct · 7 at \+1\n/.test(sheet),
      `§2.22.5: the sheet's rows are the world it is describing (${sheet.replace(/\n/g, ' · ').slice(0, 200)})`);
    ok(/Telegram\nNot connected/.test(sheet),
      "§2.22.5: `Telegram · Not connected` — the row that answers the reviewer without them taking our word for it");
    await snapPage(d, 'demo-sheet');
    await d.click('#modal button.btn.ghost:has-text("Close")');
    await d.waitForFunction(() => !document.querySelector('#modal .modal-card'), null, { timeout: 5000 });

    // §2.22.3 — writes. Nothing is greyed out; every one answers.
    await d.evaluate(() => { location.hash = '#/explore'; });
    await dWait(/NEARBY/);
    await d.locator('#view .node-row:has-text("Arto Vansi") button.btn:has-text("Follow")').first().click();
    await dToast(/The demo doesn't write to Telegram\./);
    ok(await d.evaluate(() => !window.__tgsocial.app.repo.myCard.follows.includes('tgs_demo_arto')),
      "§2.22.3: Follow stays where it is, stays tappable, and answers `The demo doesn't write to Telegram.`");

    await d.evaluate(() => { location.hash = '#/you'; });
    await dWait(/YOUR FEEDS/);
    await d.click('#view button.btn.primary:has-text("Compose")');
    await d.waitForSelector('#modal textarea', { timeout: 5000 });
    await d.fill('#modal textarea', 'Can I post from the demo?');
    await d.click('#modal button.btn.primary:has-text("Post")');
    await dToast(/The demo doesn't write to Telegram\./);
    ok(true, '§2.22.3: Post answers with the same words');
    await d.click('#modal button.btn.ghost:has-text("Cancel")');
    await d.waitForFunction(() => !document.querySelector('#modal .modal-card'), null, { timeout: 5000 });

    // §2.22.3 — Share, Copy Link and Open in Telegram: one string between them,
    // because they are one truth — there is no message on Telegram to hand over
    await d.evaluate(() => { location.hash = '#/feed'; });
    await d.waitForSelector('#view article.post', { timeout: 20000 });
    await d.locator('#view article.post .btn:has-text("Share")').first().click();
    await dToast(/Nothing here is on Telegram\./);
    ok(true, '§2.22.3: Share answers `Nothing here is on Telegram.`');

    await d.evaluate(() => { location.hash = '#/node/tgs_demo_wren'; });
    await dWait(/Wren Alderiss/);
    await d.click('#view .head-actions button.kebab');
    await d.waitForSelector('.menu[role="menu"]', { timeout: 5000 });
    await d.locator('.menu[role="menu"] button.list-item:has-text("Copy Link")').click();
    await dToast(/Nothing here is on Telegram\./);
    ok((await d.evaluate(() => navigator.clipboard.readText())) !== 'https://t.me/tgs_demo_wren',
      '§2.22.3: Copy Link answers `Nothing here is on Telegram.` and copies nothing');

    // §2.22.3 — a link preview, which is a third
    await d.evaluate(() => { location.hash = '#/feed/demo_press_run'; });
    await dWait(/A Short History of the Em Dash/, 20000);
    await d.click('#view button.post-preview');
    await dToast(/Links don't open in the demo\./);
    ok(await d.evaluate(() => document.querySelectorAll('#view .post-preview-site')[0]?.textContent === 'example.com'),
      "§2.22.3: the link preview answers `Links don't open in the demo.` (and its host is example.com, RFC 2606)");

    // §2.22.2 — the filter, checkable by counting (§2.18)
    await d.evaluate(() => { location.hash = '#/thread/demo_tidewright/144'; });
    await dWait(/COMMENTS · 5/, 20000);
    const thread = await d.evaluate(() => ({
      plusOne: [...document.querySelectorAll('#view .comment')].some((c) => /Crate Mailer/.test(c.textContent) && !!c.querySelector('.pill')),
      crate: [...document.querySelectorAll('#view .comment')].some((c) => /FREE CRATES/.test(c.textContent)),
    }));
    ok(thread.crate && thread.plusOne,
      "§2.22.1: crate is reached at +1 through pell, so their comment is in scope and carries the `+1` pill");
    await snapPage(d, 'demo-thread');
    await d.evaluate(() => window.__tgsocial.safety.block('tgs_demo_crate'));
    await dWait(/COMMENTS · 4/, 10000);
    ok(true, '§2.22.2: blocking @tgs_demo_crate takes post 144 from 5 comments to 4');
    await d.evaluate(() => { location.hash = '#/graph'; });
    await dWait(/\+1 · 6/, 20000);
    ok(!/Crate Mailer/.test(await dText()), '§2.22.2: and Graph from `+1 · 7` to `+1 · 6`, with no row left behind');

    // §2.17/§2.18 — mute is the main feed only
    await d.evaluate(() => window.__tgsocial.safety.muteFeed('demo_slow_radio'));
    await d.evaluate(() => { location.hash = '#/feed'; });
    await d.waitForSelector('#view article.post', { timeout: 20000 });
    await d.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await dWait(/That's everything\./, 20000);
    const muted = await d.evaluate(() => document.querySelectorAll('#view article.post').length);
    ok(muted === 12, `§2.22.2: muting Slow Radio takes Feed from 15 posts to 12 (${muted})`);
    await d.evaluate(() => { location.hash = '#/feed/demo_slow_radio'; });
    await d.waitForSelector('#view article.post', { timeout: 20000 });
    const onChannel = await d.evaluate(() => document.querySelectorAll('#view article.post').length);
    ok(onChannel === 3, `§2.22.2: while @demo_slow_radio's own screen stays complete (${onChannel})`);
    await d.evaluate(() => { location.hash = '#/node/tgs_demo_mox'; });
    await dWait(/Mox Petrakis/, 20000);
    ok(await d.evaluate(() => [...document.querySelectorAll('#view .feed-row')].some((r) => /Slow Radio/.test(r.textContent) && !!r.querySelector('.pill.faint'))),
      "§2.22.2: and the feed row on Mox's profile gains the faint `Muted` pill");
    await d.evaluate(() => window.__tgsocial.safety.unmuteFeed('demo_slow_radio'));

    // §2.22.2 — report, with §2.15's one written-down deviation
    await d.evaluate(() => { location.hash = '#/thread/demo_kiln_log/219'; });
    await dWait(/Failure on the left\./, 20000);
    await d.evaluate(() => {
      const orig = HTMLAnchorElement.prototype.click;
      window.__mailto = null;
      HTMLAnchorElement.prototype.click = function click(...args) {
        if (String(this.href).startsWith('mailto:')) {
          window.__mailto = this.href;
          return undefined;
        }
        return orig.apply(this, args);
      };
    });
    await longPressTextOn(d, d.locator('#view article.post .post-body').first());
    await d.click('#modal button.btn.danger:has-text("Report Post")');
    await d.waitForSelector('#modal .reason-row', { timeout: 5000 });
    await d.click('#modal .reason-row:has-text("Spam")');
    await d.click('#modal button.btn.danger:has-text("Send Report")');
    await dToast(/Reported\. It's hidden here now\./);
    const demoBody = new URL(await d.evaluate(() => window.__mailto)).searchParams.get('body');
    ok(demoBody.startsWith('Demo: this report is from the demo and the link is invented.\nReason: Spam\n'),
      '§2.22.2: the demo report prepends one line, and §2.15 still adds nothing else');
    await d.evaluate(() => { location.hash = '#/settings'; });
    await dWait(/HIDDEN · 1/, 20000);
    ok(/(Kiln log|@demo_kiln_log) · 219/.test(await dText()), '§2.22.2: and it is listed in Settings → HIDDEN, by channel and message id');

    // §2.22.3 — Sign Out is not in the demo at all
    const settings = await d.evaluate(() => [...document.querySelectorAll('#view > div > button.btn')].map((b) => `${b.textContent}:${b.className}`));
    ok(!settings.some((b) => /^Sign Out/.test(b)) && /^Leave Demo:.*btn/.test(settings[settings.length - 2] ?? '') && /^Delete My Node:.*danger/.test(settings[settings.length - 1] ?? ''),
      `§2.22.3: Settings carries ( Leave Demo ) where Sign Out sits, above ( Delete My Node ) (${settings.join(' | ')})`);
    await snapPage(d, 'demo-settings');

    // §2.22.4 — the claim a reviewer's proxy can falsify
    ok(offsite.length === 0, `§2.22.4: the demo made no request to any origin but this page's own${offsite.length ? `: ${offsite.join(' | ')}` : ''}`);

    // §2.22 — leaving, and §2.22.5's "leaving persists nothing"
    await d.click('#status');
    await d.waitForSelector('#modal .modal-card[aria-label="Demo"]', { timeout: 5000 });
    await d.click('#modal button.btn.primary:has-text("Leave Demo")');
    await dToast(/Left the demo\./);
    await d.waitForSelector('input[type="tel"]', { timeout: 20000 });
    const left = await d.evaluate(() => ({
      phone: document.querySelector('input[type="tel"]').value,
      demo: window.__tgsocial.demo,
      pill: document.getElementById('status').textContent,
      strip: !!document.querySelector('.demo-strip'),
      keys: Object.keys(localStorage).filter((k) => k.startsWith('tgs.')),
      blocked: window.__tgsocial.safety.blocked,
    }));
    ok(left.phone === '' && left.demo === null && !left.strip && left.pill !== 'Demo',
      '§2.22: Leave Demo returns to §2.1 step 1 with the phone field empty, and the marks go with it');
    ok(left.keys.length === 0 && left.blocked.length === 0,
      `§2.22.5 / PROTOCOL §7.1: nothing was written to disk, and the demo's block of @tgs_demo_crate is not in the reader's list (${left.keys.join(',')})`);

    // §2.22.2 — the whole reason the demo is visible: 5.1.1(v) with no account
    await enter();
    await d.evaluate(() => { location.hash = '#/settings'; });
    await dWait(/DELETE MY NODE/, 20000);
    await d.click('#view button.btn.danger:has-text("Delete My Node")');
    await d.waitForSelector('#modal .modal-card[aria-label="Delete My Node"]', { timeout: 5000 });
    const modalCopy = await d.evaluate(() => document.getElementById('modal').innerText);
    ok(/@tgs_demo_you/.test(modalCopy) && /@tgs_demo_you_r/.test(modalCopy) && /This cannot be undone\./.test(modalCopy),
      '§2.21 in the demo: the modal names both channels and asks for the username');
    ok(await d.evaluate(() => document.querySelector('#modal button.btn.danger').disabled),
      '§2.21 in the demo: Delete My Node is armed only by typing the username');
    await d.fill('#modal input', '@tgs_demo_you');
    await d.click('#modal button.btn.danger:has-text("Delete My Node")');
    await dToast(/Your node is gone\. The demo is over\./);
    await d.waitForSelector('input[type="tel"]', { timeout: 20000 });
    ok(await d.evaluate(() => window.__tgsocial.demo === null && !document.querySelector('.demo-strip')),
      '§2.22.2: the demo runs §2.21 to the end and then ends, because a demo has no session to survive');

    await demoCtx.close();
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
