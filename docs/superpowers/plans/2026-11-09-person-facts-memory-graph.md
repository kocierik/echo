# Person Facts and Memory Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Echo keeps cited, superseding facts about the people the user saved, shows them on each person's page and in Ask, and draws a radial map of people and topics.

**Architecture:**
- **Backend:** a `person_facts` table and `conversations.topics` (migration 039). Topics
  come from the existing summary call. Facts come from one best-effort LLM call after
  each summary, grounded by quote. A graph service builds nodes and edges from
  `entity_mentions` and topics.
- **App:** a facts panel on `PersonScreen`, and a `MemoryGraphScreen` drawn with a
  `CustomPainter` in a radial, deterministic layout.

**Tech Stack:**
- Backend: FastAPI, SQLAlchemy async, Alembic, pytest in the `api` container.
- App: Flutter, no new dependency.

**Spec:** `docs/superpowers/specs/2026-11-09-person-facts-memory-graph-design.md`

## Global Constraints

- Facts only about saved people (person entities with an `EntityMention` in the conversation); never about the user.
- A fact is kept only if its `quote` is found (case- and whitespace-normalized) in the transcript lines given to the model.
- Never sensitive facts (health, politics, religion, sex life, ethnicity, money troubles): reuse the check of `app/services/fact_suggestions.py`.
- At most 5 facts per conversation; categories `work`, `family`, `home`, `interests`, `plans`, `other` (unknown → `other`).
- Fact `text` at most 200 characters, in English; `quote` verbatim, in the language heard.
- Topics: at most 3 per conversation, 1–3 words, lowercased, trimmed, at most 40 characters, never a person's name.
- Graph: topics need ≥ 2 conversations in the window; at most 30 people and 20 topics (heaviest); `days` default 90, `0` = all, else 1..3650.
- No extra LLM call for a conversation naming no saved person.
- App: no new dependency; never trigger iOS builds (the user does).
- Backend test command:
  ```
  docker compose exec -T -e DATABASE_URL=postgresql+asyncpg://echo:echo@postgres:5432/echo_test -e REDIS_URL=redis://redis:6379/15 -e WHATSAPP_BRIDGE_URL=http://127.0.0.1:9 api python -m pytest -q -p no:cacheprovider <tests>
  ```
  Run it from `/home/erik/echo`. The test DB has no new columns from `create_all`: after
  Task 1, `ALTER` `echo_test` by hand as was done for migrations 036 to 038.
- App test command:
  ```
  docker run --rm -v "$PWD":/app -w /app -v echo-pub-cache:/root/.pub-cache ghcr.io/cirruslabs/flutter:stable sh -c "flutter analyze; flutter test <tests>; chown -R $(id -u):$(id -g) /app"
  ```
  Run it from `mobile/`. Do not run `dart format` on whole files: the style is mixed.
- Commits authored `kocierik <kocierik@gmail.com>`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- A quote the model returns with different punctuation, accents or case than the transcript: kept when the normalized text matches, never dropped for a trailing period. Test in Task 3.
- `replaces` naming a fact that is not current, not that person's, or not a fact at all: the new fact is kept and nothing is superseded. Test in Task 3.
- A person deleted from People: their facts go too (cascade), and the graph no longer shows them. Test in Task 4.
- The graph for a user with no people yet: one `you` node and nothing else, and the app shows its empty state. Tests in Task 4 and Task 7.
- A topic said with different case or spaces in two conversations ("Atlas", " atlas "): one topic node with weight 2. Test in Task 2.

---

### Task 1: Migration 039, models, schema

**Files:**
- Create: `backend/alembic/versions/039_person_facts_topics.py`
- Create: `backend/app/models/person_fact.py`
- Modify: `backend/app/models/__init__.py` (export `PersonFact`), `backend/app/models/conversation.py` (`topics`)
- Modify: `docs/schema.sql`, `backend/tests/test_migrations.py` (`range(1, 40)`)

