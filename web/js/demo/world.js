/* demo/world.js — the fixture world of PRODUCT §2.22.1, built in memory.
 *
 * Fifteen invented nodes, six feeds carrying fifteen posts, eleven comments in
 * two threads. Nothing here is captured from a real channel: `web/test/fixtures/`
 * holds real people's posts and is deliberately not reused.
 *
 * Two things make this the SAME world on iOS, Android and here rather than
 * three worlds that look alike:
 *   - times are offsets from the moment the demo starts, never dates, so the
 *     §2.3 relative-time ladder reads correctly in a review a year from now;
 *   - reactions and views derive from the message id — `(id × 7) mod 23` and
 *     `60 + (id × 37) mod 900` — instead of being invented per row.
 *
 * Ids are TDLib-shaped (`serverId × 1048576`) so `deepLink`, `serverMessageId`
 * and PROTOCOL §7.1's hidden key all behave exactly as they do in a real
 * session; nothing downstream can tell the difference, which is the point.
 */
import { attributionNode, deepLink, nodeDescription, parseCard, serialiseCard, usernameKey } from '../protocol.js';
import { clipUrl, documentUrl, minithumb, plate, recordClip, waveformBytes } from './media.js';

/** PROTOCOL §2, verbatim — the vector the three builds' parsers have to agree on. */
export const READER_CARD_TEXT = [
  'tgsocial v1',
  'name: Demo Reader',
  'bio: Looking around.',
  'public: no',
  'feeds: @demo_you_notes',
  'follows: @tgs_demo_wren @tgs_demo_mox @tgs_demo_juno @tgs_demo_pell',
  'replies: @tgs_demo_you_r',
].join('\n');

export const READER = 'tgs_demo_you';

/**
 * The cast. `follows` is §2.22.1's graph and nothing else derives from it —
 * Explore's NEARBY, Graph's two lists and PROTOCOL §6.3's comment scope are
 * all the app's own walks over these five lines.
 */
const NODES = [
  { u: 'tgs_demo_wren', name: 'Wren Alderiss', bio: 'Tide clocks and bad solder.', feeds: ['demo_tidewright', 'demo_wren_bench'], follows: ['tgs_demo_mox', 'tgs_demo_arto', 'tgs_demo_sable', 'tgs_demo_ilka'] },
  { u: 'tgs_demo_mox', name: 'Mox Petrakis', bio: 'Field recordings. Mostly rain.', feeds: ['demo_slow_radio'], follows: ['tgs_demo_juno', 'tgs_demo_arto', 'tgs_demo_bly'] },
  { u: 'tgs_demo_juno', name: 'Juno Bell-Okafor', bio: 'Ceramics, mostly failures.', feeds: ['demo_kiln_log'], follows: ['tgs_demo_pell', 'tgs_demo_wren', 'tgs_demo_orrin'] },
  { u: 'tgs_demo_pell', name: 'Pell Nakagawa', bio: 'Letterpress, one press.', feeds: ['demo_press_run'], follows: ['tgs_demo_sable', 'tgs_demo_hask', 'tgs_demo_orrin', 'tgs_demo_crate'] },
  { u: 'tgs_demo_arto', name: 'Arto Vansi', bio: 'Trail cameras on the creek.', feeds: ['demo_creek_cam'], follows: [] },
  { u: 'tgs_demo_orrin', name: 'Orrin Baptiste', bio: 'Bread, weather, complaints.', feeds: ['demo_proof_box'], follows: [] },
  { u: 'tgs_demo_sable', name: 'Sable Quiring', bio: 'Maps nobody asked for.', feeds: ['demo_paper_maps'], follows: [] },
  { u: 'tgs_demo_bly', name: 'Bly Toussaint', bio: 'Night sky, cheap lens.', feeds: ['demo_dark_sky'], follows: [] },
  { u: 'tgs_demo_hask', name: 'Hask Oyelaran', bio: 'Fixes the ferry radio.', feeds: ['demo_ferry_net'], follows: [] },
  { u: 'tgs_demo_ilka', name: 'Ilka Ferreira', bio: 'Bike frames.', feeds: ['demo_frame_jig'], follows: [] },
  { u: 'tgs_demo_crate', name: 'Crate Mailer', bio: 'Free crates. Ask me.', feeds: ['demo_free_crates'], follows: [] },
  { u: 'tgs_demo_lume', name: 'Lume Adeyemi', bio: 'Neon repair.', feeds: ['demo_neon_bench'], follows: [] },
  { u: 'tgs_demo_noor', name: 'Noor Salk', bio: 'Weather balloons.', feeds: ['demo_balloon_log'], follows: [] },
  { u: 'tgs_demo_veda', name: 'Veda Marchetti', bio: 'Sails.', feeds: ['demo_sail_loft'], follows: [] },
];

