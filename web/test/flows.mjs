/* Flow test — every screen in PRODUCT.md §2 against the mock TDLib
 * (test/mock-tdweb.js, served in place of vendor/tdweb/tdweb.js by route
 * interception). No network. Not part of `npm test`; run on demand:
 *
 *   node test/flows.mjs [--shots <dir>]
 *
 * Asserts the copy on each screen, optimistic follow + rollback, FLOOD_WAIT
 * toast, compose → Posted., sign-out wipe, and zero console errors overall.
 */
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { existsSync, readdirSync, readFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
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

const port = await freePort();
const base = `http://127.0.0.1:${port}`;
const server = spawn('python3', ['-m', 'http.server', String(port), '--bind', '127.0.0.1'], { cwd: web, stdio: 'ignore' });
const mock = readFileSync(join(here, 'mock-tdweb.js'), 'utf8');
let shot = 0;

try {
  await waitFor(`${base}/index.html`, 10000);
  const pw = findPlaywright();
  if (!pw) throw new Error('playwright not found (run test/smoke.mjs once to install it)');
  const browser = await pw.chromium.launch({ headless: true, executablePath: findExecutable() || undefined });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await ctx.route('**/vendor/tdweb/tdweb.js', (route) => route.fulfill({ status: 200, contentType: 'application/javascript', body: mock }));
  const page = await ctx.newPage();
  globalThis.__page = page;
  const errors = [];
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text());
  });
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  const snap = async (name) => {
    if (!shotsDir) return;
    shot += 1;
    await page.screenshot({ path: join(shotsDir, `${String(shot).padStart(2, '0')}-${name}.png`), fullPage: true });
  };
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

  // feed channel
  await page.click('#view .feed-row:has-text("ana_notes")');
  await waitText(/@ana_notes/);
  await page.waitForSelector('#view article.post', { timeout: 10000 });
  const chText = await text();
  ok(/Ana's notes/.test(chText) && /Open in Telegram/i.test(chText) && /VERIFIED/.test(chText), 'channel: header with Verified + Open in Telegram');
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
  ok(/views/.test(feedText) && /❤ 14/.test(feedText), 'feed: views + reaction counts');
  ok(/Open in Telegram/i.test(feedText), 'feed: Open in Telegram');
  ok(await page.evaluate(() => !!document.querySelector('#view .post-body b') && !!document.querySelector('#view .post-body code') && !!document.querySelector('#view .post-body a')), 'feed: entities rendered as b/code/a');
  await page.waitForFunction(() => [...document.querySelectorAll('#view .post-media img')].some((i) => i.src.startsWith('blob:')), null, { timeout: 10000 });
  ok(true, 'feed: media loaded via readFile blob');
  ok(/release-notes-\d+\.pdf/.test(feedText), 'feed: document file name');
  ok(/Bench loop · 3:32/.test(feedText), 'feed: audio title + duration');
  ok(await page.evaluate(() => [...document.querySelectorAll('#view article.post')].every((a) => !/Pinned a message/.test(a.textContent))), 'feed: service messages skipped');
  await snap('feed');
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
  await page.waitForFunction((n) => document.querySelectorAll('#view article.post').length > n, posts2, { timeout: 15000 });
  ok(true, 'feed: load more on scroll');
  for (let i = 0; i < 10 && !/That's everything\./.test(await text()); i += 1) {
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await page.waitForTimeout(500);
  }
  ok(/That's everything\./.test(await text()), "feed: That's everything. at the end");
  const total = await page.locator('#view article.post').count();
  ok(total >= 40, `feed: ${total} posts after exhausting sources`);
  const linkOk = await page.evaluate(() => window.__tgsocial.repo.cachedFeed()[0].link);
  ok(/^https:\/\/t\.me\/[a-z_]+\/\d+$/.test(linkOk), `feed: deep link ${linkOk}`);
  await page.goto(`${base}/?mock=node&mockslow=1`, { waitUntil: 'load' });
  await page.waitForFunction(() => document.querySelectorAll('#view article.post').length > 0 && document.getElementById('status').textContent === 'Syncing', null, { timeout: 3000 });
  ok(true, 'cold start paints cached feed (pill Syncing) before TDLib is ready');
  await page.waitForFunction(() => document.getElementById('status').textContent === 'Synced', null, { timeout: 15000 });
  await page.waitForSelector('#view article.post', { timeout: 15000 });
  await page.waitForFunction(() => window.__tgsocial.td.isReady, null, { timeout: 15000 });
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
  server.kill();
}

if (failures.length) {
  console.log(`# flows: ${failures.length} failure(s)`);
  process.exit(1);
}
console.log('# flows: all checks passed');