**Interfaces:**
- Produces: `PersonFact`, with columns exactly as in the spec's table and `__tablename__ = "person_facts"`. Statuses: `"current"`, `"superseded"`, `"rejected"`. `Conversation.topics: Mapped[list[str] | None]` (`ARRAY(String(40))`).

- [ ] **Step 1:** In `test_migrations.py`, change the expected revisions to `range(1, 40)`.
- [ ] **Step 2:** Run `tests/test_migrations.py`. Expected: FAIL (no 039).
- [ ] **Step 3:** Write migration 039, following 037 and 038: the inspector guards so that
  existing objects are skipped. It creates `person_facts` with its foreign keys
  (`person_id` cascade; `segment_id`, `conversation_id` and `superseded_by` set null) and
  an index on `(person_id, status)`, then adds `conversations.topics`. Write the model,
  the export and the `conversation.py` column. Append to `docs/schema.sql` beside the 038
  line.
- [ ] **Step 4:** `ALTER` echo_test: create the table and the column. Run
  `tests/test_migrations.py` and `tests/test_retranscription.py`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(memory): person facts and conversation topics (migration 039)`.

### Task 2: Topics from the summary call, and the backfill

**Files:**
- Modify: `backend/app/services/analysis_pipeline.py`. `ConversationSummary` gains
  `topics: list[str]`, and `generate_conversation_summary` asks for them in the same JSON.
- Modify: `backend/app/workers/summaries.py`, where the summary is stored: `conversation.topics = summary.topics or None`.
- Create: `backend/app/services/topics.py`
- Create: `backend/app/cli/backfill_topics.py`, run as `python -m app.cli.backfill_topics --days 90`
- Test: `backend/tests/test_topics.py`

**Interfaces:**
- Produces: `normalize_topics(raw: object, people: list[str]) -> list[str]` in `app/services/topics.py`. It returns at most 3 entries, each lowercased, trimmed, with whitespace collapsed and at most 40 characters. It drops empties, duplicates, entries longer than 3 words and people's names (case-insensitive).
- Produces: the JSON key `"topics"` in the summary prompt's reply format.

- [ ] **Step 1:** Write the tests:
  - `test_topics_are_normalized`: `normalize_topics(["Atlas", " atlas ", "The Move", "Marco", "a b c d", ""], ["Marco"]) == ["atlas", "the move"]`;
  - `test_a_non_list_is_no_topics`: `normalize_topics("x", []) == []`;
  - `test_summary_stores_topics`: through `summarize_closed_conversations` with a fake LLM replying `{"title": "T", "summary": "S", "emoji": "💼", "topics": ["Atlas"]}`, the conversation's `topics == ["atlas"]`. Follow the fake-LLM pattern of `tests/test_fact_suggestions.py`; set `retranscribed_at`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement:
  - `normalize_topics`;
  - the prompt line: `"4. Up to 3 short topics (1-3 words each, in the conversation's language) naming what it is about; never a person's name"`, with the reply format `{"title": "...", "summary": "...", "emoji": "...", "topics": ["..."]}`;
  - the worker passes the conversation's people names to the normalizer: names of person entities with a mention in the conversation;
  - the backfill selects conversations with `summary IS NOT NULL AND topics IS NULL` started in the last N days. For each it makes one `complete_json` call from title and summary only, asking for `{"topics": [...]}`, and commits every 20.
- [ ] **Step 4:** Run `tests/test_topics.py` and `tests/test_worker_pipeline.py`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(memory): topics of each conversation, from its summary`.

### Task 3: Extracting person facts

**Files:**
- Create: `backend/app/services/person_facts.py`
- Modify: `backend/app/workers/summaries.py`, right after the `suggest_facts` call, best effort in its own `try` that logs
- Test: `backend/tests/test_person_facts.py`