/** Channel titles. Every one starts `demo_`, so a cropped screenshot still says so. */
const FEED_TITLES = {
  demo_you_notes: 'Notes',
  demo_tidewright: 'Tidewright',
  demo_wren_bench: "Wren's bench",
  demo_slow_radio: 'Slow Radio',
  demo_kiln_log: 'Kiln log',
  demo_press_run: 'Press run',
  demo_creek_cam: 'Creek cam',
  demo_proof_box: 'Proof box',
  demo_paper_maps: 'Paper maps',
  demo_dark_sky: 'Dark sky',
  demo_ferry_net: 'Ferry net',
  demo_frame_jig: 'Frame jig',
  demo_free_crates: 'Free crates',
  demo_neon_bench: 'Neon bench',
  demo_balloon_log: 'Balloon log',
  demo_sail_loft: 'Sail loft',
};

/**
 * §2.22.1: two feeds carry the `tgsocial: @<node>` backlink of PROTOCOL §3 and
 * the rest do not, so both `Verified` states are on screen at once.
 */
const BACKLINKED = new Set(['demo_tidewright', 'demo_kiln_log']);

/**
 * §2.22: node and channel avatars are the initial over a seeded tint — §2.3's
 * THIRD fallback, reached honestly, since fixture channels have no photo —
 * except these two, which carry a generated plate so §2.3's first branch
 * paints too. No fixture carries a photograph of a person.
 */
const PLATED_CHANNELS = new Set(['demo_tidewright', 'demo_slow_radio']);

const MINUTE = 60;
const HOUR = 3600;
const DAY = 86400;

/** The six main-feed sources: the reader's feed plus the five of the four they follow. */
export const MAIN_SOURCES = ['demo_you_notes', 'demo_tidewright', 'demo_wren_bench', 'demo_slow_radio', 'demo_kiln_log', 'demo_press_run'];

/**
 * §2.22.1's post table, newest first. `age` is seconds before the demo opened,
 * and the fifteen of them hit every rung of §2.3's ladder — now, 6m, 22m, 2h,
 * 5h, 9h, 14h, 1d, 2d, 3d, 6d, 2w, 5w, 4mo, 2y — so a wrong rounding is
 * visible without arithmetic.
 */
const POSTS = [
  { channel: 'demo_tidewright', id: 147, age: 40, text: 'Tide clock is off by nine minutes and I know exactly why.' },
  { channel: 'demo_slow_radio', id: 101, age: 6 * MINUTE, text: 'Three in the morning, and it did not let up.', media: { kind: 'audio', duration: 222, title: 'Rain on the shed roof', performer: 'Slow Radio' } },
  { channel: 'demo_kiln_log', id: 224, age: 22 * MINUTE, text: 'Glaze tests. Two of these are the same glaze.', media: { kind: 'album', aspects: [[4, 3], [3, 4], [1, 1], [16, 9]] } },
  { channel: 'demo_press_run', id: 72, age: 2 * HOUR, text: 'Found this while cleaning out a drawer.', preview: { url: 'https://example.com/em-dash', siteName: 'example.com', title: 'A Short History of the Em Dash', description: 'Why the long dash outlived the metal it was cast in.' } },
  { channel: 'demo_wren_bench', id: 17, age: 5 * HOUR, text: 'Someone scanned the whole 1971 table. All of it.', media: { kind: 'document', fileName: 'tide-table-1971.pdf', size: 2516582 } },
  { channel: 'demo_you_notes', id: 2, age: 9 * HOUR, text: 'Testing the demo. This one is mine.' },
  { channel: 'demo_slow_radio', id: 95, age: 14 * HOUR, text: 'The ferry leaving in fog.', media: { kind: 'video', duration: 18, w: 640, h: 360 } },
  { channel: 'demo_tidewright', id: 144, age: DAY, text: 'New moon. Everything in the harbour is six inches lower than it should be.' },
  { channel: 'demo_kiln_log', id: 219, age: 2 * DAY, text: 'Failure on the left.', media: { kind: 'album', aspects: [[1, 1]] } },
  { channel: 'demo_press_run', id: 71, age: 3 * DAY, media: { kind: 'voice', duration: 47 } },
  { channel: 'demo_wren_bench', id: 12, age: 6 * DAY, text: 'Ordered the wrong solder again.' },
  { channel: 'demo_slow_radio', id: 88, age: 14 * DAY, media: { kind: 'animation', duration: 2, w: 480, h: 360 } },
  { channel: 'demo_kiln_log', id: 203, age: 35 * DAY, text: 'Kiln is at cone six and holding.' },
  { channel: 'demo_press_run', id: 58, age: 120 * DAY, text: 'The press is level. It only took a year.' },
  { channel: 'demo_you_notes', id: 1, age: 730 * DAY, text: 'First post.' },
];

