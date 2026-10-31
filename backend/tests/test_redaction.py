"""Run tracking keeps the shape of tool arguments, never their content (core/redaction.py).

The audit's own summary (summarize_arguments) is tested, unchanged, in test_action_audit.py.
"""

import json

from app.core.redaction import redact_for_tracking, summarize_arguments


def test_bodies_become_their_type_and_length():
    redacted = redact_for_tracking({
        "body": "Ciao Ada, ecco il budget del progetto Atlas",
        "message_body": "x" * 500,
        "text": "secret",
    })

    assert redacted == {"body": "str(43)", "message_body": "str(500)", "text": "str(6)"}


def test_subject_query_and_recipients_are_reduced_too():
    # The audit shows these (an action the user confirmed); tracking does not
    redacted = redact_for_tracking({
        "subject": "Budget Atlas",
        "query": "mail from my doctor",
        "to": ["ada@example.com", "bob@example.com"],
        "start": {"dateTime": "2026-10-30T10:00"},
    })

    assert redacted == {
        "subject": "str(12)", "query": "str(19)", "to": "list(2)", "start": "dict(1)",
    }
    assert "Atlas" not in json.dumps(redacted) and "@" not in json.dumps(redacted)


def test_identifiers_are_kept_whatever_the_case_of_the_key():
    redacted = redact_for_tracking({
        "event_id": "abc123",
        "Thread_ID": "t-9",
        "MESSAGE_IDS": ["m1", "m2"],
        "label_ids": ("INBOX",),
    })

    assert redacted == {
        "event_id": "abc123", "Thread_ID": "t-9", "MESSAGE_IDS": ["m1", "m2"],
        "label_ids": ["INBOX"],
    }


def test_an_identifier_that_is_an_address_or_too_long_is_reduced():
    redacted = redact_for_tracking({
        "calendar_id": "ada.rossi@example.com",
        "page_id": "p" * 65,
        "attendee_ids": ["a1", "ada@example.com"],
        "chat_id": 12345,
    })

    assert redacted == {
        "calendar_id": "str(21)", "page_id": "str(65)", "attendee_ids": "list(2)",
        "chat_id": 12345,  # a small number: kept as any other
    }


def test_small_numbers_and_booleans_are_kept_large_numbers_and_others_are_not():
    redacted = redact_for_tracking({
        "limit": 10,
        "offset": -999_999,
        "send_updates": False,
        "phone": 393331234567,
        "ratio": 0.5,
        "nothing": None,
    })

    assert redacted == {
        "limit": 10, "offset": -999_999, "send_updates": False,
        "phone": "int(-)", "ratio": "float(-)", "nothing": "NoneType(-)",
    }


def test_long_lists_of_identifiers_are_reduced():
    ids = [f"id{i}" for i in range(21)]

    assert redact_for_tracking({"message_ids": ids}) == {"message_ids": "list(21)"}
    assert redact_for_tracking({"message_ids": ids[:20]}) == {"message_ids": ids[:20]}
    assert redact_for_tracking({"recipients": ids}) == {"recipients": "list(21)"}


def test_anything_but_a_dict_gives_nothing():
    assert redact_for_tracking(None) == {}
    assert redact_for_tracking(["body"]) == {}
    assert redact_for_tracking({}) == {}


def test_the_audit_summary_is_still_the_one_actions_audit_exports():
    from app.actions import audit

    assert audit.summarize_arguments is summarize_arguments
    assert summarize_arguments({"to": "ada@x.it", "body": "x" * 500}) == (
        "to=ada@x.it, body=(500 chars)"
    )
