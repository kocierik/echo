# Assistants: Echo for one part of your life

Date: 2026-10-29. Point of `next-step`: "possibilità di creare assistenti, tipo dieta, uno per il
sonno, uno per il lavoro". The user asked to proceed and to take inspiration from similar
projects ("procedi con gli assistenti, prendi spunto da qualche progetto simile"); every
decision below is the builder's call unless quoted.

## Inspiration

- **Khoj agents**: an agent is a persona (custom instructions), its own knowledge (a chosen
  set of files), and the tools it may use.
- **Omi prompt apps**: a prompt alone changes how the assistant answers; integration apps run
  on events (a routine here).
- **Letta**: each agent has its own memory block, shown to the user, that the agent updates
  itself.
- ChatGPT GPTs / Projects: instructions + files + their own chats.

## Intent

Echo answers about everything. An assistant is Echo focused on one part of the user's life,
with its own way of answering, what it remembers about that part, and the documents that
matter there: a work assistant that knows the user's projects, a diet coach that keeps what
they eat in mind, a sleep coach. It is Echo underneath: the same memory of conversations,
apps, web search and routines.

## Goals

- **An assistant** has a name (40 characters), an emoji, instructions (2,000 characters:
  role, tone, what to watch), its own **notes** (3,000 characters: what it keeps about its
  topic, shown and editable), and optionally a set of the user's documents (none chosen: all
  of them). At most 10 (call).
- **Templates** to start from, all editable: Lavoro / Work, Dieta / Diet, Sonno / Sleep.
  Diet and sleep say they are not medical advice and suggest a doctor for medical concerns.
- **Profile → Assistants**: the list, "New assistant" (from a template or blank), editing
  everything, deleting.
- **Ask**: a new chat can start with an assistant (chips: Echo and each assistant). Its chat
  says the assistant's name and emoji; chat history shows them; reopening it continues with
  the same assistant.
- An assistant's chat always goes through the agent (Echo's tools: memory search, apps, web
  search, routines, to-dos, Saved, About you), with the assistant's instructions and notes in
  its prompt, after the user's own instructions and facts.
- **Its notes**: the assistant updates them with a tool (add a line, remove one) when the user
  tells it something worth keeping for its topic ("ho fatto colazione con yogurt", "il
  progetto Atlas consegna a marzo"). The notes are facts, never instructions.
- **Its documents**: in its chat, memory search uses only its documents when some are chosen.
- **Routines**: a routine made inside an assistant's chat belongs to it and runs with its
  instructions and notes ("ogni sera alle 21 chiedimi cosa ho mangiato").

## Non-goals

- Talking to an assistant by voice from the wearable (later: "Echo, chiedi al coach…").
- Apple Health / Health Connect data (later, its own project and consent).
- A different model or a different set of apps per assistant.
- Sharing assistants, a marketplace.

## Anti-goals

- An assistant gives medical advice as if it were a doctor.
- Text from an email or a document makes an assistant's notes say something the user never
  said, and that text then acts as an instruction.
- The plain Echo chat changes for a user without assistants.

## Constraints

- FastAPI + SQLAlchemy async + Alembic (029); Flutter app; tests as before.

## Left to the builder

Names, prompt wording, template texts, layout.
