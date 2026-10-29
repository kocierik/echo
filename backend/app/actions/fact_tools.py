"""The action agent's About you tools: remember a fact about the user when they ask
("Echo, ricordati che sono vegetariano"), forget one ("dimentica che lavoro a Milano").
A remembered fact is kept at once: the user asked for it.
"""

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


async def run_fact_tool(
    db: AsyncSession, user_id: uuid.UUID, name: str, arguments: dict
) -> ToolResult:
    """Run an About you tool; the caller logs it and commits."""
    text = str(arguments.get("fact") or "").strip()
    if name == REMEMBER:
        try:
            fact = await user_facts.add_kept(db, user_id, text, "echo")
        except FactError as exc:
            return ToolResult(ok=False, error=str(exc))
        return ToolResult(ok=True, data={"remembered": fact.text})
    if name == FORGET:
        wanted = user_facts.normalize(text)
        if not wanted:
            return ToolResult(ok=False, error="fact is required")
        facts = await user_facts.list_facts(db, user_id, "kept")
        # The fact said again, else the one the words are about (only when it is one)
        same = [f for f in facts if user_facts.normalize(f.text) == wanted]
        about = same or [f for f in facts if wanted in user_facts.normalize(f.text)]
        if len(about) != 1:
            return ToolResult(
                ok=False,
                error="No such fact" if not about else "Several facts match: say which one",
            )
        fact: UserFact = about[0]
        await db.delete(fact)
        return ToolResult(ok=True, data={"forgotten": fact.text})
    return ToolResult(ok=False, error=f"Unknown tool: {name}")
