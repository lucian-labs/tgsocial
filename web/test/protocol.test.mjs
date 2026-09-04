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
  publicOrigin,
  publicPersonUrl,
  publicPath,
  setPublicOrigin,
  trimFeedWindow,
} from '../js/protocol.js';
import { MediaCache, mediaBudgetBytes, renditionKey, costOf, MB } from '../js/blobcache.js';
import { readImageHeader } from '../js/decode.js';
import { Td } from '../js/td.js';
import { decodeWaveform } from '../js/media.js';
import { rampStops } from '../vendor/house-pour.js';
import { MOSAIC_AREAS, MOSAIC_MAX_TILES, mosaicPlan, mosaicRatio, tileArea } from '../js/mosaic.js';
import { replyTarget } from '../js/views/comments.js';
import {
  CONTACT_ADDRESS,
  MODERATION_KEY,
  REPORT_REASONS,
  SafetyLists,
  keepsComment,
  keepsPost,
  mailtoUrl,
  normaliseRecord,
  reportBody,
  reportSubject,
} from '../js/moderation.js';
import {
  analyse,
  analysisPlan,
  analysisRate,
  axisMaxHz,
  bandCentreHz,
  DURATION_CAP_S,
  ENVELOPE_CAP_S,
  ENVELOPE_MAX_SAMPLES,
  ENVELOPE_RATE,
  envelopeColumns,
  resampleEnvelope,
  ENVELOPE_ATTACK_MS,
  ENVELOPE_RELEASE_MS,
  F_MAX,
  FFT_SIZE,
  followEnvelope,
  framePlan,
  logBandEdges,
  MAX_FFT_SIZE,
  MAX_FRAMES,
  MAX_SAMPLES,
  MIN_RATE,
  onePoleCoefficient,
  paintStrip,
  rampColorAt,
  rowForFrequency,
  TARGET_RATE,
} from '../js/spectro.js';

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
    ['/u/tastycrow', { name: 'person', username: 'tastycrow' }],
    ['/u/tastycrow/', { name: 'person', username: 'tastycrow' }],
    ['/u/@tastycrow', { name: 'person', username: 'tastycrow' }],
    ['/u/bad-name', null],
    ['/u/%zz', null],
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
  // The default, and the only state a fresh clone has: no origin is
  // configured, so every share is the t.me link — nobody hosts the public
  // pages until somebody chooses to.
  test('publicFeedUrl / publicNodeUrl / publicPersonUrl are t.me links with no origin configured', () => {
    setPublicOrigin(null);
    assert.equal(publicOrigin(), null);
    assert.equal(publicFeedUrl('waveloop_devlog'), 'https://t.me/waveloop_devlog');
    assert.equal(publicNodeUrl('tgs_elijah'), 'https://t.me/tgs_elijah');
    assert.equal(publicPersonUrl('tastycrow'), 'https://t.me/tastycrow');
  });
  // A person is not a feed. `/u/<name>` may have been reached through a feed's
  // backlink (PUBLIC §4), and with no reader to resolve that a second time the
  // t.me link has to name the node — whose pinned message is the card — rather
  // than the channel the visitor happened to arrive by.
  test('publicPersonUrl falls back to the resolved node, not the arrival handle', () => {
    setPublicOrigin(null);
    assert.equal(publicPersonUrl('tastycrow', 'tgs_dankcoin'), 'https://t.me/tgs_dankcoin');
    assert.notEqual(publicPersonUrl('tastycrow', 'tgs_dankcoin'), publicFeedUrl('tastycrow'));
    // no node to hand it (the handle already is the node): unchanged
    assert.equal(publicPersonUrl('tgs_dankcoin', 'tgs_dankcoin'), 'https://t.me/tgs_dankcoin');
  });
  test('a configured publicOrigin makes the same three absolute to that host', () => {
    try {
      // a trailing slash is what a config file gets typed with; it is not a
      // second origin
      assert.equal(setPublicOrigin('https://tgs.example/'), 'https://tgs.example');
      assert.equal(publicOrigin(), 'https://tgs.example');
      assert.equal(publicFeedUrl('waveloop_devlog'), 'https://tgs.example/f/waveloop_devlog');
      assert.equal(publicNodeUrl('tgs_elijah'), 'https://tgs.example/n/tgs_elijah');
      assert.equal(publicPersonUrl('tastycrow'), 'https://tgs.example/u/tastycrow');
      // the arrival handle, not the node it resolved to: the reader on the
      // other end follows the backlink again (PUBLIC §4)
      assert.equal(publicPersonUrl('tastycrow', 'tgs_dankcoin'), 'https://tgs.example/u/tastycrow');
      assert.equal(setPublicOrigin('http://localhost:8080'), 'http://localhost:8080');
      assert.equal(publicFeedUrl('waveloop_devlog'), 'http://localhost:8080/f/waveloop_devlog');
    } finally {
      setPublicOrigin(null);
    }
  });
  // A refused origin is not a crash and not a broken link: it falls back to
  // the same t.me link an unset one does.
  test('setPublicOrigin refuses anything that is not a bare http(s) origin', () => {
    for (const bad of [undefined, null, '', '   ', 42, 'tgs.example', '//tgs.example',
      'javascript:alert(1)', 'https://tgs.example/tgsocial', 'https://tgs.example/?a=b', 'https://tgs example']) {
      assert.equal(setPublicOrigin(bad), null, `refused: ${String(bad)}`);
      assert.equal(publicFeedUrl('waveloop_devlog'), 'https://t.me/waveloop_devlog');
    }
  });
  // Minting a link is a choice about this deployment; recognising one is not.
  // Somebody else's /f/ URL has to keep routing here whatever we mint.
  test('parsePublicPath stays origin-blind whatever is configured', () => {
    try {
      setPublicOrigin('https://tgs.example');
      assert.deepEqual(parsePublicPath('/f/waveloop_devlog'), { name: 'channel', username: 'waveloop_devlog' });
      assert.deepEqual(parsePublicPath(new URL('https://someone.else/u/tastycrow').pathname), { name: 'person', username: 'tastycrow' });
    } finally {
      setPublicOrigin(null);
    }
  });
  test('publicPath round-trips every public route', () => {
    for (const path of ['/u/tastycrow', '/f/waveloop_devlog', '/n/tgs_elijah']) {
      assert.equal(publicPath(parsePublicPath(path)), path);
    }
    assert.equal(publicPath({ name: 'feed' }), '/');
  });
}

/* PUBLIC.md §3 — "the renderer builds nodes; no innerHTML of preview content
 * anywhere". The cheapest way to keep that true is to have none at all: no
 * module in js/ may assign innerHTML/outerHTML or call insertAdjacentHTML,
 * because a page rendering third-party HTML is one careless line away and the
 * line is easy to grep for and hard to notice in review. */
