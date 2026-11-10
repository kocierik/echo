# Person Facts and Memory Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Echo keeps cited, superseding facts about the people the user saved, shows them on each person's page and in Ask, and draws a radial map of people and topics.

**Architecture:**
- **Backend:** a `person_facts` table and `conversations.topics` (migration 040). Topics
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
- Graph: topics need ≥ 2 conversations in the window; at most 30 people and 20 topics (heaviest); `days` default 90, `0` = unbounded all-time, else 1..3650 with inclusive `started_at` bounds from one captured `now - days` through `now`.
- No extra LLM call for a conversation naming no saved person.
- App: no new dependency; never trigger iOS builds (the user does).
- Backend integration tests run from the repository root with `make test-all`; it creates
  `echo_test`, applies Alembic migrations through head, then runs the full backend suite.
  No manual `ALTER` is needed.
- App test command:
  ```
  Push-Location mobile; flutter analyze; if ($?) { flutter test }; Pop-Location
  ```
  Run it from the repository root in PowerShell. Do not run `dart format` on whole files:
  the style is mixed.
- Do not push or deploy. At handoff, report the migration and backfill commands; the user
  decides when to deploy and starts any iOS build.
- New commits use the repository's configured author and end with
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.

## Review Focus

- A quote with different case, whitespace or surrounding punctuation is kept only when its
  normalized words still match; accents are not stripped because the quote must be grounded
  in the heard words. Test in Task 3.
- `replaces` naming a fact that is not current, not that person's, or not a fact at all: the new fact is kept and nothing is superseded. Test in Task 3.
- A person deleted from People: their facts go too (cascade), and the graph no longer shows them. Test in Task 4.
- The graph for a user with no people yet: one `you` node and nothing else, and the app shows its empty state. Tests in Task 4 and Task 7.
- A topic said with different case or spaces in two conversations ("Atlas", " atlas "): one topic node with weight 2. Test in Task 2.

---

### Task 1: Migration 040, models, schema

**Files:**
- Create: `backend/alembic/versions/040_person_facts_topics.py`
- Create: `backend/app/models/person_fact.py`
- Modify: `backend/app/models/__init__.py` (export `PersonFact`), `backend/app/models/conversation.py` (`topics`)
- Modify: `docs/schema.sql`, `backend/tests/test_migrations.py` (`range(1, 41)`)

**Interfaces:**
- Produces: `PersonFact`, with columns exactly as in the spec's table and `__tablename__ = "person_facts"`. Statuses: `"current"`, `"superseded"`, `"rejected"`. `Conversation.topics: Mapped[list[str] | None]` (`ARRAY(String(40))`).

- [ ] **Step 1:** In `test_migrations.py`, change the expected revisions to `range(1, 41)`;
  add `test_migration_040_creates_person_facts_and_topics` for the table columns,
  foreign-key delete actions, index and topics array; add a repeat-upgrade assertion.
- [ ] **Step 2:** Run `docker compose exec -T api python -m pytest tests/test_migrations.py -q -p no:cacheprovider`.
  Expected: FAIL because the migration-chain assertion expects revision 040.
- [ ] **Step 3:** Write migration 040, following 037 and 038: the inspector guards so that
  existing objects are skipped. It creates `person_facts` with its foreign keys
  (`person_id` cascade; `segment_id`, `conversation_id` and `superseded_by` set null) and
  an index on `(person_id, status)`, then adds `conversations.topics`. Write the model,
  the export and the `conversation.py` column. Append the migration-040 schema reference
  after the STT recovery changes already recorded for 039 in `docs/schema.sql`.
- [ ] **Step 4:** Run `docker compose exec -T api python -m pytest tests/test_migrations.py -q -p no:cacheprovider`.
  Expected: PASS. `make test-all` applies migration 040 to `echo_test` before the full suite.
- [ ] **Step 5:** Commit `feat(memory): person facts and conversation topics (migration 040)`.

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

- [ ] **Step 1:** Add a regression to the existing `test_worker_pipeline.py` that calls
  `generate_conversation_summary` with `{"title": "T", "summary": "S", "emoji": "💼",
  "topics": ["Atlas"]}` and asserts `getattr(result, "topics", None) == ["atlas"]`.
  Add a worker regression in `test_fact_suggestions.py` verifying the normalized topics
  are stored on the conversation. These existing modules let the initial test fail as an
  assertion, not a missing-module import error.
