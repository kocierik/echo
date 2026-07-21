"""Retry utility with exponential backoff and timeout for async calls."""

import asyncio
import logging
from typing import TypeVar

logger = logging.getLogger(__name__)

T = TypeVar("T")

# Defaults
DEFAULT_MAX_ATTEMPTS = 3
DEFAULT_BASE_DELAY = 1.0  # seconds
DEFAULT_MULTIPLIER = 4.0
DEFAULT_TIMEOUT = 60.0  # seconds per attempt


class RetryExhaustedError(Exception):
    """Raised when all retry attempts have been exhausted."""

    def __init__(self, last_error: Exception, attempts: int):
        self.last_error = last_error
        self.attempts = attempts
        super().__init__(f"Failed after {attempts} attempts: {last_error}")


async def retry_with_backoff(
    coro_func,
    *args,
    max_attempts: int = DEFAULT_MAX_ATTEMPTS,
    base_delay: float = DEFAULT_BASE_DELAY,
    multiplier: float = DEFAULT_MULTIPLIER,
    timeout: float = DEFAULT_TIMEOUT,
    operation_name: str = "operation",
    **kwargs,
):
    """Execute an async function with retry and exponential backoff.

    Args:
        coro_func: Async function to call.
        *args: Positional arguments for the function.
        max_attempts: Maximum number of attempts (default 3).
        base_delay: Initial delay in seconds (default 1).
        multiplier: Backoff multiplier (default 4, giving 1s, 4s, 16s).
        timeout: Timeout per attempt in seconds (default 60).
        operation_name: Name for logging purposes.
        **kwargs: Keyword arguments for the function.

    Returns:
        The result of the successful call.

    Raises:
        RetryExhaustedError: If all attempts fail.
    """
    last_error: Exception | None = None

    for attempt in range(1, max_attempts + 1):
        try:
            async with asyncio.timeout(timeout):
                result = await coro_func(*args, **kwargs)
            return result
        except asyncio.CancelledError:
            # Don't retry on cancellation (shutdown scenario)
            raise
        except Exception as e:
            last_error = e
            if attempt < max_attempts:
                delay = base_delay * (multiplier ** (attempt - 1))
                logger.warning(
                    f"[Retry] {operation_name} failed (attempt {attempt}/{max_attempts}): "
                    f"{type(e).__name__}: {e}. Retrying in {delay:.1f}s..."
                )
                await asyncio.sleep(delay)
            else:
                logger.error(
                    f"[Retry] {operation_name} failed after {max_attempts} attempts: "
                    f"{type(e).__name__}: {e}"
                )

    raise RetryExhaustedError(last_error, max_attempts)
