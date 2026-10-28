import assert from 'node:assert/strict';
import { test } from 'node:test';

import { MessageStore } from '../src/store.js';

const DAY = 24 * 3600 * 1000;
const NOW = Date.UTC(2026, 9, 28, 12);
const MARCO = '393331112222@s.whatsapp.net';
const ADA = '393334445555@s.whatsapp.net';

function message(id, chat, text, at, extra = {}) {
  return { id, chat, fromMe: false, pushName: 'Marco', text, at, ...extra };
}

function store(options = {}) {
  return new MessageStore({ now: () => NOW, ...options });
}

test('both sides of a chat, oldest first', () => {
  const s = store();
  s.add('u1', message('1', MARCO, 'Ci vediamo alle 9?', NOW - 3000));
  s.add('u1', message('2', MARCO, 'Sì, a dopo', NOW - 2000, { fromMe: true }));

  assert.deepEqual(
    s.messages('u1', { chat: MARCO }).map((m) => [m.text, m.fromMe]),
    [['Ci vediamo alle 9?', false], ['Sì, a dopo', true]],
  );
});

test('the same message twice is kept once', () => {
  const s = store();
  s.add('u1', message('1', MARCO, 'Ciao', NOW - 1000));
  s.add('u1', message('1', MARCO, 'Ciao', NOW - 1000));

  assert.equal(s.messages('u1', { chat: MARCO }).length, 1);
});

test('nothing older than seven days', () => {
  let now = NOW;
  const s = new MessageStore({ now: () => now });
  s.add('u1', message('old', MARCO, 'Vecchio', NOW - 8 * DAY));
  s.add('u1', message('1', MARCO, 'Ieri', NOW - DAY));
  assert.deepEqual(s.messages('u1', { chat: MARCO }).map((m) => m.id), ['1']);

  now = NOW + 7 * DAY;
  assert.deepEqual(s.messages('u1', { chat: MARCO }), []);
});

test('past the cap the oldest go first', () => {
  const s = store({ cap: 3 });
  for (let i = 0; i < 5; i++) s.add('u1', message(`${i}`, MARCO, `m${i}`, NOW - (10 - i) * 1000));

  assert.deepEqual(s.messages('u1', { chat: MARCO }).map((m) => m.id), ['2', '3', '4']);
});

test('a chat is found by a part of its name, the contact name before the push name', () => {
  const s = store();
  s.add('u1', message('1', MARCO, 'Ciao', NOW - 1000, { pushName: 'Marchino' }));
  s.add('u1', message('2', ADA, 'Hello', NOW - 500, { pushName: 'Ada' }));
  s.setName('u1', MARCO, 'Marco Rossi');

  assert.deepEqual(s.messages('u1', { name: 'marco' }).map((m) => m.id), ['1']);
  assert.deepEqual(s.messages('u1', { name: 'ROSSI' }).map((m) => m.id), ['1']);
  assert.deepEqual(s.messages('u1', { name: 'nessuno' }), []);
  assert.equal(s.chats('u1')[1].name, 'Marco Rossi');
});

test('my own push name never names a chat', () => {
  const s = store();
  s.add('u1', message('1', MARCO, 'Ciao', NOW - 1000, { fromMe: true, pushName: 'Erik' }));

  assert.equal(s.chats('u1')[0].name, '+393331112222');
});

test('chats newest first with their last message', () => {
  const s = store();
  s.add('u1', message('1', MARCO, 'Prima', NOW - 3000));
  s.add('u1', message('2', ADA, 'Dopo', NOW - 1000, { pushName: 'Ada' }));
  s.add('u1', message('3', MARCO, 'Ultima di Marco', NOW - 2000));

  assert.deepEqual(
    s.chats('u1').map((c) => [c.chat, c.name, c.lastText, c.count]),
    [[ADA, 'Ada', 'Dopo', 1], [MARCO, 'Marco', 'Ultima di Marco', 2]],
  );
  assert.equal(s.chats('u1', { limit: 1 }).length, 1);
});

test('since and limit keep the latest', () => {
  const s = store();
  for (let i = 0; i < 5; i++) s.add('u1', message(`${i}`, MARCO, `m${i}`, NOW - (5 - i) * 1000));

  assert.deepEqual(s.messages('u1', { chat: MARCO, since: NOW - 3000 }).map((m) => m.id), ['2', '3', '4']);
  assert.deepEqual(s.messages('u1', { chat: MARCO, limit: 2 }).map((m) => m.id), ['3', '4']);
});

test('users are apart; clear forgets one', () => {
  const s = store();
  s.add('u1', message('1', MARCO, 'Ciao', NOW - 1000));
  s.add('u2', message('1', MARCO, 'Altro', NOW - 1000));
  s.clear('u1');

  assert.deepEqual(s.chats('u1'), []);
  assert.equal(s.chats('u2').length, 1);
});
