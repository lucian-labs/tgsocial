/* preview.js — Telegram's public preview (`t.me/s/<channel>`) → tgsocial model.
 *
 * PUBLIC.md §3. One module, used by every public surface. Pure: an HTML string
 * in, tgsocial model out. No network, no app state, no DOM beyond DOMParser —
 * the document it builds is inert (DOMParser never runs scripts, never loads
 * subresources) and nothing from it is ever adopted into the live page.
 *
 *   parsePreview(html, channel)
 *     → { channel: { username, title, photo, description, verifiedFor },
 *         posts: [Post], card, nextBefore, unavailable }
 *
 * `Post` is the same shape `repo.toPost()` builds, so PRODUCT §2.3's post card
 * renders a preview post and a TDLib post with the same code. The one
 * difference is inside the file slots: a preview file is `{ url }` (Telegram
 * serves it straight off its CDN) where a TDLib file is `{ id, uniqueId }`.
 * `post.source === 'preview'` is what tells the renderer which it is holding.
 *
 * SANITISATION IS THE POINT. Every string here is untrusted third-party HTML.
 * This module returns TEXT AND STRUCTURED ENTITIES, NEVER HTML — there is no
 * markup anywhere in the result, so there is nothing for a renderer to inject.
 * `<script>`/`<style>` subtrees are dropped outright, every URL (link, media,
 * thumbnail) goes through `safeUrl()` which allows only http/https (plus
 * mailto/tg for links) and therefore drops `javascript:` and `data:`, and the
 * renderer builds nodes with `document.createTextNode` — no `innerHTML` of
 * preview content anywhere in this codebase.
 *
 * DEFENSIVE BY CONSTRUCTION. Telegram's markup is not a contract: an
 * unrecognised block degrades to a post carrying whatever text it could find,
 * never a thrown error, and a page that parses to zero posts is reported
 * `unavailable` rather than as an empty channel. `web/test/fixtures/` holds
 * real fetched pages so a markup change fails a test instead of a page.
 */
import { cardVersion, parseCard } from '../protocol.js';

/** Schemes a link out of the preview may carry. Everything else — javascript:, data:, file: — is dropped. */
const LINK_SCHEMES = new Set(['http:', 'https:', 'mailto:', 'tg:']);
/** Schemes a picture/video/audio URL may carry. Stricter: no mailto, no tg, no data. */
const MEDIA_SCHEMES = new Set(['http:', 'https:']);

/**
 * Hosts that serve Telegram's own file bytes. A document row is the one media
 * kind whose action hands the reader a URL to *go to*, so its host is checked
 * against this list and anything else degrades to a summary — otherwise a
 * hostile channel writes `href="https://evil.example/pwn.exe"` on a row
 * labelled `invoice.pdf` and the reader's Download button walks them off
 * tgsocial onto a page they never saw the address of.
 */
const FILE_HOSTS = /(^|\.)(telesco\.pe|telegram-cdn\.org|telegram\.org|tdesktop\.com)$/i;

const isTelegramFileHost = (url) => {
  try {
    return FILE_HOSTS.test(new URL(url).hostname);
  } catch {
    return false;
  }
};

const previewBase = (channel) => `https://t.me/s/${encodeURIComponent(channel || '')}`;

/**
 * Absolute, scheme-checked URL, or null. Relative hrefs resolve against the
 * preview page they came from (Telegram emits `?q=%23tag` for hashtags), which
 * is also what makes a scheme check meaningful — a bare `javascript:alert(1)`
 * parses as a URL with that scheme and is refused here.
 */
function safeUrl(raw, base, schemes = LINK_SCHEMES) {
  if (typeof raw !== 'string' || !raw.trim()) return null;
  let u;
  try {
    u = new URL(raw.trim(), base);
  } catch {
    return null;
  }
  return schemes.has(u.protocol) ? u.href : null;
}

