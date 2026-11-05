"""Making an assistant from a description (Profile → Assistants → New).

As Lindy and Gemini's Gems: the user says in words what it should do for them (a
template, when chosen, is the starting point); Echo writes the proposal (name, emoji,
instructions, first notes), which the user tries ("Try it", nothing kept) and saves or
edits. "Improve" turns a few words of instructions into full ones.
"""

import logging
import re

from app.services.assistants import (
    DEFAULT_EMOJI,
    MAX_INSTRUCTIONS,
    MAX_NAME,
    MAX_NOTES,
    AssistantError,
    template,
)
from app.services.llm_base import LLMMessage

logger = logging.getLogger(__name__)

# Answers given alongside a description (older apps)
MAX_ANSWERS = 8
# What the user writes (or dictates) to describe an assistant
MAX_DESCRIPTION = 2000
# What a proposal may use of the limits: room is left for the user and for the notes
# the assistant adds itself
PROPOSED_INSTRUCTIONS = 1200
PROPOSED_NOTES = 600


def _lang(language: str) -> str:
    return "it" if language == "it" else "en"


def _clean_emoji(value, fallback: str) -> str:
    emoji = str(value or "").strip()[:8]
    # Letters are a word, not an emoji
    return emoji if emoji and not re.search(r"[A-Za-z0-9]", emoji) else fallback


def _clean_notes(value) -> str:
    lines = value if isinstance(value, list) else str(value or "").splitlines()
    kept = []
    for line in lines:
        line = " ".join(str(line).split()).lstrip("-• ").strip()
        if line:
            kept.append(f"- {line[:200]}")
    notes = ""
    for line in kept[:6]:
        if len(notes) + len(line) + 1 > PROPOSED_NOTES:
            break
        notes = f"{notes}\n{line}" if notes else line
    return notes


def _answers_text(answers: list[dict]) -> str:
    lines = []
    for item in answers[:MAX_ANSWERS]:
        question = " ".join(str(item.get("question") or "").split())[:200]
        answer = " ".join(str(item.get("answer") or "").split())[:500]
        if question and answer:
            lines.append(f"Q: {question}\nA: {answer}")
    return "\n".join(lines) or "(no answers)"


async def compose(
    llm, language: str, *, key: str | None, topic: str | None, answers: list[dict]
) -> dict:
    """The proposal from the answers: {name, emoji, instructions, notes}."""
    lang = _lang(language)
    base = template(key, language) if key else None
    language_name = "Italian" if lang == "it" else "English"
    described = (topic or "").strip()[:MAX_DESCRIPTION]
    parts = []
    if described:
        parts.append(f"The user's description of what it should do for them:\n{described}")
    if base:
        parts.append(
            f'Start from this template ("{base["name"]}" {base["emoji"]}) and keep what it '
            f"says, adapted to the description:\n{base['instructions']}"
        )
    if not parts:
        raise AssistantError("Say what the assistant should do")
    start = "\n\n".join(parts)
    messages = [
        LLMMessage(role="system", content=(
            "You write a personal assistant for the user, inside a memory app that hears "
            "their day (Echo). From the user's description (and the template or answers, when "
            "given) write, in "
            f"{language_name}:\n"
            f"- name: 1-3 words, at most {MAX_NAME} characters;\n"
            "- emoji: one emoji for the topic;\n"
            "- instructions: addressed to the assistant in the second person (\"You are "
            "my...\"), from the user's point of view: its role, what to note in its notes, "
            "how to answer (the tone the user asked, else short and warm), what to watch "
            "for and remind; concrete, keeping every wish the user wrote and adding nothing "
            f"they would not want, at most {PROPOSED_INSTRUCTIONS} characters, plain text;\n"
            "- notes: the facts the user gave worth keeping (goal, limits, times, budget, "
            "exam dates), one short line each, at most 6 lines; none when there are none.\n"
            "Health topics: general guidance only, never diagnoses or prescriptions. Money: "
            "no investment advice.\n"
            'Answer in JSON: {"name": "...", "emoji": "...", "instructions": "...", '
            '"notes": ["..."]}'
        )),
        LLMMessage(
            role="user", content=f"{start}\n\nThe user's answers:\n{_answers_text(answers)}"
        ),
    ]
    try:
        result = await llm.complete_json(messages, temperature=0.4)
    except Exception as exc:
        logger.warning("Could not write an assistant", exc_info=True)
        raise AssistantError("Echo could not write it now: try again", 503) from exc
    name = " ".join(str(result.get("name") or "").split())[:MAX_NAME] or (
        base["name"] if base else ""
    )
    instructions = str(result.get("instructions") or "").strip()[:MAX_INSTRUCTIONS]
    if not instructions:
        if base is None:
            raise AssistantError("Echo could not write it now: try again", 503)
        instructions = base["instructions"]
    return {
        "name": name or ("Assistente" if lang == "it" else "Assistant"),
        "emoji": _clean_emoji(result.get("emoji"), base["emoji"] if base else DEFAULT_EMOJI),
        "instructions": instructions,
        "notes": _clean_notes(result.get("notes"))[:MAX_NOTES],
    }