test('no HTML injection sink exists anywhere in js/', async () => {
  const { readdir } = await import('node:fs/promises');
  const walk = async (dir) => {
    const out = [];
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) out.push(...await walk(full));
      else if (entry.name.endsWith('.js')) out.push(full);
    }
    return out;
  };
  const sink = /\.(innerHTML|outerHTML)\s*(=|\+=)|insertAdjacentHTML|document\.write/;
  const offenders = [];
  for (const file of await walk(join(here, '..', 'js'))) {
    const src = await readFile(file, 'utf8');
    src.split('\n').forEach((line, i) => {
      if (sink.test(line)) offenders.push(`${file}:${i + 1} ${line.trim()}`);
    });
  }
  assert.deepEqual(offenders, [], 'HTML injection sinks in js/');
});

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

// ── PRODUCT §2.11.1 — the spectrogram strip ────────────────────────────────
//
// The pure half of the strip: the follower, the log axis, the AGC, the ramp,
// the caps and the fallback. Everything below runs under node with no DOM and
// no AudioContext, which is the whole reason js/spectro.js knows nothing about
// either. The assembled behaviour — a real clip decoded, painted, seeked and
// measured on the card — is test/flows.mjs.

/** The generated `--ramp-*` tokens, read the way vendor/house-pour.js reads them. */
async function generatedRamp() {
  const css = await readFile(join(here, '..', 'vendor', 'house-pour.css'), 'utf8');
  const values = new Map();
  for (const m of css.matchAll(/(--ramp-[\w-]+)\s*:\s*([^;]+);/g)) values.set(m[1], m[2].trim());
  globalThis.getComputedStyle = () => ({ getPropertyValue: (n) => values.get(n) ?? '' });
  return rampStops({});
}

test('strip: the one-pole follower rises at the attack rate and decays at the release rate', () => {
  const rate = TARGET_RATE;
  // A time constant is defined by where the step lands after exactly τ: one
  // 1/e of the way there going up, one 1/e of the way back coming down. If the
  // coefficient is derived wrongly from the rate, this is what moves.
  const attackSamples = Math.round((ENVELOPE_ATTACK_MS / 1000) * rate);
  const releaseSamples = Math.round((ENVELOPE_RELEASE_MS / 1000) * rate);

  const step = new Float32Array(attackSamples + releaseSamples);
  step.fill(1, 0, attackSamples);
  const y = followEnvelope(step, rate);
  assert.ok(Math.abs(y[attackSamples - 1] - (1 - 1 / Math.E)) < 0.01,
    `after one attack τ the follower is at 1 − 1/e (got ${y[attackSamples - 1].toFixed(4)})`);

  const held = new Float32Array(releaseSamples * 2);
  held.fill(1, 0, releaseSamples * 8); // stays 1 for the whole first half
  const settled = followEnvelope(held, rate);
  assert.ok(settled[releaseSamples * 2 - 1] > 0.99, 'a long step settles at the input');

  // decay: hold 1 long enough to settle, then drop to 0 for exactly one release τ
  const decay = new Float32Array(releaseSamples * 20 + releaseSamples);
  decay.fill(1, 0, releaseSamples * 20);
  const d = followEnvelope(decay, rate);
  assert.ok(Math.abs(d[d.length - 1] - 1 / Math.E) < 0.01,
    `after one release τ the follower is at 1/e (got ${d[d.length - 1].toFixed(4)})`);

  // attack is fast, release is slow — the shape §2.11.1 asks for, not the reverse
  assert.ok(onePoleCoefficient(ENVELOPE_ATTACK_MS, rate) > onePoleCoefficient(ENVELOPE_RELEASE_MS, rate) * 10,
    'attack is more than an order of magnitude faster than release');
});

test('strip: the follower produces one normalised value per column, spanning the strip', () => {
  const rate = TARGET_RATE;
  const n = rate * 2;
  const samples = new Float32Array(n);
  // loud in the middle third, silent either side
  for (let i = 0; i < n; i += 1) {
    const loud = i > n / 3 && i < (2 * n) / 3;
    samples[i] = loud ? 0.4 * Math.sin((2 * Math.PI * 220 * i) / rate) : 0;
  }
  const env = envelopeColumns(samples, rate, 64);
  assert.equal(env.length, 64);
  assert.ok(Math.max(...env) > 0.99, 'the silhouette is normalised to span the strip');
  assert.ok(env[32] > 0.8, 'the loud middle is tall');
  assert.ok(env[2] < 0.05, 'the silent opening is flat');
});

test('strip: a bin centre frequency lands on its own row of the log axis', () => {
  const rows = 88;
  // §2.11.1: the axis runs 20 Hz to the ANALYSIS NYQUIST, ceilinged at 20 kHz.
  // It follows the rate rather than reserving rows for a band the decimation
  // discarded — the same clamp iOS (`SpectrogramSpec.axisMax`) and Android
  // (`effectiveFMax`) make, so one clip is one picture on all three.
  const fMax = axisMaxHz(TARGET_RATE);
  assert.equal(fMax, TARGET_RATE / 2, 'the axis tops out at Nyquist when the declared span is higher');
  assert.equal(axisMaxHz(96000), F_MAX, 'and at the declared span when Nyquist is higher');
  // the rate slides with the clip's length, so the top of the strip does too
  assert.equal(axisMaxHz(analysisRate(30)), TARGET_RATE / 2, 'a short clip tops out at 8 kHz');
  assert.equal(axisMaxHz(analysisRate(DURATION_CAP_S)), MIN_RATE / 2, 'and a clip at the cap tops out at 4 kHz');
  for (let i = 0; i < rows; i += 1) {
    assert.equal(rowForFrequency(bandCentreHz(i, rows, fMax), rows, fMax), i, `row ${i} round-trips through its centre frequency`);
  }
  // low at the bottom, high at the top, and log — not linear — in between
  assert.equal(rowForFrequency(20, rows, fMax), 0);
  assert.equal(rowForFrequency(fMax, rows, fMax), rows - 1);
  const geometricMiddle = Math.sqrt(20 * fMax);
  assert.equal(rowForFrequency(geometricMiddle, rows, fMax), Math.floor(rows / 2),
    'the GEOMETRIC mean sits at the middle row, which a linear axis would not do');
  assert.ok(rowForFrequency((20 + fMax) / 2, rows, fMax) > rows * 0.85, 'while the ARITHMETIC mean is crowded up near the top');
  // both ends clamp rather than running off the array
  assert.equal(rowForFrequency(1, rows, fMax), 0);
  assert.equal(rowForFrequency(96000, rows, fMax), rows - 1);
});

