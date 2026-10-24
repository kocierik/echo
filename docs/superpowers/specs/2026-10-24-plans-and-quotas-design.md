# Plans and quotas — Design

Date: 2026-10-24. Status: structure decided with the user on 16/10 (three tiers by minutes of speech a
month; past the budget Echo slows down, nothing is lost); numbers and payment still open. Written up for
approval.
Measured cost (make usage, 14–23/10): **~0.30 $ per hour of speech**, 85% transcription; a question
< 0.01 $, a web search 0.01 $. A typical wearer speaks 2–3 h a day (60–90 h a month), a heavy one 5–6 h.

## Intent

Echo is sold as a hosted service: every hour of speech costs money. Each user needs a plan with a
monthly budget, the app must show how much is used, and past the budget Echo must **slow down without
losing anything** (16/10, like Omi), not stop. Prices are fixed later, after cheaper transcription is
measured; this builds the machinery so the numbers are a setting.

## Goals

1. **Plans** as configuration (not hard-coded copy): `free`, `plus`, `unlimited`, each with monthly
   minutes of speech, a daily allowance after the budget, web searches per day and routines. Defaults
   (to be revised with the prices): free 300 min, plus 1 500 min, unlimited 9 000 min (fair use);
   after the budget 10 min a day; searches 5 / 30 / 60 a day; routines 2 / 10 / 10.
2. **A user's plan** stored with the account (`users.plan`, default `free`), set by the operator
   (`make set-plan EMAIL=… PLAN=…`) until payments exist.
3. **Counting** from what is already recorded: the `stt` seconds in `llm_usage` this calendar month
   (UTC). No second counter.
4. **Past the budget, slower, not lost**: segments keep uploading and their audio is kept; each day
   the first N minutes (the daily allowance) are still transcribed at once, so "Ehi Echo" keeps working
   for short requests; the rest waits as **deferred**. Deferred segments are transcribed in order when
   the budget allows: the next month, or at once when the plan is raised. Deferred audio is never
   deleted by the 24 h retention while it waits (kept at most until it is transcribed).
5. **The app shows it**: Profile → Plan: the plan's name, "12 h of 25 h this month", the reset day,
   what happens past the budget, and, when there is deferred speech, "3 h of speech waiting: Echo
   transcribes it on 1 November" (no purchase button yet). Today shows a quiet line when the budget is
   reached ("Echo is transcribing 10 minutes a day until 1 November").
6. **Limits applied where they are used**: web searches per day (replacing the single
   `WEB_SEARCHES_PER_DAY`), routines per plan (replacing the fixed 10).

## Non-goals (for now)

- Payments (App Store / Google Play in-app, or Stripe on the website): a separate decision.
- Prices and plan names shown to buyers; trials; per-seat business plans.
- Throttling chat questions (cheap) or vision (rare).
- Transcription on the phone for the free plan (deferred on 16/10).

## Anti-goals

- Speech lost because of a budget: never; deferred is late, not gone.
- A user surprised: the app says before and when the budget is reached, and what happens next.
- Two sources of truth for usage: the budget reads `llm_usage`.

## Constraints

- Backend: the STT worker (`workers/stt.py`, `queue:stt`), retention (`workers/retention.py`,
  `COMPLETED_AUDIO_RETENTION_HOURS`), web search cap (`services/web_search.py`), routines
  (`services/routines.py` `MAX_ROUTINES`). Next migration after those on main.
- App: Profile screens; English copy.
- Tests one suite at a time; TDD; main, verified.

## What the user decided

- 16/10: three tiers by minutes of speech a month (free ~300 min, a middle one, unlimited ~30 $);
  past the budget slow down, never lose; audio always kept, processing waits.
- 24/10: a typical day is "5–6 hours" worn; numbers to be set after measuring cheaper transcription.

## Calls made by Claude (check these)

- Calendar month (UTC) as the period; the reset day is the 1st.
- The daily allowance after the budget (10 min) so voice requests keep working.
- Deferred speech is transcribed oldest first, at most one month's backlog a night, and it counts on
  the month it is transcribed in.
- No purchase in the app yet; the operator sets plans.

## Left to the builder

- How the STT worker marks and re-queues deferred segments (a status, a nightly job, a hook when the
  plan changes).
- The exact Profile → Plan and Today copy.
