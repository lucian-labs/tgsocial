/* demo/mode.js — the copy, the strip and the sheet of PRODUCT §2.22.
 *
 * Every string here is verbatim from the spec, because §3 makes copy shared
 * across the three builds: the same control says the same words on iOS,
 * Android and the web. Nothing in this file talks to Telegram, and nothing in
 * this directory imports js/td.js (§2.22.4).
 */
import { button, h, modal, sectionMark } from '../../vendor/house-pour.js';
import { SafetyLists } from '../moderation.js';

/** §2.1 — the entry point, on step 1 only. */
export const ENTRY_LABEL = 'Look Around First';
export const ENTRY_NOTE = 'Invented people, invented posts. Nothing is sent to Telegram.';

/** §2.22 — the strip docked under the topbar, on every screen and in the viewers. */
export const STRIP_TEXT = 'Demo. Everyone here is invented. Nothing leaves this device.';

/** §2.22 — the status pill, neutral. Never gold: gold means a live Telegram connection (§1). */
export const PILL_TEXT = 'Demo';

/**
 * §2.22.3's three refusals. They are three strings and not one because each
 * names a different truth: a write has nowhere to go, `Open in Telegram` is
 * about a message that is not on Telegram at all, and a link is about the demo
 * not navigating anywhere.
 */
export const WRITE_REFUSED = "The demo doesn't write to Telegram.";
export const NOT_ON_TELEGRAM = 'Nothing here is on Telegram.';
export const LINKS_REFUSED = "Links don't open in the demo.";

/**
 * §2.22.2's one deviation from §2.15, written down: the report email gets this
 * line prepended to its body. §2.15 says the app adds nothing else, and this is
 * the exception — without it the operator opens their inbox and goes looking
 * for a channel that does not exist.
 */
export const REPORT_PREFACE = 'Demo: this report is from the demo and the link is invented.';

/** §2.22 — leaving, and the one §2.21 outcome the demo deviates on. */
export const LEFT_TOAST = 'Left the demo.';
export const DELETED_TOAST = 'Your node is gone. The demo is over.';
export const LEAVE_LABEL = 'Leave Demo';

/**
 * PROTOCOL §7.1's demo paragraph: block, mute and report are real here, so
 * they need a record — of the same shape, in memory, `userId: null`, written
 * to none of §7.1's three homes and loaded from none of them either. A demo
 * block of @tgs_demo_crate must not turn up in a real account's list, and a
 * real account's blocks are not someone's demo to browse.
 */
const NOWHERE = { getItem: () => null, setItem: () => {}, removeItem: () => {} };

export function demoSafetyLists(onChange) {
  return new SafetyLists({ storage: NOWHERE, onChange });
}

/**
 * §2.22 item 2 — full column width, `bg2` fill, hairline below, mono small in
 * `muted`. It lives inside `.head`, which is the sticky container the topbar
 * is in, so it is sticky WITH the topbar rather than merely under it; the
 * stylesheet keeps it painted over the full-screen viewers, which is the one
 * place the topbar hides.
 */
export function demoStrip() {
  return h('div.demo-strip', { role: 'note' }, STRIP_TEXT);
}

/**
 * §2.22.5 — the demo sheet, in the status sheet's place. `Telegram · Not
 * connected` is the row that answers the reviewer's question without them
 * having to take our word for §2.22.4.
 */
export function openDemoSheet(app) {
  const row = (label, value) => h('div.status-row', h('div.status-label', label), h('div.status-value', value));
  const stats = app.repo.demoStats();
  let m = null;
  const leave = button(LEAVE_LABEL, { style: 'primary', onClick: () => {
    m.close();
    app.leaveDemo();
  } });
  const close = button('Close', { style: 'ghost', onClick: () => m.close() });
  const content = h('div.status-sheet',
    sectionMark('Demo'),
    h('h2', "You're in the demo."),
    h('p.muted', 'Everyone here is invented. Nothing is sent to Telegram and nothing is saved on this device. Report, block and mute are real and work on these fixtures.'),
    row('Nodes', String(stats.nodes)),
    row('Feeds', `${stats.sources} sources · ${stats.posts} posts`),
    row('Network', `${stats.direct} direct · ${stats.plusOne} at +1`),
    row('Telegram', 'Not connected'),
    leave,
    close,
  );
  m = modal(content, { label: 'Demo' });
  return m;
}