test('strip: the log band edges cover the axis without gaps and stay inside the bins', () => {
  const rows = 88;
  // Every rate the plan can pick, because the axis follows the rate: no rate
  // may leave a row of the strip with nothing to peak-pick.
  for (const rate of [TARGET_RATE, analysisRate(300), analysisRate(DURATION_CAP_S)]) {
    const { lo, hi, fMax } = logBandEdges(rows, rate, FFT_SIZE);
    assert.equal(fMax, axisMaxHz(rate), `${rate} Hz: the axis ends at its own Nyquist`);
    for (let i = 0; i < rows; i += 1) {
      assert.ok(hi[i] > lo[i], `${rate} Hz: band ${i} holds at least one bin`);
      assert.ok(hi[i] <= FFT_SIZE / 2, `${rate} Hz: band ${i} stays inside the N/2 magnitude bins`);
      if (i > 0) assert.ok(lo[i] >= lo[i - 1], 'bands ascend');
    }
  }
  // …and a caller that insists on a top ABOVE Nyquist gets empty bands up
  // there, never the top real bin clamped upward into a bright false ceiling.
  const wide = logBandEdges(rows, TARGET_RATE, FFT_SIZE, F_MAX);
  const dead = [...wide.lo.keys()].filter((i) => wide.hi[i] === wide.lo[i]);
  assert.ok(dead.length > 0 && dead.every((i) => 20 * (F_MAX / 20) ** (i / rows) >= TARGET_RATE / 2),
    'the empty bands are exactly the ones above Nyquist');
});

test('strip: the AGC normalises, so a quiet clip still spans the strip', () => {
  const rate = TARGET_RATE;
  const rows = 64;
  const cols = 32;
  const tone = (amp) => {
    const n = rate; // one second at 1 kHz — the tilt pivot, so tilt is 1× here
    const s = new Float32Array(n);
    for (let i = 0; i < n; i += 1) s[i] = amp * Math.sin((2 * Math.PI * 1000 * i) / rate);
    return s;
  };
  const loud = analyse({ samples: tone(0.5), rate, cols, rows });
  const quiet = analyse({ samples: tone(0.005), rate, cols, rows }); // −46 dBFS
  const peak = (r) => Math.max(...r.mag);
  assert.ok(peak(loud) > 0.99, 'a loud clip reaches the top of the range');
  assert.ok(peak(quiet) > 0.99, 'a clip 40 dB quieter reaches the same top — the AGC is a ROLLING PEAK, not dBFS');
  assert.ok(Math.abs(peak(loud) - peak(quiet)) < 1e-6, 'and reads identically, because normalisation is relative');

  // true digital silence is the one thing that stays dark: the AGC floor is
  // what stops it from opening until the nothing fills the strip
  const silence = analyse({ samples: new Float32Array(rate), rate, cols, rows });
  assert.equal(Math.max(...silence.mag), 0, 'silence is dark, not blown up to full brightness');
});

test('strip: a tone lands on the row its frequency maps to, low at the bottom', () => {
  const rate = TARGET_RATE;
  const rows = 64;
  const cols = 16;
  const n = rate;
  const hz = 200;
  const samples = new Float32Array(n);
  for (let i = 0; i < n; i += 1) samples[i] = 0.5 * Math.sin((2 * Math.PI * hz * i) / rate);
  const { mag } = analyse({ samples, rate, cols, rows });
  const column = 8;
  let best = 0;
  for (let b = 1; b < rows; b += 1) if (mag[column * rows + b] > mag[column * rows + best]) best = b;
  const expected = rowForFrequency(hz, rows, axisMaxHz(rate));
  assert.ok(Math.abs(best - expected) <= 1, `a ${hz} Hz tone peaks at row ${expected} (got ${best})`);
  assert.ok(best < rows / 2, 'and that row is in the LOWER half — frequency runs bottom to top');
});

test('strip: the frame budget is a function of the strip, not of the file', () => {
  const rate = TARGET_RATE;
  const short = framePlan(rate * 30);
  assert.equal(short.fftSize, FFT_SIZE, 'a 30 s clip needs no wider window than the default');
  assert.equal(short.hop, FFT_SIZE / 2, 'a 30 s clip runs at the ~50% overlap §2.11.1 asks for');
  assert.ok(short.frames < MAX_FRAMES, `a 30 s clip needs ${short.frames} frames, under the ceiling`);
  const long = framePlan(rate * DURATION_CAP_S);
  assert.ok(long.frames <= MAX_FRAMES, `a ${DURATION_CAP_S} s clip is still ${long.frames} frames`);
  assert.ok(long.hop > FFT_SIZE / 2, 'past the ceiling the hop opens rather than the frame count growing');
  assert.ok(long.fftSize > FFT_SIZE, 'and the WINDOW opens with it');
});

