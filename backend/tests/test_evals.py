"""The evaluation scoring and case files (the evaluations themselves call real APIs)."""

import json
from pathlib import Path

import pytest

from evals.scoring import Extracted, normalize_words, score_extraction, word_error_rate

CASES = Path(__file__).parents[1] / "evals" / "cases"


def test_words_ignore_case_punctuation_and_accents():
    assert normalize_words("Perché, sì! Già 3 volte.") == ["perche", "si", "gia", "3", "volte"]


@pytest.mark.parametrize(
    ("reference", "hypothesis", "expected"),
    [
        ("ciao marco come stai", "Ciao, Marco! Come stai?", 0.0),
        ("ciao marco come stai", "ciao mario come stai", 0.25),  # one substitution
        ("ciao marco", "ciao", 0.5),  # one deletion
        ("ciao", "ciao marco", 1.0),  # one insertion over one word
        ("", "", 0.0),
        ("", "rumore", 1.0),
    ],
)
def test_word_error_rate(reference, hypothesis, expected):
    assert word_error_rate(reference, hypothesis) == pytest.approx(expected)


def test_an_expected_entity_needs_type_keywords_and_dates():
    case = {
        "id": "c",
        "expect": [{"types": ["task"], "keywords": ["marco"], "due_date": "2026-10-15"}],
    }
    right = Extracted("task", "Chiamare Marco", metadata={"due_date": "2026-10-15"})
    wrong_day = Extracted("task", "Chiamare Marco", metadata={"due_date": "2026-10-16"})
    wrong_type = Extracted("event", "Chiamare Marco", metadata={"due_date": "2026-10-15"})

    assert score_extraction(case, [right]).passed
    assert not score_extraction(case, [wrong_day]).passed
    assert not score_extraction(case, [wrong_type]).passed


def test_date_accepts_a_due_or_an_event_date():
    case = {
        "id": "c",
        "expect": [{"types": ["event", "task"], "keywords": ["revisione"], "date": "2026-10-28"}],
    }

    assert score_extraction(
        case, [Extracted("event", "Revisione auto", metadata={"event_date": "2026-10-28"})]
    ).passed
    assert score_extraction(
        case, [Extracted("task", "Fare la revisione", metadata={"due_date": "2026-10-28"})]
    ).passed


def test_a_forbidden_entity_fails_the_case():
    case = {"id": "c", "forbid": [{"types": ["task"]}]}

    result = score_extraction(case, [Extracted("task", "Mangiare meglio")])

    assert not result.passed
    assert result.forbidden[0].name == "Mangiare meglio"
    assert score_extraction(case, [Extracted("note", "Mangiare meglio")]).passed


def test_routing_cases_cover_requests_about_what_the_user_sees():
    cases = json.loads((CASES / "routing.json").read_text(encoding="utf-8"))["cases"]
    photos = [c for c in cases if c["expect"] == "photo"]
    negatives = [c for c in cases if c.get("camera") and c["expect"] == "memory"]
    assert len(photos) >= 8 and len(negatives) >= 3


@pytest.mark.parametrize("name", ["extraction.json", "routing.json"])
def test_case_files_are_well_formed(name):
    suite = json.loads((CASES / name).read_text(encoding="utf-8"))
    ids = [case["id"] for case in suite["cases"]]
    assert len(ids) == len(set(ids))
    for case in suite["cases"]:
        assert case["text"].strip()
        if name == "routing.json":
            assert case["expect"] in {"memory", "agent", "notice", "photo"}
            # Only voice requests may take a photo
            assert case["expect"] != "photo" or case.get("camera") is True
        else:
            for spec in [*case.get("expect", []), *case.get("forbid", [])]:
                assert set(spec["types"]) <= {"person", "task", "idea", "event", "note"}


def test_answer_and_tool_cases_are_well_formed():
    answers = json.loads((CASES / "answers.json").read_text(encoding="utf-8"))
    assert answers["context"].strip()
    for case in answers["cases"]:
        assert case["language"] in {"it", "en"}
        # Expected words are compared after normalization (lowercase, no accents)
        for word in [*case.get("must", []), *case.get("forbid", [])]:
            assert normalize_words(word) == [word]
    tools = json.loads((CASES / "tools.json").read_text(encoding="utf-8"))
    from app.actions.routine_tools import ROUTINE_TOOL_NAMES
    from app.actions.todo_tools import TODO_TOOL_NAMES

    # None: the model asks instead of calling a tool
    names = {
        None, "search_memory", *ROUTINE_TOOL_NAMES, *TODO_TOOL_NAMES,
        *(tool["function"]["name"] for tool in tools["tools"]),
    }
    for case in tools["cases"]:
        assert set(case["first"]) <= names
