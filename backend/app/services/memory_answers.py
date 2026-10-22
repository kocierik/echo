"""Answers from memory: the system prompt, the period it covers, and the reply when the
memory has nothing. Shared by chat (app.routers.query), voice requests and the evals.
"""

import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone

from app.services.language import clear_language, detect_language
from app.services.llm_base import LLMMessage, LLMService
from app.services.temporal import DateRange
from app.services.web_search import search_options

logger = logging.getLogger(__name__)


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


_LIVE_WITHOUT_SEARCH = (
    "4. Something that needs live information (weather, news, scores, today's prices): "
    "say Echo cannot see live information, never make it up, and offer what it can, such "
    "as whether the user talked about it."
)
_LIVE_WITH_SEARCH = (
    "4. Something that needs live or current information (weather, news, scores, today's "
    "prices, opening hours): search the web, answer from what you found and name the "
    "sources (the site); if the search finds nothing, say so and never make it up. Search "
    "only for this kind of question, never for the user's own past."
)

_KINDS_OF_QUESTION = (
    "Not every question is about the user's memory. Tell which kind it is:\n"
    "1. About Echo itself or how to use it: answer from 'About Echo' below.\n"
    "2. A general question, not about the user's life (a definition, a calculation, a "
    "translation): answer briefly from general knowledge and say it does not come from "
    "their memory.\n"
    "3. About the user's past (what was said, who, when, what they promised): answer only "
    "from the context; when the context does not support an answer, say so and never guess.\n"
)


# Last, so they are not lost after the longer text about Echo
_LAST_RULES = (
    "Name Echo's screens and buttons exactly as written above, in English (the app is in "
    "English): 'Profile → Apps', never a translation. Answer in the language of the "
    "user's question, even when the context or these instructions are in another language."
)


_LANGUAGE_NAMES = {"en": "English", "it": "Italian"}


def rag_system_prompt(
    date_range: DateRange | None,
    about: str = "",
    language: str | None = None,
    can_search: bool = False,
) -> str:
    """System prompt for memory answers, written in the question's language.

    `about` (services.about_echo) lets it answer questions about Echo itself; `language`
    (`clear_language` of the question) is spelled out, since transcripts in another
    language pull the answer towards theirs; `can_search`: the web search tool is offered.
    """
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
    if about:
        live = _LIVE_WITH_SEARCH if can_search else _LIVE_WITHOUT_SEARCH
        prompt += (
            f"\n\n{_KINDS_OF_QUESTION}{live}\n\nAbout Echo:\n{about}\n\n{_LAST_RULES}"
        )
    if date_range:
        prompt += f"\n\nNote: results are filtered to the period {describe_period(date_range)}."
    if language in _LANGUAGE_NAMES:
        name = _LANGUAGE_NAMES[language]
        prompt += f"\n\nThe question is in {name}: answer in {name}."
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


@dataclass
class MemoryAnswer:
    text: str
    # Pages a web search found and the answer cites ({"title", "url"}); never memory
    web_sources: list[dict] = field(default_factory=list)


async def generate_answer(
    llm: LLMService,
    messages: list[LLMMessage],
    *,
    on_token: Callable[[str], Awaitable[None]] | None = None,
    search: dict | None = None,
) -> MemoryAnswer:
    """The model's answer, whole or passed on in pieces; `search` is the web search tool
    to offer (services/web_search.search_tool_for)."""
    options = search_options(search)
    if on_token is None:
        response = await llm.complete(messages, temperature=0.3, **options)
        return MemoryAnswer(response.content, list(response.citations))
    pieces: list[str] = []
    cited: list[dict] = []
    if search:
        options["on_citations"] = cited.extend
    async for piece in llm.stream(messages, temperature=0.3, **options):
        pieces.append(piece)
        await on_token(piece)
    return MemoryAnswer("".join(pieces), cited)


async def answer_without_memory(
    llm: LLMService,
    question: str,
    history: list[dict],
    date_range: DateRange | None,
    about: str,
    on_token: Callable[[str], Awaitable[None]] | None = None,
    search: dict | None = None,
) -> MemoryAnswer:
    """Nothing in memory: the model answers with the prompt's rules and no context (a
    question about Echo, a general one, a live one with `search`), or says it does not
    know. The fixed text only when the model fails before writing anything."""
    prompt = rag_system_prompt(
        date_range, about, clear_language(question), can_search=search is not None
    )
    messages = [LLMMessage(role="system", content=prompt)]
    messages.extend(LLMMessage(role=m["role"], content=m["content"]) for m in history)
    messages.append(
        LLMMessage(role="user", content=f"(Nothing found in memory.)\n\nQuestion: {question}")
    )
    written = False

    async def passed_on(piece: str) -> None:
        nonlocal written
        written = True
        await on_token(piece)

    try:
        return await generate_answer(
            llm, messages, on_token=passed_on if on_token else None, search=search
        )
    except Exception:
        if written:
            raise
        logger.warning("Answer without memory failed; using the fixed text", exc_info=True)
        return MemoryAnswer(no_results_message(question, date_range))
