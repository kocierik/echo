"""Tool-calling agent: reads and acts on the user's connected tools, with confirmations.

READ and CREATE tools run immediately (each audited); the first CONFIRM-tier call of a
model turn becomes a pending action the user confirms in the app, and the loop stops
without executing anything else from that turn.
"""

import json
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime

from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.audit import log_action, pending_summary
from app.actions.availability import APP_NAMES
from app.actions.pending import create_pending_action
from app.actions.phone_provider import PHONE_APP_NAMES
from app.actions.policy import ToolTier, classify_call, toolkit_of
from app.actions.provider import (
    AccountNotConnectedError,
    ActionOutcomeUnknown,
    ActionProvider,
    ActionProviderError,
    ToolResult,
)
from app.core.config import settings
from app.core.timezone import user_zone
from app.models.pending_action import PendingAction
from app.services.language import detect_language
from app.services.llm_base import LLMMessage, LLMService, LLMToolCall
from app.services.memory_retrieval import retrieve_memory_context

logger = logging.getLogger(__name__)

MAX_TOOL_RESULT_CHARS = 12_000
TRUNCATION_SUFFIX = "[truncated]"

SEARCH_MEMORY_TOOL = {
    "type": "function",
    "function": {
        "name": "search_memory",
        "description": (
            "Search Echo's memory of the user's recorded conversations "
            "(what was said, by whom, when). Use it for questions about the user's past."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "What to look for in memory."},
            },
            "required": ["query"],
        },
    },
}

TEXTS = {
    "en": {
        "confirm": "Confirm in the app to proceed.",
        "not_connected": "{toolkit} isn't connected. Connect it in the app and try again.",
        "provider_error": (
            "I couldn't reach {toolkit}, so nothing was done. Please try again later."
        ),
        "unreachable": "I couldn't reach your connected apps right now. Please try again later.",
        "step_limit": (
            "I couldn't finish this request in a reasonable number of steps. "
            "Please try a more specific request."
        ),
        "no_answer": "I couldn't produce an answer. Please try again.",
        "unknown": (
            "I couldn't confirm whether it went through — check {toolkit} before trying again."
        ),
    },
    "it": {
        "confirm": "Conferma nell'app per procedere.",
        "not_connected": "{toolkit} non è collegato. Collegalo nell'app e riprova.",
        "provider_error": (
            "Non sono riuscito a raggiungere {toolkit}, quindi non è stato fatto nulla. "
            "Riprova più tardi."
        ),
        "unreachable": (
            "Non riesco a raggiungere le app collegate in questo momento. Riprova più tardi."
        ),
        "step_limit": (
            "Non sono riuscito a completare la richiesta in un numero ragionevole di passaggi. "
            "Prova con una richiesta più specifica."
        ),
        "no_answer": "Non sono riuscito a produrre una risposta. Riprova.",
        "unknown": (
            "Non sono riuscito a verificare se è andata a buon fine: "
            "controlla {toolkit} prima di riprovare."
        ),
    },
}

TOOLKIT_NAMES = {**APP_NAMES, **PHONE_APP_NAMES}

# Told to the model when an execute call timed out after being sent.
_UNKNOWN_NOTE = (
    "The request timed out after it was sent: it may or may not have been done. "
    "Do not say it was done or not done, and do not retry it."
)

_NOTHING_FOUND = "Nothing found in memory for this query."

_SYSTEM_PROMPT = """You are Echo, the user's personal assistant. You can search the user's \
memory of recorded conversations (search_memory) and use the tools of their connected apps.

Now: {now} (timezone {timezone}). Today's date is {today}.

Rules:
- Answer in the same language as the user's request.
- Be concise. When summarizing emails, messages or events, keep only what matters.
- Never say an action was done unless its tool result confirms it. If a tool returns an \
error, say what failed and name the app.
- For anything that sends something to other people, modifies or deletes, just call the \
tool: Echo asks the user to confirm in the app before it runs. Do not ask for confirmation \
in the text yourself.
- Calendar: the default event duration is 1 hour. Use the user's timezone ({timezone}) for \
all times. When the user gives a new time for an event, keep its day and duration unless \
told otherwise. When no event id is known, find the event by title and day by listing \
events first.
"""

_PHONE_RULES = """- Reminders and Calendar on the user's iPhone (applereminders, applecalendar): \
when the user asks to be reminded of something at a time, create a reminder due then (the \
iPhone alerts them). Give their times as local 'YYYY-MM-DDTHH:MM'. An event goes to the \
iPhone's calendar unless the user names another calendar app.
"""


