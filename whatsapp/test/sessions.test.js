import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { access, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { beforeEach, test } from 'node:test';

import { Sessions } from '../src/sessions.js';
import { MessageStore } from '../src/store.js';

const MARCO = '393331112222@s.whatsapp.net';

let sockets;
let store;
let sessions;
let dataDir;

function fakeSocket() {
  const sock = {
    ev: new EventEmitter(),
    user: undefined,
    ended: 0,
    loggedOut: 0,
    end() {
      this.ended++;
    },
    async logout() {
      this.loggedOut++;
    },
    async requestPairingCode(phone) {
      this.paired = phone;
      return 'ABCD1234';
    },
  };
  sockets.push(sock);
  return sock;
}

const settle = (ms = 20) => new Promise((resolve) => setTimeout(resolve, ms));

/** Until `condition()` holds, at most ~2 s: link and reconnect do disk I/O first, slow on CI. */
async function until(condition) {
  for (let i = 0; i < 200 && !(await condition()); i++) await settle(10);
}

const folderGone = (userId) => access(path.join(dataDir, userId)).then(() => false, () => true);

beforeEach(async () => {
  sockets = [];
  store = new MessageStore();
  dataDir = await mkdtemp(path.join(tmpdir(), 'wa-'));
  sessions = new Sessions({
    dataDir,
    store,
    connect: fakeSocket,
    fetchVersion: async () => ({ version: [2, 3000, 1] }),
  });
});

async function linked(userId = 'u1') {
  const code = sessions.link(userId, '393330000000');
  await until(() => sessions.status(userId).state === 'linking');
  sockets.at(-1).ev.emit('connection.update', { qr: 'qr-data' });
  assert.equal(await code, 'ABCD1234');
  const sock = sockets.at(-1);
  sock.user = { id: '393330000000:12@s.whatsapp.net' };
  sock.ev.emit('connection.update', { connection: 'open' });
  return sock;
}

test('linking gives the pairing code once WhatsApp is ready, then the number', async () => {
  const code = sessions.link('u1', '393330000000');
  await until(() => sessions.status('u1').state === 'linking');
  assert.equal(sessions.status('u1').state, 'linking');

  sockets[0].ev.emit('connection.update', { qr: 'qr-data' });
  assert.equal(await code, 'ABCD1234');
  assert.equal(sockets[0].paired, '393330000000');

  sockets[0].user = { id: '393330000000:12@s.whatsapp.net' };
  sockets[0].ev.emit('connection.update', { connection: 'open' });
  assert.deepEqual(sessions.status('u1'), { state: 'linked', phone: '+393330000000' });
});

test('private messages and the history go to the store, named by the contacts', async () => {
  const sock = await linked();
  const now = Math.floor(Date.now() / 1000);

  sock.ev.emit('messaging-history.set', {
    contacts: [{ id: MARCO, name: 'Marco Rossi' }],
    messages: [
      { key: { remoteJid: MARCO, id: 'H1', fromMe: false }, message: { conversation: 'Ieri' }, messageTimestamp: now - 3600 },
    ],
  });
  sock.ev.emit('messages.upsert', {
    type: 'notify',
    messages: [
      { key: { remoteJid: MARCO, id: 'N1', fromMe: false }, message: { conversation: 'Alle 9?' }, messageTimestamp: now },
      { key: { remoteJid: '1203@g.us', id: 'G1', fromMe: false }, message: { conversation: 'Gruppo' }, messageTimestamp: now },
    ],
  });

  assert.deepEqual(
    store.messages('u1', { name: 'rossi' }).map((m) => m.text),
    ['Ieri', 'Alle 9?'],
  );
  assert.equal(store.chats('u1').length, 1);
});

test('logged out from the phone: keys and messages are gone', async () => {
  const sock = await linked();
  sock.ev.emit('messages.upsert', {
    messages: [{ key: { remoteJid: MARCO, id: 'N1' }, message: { conversation: 'Ciao' }, messageTimestamp: Math.floor(Date.now() / 1000) }],
  });

  sock.ev.emit('connection.update', {
    connection: 'close',
    lastDisconnect: { error: { output: { statusCode: 401 } } },
  });
  await until(async () => sessions.status('u1').state === 'unlinked' && (await folderGone('u1')));

  assert.equal(sessions.status('u1').state, 'unlinked');
  assert.deepEqual(store.chats('u1'), []);
  await assert.rejects(access(path.join(dataDir, 'u1')));
});

test('unlink logs the device out and deletes its keys', async () => {
  const sock = await linked();

  await sessions.unlink('u1');

  assert.equal(sock.loggedOut, 1);
  assert.equal(sessions.status('u1').state, 'unlinked');
  await assert.rejects(access(path.join(dataDir, 'u1')));
});

test('a dropped connection connects again', async () => {
  const sock = await linked();

  sock.ev.emit('connection.update', {
    connection: 'close',
    lastDisconnect: { error: { output: { statusCode: 515 } } },
  });
  await until(() => sockets.length === 2);

  assert.equal(sockets.length, 2);
});

test('linking an account already linked is refused', async () => {
  await linked();

  await assert.rejects(sessions.link('u1', '393330000000'), { status: 409 });
});
