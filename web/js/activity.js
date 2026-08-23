/* activity.js — the in-flight operation registry behind the status pill and
 * the Status sheet's Pending row (PRODUCT §2.10).
 *
 * Every operation the app runs registers here with a human label
 * ("Reading card @tgs_ana", "Downloading photo"). The pill reads Syncing
 * exactly while this registry is non-empty; a stuck pill is therefore
 * impossible by construction:
 *
 *   - run() releases in `finally`, so a throw, a rejection, or an early
 *     return all end the entry;
 *   - end() is idempotent, so double-release never drives a counter negative;
 *   - every entry auto-clears after TIMEOUT_MS (30 s) even if its promise
 *     never settles (a TDLib request parked on a dead socket, for example) —
 *     the entry dies, the pill resolves, and the operation, if it ever does
 *     settle, finds its end() a no-op.
 */

export const TIMEOUT_MS = 30000;

let nextId = 1;

export class Activity {
  constructor({ timeoutMs = TIMEOUT_MS, onChange = null } = {}) {
    this.timeoutMs = timeoutMs;
    this.onChange = onChange;
    this.entries = new Map();
  }

  get size() {
    return this.entries.size;
  }

  /** Labels of everything in flight, oldest first. */
  list() {
    return [...this.entries.values()].sort((a, b) => a.startedAt - b.startedAt).map((e) => e.label);
  }

  notify() {
    if (this.onChange) {
      try {
        this.onChange(this);
      } catch (e) {
        console.warn('[activity] onChange', e);
      }
    }
  }

  /**
   * Register an operation. Returns end(): idempotent, clears the timeout.
   * The entry removes itself after timeoutMs regardless.
   */
  begin(label) {
    const id = nextId;
    nextId += 1;
    const entry = { id, label: String(label || 'Working'), startedAt: Date.now() };
    entry.timer = setTimeout(() => this.release(id), this.timeoutMs);
    this.entries.set(id, entry);
    this.notify();
    return () => this.release(id);
  }

  release(id) {
    const entry = this.entries.get(id);
    if (!entry) return;
    clearTimeout(entry.timer);
    this.entries.delete(id);
    this.notify();
  }

  /** Wrap a promise (or a promise-returning fn): begin now, end in finally. */
  async run(label, work) {
    const end = this.begin(label);
    try {
      return await (typeof work === 'function' ? work() : work);
    } finally {
      end();
    }
  }
}

/** "Reading card @tgs_ana" ×3 → ["Reading card @tgs_ana × 3"] for display. */
export function collapseLabels(labels) {
  const counts = new Map();
  for (const l of labels) counts.set(l, (counts.get(l) ?? 0) + 1);
  return [...counts.entries()].map(([l, n]) => (n > 1 ? `${l} × ${n}` : l));
}