/**
 * §2.22.1: the +1 nodes' feeds are deliberately absent from the main feed, and
 * "a reviewer who opens arto's profile finds posts they never saw in Feed" —
 * so those feeds are not empty, they are simply not merged. Three each, text
 * only: their job is to prove the merge is the follow graph, not to be
 * another media matrix.
 */
const OFF_FEED_POSTS = {
  demo_creek_cam: ['Deer, 04:12. Same deer.', 'The creek is up again.', 'Card full. New card.'],
  demo_proof_box: ['Overproofed. Baking it anyway.', 'Rain all week, dough loves it.', 'Third loaf is the one.'],
  demo_paper_maps: ['Redrew the harbour approach.', 'Contours at two metres now.', 'Nobody asked for this one either.'],
  demo_dark_sky: ['Twenty seconds, wide open, still nothing.', 'Clear at last.', 'The lens is the limit, not the sky.'],
  demo_ferry_net: ['Radio back up on channel 16.', 'Antenna corroded straight through.', 'Ferry ran on time. Once.'],
  demo_frame_jig: ['Brazed the seat cluster twice.', 'Alignment is off by a millimetre.', 'Frame is in paint.'],
  demo_free_crates: ['FREE CRATES. Message me.', 'More crates. Still free.', 'Crates crates crates.'],
  demo_neon_bench: ['Bent a new letter R today.', 'The transformer was the problem.', 'It hums, but it lights.'],
  demo_balloon_log: ['Launched at dawn, lost it by nine.', 'Sonde recovered from a hedge.', 'Winds aloft, as promised.'],
  demo_sail_loft: ['New main is cut.', 'Three days of seaming.', 'It sets flat. Finally.'],
};

const OFF_FEED_AGES = [3 * HOUR, 2 * DAY, 21 * DAY];

/**
 * §2.22.1's eleven comments (PROTOCOL §6.2). `target` is a `<channel>/<id>`
 * pair; the `re:` line it becomes is what the tree is built from, so the
 * 3-deep chain on 144 and the 6-deep chain on 219 are the app's own resolution
 * of these pointers and not a shape drawn here.
 */
const COMMENTS = [
  { channel: 'demo_mox_r', node: 'tgs_demo_mox', id: 31, age: 22 * HOUR, target: 'demo_tidewright/144', text: 'Six inches is the whole reason I stopped trusting that gauge.' },
  { channel: 'demo_wren_r', node: 'tgs_demo_wren', id: 40, age: 21 * HOUR, target: 'demo_mox_r/31', text: 'The gauge is fine. The pier moved.' },
  { channel: 'demo_mox_r', node: 'tgs_demo_mox', id: 32, age: 20 * HOUR, target: 'demo_wren_r/40', text: 'Then the pier moved.' },
  { channel: 'demo_juno_r', node: 'tgs_demo_juno', id: 9, age: 19 * HOUR, target: 'demo_tidewright/144', text: "Photograph the pier or it didn't happen." },
  { channel: 'demo_crate_r', node: 'tgs_demo_crate', id: 12, age: 18 * HOUR, target: 'demo_tidewright/144', text: 'FREE CRATES today only, message me for the link.' },
  { channel: 'demo_wren_r', node: 'tgs_demo_wren', id: 41, age: 47 * HOUR, target: 'demo_kiln_log/219', text: 'Which one is the failure?' },
  { channel: 'demo_juno_r', node: 'tgs_demo_juno', id: 10, age: 46 * HOUR, target: 'demo_wren_r/41', text: 'Both.' },
  { channel: 'demo_wren_r', node: 'tgs_demo_wren', id: 42, age: 45 * HOUR, target: 'demo_juno_r/10', text: 'Then it worked.' },
  { channel: 'demo_juno_r', node: 'tgs_demo_juno', id: 11, age: 44 * HOUR, target: 'demo_wren_r/42', text: 'It cracked.' },
  { channel: 'demo_mox_r', node: 'tgs_demo_mox', id: 33, age: 43 * HOUR, target: 'demo_juno_r/11', text: 'It always cracks.' },
  { channel: 'demo_wren_r', node: 'tgs_demo_wren', id: 43, age: 42 * HOUR, target: 'demo_mox_r/33', text: 'Agreed.' },
];