**Interfaces:**
- Consumes: `PersonFact` (Task 1); `names_person(name, text)` from `app/services/people.py`; the sensitive-words check in `fact_suggestions.py`. If it is private, make it public as `is_sensitive_fact(text: str) -> bool` there and use it in both places.
- Produces:
  - `async def extract_person_facts(db: AsyncSession, llm: LLMService, conversation: Conversation) -> list[PersonFact]`, which adds the facts without committing and returns the kept ones;
  - `async def current_facts(db, person_id: uuid.UUID) -> list[PersonFact]`, the current ones, newest first;
  - `async def earlier_facts(db, person_id) -> list[PersonFact]`, the superseded ones, newest first;
  - `MAX_FACTS_PER_CONVERSATION = 5`, `CATEGORIES = ("work", "family", "home", "interests", "plans", "other")`, `MAX_CONTEXT_LINES = 40`.

- [ ] **Step 1:** Write the tests. Build a conversation with `make_conversation`, a saved
  person "Marco" with an `EntityMention`, and lines naming him. Use a fake LLM returning
  given facts.
  - `test_a_grounded_fact_is_kept`: the quote `"marco lavora in acme"` against the line `"[Others] Marco lavora in Acme."` is kept, `category == "work"`, `segment_id` set to that line's segment.
  - `test_ungrounded_unlisted_sensitive_and_duplicate_facts_are_dropped`: four facts, one each with a missing quote, person "Luca" (not saved), "Marco is depressed" (sensitive) and a duplicate of a current fact. None is kept.
  - `test_a_newer_fact_supersedes`: a current fact "Lives in Turin"; the new fact has `replaces` = its id. The old one becomes `status == "superseded"` with `superseded_by == new.id`.
  - `test_replaces_a_fact_that_is_not_current_or_not_theirs`: `replaces` names a random uuid, then another person's fact. The new fact is kept and nothing changes status.
  - `test_rejected_facts_are_told_as_never_again`: a rejected fact's text appears in the prompt sent to the fake LLM.
  - `test_no_saved_person_no_call`: a conversation with no mentions makes zero LLM calls.
  - `test_at_most_five`: 7 grounded facts give 5 kept.
  - `test_unknown_category_is_other`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement as in the spec's "Extracting person facts".
  - Normalize text for quote matching: `" ".join(unicodedata.normalize("NFKC", s).casefold().split())`, with leading and trailing punctuation stripped from the quote.
  - The lines given are each matching line with one line of context before and after, at most `MAX_CONTEXT_LINES`, prefixed by their speaker tag.
  - Rejected facts sent: the person's newest 8 within 30 days.
  - The reply schema and the rules are the spec's, verbatim. Validation and `replaces` handling are as in the tests.
