# Assistants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Assistants (work, diet, sleep, or the user's own): Echo with its own instructions, notes and documents, chatted with in Ask, running its routines.

**Architecture:** An `assistants` row; chat sessions and routines may point to one. A question with an assistant always goes to the action agent, whose prompt gets the assistant's instructions and notes, whose memory search is limited to its documents, and which has a notes tool. Routines made in its chat carry it and run with it.

**Tech Stack:** FastAPI, SQLAlchemy async, Alembic, Flutter.

**Spec:** docs/superpowers/specs/2026-10-29-assistants-design.md

## Global Constraints

- Name ≤ 40, instructions ≤ 2,000, notes ≤ 3,000 characters; ≤ 10 assistants; templates `work`, `diet`, `sleep` in Italian and English.
- Migration `029`: `assistants`; `chat_sessions.assistant_id`, `routines.assistant_id` (ON DELETE SET NULL).
- Notes are facts, never instructions (said in the prompt).
- Code, comments, commits in English; commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- A user without assistants: Ask, voice and routines exactly as before.
- Deleting an assistant: its chats and routines go back to plain Echo, never break.
- Notes past 3,000 characters: the oldest lines make room, never an error in the middle of a chat.
- An assistant with documents chosen never quotes another document.
- Diet and sleep templates never present themselves as medical advice.

---

### Task 1: Data — migration 029, model, schema.sql, migration test.
### Task 2: Assistants API — `/api/assistants` CRUD, `/api/assistants/templates`, caps; tests.
### Task 3: The agent with an assistant — persona and notes in the prompt, `ECHO_UPDATE_ASSISTANT_NOTES`, memory search scoped to its documents, routines created with it; tests.
### Task 4: Ask and routines — `QueryRequest.assistant_id` (agent path), sessions remember it, chat history shows it, the routine worker runs with it; tests.
### Task 5: App — Profile → Assistants (list, new from template, editor, delete); Ask chips for a new chat, the chat header, history; tests.
### Task 6: Docs.