/** §2.22.1 — derived from the id so all three builds print the same figures. */
export function reactionsFor(id) {
  return (id * 7) % 23;
}

export function viewsFor(id) {
  return 60 + ((id * 37) % 900);
}

const REACTION_EMOJI = ['👍', '🔥', '👀', '🌊', '🫡'];

/** TDLib shifts server ids; the demo does too, so nothing downstream needs to know. */
const SHIFT = 1048576;

function chatIdFor(channel) {
  // stable, negative, and unlike any real chat id we could collide with
  let h = 0;
  for (let i = 0; i < channel.length; i += 1) h = (h * 31 + channel.charCodeAt(i)) >>> 0;
  return -1000000000000 - (h % 1000000000);
}

function lazyUrl(file, make) {
  Object.defineProperty(file, 'url', { get: make, enumerable: true, configurable: true });
  return file;
}

function photoSizes(key, w, h) {
  return [{ w, h, file: lazyUrl({ id: null, size: 0 }, () => plate(key, w, h)) }];
}

function mediaFor(spec, channel, serverId) {
  const key = (n) => `${channel}/${serverId}·${n}`;
  if (spec.kind === 'album') {
    return spec.aspects.map(([aw, ah], i) => {
      const w = aw >= ah ? 1024 : Math.round(1024 * (aw / ah));
      const h = aw >= ah ? Math.round(1024 * (ah / aw)) : 1024;
      return { kind: 'photo', sizes: photoSizes(key(i + 1), w, h), mini: minithumb(key(i + 1), w, h), messageId: (serverId + i) * SHIFT };
    });
  }
  if (spec.kind === 'audio') {
    return [{
      kind: 'audio',
      file: lazyUrl({ id: null, size: 0 }, () => clipUrl(key(1), spec.duration)),
      duration: spec.duration,
      title: spec.title,
      performer: spec.performer,
      mime: 'audio/wav',
      fileName: `${spec.title}.wav`,
      cover: null,
      messageId: serverId * SHIFT,
    }];
  }
  if (spec.kind === 'voice') {
    return [{
      kind: 'voice',
      file: lazyUrl({ id: null, size: 0 }, () => clipUrl(key(1), spec.duration)),
      duration: spec.duration,
      waveform: waveformBytes(key(1)),
      mime: 'audio/wav',
      messageId: serverId * SHIFT,
    }];
  }
  if (spec.kind === 'video' || spec.kind === 'animation') {
    const { w, h } = spec;
    return [{
      kind: spec.kind,
      file: lazyUrl({ id: null, size: 0 }, () => recordClip(key(1), spec.duration, w, h)),
      duration: spec.duration,
      w,
      h,
      thumb: { w, h, file: lazyUrl({ id: null, size: 0 }, () => plate(key(1), w, h)) },
      mini: minithumb(key(1), w, h),
      mime: 'video/webm',
      fileName: spec.kind === 'video' ? 'ferry.webm' : 'loop.webm',
      streamable: true,
      messageId: serverId * SHIFT,
    }];
  }
  if (spec.kind === 'document') {
    return [{
      kind: 'document',
      // no mime, so §2.11's document row is a Download and never the PDF
      // iframe: `frame-src 'none'` is the app's own CSP (index.html)
      file: lazyUrl({ id: null, size: spec.size }, () => documentUrl(key(1), spec.fileName)),
      fileName: spec.fileName,
      mime: '',
      thumb: null,
      mini: null,
      messageId: serverId * SHIFT,
    }];
  }
  return [];
}

/**
 * Build the world. `now` is the moment the demo opened; every age in the
 * tables above is an offset from it.
 */