@dataclass
class AgentOutcome:
    answer: str
    pending_action: PendingAction | None = None
    executed_tools: list[str] = field(default_factory=list)


@dataclass
class _Failure:
    tool: str
    toolkit: str
    not_connected: bool
    # Timed out after being sent: reported with the "check {App}" note, never as failed.
    unknown: bool = False


def _system_prompt(phone_apps: bool = False) -> str:
    now = datetime.now(user_zone())
    prompt = _SYSTEM_PROMPT.format(
        now=now.strftime("%A %Y-%m-%d %H:%M"),
        today=now.date().isoformat(),
        timezone=settings.user_timezone,
    )
    return prompt + _PHONE_RULES if phone_apps else prompt


def _tool_name(schema: dict) -> str:
    return schema.get("function", {}).get("name", "")


def serialize_tool_result(value) -> str:
    """JSON for the model, truncated to MAX_TOOL_RESULT_CHARS (suffix included)."""
    text = json.dumps(value, default=str, ensure_ascii=False)
    if len(text) > MAX_TOOL_RESULT_CHARS:
        text = text[: MAX_TOOL_RESULT_CHARS - len(TRUNCATION_SUFFIX)] + TRUNCATION_SUFFIX
    return text


def _toolkit_label(toolkit: str) -> str:
    return TOOLKIT_NAMES.get(toolkit, toolkit.title())


def _failure_text(failure: _Failure, texts: dict) -> str:
    key = "not_connected" if failure.not_connected else "provider_error"
    return texts[key].format(toolkit=_toolkit_label(failure.toolkit))


def _mentions(answer: str, toolkit: str) -> bool:
    lowered = answer.lower()
    return toolkit in lowered or _toolkit_label(toolkit).lower() in lowered


def _final_answer(
    content: str, failures: list[_Failure], succeeded: set[str], texts: dict
) -> str:
    """The model's answer, made explicit about tools that failed.

    A failure is cleared only by a later success of the same tool slug (a retry), never by
    another tool of the same toolkit; an unknown outcome is never cleared (its note stays).
    If the answer does not name the toolkit of an uncleared failure, it is replaced by the
    fixed notice so it cannot claim the failed step happened.
    """
    answer = (content or "").strip()
    unresolved: list[_Failure] = []
    for failure in failures:
        if failure.unknown or failure.tool in succeeded:
            continue
        if any(f.toolkit == failure.toolkit for f in unresolved):
            continue
        if not _mentions(answer, failure.toolkit):
            unresolved.append(failure)
    if unresolved:
        answer = "\n".join(_failure_text(f, texts) for f in unresolved)
    if not answer and not _unknown_notes(failures, succeeded, texts):
        return texts["no_answer"]
    return _with_unknown_notes(answer, failures, succeeded, texts)


def _unknown_notes(failures: list[_Failure], succeeded: set[str], texts: dict) -> list[str]:
    """One "check {App}" note per toolkit with a call whose outcome is unknown.

    Never cleared by a later success of the same tool: the timed-out call may have gone
    through as well (a duplicate), so the user must still check the app.
    """
    notes: list[str] = []
    for failure in failures:
        if not failure.unknown:
            continue
        note = texts["unknown"].format(toolkit=_toolkit_label(failure.toolkit))
        if note not in notes:
            notes.append(note)
    return notes


def _with_unknown_notes(
    answer: str, failures: list[_Failure], succeeded: set[str], texts: dict
) -> str:
    notes = [n for n in _unknown_notes(failures, succeeded, texts) if n not in answer]
    return "\n".join(part for part in (answer, *notes) if part)


async def _offered_tools(
    provider: ActionProvider, user_id: uuid.UUID, connected: list[str] | None
) -> list[dict]:
    if connected is None:
        connected = await provider.connected_toolkits(str(user_id))
    if not connected:
        return []
    return await provider.tools_for(str(user_id), list(connected))


