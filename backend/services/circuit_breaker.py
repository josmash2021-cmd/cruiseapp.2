"""Circuit breaker pattern for external service calls.

Protects integrations (Stripe, Checkr, Twilio, Google Maps) from
cascading failures by opening the circuit after repeated errors.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from dataclasses import dataclass, field
from enum import Enum
from functools import wraps
from typing import Any, Callable, Dict, Optional

_log = logging.getLogger(__name__)


class State(Enum):
    CLOSED = "closed"      # normal operation
    OPEN = "open"          # failing fast
    HALF_OPEN = "half_open"  # testing recovery


@dataclass
class _ServiceStats:
    failures: int = 0
    successes: int = 0
    last_failure_time: float = 0.0
    state: State = State.CLOSED
    consecutive_successes: int = 0


# ── Tunable defaults ──
DEFAULT_FAILURE_THRESHOLD = int(os.getenv("CB_FAILURE_THRESHOLD", "5"))
DEFAULT_RECOVERY_TIMEOUT = float(os.getenv("CB_RECOVERY_TIMEOUT", "30"))
DEFAULT_HALF_OPEN_MAX_CALLS = int(os.getenv("CB_HALF_OPEN_MAX", "3"))

# In-memory registry per process
_registry: Dict[str, _ServiceStats] = {}
_lock = asyncio.Lock()


class CircuitBreakerError(Exception):
    """Raised when the circuit is OPEN and a call is rejected."""
    pass


def _now() -> float:
    return time.monotonic()


async def _get_stats(service_name: str) -> _ServiceStats:
    if service_name not in _registry:
        _registry[service_name] = _ServiceStats()
    return _registry[service_name]


async def record_success(service_name: str) -> None:
    """Manually record a successful call (for non-decorator usage)."""
    async with _lock:
        stats = await _get_stats(service_name)
        stats.successes += 1
        if stats.state == State.HALF_OPEN:
            stats.consecutive_successes += 1
            if stats.consecutive_successes >= DEFAULT_HALF_OPEN_MAX_CALLS:
                stats.state = State.CLOSED
                stats.failures = 0
                stats.consecutive_successes = 0
                _log.info("Circuit breaker CLOSED for %s", service_name)
        elif stats.state == State.CLOSED:
            stats.failures = 0


async def record_failure(service_name: str) -> None:
    """Manually record a failed call (for non-decorator usage)."""
    async with _lock:
        stats = await _get_stats(service_name)
        stats.failures += 1
        stats.last_failure_time = _now()
        stats.consecutive_successes = 0
        if stats.state == State.HALF_OPEN:
            stats.state = State.OPEN
            _log.warning("Circuit breaker OPEN for %s (half-open failure)", service_name)
        elif stats.state == State.CLOSED and stats.failures >= DEFAULT_FAILURE_THRESHOLD:
            stats.state = State.OPEN
            _log.warning(
                "Circuit breaker OPEN for %s after %s failures",
                service_name,
                stats.failures,
            )


async def get_state(service_name: str) -> State:
    """Return current circuit state, handling timeout transitions."""
    async with _lock:
        stats = await _get_stats(service_name)
        if stats.state == State.OPEN:
            elapsed = _now() - stats.last_failure_time
            if elapsed >= DEFAULT_RECOVERY_TIMEOUT:
                stats.state = State.HALF_OPEN
                stats.consecutive_successes = 0
                _log.info("Circuit breaker HALF_OPEN for %s", service_name)
        return stats.state


def circuit_breaker(
    service_name: str,
    *,
    failure_threshold: Optional[int] = None,
    recovery_timeout: Optional[float] = None,
    half_open_max_calls: Optional[int] = None,
    fallback: Optional[Callable] = None,
):
    """Decorator that wraps an async function with a circuit breaker.

    Usage:
        @circuit_breaker("stripe")
        async def charge_customer(...):
            ...

    Parameters:
        service_name: logical name used to track failures.
        failure_threshold: failures before opening (default 5).
        recovery_timeout: seconds before half-open (default 30).
        half_open_max_calls: successes needed to close (default 3).
        fallback: optional async callable(args, kwargs) invoked when OPEN.
    """
    ft = failure_threshold or DEFAULT_FAILURE_THRESHOLD
    rt = recovery_timeout or DEFAULT_RECOVERY_TIMEOUT
    hm = half_open_max_calls or DEFAULT_HALF_OPEN_MAX_CALLS

    def decorator(func: Callable) -> Callable:
        @wraps(func)
        async def wrapper(*args, **kwargs):
            state = await get_state(service_name)
            if state == State.OPEN:
                if fallback is not None:
                    return await fallback(*args, **kwargs)
                raise CircuitBreakerError(
                    f"Circuit breaker OPEN for {service_name}"
                )

            try:
                result = await func(*args, **kwargs)
            except Exception as exc:
                async with _lock:
                    stats = await _get_stats(service_name)
                    stats.failures += 1
                    stats.last_failure_time = _now()
                    stats.consecutive_successes = 0
                    if stats.state == State.HALF_OPEN:
                        stats.state = State.OPEN
                        _log.warning(
                            "Circuit breaker OPEN for %s (half-open failure: %s)",
                            service_name,
                            exc,
                        )
                    elif stats.state == State.CLOSED and stats.failures >= ft:
                        stats.state = State.OPEN
                        _log.warning(
                            "Circuit breaker OPEN for %s after %s failures (%s)",
                            service_name,
                            stats.failures,
                            exc,
                        )
                raise

            # Success path
            async with _lock:
                stats = await _get_stats(service_name)
                stats.successes += 1
                if stats.state == State.HALF_OPEN:
                    stats.consecutive_successes += 1
                    if stats.consecutive_successes >= hm:
                        stats.state = State.CLOSED
                        stats.failures = 0
                        stats.consecutive_successes = 0
                        _log.info("Circuit breaker CLOSED for %s", service_name)
                elif stats.state == State.CLOSED:
                    stats.failures = max(0, stats.failures - 1)

            return result

        return wrapper
    return decorator


async def reset(service_name: str) -> None:
    """Reset a service's circuit to CLOSED."""
    async with _lock:
        _registry[service_name] = _ServiceStats()
        _log.info("Circuit breaker reset for %s", service_name)


async def all_stats() -> Dict[str, Dict[str, Any]]:
    """Return metrics for every tracked service."""
    async with _lock:
        return {
            name: {
                "state": s.state.value,
                "failures": s.failures,
                "successes": s.successes,
                "last_failure_age_sec": round(_now() - s.last_failure_time, 1)
                if s.last_failure_time
                else None,
                "consecutive_successes": s.consecutive_successes,
            }
            for name, s in _registry.items()
        }


