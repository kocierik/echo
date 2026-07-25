"""Unit tests for transcription enhancement utilities."""

from app.services.transcription_enhancer import (  # noqa: E402
    clean_transcription,
    is_meaningful_transcription,
)


class TestIsMeaningfulTranscription:
    def test_empty_string(self):
        assert is_meaningful_transcription("") is False

    def test_very_short(self):
        # Only truly empty/artifact content is filtered
        assert is_meaningful_transcription("..") is False

    def test_filler_words_kept(self):
        # Fillers are meaningful in conversation context (agreement/confirmation)
        assert is_meaningful_transcription("sì ok") is True
        assert is_meaningful_transcription("ok") is True
        assert is_meaningful_transcription("no") is True

    def test_meaningful_short(self):
        assert is_meaningful_transcription("chiamami domani") is True

    def test_meaningful_sentence(self):
        assert is_meaningful_transcription(
            "Marco mi ha detto di comprare il latte"
        ) is True

    def test_punctuation_only(self):
        assert is_meaningful_transcription("...") is False

    def test_single_real_word(self):
        assert is_meaningful_transcription("ciao") is True

    def test_two_real_words(self):
        assert is_meaningful_transcription("buongiorno Marco") is True


class TestCleanTranscription:
    def test_normalizes_whitespace(self):
        result = clean_transcription("  ciao   come   stai  ")
        assert result == "Ciao come stai"

    def test_capitalizes_first_letter(self):
        result = clean_transcription("marco è arrivato")
        assert result == "Marco è arrivato"

    def test_already_capitalized(self):
        result = clean_transcription("Tutto bene grazie")
        assert result == "Tutto bene grazie"

    def test_removes_repeated_hallucinations(self):
        # Whisper sometimes repeats phrases when transcribing silence
        result = clean_transcription(
            "Grazie per averci guardato. Grazie per averci guardato. "
            "Grazie per averci guardato."
        )
        # Should collapse repetitions
        assert result.count("Grazie per averci guardato") < 3

    def test_empty_string(self):
        result = clean_transcription("")
        assert result == ""

    def test_preserves_normal_text(self):
        text = "Domani alle tre ho una riunione con il team di marketing."
        result = clean_transcription(text)
        assert result == text
