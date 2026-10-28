// Echo's WhatsApp bridge: restores the linked users, then serves the internal API.

import pino from 'pino';

import { createServer } from './server.js';
import { Sessions } from './sessions.js';
import { MessageStore } from './store.js';

// Warnings only by default: Baileys' debug logs would carry message contents
const logger = pino({ level: process.env.LOG_LEVEL ?? 'warn' });
const store = new MessageStore();
const sessions = new Sessions({ dataDir: process.env.DATA_DIR ?? '/data', store, logger });

const server = createServer({ token: process.env.WHATSAPP_BRIDGE_TOKEN, sessions, store, logger });
const port = Number(process.env.PORT ?? 3100);
// Listening first: status answers while the linked users reconnect
server.listen(port, '0.0.0.0', () => logger.warn({ port }, 'whatsapp bridge listening'));
await sessions.restore();

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    sessions.close();
    server.close(() => process.exit(0));
  });
}
