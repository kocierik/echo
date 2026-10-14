from app.actions.audit import pending_summary, summarize_arguments


def test_argument_summary_hides_bodies():
    s = summarize_arguments({"to": "ada@x.it", "body": "x" * 500})
    assert "ada@x.it" in s
    assert "(500 chars)" in s
    assert "x" * 50 not in s


def test_summary_truncates_values_and_total():
    s = summarize_arguments({"a": "y" * 200})
    assert len(s) < 100
    big = {f"k{i}": "v" * 80 for i in range(20)}
    assert len(summarize_arguments(big)) <= 300


def test_argument_summary_redacts_body_like_keys_by_substring():
    s = summarize_arguments({
        "recipient_email": "ada@x.it",
        "message_body": "secret one",
        "markdown_text": "secret two",
        "html_content": "secret three",
        "text": "secret four",
        "Message": "secret five",
    })
    assert "ada@x.it" in s
    assert "secret" not in s
    assert "message_body=(10 chars)" in s
    assert "markdown_text=(10 chars)" in s


def test_pending_summary_send_email_shows_recipient_subject_and_body():
    s = pending_summary(
        "GMAIL_SEND_EMAIL",
        {"recipient_email": "ada@x.it", "subject": "Budget", "body": "Hi Ada, see you at 5."},
    )
    assert s == "Send email to ada@x.it: Budget\nHi Ada, see you at 5."


def test_pending_summary_truncates_the_body_preview():
    s = pending_summary("SLACK_SEND_MESSAGE", {"channel": "#team", "markdown_text": "x" * 500})
    first, preview = s.split("\n")
    assert first == "Send Slack message to #team"
    assert preview == "x" * 200 + "…"


def test_pending_summary_known_verbs_and_targets():
    assert pending_summary(
        "GMAIL_REPLY_TO_THREAD", {"thread_id": "t1", "message_body": "Thanks!"}
    ) == "Reply to email\nThanks!\nthread_id: t1"  # G1: no argument is hidden
    assert pending_summary(
        "TELEGRAM_SEND_MESSAGE", {"chat_id": 42, "text": "On my way"}
    ) == "Send Telegram message to 42\nOn my way"
    assert pending_summary(
        "GOOGLECALENDAR_UPDATE_EVENT",
        {"event_id": "e1", "summary": "Dentist", "start_datetime": "2026-10-14T10:00"},
    ) == "Update event: Dentist (2026-10-14T10:00)\nevent_id: e1"
    assert pending_summary(
        "GOOGLECALENDAR_CREATE_EVENT", {"summary": "Sync", "attendees": ["a@x.it", "b@x.it"]}
    ) == "Create event with a@x.it, b@x.it: Sync"
    assert pending_summary(
        "TODOIST_CREATE_TASK", {"content": "Buy milk", "responsible_uid": "7"}
    ) == "Create task · Responsible uid: 7: Buy milk"


def test_pending_summary_fallback_uses_slug_words_and_arguments():
    assert pending_summary("GMAIL_MOVE_TO_TRASH", {"message_id": "m1"}) == (
        "Gmail Move To Trash (message_id=m1)"
    )
    assert pending_summary("GOOGLECALENDAR_DELETE_EVENT", {"event_id": "e1"}) == (
        "Delete event (event_id=e1)"
    )
    assert pending_summary("SOMEAPP_DO_MAGIC", {}) == "Someapp Do Magic"


def test_pending_summary_shows_every_recipient_with_labels():
    s = pending_summary(
        "GMAIL_SEND_EMAIL",
        {
            "recipient_email": "ann@x.it",
            "cc": ["c1@x.com"],
            "bcc": ["evil@x.com"],
            "extra_recipients": ["e2@x.com"],
            "subject": "Budget",
            "body": "hi",
        },
    )
    first, preview = s.split("\n")
    assert preview == "hi"
    for address in ("ann@x.it", "c1@x.com", "evil@x.com", "e2@x.com"):
        assert address in first
    assert "Cc: c1@x.com" in first and "Bcc: evil@x.com" in first
    assert first.endswith(": Budget")