async def run_action_agent(
    db: AsyncSession,
    user_id: uuid.UUID,
    request: str,
    history: list[dict],
    *,
    session_id: uuid.UUID | None,
    source: str,
    provider: ActionProvider,
    llm: LLMService,
    max_steps: int = 6,
    connected_toolkits: list[str] | None = None,
) -> AgentOutcome:
    """Run the tool-calling loop for one request. The caller commits the session.

    `connected_toolkits`, when the caller already knows them, are the toolkits whose tools
    are offered: the connected apps the request names, else all connected ones.
    """
    texts = TEXTS[detect_language(request)]

    try:
        external_tools = await _offered_tools(provider, user_id, connected_toolkits)
    except ActionProviderError:
        logger.warning("Action provider unreachable while listing tools", exc_info=True)
        return AgentOutcome(answer=texts["unreachable"])
    offered = {_tool_name(schema) for schema in external_tools}
    tools = [SEARCH_MEMORY_TOOL, *external_tools]
    phone_apps = any(toolkit_of(name) in PHONE_APP_NAMES for name in offered)

    messages = [LLMMessage(role="system", content=_system_prompt(phone_apps))]
    for item in history:
        if item.get("role") in ("user", "assistant") and isinstance(item.get("content"), str):
            messages.append(LLMMessage(role=item["role"], content=item["content"]))
    messages.append(LLMMessage(role="user", content=request))

    executed: list[str] = []
    failures: list[_Failure] = []
    succeeded: set[str] = set()

    for _ in range(max_steps):
        response = await llm.complete_with_tools(list(messages), tools)
        if not response.tool_calls:
            answer = _final_answer(response.content, failures, succeeded, texts)
            return AgentOutcome(answer=answer, executed_tools=executed)

        confirm_call = next(
            (
                call for call in response.tool_calls
                if call.name in offered
                and classify_call(call.name, call.arguments) == ToolTier.CONFIRM
            ),
            None,
        )
        if confirm_call is not None:
            # Only the first confirm-tier call is kept; nothing else from this turn runs.
            summary = pending_summary(confirm_call.name, confirm_call.arguments)
            pending = await create_pending_action(
                db, user_id, session_id, source,
                confirm_call.name, confirm_call.arguments, summary,
            )
            return AgentOutcome(
                answer=_with_unknown_notes(
                    f"{summary}\n{texts['confirm']}", failures, succeeded, texts
                ),
                pending_action=pending,
                executed_tools=executed,
            )

        messages.append(LLMMessage(
            role="assistant", content=response.content or "", tool_calls=response.tool_calls,
        ))
        for call in response.tool_calls:
            content = await _run_tool(
                db, user_id, source, provider, call, offered, executed, failures, succeeded,
            )
            messages.append(LLMMessage(
                role="tool", content=content, tool_call_id=call.id, name=call.name,
            ))

    return AgentOutcome(
        answer=_with_unknown_notes(texts["step_limit"], failures, succeeded, texts),
        executed_tools=executed,
    )


async def _run_tool(
    db: AsyncSession,
    user_id: uuid.UUID,
    source: str,
    provider: ActionProvider,
    call: LLMToolCall,
    offered: set[str],
    executed: list[str],
    failures: list[_Failure],
    succeeded: set[str],
) -> str:
    """Run one READ/CREATE call (or search_memory) and return the tool message content."""
    if call.name == "search_memory":
        query = str(call.arguments.get("query") or "").strip()
        if not query:
            return serialize_tool_result({"error": "query is required"})
        memory = await retrieve_memory_context(db, user_id, query)
        return serialize_tool_result({"context": memory.context or _NOTHING_FOUND})

    if call.name not in offered:
        return serialize_tool_result({"error": f"Unknown tool: {call.name}"})

    toolkit = toolkit_of(call.name)
    not_connected = False
    try:
        result = await provider.execute(str(user_id), call.name, call.arguments)
    except ActionOutcomeUnknown as exc:
        result = ToolResult(ok=False, error=str(exc) or type(exc).__name__, unknown=True)
    except AccountNotConnectedError as exc:
        not_connected = True
        result = ToolResult(ok=False, error=str(exc))
    except ActionProviderError as exc:
        result = ToolResult(ok=False, error=str(exc) or type(exc).__name__)

    executed.append(call.name)
    await log_action(db, user_id, source, call.name, call.arguments, result)

    if result.ok:
        succeeded.add(call.name)
        return serialize_tool_result(result.data)
    failures.append(_Failure(
        tool=call.name, toolkit=toolkit, not_connected=not_connected, unknown=result.unknown,
    ))
    if result.unknown:
        return serialize_tool_result({
            "error": result.error or "Timed out", "outcome": "unknown", "note": _UNKNOWN_NOTE,
        })
    return serialize_tool_result({"error": result.error or "Tool failed"})
