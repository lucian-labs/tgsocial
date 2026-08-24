#!/usr/bin/env node
/* dev-proxy.mjs — web/ over http, plus the `/tg/s/` proxy, for local runs.
 *
 *   node web/scripts/dev-proxy.mjs [--port 8080] [--fixtures web/test/fixtures]
 *
 * `python3 -m http.server` cannot proxy, and the public pages (PRODUCT §2.13)
 * need `/tg/s/<channel>` on our own origin because t.me sends no
 * `Access-Control-Allow-Origin`. This is that one route plus a static server,
 * in node built-ins only — no dependency, nothing to install.
 *
 * It is the development stand-in for web/nginx-public.conf and obeys the same
 * rules (PUBLIC.md §1): only `/s/`, only a bare channel with an optional
 * `?before=<id>`, the same User-Agent, a 60-second cache, one upstream fetch
 * per key. It is not a deploy artefact; production is nginx.
 *
 * `--fixtures <dir>` serves `<dir>/<channel>.html` instead of reaching
 * Telegram, which is how you work on the parser on a plane.
 */
import { createServer } from 'node:http';
import { request } from 'node:https';
import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, extname, join, normalize } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, '..');
const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const port = Number(arg('--port', 8080));
const fixtures = arg('--fixtures', null);

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

const UA = 'tgsocial/1.0 (+https://tgsocial.lucianlabs.ca)';
const TTL_MS = 60 * 1000;
/** key → { at, body, status } — nginx's `proxy_cache_valid 200 60s`, in a Map. */
const cache = new Map();
/** key → Promise — nginx's `proxy_cache_lock on`: one upstream fetch per key. */
const inflight = new Map();

/**
 * PUBLIC §1's response headers, the same set nginx sends (web/nginx-public.conf).
 * The body is Telegram's HTML — nine <script> tags in a real page — and the
 * parser reads it as a string, so it goes out as inert text rather than as a
 * document: opening `/tg/s/<channel>` in a tab must never run Telegram's
 * scripts on the origin that holds the TDLib session. Dev and prod agree here
 * on purpose; a rule that only one of them enforces is not a rule.
 */
const PREVIEW_HEADERS = {
  'content-type': 'text/plain; charset=utf-8',
  'x-content-type-options': 'nosniff',
  'content-security-policy': "sandbox; default-src 'none'",
  'access-control-allow-origin': '*',
  'cache-control': 'max-age=60',
};

/** PUBLIC §1: a bare channel, optionally `?before=<id>`, or nothing. */
function previewTarget(url) {
  const m = /^\/tg\/s\/([A-Za-z0-9_]{4,32})\/?$/.exec(url.pathname);
  if (!m) return null;
  // the whole query, not just `before` — nginx refuses anything else outright
  // (`if ($args !~ "^(before=[0-9]+)?$")`), and a rule only one of the two
  // enforces is not a rule
  if (!/^(\?before=[0-9]+)?$/.test(url.search)) return null;
  const before = url.searchParams.get('before');
  if (before !== null && !/^\d+$/.test(before)) return null;
  return { path: `/s/${m[1]}${before ? `?before=${before}` : ''}`, key: `${m[1]}|${before ?? ''}` };
}

function fetchPreview(path) {
  return new Promise((resolve) => {
    const req = request({ host: 't.me', path, method: 'GET', headers: { host: 't.me', 'user-agent': UA, accept: 'text/html' } }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode ?? 502, body: Buffer.concat(chunks) }));
    });
    req.on('error', () => resolve({ status: 502, body: Buffer.from('') }));
    req.setTimeout(15000, () => {
      req.destroy();
      resolve({ status: 504, body: Buffer.from('') });
    });
    req.end();
  });
}

async function preview(target) {
  if (fixtures) {
    const file = join(fixtures, `${target.key.split('|')[0]}.html`);
    return existsSync(file)
      ? { status: 200, body: readFileSync(file) }
      : { status: 404, body: Buffer.from('no fixture') };
  }
  const hit = cache.get(target.key);
  if (hit && Date.now() - hit.at < TTL_MS) return hit;
  if (inflight.has(target.key)) return inflight.get(target.key);
  const job = fetchPreview(target.path).then((res) => {
    if (res.status === 200) cache.set(target.key, { ...res, at: Date.now() });
    inflight.delete(target.key);
    return res;
  });
  inflight.set(target.key, job);
  return job;
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${port}`);
  const target = previewTarget(url);
  if (url.pathname.startsWith('/tg/')) {
    if (!target) {
      res.writeHead(404, { 'content-type': 'text/plain' });
      res.end('not found');
      return;
    }
    const { status, body } = await preview(target);
    res.writeHead(status, PREVIEW_HEADERS);
    res.end(body);
    return;
  }
  // static, with the deploy host's SPA fallback (`try_files $uri $uri/ /index.html`)
  let decoded;
  try {
    decoded = decodeURIComponent(url.pathname);
  } catch {
    decoded = url.pathname;
  }
  let rel = normalize(decoded);
  if (rel.endsWith('/')) rel = join(rel, 'index.html');
  let file = join(web, rel);
  if (!(file === web || file.startsWith(`${web}/`)) || !existsSync(file) || statSync(file).isDirectory()) {
    file = extname(rel) ? null : join(web, 'index.html');
  }
  if (!file) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
    return;
  }
  res.writeHead(200, { 'content-type': MIME[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
  createReadStream(file).pipe(res);
});

server.listen(port, '127.0.0.1', () => {
  console.log(`tgsocial dev server  http://127.0.0.1:${port}`);
  console.log(`  /tg/s/<channel>    ${fixtures ? `fixtures in ${fixtures}` : 'proxied to https://t.me/s/ (60 s cache)'}`);
});