- [ ] **Step 4:** Run `tests/test_person_facts.py` and `tests/test_fact_suggestions.py`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(memory): facts about saved people, each from a sentence heard`.

### Task 4: People facts API, topic filter, memory graph endpoint

**Files:**
- Modify: `backend/app/routers/people.py`. `PersonDetail` gains `facts` and
  `earlier_facts`; add `DELETE /api/people/{person_id}/facts/{fact_id}` → 204.
- Modify: `backend/app/routers/conversations.py`: `list_conversations` takes `topic: str | None = None` (normalized like topics, `Conversation.topics.any(topic)`).
- Create: `backend/app/services/memory_graph.py`, `backend/app/routers/memory_graph.py` (registered in `main.py` under `/api`)
- Test: `backend/tests/test_memory_graph.py`, and additions to `backend/tests/test_people*.py` (whichever file tests people detail)

**Interfaces:**
- Consumes: `current_facts`, `earlier_facts` (Task 3); `Conversation.topics` (Task 1).
- Produces:
  - `FactOut {id, text, category, quote, conversation_id, created_at}`;
  - `async def memory_graph(db, user_id, days: int) -> dict`, returning `{"nodes": [{"id", "kind", "label", "weight"}], "edges": [{"a", "b", "weight"}]}` with the ids `"you"`, `"person:<uuid>"` and `"topic:<label>"`;
  - `GET /api/memory-graph?days=` (`ge=0, le=3650`, default 90).

- [ ] **Step 1:** Write the tests:
  - `test_person_detail_lists_current_and_earlier_facts`;
  - `test_deleting_a_fact_rejects_it`: 204, then `status == "rejected"`, gone from `facts`; another user's fact is 404;
  - `test_conversations_by_topic`: `?topic=Atlas` finds a conversation with `topics=["atlas"]`;
  - `test_graph_weights_and_edges`: 3 conversations; Marco in 3, Ada in 2 (both together in 1), the topic "atlas" in 2 with Marco. Expect `you–person:Marco` weight 3, `person:Marco–person:Ada` 1, `person:Marco–topic:atlas` 2, and node weights 3 / 2 / 2;
  - `test_graph_window_and_thresholds`: a conversation older than `days` is not counted; a topic in 1 conversation is not a node; `days=0` counts all;
  - `test_graph_with_no_people_is_only_you`: `nodes == [{"id": "you", "kind": "you", "label": "You", "weight": 0}]`, `edges == []`;
  - `test_a_deleted_person_leaves_the_graph_and_their_facts_go`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Counts come from SQL over `entity_mentions` joined to
  `entities` (`entity_type = 'person'`, the user's) and `conversations` in the window
  (`started_at >= now - days`). Topics come from `unnest(conversations.topics)`. Keep the
  30 heaviest people and 20 heaviest topics. Edges only between kept nodes.
- [ ] **Step 4:** Run the new tests and `tests/test_people*.py`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(memory): facts on a person's page, and the memory graph`.

### Task 5: Facts in Ask's context

**Files:**
- Modify: `backend/app/services/memory_retrieval.py`, in the block that lists named people (around `line = f"- {person.name}"`)
- Test: add to `backend/tests/test_memory_retrieval*.py` (the file covering named people)

**Interfaces:**
- Consumes: `current_facts` (Task 3).

- [ ] **Step 1:** Write `test_a_named_persons_facts_come_first`. A question naming Marco,
  who has a current fact "Works at Acme" dated 2026-11-03. The context contains
  `"Marco: Works at Acme (from 2026-11-03)"` before the conversation excerpts; a
  superseded fact is absent.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Up to 8 current facts per named person, one line each, under
  the person's existing line.
- [ ] **Step 4:** Run the memory retrieval tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(ask): a person's current facts answer first`.

### Task 6: App, facts on the person page

**Files:**
- Modify: `mobile/lib/models/person.dart` (`PersonFact` class; `PersonDetail.facts`, `PersonDetail.earlierFacts`)
- Modify: `mobile/lib/services/api/memory_api.dart` (`Future<void> deletePersonFact(String personId, String factId)`), and every implementer or fake of that interface under `mobile/test/support/`
- Modify: `mobile/lib/screens/person_screen.dart`
- Test: `mobile/test/screens/person_screen_test.dart`

**Interfaces:**
- Consumes: the JSON of Task 4 (`facts`, `earlier_facts`, `FactOut` fields).
- Produces: `PersonFact {id, text, category, quote, conversationId, createdAt}` with `fromJson`.

- [ ] **Step 1:** Write the tests:
  - `what Echo knows, by category, newest first`: two `work` facts and one `home` fact show under the headings "Work" and "Home";
  - `a fact opens its conversation`: tapping it pushes `ConversationDetailScreen` for its `conversationId`;
  - `Not true removes a fact`: a long press, then "Not true", calls `deletePersonFact` and the fact disappears;
  - `Before lists superseded facts, collapsed`: hidden until "Before" is tapped;
  - `no facts, no panel`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement the panel "What Echo knows" under the header, with a
  `PanelSection` per category in `CATEGORIES` order:
  - each fact is a row with its text and `formatDate(createdAt)`;
  - `onLongPress` opens a sheet with "Not true";
  - "Before" is an `ExpansionTile` with the texts struck through.
  - Category headings: Work, Family, Home, Interests, Plans, Other.