- [ ] **Step 2:** Run `make test-all`. Expected: the summary regression fails because
  `ConversationSummary` does not expose `topics`.
- [ ] **Step 3:** Before implementing each new helper, add its tests to
  `backend/tests/test_topics.py`:
  - `test_topics_are_normalized`: `normalize_topics(["Atlas", " atlas ", "The Move", "Marco", "a b c d", ""], ["Marco"]) == ["atlas", "the move"]`;
  - `test_a_non_list_is_no_topics`: `normalize_topics("x", []) == []`;
  - `test_backfill_topics_only_selects_missing_recent_summaries`: include one eligible
    conversation, one with topics already set, one without a summary, and one older than
    `--days`; only the eligible row receives a model call;
  - `test_backfill_uses_summary_only_and_commits_in_batches`: assert transcript text is
    never sent and a batch of 21 commits once after row 20 and once at completion.
  Run the focused topic tests after creating the helper/CLI entry points but before adding
  their normalization and backfill behavior.
- [ ] **Step 4:** Implement:
  - `normalize_topics` so non-list input returns `[]`; normalize with NFKC, casefold,
    trim and collapse whitespace; retain no more than 3 unique non-empty labels of
    1-3 words and <=40 characters; exclude full saved-person names case-insensitively.
  - the prompt line: `"4. Up to 3 short topics (1-3 words each, in the conversation's language) naming what it is about; never a person's name"`, with the reply format `{"title": "...", "summary": "...", "emoji": "...", "topics": ["..."]}`;
  - the summary worker passes names of user-owned person entities having an
    `EntityMention` in the conversation; store `None` when normalization returns no topics;
  - the backfill CLI validates `--days` in `1..3650`, selects only
    `summary IS NOT NULL AND topics IS NULL` conversations in that window, and makes one
    retryable `complete_json` call per row using title and summary only. Normalize the
    returned labels with the same helper and commit after each 20 rows and at completion.
    Log failures by conversation ID without logging summary text; continue to the next row.
- [ ] **Step 5:** Run `make test-all`. Expected: PASS for `test_topics.py` and
  `test_worker_pipeline.py`.
- [ ] **Step 6:** Commit `feat(memory): topics of each conversation, from its summary`.

### Task 3: Extracting person facts

**Files:**
- Create: `backend/app/services/person_facts.py`
- Modify: `backend/app/workers/summaries.py`, right after the `suggest_facts` call, best effort in its own `try` that logs
- Test: `backend/tests/test_fact_suggestions.py` (exercise extraction through the existing summary-worker path)
- Test: add a worker-level regression to `backend/tests/test_fact_suggestions.py` that
  summarizes a closed conversation naming one saved person and asserts a grounded
  `PersonFact` is persisted after the summary.

**Interfaces:**
- Consumes: `PersonFact` (Task 1); `names_person(name, text)` from `app/services/people.py`; `is_sensitive(text: str) -> bool` from `app/services/fact_suggestions.py`.
- Produces:
  - `async def extract_person_facts(db: AsyncSession, llm: LLMService, conversation: Conversation) -> list[PersonFact]`, which adds the facts without committing and returns the kept ones;
  - `async def current_facts(db: AsyncSession, user_id: uuid.UUID, person_id: uuid.UUID) -> list[PersonFact]`, the current ones, newest first, scoped to the user;
  - `async def earlier_facts(db: AsyncSession, user_id: uuid.UUID, person_id: uuid.UUID) -> list[PersonFact]`, the superseded ones, newest first, scoped to the user;
  - `MAX_FACTS_PER_CONVERSATION = 5`, `CATEGORIES = ("work", "family", "home", "interests", "plans", "other")`, `MAX_CONTEXT_LINES = 40`.

