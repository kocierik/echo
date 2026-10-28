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

import { extractMessage } from './extract.js';

const PAIRING_WAIT_MS = 20_000;
const MAX_BACKOFF_MS = 60_000;

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
  constructor({ dataDir, store, logger, connect = makeWASocket, fetchVersion = fetchLatestBaileysVersion }) {
    this.dataDir = dataDir;
    this.store = store;
    this.logger = logger;
    this.connect = connect;
    this.fetchVersion = fetchVersion;
    // userId -> {sock, state, phone, retries, stopped, onPairable}
    this.sessions = new Map();
  }

  status(userId) {
    const session = this.sessions.get(userId);
    return { state: session?.state ?? 'unlinked', phone: session?.phone ?? null };
  }

  /** The users linked before a restart: their keys are on disk. */
  async restore() {
    let entries = [];
    try {
      entries = await readdir(this.dataDir);
    } catch {
      return;
    }
    for (const userId of entries) {
      try {
        await stat(path.join(this.dataDir, userId, 'creds.json'));
        await this.#start(userId);
      } catch (error) {
        this.logger?.warn({ userId, err: error }, 'could not restore a session');
      }
    }
  }

  /** A fresh link: the pairing code the user types in WhatsApp → Linked devices. */
  async link(userId, phone) {
    if (this.sessions.get(userId)?.state === 'linked') throw failure(409, 'already linked');
    await this.#stop(userId, { forget: true });
    const pairable = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(failure(504, 'WhatsApp did not answer')), PAIRING_WAIT_MS);
      this.#pending.set(userId, () => {
        clearTimeout(timer);
        resolve();
      });
    });
    const session = await this.#start(userId);
    session.state = 'linking';
    await pairable;
    return session.sock.requestPairingCode(phone);
  }

  /** Logs the device out and forgets its keys and messages. */
  async unlink(userId) {
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

  #pending = new Map();

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

  async #start(userId, retries = 0) {
    const { state, saveCreds } = await useMultiFileAuthState(path.join(this.dataDir, userId));
    let version;
    try {
      ({ version } = await this.fetchVersion());
    } catch {
      // Baileys' own default
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
      state: state.creds.registered ? 'linked' : 'unlinked',
      phone: phoneOf(state.creds.me?.id),
      retries,
      stopped: false,
    };
    this.sessions.set(userId, session);

    sock.ev.on('creds.update', saveCreds);

    sock.ev.on('connection.update', ({ connection, lastDisconnect, qr }) => {
      if (qr) {
        // The socket can now ask for a pairing code
        this.#pending.get(userId)?.();
        this.#pending.delete(userId);
      }
      if (connection === 'open') {
        session.state = 'linked';
        session.phone = phoneOf(sock.user?.id) ?? session.phone;
        session.retries = 0;
      }
      if (connection === 'close') this.#closed(userId, session, lastDisconnect);
    });

    sock.ev.on('messages.upsert', ({ messages }) => this.#keep(userId, messages));

    sock.ev.on('messaging-history.set', ({ contacts, messages }) => {
      this.#name(userId, contacts);
      this.#keep(userId, messages);
    });

    sock.ev.on('contacts.upsert', (contacts) => this.#name(userId, contacts));
    sock.ev.on('contacts.update', (contacts) => this.#name(userId, contacts));
    return session;
  }

  #closed(userId, session, lastDisconnect) {
    if (session.stopped || this.sessions.get(userId) !== session) return;
    const code = lastDisconnect?.error?.output?.statusCode;
    if (code === DisconnectReason.loggedOut) {
      // Unlinked from the phone: nothing left to read
      this.logger?.warn({ userId }, 'logged out from the phone');
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
        const next = await this.#start(userId, session.retries + 1);
        if (linking && next.state !== 'linked') next.state = 'linking';
      } catch (error) {
        this.logger?.warn({ userId, err: error }, 'could not reconnect');
      }
    }, wait).unref();
  }

  #keep(userId, messages) {
    for (const waMessage of messages ?? []) {
      const message = extractMessage(waMessage);
      if (message) this.store.add(userId, message);
    }
  }

  #name(userId, contacts) {
    for (const contact of contacts ?? []) {
      const name = contact.name || contact.verifiedName;
      if (!name) continue;
      for (const jid of [contact.id, contact.phoneNumber, contact.lid]) {
        if (jid) this.store.setName(userId, jid, name);
      }
    }
  }
}
