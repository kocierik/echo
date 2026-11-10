# Person facts and the memory graph

## Intent

Echo should remember facts about the people the user saved, the way Omi keeps facts about
the user. Each fact comes from a sentence actually heard. A newer fact supersedes an
older one but does not erase it. Each person's page shows what is true about them now,
with where it comes from. A memory graph lets the user **see** their circle at a glance
(who they talk to, and about what) and **navigate** from it to a person, a topic or a
conversation.

Why: Ask rebuilds "what do I know about Marco?" from scattered transcript fragments every
time. It misses things, mixes old and new, and never notices a contradiction. Omi solved
this with atomic, cited facts and supersession. The user chose this over an LLM-written
wiki page, which would accumulate the model's mistakes.

## Goals

- Facts about **saved people only** (People has only people the user added, since
  2026-11-09), each with its quote, its conversation and its date.
- A newer fact supersedes an older one ("moved to Milan" over "lives in Turin"). The old
  one stays under "Before" on the person's page.
- A person's page: current facts grouped by category, each opening its conversation; the
  user can delete a wrong fact.
- Ask uses a person's current facts before searching transcripts.
- A radial memory graph: the user at the centre, saved people on a ring (closer and larger
  the more they talk), recurring topics on an outer ring. Tapping a node opens it.

## Non-goals

- Facts about the user: "About you" stays as it is.
- Facts about people the user has not saved, and People entries created automatically
  (removed on purpose, 6481058).
- Conversations or places as graph nodes. Conversations would be hundreds; places have
  "Where you've been".
- A nightly consolidation ("Dream"). It comes later, once there are facts to consolidate.
- Editing a fact's text. Deleting it is enough for now.
- A force-directed or animated graph.

## Anti-goals (a failure even if it works)

- A fact with no sentence behind it. A hallucinated fact on someone's page is worse than
  none.
- Sensitive facts about other people: health, politics, religion, sex life, ethnicity,
  money troubles. The same rule as "About you" (fact_suggestions.py).
- A graph that is an unreadable tangle on a phone, or that moves every time it opens.
- Extra model cost on conversations that name no saved person.

## Constraints

- Backend: FastAPI and SQLAlchemy async; Alembic migration 040. `docs/schema.sql` and
  `test_migrations` range updated.
- App: Flutter. No new dependency; the graph is a `CustomPainter`.
- The user starts iOS builds; never trigger them.
- The facts model is the analysis LLM (`get_llm_analysis_service`), as fact suggestions are.

## Approaches considered

1. **A `person_facts` table and a radial graph** (chosen). Facts in their own table with
   quote, conversation, status and `superseded_by`; extracted automatically, deletable on
   the page. A radial layout drawn without a library: stable, readable on a phone, easy to
   tap. The trade-off: less "alive" than a force-directed graph.
2. **Extend `user_facts` and a force-directed graph (`graphview`).** It would reuse the
   suggested/kept/discarded review, but approving every fact about every person is
   tiring. Mixing facts about others into the table that enters every answer complicates
   it. On a phone a force graph tangles and moves at each opening. Rejected.
3. **An LLM-written page per person (LLM Wiki).** Rejected: the model's mistakes
   accumulate in the prose, and a single claim cannot be checked or removed.

The user picked 1.

On 2026-11-10 the user confirmed the full end-to-end scope and approved the
backend-authoritative architecture: the backend owns extraction, persistence, validation and
graph aggregation; Flutter renders and navigates the resulting data without a new dependency.
The graph work follows the STT recovery migration 039, so its migration is 040.

## Design

### Data (migration 040)

`person_facts`:

| column | |
|---|---|
| id | uuid |
| user_id | uuid, not null |
| person_id | uuid → `entities.id` (person), on delete cascade |
| text | varchar(200): one short fact, in English like titles ("Works at Acme as a designer") |
| category | varchar(20): `work`, `family`, `home`, `interests`, `plans`, `other` |
| quote | text: the sentence heard, verbatim from the transcript |
| segment_id | uuid → `segments.id`, on delete set null (the line quoted) |
| conversation_id | uuid → `conversations.id`, on delete set null |
| status | varchar(12): `current`, `superseded`, `rejected` |
| superseded_by | uuid → `person_facts.id`, nullable |
| created_at | timestamptz |

`conversations.topics`: `ARRAY(varchar(40))`, nullable. Up to 3 short topic labels
("Atlas", "the move", "gym"), lowercased and trimmed.

### Topics

`generate_conversation_summary` already returns title, summary and emoji in one JSON call.
It also returns `topics`: up to 3 short noun phrases (1 to 3 words) naming what the
conversation is about, in the conversation's language. People's names are not topics.
They are stored normalized: lowercase, trimmed, at most 40 characters. The cost is no
extra call.

Topics are backfilled, as the builder's call, for conversations of the last 90 days that
have a summary. A one-off script makes one cheap call per conversation, from the summary
text alone (not the transcript). Without it the graph starts empty of topics.

### Extracting person facts

