"""Lightweight Prometheus-compatible metrics for Echo.

Provides basic counters and histograms without requiring the full
prometheus_client library. Outputs in text exposition format.
"""

import time
from collections import defaultdict
from threading import Lock


class Metrics:
    """Thread-safe metrics collector."""

    def __init__(self):
        self._counters: dict[str, int] = defaultdict(int)
        self._histograms: dict[str, list[float]] = defaultdict(list)
        self._lock = Lock()
        self._start_time = time.time()

    def inc(self, name: str, value: int = 1) -> None:
        """Increment a counter."""
        with self._lock:
            self._counters[name] += value

    def observe(self, name: str, value: float) -> None:
        """Record a histogram observation (last 1000 values kept)."""
        with self._lock:
            hist = self._histograms[name]
            hist.append(value)
            if len(hist) > 1000:
                self._histograms[name] = hist[-1000:]

    def export(self) -> str:
        """Export metrics in Prometheus text exposition format."""
        lines = []
        lines.append(f"# Echo metrics - uptime {time.time() - self._start_time:.0f}s")

        with self._lock:
            for name, value in sorted(self._counters.items()):
                lines.append(f"# TYPE {name} counter")
                lines.append(f"{name} {value}")

            for name, values in sorted(self._histograms.items()):
                if values:
                    avg = sum(values) / len(values)
                    lines.append(f"# TYPE {name} summary")
                    lines.append(f"{name}_count {len(values)}")
                    lines.append(f"{name}_avg {avg:.4f}")
                    lines.append(f"{name}_max {max(values):.4f}")

        return "\n".join(lines) + "\n"


# Global metrics instance
metrics = Metrics()
