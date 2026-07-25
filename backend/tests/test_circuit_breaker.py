"""Unit tests for the circuit breaker."""

from app.core.circuit_breaker import CircuitBreaker, CircuitOpenError, CircuitState


class TestCircuitBreaker:
    def test_starts_closed(self):
        cb = CircuitBreaker("test", failure_threshold=3, recovery_timeout=10)
        assert cb.state == CircuitState.CLOSED
        assert cb.allow_request() is True

    def test_opens_after_threshold_failures(self):
        cb = CircuitBreaker("test", failure_threshold=3, recovery_timeout=10)

        cb.record_failure()
        assert cb.state == CircuitState.CLOSED
        cb.record_failure()
        assert cb.state == CircuitState.CLOSED
        cb.record_failure()
        assert cb.state == CircuitState.OPEN
        assert cb.allow_request() is False

    def test_success_resets_failure_count(self):
        cb = CircuitBreaker("test", failure_threshold=3, recovery_timeout=10)

        cb.record_failure()
        cb.record_failure()
        cb.record_success()  # reset
        assert cb.state == CircuitState.CLOSED

        # Need 3 more failures now
        cb.record_failure()
        cb.record_failure()
        assert cb.state == CircuitState.CLOSED

    def test_transitions_to_half_open_after_timeout(self):
        cb = CircuitBreaker("test", failure_threshold=2, recovery_timeout=0)

        cb.record_failure()
        assert cb._state == CircuitState.CLOSED
        cb.record_failure()
        assert cb._state == CircuitState.OPEN

        # With recovery_timeout=0, state getter should transition to HALF_OPEN
        assert cb.state == CircuitState.HALF_OPEN
        assert cb.allow_request() is True

    def test_half_open_success_closes_circuit(self):
        cb = CircuitBreaker("test", failure_threshold=2, recovery_timeout=0)

        cb.record_failure()
        cb.record_failure()
        # Force half-open via state getter
        _ = cb.state

        cb.record_success()
        assert cb.state == CircuitState.CLOSED

    def test_half_open_failure_reopens(self):
        cb = CircuitBreaker("test", failure_threshold=2, recovery_timeout=0)

        cb.record_failure()
        cb.record_failure()
        # Force half-open via state getter
        assert cb.state == CircuitState.HALF_OPEN

        cb.record_failure()
        # After failure in HALF_OPEN, internal state is OPEN
        assert cb._state == CircuitState.OPEN
        # But with timeout=0, getter will transition again to HALF_OPEN
        # So test the internal state directly
        assert cb._state == CircuitState.OPEN

    def test_manual_reset(self):
        cb = CircuitBreaker("test", failure_threshold=2, recovery_timeout=60)

        cb.record_failure()
        cb.record_failure()
        assert cb.state == CircuitState.OPEN

        cb.reset()
        assert cb.state == CircuitState.CLOSED
        assert cb.allow_request() is True

    def test_status_dict(self):
        cb = CircuitBreaker("openai", failure_threshold=5, recovery_timeout=60)
        status = cb.status()

        assert status["name"] == "openai"
        assert status["state"] == "closed"
        assert status["failure_count"] == 0
        assert status["failure_threshold"] == 5
        assert status["recovery_timeout_s"] == 60

    def test_circuit_open_error(self):
        err = CircuitOpenError("openai")
        assert "openai" in str(err)
        assert err.service_name == "openai"
