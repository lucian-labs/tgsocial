/* resolve.js — who a public URL is about (PUBLIC.md §4, PRODUCT §2.13).
 *
 * `/u/<name>` resolves two ways so a person can be reached by the handle
 * people actually know:
 *
 *   1. `<name>` is a node channel — its card parses → that is the node.
 *   2. `<name>` is a feed channel whose description carries `tgsocial: @<node>`
 *      (PROTOCOL §3) → follow the backlink and use that node.
 *   3. Neither → not a tgsocial person, and the caller shows the §2.6 empty card.
 *
 * So `/u/tastycrow` reaches the person behind `@tastycrow` even though their
 * node is `@tgs_dankcoin`.
 *
 * A node whose card says `public: no` is refused here, on every public route:
 * that flag is the owner saying "not in directories", and a public URL is a
 * directory of one. The refusal follows the backlink too — a feed of an
 * unlisted node is not a side door onto them.
 *
 * The routes are not the only door, so `isUnlisted` is exported and used at the
 * two other places an unlisted node can reach a public page without ever being
 * asked for by name: as a merge source (js/public/feed.js) and as a filled-in
 * row on somebody else's node page (js/views/public.js). Following someone
 * needs no consent, so both fire on ordinary use rather than on a hostile card.
 */
import { usernameKey } from '../protocol.js';

/** Result kinds, so a caller never has to guess what null meant. */
export const FOUND = 'found';
export const UNLISTED = 'unlisted';
export const MISSING = 'missing';

const found = (extra) => ({ kind: FOUND, ...extra });
const unlisted = (node) => ({ kind: UNLISTED, node });
const missing = (reason) => ({ kind: MISSING, reason });

/** `card.public === false` — PROTOCOL §2 defaults it to yes, so only an explicit `no` refuses. */
export function isUnlisted(card) {
  return card?.public === false;
}

/**
 * A person: `{ kind, node, card, page, via }`. `page` is the node channel's
 * parsed preview (its header is the person's identity); `via` is the handle
 * the visitor typed when it was a feed rather than the node.
 */
export async function resolvePerson(source, name) {
  const page = await source.channel(name);
  if (page.card) {
    if (isUnlisted(page.card)) return unlisted(page.channel.username || name);
    return found({ node: page.channel.username || name, card: page.card, page, via: null });
  }
  const back = page.channel.verifiedFor;
  if (back && usernameKey(back) !== usernameKey(name)) {
    const nodePage = await source.channel(back);
    if (nodePage.card) {
      if (isUnlisted(nodePage.card)) return unlisted(nodePage.channel.username || back);
      return found({ node: nodePage.channel.username || back, card: nodePage.card, page: nodePage, via: page.channel.username || name });
    }
  }
  return missing(page.unavailable ? 'unavailable' : 'not-a-node');
}

/**
 * A node channel for `/n/<node>`: the card itself, refused when unlisted.
 */
export async function resolveNode(source, name) {
  const page = await source.channel(name);
  if (!page.card) return missing(page.unavailable ? 'unavailable' : 'not-a-node');
  if (isUnlisted(page.card)) return unlisted(page.channel.username || name);
  return found({ node: page.channel.username || name, card: page.card, page, via: null });
}

/**
 * A channel for `/f/<channel>`: the page plus the node it backlinks (which is
 * what the `Verified` pill means, PROTOCOL §3). Refused when the channel is
 * itself an unlisted node, or when it backlinks one.
 */
export async function resolveChannel(source, name) {
  const page = await source.channel(name);
  if (page.unavailable) return missing('unavailable');
  if (isUnlisted(page.card)) return unlisted(page.channel.username || name);
  const back = page.channel.verifiedFor;
  if (!back) return found({ page, node: null, card: page.card ?? null, verified: false });
  const nodePage = await source.channel(back);
  if (isUnlisted(nodePage.card)) return unlisted(nodePage.channel.username || back);
  return found({
    page,
    node: nodePage.card ? (nodePage.channel.username || back) : null,
    card: nodePage.card ?? null,
    // verified = the backlink names a node that really is one (PROTOCOL §3)
    verified: !!nodePage.card,
    nodePage: nodePage.card ? nodePage : null,
  });
}
