// The messages Echo can read: in this process's memory only, never on disk, for at most
// seven days and `cap` messages per user (the oldest go first). A restart forgets them.

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
      user = { messages: [], ids: new Set(), names: new Map(), pushNames: new Map(), sorted: true };
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
  add(userId, message) {
    if (message.at < this.now() - this.keepFor) return;
    const user = this.#user(userId);
    const key = `${message.chat}|${message.id}`;
    if (user.ids.has(key)) return;
    user.ids.add(key);
    const last = user.messages.at(-1);
    if (last && last.at > message.at) user.sorted = false;
    user.messages.push(message);
    if (!message.fromMe && message.pushName) user.pushNames.set(message.chat, message.pushName);
    if (user.messages.length > this.cap) this.#prune(user);
  }

  /** The name the phone's contacts give a chat. */
  setName(userId, jid, name) {
    if (name) this.#user(userId).names.set(jid, name);
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

  clear(userId) {
    this.users.delete(userId);
  }
}
