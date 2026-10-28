import assert from 'node:assert/strict';
import { test } from 'node:test';

import { extractMessage, isPrivateJid } from '../src/extract.js';

const at = 1761638400; // 2025-10-28T08:00:00Z

function wa(message, key = {}) {
  return {
    key: { remoteJid: '393331112222@s.whatsapp.net', fromMe: false, id: 'M1', ...key },
    message,
    messageTimestamp: at,
    pushName: 'Marco',
  };
}

test('a text from a private chat', () => {
  assert.deepEqual(extractMessage(wa({ conversation: 'Ci vediamo alle 9?' })), {
    id: 'M1',
    chat: '393331112222@s.whatsapp.net',
    fromMe: false,
    pushName: 'Marco',
    text: 'Ci vediamo alle 9?',
    at: at * 1000,
  });
});

test('extended text, captions and wrapped messages', () => {
  assert.equal(extractMessage(wa({ extendedTextMessage: { text: 'Guarda qui' } })).text, 'Guarda qui');
  assert.equal(extractMessage(wa({ imageMessage: { caption: 'La lavagna' } })).text, '[photo] La lavagna');
  assert.equal(extractMessage(wa({ imageMessage: {} })).text, '[photo]');
  assert.equal(
    extractMessage(wa({ ephemeralMessage: { message: { conversation: 'Sparisce' } } })).text,
    'Sparisce',
  );
  assert.equal(
    extractMessage(wa({ viewOnceMessageV2: { message: { videoMessage: { caption: 'Una volta' } } } })).text,
    '[video] Una volta',
  );
});

test('what is not text says what it was', () => {
  assert.equal(extractMessage(wa({ audioMessage: { ptt: true } })).text, '[voice note]');
  assert.equal(extractMessage(wa({ audioMessage: {} })).text, '[audio]');
  assert.equal(
    extractMessage(wa({ documentMessage: { fileName: 'preventivo.pdf' } })).text,
    '[document: preventivo.pdf]',
  );
  assert.equal(extractMessage(wa({ stickerMessage: {} })).text, '[sticker]');
  assert.equal(
    extractMessage(wa({ locationMessage: { name: 'Bar Roma' } })).text,
    '[location: Bar Roma]',
  );
  assert.equal(
    extractMessage(wa({ contactMessage: { displayName: 'Ada' } })).text,
    '[contact: Ada]',
  );
});

test('what the user sent is kept, marked as theirs', () => {
  const sent = extractMessage(wa({ conversation: 'Arrivo' }, { fromMe: true }));
  assert.equal(sent.fromMe, true);
});

test('a timestamp as a protobuf Long', () => {
  const message = wa({ conversation: 'Ciao' });
  message.messageTimestamp = { low: at, high: 0, toNumber: () => at };
  assert.equal(extractMessage(message).at, at * 1000);
});

test('a chat addressed by lid uses its phone number when WhatsApp gives it', () => {
  const message = wa(
    { conversation: 'Ciao' },
    { remoteJid: '1234567@lid', remoteJidAlt: '393331112222@s.whatsapp.net' },
  );
  assert.equal(extractMessage(message).chat, '393331112222@s.whatsapp.net');
  const onlyLid = wa({ conversation: 'Ciao' }, { remoteJid: '1234567@lid' });
  assert.equal(extractMessage(onlyLid).chat, '1234567@lid');
});

test('groups, status, broadcasts, reactions and protocol messages are left out', () => {
  assert.equal(extractMessage(wa({ conversation: 'Ciao' }, { remoteJid: '1203@g.us' })), null);
  assert.equal(extractMessage(wa({ conversation: 'Ciao' }, { remoteJid: 'status@broadcast' })), null);
  assert.equal(extractMessage(wa({ conversation: 'Ciao' }, { remoteJid: '1@newsletter' })), null);
  assert.equal(extractMessage(wa({ reactionMessage: { text: '👍' } })), null);
  assert.equal(extractMessage(wa({ protocolMessage: { type: 0 } })), null);
  assert.equal(extractMessage(wa(undefined)), null);
});

test('private jids', () => {
  assert.equal(isPrivateJid('393331112222@s.whatsapp.net'), true);
  assert.equal(isPrivateJid('1234567@lid'), true);
  assert.equal(isPrivateJid('1203@g.us'), false);
  assert.equal(isPrivateJid('status@broadcast'), false);
  assert.equal(isPrivateJid(undefined), false);
});
