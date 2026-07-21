"""Sentence-aware text chunking for RAG embeddings.

Splits text into chunks that respect sentence boundaries,
ensuring no concept is cut mid-sentence.
"""

import re


def split_sentences(text: str) -> list[str]:
    """Split text into sentences using punctuation boundaries.

    Handles common edge cases in Italian/English transcriptions.
    Merges very short fragments (< 5 words) with the previous sentence.
    """
    text = text.strip()
    if not text:
        return []

    # Split on sentence-ending punctuation followed by space or end of string
    raw_splits = re.split(r'(?<=[.!?…])\s+', text)

    # Filter empty strings and merge very short fragments with previous
    sentences = []
    for fragment in raw_splits:
        fragment = fragment.strip()
        if not fragment:
            continue
        if sentences and len(fragment.split()) < 2:
            # Merge single-word fragments (e.g. "Sì.", "Ok.", "No.") with previous
            sentences[-1] = sentences[-1] + " " + fragment
        else:
            sentences.append(fragment)

    return sentences


def chunk_text(text: str, chunk_size: int, overlap: int) -> list[str]:
    """Split text into chunks of approximately chunk_size tokens with overlap.

    Uses sentence-aware splitting: never breaks mid-sentence.
    Aggregates complete sentences until the token budget is reached,
    then starts a new chunk with overlap (repeating the last N tokens
    worth of sentences from the previous chunk).

    Args:
        text: Input text to chunk.
        chunk_size: Maximum tokens (words) per chunk.
        overlap: Number of overlap tokens between consecutive chunks.

    Returns:
        List of text chunks.
    """
    sentences = split_sentences(text)
    if not sentences:
        return []

    chunks = []
    current_sentences: list[str] = []
    current_token_count = 0

    for sentence in sentences:
        sentence_tokens = len(sentence.split())

        # If a single sentence exceeds chunk_size, include it as its own chunk
        if sentence_tokens > chunk_size:
            # Flush current buffer first
            if current_sentences:
                chunks.append(" ".join(current_sentences))
            chunks.append(sentence)
            current_sentences = []
            current_token_count = 0
            continue

        # Would adding this sentence exceed the budget?
        if current_token_count + sentence_tokens > chunk_size and current_sentences:
            # Flush current chunk
            chunks.append(" ".join(current_sentences))

            # Build overlap: take sentences from the end of current chunk
            overlap_sentences: list[str] = []
            overlap_tokens = 0
            for s in reversed(current_sentences):
                s_tokens = len(s.split())
                if overlap_tokens + s_tokens > overlap:
                    break
                overlap_sentences.insert(0, s)
                overlap_tokens += s_tokens

            # Start new chunk with overlap
            current_sentences = overlap_sentences
            current_token_count = overlap_tokens

        current_sentences.append(sentence)
        current_token_count += sentence_tokens

    # Flush remaining
    if current_sentences:
        chunks.append(" ".join(current_sentences))

    return chunks