/** `background-image:url('…')` out of a style attribute, scheme-checked. */
function bgUrl(el, base) {
  const style = el?.getAttribute?.('style') ?? '';
  const m = /background-image\s*:\s*url\((['"]?)(.*?)\1\)/i.exec(style);
  return m ? safeUrl(m[2], base, MEDIA_SCHEMES) : null;
}

/** `width:384px` / `padding-top:133.3%` out of a style attribute. */
function styleNumber(el, prop) {
  const style = el?.getAttribute?.('style') ?? '';
  const m = new RegExp(`${prop}\\s*:\\s*([\\d.]+)`, 'i').exec(style);
  const n = m ? Number(m[1]) : NaN;
  return Number.isFinite(n) ? n : null;
}

/** `1` → 1, `1.2K` → 1200, `2.91M` → 2910000. Telegram's own compaction, undone. */
function parseCount(text) {
  const m = /^([\d.,]+)\s*([KMB])?$/i.exec(String(text ?? '').trim());
  if (!m) return 0;
  const n = Number.parseFloat(m[1].replace(/,/g, ''));
  if (!Number.isFinite(n)) return 0;
  const mult = { k: 1e3, m: 1e6, b: 1e9 }[(m[2] || '').toLowerCase()] ?? 1;
  return Math.round(n * mult);
}

/** `<time datetime="…">` → unix seconds, or 0. */
function parseDate(el) {
  const raw = el?.getAttribute?.('datetime');
  const t = raw ? Date.parse(raw) : NaN;
  return Number.isFinite(t) ? Math.floor(t / 1000) : 0;
}

const TEXT_NODE = 3;
const ELEMENT_NODE = 1;

/**
 * A message text subtree → `{ text, entities }` in TDLib's own entity shape
 * (`entityRuns()` consumes it unchanged, so bold/italic/code/links/mentions
 * render exactly as they do signed in). Offsets are UTF-16 code units, which
 * is what JS strings index.
 *
 * `<br>` becomes a newline. Telegram wraps emoji in `<i class="emoji"><b>😀</b></i>`
 * — that inner `<b>` is layout, not emphasis, so an emoji contributes its text
 * and nothing else. `<script>`/`<style>` never contribute at all.
 */
function extractText(root, base) {
  const entities = [];
  let text = '';
  const walk = (node) => {
    for (const child of node.childNodes) {
      if (child.nodeType === TEXT_NODE) {
        text += child.nodeValue ?? '';
        continue;
      }
      if (child.nodeType !== ELEMENT_NODE) continue;
      const tag = child.tagName.toLowerCase();
      if (tag === 'script' || tag === 'style' || tag === 'template') continue;
      if (tag === 'br') {
        text += '\n';
        continue;
      }
      const cls = child.getAttribute('class') || '';
      if (tag === 'tg-emoji' || /\bemoji\b/.test(cls)) {
        text += child.textContent ?? '';
        continue;
      }
      const start = text.length;
      let type = null;
      if (tag === 'b' || tag === 'strong') type = { '@type': 'textEntityTypeBold' };
      else if (tag === 'i' || tag === 'em') type = { '@type': 'textEntityTypeItalic' };
      else if (tag === 'code' || tag === 'pre' || tag === 'kbd' || tag === 'samp') type = { '@type': 'textEntityTypeCode' };
      walk(child);
      const length = text.length - start;
      if (length <= 0) continue;
      if (tag === 'a') {
        const href = safeUrl(child.getAttribute('href'), base);
        const label = text.slice(start, start + length);
        // `@name` linking at t.me is a mention; anything else is a link. A
        // dropped scheme leaves the label as plain text, which is the whole
        // point: a `javascript:` link renders as words, not as a link.
        if (/^@[A-Za-z0-9_]{4,32}$/.test(label) && (!href || /^https?:\/\/(www\.)?t\.me\//i.test(href))) {
          entities.push({ offset: start, length, type: { '@type': 'textEntityTypeMention' } });
        } else if (href) {
          entities.push({ offset: start, length, type: { '@type': 'textEntityTypeTextUrl', url: href } });
        }
        continue;
      }
      if (type) entities.push({ offset: start, length, type });
    }
  };
  walk(root);
  return { text: text.replace(/\s+$/, ''), entities };
}

/** Bubble chrome: present on every message, never part of what was posted. */
const BUBBLE_CHROME = '.tgme_widget_message_author, .tgme_widget_message_user, .tgme_widget_message_footer,'
  + ' .tgme_widget_message_bubble_tail, .tgme_widget_message_forwarded_from, .tgme_widget_message_reply,'
  + ' .message_media_not_supported_wrap';

/** The words inside a bubble with its chrome left out — the last-resort text of an unknown block. */
function bubbleWords(bubble) {
  const parts = [];
  for (const child of bubble.children) {
    if (child.nodeType !== ELEMENT_NODE || child.matches?.(BUBBLE_CHROME)) continue;
    const t = text(child);
    if (t) parts.push(t);
  }
  return parts.join(' ');
}

/** A photo/thumbnail URL as the one "size" the preview offers. */
function sizeOf(url, w, h) {
  return [{ w: w || 0, h: h || 0, file: { url } }];
}

/** Media in one message bubble, in document order (an album is several items). */
function mediaItems(bubble, base) {
  const items = [];
  const add = (item) => {
    if (item) items.push(item);
  };

  for (const el of bubble.querySelectorAll(
    '.tgme_widget_message_photo_wrap, .tgme_widget_message_video_player, .tgme_widget_message_roundvideo_player,'
    + ' .tgme_widget_message_voice_player, .tgme_widget_message_audio_player, .tgme_widget_message_document_wrap,'
    + ' .tgme_widget_message_sticker_wrap, .tgme_widget_message_poll, .tgme_widget_message_location_wrap,'
    + ' .tgme_widget_message_contact_wrap',
  )) {
    const cls = el.getAttribute('class') || '';
    if (/tgme_widget_message_photo_wrap/.test(cls)) {
      const url = bgUrl(el, base);
      if (!url) continue;
      const w = styleNumber(el, 'width') ?? 0;
      const pad = styleNumber(el.querySelector('.tgme_widget_message_photo'), 'padding-top');
      const h = w && pad ? Math.round((w * pad) / 100) : 0;
      add({ kind: 'photo', sizes: sizeOf(url, w, h), mini: null });
      continue;
    }
    if (/tgme_widget_message_roundvideo_player/.test(cls)) {
      add(videoItem(el, base, 'videoNote'));
      continue;
    }
    if (/tgme_widget_message_video_player/.test(cls)) {
      const video = el.querySelector('video');
      const looping = !!video && (video.hasAttribute('loop') || /\bgif\b/i.test(cls));
      add(videoItem(el, base, looping ? 'animation' : 'video'));
      continue;
    }
    // Voice and audio are the two shapes with no fixture behind them: no
    // public channel we could reach posts either through the preview, so these
    // selectors are read off Telegram's widget markup rather than measured.
    // If they are wrong the post degrades to its caption, which is what the
    // defensive contract promises — and the fixtures will say so the day one
    // of these turns up.
    if (/tgme_widget_message_voice_player/.test(cls)) {
      const audio = el.querySelector('audio');
      const url = safeUrl(audio?.getAttribute('src'), base, MEDIA_SCHEMES);
      if (!url) continue;
      add({
        kind: 'voice',
        file: { url },
        duration: parseDuration(el.querySelector('.tgme_widget_message_voice_duration')?.textContent),
        // Telegram ships the waveform as its own bar list here, not as TDLib's
        // packed 5-bit blob; the player draws its flat bar set rather than lie.
        waveform: null,
        mime: 'audio/ogg',
      });
      continue;
    }
    if (/tgme_widget_message_audio_player/.test(cls)) {
      const audio = el.querySelector('audio');
      const url = safeUrl(audio?.getAttribute('src'), base, MEDIA_SCHEMES);
      if (!url) continue;
      add({
        kind: 'audio',
        file: { url },
        duration: parseDuration(el.querySelector('.tgme_widget_message_audio_duration')?.textContent),
        title: text(el.querySelector('.tgme_widget_message_audio_title')) || 'Audio',
        performer: text(el.querySelector('.tgme_widget_message_audio_performer')),
        mime: 'audio/mpeg',
        fileName: text(el.querySelector('.tgme_widget_message_audio_title')) || 'Audio',
        cover: null,
      });
      continue;
    }
    if (/tgme_widget_message_document_wrap/.test(cls)) {
      // a document whose link did not survive the scheme check is not a
      // document — there is nothing to open, and a row that cannot open is
      // worse than no row
      const url = safeUrl(el.getAttribute('href'), base, MEDIA_SCHEMES);
      if (!url) continue;
      const name = text(el.querySelector('.tgme_widget_message_document_title')) || 'File';
      const extra = text(el.querySelector('.tgme_widget_message_document_extra'));
      // Telegram serves some files only in the app and links the post instead
      // of the bytes (measured on @tastycrow/5, an audio file). A row offering
      // `Download` that navigates to Telegram would be a lie; the honest
      // degrade is §2.11's muted one-line summary, and the post sheet's
      // `Open in Telegram` is right there.
      //
      // The same reasoning, taken to its end: the only href that earns a
      // Download button is one that really is Telegram's bytes. Every other
      // host — `t.me` itself, and anything a hostile channel invented — is a
      // destination the row cannot honestly promise, so it degrades to the
      // summary rather than becoming a button that walks the reader off the
      // site to an address they were never shown.
      if (!isTelegramFileHost(url)) {
        add({ kind: 'summary', text: name });
        continue;
      }
      add({
        kind: 'document',
        file: { url, size: parseSize(extra) },
        fileName: name,
        mime: '',
        // the preview offers no thumbnail for a document, and the row does not need one
        thumb: null,
        mini: null,
        // the size line as Telegram wrote it, when we could not read bytes out of it
        extra,
      });
      continue;
    }
    if (/tgme_widget_message_sticker_wrap/.test(cls)) {
      const sticker = el.querySelector('.tgme_widget_message_sticker');
      const url = safeUrl(sticker?.getAttribute('data-webp'), base, MEDIA_SCHEMES) || bgUrl(sticker, base);
      if (!url) continue;
      add({ kind: 'sticker', file: { url }, w: 0, h: 0, animated: false, thumb: null });
      continue;
    }
    if (/tgme_widget_message_poll/.test(cls)) {
      const n = el.querySelectorAll('.tgme_widget_message_poll_option').length;
      add({ kind: 'summary', text: `Poll · ${n} ${n === 1 ? 'option' : 'options'}` });
      continue;
    }
    if (/tgme_widget_message_location_wrap/.test(cls)) {
      add({ kind: 'summary', text: 'Location' });
      continue;
    }
    if (/tgme_widget_message_contact_wrap/.test(cls)) add({ kind: 'summary', text: 'Contact' });
  }
  return items;
}

function videoItem(el, base, kind) {
  const video = el.querySelector('video');
  const url = safeUrl(video?.getAttribute('src'), base, MEDIA_SCHEMES);
  const thumbUrl = bgUrl(el.querySelector('.tgme_widget_message_video_thumb, .tgme_widget_message_roundvideo_thumb'), base);
  const wrap = el.querySelector('.tgme_widget_message_video_wrap, .tgme_widget_message_roundvideo_wrap');
  const w = styleNumber(wrap, 'width') ?? 0;
  const pad = styleNumber(wrap, 'padding-top');
  const h = w && pad ? Math.round((w * pad) / 100) : 0;
  const duration = parseDuration(el.querySelector('.message_video_duration, .tgme_widget_message_video_duration')?.textContent);
  if (!url && !thumbUrl) return null;
  return {
    kind,
    file: url ? { url } : null,
    duration,
    w,
    h,
    thumb: thumbUrl ? { file: { url: thumbUrl }, w, h } : null,
    mini: null,
    mime: 'video/mp4',
    fileName: kind === 'animation' ? 'GIF' : 'Video',
    streamable: true,
  };
}

/** `0:55` / `1:02:03` → seconds. */
function parseDuration(text) {
  const parts = String(text ?? '').trim().split(':');
  if (parts.length < 2 || parts.some((p) => !/^\d+$/.test(p))) return 0;
  return parts.reduce((sum, p) => sum * 60 + Number(p), 0);
}

/** `2.4 MB` → bytes, best effort; 0 when Telegram wrote something else. */
function parseSize(text) {
  const m = /([\d.,]+)\s*(B|KB|MB|GB)\b/i.exec(String(text ?? ''));
  if (!m) return 0;
  const n = Number.parseFloat(m[1].replace(/,/g, ''));
  if (!Number.isFinite(n)) return 0;
  const unit = { b: 1, kb: 1024, mb: 1024 ** 2, gb: 1024 ** 3 }[m[2].toLowerCase()] ?? 1;
  return Math.round(n * unit);
}

/**
 * Visible words of a subtree, collapsed to one line. Deliberately not
 * `textContent`: that returns the source of a `<script>` a hostile page put in
 * a title or a description, and printing an attacker's code as if it were the
 * channel's own words is a lie even when it cannot execute.
 */
function text(el) {
  if (!el) return '';
  return extractText(el, null).text.replace(/\s+/g, ' ').trim();
}

/** `.tgme_widget_message_link_preview` → the post's link-preview row (PRODUCT §2.11). */
function linkPreview(bubble, base) {
  const el = bubble.querySelector('.tgme_widget_message_link_preview');
  if (!el) return null;
  const url = safeUrl(el.getAttribute('href'), base);
  if (!url) return null;
  const image = el.querySelector('.link_preview_image, .link_preview_right_image, .link_preview_video_thumb');
  const thumbUrl = bgUrl(image, base);
  return {
    url,
    siteName: text(el.querySelector('.link_preview_site_name')),
    title: text(el.querySelector('.link_preview_title')) || text(el.querySelector('.link_preview_site_name')) || url,
    description: text(el.querySelector('.link_preview_description')),
    thumb: thumbUrl ? sizeOf(thumbUrl, 0, 0) : null,
    mini: null,
  };
}

/** `tgsocial: @<node>` in a channel description (PROTOCOL §3) → the node it backlinks. */
export function backlinkNode(description) {
  const m = /tgsocial:\s*@([A-Za-z0-9_]{4,32})/i.exec(String(description ?? ''));
  return m ? m[1] : null;
}

/**
 * A channel's own photo, or null — where "or null" includes the case Telegram
 * makes hardest to see.
 *
 * A channel with no photo does not get an empty slot on `t.me/s/`: Telegram
 * GENERATES a letter avatar and serves it as an image, so the markup for a
 * photographed and an unphotographed channel differ only in the src. Measured
 * live: `@tgs_dankcoin` returns
 *   `<i class="tgme_page_photo_image bgcolor1" data-content="E"><img src="data:image/svg+xml;base64,…">`
 * while `@tastycrow` returns an `<img src="https://cdn1.telesco.pe/file/….jpg">`.
 * The `bgcolorN` class and the `data-content` letter are the tell; the `data:`
 * URL is the one that is safe to test, because it is the payload itself.
 *
 * That letter is Telegram's fallback, not the channel's face. Taken as a photo
 * it wins PRODUCT §2.3's fallback chain outright and every unphotographed
 * channel paints Telegram's letter where ours belongs — so it is treated as
 * ABSENT and the chain falls through. (The app side gets this for free:
 * `chat.photo` is simply null there.)
 *
 * `safeUrl` would already drop a `data:` URL, since MEDIA_SCHEMES is http(s)
 * only. This is deliberately not left to that: the scheme list is a security
 * rule that may be widened one day, and this is a product rule that must not
 * follow it.
 */
function channelPhoto(raw, base) {
  const src = String(raw ?? '').trim();
  if (/^data:/i.test(src)) return null;
  return safeUrl(src, base, MEDIA_SCHEMES);
}

function metaContent(doc, property) {
  const el = doc.querySelector(`meta[property="${property}"], meta[name="${property}"]`);
  return el?.getAttribute('content') ?? '';
}

/** The channel header: title, @username, photo, description, backlink. */
function channelInfo(doc, channel, base) {
  const info = doc.querySelector('.tgme_channel_info');
  const title = text(info?.querySelector('.tgme_channel_info_header_title')) || metaContent(doc, 'og:title') || `@${channel}`;
  const usernameRaw = text(info?.querySelector('.tgme_channel_info_header_username')).replace(/^@/, '');
  const username = /^[A-Za-z0-9_]{4,32}$/.test(usernameRaw) ? usernameRaw : channel;
  // `og:image` is the same picture by another route — empty on an
  // unphotographed channel today, but "empty today" is not a contract, so it
  // goes through the same refusal.
  const photo = channelPhoto(info?.querySelector('.tgme_page_photo_image img')?.getAttribute('src'), base)
    || channelPhoto(metaContent(doc, 'og:image'), base);
  const description = text(info?.querySelector('.tgme_channel_info_description')) || metaContent(doc, 'og:description');
  return {
    username,
    title,
    photo: photo ? { url: photo } : null,
    description,
    verifiedFor: backlinkNode(description),
  };
}

/** `?before=` for the next (older) page: Telegram's own `rel=prev` / More link. */
function nextBefore(doc, posts) {
  const candidates = [
    doc.querySelector('link[rel="prev"]')?.getAttribute('href'),
    doc.querySelector('a.tme_messages_more[data-before]')?.getAttribute('data-before'),
  ];
  for (const raw of candidates) {
    if (!raw) continue;
    const m = /(?:before=)?(\d+)\s*$/.exec(String(raw));
    if (m) return Number(m[1]);
  }
  // No paging link: page back from the oldest post we hold, so "load more"
  // still moves. A page with nothing on it ends the source instead.
  const oldest = posts[posts.length - 1];
  return oldest ? oldest.id : null;
}

/**
 * One `.tgme_widget_message` block → a Post. Never throws: a block whose
 * media, time or counts are unrecognisable still becomes a post carrying the
 * text it could find (PUBLIC §3).
 */
function parseBlock(el, ctx) {
  const dataPost = el.getAttribute('data-post') || '';
  const m = /^([A-Za-z0-9_]+)\/(\d+)$/.exec(dataPost);
  const username = m ? m[1] : ctx.username;
  const id = m ? Number(m[2]) : 0;
  if (!id) return null;
  const bubble = el.querySelector('.tgme_widget_message_bubble') || el;
  const textEl = bubble.querySelector('.tgme_widget_message_text');
  const { text: body, entities } = textEl ? extractText(textEl, ctx.base) : { text: '', entities: [] };
  const album = mediaItems(bubble, ctx.base);
  const timeEl = bubble.querySelector('.tgme_widget_message_date time[datetime], .tgme_widget_message_meta time[datetime]')
    || bubble.querySelector('time[datetime]');
  const views = parseCount(text(bubble.querySelector('.tgme_widget_message_views')));
  const forwarded = text(bubble.querySelector('.tgme_widget_message_forwarded_from_name'));
  // an unrecognised block: no text node and no media we know — keep whatever
  // words are in it rather than dropping the post on the floor. The bubble's
  // known chrome (the author line, the footer with views and time) is not the
  // post's words and never joins them.
  const fallback = !body && !album.length ? bubbleWords(bubble).slice(0, 4096) : '';
  const post = {
    key: `${ctx.username}:${id}`,
    id,
    chatId: null,
    username,
    title: ctx.title,
    // §2.3: the card's avatar is the SOURCE CHANNEL's photo, so it travels with
    // every post on the same path the subheading title does — including through
    // the merge on /u/<name>, where posts from several channels share one node.
    // Null when the channel has no photo of its own (channelPhoto()).
    avatar: ctx.photo,
    node: null,
    nodeName: null,
    nodeAvatar: null,
    date: parseDate(timeEl),
    text: body || fallback,
    entities: body ? entities : [],
    media: album[0] ?? null,
    album,
    preview: linkPreview(bubble, ctx.base),
    views,
    reactions: [],
    forwardedFrom: forwarded || null,
    link: `https://t.me/${username}/${id}`,
    /** Preview-sourced: files carry URLs, links get rel="noopener nofollow ugc". */
    source: 'preview',
    /** The node card lives in the channel as an ordinary message; feeds skip it (PROTOCOL §4.8). */
    isCard: cardVersion(body) !== null,
  };
  return post;
}

/**
 * PUBLIC §3 — the parser. `html` is the body of `/tg/s/<channel>`; `channel`
 * is the username it was fetched for (used when a block does not name itself).
 */
export function parsePreview(html, channel) {
  const base = previewBase(channel);
  const empty = {
    channel: { username: channel, title: `@${channel}`, photo: null, description: '', verifiedFor: null },
    posts: [],
    card: null,
    nextBefore: null,
    unavailable: true,
  };
  if (typeof html !== 'string' || !html.trim()) return empty;
  let doc;
  try {
    doc = new DOMParser().parseFromString(html, 'text/html');
  } catch {
    return empty;
  }
  if (!doc?.querySelectorAll) return empty;
  const info = channelInfo(doc, channel, base);
  const ctx = { username: info.username || channel, title: info.title, photo: info.photo, base };
  const posts = [];
  let card = null;
  for (const el of doc.querySelectorAll('.tgme_widget_message')) {
    // service messages ("Channel created", "pinned …") are skipped, as they
    // are in the app (PROTOCOL §4.8)
    if (/\bservice_message\b/.test(el.getAttribute('class') || '')) continue;
    let post = null;
    try {
      post = parseBlock(el, ctx);
    } catch {
      post = null;
    }
    if (!post) continue;
    if (post.isCard && !card) card = parseCard(post.text);
    posts.push(post);
  }
  posts.sort((a, b) => b.date - a.date || b.id - a.id);
  return {
    channel: info,
    posts,
    card,
    nextBefore: nextBefore(doc, posts),
    // zero posts is "we could not read this page", never "this channel is empty"
    unavailable: posts.length === 0,
  };
}