- [ ] **Step 1:** Add integration tests to the existing `test_fact_suggestions.py`, using
  `summarize_closed_conversations`, `make_conversation`, a saved person with an
  `EntityMention`, and a fake LLM that returns the summary, existing user-fact suggestion,
  then person-fact response. Cover:
  - `test_a_grounded_fact_is_kept`: the quote `"marco lavora in acme"` against the line `"[Others] Marco lavora in Acme."` is kept, `category == "work"`, `quote == "Marco lavora in Acme."` (exact source sentence without the speaker tag), and `segment_id` is set to that line's segment.
  - `test_ungrounded_unlisted_sensitive_and_duplicate_facts_are_dropped`: four facts, one each with a missing quote, person "Luca" (not saved), "Marco is depressed" (sensitive) and a duplicate of a current fact. None is kept.
  - `test_a_newer_fact_supersedes`: a current fact "Lives in Turin"; the new fact has `replaces` = its id. The old one becomes `status == "superseded"` with `superseded_by == new.id`.
  - `test_replaces_a_fact_that_is_not_current_or_not_theirs`: `replaces` names a random uuid, then another person's fact. The new fact is kept and nothing changes status.
  - `test_rejected_facts_are_told_as_never_again`: a rejected fact's text appears in the prompt sent to the fake LLM.
  - a rejected fact older than 30 days and one outside the newest-eight prompt context
    are not recreated; both texts are absent from prompt context.
  - `test_invalid_fact_log_has_reason_but_no_personal_text`: rejected candidate logs
    include a reason code and conversation ID but not the candidate text or quote.
  - `test_person_fact_failure_does_not_roll_back_summary`: make the extractor exhaust
    retries with a private sentinel in the exception message; the summary remains
    committed, the worker logs the conversation ID and exception type, and neither the
    sentinel nor transcript text appears in logs.
  - `test_no_saved_person_no_call`: a conversation with no mentions makes zero LLM calls.
  - `test_at_most_five`: 7 grounded facts give 5 kept.
  - `test_unknown_category_is_other`.
- [ ] **Step 2:** Run `make test-all`. Expected: the grounded fact is not persisted,
  so the first new integration assertion fails without an import or setup error.
- [ ] **Step 3:** Implement `extract_person_facts` with the following sequence:
  - Query only person entities owned by `conversation.user_id` that have an `EntityMention`
    for this conversation. Return without calling the LLM if the query is empty.
  - Load transcriptions through their segments, ordered by `Segment.recorded_at`; retain the
    segment ID and speaker-tagged line for each quote candidate. Send each matching line
    with one neighboring line on either side, capped at 40 lines total.
  - Send current facts and the newest 8 rejected facts per person from the last 30 days;
    keep this prompt context limit and window unchanged.
    Call `complete_json` through `retry_with_backoff` with the schema and prompt rules in
    the spec. Catch exhausted retries at the worker boundary, log conversation ID and
    exception (not transcript text), and let summary processing continue.
  - Inspect no more than 5 returned facts. Keep a fact only when its person is in the
    conversation's saved-people list, its quote matches a provided transcript line after
    NFKC + casefold + whitespace collapse and edge-punctuation stripping. Persist the
    matched source sentence exactly, without its speaker tag, rather than the model's
    reformatted quote. Require non-empty fact text of <=200 characters, reject a
    case-insensitive exact-text duplicate of that person's current facts or any
    historical rejections scoped to the same user and person (trim candidate text as
    for current-fact duplicate detection), and call the existing `is_sensitive` helper
    on both text and quote. The all-history check is independent of the bounded prompt
    context. Map unknown categories to `other`.
  - Accept `replaces` only when it parses as a UUID and names a current fact belonging to
    the same user and person. Add the new fact and mark the replaced fact superseded in
    the same transaction. For rejected candidates, log only reason codes; never log fact
    text or quotes.
- [ ] **Step 4:** Run `make test-all`. Expected: all new cases in
  `test_fact_suggestions.py` pass.
- [ ] **Step 5:** Commit `feat(memory): facts about saved people, each from a sentence heard`.

### Task 4: People facts API, topic filter, memory graph endpoint

**Files:**
- Modify: `backend/app/routers/people.py`. `PersonDetail` gains `facts` and
  `earlier_facts`; add `DELETE /api/people/{person_id}/facts/{fact_id}` → 204.
