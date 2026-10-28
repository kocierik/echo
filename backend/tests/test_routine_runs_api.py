"""GET /api/routine-runs, POST /api/routine-runs/{id}/ask ("Ask about this") and the runs
in /api/actions/voice-updates."""

import uuid
from datetime import datetime, timedelta, timezone

from app.models.chat_session import ChatSession
from app.models.routine import Routine
from app.models.routine_run import RoutineRun
from app.services.chat_history import load_thread_history
from tests.conftest import TEST_USER_ID, test_session
from tests.fakes.redis import InMemoryRedis

NOW = datetime.now(timezone.utc).replace(microsecond=0)


async def _routine(user_id=TEST_USER_ID, **values) -> Routine:
    routine = Routine(
        id=uuid.uuid4(),
        user_id=user_id,
        instruction=values.get("instruction", "dimmi se piove domani"),
        schedule={"kind": "daily", "time": "07:00"},
        timezone="Europe/Rome",
        active=True,
        next_run_at=NOW + timedelta(hours=3),
        source="voice",
        mode=values.get("mode", "only_if"),
    )
    async with test_session() as db:
        db.add(routine)
        await db.commit()
    return routine


async def _run(
    routine, ago=timedelta(0), status="reported", text="Domani piove dalle 15", **values
):
    run = RoutineRun(
        id=uuid.uuid4(),
        routine_id=routine.id,
        user_id=routine.user_id,
        ran_at=NOW - ago,
        status=status,
        text=text if status in ("reported", "failed") else None,
        sources=values.get("sources", []),
    )
    async with test_session() as db:
        db.add(run)
        await db.commit()
    return run


async def test_runs_are_the_users_own_newest_first_with_their_routine(client, auth_headers):
    routine = await _routine()
    old = await _run(routine, ago=timedelta(days=1), status="nothing")
    new = await _run(routine, sources=[{"title": "Meteo", "url": "https://meteo.it"}])
    await _run(await _routine(user_id=uuid.uuid4()))

    response = await client.get("/api/routine-runs", headers=auth_headers)

    assert response.status_code == 200
    body = response.json()
    assert [r["id"] for r in body["items"]] == [str(new.id), str(old.id)]
    first = body["items"][0]
    assert first["routine_id"] == str(routine.id)
    assert first["instruction"] == "dimmi se piove domani"
    assert (first["mode"], first["schedule_text"]) == ("only_if", "Every day at 07:00")
    assert (first["status"], first["text"]) == ("reported", "Domani piove dalle 15")
    assert first["sources"] == [{"title": "Meteo", "url": "https://meteo.it"}]
    assert body["items"][1]["text"] is None
    assert body["next_before"] is None


async def test_runs_filter_by_routine_and_since_and_page_with_before(client, auth_headers):
    rain, jobs = await _routine(), await _routine(instruction="nuove posizioni")
    runs = [await _run(rain, ago=timedelta(hours=h)) for h in (1, 2, 3)]
    await _run(jobs)

    by_routine = await client.get(
        f"/api/routine-runs?routine_id={rain.id}&limit=2", headers=auth_headers
    )
    page = by_routine.json()
    assert [r["id"] for r in page["items"]] == [str(runs[0].id), str(runs[1].id)]
    assert page["next_before"] is not None

    rest = await client.get(
        "/api/routine-runs",
        params={"routine_id": str(rain.id), "before": page["next_before"]},
        headers=auth_headers,
    )
    assert [r["id"] for r in rest.json()["items"]] == [str(runs[2].id)]

    since = (NOW - timedelta(hours=2)).isoformat()
    recent = await client.get("/api/routine-runs", params={"since": since}, headers=auth_headers)
    assert len(recent.json()["items"]) == 3  # 1 h and 2 h of rain, and the jobs run



async def test_runs_at_the_same_time_are_never_split_across_pages(client, auth_headers):
    # Two 07:00 routines both missed while the server was off
    rain, jobs = await _routine(), await _routine(instruction="nuove posizioni")
    missed = [await _run(r, ago=timedelta(days=2), status="skipped") for r in (rain, jobs)]
    newer = await _run(rain)

    first = (await client.get("/api/routine-runs?limit=2", headers=auth_headers)).json()
    rest = await client.get(
        "/api/routine-runs",
        params={"limit": 2, "before": first["next_before"]},
        headers=auth_headers,
    )

    seen = [r["id"] for r in first["items"]] + [r["id"] for r in rest.json()["items"]]
    assert sorted(seen) == sorted(str(run.id) for run in [newer, *missed])


