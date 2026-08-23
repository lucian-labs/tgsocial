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
  compactCount,
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
    });
  }
}

for (const c of vectors.compactCount.cases) {
  test(`compactCount: ${c.in}`, () => {
    assert.equal(compactCount(c.in), c.out);
  });
}

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
