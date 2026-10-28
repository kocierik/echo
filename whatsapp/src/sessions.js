// One WhatsApp linked device per Echo user, through Baileys (unofficial: WhatsApp may ban
// the number; the user chose it). Read-only: it never sends, never marks as read, never
// shows online. Its keys stay in `dataDir/<userId>` so a restart does not unlink it; its
// messages only go to the in-memory store.

import { readdir, rm, stat } from 'node:fs/promises';
import path from 'node:path';

import makeWASocket, {
  Browsers,
  DisconnectReason,
  fetchLatestBaileysVersion,
  useMultiFileAuthState,
} from 'baileys';

import { extractChange, extractMessage } from './extract.js';

const PAIRING_WAIT_MS = 20_000;
const MAX_BACKOFF_MS = 60_000;
const VERSION_WAIT_MS = 5_000;

function failure(status, publicMessage) {
  return Object.assign(new Error(publicMessage), { status, publicMessage });
}

function phoneOf(jid) {
  const user = jid?.split('@')[0]?.split(':')[0];
  return user ? `+${user}` : null;
}

// Groups, status, broadcasts and channels: WhatsApp need not even tell us
function ignored(jid) {
  return jid.endsWith('@g.us') || jid.endsWith('@broadcast') || jid.endsWith('@newsletter');
}

export class Sessions {
  constructor({
    dataDir,
    store,
    logger,
    connect = makeWASocket,
    fetchVersion = fetchLatestBaileysVersion,
    authState = useMultiFileAuthState,
    pairingWaitMs = PAIRING_WAIT_MS,
  }) {
    this.dataDir = dataDir;
    this.store = store;
    this.logger = logger;
    this.connect = connect;
    this.fetchVersion = fetchVersion;
    this.authState = authState;
    this.pairingWaitMs = pairingWaitMs;
    // userId -> {sock, creds, state, phone, retries, stopped}
    this.sessions = new Map();
    // Users WhatsApp refused (403: the number may be banned), until they link again
    this.blocked = new Set();
    this.pending = new Map();
    this.version = null;
  }

  status(userId) {
    const session = this.sessions.get(userId);
    if (!session && this.blocked.has(userId)) return { state: 'blocked', phone: null };
    return { state: session?.state ?? 'unlinked', phone: session?.phone ?? null };
  }

  /** The users linked before a restart (their keys are on disk), all at once. */
  async restore() {
    let entries = [];
    try {
      entries = await readdir(this.dataDir);
    } catch {
      return;
    }
    await Promise.allSettled(entries.map(async (userId) => {
      try {
        await stat(path.join(this.dataDir, userId, 'creds.json'));
        await this.#start(userId);
      } catch (error) {
        this.logger?.warn({ userId, err: error }, 'could not restore a session');
      }
    }));
  }

  /** A fresh link: the pairing code the user types in WhatsApp → Linked devices. */
  async link(userId, phone) {
    if (this.sessions.get(userId)?.state === 'linked') throw failure(409, 'already linked');
    await this.#stop(userId, { forget: true });
    this.blocked.delete(userId);
    let ready;
    const pairable = new Promise((resolve, reject) => {
      ready = { resolve, reject };
    });
    // Handled even when the start fails first: never an unhandled rejection
    pairable.catch(() => {});
    this.pending.set(userId, ready.resolve);
    const timer = setTimeout(
      () => ready.reject(failure(504, 'WhatsApp did not answer')),
      this.pairingWaitMs,
    );
    try {
      const session = await this.#start(userId);
      session.state = 'linking';
      await pairable;
      return await session.sock.requestPairingCode(phone);
    } catch (error) {
      // Nothing half-linked is left trying
      await this.#stop(userId, { forget: true });
      throw error;
    } finally {
      clearTimeout(timer);
      this.pending.delete(userId);
    }
  }

  /** Logs the device out and forgets its keys and messages. */
  async unlink(userId) {
    this.blocked.delete(userId);
    const session = this.sessions.get(userId);
    if (session) {
      session.stopped = true;
      try {
        await session.sock.logout();
      } catch (error) {
        this.logger?.warn({ userId, err: error }, 'logout failed');
      }
    }
    await this.#stop(userId, { forget: true });
  }

  /** Closes every socket without unlinking (shutdown). */
  close() {
    for (const session of this.sessions.values()) {
      session.stopped = true;
      session.sock.end(undefined);
    }
  }

