// What the final review found: abandoned links, crashes, unlink races, bans, deleted and
// edited messages, and the same person as two chats.

import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { access, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { beforeEach, test } from 'node:test';

import { extractChange } from '../src/extract.js';
import { Sessions } from '../src/sessions.js';
import { MessageStore } from '../src/store.js';

const MARCO = '393331112222@s.whatsapp.net';
const MARCO_LID = '777@lid';
const NOW = Date.UTC(2026, 9, 28, 12);

let sockets;
let store;
let dataDir;

function fakeSocket() {
  const sock = {
    ev: new EventEmitter(),
    end() {},
    async logout() {},
    async requestPairingCode() {
      return 'ABCD1234';
    },
  };
  sockets.push(sock);
  return sock;
}

const settle = (ms = 20) => new Promise((resolve) => setTimeout(resolve, ms));

/** Until `count` sockets exist (a start does disk I/O first). */
async function sockets_(count) {
  for (let i = 0; i < 200 && sockets.length < count; i++) await settle(10);
}

function sessions(options = {}) {
  return new Sessions({
    dataDir,
    store,
    connect: fakeSocket,
    fetchVersion: async () => ({ version: [2, 3000, 1] }),
    pairingWaitMs: 50,
    ...options,
  });
}

beforeEach(async () => {
  sockets = [];
  store = new MessageStore();
  dataDir = await mkdtemp(path.join(tmpdir(), 'wa-'));
});

test('a link WhatsApp never answers is given up, not left trying', async () => {
  const s = sessions();

  await assert.rejects(s.link('u1', '393330000000'), { status: 504 });

  assert.equal(s.status('u1').state, 'unlinked');
  await assert.rejects(access(path.join(dataDir, 'u1')));
});

test('a start that fails while linking is an error, never a crash', async () => {
  const s = sessions({
    connect: () => {
      throw new Error('EACCES');
    },
  });

  await assert.rejects(s.link('u1', '393330000000'));
  // The pairing timer must not reject a promise nobody handles
  await settle(80);
});

test('a link closed before it was ever registered is forgotten', async () => {
  const s = sessions({ pairingWaitMs: 1000 });
  const code = s.link('u1', '393330000000');
  await sockets_(1);
  sockets[0].ev.emit('connection.update', { qr: 'qr' });
  await code;

  // The user never typed the code: WhatsApp's QR refs run out
  sockets[0].ev.emit('connection.update', {
    connection: 'close',
    lastDisconnect: { error: { output: { statusCode: 408 } } },
  });
  await settle();

  assert.equal(s.status('u1').state, 'unlinked');
  assert.equal(sockets.length, 1);
});

test('a ban is said, and the keys forgotten', async () => {
  const s = sessions({ pairingWaitMs: 1000 });
  const code = s.link('u1', '393330000000');
  await sockets_(1);
  sockets[0].ev.emit('connection.update', { qr: 'qr' });
  await code;
  sockets[0].user = { id: '393330000000:1@s.whatsapp.net' };
  sockets[0].ev.emit('connection.update', { connection: 'open' });

  sockets[0].ev.emit('connection.update', {
    connection: 'close',
    lastDisconnect: { error: { output: { statusCode: 403 } } },
  });
  await settle();

  assert.equal(s.status('u1').state, 'blocked');
  await assert.rejects(access(path.join(dataDir, 'u1')));
});

test('history still arriving after an unlink is not kept', async () => {
  const s = sessions({ pairingWaitMs: 1000 });
  const code = s.link('u1', '393330000000');
  await sockets_(1);
  sockets[0].ev.emit('connection.update', { qr: 'qr' });
  await code;
  const sock = sockets[0];

  await s.unlink('u1');
  sock.ev.emit('messaging-history.set', {
    contacts: [],
    messages: [{
      key: { remoteJid: MARCO, id: 'H1' },
      message: { conversation: 'Tardi' },
      messageTimestamp: Math.floor(Date.now() / 1000),
    }],
  });

  assert.deepEqual(store.chats('u1'), []);
});

test('a reconnect that lands after an unlink does not come back', async () => {
  let release;
  const slow = new Promise((resolve) => {
    release = resolve;
  });
  let starts = 0;
  const s = sessions({
    pairingWaitMs: 1000,
    authState: async (folder) => {
      starts++;
      // The reconnect waits here, as on a slow disk
      if (starts > 1) await slow;
      const { useMultiFileAuthState } = await import('baileys');
      return useMultiFileAuthState(folder);
    },
  });
  const code = s.link('u1', '393330000000');
  await sockets_(1);
  sockets[0].ev.emit('connection.update', { qr: 'qr' });
  await code;
  sockets[0].user = { id: '393330000000:1@s.whatsapp.net' };
  sockets[0].ev.emit('connection.update', { connection: 'open' });
  // Linked for real: a drop now reconnects
  s.sessions.get('u1').creds.registered = true;

  sockets[0].ev.emit('connection.update', {
    connection: 'close',
    lastDisconnect: { error: { output: { statusCode: 428 } } },
  });
  await settle(1100);
  await s.unlink('u1');
  release();
  await settle(100);

  assert.equal(s.status('u1').state, 'unlinked');
  assert.equal(sockets.length, 1);
  await assert.rejects(access(path.join(dataDir, 'u1')));
});

test('a message deleted for everyone goes; an edited one changes', () => {
  const s = new MessageStore({ now: () => NOW });
  s.add('u1', { id: 'A', chat: MARCO, fromMe: false, pushName: 'Marco', text: 'Ops', at: NOW - 2000 });
  s.add('u1', { id: 'B', chat: MARCO, fromMe: false, pushName: 'Marco', text: 'Alle 8', at: NOW - 1000 });

  const revoke = extractChange({
    key: { remoteJid: MARCO, id: 'X' },
    message: { protocolMessage: { type: 0, key: { remoteJid: MARCO, id: 'A' } } },
  });
  const edit = extractChange({
    key: { remoteJid: MARCO, id: 'Y' },
    message: {
      protocolMessage: {
        type: 14,
        key: { remoteJid: MARCO, id: 'B' },
        editedMessage: { conversation: 'Alle 9' },
      },
    },
  });
  assert.deepEqual(revoke, { chat: MARCO, id: 'A', text: null });
  assert.deepEqual(edit, { chat: MARCO, id: 'B', text: 'Alle 9' });

  s.change('u1', revoke);
  s.change('u1', edit);

  assert.deepEqual(s.messages('u1', { chat: MARCO }).map((m) => m.text), ['Alle 9']);
});

test('a person known by lid and by number is one chat', () => {
  const s = new MessageStore({ now: () => NOW });
  s.add('u1', { id: '1', chat: MARCO_LID, fromMe: false, pushName: 'Marco', text: 'Dalla cronologia', at: NOW - 3000 });
  s.alias('u1', MARCO_LID, MARCO);
  s.add('u1', { id: '2', chat: MARCO, fromMe: false, pushName: 'Marco', text: 'Dal vivo', at: NOW - 2000 });
  s.add('u1', { id: '3', chat: MARCO_LID, fromMe: true, pushName: null, text: 'Risposta', at: NOW - 1000 });

  assert.equal(s.chats('u1').length, 1);
  assert.deepEqual(
    s.messages('u1', { chat: MARCO }).map((m) => m.text),
    ['Dalla cronologia', 'Dal vivo', 'Risposta'],
  );
});

test('the sessions learn lid and number pairs, and apply changes', async () => {
  const s = sessions({ pairingWaitMs: 1000 });
  const code = s.link('u1', '393330000000');
  await sockets_(1);
  sockets[0].ev.emit('connection.update', { qr: 'qr' });
  await code;
  const sock = sockets[0];
  const at = Math.floor(Date.now() / 1000);

  sock.ev.emit('messaging-history.set', {
    contacts: [],
    lidPnMappings: [{ lid: MARCO_LID, pn: MARCO }],
    messages: [{ key: { remoteJid: MARCO_LID, id: 'H1' }, message: { conversation: 'Ciao' }, messageTimestamp: at }],
  });
  sock.ev.emit('messages.upsert', {
    messages: [{
      key: { remoteJid: MARCO, id: 'R1' },
      message: { protocolMessage: { type: 0, key: { remoteJid: MARCO_LID, id: 'H1' } } },
      messageTimestamp: at,
    }],
  });

  assert.deepEqual(store.messages('u1', { chat: MARCO }), []);
});
