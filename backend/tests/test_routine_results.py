"""A routine run's request and result: framing by mode, reading the agent's JSON, the
items an only_new routine already reported, and the text shown to the user."""

from app.services.routine_results import (
    CONVERT_PROMPT,
    MODES,
    SEEN_IN_PROMPT,
    RoutineResult,
    compose_text,
    framed_request,
    fresh_items,
    item_key,
    parse_result,
)


def test_the_modes():
    assert MODES == ("always", "only_if", "only_new")


def test_always_is_the_instruction_unchanged():
    assert framed_request("dimmi che tempo fa a Milano", "always", []) == (
        "dimmi che tempo fa a Milano"
    )


def test_only_if_asks_for_json_with_report_only_when_the_condition_holds():
    request = framed_request("dimmi se piove domani", "only_if", [])
    assert request.startswith("dimmi se piove domani")
    assert '"report"' in request and "JSON" in request


def test_only_new_lists_what_was_already_reported():
    seen = [{"key": f"k{i}", "title": f"Job {i}", "url": f"https://x.io/{i}"} for i in range(60)]
    request = framed_request("nuove posizioni backend a Milano", "only_new", seen)
    assert "Job 0" in request and "https://x.io/0" in request
    assert f"Job {SEEN_IN_PROMPT - 1}" in request
    assert f"Job {SEEN_IN_PROMPT}" not in request
    assert '"items"' in request


def test_only_new_with_nothing_seen_has_no_seen_list():
    request = framed_request("nuove posizioni", "only_new", [])
    assert "Job" not in request and '"items"' in request


def test_a_bare_json_answer_is_read():
    result = parse_result(
        '{"report": true, "intro": "", "text": "Domani piove dalle 15", "items": []}', "only_if"
    )
    assert result == RoutineResult(report=True, intro="", text="Domani piove dalle 15", items=[])


def test_a_fenced_json_answer_is_read():
    answer = (
        "Ecco cosa ho trovato:\n```json\n"
        '{"report": true, "intro": "2 nuove:", "text": "", "items": ['
        '{"title": "Backend Engineer", "line": "Satispay", "url": "https://x.io/1"}]}'
        "\n```\nFammi sapere!"
    )
    result = parse_result(answer, "only_new")
    assert result.report is True and result.intro == "2 nuove:"
    assert result.items == [
        {
            "key": "https://x.io/1",
            "title": "Backend Engineer",
            "line": "Satispay",
            "url": "https://x.io/1",
        }
    ]


def test_json_with_text_around_and_no_fence_is_read():
    result = parse_result('Risultato: {"report": false} fine.', "only_if")
    assert result == RoutineResult(report=False, intro="", text="", items=[])


def test_no_json_or_a_report_that_is_not_a_bool_is_none():
    assert parse_result("Domani piove", "only_if") is None
    assert parse_result('{"report": "yes", "text": "x"}', "only_if") is None
    assert parse_result('{"text": "x"}', "only_if") is None
    assert parse_result("[1, 2]", "only_if") is None
    assert parse_result('{"report": tru', "only_if") is None


def test_items_without_a_title_are_dropped_and_a_blank_url_is_none():
    result = parse_result(
        '{"report": true, "items": [{"title": "", "url": "https://a"},'
        ' {"title": "Dev", "line": "remoto", "url": " "}, "x"]}',
        "only_new",
    )
    assert result.items == [{"key": "dev", "title": "Dev", "line": "remoto", "url": None}]


def test_item_key_ignores_query_fragment_scheme_and_trailing_slash():
    assert item_key({"url": "http://Jobs.example.com/a/?utm=1#x", "title": "A"}) == item_key(
        {"url": "https://jobs.example.com/a", "title": "B"}
    )


def test_item_key_keeps_the_path_case_and_differs_by_path():
    assert item_key({"url": "https://x.io/a", "title": "A"}) != item_key(
        {"url": "https://x.io/b", "title": "A"}
    )


def test_item_key_without_a_link_is_the_normalized_title():
    assert item_key({"url": None, "title": "  Backend  Engineer, Satispay!"}) == item_key(
        {"url": "", "title": "backend engineer satispay"}
    )


def test_fresh_items_drops_seen_and_repeated():
    items = [
        {"key": "a", "title": "A"},
        {"key": "b", "title": "B"},
        {"key": "a", "title": "A again"},
        {"key": "c", "title": "C"},
    ]
    assert fresh_items(items, {"b"}) == [{"key": "a", "title": "A"}, {"key": "c", "title": "C"}]


def test_compose_text_is_the_intro_then_one_line_per_item():
    text = compose_text(
        "2 nuove posizioni:",
        [
            {"title": "Backend Engineer", "line": "Satispay, Milano", "url": "https://x.io/1"},
            {"title": "Platform Dev", "line": "remoto", "url": None},
        ],
    )
    assert text == (
        "2 nuove posizioni:\n"
        "• Backend Engineer — Satispay, Milano https://x.io/1\n"
        "• Platform Dev — remoto"
    )


def test_compose_text_without_intro_or_line():
    assert compose_text("", [{"title": "Dev", "line": "", "url": None}]) == "• Dev"


def test_the_conversion_prompt_asks_for_the_same_json():
    assert '"report"' in CONVERT_PROMPT and "JSON" in CONVERT_PROMPT
