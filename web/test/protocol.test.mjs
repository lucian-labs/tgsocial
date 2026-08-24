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
} from '../js/protocol.js';

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
