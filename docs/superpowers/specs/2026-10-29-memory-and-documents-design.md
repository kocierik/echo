# Memory and documents: what Echo knows about you, and your files

Date: 2026-10-29. Point of `next-step`: "gestire la memoria e i documenti dell'utente…
nella sezione profilo istruzioni… gestione dei documenti e informazioni dell'utente per dare
migliori risultati durante le ricerche. Puoi ispirarti a Letta… vedi Khoj per indicizzare
documenti." The user skipped the design questions ("salta la domanda, è per gestire meglio la
memoria"): every decision below is the builder's call unless quoted.

## Intent

Echo remembers conversations, but not who the user is (job, family, where they live, what they
prefer) unless they wrote it in the 1,000 characters of Instructions, and it cannot search the
user's own documents. Two parts, both inside Echo (Letta's and Khoj's ideas, not their
programs: adopting either would mean a second memory to keep in sync):

1. **About you** (Letta's "core memory"): short facts about the user, in every answer, that
   the user sees, edits and deletes. Echo adds one when asked ("Echo, ricordati che sono
   vegetariano") and *suggests* the ones it hears the user say in conversations; a suggestion
   is used only once the user keeps it.
2. **Documents** (Khoj's indexing): the user uploads a file from the phone; Echo extracts its
   text, indexes it in the same searchable memory as conversations, and answers from it,
   naming the document.

## Goals

### About you
- A list of facts, each one sentence (at most 200 characters), at most 60 kept (call).
- All kept facts go into the prompt of every answer (chat, voice, the action agent and
  routines, photos), after the Instructions: "What you know about the user".
- Profile → **Memory** (a new page grouping Instructions, About you and Documents; it replaces
  the Instructions row (call)):
  - About you: the kept facts, each editable and deletable; "Add a fact".
  - "Echo noticed" (suggestions): each with Keep / Discard and the conversation it came from.
- The agent gets two own tools: remember a fact about the user (kept at once: the user asked)
  and forget one ("dimentica che…"). Saved stays for things to find again ("dove ho
  parcheggiato"); facts are about the user themselves.
- Suggestions: once a conversation's analysis ends, one LLM call reads only the user's own
  lines ([You]) and proposes stable facts the user states about themselves. Never facts about
  health, politics, religion, sex life or sexual orientation, ethnicity, money troubles
  (call: the roadmap's "niente deduzioni" plus the GDPR special categories), never guesses,
  never facts already kept. At most 3 suggestions per conversation, 20 waiting (the oldest
  go).

### Documents
- Profile → Memory → Documents: "Add a document" opens the phone's file picker; PDF, TXT,
  Markdown and Word (.docx); at most 10 MB, 30 documents (call).
- The server keeps the **text only**, never the file (call: privacy, storage): it extracts it,
  splits it into chunks, embeds them and stores them. A document is `processing`, then
  `ready` (with its page or word count) or `failed` with the reason ("no text: a scanned
  PDF?", "too large", "unsupported").
- Extraction and embedding run in the worker (a queue), not in the upload request.
- Memory answers (Ask, voice, the agent's `search_memory`) also search the document chunks;
  a passage used is named: "From your document *Contratto affitto.pdf*". Sources carry the
  document so the app shows it.
- The list shows each document with its state; a tap shows its title, size and the first
  lines; Delete removes it and its chunks.

## Non-goals

- OCR of scanned PDFs or images (photos already exist).
- Keeping or showing the original file; editing a document's text.
- Folders, sharing, syncing a cloud drive (Google Drive, Notion): later, maybe.
- A graph memory (the roadmap's other item).
- Automatic facts used without the user keeping them.

## Anti-goals

- A wrong fact Echo made up silently changes every answer.
- A sensitive fact (health, politics, religion…) is inferred or suggested.
- Documents slow down or crowd out the answers about conversations.

## Constraints

- FastAPI + SQLAlchemy async + Alembic (next 028) + pgvector (1536, the existing embedding
  service); pytest via podman; Flutter app.
- New backend libraries: `pypdf`, `python-docx`. New app library: `file_picker`.

## Left to the builder

Chunk size and overlap (reuse the conversations' chunking if it fits), how many document
passages an answer gets, names, the exact prompts.