test('strip: the STFT never skips audio — the window opens with the hop, so the windows still abut', () => {
  // The bug this pins: growing the hop ALONE past the window leaves a stretch
  // between one frame and the next that nothing ever looks at. At a 3 minute
  // clip that gap was 23 ms wide and a quarter of the audio fell in it, so a
  // transient landing there lit no column at all.
  // every sample count the caps can actually hand to `analyse` — the decode is
  // capped at MAX_SAMPLES, so that is the longest clip this ever sees
  for (const n of [TARGET_RATE * 5, TARGET_RATE * 30, TARGET_RATE * 90, TARGET_RATE * 180, MAX_SAMPLES]) {
    const plan = framePlan(n);
    assert.ok(plan.hop <= plan.fftSize, `${n} samples: hop ${plan.hop} never opens past the ${plan.fftSize} window`);
    assert.ok(plan.frames <= MAX_FRAMES, `${n} samples: ${plan.frames} frames stays inside the budget`);
    assert.ok(plan.fftSize <= MAX_FFT_SIZE, `${n} samples: the window stays inside its own ceiling`);
    // every sample is inside a window: the frames tile the clip with no hole
    const covered = (plan.frames - 1) * plan.hop + plan.fftSize;
    assert.ok(covered >= n, `${n} samples: the frames cover the whole clip (${covered} covered)`);
  }
  // and past anything the caps allow, coverage still wins over the frame budget
  const beyond = framePlan(TARGET_RATE * 1200);
  assert.ok(beyond.hop <= beyond.fftSize, 'even off the end of the window ceiling the windows abut rather than gapping');
  assert.ok(beyond.frames > MAX_FRAMES, 'and it is the FRAME budget that gives, not the coverage');
  // and a burst in what USED to be the gap now lands in a window: 3 kHz for
  // 23 ms, dropped one hop past the first frame of a 180 s clip
  const rate = TARGET_RATE;
  const n = rate * 180;
  const plan = framePlan(n);
  const samples = new Float32Array(n);
  const at = plan.fftSize + Math.floor(plan.hop / 2);
  for (let i = at; i < at + Math.round(0.023 * rate); i += 1) samples[i] = Math.sin((2 * Math.PI * 3000 * i) / rate);
  const { mag } = analyse({ samples, rate, cols: 64, rows: 88 });
  assert.ok(Math.max(...mag) > 0.5, 'a burst between two frames still lights the strip');

  // …and the acceptance bar is not one position in one clip: a burst ANYWHERE
  // in a clip at the duration cap must light a column. One `analyse` over the
  // longest clip the caps allow, carrying sixteen 23 ms bursts — one per column
  // region, each at a different phase of the hop, so every part of the stride
  // the old plan was blind to is represented. Under the bug the ones landing in
  // the gap read exactly 0.000, which is what the dark-column assertion below
  // measures on the columns that really are empty.
  const capRate = analysisRate(DURATION_CAP_S);
  const capN = Math.round(DURATION_CAP_S * capRate);
  const capPlan = framePlan(capN);
  const capCols = 64;
  const capRows = 88;
  const burst = Math.round(0.023 * capRate);
  const wide = new Float32Array(capN);
  const spots = [];
  for (let j = 0; j < 16; j += 1) {
    const at = Math.min(capN - burst - 1, Math.round((((j * 2 + 1) / 32) * capN) + (j / 16) * capPlan.hop));
    for (let i = at; i < at + burst; i += 1) wide[i] = Math.sin((2 * Math.PI * 3000 * i) / capRate);
    spots.push(at);
  }
  const capField = analyse({ samples: wide, rate: capRate, cols: capCols, rows: capRows }).mag;
  const colPeak = (c) => {
    let m = 0;
    for (let b = 0; b < capRows; b += 1) if (capField[c * capRows + b] > m) m = capField[c * capRows + b];
    return m;
  };
  // the column a burst lands in, ±1 for the frame that straddles the boundary
  const colOf = (at) => Math.min(capCols - 1, Math.floor((Math.floor(at / capPlan.hop) * capCols) / capPlan.frames));
  const near = new Set();
  for (const at of spots) for (const d of [-1, 0, 1]) near.add(colOf(at) + d);
  for (const at of spots) {
    const c = colOf(at);
    const peak = Math.max(colPeak(Math.max(0, c - 1)), colPeak(c), colPeak(Math.min(capCols - 1, c + 1)));
    assert.ok(peak > 0.2, `a burst at sample ${at} of a ${DURATION_CAP_S} s clip lights column ${c} (${peak.toFixed(3)})`);
  }
  // and the strip is not simply lit everywhere: the columns with no burst in
  // them are still exactly dark, so the assertion above is measuring the bursts
  const empty = [...Array(capCols).keys()].filter((c) => !near.has(c));
  assert.ok(empty.length > 8, 'there are columns with no burst in them to compare against');
  assert.equal(Math.max(...empty.map(colPeak)), 0, 'and every one of them is dark');
});

test('strip: the plan splits at the duration ceiling — spectrum, then silhouette, then nothing', () => {
  const under = analysisPlan(DURATION_CAP_S - 1);
  assert.equal(under.mode, 'spectrum', 'under the ceiling, the whole strip');
  assert.equal(analysisPlan(DURATION_CAP_S).mode, 'spectrum', 'at the ceiling, the whole strip');

  // §2.11.1: "past a duration ceiling (about 10 minutes) … fall back to the
  // amplitude-only silhouette". A 12 minute DJ set is a silhouette, not a
  // hairline — the same band iOS runs (SpectrogramPlan.envelopeOnly).
  const long = analysisPlan(12 * 60);
  assert.equal(long.mode, 'envelope', 'past the ceiling, the silhouette alone');
  assert.equal(long.rate, ENVELOPE_RATE, 'decoded coarse, because there is no spectrum to resolve');
  assert.ok(long.rate * (12 * 60) < MAX_SAMPLES, 'and still inside the working-set ceiling');

  assert.equal(analysisPlan(ENVELOPE_CAP_S + 1).mode, 'none', 'past the hard ceiling, nothing at all');
  assert.equal(analysisPlan(4 * 3600).mode, 'none', 'a four-hour set is refused');
  // a runtime that will not decode coarsely shrinks the band rather than
  // allocating past the ceiling for a silhouette
  assert.equal(analysisPlan(30 * 60, { envelopeRate: 8000 }).mode, 'none',
    '30 minutes at 8 kHz is 14.4 M samples — refused rather than decoded');

  // …SHRINKS it, though, never deletes it. The Web Audio spec only obliges an
  // engine to decode at 8 kHz and up, so `envelopeDecodeRate` returning 8000 is
  // the case the ladder exists for — and charging that pass against the
  // SPECTRUM's ceiling (601 × 8000 = 4.808 M, already past 4.8 M) refused every
  // clip from the first second past the cap, which is this whole band deleting
  // itself on a conforming engine. It is charged against ENVELOPE_MAX_SAMPLES
  // instead, so a 12 minute set is a silhouette on every runtime, not only on
  // the ones that reach 3 kHz (headless Chrome does, which is why flows.mjs
  // could never see this).
  assert.equal(analysisPlan(DURATION_CAP_S + 1, { envelopeRate: 8000 }).mode, 'envelope',
    'one second past the cap at 8 kHz is a silhouette, not a hairline');
  assert.equal(analysisPlan(720, { envelopeRate: 8000 }).mode, 'envelope',
    '12 minutes at 8 kHz is the silhouette iOS draws at the same duration');
  assert.equal(analysisPlan(1350, { envelopeRate: 8000 }).mode, 'envelope',
    '22.5 minutes lands exactly on the envelope budget, and is still inside it');
  assert.equal(analysisPlan(1351, { envelopeRate: 8000 }).mode, 'none',
    'and one second past it is refused — the budget is a real ceiling');
  assert.equal(1350 * 8000, ENVELOPE_MAX_SAMPLES, 'which is where that boundary comes from');

  // …and on an engine that decodes as coarsely as the band ASKS for, the budget
  // is not a ceiling at all: ENVELOPE_CAP_S is, which is the one iOS runs
  // (SpectrogramPlan.forDuration — a pure duration split, nothing else in it).
  // The band used to stop at ENVELOPE_MAX_SAMPLES / ENVELOPE_RATE = 3200 s, so
  // a 55 minute set drew a silhouette on iOS and the bare §2.11 hairline on
  // web, from a round number rather than from anything §2.11.1 says.
  assert.equal(ENVELOPE_MAX_SAMPLES, ENVELOPE_CAP_S * ENVELOPE_RATE,
    'the budget IS the band: its own ceiling at its own rate');
  assert.equal(analysisPlan(3201).mode, 'envelope', 'the old 3200 s ceiling is now mid-band');
  assert.equal(analysisPlan(ENVELOPE_CAP_S).mode, 'envelope',
    'and the hour §2.11.1 names is reachable, as it is on iOS');
  assert.equal(analysisPlan(ENVELOPE_CAP_S).reason, 'too-long',
    'reached as the silhouette band, not as a refusal that happens to say envelope');
  // the coarse pass may decode more than the FFT's buffer holds, because
  // decodeMono's box average caps the mono copy at MAX_SAMPLES independently
  assert.ok(ENVELOPE_MAX_SAMPLES > MAX_SAMPLES, 'the two ceilings bound different buffers');

  // an unknown length is not a refusal: the decode gets to be the one that fails
  for (const d of [0, undefined, NaN]) assert.equal(analysisPlan(d).mode, 'spectrum');
});

