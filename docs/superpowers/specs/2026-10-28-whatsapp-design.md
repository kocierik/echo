# WhatsApp: Echo reads your private chats

Date: 2026-10-28. Point 5 of `next-step` ("collegare WhatsApp Web a Echo, in modo che possa
leggere i messaggi"). Decided with the user on 28/10:

- **Baileys on the user's own number**, knowing it is unofficial: it breaks WhatsApp's
  terms and the number can be banned (the user chose it; Echo has one user).
- **Nothing saved**: messages live **only in the bridge's RAM**, never on disk or in the
  database, for **at most 7 days**; a restart loses them and Echo starts again from the
  ones that arrive after.
- **Private chats only**, not groups.
- **Both sides** of a chat: what the user sends too.
- Uses: **answering questions** (Ask and voice: "cosa mi ha scritto Marco?") and
  **routines** ("ogni sera riassumimi WhatsApp").

Calls below marked "(call)" are the builder's.

## How it fits

```
WhatsApp (phone) ──linked device──> whatsapp bridge (Node, Baileys)  ── RAM store, 7 days
                                         ▲  internal HTTP, token
                     api / worker ───────┘  (agent tools, link/unlink endpoints)
                          ▲
                        app (Profile → WhatsApp)
```

- **The bridge** is a new service in `whatsapp/` (Node 22, Baileys `7.0.0-rc14`, plain
  ESM JavaScript, no build step (call)), its own container in `docker-compose.yml`,
  reachable only on the compose network, every request carrying a shared token.
  - One WhatsApp session per Echo user (call: one user today, nothing to change later).
  - The session keys stay in a volume (`/data/<user_id>`): without them the user would
    link again after every restart. They are deleted on Unlink.
  - Read-only: never sends a message, never marks as read, never shows online
    (`markOnlineOnConnect: false`). Group, broadcast, status and newsletter chats are
    ignored.
  - Messages kept: text, captions, and a placeholder for what is not text ("[voice
    note]", "[photo]", "[document: name.pdf]"). Up to 7 days and 20,000 messages per user,
    the oldest dropped first (call). Chat names come from the phone's contacts as
    WhatsApp syncs them, else the sender's push name, else the number.
  - At link time WhatsApp sends the recent history: the last 7 days of private chats go
    into RAM, so Echo is useful at once.
- **Linking** uses a **pairing code**, not a QR: the QR would be on the same phone that has
  to scan it. Profile → WhatsApp asks for the number, shows an 8-character code and the
  steps (WhatsApp → Linked devices → Link a device → Link with phone number instead), and
  waits until it is linked. **Unlink** logs the device out and deletes keys and messages.
  The page says plainly that the connection is unofficial and the number may be banned.
- **Echo uses it as an app**, like the iPhone's Reminders and Calendar: a `whatsapp`
  toolkit with two read-only tools, offered when the user's WhatsApp is linked (the
  bridge's status, kept 60 s):
  - `WHATSAPP_LIST_CHATS`: recent private chats, with name, last message time and
    preview, newest first.
  - `WHATSAPP_READ_CHAT`: a chat's messages (by person name or chat id), optionally
    since a time, oldest first, each with who wrote it ("you" or the name) and when.
- It reaches the agent in Ask, in voice requests and in **routines** (which get no other
  Echo tools). "Cosa mi ha scritto Marco?" counts as an app request: the cheap pre-check
  learns words like "scritto", "wrote", "WhatsApp", "chat".
- WhatsApp not linked and asked about: "WhatsApp isn't linked. Link it in Profile →
  WhatsApp." The server without a bridge (`WHATSAPP_BRIDGE_URL` unset): no Profile row,
  no tools, nothing changes.

## Non-goals

- Sending, replying, reacting, marking as read.
- Groups.
- Saving messages anywhere but the bridge's RAM; adding them to Echo's memory.
- Transcribing voice notes, reading photos (later, maybe).
- Notifications for new messages.

## Anti-goals

- Echo sends anything to WhatsApp that the user could see (a read tick, an online status,
  a message).
- A message is written to disk or the database.
- A server without the bridge behaves differently from today.

## Constraints

- Backend FastAPI/pytest via podman; app Flutter; bridge tests with `node --test`.
- The bridge port is not published; the token comes from `WHATSAPP_BRIDGE_TOKEN`.

## Left to the builder

File layout, names, the matching of a person name to a chat, timeouts.
