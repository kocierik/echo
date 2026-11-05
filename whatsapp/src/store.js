// The messages Echo can read: in this process's memory only, never on disk, for at most
// seven days and `cap` messages per user (the oldest go first). A restart forgets them;
// the contacts' names are kept on disk by the sessions (names(), restoreNames()).

const WEEK = 7 * 24 * 3600 * 1000;

function normalize(text) {
  return text
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase();
}

function numberOf(jid) {
  const [user, server] = jid.split('@');
  return server === 's.whatsapp.net' ? `+${user}` : user;
}

export class MessageStore {
  constructor({ now = Date.now, keepFor = WEEK, cap = 20000 } = {}) {
    this.now = now;
    this.keepFor = keepFor;
    this.cap = cap;
    // userId -> {messages: [], ids: Set, names: Map(jid -> contact name),
    //            pushNames: Map(jid -> name the person gave themselves)}
    this.users = new Map();
  }

  #user(userId) {
    let user = this.users.get(userId);
    if (!user) {
      user = {
        messages: [],
        ids: new Set(),
        names: new Map(),
        pushNames: new Map(),
        // lid -> phone number jid: the same person, one chat
        aliases: new Map(),
        sorted: true,
      };
      this.users.set(userId, user);
    }
    return user;
  }

  #prune(user) {
    if (!user.sorted) {
      user.messages.sort((a, b) => a.at - b.at);
      user.sorted = true;
    }
    const oldest = this.now() - this.keepFor;
    let drop = 0;
    while (drop < user.messages.length && user.messages[drop].at < oldest) drop++;
    drop = Math.max(drop, user.messages.length - this.cap);
    if (drop > 0) {
      for (const gone of user.messages.splice(0, drop)) user.ids.delete(`${gone.chat}|${gone.id}`);
    }
  }

  /** A message from `extractMessage`; one too old or seen before is ignored. */
  add(userId, original) {
    if (original.at < this.now() - this.keepFor) return;
    const user = this.#user(userId);
    const message = { ...original, chat: user.aliases.get(original.chat) ?? original.chat };
    const key = `${message.chat}|${message.id}`;
    if (user.ids.has(key)) return;
    user.ids.add(key);
    const last = user.messages.at(-1);
    if (last && last.at > message.at) user.sorted = false;
    user.messages.push(message);
    if (!message.fromMe && message.pushName) user.pushNames.set(message.chat, message.pushName);
    if (user.messages.length > this.cap) this.#prune(user);
  }

  /** WhatsApp says `lid` is `pn`: their messages and names become one chat. */
  alias(userId, lid, pn) {
    if (!lid || !pn || lid === pn) return;
    const user = this.#user(userId);
    user.aliases.set(lid, pn);
    for (const message of user.messages) {
      if (message.chat !== lid) continue;
      user.ids.delete(`${lid}|${message.id}`);
      message.chat = pn;
      user.ids.add(`${pn}|${message.id}`);
    }
    for (const names of [user.names, user.pushNames]) {
      if (names.has(lid) && !names.has(pn)) names.set(pn, names.get(lid));
    }
  }

  /** A message deleted for everyone (`text` null) goes; an edited one takes its new text. */
  change(userId, { chat, id, text }) {
    const user = this.users.get(userId);
    if (!user) return;
    const where = user.aliases.get(chat) ?? chat;
    const index = user.messages.findIndex((m) => m.chat === where && m.id === id);
    if (index < 0) return;
    if (text === null) {
      user.messages.splice(index, 1);
      user.ids.delete(`${where}|${id}`);
    } else {
      user.messages[index].text = text;
    }
  }

  /** The name the phone's contacts give a chat. */
  setName(userId, jid, name) {
    if (!name) return;
    const user = this.#user(userId);
    user.names.set(user.aliases.get(jid) ?? jid, name);
  }

  #name(user, jid) {
    return user.names.get(jid) || user.pushNames.get(jid) || numberOf(jid);
  }

  /** Recent chats, newest first: {chat, name, lastAt, lastText, lastFromMe, count}. */
  chats(userId, { limit = 30 } = {}) {
    const user = this.users.get(userId);
    if (!user) return [];
    this.#prune(user);
    const byChat = new Map();
    for (const message of user.messages) {
      const chat = byChat.get(message.chat) ?? { chat: message.chat, count: 0 };
      chat.count += 1;
      chat.lastAt = message.at;
      chat.lastText = message.text;
      chat.lastFromMe = message.fromMe;
      byChat.set(message.chat, chat);
    }
    return [...byChat.values()]
      .sort((a, b) => b.lastAt - a.lastAt)
      .slice(0, limit)
      .map((chat) => ({ ...chat, name: this.#name(user, chat.chat) }));
  }

  /**
   * A chat's messages (by `chat` id, or every chat whose name holds `name`), oldest first,
   * from `since` (ms), the latest `limit`: {id, chat, name, fromMe, text, at}.
   */
  messages(userId, { chat, name, since, limit = 200 } = {}) {
    const user = this.users.get(userId);
    if (!user) return [];
    this.#prune(user);
    const wanted = name ? normalize(name.trim()) : null;
    const picked = user.messages.filter(
      (message) =>
        (!chat || message.chat === chat) &&
        (!wanted || normalize(this.#name(user, message.chat)).includes(wanted)) &&
        (!since || message.at >= since),
    );
    return picked.slice(-limit).map((message) => ({
      id: message.id,
      chat: message.chat,
      name: this.#name(user, message.chat),
      fromMe: message.fromMe,
      text: message.text,
      at: message.at,
    }));
  }

  /** The contact names, for the disk (the messages never are): [[jid, name], …]. */
  names(userId) {
    const user = this.users.get(userId);
    return user ? [...user.names] : [];
  }

  /** Contact names kept from before a restart. */
  restoreNames(userId, entries) {
    for (const entry of Array.isArray(entries) ? entries : []) {
      const [jid, name] = Array.isArray(entry) ? entry : [];
      if (typeof jid === 'string' && typeof name === 'string') this.setName(userId, jid, name);
    }
  }

  /** Lids named or chatting whose phone number is not known yet. */
  unaliasedLids(userId) {
    const user = this.users.get(userId);
    if (!user) return [];
    const lids = new Set();
    for (const jid of [...user.names.keys(), ...user.messages.map((m) => m.chat)]) {
      if (jid.endsWith('@lid') && !user.aliases.has(jid)) lids.add(jid);
    }
    return [...lids];
  }

  clear(userId) {
    this.users.delete(userId);
  }
}
