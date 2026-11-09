"""The words the user corrects in transcripts become hints for the speech-to-text."""

from datetime import datetime, timezone

from app.models.transcription_edit import TranscriptionEdit
from app.services.transcription_enhancer import build_stt_context, learned_words
from tests.conftest import TEST_USER_ID
from tests.factories import make_conversation


def test_the_words_a_correction_added_most_corrected_first():
    edits = [
        ("[You] Vado in palestra Siems five years.", "[You] Vado in palestra since five years."),
        ("[You] Parlo con Anit.", "[You] Parlo con Anita."),
        ("[You] Anit arriva.", "[You] Anita arriva!"),
        ("[You] ok", "[You] ok, sì"),  # too short to learn
    ]

    assert learned_words(edits) == ["Anita", "since"]


async def test_corrected_words_are_keyterms(db_session):
    _, [transcription] = await make_conversation(
        db_session, started_at=datetime.now(timezone.utc), texts=("[You] Ciao Anit.",)
    )
    db_session.add(TranscriptionEdit(
        transcription_id=transcription.id, user_id=TEST_USER_ID,
        old_text="[You] Ciao Anit.", new_text="[You] Ciao Anita.",
    ))
    await db_session.commit()

    context = await build_stt_context(db_session, TEST_USER_ID)

    assert "Anita" in context.keyterms


async def test_where_a_word_was_said(db_session):
    from app.services.memory_retrieval import where_said

    await make_conversation(
        db_session, started_at=datetime.now(timezone.utc),
        texts=("[Others] Mi mandi la Fattura?", "[You] Sì, al 100% domani.", "[You] Ciao."),
    )
    await db_session.commit()

    assert "Mi mandi la Fattura?" in await where_said(db_session, TEST_USER_ID, "fattura")
    # % is a character, not "anything"
    found = await where_said(db_session, TEST_USER_ID, "%")
    assert "100%" in found and "Ciao" not in found
    assert await where_said(db_session, TEST_USER_ID, "preventivo") == ""
