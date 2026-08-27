/* td.js — thin tdweb (TDLib wasm) wrapper.
 *
 * Client lifecycle, auth state stream, request helper with FLOOD_WAIT backoff,
 * update bus, file download → blob cache. Nothing product-specific lives here.
 *
 * tdweb is loaded by a classic <script src="/vendor/tdweb/tdweb.js"> (UMD);
 * `window.tdweb.default` is TdClient. Target semantics: TDLib ≥ 1.8.6 — flat
 * setTdlibParameters, no encryption-key step.
 */
import { floodWaitSeconds } from './protocol.js';
import { MediaCache, mediaBudgetBytes, renditionKey } from './blobcache.js';
import { downscale } from './decode.js';

export const APP_VERSION = '1.0.0';
export const APP_BUILD = '1';

export class TdError extends Error {
  constructor(err) {
    super(err?.message || 'TDLib error');
    this.name = 'TdError';
    this.code = err?.code ?? 0;
    this.raw = err;
  }
}

export class DownloadCancelled extends Error {
  constructor() {
    super('Download cancelled.');
    this.name = 'DownloadCancelled';
    this.cancelled = true;
  }
}

/** PRODUCT §2.10 Connection row copy for each TDLib connection state. */
export const CONNECTION_COPY = {
  connectionStateReady: 'Connected',
  connectionStateConnecting: 'Connecting',
  connectionStateUpdating: 'Updating',
  connectionStateWaitingForNetwork: 'Waiting for network',
  connectionStateConnectingToProxy: 'Connecting to proxy',
};

export function connectionCopy(state) {
  return CONNECTION_COPY[state] ?? 'Connecting';
}

/** The IndexedDB instance every session runs in. */
export const TD_INSTANCE = 'tgsocial';

/**
 * Everything TDLib answers before authorization (PRODUCT §2.13). Measured
 * against the bundled tdweb 1.8.66 on a client at `connectionStateReady` and
 * `authorizationStateWaitPhoneNumber`: `getOption` resolves, and
 * `searchPublicChat`, `getChat` and `getChatHistory` all reject `401
 * Unauthorized`. TDLib has no anonymous read of a public channel — the check
 * that holds this true lives in test/smoke.mjs. Anything that wants chat data
 * from *this library* has to sign in first; the public pages read Telegram's
 * own preview instead and never touch TDLib at all (PUBLIC.md, js/public/).
 */
export const PREAUTH_QUERIES = new Set(['setTdlibParameters', 'getOption', 'setNetworkType', 'getAuthorizationState']);

/** Downloads with no progress for this long are given up on (not cancelled in TDLib — the next tap resumes). */
const DOWNLOAD_STALL_MS = 60000;
/** A connection that stays Connecting/Updating this long gets a nudge (setNetworkType) so TDLib re-checks its socket. */
const CONNECTION_STALL_MS = 30000;

/** How often the heap is sampled where the browser reports one (Chrome only). */
const MEMORY_POLL_MS = 10000;
/** Fraction of the renderer's heap ceiling that counts as pressure. */
const HEAP_PRESSURE = 0.8;
/** What a backgrounded tab keeps of its media budget — enough to repaint on return, not enough to be worth killing. */
const HIDDEN_KEEP = 0.25;

export class Td {
  constructor() {
    this.client = null;
    this.authState = null;
    this.connectionState = null;
    this.tdlibVersion = null;
    this.listeners = new Map();
    this.downloads = new Map();
    /**
     * Every decoded rendition and every blob: URL the app is holding, bounded
     * by bytes first and entries second (js/blobcache.js). Nothing else in the
     * app may call URL.createObjectURL: an URL minted outside this cache has
     * nobody to revoke it.
     */
    this.media = new MediaCache({ maxBytes: mediaBudgetBytes() });
    /** key → in-flight read promise; not charged to the budget until it settles. */
    this.filePending = new Map();
    /** rendition key → in-flight decode, so a screen full of one avatar decodes it once. */
    this.renditionPending = new Map();
    this.memoryTimer = null;
    this.floodUntil = 0;
    this.onFloodWait = null;
    /** Set by the app: an Activity registry every request-bound operation reports into. */
    this.activity = null;
    this.connectionSince = 0;
    this.lastNudge = 0;
    this.watchdog = null;
    /** Bumped by init/close; updates from a superseded client are dropped. */
    this.generation = 0;
  }

