/* source.js — reading `t.me/s/<channel>` through our own origin (PUBLIC.md §1).
 *
 * `t.me` sends no `Access-Control-Allow-Origin`, so the browser cannot fetch it
 * directly: nginx proxies it at `/tg/s/` and caches it for 60 s
 * (web/nginx-public.conf). This module is the client for that one path and
 * nothing else — it builds only `/tg/s/<channel>` and `/tg/s/<channel>?before=<id>`,
 * because a path that is not a bare channel is refused upstream anyway.
 *
 * Nothing is stored. The only memory is a short in-tab cache with the same
 * lifetime as the proxy's, so a merged feed asking for the same channel twice
 * in one paint costs one request. A page is a lens, not an archive.
 */
import { normaliseUsername } from '../protocol.js';
import { parsePreview } from './preview.js';

/** Matches PUBLIC §1's `proxy_cache_valid 200 60s` — no point holding it longer than the proxy does. */
const TTL_MS = 60 * 1000;

function emptyResult(channel) {
  return {
    channel: { username: channel, title: `@${channel}`, photo: null, description: '', verifiedFor: null },
    posts: [],
    card: null,
    nextBefore: null,
    unavailable: true,
  };
}

export class PublicSource {
  constructor({ base = '/tg/s', fetchImpl = null, ttlMs = TTL_MS } = {}) {
    this.base = base;
    this.fetch = fetchImpl || ((...args) => fetch(...args));
    this.ttlMs = ttlMs;
    /** url → { at, promise } */
    this.cache = new Map();
  }

  /** `/tg/s/<channel>[?before=<id>]`, or null when the arguments are not that. */
  url(channel, before = null) {
    const name = normaliseUsername(channel);
    if (!name) return null;
    const n = Number(before);
    const query = Number.isInteger(n) && n > 0 ? `?before=${n}` : '';
    return `${this.base}/${name}${query}`;
  }

  /**
   * One parsed preview page. Never rejects: an unreachable proxy, a 404, or a
   * page that parses to nothing all come back `unavailable`, because a public
   * page has one honest failure mode and it is "this is not readable", not a
   * stack trace.
   */
  page(channel, before = null) {
    const url = this.url(channel, before);
    if (!url) return Promise.resolve(emptyResult(String(channel ?? '')));
    const hit = this.cache.get(url);
    if (hit && Date.now() - hit.at < this.ttlMs) return hit.promise;
    const name = normaliseUsername(channel);
    const promise = this.fetch(url, { credentials: 'omit', redirect: 'follow' })
      .then(async (res) => {
        if (!res.ok) return { ...emptyResult(name), status: res.status };
        return parsePreview(await res.text(), name);
      })
      .catch(() => emptyResult(name));
    this.cache.set(url, { at: Date.now(), promise });
    return promise;
  }

  /** The newest page of a channel — its header, its card, its posts. */
  channel(name) {
    return this.page(name, null);
  }
}
