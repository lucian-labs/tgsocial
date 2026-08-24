// Unit tests for web/js/protocol.js against the shared vectors in docs/card-vectors.json.
//   node test/protocol.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import {
  parseCard,
  serialiseCard,
  isNewerCard,
  normaliseUsername,
  deepLink,
  hasBacklink,
  formatTime,
  formatExactTime,
  compactCount,
  attributionNode,
  entityRuns,
  createMerge,
  pushMessages,
  markExhausted,
  takeNext,
  refillCandidate,
  isExhausted,
  rankPlusOne,
  floodWaitSeconds,
  withBacklink,
  parseIndexLine,
  isPost,
  albumId,
  takeAlbumRest,
  groupAlbums,
  isNewestFirst,
  insertIndex,
  parseComment,
  serialiseComment,
  targetKey,
  parsePublicPath,
  publicFeedUrl,
  publicNodeUrl,
  trimFeedWindow,
} from '../js/protocol.js';
import { MediaCache, mediaBudgetBytes, renditionKey, costOf, MB } from '../js/blobcache.js';
import { readImageHeader } from '../js/decode.js';
import { Td } from '../js/td.js';

const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(await readFile(join(here, '..', '..', 'docs', 'card-vectors.json'), 'utf8'));

for (const c of vectors.parse) {
  test(`parse: ${c.name}`, () => {
    const got = parseCard(c.text);
    assert.deepEqual(got, c.expect);
    if (c.newerVersion) assert.equal(isNewerCard(c.text), true);
    else assert.equal(isNewerCard(c.text), false);
  });
}

for (const c of vectors.serialise) {
  test(`serialise: ${c.name}`, () => {
    assert.equal(serialiseCard(c.card), c.expect);
  });
}

for (const c of vectors.username.cases) {
  test(`username: ${JSON.stringify(c.in)}`, () => {
    assert.equal(normaliseUsername(c.in), c.out);
  });
}

for (const c of vectors.deepLink.cases) {
  test(`deepLink: ${c.username}/${c.messageId}`, () => {
    assert.equal(deepLink(c.username, c.messageId), c.out);
  });
}

// PRODUCT §2.13 public links: the pathnames nginx falls back to index.html for.
{
  const cases = [
    ['/f/waveloop_devlog', { name: 'channel', username: 'waveloop_devlog' }],
    ['/f/waveloop_devlog/', { name: 'channel', username: 'waveloop_devlog' }],
    ['/n/tgs_elijah', { name: 'node', username: 'tgs_elijah' }],
    ['/f/@waveloop_devlog', { name: 'channel', username: 'waveloop_devlog' }],
    ['/', null],
    ['/index.html', null],
    ['/privacy.html', null],
    ['/f/', null],
    ['/f/no', null],
    ['/f/bad-name', null],
    ['/f/a/b', null],
    ['/x/waveloop_devlog', null],
    ['', null],
    // a malformed percent-escape is a bad username, never a URIError: this is
    // parsed in boot() before there is a repo to render an error with
    ['/f/%zz', null],
    ['/f/%E0%A4%A', null],
    ['/n/%zz', null],
    ['/f/%2Fwaveloop_devlog', null],
    ['/f/%77aveloop_devlog', { name: 'channel', username: 'waveloop_devlog' }],
  ];
  for (const [path, out] of cases) {
    test(`publicPath: ${JSON.stringify(path)}`, () => {
      assert.deepEqual(parsePublicPath(path), out);
    });
  }
  test('publicFeedUrl / publicNodeUrl are absolute to the canonical host', () => {
    assert.equal(publicFeedUrl('waveloop_devlog'), 'https://tgsocial.lucianlabs.ca/f/waveloop_devlog');
    assert.equal(publicNodeUrl('tgs_elijah'), 'https://tgsocial.lucianlabs.ca/n/tgs_elijah');
  });
}

for (const c of vectors.backlink.cases) {
  test(`backlink: ${c.description}`, () => {
    assert.equal(hasBacklink(c.description, c.node), c.out);
  });
}

