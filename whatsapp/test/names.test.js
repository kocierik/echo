// The contacts' names: by lid resolved to the chat's number from the keys, kept on disk
// across a restart (never the messages), and asked again from WhatsApp when lost.

import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { beforeEach, test } from 'node:test';

import { Sessions } from '../src/sessions.js';
import { MessageStore } from '../src/store.js';

const MARCO = '393331112222@s.whatsapp.net';
const MARCO_LID = '123456789@lid';

let sockets;
let dataDir;

function fakeSocket({ mapping = {} } = {}) {
  return () => {
    const sock = {
      ev: new EventEmitter(),
      user: { id: '393330000000:12@s.whatsapp.net' },
      resynced: [],
      end() {},
      signalRepository: {
        lidMapping: {
          // As Baileys gives them: the number with its device
          async getPNsForLIDs(lids) {
            return lids.filter((lid) => mapping[lid]).map((lid) => ({ lid, pn: mapping[lid] }));
          },
        },
      },
      async resyncAppState(collections) {
        this.resynced.push(collections);
      },
    };
    sockets.push(sock);
    return sock;
  };
}

/** A user linked before: their keys on disk, registered. */
function restoredAuth(keysSet) {
  return async () => ({
    state: {
      creds: { registered: true, me: { id: '393330000000:12@s.whatsapp.net' } },
      keys: { set: async (data) => keysSet.push(data) },
    },
    saveCreds: async () => {},
  });
}

const settle = (ms = 30) => new Promise((resolve) => setTimeout(resolve, ms));

async function until(condition) {
  for (let i = 0; i < 200 && !(await condition()); i++) await settle(10);
}

beforeEach(async () => {
  sockets = [];
  dataDir = await mkdtemp(path.join(tmpdir(), 'wa-names-'));
  await mkdir(path.join(dataDir, 'u1'));
  await writeFile(path.join(dataDir, 'u1', 'creds.json'), '{}');
});

function sessionsWith({ store, mapping, keysSet = [] }) {
  return new Sessions({
    dataDir,
    store,
    connect: fakeSocket({ mapping }),
    fetchVersion: async () => ({ version: [2, 3000, 1] }),
    authState: restoredAuth(keysSet),
    namesWaitMs: 5,
  });
}

test('a contact WhatsApp names by lid only names the chat of its number', async () => {
  const store = new MessageStore();
  const sessions = sessionsWith({ store, mapping: { [MARCO_LID]: '393331112222:0@s.whatsapp.net' } });
  await sessions.restore();
  const sock = sockets[0];
  sock.ev.emit('connection.update', { connection: 'open' });
  const now = Math.floor(Date.now() / 1000);

  sock.ev.emit('messages.upsert', {
    messages: [{ key: { remoteJid: MARCO, id: 'N1' }, message: { conversation: 'Alle 9?' }, messageTimestamp: now }],
  });
  sock.ev.emit('contacts.upsert', [{ id: MARCO_LID, name: 'Marco Rossi' }]);

  await until(() => store.chats('u1')[0]?.name === 'Marco Rossi');
  assert.equal(store.chats('u1')[0].name, 'Marco Rossi');
  assert.deepEqual(store.unaliasedLids('u1'), []);
  sessions.close();
});

test('the names are kept on disk, not the messages, and come back after a restart', async () => {
  let store = new MessageStore();
  let sessions = sessionsWith({ store });
  await sessions.restore();
  const now = Math.floor(Date.now() / 1000);
  sockets[0].ev.emit('messages.upsert', {
    messages: [{ key: { remoteJid: MARCO, id: 'N1' }, message: { conversation: 'Segreto' }, messageTimestamp: now }],
  });
  sockets[0].ev.emit('contacts.upsert', [{ id: MARCO, name: 'Marco Rossi' }]);

  const file = path.join(dataDir, 'u1', 'echo-names.json');
  await until(() => readFile(file, 'utf8').then(() => true, () => false));
  const kept = await readFile(file, 'utf8');
  assert.match(kept, /Marco Rossi/);
  assert.doesNotMatch(kept, /Segreto/);
  sessions.close();

  // A restart: the messages are gone, the name is not
  store = new MessageStore();
  sessions = sessionsWith({ store });
  await sessions.restore();
  sockets[1].ev.emit('messages.upsert', {
    messages: [{ key: { remoteJid: MARCO, id: 'N2' }, message: { conversation: 'Ciao' }, messageTimestamp: now }],
  });
  assert.equal(store.chats('u1')[0].name, 'Marco Rossi');
  sessions.close();
});

test('restored without names: the address book is asked again once', async () => {
  const keysSet = [];
  const sessions = sessionsWith({ store: new MessageStore(), keysSet });
  await sessions.restore();

  sockets[0].ev.emit('connection.update', { connection: 'open' });
  sockets[0].ev.emit('connection.update', { connection: 'open' });
  await until(() => sockets[0].resynced.length > 0);

  assert.deepEqual(keysSet, [{ 'app-state-sync-version': { critical_unblock_low: null } }]);
  assert.deepEqual(sockets[0].resynced, [['critical_unblock_low']]);
  sessions.close();
});

test('restored with names: nothing is asked again', async () => {
  await writeFile(path.join(dataDir, 'u1', 'echo-names.json'), JSON.stringify([[MARCO, 'Marco']]));
  const keysSet = [];
  const sessions = sessionsWith({ store: new MessageStore(), keysSet });
  await sessions.restore();

  sockets[0].ev.emit('connection.update', { connection: 'open' });
  await settle(50);

  assert.deepEqual(keysSet, []);
  assert.deepEqual(sockets[0].resynced, []);
  sessions.close();
});

test('the store lists lids without a number, and restores names', () => {
  const store = new MessageStore();
  store.restoreNames('u1', [[MARCO_LID, 'Marco'], ['bad'], 'nope', [MARCO, 42]]);
  assert.deepEqual(store.unaliasedLids('u1'), [MARCO_LID]);

  store.alias('u1', MARCO_LID, MARCO);
  assert.deepEqual(store.unaliasedLids('u1'), []);
  assert.deepEqual(store.names('u1'), [[MARCO_LID, 'Marco'], [MARCO, 'Marco']]);
});