- Modify: `backend/app/routers/conversations.py`: `list_conversations` takes `topic: str | None = None` (normalized like topics, `Conversation.topics.any(topic)`).
- Create: `backend/app/services/memory_graph.py`, `backend/app/routers/memory_graph.py` (registered in `main.py` under `/api`)
- Test: `backend/tests/test_memory_graph.py` and additions to `backend/tests/test_people_and_mentions.py`

**Interfaces:**
- Consumes: `current_facts(db, user_id, person_id)`, `earlier_facts(db, user_id, person_id)` (Task 3); `Conversation.topics` (Task 1).
- Produces:
  - `FactOut {id, text, category, quote, conversation_id: uuid.UUID | None, created_at}`;
  - `async def memory_graph(db: AsyncSession, user_id: uuid.UUID, days: int) -> dict`, returning `{"nodes": [{"id", "kind", "label", "weight"}], "edges": [{"a", "b", "weight"}]}` with the ids `"you"`, `"person:<uuid>"` and `"topic:<label>"`;
  - `GET /api/memory-graph?days=` (`ge=0, le=3650`, default 90).

- [ ] **Step 1:** Write the tests:
  - `test_person_detail_lists_current_and_earlier_facts`;
  - `test_deleting_a_fact_rejects_it`: 204, then `status == "rejected"`, gone from `facts`; another user's fact is 404;
  - `test_conversations_by_topic`: `?topic=Atlas` finds a conversation with `topics=["atlas"]`;
  - `test_graph_weights_and_edges`: 3 conversations; Marco in 3, Ada in 2 (both together in 1), the topic "atlas" in 2 with Marco. Expect `you–person:Marco` weight 3, `person:Marco–person:Ada` 1, `person:Marco–topic:atlas` 2, and node weights 3 / 2 / 2;
  - `test_graph_window_and_thresholds`: conversations older than `now - days` and later
    than `now` are not counted for positive `days`; a topic in 1 conversation is not a
    node; `days=0` remains unbounded and counts both historical and future conversations;
  - `test_graph_limits`: only the 30 heaviest people and 20 heaviest topics are returned;
  - `test_graph_days_validation`: `days < 0` and `days > 3650` return 422;
  - `test_graph_with_no_people_is_only_you`: `nodes == [{"id": "you", "kind": "you", "label": "You", "weight": 0}]`, `edges == []`;
  - `test_graph_is_scoped_to_authenticated_user`: a second user's people, conversations, topics and weights never appear;
  - `test_a_deleted_person_leaves_the_graph_and_their_facts_go`.
- [ ] **Step 2:** Run `make test-all`. Expected: the new route and field assertions fail
  because the endpoint and fact fields are not implemented yet.
- [ ] **Step 3:** Implement:
  - Scope every person, fact, conversation and graph query by the authenticated
    `user_id`. `DELETE` returns 404 unless both the fact and person belong to that user
    and the fact belongs to that person.
  - Return current and superseded facts in the existing person detail response with
    `id`, `text`, `category`, `quote`, `conversation_id`, and `created_at`; deleting a
    fact changes only its status to `rejected` and returns 204.
  - Normalize the topic query parameter with the same helper as stored topics, then
    filter `Conversation.topics` using PostgreSQL array membership.
  - Count distinct conversations for people and person-pairs from user-owned
    `entity_mentions` joined to person entities and conversations. After retaining the
    top 30 people, count topics only in conversations that mention at least one retained
    person, so a graph with no people has no topic nodes or disconnected topic nodes.
    Count person-topic edges from those same conversations' normalized topics. Apply
    the date cutoff to `Conversation.started_at` when `days > 0`; `days == 0` has no
    cutoff.
  - Retain the 30 highest-weight people and 20 highest-weight topics (ties by label),
    require topic node weight >= 2, and omit edges whose endpoints are not retained.
    The `you` node weight is the number of distinct in-window conversations represented
    by at least one retained person; it is 0 when there are no people.
- [ ] **Step 4:** Run `make test-all`. Expected: PASS, including `test_people_and_mentions.py`.
- [ ] **Step 5:** Commit `feat(memory): facts on a person's page, and the memory graph`.

### Task 5: Facts in Ask's context