{
  const now = new Date('2026-08-23T14:30:00');
  for (const c of vectors.timeFormat.cases) {
    test(`timeFormat: ${c.date}`, () => {
      assert.equal(formatTime(new Date(c.date), now), c.out);
      assert.equal(formatExactTime(new Date(c.date)), c.exact);
    });
  }
}

// PRODUCT §2.3 attribution: me for my feeds; else the followed node whose
// card lists the source feed (earliest in my follows order when several);
// else null (the card falls back to the channel itself).
test('attribution: my feed → me; followed node\'s feed → that node; earliest follow wins', () => {
  const cards = {
    tgs_ana: { feeds: ['ana_notes', 'shared_feed'], follows: [] },
    tgs_bob: { feeds: ['bob_feed', 'Shared_Feed'], follows: [] },
  };
  const my = { feeds: ['waveloop_devlog'], follows: ['tgs_ana', 'tgs_bob'] };
  const cardFor = (u) => cards[u.toLowerCase()] ?? null;
  assert.equal(attributionNode('waveloop_devlog', 'tgs_me', my, cardFor), 'tgs_me');
  assert.equal(attributionNode('bob_feed', 'tgs_me', my, cardFor), 'tgs_bob');
  // two nodes list shared_feed — the earliest in my follows order wins (case-insensitive match)
  assert.equal(attributionNode('SHARED_FEED', 'tgs_me', my, cardFor), 'tgs_ana');
  assert.equal(attributionNode('unlisted_feed', 'tgs_me', my, cardFor), null);
  assert.equal(attributionNode('waveloop_devlog', 'tgs_me', null, cardFor), null);
});

for (const c of vectors.compactCount.cases) {
  test(`compactCount: ${c.in}`, () => {
    assert.equal(compactCount(c.in), c.out);
  });
}

for (const c of vectors.comment.parse) {
  test(`comment parse: ${JSON.stringify(c.in.split('\n')[0])}`, () => {
    assert.deepEqual(parseComment(c.in), c.out);
  });
}

for (const c of vectors.comment.serialise) {
  test(`comment serialise: ${c.target}`, () => {
    assert.equal(serialiseComment(c.target, c.body), c.out);
    assert.deepEqual(parseComment(serialiseComment(c.target, c.body)), { target: c.target, body: c.body });
  });
}

test('targetKey canonicalises t.me links (case-insensitive username)', () => {
  assert.equal(targetKey('https://t.me/Waveloop_Devlog/144'), 'waveloop_devlog/144');
  assert.equal(targetKey('https://t.me/tgs_ana_r/12/'), 'tgs_ana_r/12');
  assert.equal(targetKey('https://example.com/x/1'), null);
  assert.equal(targetKey('not a link'), null);
});

test('serialise round-trips every parse vector', () => {
  for (const c of vectors.parse) {
    if (!c.expect) continue;
    assert.deepEqual(parseCard(serialiseCard(c.expect)), c.expect);
  }
});

test('serialise refuses a card over 4096 chars', () => {
  const follows = Array.from({ length: 400 }, (_, i) => `tgs_user_${String(i).padStart(4, '0')}`);
  assert.throws(() => serialiseCard({ name: 'x', bio: null, link: null, public: true, feeds: [], follows }), /Card is full\./);
});

test('withBacklink appends once and respects 255', () => {
  assert.equal(withBacklink('Notes', 'tgs_e_lucian'), 'Notes\ntgsocial: @tgs_e_lucian');
  assert.equal(withBacklink('Notes\ntgsocial: @tgs_e_lucian', 'tgs_e_lucian'), 'Notes\ntgsocial: @tgs_e_lucian');
  const long = 'x'.repeat(250);
  const out = withBacklink(long, 'tgs_e_lucian');
  assert.ok(out.length <= 255);
  assert.ok(hasBacklink(out, 'tgs_e_lucian'));
});

test('index line parse', () => {
  assert.equal(parseIndexLine('node: @tgs_ana'), 'tgs_ana');
  assert.equal(parseIndexLine('hello\nnode: @tgs_bob'), 'tgs_bob');
  assert.equal(parseIndexLine('nothing'), null);
});

