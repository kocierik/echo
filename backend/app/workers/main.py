"""The worker process: every background loop, and a graceful shutdown.

- STT (stt.py), analysis (analysis.py) and reanalysis (reanalysis.py) of what the wearable
  recorded and the user corrected;
- voice requests (voice_requests.py) and photos (photos.py);
- retention, summaries, digests, the expiry of saved things and of places visited
  (90 days) on their schedules;
- deferred speech (deferred.py), queued again when the plan's budget allows it;
- tracked runs left `running` by a stopped process, closed as `interrupted` every minute
  (core/runs.py).
- pending or stale `processing` speech is restored to the STT queue (stt.py).

Items that fail after their retries go to the dead letter queue (dead_letter.py). On
SIGTERM/SIGINT the loops finish the item in hand (up to SHUTDOWN_TIMEOUT_S), then stop.
"""

import asyncio
import logging
import signal

import redis.asyncio as redis

from app.actions.composio_provider import preload_sdk
from app.core.config import settings
from app.core.logging import setup_logging
from app.core.runs import close_interrupted, startup_close_interrupted
from app.workers.analysis import process_analysis
from app.workers.deferred import run_deferred_loop
from app.workers.digest import run_digest_loop
from app.workers.documents import run_documents_loop
from app.workers.lifecycle import SHUTDOWN_TIMEOUT_S, sleep_or_shutdown, stop_tasks
from app.workers.photos import process_photos
from app.workers.places import run_places_cleanup_loop
from app.workers.reanalysis import process_reanalysis
from app.workers.retention import run_retention_loop
from app.workers.routines import run_routines_loop
from app.workers.saved import run_saved_expiry_loop
from app.workers.stt import process_stt, run_stt_recovery_loop
from app.workers.summaries import run_summary_loop
from app.workers.voice_requests import process_voice_queue

setup_logging()
logger = logging.getLogger(__name__)

shutdown_event = asyncio.Event()

# Runs a stopped process left `running` are closed this often (core/runs.py)
INTERRUPTED_SWEEP_INTERVAL_S = 60


async def run_interrupted_sweep_loop(event: asyncio.Event | None = None) -> None:
    """At start and every minute until shutdown: close the runs left `running` past the
    threshold as `interrupted` (an api or worker restart cut them off)."""
    await startup_close_interrupted()
    while not await sleep_or_shutdown(INTERRUPTED_SWEEP_INTERVAL_S, event):
        await close_interrupted(settings.run_interrupted_after_seconds)


def _handle_signal(sig: signal.Signals):
    """Signal handler: set shutdown event."""
    logger.info(f"[Shutdown] Received {sig.name}, initiating graceful shutdown...")
    shutdown_event.set()


async def main():
    """Main entry point for the worker process."""
    logger.info("Starting Echo background worker...")

    # Register signal handlers
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _handle_signal, sig)

    redis_client = redis.from_url(settings.redis_url)

    # Create worker tasks
    tasks = [
        asyncio.create_task(process_stt(redis_client, shutdown_event), name="stt_worker"),
        asyncio.create_task(
            run_stt_recovery_loop(redis_client, shutdown_event), name="stt_recovery_worker"
        ),
        asyncio.create_task(
            process_analysis(redis_client, shutdown_event), name="analysis_worker"
        ),
        asyncio.create_task(
            process_reanalysis(redis_client, shutdown_event), name="reanalysis_worker"
        ),
        asyncio.create_task(run_retention_loop(shutdown_event), name="retention_worker"),
        asyncio.create_task(run_summary_loop(shutdown_event), name="summary_worker"),
        asyncio.create_task(run_digest_loop(shutdown_event), name="digest_worker"),
        asyncio.create_task(run_documents_loop(shutdown_event), name="documents_worker"),
        asyncio.create_task(run_saved_expiry_loop(shutdown_event), name="saved_worker"),
        asyncio.create_task(run_places_cleanup_loop(shutdown_event), name="places_worker"),
        asyncio.create_task(
            run_routines_loop(redis_client, shutdown_event), name="routines_worker"
        ),
        asyncio.create_task(
            run_deferred_loop(redis_client, shutdown_event), name="deferred_worker"
        ),
        asyncio.create_task(
            process_voice_queue(redis_client, shutdown_event), name="voice_worker"
        ),
        asyncio.create_task(process_photos(redis_client, shutdown_event), name="photo_worker"),
        asyncio.create_task(
            run_interrupted_sweep_loop(shutdown_event), name="interrupted_runs_worker"
        ),
        asyncio.create_task(preload_sdk(), name="composio_preload"),
    ]

    # Wait for shutdown signal
    await shutdown_event.wait()
    logger.info(f"[Shutdown] Waiting up to {SHUTDOWN_TIMEOUT_S}s for tasks to finish...")

    # Let in-progress items finish (loops exit between items); cancel after the timeout
    results = await stop_tasks(tasks, timeout=SHUTDOWN_TIMEOUT_S)

    for task, result in zip(tasks, results):
        if isinstance(result, Exception) and not isinstance(result, asyncio.CancelledError):
            logger.error(f"[Shutdown] Task {task.get_name()} ended with error: {result}")

    await redis_client.aclose()
    logger.info("[Shutdown] Worker stopped cleanly.")


if __name__ == "__main__":
    asyncio.run(main())
