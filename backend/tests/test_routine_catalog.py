"""The catalog of ready-made routines: listed in the user's language, added with one tap."""

from sqlalchemy import select

from app.models.routine import Routine
from app.services.routine_catalog import CATALOG
from app.services.routines import validate_schedule


def test_every_entry_is_complete_in_both_languages_and_its_schedule_valid():
    for entry in CATALOG:
        validate_schedule(entry.schedule)
        for language in ("it", "en"):
            assert all(entry.texts[language]), (entry.key, language)


async def test_the_catalog_is_listed_and_an_entry_added_at_another_time(
    client, auth_headers, db_session
):
    listed = (await client.get("/api/routines/catalog", headers=auth_headers)).json()
    assert [e["key"] for e in listed] == [e.key for e in CATALOG]
    assert all(e["routine_id"] is None for e in listed)

    added = await client.post(
        "/api/routines/catalog/weekly_summary", headers=auth_headers, json={"time": "19:30"}
    )

    assert added.status_code == 201
    routine = added.json()
    assert routine["catalog_key"] == "weekly_summary" and routine["source"] == "catalog"
    assert routine["schedule"] == {"kind": "weekly", "time": "19:30", "days": [5]}
    listed = (await client.get("/api/routines/catalog", headers=auth_headers)).json()
    summary = next(e for e in listed if e["key"] == "weekly_summary")
    assert summary["routine_id"] == routine["id"]


async def test_added_twice_it_is_one_routine(client, auth_headers, db_session):
    first = (await client.post(
        "/api/routines/catalog/morning_brief", headers=auth_headers, json={}
    )).json()
    second = (await client.post(
        "/api/routines/catalog/morning_brief", headers=auth_headers, json={}
    )).json()

    assert first["id"] == second["id"]
    assert len((await db_session.scalars(select(Routine))).all()) == 1


async def test_an_unknown_entry_or_a_wrong_time_is_refused(client, auth_headers):
    unknown = await client.post("/api/routines/catalog/nope", headers=auth_headers, json={})
    wrong = await client.post(
        "/api/routines/catalog/morning_brief", headers=auth_headers, json={"time": "25:99"}
    )

    assert unknown.status_code == 404
    assert wrong.status_code == 422


async def test_removed_it_can_be_added_again(client, auth_headers):
    routine = (await client.post(
        "/api/routines/catalog/evening_diary", headers=auth_headers, json={}
    )).json()
    await client.delete(f"/api/routines/{routine['id']}", headers=auth_headers)

    listed = (await client.get("/api/routines/catalog", headers=auth_headers)).json()
    assert next(e for e in listed if e["key"] == "evening_diary")["routine_id"] is None
