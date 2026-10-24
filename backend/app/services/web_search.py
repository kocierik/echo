"""Web search for answers that need live information (weather, news, today's prices).

The search is a tool the model may call while answering, offered only while the user is
under their plan's searches a day (UTC day, services/plans.py). Each search is counted in
`llm_usage` (kind "web_search"); the pages the answer cites come back as its web sources.
Nothing found on the web is written into the user's memory.

OpenAI's built-in search is the only provider today; another (Perplexity) would implement
the same `WebSearchProvider`.
"""

import logging
import uuid
from datetime import datetime, timezone
from typing import Protocol

from sqlalchemy import func, select

from app.core.config import settings
from app.core.database import async_session
from app.models.llm_usage import LlmUsage
from app.services.plans import user_plan

logger = logging.getLogger(__name__)

USAGE_KIND = "web_search"


class WebSearchProvider(Protocol):
    # The model name searches are recorded under (and priced by, app/usage_prices.py)
    usage_model: str

    def hosted_tool(self) -> dict:
        """The tool the model is offered."""
        ...


class OpenAIWebSearch:
    """The Responses API's built-in search: OpenAI runs it inside the model call."""

    usage_model = "openai-web-search"

    def hosted_tool(self) -> dict:
        return {
            "type": "web_search",
            # Where the user is, roughly: "the weather" with no city is the user's own
            "user_location": {"type": "approximate", "timezone": settings.user_timezone},
        }


def get_web_search_provider() -> WebSearchProvider | None:
    if settings.web_search_provider == "openai":
        return OpenAIWebSearch()
    if settings.web_search_provider != "none":
        logger.warning("Unknown web search provider: %s", settings.web_search_provider)
    return None


async def searches_today(user_id: uuid.UUID, session_factory=None) -> int:
    async with (session_factory or async_session)() as db:
        total = await db.scalar(
            select(func.coalesce(func.sum(LlmUsage.input_units), 0)).where(
                LlmUsage.user_id == user_id,
                LlmUsage.kind == USAGE_KIND,
                LlmUsage.day == datetime.now(timezone.utc).date(),
            )
        )
    return int(total or 0)


async def search_tool_for(llm, user_id: uuid.UUID | None, session_factory=None) -> dict | None:
    """The search tool to offer `llm` for this user's question, or None: no provider, a
    model that cannot run it, the day's cap reached, or the count unreadable."""
    provider = get_web_search_provider()
    if provider is None or user_id is None or not getattr(llm, "can_search", False):
        return None
    try:
        async with (session_factory or async_session)() as db:
            cap = (await user_plan(db, user_id)).web_searches_per_day
        if await searches_today(user_id, session_factory) >= cap:
            return None
    except Exception:
        logger.warning("Could not count today's web searches", exc_info=True)
        return None
    return provider.hosted_tool()


def search_options(tool: dict | None) -> dict:
    """Keyword arguments for an LLM call: the search tool, when there is one."""
    return {"hosted_tools": [tool]} if tool else {}


# The OpenAI Responses output: what the model searched and the pages it cited


def searches_in(output) -> int:
    return sum(1 for item in output or [] if getattr(item, "type", None) == "web_search_call")


def citations_in(output) -> list[dict]:
    """The pages cited in the answer (title and URL), each once, in order."""
    seen: set[str] = set()
    cited: list[dict] = []
    for item in output or []:
        if getattr(item, "type", None) != "message":
            continue
        for part in getattr(item, "content", None) or []:
            for note in getattr(part, "annotations", None) or []:
                url = getattr(note, "url", None)
                if getattr(note, "type", None) != "url_citation" or not url or url in seen:
                    continue
                seen.add(url)
                cited.append({"title": getattr(note, "title", None), "url": url})
    return cited