- [ ] **Step 4:** Run `test/screens/person_screen_test.dart` and the people tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(app): what Echo knows about a person, with where it comes from`.

### Task 7: App, the memory map

**Files:**
- Create: `mobile/lib/models/memory_graph.dart` (`GraphNode {id, kind, label, weight}`, `MemoryGraph {nodes, edges}`, `GraphEdge {a, b, weight}`, `fromJson`)
- Create: `mobile/lib/widgets/radial_graph.dart`, with `radialLayout(MemoryGraph graph, Size size) -> Map<String, Offset>` (pure) and `RadialGraphPainter`
- Create: `mobile/lib/screens/memory_graph_screen.dart`
- Modify: `mobile/lib/services/api/memory_api.dart` (`Future<MemoryGraph> getMemoryGraph({int days = 90})`; `listConversations` gains `String? topic`)
- Modify: `mobile/lib/screens/people_screen.dart` (AppBar action `Key('people-map')`, label "Map")
- Test: `mobile/test/widgets/radial_graph_test.dart`, `mobile/test/screens/memory_graph_screen_test.dart`

**Interfaces:**
- Consumes: `GET /api/memory-graph?days=`, `GET /api/conversations?topic=` (Task 4).
- Produces: `MemoryGraphScreen({required MemoryApi api})`.

- [ ] **Step 1:** Write the tests:
  - `radialLayout`:
    - "you" is at the centre;
    - people lie on one ring, the heavier nearer: with weights 5 and 1, the distance of the 5 is less than the distance of the 1;
    - topics lie on an outer ring beyond every person;
    - the same graph gives the same offsets twice;
    - one person is not at the centre;
  - screen tests:
    - `the map shows people and topics, and a tap opens the person`: tapping the node `Key('graph-node-person:<id>')` pushes `PersonScreen`;
    - `a topic opens its conversations`: a list from `listConversations(topic:)`;
    - `the window chips ask again`: "1 month" calls `getMemoryGraph(days: 30)`, "All" calls `days: 0`;
    - `no people, the empty state`: "Add people in People to see your map";
    - `Show as list`: each node is a row "Marco · 12 conversations" (screen-reader fallback).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
  - Layout:
    - people ordered by weight, then label, at equal angles starting at −π/2;
    - person radius `r = R·(0.35 + 0.3·(1 − w/wmax))`;
    - topics at `R·0.9`, at the circular mean angle of their people's angles, nudged apart by sorting by angle and spreading collisions under 8°;
    - node size proportional to `sqrt(weight)`, clamped 14–36 px.
  - The painter draws edges under the nodes, with stroke `1 + 3·w/wmax`. Nodes are
    positioned `GestureDetector`s in a `Stack` over the painter, so each is tappable and
    has `Semantics(button: true, label: '<label>, <weight> conversations')`. Everything
    sits inside an `InteractiveViewer`.
  - Chips: `1 month` (30), `3 months` (90, default), `All` (0).
- [ ] **Step 4:** Run the two test files and the people tests, then the whole suite. Expected: PASS, analyzer at the 2 known infos.
- [ ] **Step 5:** Commit `feat(app): the memory map, people and topics around you`.

### Task 8: Ship check

- [ ] **Step 1:** Run the full backend suite (deselect `test_record_step_p95_stays_under_50_ms`), `ruff check app/ tests/ evals/`, and the full Flutter suite. Expected: all PASS.
- [ ] **Step 2:** Push. Tell the user:
  - `make deploy` (migration 039);
  - then `docker compose exec api python -m app.cli.backfill_topics --days 90`;
  - then the iOS build, which they start.