test('strip: the decode is capped in samples, so one clip cannot cost more than the whole media budget', () => {
  // iOS bounds this with maxSamples and an adaptive rate; without the same
  // bound a 10 minute stereo clip is ~77 MB of AudioBuffer plus a 38 MB mono
  // copy, none of it visible to the media cache and none of it evictable.
  assert.equal(analysisRate(30), TARGET_RATE, 'a short clip runs at the top of §2.11.1\'s 8–16 kHz band');
  assert.equal(analysisRate(DURATION_CAP_S), MIN_RATE, 'and at the duration cap the arithmetic lands on the floor');
  for (const seconds of [1, 30, 212, 300, DURATION_CAP_S]) {
    const rate = analysisRate(seconds);
    assert.ok(rate >= MIN_RATE && rate <= TARGET_RATE, `${seconds} s stays inside the band (${rate} Hz)`);
    assert.ok(Number.isInteger(rate), 'and is an integer, because it becomes an OfflineAudioContext sample rate');
    assert.ok(seconds * rate <= MAX_SAMPLES + 1, `${seconds} s decodes to at most the ceiling (${Math.round(seconds * rate)})`);
  }
});

test('strip: the fallback silhouette needs no decode — Telegram ships the bytes', () => {
  // the voice note the mock TDLib serves (test/mock-tdweb.js)
  const values = decodeWaveform('kqUqVaqlKlWqpSpVqqUqVQ==', 64);
  assert.ok(Array.isArray(values) && values.length === 64, 'waveform bytes unpack to one value per column');
  assert.ok(values.every((v) => v >= 0 && v <= 1), 'and are already 0…1, ready for the silhouette');
  assert.ok(Math.max(...values) > 0.3, 'with something in them');
  // no bytes, or bytes that are not base64, is the third fidelity: the hairline
  assert.equal(decodeWaveform(null), null);
  assert.equal(decodeWaveform(''), null);
  assert.equal(decodeWaveform('!!!not base64!!!'), null);
});

test('strip: the ramp is the generated token set, and it interpolates', async () => {
  const stops = await generatedRamp();
  assert.equal(stops.length, 5, 'five stops: transparent → line2 → muted → accent → accent-2');
  assert.equal(stops[0].a, 0, 'the quiet end is transparent, so the strip shows the bg2 it sits on');
  assert.equal(stops[stops.length - 1].at, 1, 'the loud end tops out at 1');
  for (let i = 1; i < stops.length; i += 1) assert.ok(stops[i].at > stops[i - 1].at, 'stops ascend');

  // every stop is hit exactly at its own position
  for (const s of stops) {
    const c = rampColorAt(stops, s.at);
    assert.ok(Math.abs(c.r - s.r) < 1e-6 && Math.abs(c.g - s.g) < 1e-6 && Math.abs(c.b - s.b) < 1e-6 && Math.abs(c.a - s.a) < 1e-6,
      `stop at ${s.at} reproduces itself`);
  }
  // and between two stops the value is strictly between them
  const mid = (stops[2].at + stops[3].at) / 2;
  const c = rampColorAt(stops, mid);
  const lo = Math.min(stops[2].r, stops[3].r);
  const hi = Math.max(stops[2].r, stops[3].r);
  assert.ok(c.r > lo && c.r < hi, 'a value between two stops lands between their colours');
  assert.ok(Math.abs(c.r - (stops[2].r + stops[3].r) / 2) < 1e-6, 'and exactly halfway at the midpoint');

  // both ends clamp
  const bottom = rampColorAt(stops, -5);
  const top = rampColorAt(stops, 5);
  assert.deepEqual([bottom.r, bottom.g, bottom.b, bottom.a], [stops[0].r, stops[0].g, stops[0].b, stops[0].a], 'below the ramp clamps to the first stop');
  assert.deepEqual([top.r, top.g, top.b, top.a], [stops[4].r, stops[4].g, stops[4].b, stops[4].a], 'above the ramp clamps to the last');
  assert.deepEqual(rampColorAt(stops, NaN), rampColorAt(stops, 0), 'a non-number is the bottom of the ramp, not a hole');
  assert.deepEqual(rampColorAt([], 0.5), { r: 0, g: 0, b: 0, a: 0 }, 'no stops paints nothing rather than throwing');
});

test('strip: the texture puts low frequencies at the bottom and silence at transparent', async () => {
  const stops = await generatedRamp();
  const cols = 4;
  const rows = 8;
  const mag = new Float32Array(cols * rows);
  for (let c = 0; c < cols; c += 1) mag[c * rows + 0] = 1; // the LOWEST band, full
  const px = paintStrip(mag, cols, rows, stops);
  const at = (x, y) => {
    const o = (y * cols + x) * 4;
    return { r: px[o], g: px[o + 1], b: px[o + 2], a: px[o + 3] };
  };
  const bottom = at(0, rows - 1);
  const top = at(0, 0);
  assert.ok(bottom.a > 250, 'the loud low band is opaque at the BOTTOM row of the image');
  assert.equal(top.a, 0, 'and the empty high band at the top is transparent');
  const last = stops[stops.length - 1];
  assert.ok(Math.abs(bottom.r - last.r) < 1.5 && Math.abs(bottom.g - last.g) < 1.5 && Math.abs(bottom.b - last.b) < 1.5,
    'the top of the range is accent-2, straight off the ramp');
  assert.equal(px.length, cols * rows * 4, 'the texture is exactly one RGBA pixel per column-row');
});

test('strip: the strip is charged to the media budget at its true decoded cost', () => {
  // what td.putDerived hands MediaCache: a small PNG that paints cols × rows
  const cols = 664;
  const rows = 88;
  const png = { size: 9 * 1024 };
  assert.equal(costOf(png, cols, rows), cols * rows * 4,
    'a compressed strip is charged for the surface it paints, not for its bytes on the wire');
  const cache = new MediaCache({ maxBytes: 4 * MB, create: () => 'blob:strip', revoke: () => {} });
  cache.put('u1#strip664x88', png, { width: cols, height: rows });
  assert.equal(cache.stats().bytes, cols * rows * 4, 'and shows up in the same accounting as every picture');
});

// ── PRODUCT §2.11.2 — the dock's mini waveform reads the strip's envelope ───

