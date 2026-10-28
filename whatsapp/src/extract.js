// A Baileys message as Echo keeps it: private chats only, text or a short placeholder
// for what is not text; reactions, protocol messages, groups and status are left out.

const WRAPPERS = [
  'ephemeralMessage',
  'viewOnceMessage',
  'viewOnceMessageV2',
  'viewOnceMessageV2Extension',
  'documentWithCaptionMessage',
  'editedMessage',
];

/** One to one chats: a phone number or a lid (WhatsApp's hidden id for a number). */
export function isPrivateJid(jid) {
  return typeof jid === 'string' && (jid.endsWith('@s.whatsapp.net') || jid.endsWith('@lid'));
}

function unwrap(message) {
  let current = message;
  for (let depth = 0; current && depth < 4; depth++) {
    const wrapper = WRAPPERS.find((name) => current[name]?.message);
    if (!wrapper) break;
    current = current[wrapper].message;
  }
  return current;
}

function withCaption(label, caption) {
  return caption ? `${label} ${caption}` : label;
}

function textOf(message) {
  if (!message) return null;
  if (typeof message.conversation === 'string') return message.conversation;
  if (message.extendedTextMessage?.text) return message.extendedTextMessage.text;
  if (message.imageMessage) return withCaption('[photo]', message.imageMessage.caption);
  if (message.videoMessage) return withCaption('[video]', message.videoMessage.caption);
  if (message.audioMessage) return message.audioMessage.ptt ? '[voice note]' : '[audio]';
  if (message.documentMessage) {
    const name = message.documentMessage.fileName || message.documentMessage.title;
    return withCaption(name ? `[document: ${name}]` : '[document]', message.documentMessage.caption);
  }
  if (message.stickerMessage) return '[sticker]';
  if (message.locationMessage || message.liveLocationMessage) {
    const place = message.locationMessage?.name || message.locationMessage?.address;
    return place ? `[location: ${place}]` : '[location]';
  }
  if (message.contactMessage) return `[contact: ${message.contactMessage.displayName || ''}]`.replace(': ]', ']');
  if (message.contactsArrayMessage) return '[contacts]';
  if (message.pollCreationMessage || message.pollCreationMessageV3) {
    const poll = message.pollCreationMessage || message.pollCreationMessageV3;
    return `[poll: ${poll.name || ''}]`.replace(': ]', ']');
  }
  return null;
}

function seconds(timestamp) {
  if (typeof timestamp === 'number') return timestamp;
  if (typeof timestamp === 'bigint') return Number(timestamp);
  if (timestamp && typeof timestamp.toNumber === 'function') return timestamp.toNumber();
  if (timestamp && typeof timestamp.low === 'number') return timestamp.low;
  return Number(timestamp) || 0;
}

/**
 * `{id, chat, fromMe, pushName, text, at}` (at in ms), or null for what Echo does not keep.
 * A chat addressed by lid is named by its phone number when WhatsApp gives it
 * (`remoteJidAlt`), so the same person is one chat.
 */
export function extractMessage(waMessage) {
  const key = waMessage?.key;
  if (!key || !isPrivateJid(key.remoteJid)) return null;
  const text = textOf(unwrap(waMessage.message));
  if (text === null || text.trim() === '') return null;
  const chat =
    key.remoteJid.endsWith('@lid') && key.remoteJidAlt?.endsWith('@s.whatsapp.net')
      ? key.remoteJidAlt
      : key.remoteJid;
  return {
    id: key.id,
    chat,
    fromMe: Boolean(key.fromMe),
    pushName: waMessage.pushName || null,
    text: text.trim(),
    at: seconds(waMessage.messageTimestamp) * 1000,
  };
}

const REVOKE = 0;
const MESSAGE_EDIT = 14;

function chatOf(key) {
  if (!key || !isPrivateJid(key.remoteJid)) return null;
  return key.remoteJid.endsWith('@lid') && key.remoteJidAlt?.endsWith('@s.whatsapp.net')
    ? key.remoteJidAlt
    : key.remoteJid;
}

/**
 * A message deleted for everyone (`text` null) or edited (`text` the new one), as
 * `{chat, id, text}`; null for anything else.
 */
export function extractChange(waMessage) {
  const protocol = unwrap(waMessage?.message)?.protocolMessage;
  const target = protocol?.key;
  if (!target?.id) return null;
  const chat = chatOf(target) ?? chatOf(waMessage.key);
  if (!chat) return null;
  if (protocol.type === REVOKE) return { chat, id: target.id, text: null };
  if (protocol.type === MESSAGE_EDIT) {
    const text = textOf(unwrap(protocol.editedMessage));
    return text?.trim() ? { chat, id: target.id, text: text.trim() } : null;
  }
  return null;
}
