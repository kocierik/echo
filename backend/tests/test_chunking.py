"""Tests for sentence-aware chunking."""

from app.services.chunking import chunk_text, split_sentences


class TestSplitSentences:
    def test_basic_split(self):
        text = "Prima frase. Seconda frase. Terza frase."
        result = split_sentences(text)
        assert len(result) == 3
        assert result[0] == "Prima frase."
        assert result[1] == "Seconda frase."
        assert result[2] == "Terza frase."

    def test_question_marks(self):
        text = "Come stai? Bene grazie. E tu?"
        result = split_sentences(text)
        assert len(result) == 3

    def test_exclamation(self):
        text = "Fantastico! Andiamo avanti. Ok?"
        result = split_sentences(text)
        # "Ok?" is a single word, gets merged with "Andiamo avanti."
        assert len(result) == 2
        assert result[0] == "Fantastico!"
        assert "Ok?" in result[1]

    def test_short_fragment_merged(self):
        text = "Marco ha detto una cosa importante. Sì. Dobbiamo partire domani."
        result = split_sentences(text)
        # "Sì." is a single word, gets merged with previous
        assert len(result) == 2
        assert "Sì." in result[0]

    def test_empty_text(self):
        assert split_sentences("") == []
        assert split_sentences("   ") == []

    def test_single_sentence(self):
        result = split_sentences("Una sola frase senza punto finale")
        assert result == ["Una sola frase senza punto finale"]


class TestChunkText:
    def test_empty_text(self):
        assert chunk_text("", 100, 20) == []

    def test_short_text_single_chunk(self):
        text = "Prima frase. Seconda frase."
        result = chunk_text(text, 100, 20)
        assert len(result) == 1
        assert result[0] == text

    def test_respects_sentence_boundaries(self):
        # 3 sentences, ~10 words each. Chunk size = 15 words, overlap = 5
        text = (
            "Marco mi ha detto che la conferenza è importante. "
            "Dobbiamo preparare le slide entro venerdì. "
            "Ha suggerito di invitare anche Giulia al meeting."
        )
        result = chunk_text(text, 15, 5)
        # Each sentence is ~8-9 words, so each chunk should contain 1-2 sentences
        assert len(result) >= 2
        # No chunk should cut mid-sentence
        for chunk in result:
            # Each chunk should end with a sentence-ending punctuation
            assert chunk.rstrip().endswith((".")) or chunk.rstrip().endswith(("?", "!"))

    def test_overlap_contains_previous_sentences(self):
        text = (
            "Frase uno che è abbastanza lunga per contare. "
            "Frase due anche questa un po' lunga. "
            "Frase tre continua il discorso qui. "
            "Frase quattro per completare il testo."
        )
        result = chunk_text(text, 12, 8)
        # With overlap, some text should appear in multiple chunks
        if len(result) >= 2:
            # At least one sentence should appear in both consecutive chunks
            found_overlap = False
            for i in range(len(result) - 1):
                sentences_current = split_sentences(result[i])
                for s in sentences_current:
                    if s in result[i + 1]:
                        found_overlap = True
                        break
            assert found_overlap

    def test_very_long_sentence_own_chunk(self):
        # A sentence longer than chunk_size gets its own chunk
        long_sentence = "parola " * 600  # 600 words
        text = f"Breve. {long_sentence.strip()}. Altra breve."
        result = chunk_text(text, 500, 50)
        assert len(result) >= 2
        # The long sentence should be in its own chunk
        assert any(len(chunk.split()) > 500 for chunk in result)

    def test_no_empty_chunks(self):
        text = "Una. Due. Tre. Quattro. Cinque. Sei. Sette. Otto. Nove. Dieci."
        result = chunk_text(text, 5, 2)
        for chunk in result:
            assert chunk.strip() != ""

    def test_all_text_preserved(self):
        text = (
            "Prima frase importante. "
            "Seconda frase con dettagli. "
            "Terza frase conclusiva."
        )
        result = chunk_text(text, 8, 3)
        # All sentences should appear in at least one chunk
        for sentence in split_sentences(text):
            assert any(sentence in chunk for chunk in result)
