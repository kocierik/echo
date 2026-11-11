"""Unit tests: graceful worker shutdown."""

import asyncio

import pytest

from app.workers import lifecycle, retention, summaries
from app.workers.lifecycle import sleep_or_shutdown, stop_tasks, wait_for_shutdown_or_failure


@pytest.mark.asyncio
async def test_sleep_returns_early_when_shutdown_is_requested():
    shutdown = asyncio.Event()
    asyncio.get_running_loop().call_later(0.05, shutdown.set)

    stopped = await asyncio.wait_for(sleep_or_shutdown(30, shutdown), timeout=1)

    assert stopped is True


@pytest.mark.asyncio
async def test_sleep_runs_the_full_interval_without_shutdown():
    assert await sleep_or_shutdown(0.01, asyncio.Event()) is False


@pytest.mark.asyncio
async def test_stop_tasks_lets_in_progress_work_finish():
    finished = []

    async def worker():
        await asyncio.sleep(0.05)  # finishing the current item
        finished.append(True)
        return "done"

    task = asyncio.create_task(worker())

    results = await stop_tasks([task], timeout=1)

    assert finished == [True]
    assert results == ["done"]
    assert not task.cancelled()


@pytest.mark.asyncio
async def test_stop_tasks_cancels_work_still_running_after_the_timeout():
    async def stuck():
        await asyncio.sleep(30)

    task = asyncio.create_task(stuck())

    results = await stop_tasks([task], timeout=0.05)

    assert task.cancelled()
    assert isinstance(results[0], asyncio.CancelledError)


@pytest.mark.asyncio
async def test_retention_loop_exits_on_shutdown(monkeypatch):
    runs = []

    async def fake_cleanup():
        runs.append(1)
        return 0

    monkeypatch.setattr(retention, "cleanup_old_audio", fake_cleanup)
    shutdown = asyncio.Event()
    loop_task = asyncio.create_task(retention.run_retention_loop(shutdown))
    await asyncio.sleep(0.05)

    shutdown.set()
    await asyncio.wait_for(loop_task, timeout=1)

    assert runs == [1]


@pytest.mark.asyncio
async def test_summary_loop_exits_on_shutdown(monkeypatch):
    async def fake_summarize():
        return 0

    monkeypatch.setattr(summaries, "summarize_closed_conversations", fake_summarize)
    shutdown = asyncio.Event()
    loop_task = asyncio.create_task(summaries.run_summary_loop(shutdown))
    await asyncio.sleep(0.05)

    shutdown.set()
    await asyncio.wait_for(loop_task, timeout=1)


def test_shutdown_timeout_is_thirty_seconds():
    assert lifecycle.SHUTDOWN_TIMEOUT_S == 30


async def test_a_loop_that_dies_is_reported_and_a_one_shot_that_ends_is_not():
    """Redis restarted under the loops' blocking pops: three of them died and the worker
    stayed up without them."""
    shutdown = asyncio.Event()

    async def loop():
        await asyncio.sleep(60)

    async def one_shot():
        return None

    async def dies():
        await asyncio.sleep(0.01)
        raise ConnectionError("Redis went away")

    alive = asyncio.create_task(loop())
    broken = asyncio.create_task(dies(), name="stt_worker")
    tasks = [alive, asyncio.create_task(one_shot()), broken]

    failed = await asyncio.wait_for(wait_for_shutdown_or_failure(tasks, shutdown), timeout=2)

    assert failed is broken and isinstance(failed.exception(), ConnectionError)
    alive.cancel()


async def test_a_shutdown_is_not_a_failure():
    shutdown = asyncio.Event()

    async def loop():
        await shutdown.wait()

    tasks = [asyncio.create_task(loop())]
    waiting = asyncio.create_task(wait_for_shutdown_or_failure(tasks, shutdown))
    await asyncio.sleep(0.01)
    shutdown.set()

    assert await asyncio.wait_for(waiting, timeout=2) is None
