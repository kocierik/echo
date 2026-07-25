"""Circuit breaker for external service calls (OpenAI, etc.).

Prevents cascading failures when an external service is down by
temporarily stopping requests after repeated failures.

States:
- CLOSED: normal operation, requests pass through
- OPEN: service is down, requests fail immediately without calling the service
- HALF_OPEN: after recovery timeout, allow one request through to test

Usage:
    breaker = CircuitBreaker("openai", failure_threshold=5, recovery_timeout=60)

    async def call_openai():
        if not breaker.allow_request():
            raise CircuitOpenError("openai")
        try:
            result = await openai_client.chat(...)
            breaker.record_success()
            return result
        except Exception as e:
            breaker.record_failure()
            raise
"""

import logging
import time
from enum import Enum

from app.core.config import settings

logger = logging.getLogger(__name__)


class CircuitState(Enum):
    CLOSED = "closed"
    OPEN = "open"
    HALF_OPEN = "half_open"


class CircuitOpenError(Exception):
    """Raised when circuit breaker is open and request is rejected."""

    def __init__(self, service_name: str):
        self.service_name = service_name
        super().__init__(
            f"Circuit breaker OPEN for '{service_name}'. "
            f"Service is temporarily unavailable."
        )


class CircuitBreaker:
    """Thread-safe circuit breaker for async external service calls."""

    def __init__(
        self,
        name: str,
        failure_threshold: int = 5,
        recovery_timeout: int = 60,
    ):
        self.name = name
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout

        self._state = CircuitState.CLOSED
        self._failure_count = 0
        self._last_failure_time: float = 0
        self._success_count = 0

    @property
    def state(self) -> CircuitState:
        """Current circuit state (may transition from OPEN → HALF_OPEN)."""
        if self._state == CircuitState.OPEN:
            elapsed = time.time() - self._last_failure_time
            if elapsed >= self.recovery_timeout:
                self._state = CircuitState.HALF_OPEN
                logger.info(
                    f"[CircuitBreaker:{self.name}] OPEN → HALF_OPEN "
                    f"(recovery timeout {self.recovery_timeout}s elapsed)"
                )
        return self._state

    def allow_request(self) -> bool:
        """Check if a request should be allowed through."""
        state = self.state
        if state == CircuitState.CLOSED:
            return True
        if state == CircuitState.HALF_OPEN:
            return True  # Allow one test request
        return False  # OPEN — reject

    def record_success(self) -> None:
        """Record a successful call. Resets failure count."""
        if self._state == CircuitState.HALF_OPEN:
            logger.info(f"[CircuitBreaker:{self.name}] HALF_OPEN → CLOSED (success)")
            self._state = CircuitState.CLOSED

        self._failure_count = 0
        self._success_count += 1

    def record_failure(self) -> None:
        """Record a failed call. May trip the breaker."""
        self._failure_count += 1
        self._last_failure_time = time.time()

        if self._state == CircuitState.HALF_OPEN:
            # Test request failed — back to OPEN
            self._state = CircuitState.OPEN
            logger.warning(
                f"[CircuitBreaker:{self.name}] HALF_OPEN → OPEN "
                f"(test request failed)"
            )
        elif self._failure_count >= self.failure_threshold:
            self._state = CircuitState.OPEN
            logger.warning(
                f"[CircuitBreaker:{self.name}] CLOSED → OPEN "
                f"({self._failure_count} consecutive failures)"
            )

    def reset(self) -> None:
        """Manually reset the circuit breaker."""
        self._state = CircuitState.CLOSED
        self._failure_count = 0
        logger.info(f"[CircuitBreaker:{self.name}] Manually reset to CLOSED")

    def status(self) -> dict:
        """Return current status for health checks."""
        return {
            "name": self.name,
            "state": self.state.value,
            "failure_count": self._failure_count,
            "failure_threshold": self.failure_threshold,
            "recovery_timeout_s": self.recovery_timeout,
        }


# Global circuit breakers for external services
openai_breaker = CircuitBreaker(
    "openai",
    failure_threshold=settings.circuit_breaker_failure_threshold,
    recovery_timeout=settings.circuit_breaker_recovery_timeout,
)