export function buildWorld(now = Date.now()) {
  const nowS = Math.floor(now / 1000);
  const feeds = new Map();
  const cards = {};

  const readerCard = parseCard(READER_CARD_TEXT);
  if (!readerCard) throw new Error('The demo reader card does not parse.');

  const addNode = (username, card, title) => {
    cards[usernameKey(username)] = {
      username,
      title,
      card,
      newer: false,
      missing: false,
      chatId: chatIdFor(username),
      supergroupId: Math.abs(chatIdFor(username)) % 100000,
      photo: null,
      description: nodeDescription(card),
      pinnedMessageId: SHIFT,
      fetchedAt: now,
    };
  };

  addNode(READER, readerCard, 'Demo Reader');
  for (const n of NODES) {
    const card = parseCard(serialiseCard({
      name: n.name,
      bio: n.bio,
      link: null,
      public: true,
      feeds: n.feeds,
      follows: n.follows,
      replies: `${n.u.replace(/^tgs_/, '')}_r`,
    }));
    addNode(n.u, card, n.name);
  }

  const addFeed = (channel, node) => {
    const title = FEED_TITLES[channel] ?? `@${channel}`;
    const description = BACKLINKED.has(channel) ? `${title}. tgsocial: @${node}` : `${title}.`;
    feeds.set(usernameKey(channel), {
      chatId: chatIdFor(channel),
      username: channel,
      title,
      description,
      node,
      photo: PLATED_CHANNELS.has(channel)
        ? lazyUrl({ id: null, size: 0 }, () => plate(`${channel}/photo`, 256, 256))
        : null,
      canPost: false,
      memberCount: null,
    });
  };
  addFeed('demo_you_notes', READER);
  for (const n of NODES) for (const f of n.feeds) addFeed(f, n.u);

  /**
   * PRODUCT §2.3's rule, not the channel's owner: the node a feed reaches the
   * reader THROUGH. So `demo_creek_cam` — arto's, and arto is at +1 — is
   * unattributed here and its card falls back to the channel, which is what
   * §2.22.1 means by the merge being the follow graph.
   */
  const attributionFor = (channel) => {
    const node = attributionNode(channel, READER, readerCard, (u) => cards[usernameKey(u)]?.card ?? null);
    if (!node) return null;
    const entry = cards[usernameKey(node)];
    return entry ? { username: entry.username, name: entry.card?.name || `@${entry.username}`, photo: entry.photo } : null;
  };

  const buildPost = ({ channel, id, age, text, media, preview }) => {
    const src = feeds.get(usernameKey(channel));
    const attr = attributionFor(channel);
    const album = media ? mediaFor(media, channel, id) : [];
    const count = reactionsFor(id);
    const post = {
      key: `${src.chatId}:${id * SHIFT}`,
      id: id * SHIFT,
      chatId: src.chatId,
      username: src.username,
      title: src.title,
      avatar: src.photo,
      node: attr?.username ?? null,
      nodeName: attr?.name ?? null,
      nodeAvatar: attr?.photo ?? null,
      date: nowS - age,
      text: text ?? '',
      entities: [],
      media: album[0] ?? null,
      album,
      preview: null,
      views: viewsFor(id),
      reactions: count > 0 ? [{ emoji: REACTION_EMOJI[id % REACTION_EMOJI.length], count }] : [],
      forwardedFrom: null,
      link: deepLink(src.username, id * SHIFT),
    };
    if (preview) {
      post.preview = {
        ...preview,
        thumb: photoSizes(`${channel}/${id}·link`, 480, 480),
        mini: minithumb(`${channel}/${id}·link`, 480, 480),
      };
    }
    return post;
  };

  const posts = POSTS.map(buildPost);
  for (const [channel, bodies] of Object.entries(OFF_FEED_POSTS)) {
    bodies.forEach((text, i) => {
      posts.push(buildPost({ channel, id: 40 + i, age: OFF_FEED_AGES[i], text }));
    });
  }
  posts.sort((a, b) => b.date - a.date || b.id - a.id);

  const comments = COMMENTS.map((c) => {
    const entry = cards[usernameKey(c.node)];
    const [tChannel, tId] = c.target.split('/');
    const chatId = chatIdFor(c.channel);
    return {
      key: `${chatId}:${c.id * SHIFT}`,
      id: c.id * SHIFT,
      chatId,
      channel: c.channel,
      node: entry.username,
      name: entry.card?.name || `@${entry.username}`,
      avatar: entry.photo,
      date: nowS - c.age,
      target: `https://t.me/${tChannel}/${tId}`,
      targetKey: `${tChannel.toLowerCase()}/${tId}`,
      text: c.text,
      entities: [],
      media: null,
      album: [],
      preview: null,
      link: deepLink(c.channel, c.id * SHIFT),
      mine: false,
    };
  });

  return { cards, feeds, posts, comments, readerCard, startedAt: now };
}

/**
 * §2.22.1's two procedural clips, started when the demo opens because
 * MediaRecorder records in real time (js/demo/media.js). Failure is silent and
 * total: the blocks keep their posters and the demo carries on.
 */
export function primeClips() {
  for (const p of POSTS) {
    if (p.media?.kind !== 'video' && p.media?.kind !== 'animation') continue;
    const url = mediaFor(p.media, p.channel, p.id)[0].file.url;
    if (url && typeof url.catch === 'function') url.catch(() => null);
  }
}
