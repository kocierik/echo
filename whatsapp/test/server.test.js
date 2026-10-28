import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';

import { createServer } from '../src/server.js';
import { MessageStore } from '../src/store.js';

const NOW = Date.UTC(2026, 9, 28, 12);
const MARCO = '393331112222@s.whatsapp.net';
const TOKEN = 'secret';

class FakeSessions {
  constructor() {
    this.linked = [];
    this.unlinked = [];
    this.states = new Map();
  }

  status(userId) {
    return this.states.get(userId) ?? { state: 'unlinked', phone: null };
  }

  async link(userId, phone) {
    this.linked.push([userId, phone]);
    return 'ABCD1234';
  }

  async unlink(userId) {
    this.unlinked.push(userId);
  }
}

let server;
let base;
let sessions;
let store;

before(async () => {
  sessions = new FakeSessions();
  store = new MessageStore({ now: () => NOW });
  store.add('u1', { id: '1', chat: MARCO, fromMe: false, pushName: 'Marco', text: 'Alle 9?', at: NOW - 2000 });
  store.add('u1', { id: '2', chat: MARCO, fromMe: true, pushName: null, text: 'Sì', at: NOW - 1000 });
  server = createServer({ token: TOKEN, sessions, store });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

function call(path, { method = 'GET', body, token = TOKEN } = {}) {
  return fetch(`${base}${path}`, {
    method,
    headers: {
      ...(token ? { 'X-Bridge-Token': token } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

test('without the token nothing answers', async () => {
  assert.equal((await call('/users/u1/status', { token: null })).status, 401);
  assert.equal((await call('/users/u1/status', { token: 'wrong' })).status, 401);
});

test('status says the session state', async () => {
  sessions.states.set('u2', { state: 'linked', phone: '+393330000000' });

  assert.deepEqual(await (await call('/users/u1/status')).json(), { state: 'unlinked', phone: null });
  assert.deepEqual(await (await call('/users/u2/status')).json(), {
    state: 'linked',
    phone: '+393330000000',
  });
});

test('linking takes the number as digits and answers the pairing code', async () => {
  const response = await call('/users/u1/link', { method: 'POST', body: { phone: '+39 333 111-2222' } });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { code: 'ABCD1234' });
  assert.deepEqual(sessions.linked.at(-1), ['u1', '393331112222']);
});

test('a number that is not one is refused', async () => {
  const response = await call('/users/u1/link', { method: 'POST', body: { phone: '12' } });

  assert.equal(response.status, 400);
});

test('chats and messages, with ISO times and who wrote', async () => {
  const chats = await (await call('/users/u1/chats?limit=5')).json();
  assert.deepEqual(chats, {
    chats: [
      {
        chat: MARCO,
        name: 'Marco',
        last_at: new Date(NOW - 1000).toISOString(),
        last_text: 'Sì',
        last_from_me: true,
        count: 2,
      },
    ],
  });

  const since = encodeURIComponent(new Date(NOW - 1500).toISOString());
  const messages = await (await call(`/users/u1/messages?name=marco&since=${since}`)).json();
  assert.deepEqual(messages, {
    messages: [
      { chat: MARCO, name: 'Marco', from_me: true, text: 'Sì', at: new Date(NOW - 1000).toISOString() },
    ],
  });
});

test('unlinking ends the session and forgets the messages', async () => {
  store.add('u3', { id: '1', chat: MARCO, fromMe: false, pushName: 'Marco', text: 'Ciao', at: NOW - 1000 });

  const response = await call('/users/u3', { method: 'DELETE' });

  assert.equal(response.status, 204);
  assert.deepEqual(sessions.unlinked, ['u3']);
  assert.deepEqual(store.chats('u3'), []);
});

test('an unknown path is 404', async () => {
  assert.equal((await call('/nowhere')).status, 404);
});
