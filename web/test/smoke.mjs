/* Smoke test — serves web/ with python3 -m http.server, drives headless
 * Chromium against it, and asserts:
 *   - the page loads with zero console errors and no failed requests
 *   - the wordmark renders in Kaushan Script (computed font-family)
 *   - config.json loaded (or the "Missing config.json." card renders when absent)
 *   - TdClient reaches authorizationStateWaitPhoneNumber within 60 s
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