**Files:**
- Modify: `backend/app/services/memory_retrieval.py`, in the block that lists named people (around `line = f"- {person.name}"`)
- Test: add to `backend/tests/test_person_retrieval.py`

**Interfaces:**
- Consumes: `current_facts(db, user_id, person_id)` (Task 3).

- [ ] **Step 1:** Write `test_a_named_persons_facts_come_first`. A question naming Marco,
  who has a current fact "Works at Acme" dated 2026-11-03. The context contains
  `"Marco: Works at Acme (from 2026-11-03)"` before the conversation excerpts; a
  superseded fact is absent.
- [ ] **Step 2:** Run `make test-all`. Expected: `test_a_named_persons_facts_come_first`
  fails because the context has no current fact line.
- [ ] **Step 3:** Add up to 8 `current_facts(db, user_id, person.id)` lines per named
  person under the existing person line, formatted as
  `"{name}: {text} (from {created_at:%Y-%m-%d})"`. Add these before transcript excerpts;
  never include superseded or rejected facts.
- [ ] **Step 4:** Run `make test-all`. Expected: `test_person_retrieval.py` passes.
- [ ] **Step 5:** Commit `feat(ask): a person's current facts answer first`.

### Task 6: App, facts on the person page

**Files:**
- Modify: `mobile/lib/models/person.dart` (`PersonFact` class; `PersonDetail.facts`, `PersonDetail.earlierFacts`)
- Modify: `mobile/lib/services/api/memory_api.dart` (`Future<void> deletePersonFact(String personId, String factId)`), `mobile/lib/services/api/api_service.dart`, and `mobile/test/support/fake_memory_api.dart`
- Modify: `mobile/lib/screens/person_screen.dart`
- Test: `mobile/test/screens/person_screen_test.dart`, `mobile/test/services/api/api_service_test.dart`

**Interfaces:**
- Consumes: the JSON of Task 4 (`facts`, `earlier_facts`, `FactOut` fields).
- Produces: `PersonFact {id, text, category, quote, conversationId: String?, createdAt}` with `fromJson`.

- [ ] **Step 1:** Write the tests:
  - `what Echo knows, by category, newest first`: two `work` facts and one `home` fact show under the headings "Work" and "Home";
  - `a fact shows its evidence`: its exact source quote and date appear beneath the fact text;
  - `a fact opens its conversation`: tapping it pushes `ConversationDetailScreen` for its `conversationId`;
  - a fact whose conversation was deleted retains its quote/date and has no navigation action;
  - `Not true removes a fact`: a long press, then "Not true", calls `deletePersonFact` and the fact disappears;
  - `Before lists superseded facts, collapsed`: hidden until "Before" is tapped;
  - `no facts, no panel`;
  - `delete failure is visible`: a failed API call leaves the fact visible and shows the
    repository-standard error message.
- [ ] **Step 2:** Run from the repository root:
  `Push-Location mobile; flutter test test/screens/person_screen_test.dart; Pop-Location`.
  Expected: the new facts-panel and delete-action tests fail.
- [ ] **Step 3:** Implement the panel "What Echo knows" under the header, with a
  `PanelSection` per category in `CATEGORIES` order:
  - each fact row shows its text, exact `quote` and `formatDate(createdAt)`; make it
    navigable only when `conversationId != null`;
  - `onLongPress` opens a sheet with "Not true";
  - "Before" is an `ExpansionTile` with superseded text struck through and its quote/date
    still visible.
  - Category headings: Work, Family, Home, Interests, Plans, Other.
  - On successful rejection, reload the person detail; on failure, keep the fact visible
    and display the existing `userMessage` error treatment.
- [ ] **Step 4:** Run from the repository root:
  `Push-Location mobile; flutter analyze; if ($?) { flutter test test/screens/person_screen_test.dart }; Pop-Location`.
  Expected: analyze succeeds and the focused test file passes.
- [ ] **Step 5:** Commit `feat(app): what Echo knows about a person, with where it comes from`.

### Task 7: App, the memory map