  async #stop(userId, { forget }) {
    const session = this.sessions.get(userId);
    if (session) {
      session.stopped = true;
      try {
        session.sock.end(undefined);
      } catch {
        // already closed
      }
      this.sessions.delete(userId);
    }
    if (forget) {
      await rm(path.join(this.dataDir, userId), { recursive: true, force: true });
      this.store.clear(userId);
    }
  }

  /** WhatsApp's current version, asked once per process and never for long. */
  #currentVersion() {
    this.version ??= Promise.race([
      this.fetchVersion().then((found) => found?.version),
      new Promise((resolve) => setTimeout(resolve, VERSION_WAIT_MS).unref()),
    ]).catch(() => undefined);
    return this.version;
  }

  /** A socket for the user; null when `previous` was stopped meanwhile (an unlink). */
  async #start(userId, { retries = 0, previous = null } = {}) {
    if (previous?.stopped) return null;
    const folder = path.join(this.dataDir, userId);
    const { state, saveCreds } = await this.authState(folder);
    const version = await this.#currentVersion();
    if (previous?.stopped) {
      // Unlinked while this reconnect waited: what it just made goes too
      await rm(folder, { recursive: true, force: true });
      return null;
    }
    const sock = this.connect({
      auth: state,
      ...(version ? { version } : {}),
      logger: this.logger,
      browser: Browsers.macOS('Chrome'),
      markOnlineOnConnect: false,
      syncFullHistory: false,
      shouldIgnoreJid: ignored,
      getMessage: async () => undefined,
    });
    const session = {
      sock,
      creds: state.creds,
      state: state.creds.registered ? 'linked' : 'unlinked',
      phone: phoneOf(state.creds.me?.id),
      retries,
      stopped: false,
    };
    this.sessions.set(userId, session);
    // Events of a session that was stopped or replaced change nothing
    const live = () => !session.stopped && this.sessions.get(userId) === session;

    sock.ev.on('creds.update', saveCreds);

    sock.ev.on('connection.update', ({ connection, lastDisconnect, qr }) => {
      if (!live()) return;
      if (qr) {
        // The socket can now ask for a pairing code
        this.pending.get(userId)?.();
      }
      if (connection === 'open') {
        session.state = 'linked';
        session.phone = phoneOf(sock.user?.id) ?? session.phone;
        session.retries = 0;
      }
      if (connection === 'close') this.#closed(userId, session, lastDisconnect);
    });

    sock.ev.on('messages.upsert', ({ messages }) => {
      if (live()) this.#keep(userId, messages);
    });

    sock.ev.on('messaging-history.set', ({ contacts, messages, lidPnMappings }) => {
      if (!live()) return;
      for (const { lid, pn } of lidPnMappings ?? []) this.store.alias(userId, lid, pn);
      this.#name(userId, contacts);
      this.#keep(userId, messages);
    });

    sock.ev.on('lid-mapping.update', (mapping) => {
      if (live()) this.store.alias(userId, mapping?.lid, mapping?.pn);
    });
    sock.ev.on('contacts.upsert', (contacts) => {
      if (live()) this.#name(userId, contacts);
    });
    sock.ev.on('contacts.update', (contacts) => {
      if (live()) this.#name(userId, contacts);
    });
    return session;
  }

  #closed(userId, session, lastDisconnect) {
    const code = lastDisconnect?.error?.output?.statusCode;
    if (code === DisconnectReason.loggedOut || code === DisconnectReason.forbidden) {
      // Unlinked from the phone, or refused by WhatsApp: nothing left to read
      if (code === DisconnectReason.forbidden) this.blocked.add(userId);
      this.logger?.warn({ userId, code }, 'WhatsApp ended the session');
      void this.#stop(userId, { forget: true });
      return;
    }
    if (!session.creds.registered && code !== DisconnectReason.restartRequired) {
      // A link never completed (the code was not typed in time): given up
      this.logger?.warn({ userId, code }, 'link abandoned');
      void this.#stop(userId, { forget: true });
      return;
    }
    // A restart after pairing, or the network: connect again, waiting longer each time
    const wait = code === DisconnectReason.restartRequired
      ? 0
      : Math.min(1000 * 2 ** session.retries, MAX_BACKOFF_MS);
    const linking = session.state === 'linking';
    setTimeout(async () => {
      if (session.stopped || this.sessions.get(userId) !== session) return;
      try {
        const next = await this.#start(userId, { retries: session.retries + 1, previous: session });
        if (next && linking && next.state !== 'linked') next.state = 'linking';
      } catch (error) {
        this.logger?.warn({ userId, err: error }, 'could not reconnect');
      }
    }, wait).unref();
  }

  #keep(userId, messages) {
    for (const waMessage of messages ?? []) {
      const change = extractChange(waMessage);
      if (change) {
        this.store.change(userId, change);
        continue;
      }
      const message = extractMessage(waMessage);
      if (message) this.store.add(userId, message);
    }
  }

  #name(userId, contacts) {
    for (const contact of contacts ?? []) {
      if (contact.lid && contact.phoneNumber) this.store.alias(userId, contact.lid, contact.phoneNumber);
      const name = contact.name || contact.verifiedName;
      if (!name) continue;
      for (const jid of [contact.id, contact.phoneNumber, contact.lid]) {
        if (jid) this.store.setName(userId, jid, name);
      }
    }
  }
}