test('the mini waveform resamples the strip\'s envelope instead of computing one', () => {
  // 448 columns is the strip's own width at a 540 column (js/strip.js
  // stripPixels); the dock's is a fraction of that, so this is a downsample.
  const strip = envelopeColumns(Float32Array.from({ length: 48000 }, (_, i) => Math.sin(i / 9) * (i > 32000 ? 0.02 : 1)), 16000, 448);
  const dock = resampleEnvelope(strip, 96);
  assert.equal(dock.length, 96, 'exactly the columns the dock asked for');
  assert.ok(dock.every((v) => v >= 0 && v <= 1), 'still 0…1 per column');
  // Peak-picking, not averaging: the loud front of the clip must stay at full
  // height, which is the whole reason the line is worth drawing.
  assert.ok(Math.max(...dock) >= 0.99, 'the peak survives the resample');
  assert.ok(Math.max(...dock.slice(-8)) < Math.max(...dock.slice(0, 8)) / 2,
    'and the quiet tail stays quiet — a mean over eight columns would have flattened both');
});

test('resampleEnvelope widens as well as it narrows, and refuses nothing-to-draw', () => {
  assert.deepEqual([...resampleEnvelope(Float32Array.from([0, 1]), 6)], [0, 0, 0, 1, 1, 1],
    'widening is a staircase of the inputs, never a gap-toothed comb');
  assert.deepEqual([...resampleEnvelope(Float32Array.from([0, 1, 0, 0.5, 0, 0, 0, 0]), 4)], [1, 0.5, 0, 0],
    'narrowing keeps each bucket\'s peak');
  // §2.11.2: "a clip whose strip degraded to the hairline shows a flat line
  // rather than nothing" — the component draws that from a null envelope.
  assert.equal(resampleEnvelope(null, 96), null, 'no envelope is null, which the component paints flat');
  assert.equal(resampleEnvelope(Float32Array.from([0.5]), 96), null, 'and one column is not a line');
  assert.equal(resampleEnvelope(Float32Array.from([0, 1]), 0), null, 'and nowhere to paint is not a line either');
});

// ── PRODUCT §2.11.3 — the mosaic's layout rule ─────────────────────────────

test('the mosaic is one grid per count, and 5+ is 4 with the rest counted', () => {
  assert.equal(mosaicPlan(1).mosaic, false, 'one photo is not a mosaic — it is §2.11 media');
  assert.equal(mosaicPlan(0).mosaic, false, 'and no photos are not either');
  for (const [count, shown, extra] of [[2, 2, 0], [3, 3, 0], [4, 4, 0], [5, 4, 1], [9, 4, 5]]) {
    const plan = mosaicPlan(count);
    assert.equal(plan.mosaic, true, `${count} photos are a mosaic`);
    assert.equal(plan.shown, shown, `${count} photos paint ${shown} tiles`);
    assert.equal(plan.extra, extra, `${count} photos hide ${extra} behind the +N`);
    assert.equal(plan.areas, MOSAIC_AREAS[shown], 'and take the grid of their shown count');
  }
  assert.equal(MOSAIC_MAX_TILES, 4, 'four tiles is the ceiling (§2.11.3)');
  assert.deepEqual(MOSAIC_AREAS[2], [['a', 'b']], '2 → side by side, equal width');
  assert.deepEqual(MOSAIC_AREAS[3], [['a', 'b'], ['a', 'c']], '3 → one tall leading tile with two stacked beside it');
  assert.deepEqual(MOSAIC_AREAS[4], [['a', 'b'], ['c', 'd']], '4 → two by two');
  assert.deepEqual([0, 1, 2, 3].map(tileArea), ['a', 'b', 'c', 'd'], 'tiles take their areas in album order');
});

test('the mosaic block keeps a sane ratio instead of letting one tall photo set the height', () => {
  const bounds = { min: 0.8, max: 1.9 };
  const square = [1, 1, 1, 1];
  // two tiles side by side are each half the block's width at its full height,
  // so squares want a block twice as wide as it is tall
  assert.equal(mosaicRatio(square.slice(0, 2), 2, { min: 0.5, max: 4 }), 2, '2 up: the block is twice the tile');
  assert.equal(mosaicRatio(square.slice(0, 4), 4, { min: 0.5, max: 4 }), 1, '4 up: a cell is the block again');
  assert.equal(mosaicRatio(square.slice(0, 3), 3, { min: 0.5, max: 4 }), 1, '3 up: the stacked cells are the block again');
  // one panorama among squares must not set the shape (median, not mean), and
  // one portrait must not drag the block past the clamp
  assert.equal(mosaicRatio([1, 1, 8], 3, bounds), 1, 'a panorama among squares is outvoted');
  assert.equal(mosaicRatio([0.2, 0.25, 0.2], 3, bounds), bounds.min, 'a column of portraits stops at the floor');
  assert.equal(mosaicRatio([4, 4], 2, bounds), bounds.max, 'a pair of panoramas stops at the ceiling');
  assert.ok(mosaicRatio([], 4, bounds) >= bounds.min && mosaicRatio([], 4, bounds) <= bounds.max,
    'photos with no declared size fall inside the range rather than guessing');
});

// ── PRODUCT §2.12 — the reply target is whatever was tapped ────────────────

test('the reply target decides the re: line, and nothing else does', () => {
  const post = { link: 'https://t.me/waveloop_devlog/403', title: 'WaveLoop devlog', username: 'waveloop_devlog', text: 'Bench notes.' };
  const comment = { key: 'c1', link: 'https://t.me/tgs_ana_r/600', name: 'Ana Iliovic', text: 'Nice one.' };
  assert.equal(replyTarget(post, null).link, post.link, 'no selection replies to the post');
  assert.equal(replyTarget(post, comment).link, comment.link, 'a selected comment replies to THAT comment');
  assert.equal(replyTarget(post, comment).name, 'Ana Iliovic', 'and names it, for `Reply to <name>.`');
  // §6.5 does the formatting; §2.12's whole job is choosing the link
  assert.equal(serialiseComment(replyTarget(post, comment).link, 'Agreed.').split('\n')[0],
    're: https://t.me/tgs_ana_r/600', 'the written comment points at the comment');
  assert.equal(serialiseComment(replyTarget(post, null).link, 'Agreed.').split('\n')[0],
    're: https://t.me/waveloop_devlog/403', 'clearing it points at the post again');
});

// ── PRODUCT §2.15–§2.18 / PROTOCOL §7.1 — the safety lists ─────────────────

/** localStorage over a Map, so the record's persistence is testable in node. */
function fakeStorage(seed = null) {
  const map = new Map();
  if (seed !== null) map.set(MODERATION_KEY, typeof seed === 'string' ? seed : JSON.stringify(seed));
  return {
    map,
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, v),
  };
}