**Files:**
- Create: `mobile/lib/models/memory_graph.dart` (`GraphNode {id, kind, label, weight}`, `MemoryGraph {nodes, edges}`, `GraphEdge {a, b, weight}`, `fromJson`)
- Create: `mobile/lib/widgets/radial_graph.dart`, with `radialLayout(MemoryGraph graph, Size size) -> Map<String, Offset>` (pure) and `RadialGraphPainter`
- Create: `mobile/lib/screens/memory_graph_screen.dart`
- Modify: `mobile/lib/services/api/memory_api.dart` (`Future<MemoryGraph> getMemoryGraph({int days = 90})`; `listConversations` gains `String? topic`)
- Modify: `mobile/lib/services/api/api_service.dart`, `mobile/test/support/fake_memory_api.dart`
- Modify: `mobile/lib/screens/people_screen.dart` (AppBar action `Key('people-map')`, label "Map"; callback opens map)
- Modify: `mobile/lib/screens/home_screen.dart` (owns API/navigation; supplies map callback and opens `MemoryGraphScreen`)
- Create: `mobile/lib/screens/topic_conversations_screen.dart` (topic-filtered conversations using existing cards)
- Test: `mobile/test/widgets/radial_graph_test.dart`, `mobile/test/screens/memory_graph_screen_test.dart`, `mobile/test/screens/topic_conversations_screen_test.dart`, `mobile/test/services/api/api_service_test.dart`, `mobile/test/screens/memory_screens_test.dart`

**Interfaces:**
- Consumes: `GET /api/memory-graph?days=`, `GET /api/conversations?topic=` (Task 4).
- Produces: `MemoryGraphScreen({required MemoryApi api, required Future<void> Function(String id) onOpenPerson, required Future<void> Function(String id) onOpenConversation})`.

- [ ] **Step 1:** In `mobile/test/screens/memory_screens_test.dart`, add an assertion that
  `PeopleScreen` renders the Map action and invokes its callback. This test uses existing
  widgets only and must fail against the current screen.
- [ ] **Step 2:** Run from the repository root:
  `Push-Location mobile; flutter test test/screens/memory_screens_test.dart; $code = $LASTEXITCODE; Pop-Location; if ($code -ne 0) { exit $code }`.
  Expected: the new Map-action assertion fails because the action is absent.
- [ ] **Step 3:** Add the radial layout and graph-screen test cases below before implementing
  their corresponding layout and screen behavior:
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
    - tapping "You" does nothing; tapping a person calls `onOpenPerson`, and tapping a
      topic opens `TopicConversationsScreen` with that topic's filtered conversation list;
    - labels truncate visually but retain complete text in their `Semantics` labels.
- [ ] **Step 4:** Implement the API/model, layout and screens.
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
- [ ] **Step 5:** Run from the repository root:
  ```
  Push-Location mobile
  flutter analyze
  if ($LASTEXITCODE -eq 0) { flutter test test/widgets/radial_graph_test.dart }
  if ($LASTEXITCODE -eq 0) { flutter test test/screens/memory_graph_screen_test.dart }
  if ($LASTEXITCODE -eq 0) { flutter test test/screens/topic_conversations_screen_test.dart }
  if ($LASTEXITCODE -eq 0) { flutter test test/screens/person_screen_test.dart }
  if ($LASTEXITCODE -eq 0) { flutter test test/services/api/api_service_test.dart }
  if ($LASTEXITCODE -eq 0) { flutter test test/screens/memory_screens_test.dart }
  $code = $LASTEXITCODE
  Pop-Location
  if ($code -ne 0) { exit $code }
  ```
  Expected: analyze succeeds and all focused tests pass.
- [ ] **Step 6:** Commit `feat(app): the memory map, people and topics around you`.

### Task 8: Ship check

- [ ] **Step 1:** From the repository root, run `make test-all`; if successful, run
  `make lint`. Then run the full Flutter suite:
  ```
  Push-Location mobile
  flutter analyze
  if ($LASTEXITCODE -eq 0) { flutter test }
  $code = $LASTEXITCODE
  Pop-Location
  if ($code -ne 0) { exit $code }
  ```
  Expected: all feature tests pass; record any known unrelated baseline failure separately.
- [ ] **Step 2:** At handoff, tell the user:
  - `make deploy` (migration 040);
  - then `docker compose exec api python -m app.cli.backfill_topics --days 90`;
  - then the iOS build, which they start.
