"""Worker lifecycle helpers: shutdown-aware sleeps and graceful task shutdown."""

import asyncio
import logging
from collections.abc import Iterable

logger = logging.getLogger(__name__)

# How long in-progress work may take to finish after SIGTERM/SIGINT
SHUTDOWN_TIMEOUT_S = 30


async def sleep_or_shutdown(seconds: float, shutdown_event: asyncio.Event | None) -> bool:
    """Sleep up to `seconds`; return True as soon as shutdown is requested."""
    if shutdown_event is None:
        await asyncio.sleep(seconds)
        return False
    try:
        await asyncio.wait_for(shutdown_event.wait(), timeout=seconds)
    except TimeoutError:
        return False
    return True


async def stop_tasks(
    tasks: Iterable[asyncio.Task], timeout: float = SHUTDOWN_TIMEOUT_S
) -> list:
    """Wait for tasks to finish on their own, then cancel the ones still running.

    Worker loops check the shutdown event between items, so waiting lets the
    current STT/analysis/reanalysis finish instead of interrupting it; work
    cancelled after the timeout is requeued by each worker's CancelledError path.
    """
    tasks = list(tasks)
    if not tasks:
        return []
    _, pending = await asyncio.wait(tasks, timeout=timeout)
    for task in pending:
        logger.warning(f"[Shutdown] Cancelling {task.get_name()} after {timeout}s")
        task.cancel()
    return await asyncio.gather(*tasks, return_exceptions=True)