test('floodWaitSeconds', () => {
  assert.equal(floodWaitSeconds({ code: 429, message: 'Too Many Requests: retry after 17' }), 17);
  assert.equal(floodWaitSeconds({ code: 400, message: 'FLOOD_WAIT_42' }), 42);
  assert.equal(floodWaitSeconds({ code: 400, message: 'USERNAME_INVALID' }), null);
});

test('entityRuns splits and flags', () => {
  const runs = entityRuns('hi bold and link', [
    { offset: 3, length: 4, type: { '@type': 'textEntityTypeBold' } },
    { offset: 12, length: 4, type: { '@type': 'textEntityTypeTextUrl', url: 'https://example.com' } },
    { offset: 0, length: 2, type: { '@type': 'textEntityTypeSpoiler' } },
  ]);
  assert.deepEqual(runs, [
    { text: 'hi ' },
    { text: 'bold', bold: true },
    { text: ' and ' },
    { text: 'link', href: 'https://example.com' },
  ]);
  assert.deepEqual(entityRuns('plain', []), [{ text: 'plain' }]);
});

test('isPost filters service messages and cards', () => {
  assert.equal(isPost({ id: 1, content: { '@type': 'messagePinMessage' } }), false);
  assert.equal(isPost({ id: 1, content: { '@type': 'messageText', text: { text: 'tgsocial v1\nname: x' } } }), false);
  assert.equal(isPost({ id: 1, content: { '@type': 'messageText', text: { text: 'hello' } } }), true);
  assert.equal(isPost({ id: 7, content: { '@type': 'messagePhoto' } }, 7), false);
});

test('feed merge is strictly chronological across sources with cursors', () => {
  const m = createMerge(['a', 'b']);
  // a has items at 100, 90, 80; b has 95, 85 (newest first as TDLib returns)
  pushMessages(m, 'a', [
    { id: 3145728, date: 100 },
    { id: 2097152, date: 90 },
    { id: 1048576, date: 80 },
  ]);
  // b not yet fetched → nothing can be emitted
  let r = takeNext(m, 10);
  assert.equal(r.items.length, 0);
  assert.equal(r.blockedOn, 'b');
  pushMessages(m, 'b', [
    { id: 5242880, date: 95 },
    { id: 4194304, date: 85 },
  ]);
  r = takeNext(m, 10);
  assert.deepEqual(
    r.items.map((i) => `${i.key}${i.date}`),
    ['a100', 'b95', 'a90', 'b85'],
  );
  // a still has 80 but b's buffer is empty and live (lastDate 85 ≥ 80) → blocked on b
  assert.equal(r.blockedOn, 'b');
  assert.equal(refillCandidate(m), 'b');
  markExhausted(m, 'b');
  r = takeNext(m, 10);
  assert.deepEqual(r.items.map((i) => `${i.key}${i.date}`), ['a80']);
  assert.equal(r.blockedOn, 'a');
  markExhausted(m, 'a');
  assert.equal(isExhausted(m), true);
});

test('merge refill picks the empty source whose last item is newest', () => {
  const m = createMerge(['a', 'b', 'c']);
  pushMessages(m, 'a', [{ id: 10 * 1048576, date: 50 }]);
  pushMessages(m, 'b', [{ id: 10 * 1048576, date: 70 }]);
  pushMessages(m, 'c', [{ id: 10 * 1048576, date: 60 }]);
  const r = takeNext(m, 10);
  assert.deepEqual(r.items.map((i) => i.key), ['b']);
  assert.equal(r.blockedOn, 'b');
});

test('merge dedupes repeated ids', () => {
  const m = createMerge(['a']);
  pushMessages(m, 'a', [{ id: 2, date: 2 }, { id: 1, date: 1 }]);
  pushMessages(m, 'a', [{ id: 1, date: 1 }]);
  assert.equal(m.sources.a.exhausted, true);
  const r = takeNext(m, 10);
  assert.equal(r.items.length, 2);
});

test('rankPlusOne ranks by mutual count and excludes me and direct follows', () => {
  const cards = new Map([
    ['tgs_ana', { follows: ['tgs_bob', 'tgs_carol', 'tgs_me'] }],
    ['tgs_bob', { follows: ['tgs_carol', 'tgs_dave', 'TGS_ANA'] }],
  ]);
  const ranked = rankPlusOne('tgs_me', ['tgs_ana', 'tgs_bob'], cards);
  assert.deepEqual(ranked.map((r) => [r.username, r.mutual]), [['tgs_carol', 2], ['tgs_dave', 1]]);
});

