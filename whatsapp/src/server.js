// The bridge's HTTP API, for Echo's api and worker on the compose network only. Every
// request carries the shared token (X-Bridge-Token).
//
//   GET    /users/:id/status                 {state: unlinked|linking|linked, phone}
//   POST   /users/:id/link     {phone}       {code}: the pairing code to type in WhatsApp
//   DELETE /users/:id                        unlink: logs the device out, forgets everything
//   GET    /users/:id/chats?limit=           recent private chats, newest first
//   GET    /users/:id/messages?chat=&name=&since=&limit=

import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';

function send(response, status, body) {
  if (body === undefined) {
    response.writeHead(status).end();
    return;
  }
  const data = JSON.stringify(body);
  response.writeHead(status, { 'Content-Type': 'application/json' }).end(data);
}

function authorized(request, token) {
  const given = Buffer.from(String(request.headers['x-bridge-token'] ?? ''));
  const expected = Buffer.from(token);
  return given.length === expected.length && timingSafeEqual(given, expected);
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 10_000) throw new Error('too large');
    chunks.push(chunk);
  }
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {};
}

function time(value) {
  if (!value) return undefined;
  const parsed = /^\d+$/.test(value) ? Number(value) : Date.parse(value);
  return Number.isNaN(parsed) ? undefined : parsed;
}

function count(value, fallback, most) {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isNaN(parsed) || parsed < 1 ? fallback : Math.min(parsed, most);
}

export function createServer({ token, sessions, store, logger }) {
  if (!token) throw new Error('WHATSAPP_BRIDGE_TOKEN is required');
  return http.createServer(async (request, response) => {
    try {
      if (!authorized(request, token)) return send(response, 401, { error: 'unauthorized' });
      const url = new URL(request.url, 'http://bridge');
      const match = url.pathname.match(/^\/users\/([\w-]{1,64})(\/[a-z]+)?$/);
      if (!match) return send(response, 404, { error: 'not found' });
      const [, userId, action = ''] = match;
      const route = `${request.method} ${action}`;

      if (route === 'GET /status') return send(response, 200, sessions.status(userId));

      if (route === 'POST /link') {
        const body = await readJson(request);
        const phone = String(body.phone ?? '').replace(/\D/g, '');
        if (phone.length < 8 || phone.length > 15) {
          return send(response, 400, { error: 'phone must be a full number with country code' });
        }
        return send(response, 200, { code: await sessions.link(userId, phone) });
      }

      if (route === 'DELETE ') {
        await sessions.unlink(userId);
        store.clear(userId);
        return send(response, 204);
      }

      if (route === 'GET /chats') {
        const chats = store.chats(userId, { limit: count(url.searchParams.get('limit'), 30, 100) });
        return send(response, 200, {
          chats: chats.map((chat) => ({
            chat: chat.chat,
            name: chat.name,
            last_at: new Date(chat.lastAt).toISOString(),
            last_text: chat.lastText,
            last_from_me: chat.lastFromMe,
            count: chat.count,
          })),
        });
      }

      if (route === 'GET /messages') {
        const messages = store.messages(userId, {
          chat: url.searchParams.get('chat') || undefined,
          name: url.searchParams.get('name') || undefined,
          since: time(url.searchParams.get('since')),
          limit: count(url.searchParams.get('limit'), 200, 500),
        });
        return send(response, 200, {
          messages: messages.map((message) => ({
            chat: message.chat,
            name: message.name,
            from_me: message.fromMe,
            text: message.text,
            at: new Date(message.at).toISOString(),
          })),
        });
      }

      return send(response, 404, { error: 'not found' });
    } catch (error) {
      logger?.warn({ err: error }, 'request failed');
      return send(response, error.status ?? 500, { error: error.publicMessage ?? 'failed' });
    }
  });
}