async def improve(llm, language: str, *, name: str, instructions: str) -> str:
    """A few words of instructions made into full ones, keeping everything they say."""
    instructions = (instructions or "").strip()
    if len(instructions) < 3:
        raise AssistantError("Write a few words first")
    language_name = "Italian" if _lang(language) == "it" else "English"
    messages = [
        LLMMessage(role="system", content=(
            "Rewrite the user's instructions for their personal assistant (inside Echo, a "
            "memory app that hears their day) into clear, complete ones: its role, what to "
            "keep in its notes, how to answer, what to watch for. Keep every wish the user "
            "wrote, add nothing they would not want, second person (\"You are my...\"), "
            f"in {language_name}, at most {PROPOSED_INSTRUCTIONS} characters, plain text.\n"
            'Answer in JSON: {"instructions": "..."}'
        )),
        LLMMessage(
            role="user",
            content=f"Assistant: {name or '(no name yet)'}\n\n{instructions[:MAX_INSTRUCTIONS]}",
        ),
    ]
    try:
        result = await llm.complete_json(messages, temperature=0.3)
    except Exception as exc:
        logger.warning("Could not improve instructions", exc_info=True)
        raise AssistantError("Echo could not rewrite them now: try again", 503) from exc
    better = str(result.get("instructions") or "").strip()[:MAX_INSTRUCTIONS]
    if not better:
        raise AssistantError("Echo could not rewrite them now: try again", 503)
    return better


async def try_out(llm, *, personal: str, draft: dict, question: str) -> str:
    """How an assistant not saved yet would answer `question` (its prompt, the user's own
    instructions and facts; no tools, nothing kept): "Try it" before saving."""
    from app.models.assistant import Assistant
    from app.services.assistants import assistant_prompt

    question = " ".join((question or "").split())[:1000]
    if not question:
        raise AssistantError("Ask it something")
    draft_assistant = Assistant(
        name=" ".join(str(draft.get("name") or "").split())[:MAX_NAME] or "Assistant",
        emoji=str(draft.get("emoji") or DEFAULT_EMOJI)[:8],
        instructions=str(draft.get("instructions") or "")[:MAX_INSTRUCTIONS],
        notes=str(draft.get("notes") or "")[:MAX_NOTES],
    )
    system = (
        "You are Echo, the user's personal assistant inside a memory app that hears their "
        "day. Answer briefly, in the user's language. This is a trial of an assistant the "
        "user is making: answer as it would. It cannot search the memory or use apps in "
        "this trial; when it would need them, say what it would do once saved.\n"
        f"{personal}\n{assistant_prompt(draft_assistant, notes_tool=False)}"
    )
    try:
        response = await llm.complete(
            [LLMMessage(role="system", content=system), LLMMessage(role="user", content=question)],
            temperature=0.4,
        )
    except Exception as exc:
        logger.warning("Could not try an assistant", exc_info=True)
        raise AssistantError("Echo could not answer now: try again", 503) from exc
    answer = (response.content or "").strip()
    if not answer:
        raise AssistantError("Echo could not answer now: try again", 503)
    return answer