// PRODUCT §2.3: strictly newest first, end to end. Three sources whose pages
// interleave every which way (one source even arrives in two fetches, the
// second older than anything buffered) must come out in one descending run,
// with load-more pages continuing the run rather than restarting it.
test('three interleaved sources emit one strictly newest-first run across pages', () => {
  const id = (n) => n * 1048576;
  const m = createMerge(['a', 'b', 'c']);
  pushMessages(m, 'a', [{ id: id(31), date: 1000 }, { id: id(30), date: 940 }, { id: id(29), date: 700 }, { id: id(28), date: 400 }]);
  pushMessages(m, 'b', [{ id: id(52), date: 990 }, { id: id(51), date: 950 }, { id: id(50), date: 450 }]);
  pushMessages(m, 'c', [{ id: id(73), date: 960 }, { id: id(72), date: 960 }, { id: id(71), date: 800 }, { id: id(70), date: 410 }]);
  const emitted = [];
  const page = (n) => {
    const r = takeNext(m, n);
    emitted.push(...r.items);
    return r;
  };
  let r = page(5);
  assert.deepEqual(r.items.map((i) => `${i.key}${i.date}`), ['a1000', 'b990', 'c960', 'c960', 'b950']);
  // same date: higher id first
  assert.equal(r.items[2].id, id(73));
  assert.equal(r.blockedOn, null);
  r = page(5);
  assert.deepEqual(r.items.map((i) => `${i.key}${i.date}`), ['a940', 'c800', 'a700', 'b450']);
  // b's buffer ran dry at 450 while a still holds 400 — the merge must wait for b, not skip ahead
  assert.equal(r.blockedOn, 'b');
  // the refill returns older messages than b's cursor, as getChatHistory does
  pushMessages(m, 'b', [{ id: id(49), date: 440 }, { id: id(48), date: 405 }]);
  r = page(5);
  // c ran dry at 410: b405 is held until c says it has nothing between 405 and 410
  assert.deepEqual(r.items.map((i) => `${i.key}${i.date}`), ['b440', 'c410']);
  assert.equal(r.blockedOn, 'c');
  markExhausted(m, 'c');
  r = page(5);
  assert.deepEqual(r.items.map((i) => `${i.key}${i.date}`), ['b405']);
  assert.equal(r.blockedOn, 'b');
  markExhausted(m, 'b');
  r = page(5);
  assert.deepEqual(r.items.map((i) => `${i.key}${i.date}`), ['a400']);
  markExhausted(m, 'a');
  assert.equal(isExhausted(m), true);
  assert.equal(emitted.length, 13);
  assert.equal(isNewestFirst(emitted), true);
  for (let i = 1; i < emitted.length; i += 1) assert.ok(emitted[i - 1].date >= emitted[i].date, `item ${i} older than the next`);
});

test('isNewestFirst rejects ascending runs and same-date id inversions', () => {
  assert.equal(isNewestFirst([{ date: 3, id: 3 }, { date: 2, id: 2 }, { date: 1, id: 1 }]), true);
  assert.equal(isNewestFirst([{ date: 1, id: 1 }, { date: 2, id: 2 }]), false);
  assert.equal(isNewestFirst([{ date: 2, id: 1 }, { date: 2, id: 2 }]), false);
  assert.equal(isNewestFirst([]), true);
});

test('insertIndex slots a live post into a newest-first list', () => {
  const list = [{ date: 50, id: 5 }, { date: 40, id: 4 }, { date: 30, id: 3 }];
  assert.equal(insertIndex(list, 60, 6), 0);
  assert.equal(insertIndex(list, 45, 9), 1);
  assert.equal(insertIndex(list, 40, 9), 1);
  assert.equal(insertIndex(list, 40, 1), 2);
  assert.equal(insertIndex(list, 10, 1), 3);
});