async def test_a_limit_over_100_is_refused(client, auth_headers):
    response = await client.get("/api/routine-runs?limit=101", headers=auth_headers)
    assert response.status_code == 422


async def _thread() -> ChatSession | None:
    from sqlalchemy import select

    async with test_session() as db:
        return (
            await db.scalars(
                select(ChatSession).where(
                    ChatSession.user_id == TEST_USER_ID, ChatSession.kind == "voice"
                )
            )
        ).first()


async def test_ask_about_a_run_adds_it_to_the_thread_once(client, auth_headers):
    routine = await _routine()
    run = await _run(routine, sources=[{"title": "Meteo", "url": "https://meteo.it"}])

    first = await client.post(f"/api/routine-runs/{run.id}/ask", headers=auth_headers)
    second = await client.post(f"/api/routine-runs/{run.id}/ask", headers=auth_headers)

    assert first.status_code == second.status_code == 200
    thread = await _thread()
    assert first.json() == second.json() == {"session_id": str(thread.id)}
    tagged = [m for m in thread.messages if m.get("routine_run_id") == str(run.id)]
    assert len(tagged) == 1
    message = tagged[0]
    assert (message["role"], message["content"]) == ("assistant", "Domani piove dalle 15")
    assert message["notify"] is False
    # Follow-ups go to the agent, which can look again ("e domani?")
    assert message["actions"] is True
    assert message["routine_id"] == str(routine.id)
    assert message["routine_schedule"] == "Every day at 07:00"
    assert message["citations"] == [{"title": "Meteo", "url": "https://meteo.it"}]


async def test_the_next_question_has_the_run_in_its_history(client, auth_headers):
    run = await _run(await _routine())

    response = await client.post(f"/api/routine-runs/{run.id}/ask", headers=auth_headers)

    async with test_session() as db:
        history = await load_thread_history(
            InMemoryRedis(), db, TEST_USER_ID, uuid.UUID(response.json()["session_id"])
        )
    assert history[-1] == {
        "role": "assistant",
        "content": "Domani piove dalle 15",
        "actions": True,
    }


async def test_ask_about_a_quiet_run_is_409(client, auth_headers):
    routine = await _routine()
    for status in ("nothing", "skipped"):
        run = await _run(routine, status=status)
        response = await client.post(f"/api/routine-runs/{run.id}/ask", headers=auth_headers)
        assert response.status_code == 409


async def test_ask_about_someone_elses_run_is_404(client, auth_headers):
    run = await _run(await _routine(user_id=uuid.uuid4()))

    response = await client.post(f"/api/routine-runs/{run.id}/ask", headers=auth_headers)

    assert response.status_code == 404
    assert await _thread() is None


async def test_voice_updates_bring_new_reported_and_failed_runs_only(client, auth_headers):
    routine = await _routine()
    await _run(routine, ago=timedelta(hours=2))  # before `since`
    reported = await _run(routine, ago=timedelta(minutes=30))
    failed = await _run(routine, ago=timedelta(minutes=20), status="failed", text="Non riuscito")
    await _run(routine, ago=timedelta(minutes=10), status="nothing")
    await _run(routine, ago=timedelta(minutes=5), status="skipped")
    await _run(await _routine(user_id=uuid.uuid4()), ago=timedelta(minutes=1))
    since = (NOW - timedelta(hours=1)).isoformat()

    response = await client.get(
        "/api/actions/voice-updates", params={"since": since}, headers=auth_headers
    )

    runs = response.json()["routine_runs"]
    assert [(r["id"], r["status"], r["text"]) for r in runs] == [
        (str(reported.id), "reported", "Domani piove dalle 15"),
        (str(failed.id), "failed", "Non riuscito"),
    ]
    assert runs[0]["routine_id"] == str(routine.id) and runs[0]["ran_at"]


async def test_voice_updates_without_since_bring_no_runs(client, auth_headers):
    await _run(await _routine())

    response = await client.get("/api/actions/voice-updates", headers=auth_headers)

    assert response.json()["routine_runs"] == []
