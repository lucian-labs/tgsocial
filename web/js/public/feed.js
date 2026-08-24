/* feed.js — the public reader's feed, merged by the app's own merger.
 *
 * PUBLIC.md §4: read the node's card `feeds:`, fetch each, merge newest-first
 * with the same k-way merge as PROTOCOL §4.8, and page each source with
 * `?before=` so the endless scroll is real rather than a fixed page.
 *
 * "The same merge" is meant literally: this extends `FeedSession` (js/repo.js)
 * and overrides only its four reader seams — resolve a username to a source,
 * fetch one page, decide what counts as a post, turn a merged group into a
 * post model. Ordering, refill choice, exhaustion and the load-more loop are
 * the signed-in feed's, unmodified. There is no second merger.
 */
import { FeedSession } from '../repo.js';
import { usernameKey } from '../protocol.js';
import { isUnlisted } from './resolve.js';

export class PublicFeedSession extends FeedSession {
  /**
   * `attribution` is the person the posts reach the reader through (PRODUCT
   * §2.3): on `/u/<name>` it is the node whose card lists these feeds, so the
   * card header reads person-first with the channel underneath. On `/f/<channel>`
   * there is none and the card falls back to the channel itself.
   */
  constructor(source, usernames, { attribution = null } = {}) {
    super(null, usernames);
    this.source = source;
    this.attribution = attribution;
  }

  /**
   * A source, or null when there is nothing to read from this one — which the
   * base `fill()` turns into `markExhausted`, so a refused source is simply a
   * feed with no posts in it rather than a special case anywhere downstream.
   *
   * `public: no` is refused *here*, at the source, not only at the three route
   * entry points (PUBLIC §4). Otherwise an unlisted node's posts reach a public
   * page the moment anyone else names them in their card's `feeds:` — the
   * refusal has to be a property of what may be read, not of which URL asked.
   */
  async resolve(username) {
    const key = usernameKey(username);
    if (this.sources.has(key)) return this.sources.get(key);
    const page = await this.source.channel(username);
    const src = page.unavailable || isUnlisted(page.card)
      ? null
      : { key, username: page.channel.username || username, chatId: null, title: page.channel.title, photo: page.channel.photo };
    this.sources.set(key, src);
    return src;
  }

  /**
   * One preview page. `from` is the `?before=` cursor: 0 is the newest page
   * (already fetched and cached by resolve(), so this costs nothing twice).
   * `done` when Telegram offers no older page — the preview pages back, but
   * not forever (PUBLIC §5).
   */
  async page(src, from) {
    const parsed = await this.source.page(src.username, from || null);
    return {
      items: parsed.posts.map((post) => ({ id: post.id, date: post.date, post })),
      cursor: parsed.nextBefore,
      done: !parsed.nextBefore || parsed.unavailable,
    };
  }

  /** The card is a message in the channel like any other; the feed skips it (PROTOCOL §4.8). */
  keep(item) {
    return !item.post.isCard;
  }

  async postOf(src, head) {
    const post = head.message.post;
    if (!this.attribution) return post;
    // the parsed page is shared between sessions and cached: attribute a copy
    return {
      ...post,
      node: this.attribution.username,
      nodeName: this.attribution.name,
      nodeAvatar: this.attribution.photo ?? null,
    };
  }
}