test('albums: takeAlbumRest drains the rest of an album from its source', () => {
  const id = (n) => n * 1048576;
  const m = createMerge(['a', 'b']);
  pushMessages(m, 'a', [
    { id: id(13), date: 500, media_album_id: '7' },
    { id: id(12), date: 500, media_album_id: '7' },
    { id: id(11), date: 499, media_album_id: '7' },
    { id: id(10), date: 300, media_album_id: '0' },
  ]);
  pushMessages(m, 'b', [{ id: id(20), date: 499 }]);
  // count 1 emits the album's newest item; the rest follow without consulting the bound
  const r = takeNext(m, 1);
  assert.equal(r.items.length, 1);
  const rest = takeAlbumRest(m, r.items[0]);
  assert.deepEqual(rest.map((i) => i.id), [id(12), id(11)]);
  assert.deepEqual(takeAlbumRest(m, r.items[0]), []);
  const tail = takeNext(m, 5).items;
  markExhausted(m, 'b');
  tail.push(...takeNext(m, 5).items);
  const groups = groupAlbums([...r.items, ...rest, ...tail]);
  assert.deepEqual(groups.map((g) => [g.key, g.album, g.items.map((i) => i.id)]), [
    ['a', '7', [id(11), id(12), id(13)]],
    ['b', null, [id(20)]],
    ['a', null, [id(10)]],
  ]);
  assert.equal(albumId({ media_album_id: '0' }), null);
  assert.equal(albumId({}), null);
  assert.equal(albumId({ media_album_id: '42' }), '42');
});

// ── media memory: the byte-bounded blob cache (js/blobcache.js) ─────────────
//
// The cache is DOM-free by design, so the accounting and the eviction order
// are checked here rather than in a browser: a fake blob is anything with a
// `size`, and create/revoke are counters.

function fakeUrls() {
  const state = { created: [], revoked: [], n: 0 };
  state.create = () => {
    state.n += 1;
    const url = `blob:fake/${state.n}`;
    state.created.push(url);
    return url;
  };
  state.revoke = (url) => state.revoked.push(url);
  return state;
}

const blob = (size, type = 'image/jpeg') => ({ size, type });

test('media cache: cost is the decoded surface, or the buffer when unknown', () => {
  // 100 × 100 RGBA is 40 000 bytes of surface even though the JPEG is 1 000
  assert.equal(costOf(blob(1000), 100, 100), 40000);
  // …and a buffer bigger than its own surface (a video, an animation) is charged in full
  assert.equal(costOf(blob(90000), 100, 100), 90000);
  assert.equal(costOf(blob(1234)), 1234);
  assert.equal(costOf(null), 0);
});

test('media cache: every insert reports its real cost and the total tracks it', () => {
  const u = fakeUrls();
  const c = new MediaCache({ maxBytes: 10 * MB, maxEntries: 10, create: u.create, revoke: u.revoke });
  c.put('a', blob(1000), { width: 100, height: 50 }); // 100*50*4 = 20 000
  c.put('b', blob(5000));
  assert.equal(c.bytes, 20000 + 5000);
  assert.equal(c.size, 2);
  c.drop('a');
  assert.equal(c.bytes, 5000);
  c.put('b', blob(7000));
  assert.equal(c.bytes, 7000, 'replacing an entry refunds the old cost');
});

test('media cache: bytes are the binding constraint and eviction is least-recently-used', () => {
  const u = fakeUrls();
  const c = new MediaCache({ maxBytes: 300, maxEntries: 100, create: u.create, revoke: u.revoke });
  c.put('a', blob(100));
  c.put('b', blob(100));
  c.put('c', blob(100));
  const aUrl = c.url('a'); // 'a' is now the most recently used
  assert.equal(c.size, 3);
  c.put('d', blob(100));
  assert.ok(c.bytes <= c.maxBytes, `bytes ${c.bytes} within ${c.maxBytes}`);
  assert.equal(c.has('b'), false, 'the least recently used entry went first');
  assert.equal(c.has('a'), true, 'the touched entry survived');
  assert.deepEqual(u.revoked, [], 'an entry with no URL minted has nothing to revoke');
  c.put('e', blob(100));
  assert.equal(c.has('c'), false);
  assert.equal(u.revoked.includes(aUrl), false, "the surviving entry's URL is still live");
});

