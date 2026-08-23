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

export class Td {
  constructor() {
    this.client = null;
    this.authState = null;
    this.connectionState = null;
    this.tdlibVersion = null;
    this.listeners = new Map();
    this.fileWaiters = new Map();
    this.blobUrls = new Map();
    this.fileBlobs = new Map();
    this.floodUntil = 0;
    this.onFloodWait = null;
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
      this.connectionState = update.state?.['@type'] ?? null;
      this.emit('connection', this.connectionState);
    } else if (type === 'updateFile') {
      const f = update.file;
      if (f?.local?.is_downloading_completed) {
        const waiters = this.fileWaiters.get(f.id);
        if (waiters) {
          this.fileWaiters.delete(f.id);
          for (const w of waiters) w.resolve(f);
        }
      }
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

  /** Resolve a File object to a blob: URL, cached by remote.unique_id. */
  async fileUrl(file) {
    if (!file || !file.id) return null;
    const key = file.remote?.unique_id || `id:${file.id}`;
    if (this.blobUrls.has(key)) return this.blobUrls.get(key);
    const blob = await this.fileBlob(file);
    if (!blob) return null;
    const url = URL.createObjectURL(blob);
    this.blobUrls.set(key, url);
    return url;
  }

  async fileBlob(file) {
    const key = file.remote?.unique_id || `id:${file.id}`;
    if (this.fileBlobs.has(key)) return this.fileBlobs.get(key);
    const pending = (async () => {
      let f = file;
      if (!f.local?.is_downloading_completed) {
        const done = new Promise((resolve, reject) => {
          const set = this.fileWaiters.get(file.id) ?? new Set();
          set.add({ resolve, reject });
          this.fileWaiters.set(file.id, set);
        });
        const res = await this.send({ '@type': 'downloadFile', file_id: file.id, priority: 1, offset: 0, limit: 0, synchronous: false });
        if (res?.local?.is_downloading_completed) {
          this.fileWaiters.delete(file.id);
          f = res;
        } else {
          f = await Promise.race([done, new Promise((_, rej) => setTimeout(() => rej(new Error('Download timed out.')), 90000))]);
        }
      }
      const part = await this.send({ '@type': 'readFile', file_id: f.id });
      const data = part?.data;
      if (!(data instanceof Blob)) return null;
      return data;
    })();
    this.fileBlobs.set(key, pending);
    try {
      const blob = await pending;
      this.fileBlobs.set(key, blob);
      return blob;
    } catch (e) {
      this.fileBlobs.delete(key);
      console.warn('[td] file', e.message);
      return null;
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
