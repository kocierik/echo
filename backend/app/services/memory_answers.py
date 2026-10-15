"""Answers from memory: the system prompt, the period it covers, and the reply when the
memory has nothing. Shared by chat (app.routers.query), voice requests and the evals.
"""

from datetime import datetime, timezone

from app.services.language import detect_language
from app.services.temporal import DateRange


def format_date_filter(date_range: DateRange | None) -> dict | None:
    """Format date range for API response."""
    if date_range is None:
        return None
    return {
        "from": date_range.date_from.isoformat() if date_range.date_from else None,
        "to": date_range.date_to.isoformat() if date_range.date_to else None,
    }


def as_utc(value: datetime | None) -> datetime | None:
    """Make an explicit filter bound timezone-aware (naive values are UTC)."""
    if value is None or value.tzinfo is not None:
        return value
    return value.replace(tzinfo=timezone.utc)


def describe_period(date_range: DateRange) -> str:
    """Period for the RAG prompt; open ends are described in words."""
    if date_range.date_from and date_range.date_to:
        return (
            f"{date_range.date_from.strftime('%d/%m/%Y')} - "
            f"{date_range.date_to.strftime('%d/%m/%Y')}"
        )
    if date_range.date_from:
        return f"from {date_range.date_from.strftime('%d/%m/%Y')} onwards"
    return f"until {date_range.date_to.strftime('%d/%m/%Y')}"


def rag_system_prompt(date_range: DateRange | None) -> str:
    """System prompt for memory answers, written in the question's language."""
    prompt = (
        "You are a personal assistant. The user asks about their own memory: "
        "past conversations, ideas, tasks and people they mentioned. "
        "Answer ONLY from the provided context. The context includes:\n"
        "- 'Relevant conversation summaries' for a high-level overview\n"
        "- 'Structured knowledge' (entities: people, tasks, ideas, events)\n"
        "- 'People asked about': who a person the question names is, and where they came up\n"
        "- Excerpts of real transcripts for specific details\n\n"
        "Use the summaries for general questions ('what happened yesterday?') and the "
        "excerpts for specific ones ('what exactly did Marco say?'). Transcripts may be "
        "in another language than the question: quote them as they are when useful. "
        "If the context is not enough, say so clearly. For follow-up questions, use the "
        "previous conversation to understand what the user refers to. "
        "Always answer in the same language as the user's question."
    )
    if date_range:
        prompt += f"\n\nNote: results are filtered to the period {describe_period(date_range)}."
    return prompt


_NO_RESULTS = {
    "en": "I don't have anything in your memory to answer this yet.",
    "it": "Non ho ancora informazioni nella memoria per rispondere a questa domanda.",
}
_NO_RESULTS_IN_PERIOD = {
    "en": (
        "I couldn't find anything in your memory for that period. "
        "Try rephrasing the question or widening the period."
    ),
    "it": (
        "Non ho trovato informazioni nella memoria per il periodo indicato. "
        "Prova a riformulare la domanda o a estendere il periodo."
    ),
}


def no_results_message(question: str, date_range: DateRange | None) -> str:
    """Reply when memory has nothing relevant, in the question's language."""
    messages = _NO_RESULTS_IN_PERIOD if date_range else _NO_RESULTS
    return messages[detect_language(question)]