test('media cache: an evicted URL is revoked once and never handed out again', () => {
  const u = fakeUrls();
  const c = new MediaCache({ maxBytes: 200, maxEntries: 100, create: u.create, revoke: u.revoke });
  c.put('a', blob(100));
  const first = c.url('a');
  assert.equal(c.url('a'), first, 'the same entry keeps one URL');
  c.put('b', blob(100));
  c.put('c', blob(100)); // pushes 'a' out
  assert.equal(c.has('a'), false);
  assert.deepEqual(u.revoked, [first], 'revoked exactly once');
  assert.equal(c.wasRevoked(first), true);
  assert.equal(c.url('a'), null, 'a dropped key resolves to nothing, not to a dead URL');
  c.put('a', blob(100));
  const second = c.url('a');
  assert.notEqual(second, first, 'the refetched entry gets a fresh URL');
  assert.equal(c.wasRevoked(second), false);
});

test('media cache: the entry cap is the backstop when the blobs are tiny', () => {
  const u = fakeUrls();
  const c = new MediaCache({ maxBytes: 10 * MB, maxEntries: 4, create: u.create, revoke: u.revoke });
  for (let i = 0; i < 50; i += 1) c.put(`k${i}`, blob(8));
  assert.equal(c.size, 4);
  assert.ok(c.bytes <= 4 * 8);
  assert.equal(c.has('k49'), true, 'the newest insert is never its own victim');
});

test('media cache: a pinned entry is not evicted, and clear leaves it alone', () => {
  const u = fakeUrls();
  const c = new MediaCache({ maxBytes: 200, maxEntries: 100, create: u.create, revoke: u.revoke });
  c.put('open', blob(100));
  const openUrl = c.url('open');
  c.pin('open');
  for (let i = 0; i < 20; i += 1) c.put(`k${i}`, blob(100));
  assert.equal(c.has('open'), true, 'the picture on screen survived the sweep');
  assert.equal(u.revoked.includes(openUrl), false);
  c.clear();
  assert.equal(c.has('open'), true);
  c.unpin('open');
  assert.equal(c.clear(), 1);
  assert.equal(c.size, 0);
  assert.equal(c.bytes, 0);
  assert.equal(u.revoked.includes(openUrl), true, 'unpinned and cleared, the URL is revoked');
});

test('media cache: a blob stored again under the same key keeps its live URL', () => {
  const u = fakeUrls();
  const c = new MediaCache({ maxBytes: 10 * MB, create: u.create, revoke: u.revoke });
  const b = blob(100);
  c.put('a', b);
  const url = c.url('a');
  c.put('a', b);
  assert.equal(c.url('a'), url);
  assert.deepEqual(u.revoked, []);
  assert.equal(c.bytes, 100, 'and it is charged once');
});

test('media budget: derived from the runtime, clamped into the tens of MB', () => {
  const at = (deviceMemory, heap = 0) => mediaBudgetBytes({
    navigator: deviceMemory ? { deviceMemory } : {},
    performance: heap ? { memory: { jsHeapSizeLimit: heap } } : {},
  });
  assert.equal(at(0), 48 * MB, 'no signal at all → the page ceiling, one eighth of it, capped');
  assert.equal(at(8), 48 * MB, 'a big machine is still a browser tab');
  assert.equal(at(0.5), 16 * MB, 'a 512 MB device gets 128 MB / 8');
  assert.equal(at(0.25), 12 * MB, 'and the floor holds under that');
  assert.equal(at(8, 64 * MB), 12 * MB, "a small heap ceiling wins over the estimate");
  for (const g of [0.25, 0.5, 1, 2, 4, 8]) {
    const b = at(g);
    assert.ok(b >= 12 * MB && b <= 48 * MB, `${g} GiB → ${b} inside the clamp`);
  }
});

test('rendition keys separate the feed card from the full-screen viewing', () => {
  assert.equal(renditionKey('u123', 780), 'u123@780');
  assert.equal(renditionKey('u123', 96), 'u123@96');
  assert.equal(renditionKey('u123', null), 'u123@full');
  assert.notEqual(renditionKey('u123', 780), renditionKey('u123', 1170));
});

