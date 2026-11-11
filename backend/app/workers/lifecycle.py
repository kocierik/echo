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


async def wait_for_shutdown_or_failure(
    tasks: list[asyncio.Task], shutdown_event: asyncio.Event
) -> asyncio.Task | None:
    """Wait for the shutdown, or for a loop that dies: the task that failed, else None.

    A loop that ends with an error (Redis restarting under its blocking pop) used to leave
    the process up without it, transcribing nothing and saying nothing. A task that ends
    without one (a one-shot, like the SDK preload) is not a failure.
    """
    shutdown = asyncio.create_task(shutdown_event.wait())
    watched = set(tasks)
    try:
        while watched:
            finished, _ = await asyncio.wait(
                {shutdown, *watched}, return_when=asyncio.FIRST_COMPLETED
            )
            if shutdown in finished:
                return None
            for task in finished:
                watched.discard(task)
                if not task.cancelled() and task.exception() is not None:
                    return task
        await shutdown
        return None
    finally:
        shutdown.cancel()