test('the safety record survives a cache bump and a sign-out, but not a different account', () => {
  // §7.1: `v` is the record's own version, not PRODUCT §2.3's cache schema, and
  // an unknown one is read as best it can be rather than dropped.
  const future = normaliseRecord({ v: 99, userId: 7, blocked: ['@TGS_Ana'], mutedFeeds: ['WaveLoop_devlog'], hidden: [{ key: 'WaveLoop_devlog/144', reason: 'Spam', at: '2026-09-04T21:02:11Z' }] }, 7);
  assert.equal(future.v, 99, 'an unknown version is kept, not discarded');
  assert.deepEqual(future.blocked, ['tgs_ana'], 'usernames normalise the way the card parser normalises them');
  assert.deepEqual(future.mutedFeeds, ['waveloop_devlog'], '…so a list cannot miss @TGS_Ana and leave a hole in the filter');
  assert.equal(future.hidden[0].key, 'waveloop_devlog/144', 'and the target key is lowercased the same way');

  // sign-out keeps it FOR THE SAME ACCOUNT
  const same = normaliseRecord({ v: 1, userId: 176543210, blocked: ['tgs_ana'], mutedFeeds: [], hidden: [] }, 176543210);
  assert.deepEqual(same.blocked, ['tgs_ana'], 'the same account keeps its lists across a sign-out');
  // a different account on a shared device inherits nothing
  const other = normaliseRecord({ v: 1, userId: 176543210, blocked: ['tgs_ana'], mutedFeeds: ['x_feed'], hidden: [{ key: 'a/1', reason: 'Spam', at: '' }] }, 42);
  assert.deepEqual([other.blocked, other.mutedFeeds, other.hidden], [[], [], []], 'a different account starts empty — that list is someone else’s judgement');
  assert.equal(other.userId, 42, 'and the record becomes theirs');
  // a record written before the account was known is adopted, not wiped
  const adopted = normaliseRecord({ v: 1, userId: null, blocked: ['tgs_ana'], mutedFeeds: [], hidden: [] }, 42);
  assert.deepEqual(adopted.blocked, ['tgs_ana'], 'a record with no id yet is adopted by the first account that reads it');
});

test('adopt repaints only when it replaced someone else’s lists', () => {
  let repaints = 0;
  const stamped = new SafetyLists({ storage: fakeStorage({ v: 1, userId: null, blocked: ['tgs_ana'], mutedFeeds: [], hidden: [] }), onChange: () => { repaints += 1; } });
  stamped.adopt(42);
  assert.deepEqual(stamped.blocked, ['tgs_ana'], 'stamping an id keeps the lists');
  assert.equal(repaints, 0, 'and changes nothing anyone can see, so nothing repaints');

  let wiped = 0;
  const foreign = new SafetyLists({ storage: fakeStorage({ v: 1, userId: 7, blocked: ['tgs_ana'], mutedFeeds: [], hidden: [] }), onChange: () => { wiped += 1; } });
  foreign.adopt(42);
  assert.deepEqual(foreign.blocked, [], 'a foreign record is replaced');
  assert.equal(wiped, 1, 'and that one does repaint');
});

test('the filter drops exactly what §2.18 says it drops, and mute only on the main feed', () => {
  const storage = fakeStorage();
  const lists = new SafetyLists({ storage });
  const anaPost = { node: 'tgs_ana', username: 'ana_notes', link: 'https://t.me/ana_notes/12' };
  const minePost = { node: 'tgs_elijah', username: 'waveloop_devlog', link: 'https://t.me/waveloop_devlog/144' };
  const orphan = { node: null, username: 'waveloop_devlog', link: 'https://t.me/waveloop_devlog/145' };

  assert.ok([anaPost, minePost, orphan].every((p) => keepsPost(p, lists)), 'a fresh install filters nothing');

  lists.block('@TGS_Ana');
  assert.equal(keepsPost(anaPost, lists), false, 'a blocked node’s post is dropped, whatever case the card wrote them in');
  assert.equal(keepsPost(minePost, lists), true, 'and nobody else moves');
  assert.equal(keepsComment({ node: 'tgs_ana', link: 'https://t.me/tgs_ana_r/600' }, lists), false, 'their comments go too');

  lists.muteFeed('waveloop_devlog');
  assert.equal(keepsPost(minePost, lists, { applyMute: true }), false, 'a muted feed leaves the merged feed');
  assert.equal(keepsPost(minePost, lists), true, '…and stays complete on its own screen (§2.17)');

  lists.hide('https://t.me/waveloop_devlog/145', 'Spam');
  assert.equal(keepsPost(orphan, lists), false, 'a reported post is hidden everywhere, mute or no mute');
  assert.equal(keepsComment({ node: 'tgs_bob', link: 'https://t.me/waveloop_devlog/145' }, lists), false,
    'and one key filters a hidden post and a hidden comment alike (PROTOCOL §6.2)');
  assert.equal(lists.hidden[0].reason, 'Spam', 'the reason is stored verbatim, so Settings can say what was reported');
  assert.match(lists.hidden[0].at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, 'at is ISO 8601 UTC');

  // the record on disk is what a rebuilt store reads back — the "survives" part
  const reread = new SafetyLists({ storage });
  assert.deepEqual(reread.blocked, ['tgs_ana'], 'the record round-trips through storage');
  assert.equal(reread.isHidden('waveloop_devlog/145'), true, 'hidden keys included');

  lists.unblock('tgs_ana');
  lists.unmuteFeed('waveloop_devlog');
  lists.unhide('waveloop_devlog/145');
  assert.ok([anaPost, minePost, orphan].every((p) => keepsPost(p, lists, { applyMute: true })), 'and every undo puts it back');
});

test('the report email is §2.15’s, to the byte', () => {
  const subject = reportSubject('Nudity or sexual content');
  assert.equal(subject, 'tgsocial report — Nudity or sexual content', 'the subject is the reason, after an em dash');
  assert.deepEqual(REPORT_REASONS, [
    'Spam', 'Nudity or sexual content', 'Violence or threats', 'Hate or harassment',
    'Child safety', 'Illegal content', 'Something else',
  ], 'seven reasons, this order, every platform');

  const body = reportBody({
    reason: 'Spam',
    link: 'https://t.me/waveloop_devlog/144',
    channel: 'waveloop_devlog',
    messageId: 144,
    node: 'tgs_elijah',
    kind: 'post',
    app: 'tgsocial 1.0.0 (12) · iOS',
  });
  assert.equal(body, 'Reason: Spam\n'
    + 'Link: https://t.me/waveloop_devlog/144\n'
    + 'Channel: @waveloop_devlog\n'
    + 'Message: 144\n'
    + 'Node: @tgs_elijah\n'
    + 'Kind: post\n'
    + 'App: tgsocial 1.0.0 (12) · iOS\n'
    + '\nAnything you want to add:\n\n', 'and the body ends on the blank line the cursor lands in');
  assert.ok(body.endsWith('\n\n'), 'that blank line is not incidental');

  const unattributed = reportBody({ reason: 'Spam', link: 'https://t.me/x/1', channel: 'x', messageId: 1, node: null, kind: 'comment', app: 'tgsocial 1.0.0 (1) · Web' });
  assert.match(unattributed, /^Node: unattributed$/m, 'a post nobody is attributed for says so');
  assert.match(unattributed, /^Kind: comment$/m, 'and a comment says which it is');
  // nothing about the reader, and nothing about any list, ever leaves
  assert.ok(!/blocked|muted|hidden/i.test(body), 'the email carries a link and a reason, and nothing about the lists');

  const url = mailtoUrl(CONTACT_ADDRESS, subject, body);
  assert.ok(url.startsWith('mailto:elijah@lucianlabs.ca?'), 'addressed to the published address');
  const parsed = new URL(url);
  assert.equal(parsed.searchParams.get('subject'), subject, 'subject survives percent-encoding');
  assert.equal(parsed.searchParams.get('body'), body, 'and so does every newline in the body');
});