/**
 * A Td whose TDLib calls are stubbed and whose cache is DOM-free, so the key
 * derivation can be exercised end to end under node.
 */
function stubTd(bytes = 'video-bytes') {
  const td = new Td();
  const revoked = [];
  let n = 0;
  td.media = new MediaCache({
    maxBytes: 10000,
    maxEntries: 8,
    create: () => `blob:stub/${(n += 1)}`,
    revoke: (u) => revoked.push(u),
  });
  td.download = async (f) => f;
  td.send = async () => ({ data: new Blob([bytes]) });
  return { td, revoked };
}

test('pin: a player pins the key its bytes are actually cached under', async () => {
  // pinImage used to derive `<key>@full` while fileBlobOrThrow stored the bare
  // `<key>`, so every video and every voice note pinned an entry that did not
  // exist: pin() returned false and the blob a <video> was playing was an
  // ordinary eviction victim.
  const { td } = stubTd();
  const file = { id: 7, size: 11, remote: { unique_id: 'vid7' }, local: {} };
  await td.fileBlobOrThrow(file);
  assert.equal(td.media.has(td.fileKey(file)), true, 'the blob is cached under the bare file key');

  const key = td.pinImage(file, null);
  assert.equal(key, td.fileKey(file), 'and that is the key the pin names');
  assert.equal(td.media.entries.get(key).pins, 1, 'the pin landed on the entry');

  td.media.clear();
  assert.equal(td.media.has(key), true, 'a memory-pressure flush spares what is playing');
  assert.equal(td.media.url(key).startsWith('blob:'), true, 'and its URL is still live');

  td.unpinKey(key);
  assert.equal(td.media.entries.get(key).pins, 0);
  td.media.clear();
  assert.equal(td.media.has(key), false, 'once playback lets go, the flush takes it');
});

test('pin: an image rendition still pins the width it was fetched at', () => {
  const { td } = stubTd();
  const file = { id: 9, remote: { unique_id: 'ph9' }, local: {} };
  td.media.put(renditionKey('ph9', 780), new Blob(['x']));
  assert.equal(td.pinImage(file, 780), 'ph9@780');
  assert.equal(td.pinImage(file, 96), null, 'a width nothing was cached at pins nothing');
  assert.equal(td.mediaKey(file, 780), 'ph9@780');
  assert.equal(td.mediaKey(file, null), 'ph9', 'no width means the stored file itself');
});

// ── the header probe that keeps a decode off the already-small (js/decode.js) ─

function jpegBytes(width, height, orientation = 0) {
  const out = [0xff, 0xd8];
  if (orientation) {
    const tiff = [
      0x49, 0x49, 0x2a, 0x00, // 'II', 42
      0x08, 0x00, 0x00, 0x00, // IFD0 at +8
      0x01, 0x00, // one entry
      0x12, 0x01, 0x03, 0x00, // tag 0x0112, type SHORT
      0x01, 0x00, 0x00, 0x00, // count 1
      orientation & 0xff, 0x00, 0x00, 0x00, // value
      0x00, 0x00, 0x00, 0x00, // no next IFD
    ];
    const payload = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00, ...tiff];
    const len = payload.length + 2;
    out.push(0xff, 0xe1, (len >> 8) & 0xff, len & 0xff, ...payload);
  }
  out.push(0xff, 0xc0, 0x00, 0x11, 0x08,
    (height >> 8) & 0xff, height & 0xff,
    (width >> 8) & 0xff, width & 0xff,
    0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01);
  while (out.length < 32) out.push(0x00);
  return new Uint8Array(out);
}

function pngBytes(width, height) {
  const out = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52];
  for (const v of [width, height]) out.push((v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff);
  while (out.length < 40) out.push(0x00);
  return new Uint8Array(out);
}

test('image header: size comes off the header, so an already-small picture never decodes', () => {
  assert.deepEqual(readImageHeader(jpegBytes(2000, 1500)), { width: 2000, height: 1500, orientation: 1 });
  assert.deepEqual(readImageHeader(jpegBytes(96, 96, 1)), { width: 96, height: 96, orientation: 1 });
  assert.deepEqual(readImageHeader(pngBytes(1280, 720)), { width: 1280, height: 720, orientation: 1 });
});

