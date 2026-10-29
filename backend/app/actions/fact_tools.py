"""The action agent's About you tools: remember a fact about the user when they ask
("Echo, ricordati che sono vegetariano"), forget one ("dimentica che lavoro a Milano").

A remembered fact is kept at once only when the user's own message asks for it: one that
came from somewhere else (an email, a document, a web page the agent read) waits as a
suggestion, so no text can write itself into every answer.
"""

import re
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.provider import ToolResult
from app.models.user_fact import UserFact
from app.services import user_facts
from app.services.user_facts import FactError

REMEMBER = "ECHO_REMEMBER_ABOUT_USER"
FORGET = "ECHO_FORGET_ABOUT_USER"

FACT_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": REMEMBER,
            "description": (
                "Remember a lasting fact about the user themselves, when they ask Echo to "
                "('ricordati che sono vegetariano', 'remember I work at Acme'): it is then used "
                "in every answer and shown in Profile → Memory. Not for things to find again "
                "(where they parked, a wine they liked: those are Saved)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "fact": {
                        "type": "string",
                        "description": "One sentence about the user, in their language.",
                    },
                },
                "required": ["fact"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": FORGET,
            "description": (
                "Forget a fact Echo knows about the user, when they ask ('dimentica che "
                "lavoro a Milano')."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "fact": {
                        "type": "string",
                        "description": "The fact, or the words it is about.",
                    },
                },
                "required": ["fact"],
            },
        },
    },
]

FACT_TOOL_NAMES = frozenset({REMEMBER, FORGET})

# The user's own message asks Echo to remember something
_ASKED = re.compile(
    r"\b(ricord\w*|memorizz\w*|tieni a mente|segnati|non dimenticar\w*|remember|"
    r"keep in mind|note that|don'?t forget)\b",
    re.IGNORECASE,
)


async def run_fact_tool(
    db: AsyncSession, user_id: uuid.UUID, name: str, arguments: dict, request: str = "",
    untrusted: bool = False,
) -> ToolResult:
    """Run an About you tool; the caller logs it and commits. `request` is the user's own
    message; `untrusted`: the agent has also read words the user did not write, so the
    fact may come from them and is only suggested."""
    text = str(arguments.get("fact") or "").strip()
    if name == REMEMBER:
        try:
            if _ASKED.search(request) and not untrusted:
                fact = await user_facts.add_kept(db, user_id, text, "echo")
                return ToolResult(ok=True, data={"remembered": fact.text})
            await user_facts.add_suggested(db, user_id, text, "echo")
        except FactError as exc:
            return ToolResult(ok=False, error=str(exc))
        return ToolResult(ok=True, data={
            "suggested": text,
            "note": "Not kept: the user did not ask. It waits in Profile → Memory for them.",
        })
    if name == FORGET:
        wanted = user_facts.normalize(text)
        if not wanted:
            return ToolResult(ok=False, error="fact is required")
        facts = await user_facts.list_facts(db, user_id, "kept")
        # The fact said again, else the one the words are about (only when it is one)
        same = [f for f in facts if user_facts.normalize(f.text) == wanted]
        # Whole words: "auto" is not "autodidatta"
        about = same or [
            f for f in facts
            if re.search(rf"\b{re.escape(wanted)}\b", user_facts.normalize(f.text))
        ]
        if len(about) != 1:
            return ToolResult(
                ok=False,
                error="No such fact" if not about else "Several facts match: say which one",
            )
        fact: UserFact = about[0]
        # Out of every answer, and never suggested again
        fact.status = "discarded"
        return ToolResult(ok=True, data={"forgotten": fact.text})
    return ToolResult(ok=False, error=f"Unknown tool: {name}")