This runs after a conversation's summary, in `workers/summaries.py` next to
`suggest_facts`, best effort: a failure is logged and the summary stands.

1. The saved people named in the conversation: person entities with an `EntityMention`
   for it. None means no call.
2. The transcript lines naming each (`names_person`), with their speaker label and one
   line of context before and after, at most 40 lines.
3. The current facts of those people, with their ids.
4. One `complete_json` call returns
   `{"facts": [{"person": "<name>", "text": "...", "category": "...", "quote": "...",
   "replaces": "<fact id>|null"}]}`. The prompt rules:
   - lasting facts only: who they are, work, family, home, interests, plans; no
     one-off events, those are already tasks and events;
   - never sensitive categories;
   - the quote verbatim;
   - `replaces` only when the new fact contradicts or updates a listed current fact;
   - at most 5 facts per conversation;
   - the person's rejected facts listed as "never again" (Omi's negative feedback, the
     newest 8 of 30 days).
5. Each fact is checked before it is kept:
   - its person is one of those listed;
   - its quote is found in the lines given, normalized for case and whitespace;
   - it is not a near-duplicate of a current fact (same text, case-insensitive);
   - it passes the sensitive-words check of `fact_suggestions.py`;
   - its category is one of the six, else `other`.
   A failing fact is dropped silently.
6. A kept fact with `replaces` marks that fact `superseded`, with `superseded_by` set to
   the new one.

### API

- All endpoints retain the existing authentication and scope reads and writes to the
  authenticated user; supplied person, fact and conversation IDs must belong to that user.

- `GET /api/people/{id}` (existing) adds `facts` (current, newest first: id, text,
  category, quote, conversation_id, created_at) and `earlier_facts` (superseded, same
  fields).
- `DELETE /api/people/{id}/facts/{fact_id}` sets status `rejected`, never a hard delete,
  so it is not proposed again. A superseded fact that pointed at it stays superseded.
- `GET /api/memory-graph?days=90` (1 to 3650; 0 means all) returns:
  - `nodes`: `{id, kind: "you"|"person"|"topic", label, weight}`, where weight is the
    number of conversations in the window;
  - `edges`: `{a, b, weight}` for you–person (conversations with them), person–person
    (conversations naming both) and person–topic (conversations naming the person with
    that topic).
  - Topics need at least 2 conversations in the window. At most 30 people and 20 topics,
    the heaviest. People come from `entity_mentions`, topics from `conversations.topics`.
- `GET /api/conversations?topic=<label>` filters by topic, for the topic node.

### Ask

When retrieval names a person (`memory_retrieval`, where it already finds people), the
person's current facts are added to the context first: "Marco: works at Acme (from
2026-11-03)". Transcripts stay the evidence for anything else.

### App

- **Person page** (`person_screen.dart`): a "What Echo knows" panel under the header.
  Current facts are grouped by category, each with its date. Tapping one opens its
  conversation; a swipe or long press offers "Not true" (delete → rejected). A collapsed
  "Before" section lists superseded facts, struck through, each with its date.
- **Map** (`memory_graph_screen.dart`), opened from People by an app bar "Map" button:
  - a `CustomPainter` radial layout: you at the centre, people on an inner ring ordered
    by weight (radius shrinking as weight grows, node size growing), topics on an outer
    ring, each placed near the average angle of its people;
  - edges are lines with their thickness from weight, under the nodes;
  - labels under the nodes, truncated;
  - chips for 1 month, 3 months (default) and all;
  - tap a person → `PersonScreen`; a topic → a list of its conversations; you → nothing;
  - pinch to zoom and pan (`InteractiveViewer`);
  - empty states: "Add people in People to see your map" when there are no people;
  - the same layout every time it opens: it is deterministic.
- Accessibility: every node is a `Semantics` button with its label and weight ("Marco,
  12 conversations"). A list fallback, "Show as list", gives screen readers the same data.

### Tests

- Backend:
  - extraction keeps a grounded fact and drops one with a missing quote, a sensitive
    one, one about an unlisted person and a duplicate;
  - `replaces` supersedes;
  - a rejected fact is passed back as "never again";
  - no call when no saved person is named;
  - the graph endpoint's nodes, weights, window and thresholds;
  - `topics` stored normalized;
  - the facts in Ask's context;
  - the migration.
- App: the person page's facts, Before and "Not true"; the map's nodes and a tap
  opening the person; the empty state; the list fallback.

## Left to the builder

- Prompt wording, and the exact radii and sizes of the radial layout.
- The topic conversation list: reuse the day/conversation list widgets.
- Whether the facts call shares the summary's LLM retry policy (it should: `retry_with_backoff`).

## Calls I made (to check)

- Facts are automatic, not approved one by one; a wrong one is deleted with "Not true".
- Topics come from the summary call; the last 90 days are backfilled once.
- Fact text is in English, as titles and summaries are; the quote stays in the language
  heard.
- At most 5 facts per conversation, 30 people and 20 topics on the map, a 3-month default
  window.
- Map is a button in People, not a new tab.