// ── PRODUCT §2.22 the demo ──────────────────────────────────────────────────

/**
 * §2.22.4's build-time check, and the reason it is a check rather than a
 * discipline: "the demo is a different object, not a mode… `DemoRepo` imports
 * nothing from the TDLib layer". A boolean checked at each call site has
 * branches that can be missed; an import graph that cannot reach js/td.js has
 * nothing to miss. This walks the whole closure rather than grepping the four
 * files, because one hop through a module that DOES import td.js would put a
 * client back within reach.
 */
test('§2.22.4: nothing the demo imports can reach js/td.js', async () => {
  const root = join(here, '..', 'js');
  const seen = new Set();
  const trail = new Map();
  const visit = async (file, via) => {
    if (seen.has(file)) return;
    seen.add(file);
    trail.set(file, via);
    const src = await readFile(file, 'utf8');
    for (const m of src.matchAll(/^\s*import\s[^'"]*['"]([^'"]+)['"]/gm)) {
      const spec = m[1];
      if (!spec.startsWith('.')) continue;
      await visit(join(dirname(file), spec), file);
    }
  };
  for (const entry of ['demo/repo.js', 'demo/world.js', 'demo/media.js', 'demo/mode.js']) {
    await visit(join(root, entry), null);
  }
  const td = join(root, 'td.js');
  const path = [];
  for (let at = td; at; at = trail.get(at)) path.push(at.slice(root.length + 1));
  assert.ok(!seen.has(td), `the demo must not reach td.js — ${path.reverse().join(' → ')}`);
  assert.ok(seen.has(join(root, 'demo', 'world.js')) && seen.has(join(root, 'repo.js')),
    'and the walk really did follow imports (js/repo.js is in the closure, for FeedSession)');
});

/**
 * §2.22.1's reader card is given in PROTOCOL §2's wire format on purpose: three
 * builds parse the same seven lines, so the graph they draw is the same graph.
 * If this ever stops parsing, the demo opens on a reader with no follows and
 * every count in §2.22.5's sheet is wrong.
 */
test('§2.22.1: the reader card is a PROTOCOL §2 vector the parser agrees with', async () => {
  const src = await readFile(join(here, '..', 'js', 'demo', 'world.js'), 'utf8');
  const m = /export const READER_CARD_TEXT = \[([\s\S]*?)\]\.join\('\\n'\);/.exec(src);
  assert.ok(m, 'READER_CARD_TEXT is a literal in js/demo/world.js');
  const text = [...m[1].matchAll(/'((?:[^'\\]|\\.)*)'/g)].map((q) => q[1].replace(/\\'/g, "'")).join('\n');
  const card = parseCard(text);
  assert.ok(card, 'it is a v1 card');
  assert.equal(card.name, 'Demo Reader');
  assert.equal(card.bio, 'Looking around.');
  assert.equal(card.public, false, 'public: no — so the reader is absent from the Directory (§2.4)');
  assert.deepEqual(card.feeds, ['demo_you_notes']);
  assert.deepEqual(card.follows, ['tgs_demo_wren', 'tgs_demo_mox', 'tgs_demo_juno', 'tgs_demo_pell']);
  assert.equal(card.replies, 'tgs_demo_you_r');
});

/**
 * §2.22.1's follow graph, run through the app's own ranking rather than
 * re-listed here: `DIRECT · 4`, `+1 · 7`, and the order Explore's NEARBY paints
 * — arto, orrin, sable (2 mutuals each, username ascending), then bly, crate,
 * hask, ilka. Specified because otherwise three platforms produce three orders.
 */
test('§2.22.1: the follow graph ranks to §2.4’s NEARBY, in that order', () => {
  const follows = {
    tgs_demo_wren: ['tgs_demo_mox', 'tgs_demo_arto', 'tgs_demo_sable', 'tgs_demo_ilka'],
    tgs_demo_mox: ['tgs_demo_juno', 'tgs_demo_arto', 'tgs_demo_bly'],
    tgs_demo_juno: ['tgs_demo_pell', 'tgs_demo_wren', 'tgs_demo_orrin'],
    tgs_demo_pell: ['tgs_demo_sable', 'tgs_demo_hask', 'tgs_demo_orrin', 'tgs_demo_crate'],
  };
  const mine = Object.keys(follows);
  const cards = new Map(Object.entries(follows).map(([u, f]) => [u, { follows: f }]));
  const ranked = rankPlusOne('tgs_demo_you', mine, cards);
  assert.equal(mine.length, 4, 'DIRECT · 4');
  assert.equal(ranked.length, 7, '+1 · 7');
  assert.deepEqual(ranked.map((r) => r.username),
    ['tgs_demo_arto', 'tgs_demo_orrin', 'tgs_demo_sable', 'tgs_demo_bly', 'tgs_demo_crate', 'tgs_demo_hask', 'tgs_demo_ilka']);
  assert.deepEqual(ranked.slice(0, 3).map((r) => r.mutual), [2, 2, 2]);
});

/**
 * §2.22.1: reactions and views derive from the message id so all three builds
 * print the same figures. Held against the fifteen ids in the post table,
 * because the property that matters is that none of them lands on zero — a
 * post with no reactions would silently drop the footer's first half.
 */
test('§2.22.1: reactions and views derive from the id, and none of them is zero', () => {
  const ids = [147, 101, 224, 72, 17, 2, 95, 144, 219, 71, 12, 88, 203, 58, 1];
  for (const id of ids) {
    const reactions = (id * 7) % 23;
    const views = 60 + ((id * 37) % 900);
    assert.ok(reactions > 0, `id ${id} would print no reactions`);
    assert.ok(views >= 60 && views < 960, `id ${id} views out of range`);
  }
  assert.equal((144 * 7) % 23, 19, 'post 144 carries 19 reactions on every platform');
  assert.equal(60 + ((144 * 37) % 900), 888, 'and 888 views');
});