  track(label, work) {
    if (!this.activity) return typeof work === 'function' ? work() : work;
    return this.activity.run(label, work);
  }

  static available() {
    return typeof window !== 'undefined' && !!window.tdweb && !!window.tdweb.default;
  }

  // ── bus ──────────────────────────────────────────────────────────────────

  on(type, fn) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(fn);
    return () => this.off(type, fn);
  }

  off(type, fn) {
    this.listeners.get(type)?.delete(fn);
  }

  emit(type, payload) {
    for (const fn of this.listeners.get(type) ?? []) {
      try {
        fn(payload);
      } catch (e) {
        console.warn('[td] listener failed', type, e);
      }
    }
    for (const fn of this.listeners.get('*') ?? []) {
      try {
        fn(payload);
      } catch (e) {
        console.warn('[td] listener failed', type, e);
      }
    }
  }

  handleUpdate(update) {
    const type = update?.['@type'];
    if (type === 'updateAuthorizationState') {
      this.authState = update.authorization_state;
      this.emit('auth', this.authState);
    } else if (type === 'updateConnectionState') {
      const next = update.state?.['@type'] ?? null;
      if (next !== this.connectionState) this.connectionSince = Date.now();
      this.connectionState = next;
      this.emit('connection', this.connectionState);
    } else if (type === 'updateFile') {
      this.onFileUpdate(update.file);
    } else if (type === 'updateFatalError') {
      console.warn('[td] fatal', update.error);
    }
    this.emit(type, update);
  }

  // ── lifecycle ────────────────────────────────────────────────────────────

  async init(config) {
    if (!Td.available()) throw new Error('tdweb is not loaded.');
    const TdClient = window.tdweb.default;
    const generation = this.generation + 1;
    this.generation = generation;
    this.client = new TdClient({
      onUpdate: (u) => {
        // a client we have closed must not keep driving the app
        if (generation !== this.generation) return;
        this.handleUpdate(u);
      },
      instanceName: TD_INSTANCE,
      isBackground: false,
      jsLogVerbosityLevel: 'error',
      logVerbosityLevel: 0,
      useDatabase: true,
    });
    this.startWatchdog();
    this.startMemoryWatch();
    const ready = this.waitAuth((s) => s && s['@type'] !== 'authorizationStateWaitTdlibParameters', 30000);
    const params = {
      '@type': 'setTdlibParameters',
      api_id: config.apiId,
      api_hash: config.apiHash,
      system_language_code: navigator.language || 'en',
      device_model: 'Web',
      system_version: navigator.platform || 'browser',
      application_version: `${APP_VERSION} (${APP_BUILD})`,
      use_test_dc: false,
      use_secret_chats: false,
      use_file_database: true,
      use_chat_info_database: true,
      use_message_database: true,
    };
    // the worker may already have emitted WaitTdlibParameters; send regardless
    await this.send(params).catch((e) => {
      // "Unexpected setTdlibParameters" means a persisted session is already past it
      if (!/setTdlibParameters|Unexpected/i.test(e.message)) throw e;
    });
    await ready;
    try {
      const v = await this.send({ '@type': 'getOption', name: 'version' });
      this.tdlibVersion = v?.value ?? null;
    } catch {
      this.tdlibVersion = null;
    }
    return this.authState;
  }

  waitAuth(predicate, timeoutMs = 60000) {
    if (predicate(this.authState)) return Promise.resolve(this.authState);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        off();
        reject(new Error('Timed out waiting for Telegram.'));
      }, timeoutMs);
      const off = this.on('auth', (s) => {
        if (predicate(s)) {
          clearTimeout(timer);
          off();
          resolve(s);
        }
      });
    });
  }

  get isReady() {
    return this.authState?.['@type'] === 'authorizationStateReady';
  }

  /** TDLib is up and answering — past `WaitTdlibParameters`, whatever it says about the user. */
  get isBooted() {
    return !!this.client && !!this.authState && this.authState['@type'] !== 'authorizationStateWaitTdlibParameters';
  }

  // ── connection watchdog ──────────────────────────────────────────────────

  /**
   * iOS Safari suspends the tdweb worker's WebSocket when the tab is hidden;
   * on return TDLib can sit in Connecting/Updating for minutes. Nudging it with
   * setNetworkType makes it re-check the socket at once. Runs on visibility /
   * online events and every CONNECTION_STALL_MS while the state is not Ready.
   */
  startWatchdog() {
    if (this.watchdog || typeof window === 'undefined') return;
    const nudge = () => this.nudge();
    window.addEventListener('online', nudge);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') nudge();
    });
    this.watchdog = setInterval(() => {
      const c = this.connectionState;
      const stalled = c && c !== 'connectionStateReady' && c !== 'connectionStateWaitingForNetwork' && Date.now() - this.connectionSince > CONNECTION_STALL_MS;
      if (stalled) this.nudge();
    }, 5000);
  }

  nudge() {
    if (!this.client || Date.now() - this.lastNudge < 5000) return;
    this.lastNudge = Date.now();
    const online = typeof navigator === 'undefined' || navigator.onLine !== false;
    this.client.send({ '@type': 'setNetworkType', type: { '@type': online ? 'networkTypeOther' : 'networkTypeNone' } }).catch(() => null);
  }

  // ── requests ─────────────────────────────────────────────────────────────

  /** send(query) — resolves the TDLib result, rejects TdError. Backs off on FLOOD_WAIT once. */
  async send(query, { retryFlood = true } = {}) {
    if (!this.client) throw new Error('TDLib is not running.');
    const wait = this.floodUntil - Date.now();
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    try {
      return await this.client.send(query);
    } catch (raw) {
      const err = new TdError(raw);
      const seconds = floodWaitSeconds(err);
      if (seconds !== null && retryFlood) {
        this.floodUntil = Date.now() + seconds * 1000;
        if (this.onFloodWait) this.onFloodWait(seconds);
        await new Promise((r) => setTimeout(r, seconds * 1000));
        return this.send(query, { retryFlood: false });
      }
      throw err;
    }
  }

  /** Like send but resolves null instead of throwing (for optional lookups). */
  async trySend(query) {
    try {
      return await this.send(query);
    } catch {
      return null;
    }
  }

  // ── auth ─────────────────────────────────────────────────────────────────

  // Auth requests do not auto-retry on FLOOD_WAIT: the form re-enables at once and
  // the PRODUCT §2.1 copy ("Too many tries. Wait a moment." with the seconds) shows.
  // Data requests keep the automatic backoff (PRODUCT §4).
  setPhone(phone) {
    return this.send({
      '@type': 'setAuthenticationPhoneNumber',
      phone_number: phone,
      settings: { '@type': 'phoneNumberAuthenticationSettings', allow_flash_call: false, is_current_phone_number: false, allow_sms_retriever_api: false },
    }, { retryFlood: false });
  }

  checkCode(code) {
    return this.send({ '@type': 'checkAuthenticationCode', code }, { retryFlood: false });
  }

  checkPassword(password) {
    return this.send({ '@type': 'checkAuthenticationPassword', password }, { retryFlood: false });
  }

  /** logOut, then wait for TDLib to actually close (LoggingOut → Closed) so the session is gone before we reload. */
  async logOut() {
    try {
      const closed = this.waitAuth((s) => s?.['@type'] === 'authorizationStateClosed', 20000);
      await this.send({ '@type': 'logOut' });
      await closed;
    } catch (e) {
      console.warn('[td] logOut', e.message);
    } finally {
      // nothing decoded from this account may outlive it, and every blob: URL
      // it minted is revoked here rather than left to the reload
      this.flushMedia('logout');
      if (this.memoryTimer) clearInterval(this.memoryTimer);
      this.memoryTimer = null;
    }
  }

  // ── files ────────────────────────────────────────────────────────────────

  fileKey(file) {
    return file?.remote?.unique_id || `id:${file?.id}`;
  }

  onFileUpdate(f) {
    if (!f?.id) return;
    const d = this.downloads.get(f.id);
    if (!d) return;
    d.file = f;
    d.lastProgress = Date.now();
    const total = f.expected_size || f.size || 0;
    const got = f.local?.downloaded_size ?? 0;
    for (const fn of d.progress) {
      try {
        fn(total ? Math.min(1, got / total) : 0, got, total);
      } catch (e) {
        console.warn('[td] progress', e);
      }
    }
    if (f.local?.is_downloading_completed) this.settleDownload(f.id, null, f);
    else if (!f.local?.is_downloading_active && d.cancelled) this.settleDownload(f.id, new DownloadCancelled());
  }

  settleDownload(fileId, error, file) {
    const d = this.downloads.get(fileId);
    if (!d) return;
    this.downloads.delete(fileId);
    clearTimeout(d.stall);
    if (d.end) d.end();
    if (error) d.reject(error);
    else d.resolve(file);
  }

  /**
   * Download a TDLib File (PROTOCOL §4.10). Resolves the completed File.
   * opts.priority: 1 when merely visible, 32 when tapped (a later call with a
   * higher priority re-issues downloadFile, which TDLib treats as a bump).
   * opts.onProgress(fraction, downloaded, total) fires on every updateFile.
   * opts.label names the entry in the activity registry ("Downloading photo").
   * Stalls (no bytes for DOWNLOAD_STALL_MS) reject; cancel() rejects with
   * DownloadCancelled.
   */
  download(file, { priority = 1, onProgress = null, label = 'Downloading file' } = {}) {
    if (!file?.id) return Promise.reject(new Error('No file.'));
    if (file.local?.is_downloading_completed) return Promise.resolve(file);
    let d = this.downloads.get(file.id);
    if (d) {
      if (onProgress) d.progress.add(onProgress);
      if (priority > d.priority) {
        d.priority = priority;
        this.send({ '@type': 'downloadFile', file_id: file.id, priority, offset: 0, limit: 0, synchronous: false }).catch(() => null);
      }
      return d.promise;
    }
    d = { file, priority, progress: new Set(), cancelled: false, lastProgress: Date.now(), end: null };
    if (onProgress) d.progress.add(onProgress);
    d.promise = new Promise((resolve, reject) => {
      d.resolve = resolve;
      d.reject = reject;
    });
    this.downloads.set(file.id, d);
    if (this.activity) d.end = this.activity.begin(label);
    const tick = () => {
      if (!this.downloads.has(file.id)) return;
      if (Date.now() - d.lastProgress > DOWNLOAD_STALL_MS) this.settleDownload(file.id, new Error('Download timed out.'));
      else d.stall = setTimeout(tick, 5000);
    };
    d.stall = setTimeout(tick, 5000);
    this.send({ '@type': 'downloadFile', file_id: file.id, priority, offset: 0, limit: 0, synchronous: false }).then(
      (res) => {
        if (res?.local?.is_downloading_completed) this.settleDownload(file.id, null, res);
        else if (res) this.onFileUpdate(res);
      },
      (e) => this.settleDownload(file.id, e),
    );
    return d.promise;
  }

  isDownloading(fileId) {
    return this.downloads.has(fileId);
  }

  /** Cancel an in-flight download (tap on the ring). Waiters reject with DownloadCancelled. */
  async cancel(fileId) {
    const d = this.downloads.get(fileId);
    if (!d) return;
    d.cancelled = true;
    await this.trySend({ '@type': 'cancelDownloadFile', file_id: fileId, only_if_pending: false });
    this.settleDownload(fileId, new DownloadCancelled());
  }

  /** Current TDLib File for an id (fresh local state). */
  getFile(fileId) {
    return this.trySend({ '@type': 'getFile', file_id: fileId });
  }

  /** Bytes [offset, offset+count) of a file's downloaded prefix as a Blob, or null. */
  async readPart(fileId, offset, count) {
    const part = await this.trySend({ '@type': 'readFilePart', file_id: fileId, offset, count });
    return part?.data instanceof Blob ? part.data : null;
  }

  /** Resolve a File object to a blob: URL, cached by remote.unique_id. Null on failure. */
  async fileUrl(file, opts = {}) {
    if (!file || !file.id) return null;
    const key = this.fileKey(file);
    const hit = this.media.url(key);
    if (hit) return hit;
    const blob = await this.fileBlob(file, opts);
    if (!blob) return null;
    return this.media.url(key) ?? null;
  }

  /** Cached blob: URL when the file has already been read, else null (no download). */
  cachedUrl(file) {
    return this.media.url(this.fileKey(file));
  }

  /**
   * The media-cache key for one rendition of a file.
   *
   * A width means a decoded rendition and gets a rendition suffix. NO width
   * means "the bytes Telegram sent", and those are already cached under the
   * bare file key by fileBlobOrThrow — a video being played, a voice note,
   * a document. Deriving a separate `@full` key for that case would name an
   * entry nothing ever writes, which is exactly how pinImage came to be a
   * silent no-op for every player in the app.
   */
  mediaKey(file, width = null) {
    const base = this.fileKey(file);
    return width ? renditionKey(base, width) : base;
  }

  /** Cached URL for one rendition of a file (see imageUrl), else null. */
  cachedImageUrl(file, width = null) {
    if (!file?.id) return null;
    return this.media.url(this.mediaKey(file, width));
  }

  /** Like fileUrl but rejects instead of swallowing (so a viewer can tell cancel from failure). */
  async fileUrlOrThrow(file, opts = {}) {
    if (!file || !file.id) throw new Error('No file.');
    const key = this.fileKey(file);
    const hit = this.media.url(key);
    if (hit) return hit;
    await this.fileBlobOrThrow(file, opts);
    const url = this.media.url(key);
    if (!url) throw new Error('File is empty.');
    return url;
  }

  /**
   * A blob: URL for an IMAGE, decoded at no more than `width` device pixels.
   *
   * This is the path every photo, avatar and thumbnail takes. The raw bytes
   * Telegram sent are read once, downsampled to what the card will actually
   * paint (js/decode.js), cached under a rendition key, and the full-size
   * source is dropped — TDLib still has the file locally, so the full-screen
   * viewer asking for a bigger rendition costs one readFile, not a permanent
   * copy of every original in the feed.
   */
  async imageUrl(file, { width = null, priority = 1, label = 'Downloading photo', mime = null, onProgress = null } = {}) {
    if (!file?.id) return null;
    const base = this.fileKey(file);
    const key = this.mediaKey(file, width);
    const hit = this.media.url(key);
    if (hit) return hit;
    // one decode per rendition: a feed screen asks for the same avatar a dozen
    // times at once, and two decodes racing would replace (and revoke) a URL
    // the first one had already handed to an <img>
    const inflight = this.renditionPending.get(key);
    if (inflight) return inflight;
    const job = (async () => {
      const blob = await this.fileBlobOrThrow(file, { priority, label, mime, onProgress });
      const raced = this.media.url(key);
      if (raced) return raced;
      const shrunk = width ? await downscale(blob, width) : { blob, width: 0, height: 0 };
      this.media.put(key, shrunk.blob, { width: shrunk.width, height: shrunk.height });
      // the original is re-readable from TDLib; holding it as well would double
      // the cost of every photo in the feed for a rendition nobody is painting
      if (key !== base && shrunk.blob !== blob) this.media.drop(base);
      return this.media.url(key);
    })();
    this.renditionPending.set(key, job);
    try {
      return await job;
    } finally {
      this.renditionPending.delete(key);
    }
  }

  /**
   * Store a bitmap DERIVED from a file rather than decoded from it — the
   * spectrogram strip of an audio clip (PRODUCT §2.11.1), which is a picture
   * of the sound and not the sound — charged at its true decoded cost
   * (width × height × 4) like any other rendition. The caller owns the key,
   * because what makes a derivation unique is the caller's business; what is
   * NOT negotiable is that derived bytes go through the SAME budget as
   * everything else, since a strip held outside the accounting is a leak the
   * Status sheet cannot see.
   */
  putDerived(key, blob, { width = 0, height = 0 } = {}) {
    this.media.put(key, blob, { width, height });
    return this.media.url(key);
  }

  /** The URL for a derived bitmap, or null when it was never made or has been evicted. */
  derivedUrl(key) {
    return this.media.url(key);
  }

  /**
   * Hold/release a cached file against eviction while it is on screen or
   * playing. Returns the key that was pinned, or null when there was nothing
   * cached under it — the caller must treat null as "not pinned" rather than
   * assuming the bytes are safe.
   */
  pinImage(file, width = null) {
    if (!file?.id) return null;
    const key = this.mediaKey(file, width);
    return this.media.pin(key) ? key : null;
  }

  unpinKey(key) {
    if (key) this.media.unpin(key);
  }

  async fileBlob(file, opts = {}) {
    try {
      return await this.fileBlobOrThrow(file, opts);
    } catch (e) {
      if (!e?.cancelled) console.warn('[td] file', e.message);
      return null;
    }
  }

  async fileBlobOrThrow(file, { priority = 1, onProgress = null, label = 'Downloading file', mime = null } = {}) {
    const key = this.fileKey(file);
    const cached = this.media.blobOf(key);
    if (cached) return cached;
    const inflight = this.filePending.get(key);
    if (inflight) {
      // an in-flight read: join it, and bump its priority if this caller is more urgent
      if (this.downloads.has(file.id)) this.download(file, { priority, onProgress, label });
      return inflight;
    }
    const pending = (async () => {
      const f = await this.download(file, { priority, onProgress, label });
      const part = await this.send({ '@type': 'readFile', file_id: f.id });
      const data = part?.data;
      if (!(data instanceof Blob)) throw new Error('File is empty.');
      return mime && !data.type ? new Blob([data], { type: mime }) : data;
    })();
    this.filePending.set(key, pending);
    try {
      const blob = await pending;
      this.media.put(key, blob);
      return blob;
    } finally {
      this.filePending.delete(key);
    }
  }

  // ── memory pressure ──────────────────────────────────────────────────────

  /**
   * The web has no `didReceiveMemoryWarning`, so this listens to every signal
   * that stands in for one:
   *
   *   freeze / pagehide — the tab is about to be frozen or put in the back/
   *     forward cache. On iOS this is the last moment before the OS may
   *     reclaim the whole page: release everything droppable.
   *   visibilitychange (hidden) — a backgrounded tab is the first thing an OS
   *     under pressure kills, so it keeps a quarter of its budget, not all.
   *   performance.memory (Chrome) — an actual measurement: past 80 % of the
   *     renderer's heap ceiling, flush.
   *
   * Every flush emits 'mediaFlush' so the views can repaint what is on screen
   * (js/media.js) instead of leaving holes where the pictures were.
   */
  startMemoryWatch() {
    if (typeof window === 'undefined' || this.memoryTimer) return;
    const flush = (reason) => this.flushMedia(reason);
    window.addEventListener('pagehide', () => flush('pagehide'));
    document.addEventListener('freeze', () => flush('freeze'));
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') this.media.trimTo(HIDDEN_KEEP);
    });
    this.memoryTimer = setInterval(() => {
      const m = typeof performance !== 'undefined' ? performance.memory : null;
      if (!m?.jsHeapSizeLimit) return;
      if (m.usedJSHeapSize / m.jsHeapSizeLimit > HEAP_PRESSURE) flush('heap');
    }, MEMORY_POLL_MS);
  }

  /** Drop every decoded rendition and revoke its URL. Returns how many went. */
  flushMedia(reason = 'manual') {
    const released = this.media.clear();
    this.filePending.clear();
    this.renditionPending.clear();
    this.emit('mediaFlush', { reason, released });
    return released;
  }

  /** Everything the Status sheet and the flow test need to see about media memory. */
  mediaStats() {
    return this.media.stats();
  }
}

/** Map a TDLib error to the product copy for auth (PRODUCT §2.1). */
export function authErrorCopy(err) {
  const m = err?.message ?? '';
  const secs = floodWaitSeconds(err);
  if (secs !== null) return `Too many tries. Wait a moment. (${secs} s)`;
  if (/PHONE_CODE_INVALID|PHONE_CODE_EMPTY/.test(m)) return "That code didn't match.";
  if (/PASSWORD_HASH_INVALID|PASSWORD_INVALID/.test(m)) return "That password didn't match.";
  if (/PHONE_NUMBER_INVALID|PHONE_NUMBER_BANNED|PHONE_NUMBER_FLOOD/.test(m)) return "Telegram didn't accept that number.";
  return m || 'Telegram returned an error.';
}
