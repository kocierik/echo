# Saved — Design

Date: 2026-10-23. Status: decided with the user on 16/10 (behaviour, mockups) and 21/10 ("generic, not
per case"; places only on request); written up for approval.
Roadmap: Fase 8, "Saved" and "Posti"; the camera ideas (parking, passport, lists, receipts).
Mockups (approved 16/10): https://claude.ai/artifact/6KQPTgMnHd1iFfYpqb2QZz — `F-Saved` (the page),
`F-Saved-Item` (one thing and its moment), `F-Parked-Voice` (parking saved and found by voice). Since then
Memories moved into Today and the voice chat became Ask's thread with Echo
(`2026-10-22-app-tabs-redesign-design.md`): read "Memories" as Today and "Voice requests" as the thread.

## Intent

Echo remembers conversations, but some things the user wants to **find again** are not conversations and
not to-dos: where the car is, where the passport was put, the wine from Saturday's dinner, a book Giulia
recommended, this week's receipts. Today they get lost in the memory or turn into fake tasks. Saved holds
them, each with **its moment** (when, where if asked, who was there, the conversation around it), and Echo
finds them again by chat or by voice ("dov'è la macchina?", "cos'era quel vino di sabato?", "quanto ho
speso questa settimana?").

The user was explicit: **one generic mechanism**, no feature per case. Parking, passport, wines, books and
receipts are examples of the same thing.

## Goals

1. **One kind of saved thing**, generic: a title; free details; free fields (an amount, a vintage, a
   level and column); optionally a photo; optionally a place; the moment (when, people, conversation);
   and the list it belongs to.
2. **Lists made by Echo from what the user says** ("salvami questo vino" → Wines, "segnati dove ho messo il
   passaporto" → Where things are, "ricordati dove ho parcheggiato" → Your car). Echo reuses a list that
   fits and starts a new one otherwise; the user can move a thing to another list.
3. **Agent tools**: save, update, find, sum (a field over a period: "quanto ho speso"), remove. By chat
   and voice.
4. **Places only on request.** The phone's position is read only when the user asks to save something
   with its place (the car, "salvami questo posto", "il passaporto è qui" when said at home is not a
   place). Never automatically on conversations or photos; no history of places visited.
5. **"Only the latest" lists**: a list can keep only its latest thing (the car: parking again replaces
   it), and a list can keep its things for a few days only (the car: at most a week, decided 16/10).
   Echo sets both when it starts the list; "Found it" removes the thing.
6. **The app**: Today gets a **Saved** row (like People) opening the Saved page (mockup `F-Saved`):
   search; the "only the latest" things with a place first, as cards (address, "since 9:40",
   **Directions**, **Found it**); then each list (photo grid when its things have photos, rows
   otherwise; "All N"); a sum card for a list with amounts ("€184.30 this week · 7 receipts"). A thing's
   page (mockup `F-Saved-Item`): photo, list, title, details, the moment (time, place, people chips,
   the conversation with its line), what Echo read on the photo, **Ask about it**, **Move to…**,
   **Remove from Saved**. In Ask's thread, the answer that saved something shows a small chip with the
   thing ("Your car · Saved") opening it.
7. **Found again from anywhere**: a memory question about a saved thing ("cos'era quel vino di sabato con
   Marco?") is answered from Saved too, not only through the agent.

## Non-goals (for now)

- Maps drawn in the app (tiles, a static map): the card shows the address and opens the phone's maps for
  directions. A map is a later polish.
- Place names from Apple Maps / Google Places (the address from the phone's geocoder is enough now).
- Receipts parsed into line items: a receipt is a thing with an amount (and the shop as a field).
- Sharing lists with other people; a web page for Saved.
- Saving from the wearable's button directly ("double press = save, no answer"): with the new board.

## Anti-goals

- A dedicated feature per case (a "parking" screen, a "wines" model): everything is the same thing.
- Reading the position without being asked, or keeping where the user has been.
- Saved things that duplicate the memory: a saved thing is what the user asked to keep; conversations
  stay conversations.
- An agent that guesses the list wildly: it reuses existing lists by name when they fit and says which
  list it used ("Salvato nei Vini").

## Constraints

- Backend FastAPI + Postgres (next migration 023); app Flutter iOS + Android; English UI copy; the AI
  answers in the user's language.
- Photos already exist (`photos` table, the camera route, `photo_id` on messages); the phone already runs
  commands for the server (`phone_action`, the device-command long poll) and holds Reminders/Calendar
  permissions the same way.
- Tests one suite at a time; TDD; work lands on main, verified.

## What the user decided

- 16/10: Saved as described; parking the first case to try; mockups `F-Saved`, `F-Saved-Item`,
  `F-Parked-Voice` approved.
- 21/10: generic, applicable to any case, not specific; places saved only when the user asks.
- 22/10: Memories became part of Today; the voice chat is Ask's thread.
- 16/10 (roadmap): the car is kept until the next parking, at most a week.

## Calls made by Claude (check these)

- **One table** `saved_items` with a free `fields` JSON; lists are a name per user (`saved_lists`: name,
  `latest_only`), created by the agent.
- **The place comes from the phone** through a new device command (`get_location`) when the agent's save
  asks for it; the app answers with latitude, longitude, accuracy and the geocoded address. If the phone
  does not answer in time (30 s) the thing is saved without a place and the answer says so.
- **A photo is attached** when the request is about one: the last photo in the thread within 10 minutes
  ("salva questa foto nei vini"), or, by voice with the camera, the photo the request takes ("Echo,
  salvami questo vino" → photo → saved with what the vision model read). Its text ("what Echo read")
  comes from the photo's description.
- **Sum** works on a numeric field (`amount`), per list, over a period (this week, this month, a range),
  with the currency of the items.
- **Memory answers include Saved**: retrieval adds the saved things matching the question (by text and
  embedding of title + details + fields) as a "Saved things" context section.
- **Found it** deletes the thing (no archive). Remove deletes it too, after a confirm in the app.
- **Today's Saved row** shows the count and the latest list touched; hidden when there is nothing saved
  (then "What Echo can do" carries the example).
- **No map image**: address, "since …", Directions (Apple Maps on iOS, Google Maps on Android).

## Answers to the builder check (Claude's calls, 23/10)

1. **Saving the same thing again updates it.** A fifth tool, update (add details, fields, a photo or a
   place to a saved thing). The agent finds first: a thing with the same title in the same list is
   updated, not duplicated ("il passaporto è nel cassetto" moves the passport). Parking: the photo after
   "ricordati dove ho parcheggiato" adds the photo and the level/column to the car; it does not replace it.
2. **Expiry**: `keep_days` on the list (null = forever), beside `latest_only`; the car's list is
   latest-only with 7 days. A daily job deletes expired things; the card says "Kept until you park
   again, or for a week" from those two settings.
3. **No distance from the server.** Finding never reads the position: the voice answer gives the address
   (and the level from the photo). The app may show "650 m away" on the card, worked out on the phone,
   only when it already has location permission; the position never leaves the phone for that.
4. **The moment**: when = the save; people = those named in the request, matched to People (the agent
   passes the names); the conversation = the one the voice request belongs to (filled in when the
   segment is grouped), none for a typed save; "its line" = the user's request as said. Matching
   "with Marco on Saturday" uses these people and the date.
5. **Outside assistants (MCP)** see saved things without their place (no address, no coordinates):
   retrieval has a switch that MCP calls set. The app and Echo's own answers see everything.
6. **Photos and deletes**: a saved thing points to its photo with "set null": deleting the conversation
   or the thread deletes the photo as today, and the saved thing stays with its text. "Remove from
   Saved" deletes only the saved thing, never the photo (it is still in the memory and the thread).

## Left to the builder

- iOS location while the app is in the background (the request may come by voice with the phone in a
  pocket): what "When In Use" allows while BLE keeps the app alive, and the fallback (a notification
  "Open Echo to save the place", or saving the place at the next foreground).
- The exact agent prompt rules for choosing a list and for asking when the request is unclear.
- How the voice camera route carries "save it" through to after the photo's analysis.
- Evals: tool choice and list choice cases (Italian and English), and memory answers that find a saved
  thing.
