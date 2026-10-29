# Memory and Documents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Facts about the user in every answer (kept by the user, suggested by Echo) and the user's documents searchable in Echo's memory.

**Architecture:** `user_facts` rows feed `personal_context`; the agent has remember/forget tools; after a conversation's analysis one LLM call proposes facts from the user's own lines. Documents are uploaded as files, their text extracted in the request (the file is never kept), chunked and embedded by a worker into `document_chunks`, which memory retrieval searches beside conversation chunks.

**Tech Stack:** FastAPI, SQLAlchemy async, Alembic, pgvector, pypdf 6.21.4, python-docx 1.2.0, Flutter + file_picker.

**Spec:** docs/superpowers/specs/2026-10-29-memory-and-documents-design.md

## Global Constraints

- Facts: one sentence, ≤ 200 characters; ≤ 60 kept; ≤ 20 suggestions waiting; ≤ 3 suggested per conversation; never health, politics, religion, sex life or orientation, ethnicity, money troubles.
- Documents: PDF, TXT, MD, DOCX; ≤ 10 MB; ≤ 30 per user; text only kept; states `processing`, `ready`, `failed`.
- Migration `028`; embeddings 1536 like `chunks`.
- Code, comments, commits in English; commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- A user with no facts and no documents: prompts and answers exactly as before.
- A scanned PDF (no text), an empty file, a 50 MB file, an .exe renamed .pdf: a clear failed state or a refusal, never a crash.
- A fact edited or deleted: the next answer no longer uses the old one.
- Deleting a document: its passages never show up in an answer again.
- The suggestions never propose a sensitive fact or one already kept.

---

### Task 1: Data
Migration 028 (`user_facts`, `documents`, `document_chunks`), models, `schema.sql`, migration test.

### Task 2: About you (backend)
`services/user_facts.py`; `/api/facts` (list kept + suggestions, add, edit, delete, keep); facts in `personal_context`; agent tools `ECHO_REMEMBER_ABOUT_USER` / `ECHO_FORGET_ABOUT_USER` (chat and voice). Tests.

### Task 3: Suggestions
`services/fact_suggestions.py`: one LLM call on the user's own lines once a conversation's analysis ends; caps, no duplicates, no sensitive categories (prompt + a keyword guard). Tests with a fake LLM.

### Task 4: Documents (backend)
`/api/documents` (upload multipart, list, detail with a preview, delete); text extraction in the request (pypdf, python-docx, utf-8 text); a `queue:documents` worker that chunks and embeds; caps and failures. Tests.

### Task 5: Retrieval
`retrieve_memory_context` searches document chunks too ("From your document …"), sources carry `document_id` / `document_title`. Tests.

### Task 6: App
Profile → Memory (Instructions, About you, Documents); facts screen (edit, delete, add, keep/discard suggestions); documents screen (file_picker upload, states, preview, delete); Ask sources show a document. Tests.

### Task 7: Docs
README, PROJECT-STATUS, ROADMAP ("Cosa so di te" done), DEVELOPMENT if needed.