test('image header: an EXIF rotation is reported, never assumed away', () => {
  // orientations 5–8 swap the painted axes, so the stored width is the painted
  // HEIGHT: resizing to it would squash the photo. downscale() takes the full
  // decode for these rather than trusting the header.
  for (const o of [2, 3, 4, 5, 6, 7, 8]) {
    assert.equal(readImageHeader(jpegBytes(2000, 1500, o)).orientation, o, `orientation ${o} survives the probe`);
  }
});

test('image header: an unreadable header is null, not a throw', () => {
  assert.equal(readImageHeader(null), null);
  assert.equal(readImageHeader(new Uint8Array(8)), null, 'too short to say anything');
  assert.equal(readImageHeader(new Uint8Array(64)), null, 'no signature we know');
  assert.equal(readImageHeader(new Uint8Array([0xff, 0xd8, ...new Array(62).fill(0)])), null, 'SOI with no frame header');
});

// ── the in-memory feed window (PRODUCT §2.3) ───────────────────────────────

test('feed window: trims off the head and keeps the survivors newest-first', () => {
  const posts = [];
  for (let i = 0; i < 10; i += 1) posts.push({ key: `k${i}`, date: 100 - i, id: 100 - i });
  const { posts: kept, dropped } = trimFeedWindow(posts, 4);
  assert.equal(dropped, 6);
  assert.equal(kept.length, 4);
  assert.deepEqual(kept.map((p) => p.key), ['k6', 'k7', 'k8', 'k9'], 'the oldest-held page goes, the reader keeps their place');
  assert.equal(isNewestFirst(kept), true);
  assert.deepEqual(trimFeedWindow(posts, 20), { posts, dropped: 0 }, 'under the cap it is a no-op');
  assert.deepEqual(trimFeedWindow([], 4), { posts: [], dropped: 0 });
  assert.equal(trimFeedWindow(posts, 0).dropped, 0, 'a nonsense cap never empties the feed');
});

test('feed window: a live insert trims the far end, never the post that just arrived', () => {
  const posts = [];
  for (let i = 0; i < 10; i += 1) posts.push({ key: `k${i}`, date: 100 - i, id: 100 - i });
  const live = { key: 'live', date: 200, id: 200 };
  posts.splice(insertIndex(posts, live.date, live.id), 0, live);
  const { posts: kept, dropped } = trimFeedWindow(posts, 4, { from: 'tail' });
  assert.equal(dropped, 7);
  assert.equal(kept[0].key, 'live', 'the new post is at the top and stays there');
  assert.deepEqual(kept.map((p) => p.key), ['live', 'k0', 'k1', 'k2']);
  assert.equal(isNewestFirst(kept), true);
});

test('feed window: pagination survives the trim', () => {
  // the merge cursor lives outside the window, so trimming must not change
  // which post comes next — page after page, the window is the newest `max`
  const merge = createMerge(['a']);
  const id = (n) => n * 1048576;
  const all = [];
  for (let i = 0; i < 90; i += 1) all.push({ id: id(200 - i), date: 5000 - i });
  pushMessages(merge, 'a', all);
  markExhausted(merge, 'a');
  const MAX = 25;
  let window = [];
  let pages = 0;
  for (;;) {
    const page = takeNext(merge, 10).items;
    if (!page.length) break;
    pages += 1;
    window.push(...page.map((m) => ({ key: `a:${m.id}`, id: m.id, date: m.date })));
    const trimmed = trimFeedWindow(window, MAX);
    window = trimmed.posts;
    assert.ok(window.length <= MAX, `window ${window.length} <= ${MAX}`);
    assert.equal(isNewestFirst(window), true, 'still strictly newest-first after the trim');
  }
  assert.equal(pages, 9, 'every page was still delivered after trims');
  assert.equal(window.length, MAX);
  assert.equal(window[window.length - 1].id, id(111), 'the last post loaded is still in the window');
  assert.equal(new Set(window.map((p) => p.key)).size, MAX, 'no duplicates re-enter on a trim');
});
