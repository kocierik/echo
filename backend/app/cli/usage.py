"""What a day of Echo costs, per user and kind of work.

    python -m app.cli.usage [--days 7]
"""

import argparse
import asyncio

from app.core.database import async_session
from app.services.usage_report import composio_actions, summarize, usage_report


async def _main(days: int) -> None:
    async with async_session() as db:
        rows = await usage_report(db, days)
        actions = await composio_actions(db, days)
    print(summarize(rows, actions) if rows else f"No model usage in the last {days} days.")


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.cli.usage")
    parser.add_argument("--days", type=int, default=7)
    asyncio.run(_main(parser.parse_args().days))


if __name__ == "__main__":
    main()