def test_pending_summary_does_not_truncate_long_recipient_lists():
    people = [f"user{i}@example.com" for i in range(30)]
    event = {"summary": "All hands", "attendees": people}
    s = pending_summary("GOOGLECALENDAR_CREATE_EVENT", event)
    assert all(p in s for p in people)
    s = pending_summary("GMAIL_SEND_EMAIL", {"to": "a" * 300 + "@x.it", "bcc": ["b@x.it"]})
    assert "a" * 100 in s and "a" * 101 not in s and "b@x.it" in s


def test_pending_summary_update_without_title_shows_the_target_id():
    assert "event_id=evt-9" in pending_summary(
        "GOOGLECALENDAR_UPDATE_EVENT", {"event_id": "evt-9", "attendees": ["z@x.it"]}
    )
    s = pending_summary("TODOIST_DELETE_TASK", {"task_id": "t-5"})
    assert "task_id=t-5" in s
    # with a title the first line names the event, not the id (listed below it since G1)
    assert "evt-9" not in pending_summary(
        "GOOGLECALENDAR_UPDATE_EVENT", {"event_id": "evt-9", "summary": "Dentist"}
    ).split("\n")[0]


# --- G1: nothing hidden on a confirm card -----------------------------------------------


def test_confirm_summary_lists_every_other_argument():
    s = pending_summary(
        "GMAIL_SEND_EMAIL",
        {
            "recipient_email": "ann@x.it",
            "subject": "Budget",
            "body": "Hi team, numbers attached.",
            "participants": ["p1@x.it", {"email": "p2@x.it"}],
            "user_email": "hidden@x.it",
            "weird_flag": "z" * 300,
            "empty": "",
            "nothing": None,
        },
    )
    lines = s.split("\n")
    assert lines[0] == "Send email to ann@x.it: Budget"
    assert lines[1] == "Hi team, numbers attached."
    assert "participants: p1@x.it, p2@x.it" in lines
    assert "user_email: hidden@x.it" in lines
    assert "weird_flag: " + "z" * 100 + "…" in lines
    assert "z" * 101 not in s
    # the body is only the preview, never repeated as an argument line
    assert s.count("numbers attached") == 1
    assert "empty" not in s and "nothing" not in s


def test_confirm_summary_shows_other_body_like_keys_as_capped_previews():
    s = pending_summary(
        "SLACK_SEND_MESSAGE",
        {"channel": "#team", "text": "short", "html_content": "h" * 500, "members": ["u1", "u2"]},
    )
    lines = s.split("\n")
    assert lines[:2] == ["Send Slack message to #team", "short"]
    assert "members: u1, u2" in lines
    assert "html_content: " + "h" * 200 + "…" in lines
    assert "h" * 201 not in s


def test_confirm_summary_lists_ids_and_create_read_are_unchanged():
    s = pending_summary(
        "GOOGLECALENDAR_UPDATE_EVENT", {"event_id": "evt-9", "summary": "Dentist"}
    )
    assert s == "Update event: Dentist\nevent_id: evt-9"
    # CREATE without people: unchanged, nothing extra listed
    assert pending_summary(
        "TODOIST_CREATE_TASK", {"content": "Buy milk", "project_id": "p1", "priority": 4}
    ) == "Create task: Buy milk"
    assert pending_summary("GMAIL_FETCH_EMAILS", {"query": "from:ada", "max_results": 5}) == (
        "Gmail Fetch Emails (query=from:ada, max_results=5)"
    )


def test_confirm_summary_lines_cannot_be_forged_with_newlines():
    s = pending_summary(
        "GMAIL_SEND_EMAIL", {"to": "a@x.it", "subject": "Hi", "footer": "x\nSend email to b"}
    )
    assert "footer: x Send email to b" in s.split("\n")
