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

/** Downloads with no progress for this long are given up on (not cancelled in TDLib — the next tap resumes). */
const DOWNLOAD_STALL_MS = 60000;
/** A connection that stays Connecting/Updating this long gets a nudge (setNetworkType) so TDLib re-checks its socket. */
const CONNECTION_STALL_MS = 30000;

export class Td {
  constructor() {
    this.client = null;
    this.authState = null;
    this.connectionState = null;
    this.tdlibVersion = null;
    this.listeners = new Map();
    this.downloads = new Map();
    this.blobUrls = new Map();
    this.fileBlobs = new Map();
    this.floodUntil = 0;
    this.onFloodWait = null;
    /** Set by the app: an Activity registry every request-bound operation reports into. */
    this.activity = null;
    this.connectionSince = 0;
    this.lastNudge = 0;
    this.watchdog = null;
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
    this.client = new TdClient({
      onUpdate: (u) => this.handleUpdate(u),
      instanceName: 'tgsocial',
      isBackground: false,
      jsLogVerbosityLevel: 'error',
      logVerbosityLevel: 0,
      useDatabase: true,
    });
    this.startWatchdog();
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
    if (this.blobUrls.has(key)) return this.blobUrls.get(key);
    const blob = await this.fileBlob(file, opts);
    if (!blob) return null;
    if (this.blobUrls.has(key)) return this.blobUrls.get(key);
    const url = URL.createObjectURL(blob);
    this.blobUrls.set(key, url);
    return url;
  }

  /** Cached blob: URL when the file has already been read, else null (no download). */
  cachedUrl(file) {
    return this.blobUrls.get(this.fileKey(file)) ?? null;
  }

  /** Like fileUrl but rejects instead of swallowing (so a viewer can tell cancel from failure). */
  async fileUrlOrThrow(file, opts = {}) {
    if (!file || !file.id) throw new Error('No file.');
    const key = this.fileKey(file);
    if (this.blobUrls.has(key)) return this.blobUrls.get(key);
    const blob = await this.fileBlobOrThrow(file, opts);
    if (this.blobUrls.has(key)) return this.blobUrls.get(key);
    const url = URL.createObjectURL(blob);
    this.blobUrls.set(key, url);
    return url;
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
    const cached = this.fileBlobs.get(key);
    if (cached instanceof Blob) return cached;
    if (cached) {
      // an in-flight read: join it, and bump its priority if this caller is more urgent
      if (this.downloads.has(file.id)) this.download(file, { priority, onProgress, label });
      return cached;
    }
    const pending = (async () => {
      const f = await this.download(file, { priority, onProgress, label });
      const part = await this.send({ '@type': 'readFile', file_id: f.id });
      const data = part?.data;
      if (!(data instanceof Blob)) throw new Error('File is empty.');
      return mime && !data.type ? new Blob([data], { type: mime }) : data;
    })();
    this.fileBlobs.set(key, pending);
    try {
      const blob = await pending;
      this.fileBlobs.set(key, blob);
      return blob;
    } catch (e) {
      this.fileBlobs.delete(key);
      throw e;
    }
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
