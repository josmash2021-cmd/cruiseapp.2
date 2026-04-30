"""Bounded in-memory caches with TTL and size limits.

Prevents OOM crashes by enforcing maximum sizes and automatic eviction
of stale entries. Use these instead of raw Python dicts for any
cache that grows with user/driver/trip count.
"""

import time
import logging
from collections import OrderedDict
from typing import TypeVar, Generic, Optional

logger = logging.getLogger(__name__)

K = TypeVar("K")
V = TypeVar("V")


class TTLCache(Generic[K, V]):
    """In-memory cache with TTL (time-to-live) and max size.

    Entries older than ``ttl_seconds`` are considered stale.
    When ``max_size`` is exceeded, the oldest entries are evicted.
    """

    def __init__(self, ttl_seconds: float, max_size: int, name: str = "cache"):
        self._data: OrderedDict[K, tuple[V, float]] = OrderedDict()
        self._ttl = ttl_seconds
        self._max_size = max_size
        self._name = name

    def _evict_stale(self):
        """Remove entries older than TTL."""
        now = time.monotonic()
        stale = [k for k, (_, ts) in self._data.items() if now - ts > self._ttl]
        for k in stale:
            self._data.pop(k, None)
        if stale:
            logger.debug("[%s] Evicted %d stale entries", self._name, len(stale))

    def _evict_oldest(self, n: int):
        """Evict N oldest entries."""
        for _ in range(min(n, len(self._data))):
            self._data.popitem(last=False)

    def get(self, key: K, default: Optional[V] = None) -> Optional[V]:
        self._evict_stale()
        entry = self._data.get(key)
        if entry is None:
            return default
        value, ts = entry
        if time.monotonic() - ts > self._ttl:
            self._data.pop(key, None)
            return default
        # Move to end (most recently used)
        self._data.move_to_end(key)
        return value

    def __getitem__(self, key: K) -> V:
        result = self.get(key)
        if result is None and key not in self._data:
            raise KeyError(key)
        return result  # type: ignore[return-value]

    def __setitem__(self, key: K, value: V):
        now = time.monotonic()
        self._evict_stale()
        if key in self._data:
            self._data.move_to_end(key)
        self._data[key] = (value, now)
        if len(self._data) > self._max_size:
            # Evict oldest 10% to avoid thrashing
            evict_count = max(1, self._max_size // 10)
            self._evict_oldest(evict_count)
            logger.warning(
                "[%s] Size limit (%d) exceeded — evicted %d oldest entries",
                self._name, self._max_size, evict_count,
            )

    def __contains__(self, key: K) -> bool:
        return self.get(key) is not None

    def pop(self, key: K, default: Optional[V] = None) -> Optional[V]:
        entry = self._data.pop(key, None)
        if entry is None:
            return default
        value, ts = entry
        if time.monotonic() - ts > self._ttl:
            return default
        return value

    def __len__(self) -> int:
        self._evict_stale()
        return len(self._data)

    def keys(self):
        self._evict_stale()
        return self._data.keys()

    def values(self):
        self._evict_stale()
        return [v for v, _ in self._data.values()]

    def items(self):
        self._evict_stale()
        return [(k, v) for k, (v, _) in self._data.items()]

    def clear(self):
        self._data.clear()


class BoundedDict(Generic[K, V]):
    """Simple dict with a max size and LRU eviction.

    No TTL — entries persist until explicitly removed or evicted.
    """

    def __init__(self, max_size: int, name: str = "bounded_dict"):
        self._data: OrderedDict[K, V] = OrderedDict()
        self._max_size = max_size
        self._name = name

    def get(self, key: K, default: Optional[V] = None) -> Optional[V]:
        value = self._data.get(key)
        if value is not None:
            self._data.move_to_end(key)
        return value if value is not None else default

    def __getitem__(self, key: K) -> V:
        value = self._data[key]
        self._data.move_to_end(key)
        return value

    def __setitem__(self, key: K, value: V):
        if key in self._data:
            self._data.move_to_end(key)
        self._data[key] = value
        if len(self._data) > self._max_size:
            evict_count = max(1, self._max_size // 10)
            for _ in range(evict_count):
                self._data.popitem(last=False)
            logger.warning(
                "[%s] Size limit (%d) exceeded — evicted %d oldest entries",
                self._name, self._max_size, evict_count,
            )

    def __contains__(self, key: K) -> bool:
        return key in self._data

    def pop(self, key: K, default: Optional[V] = None) -> Optional[V]:
        return self._data.pop(key, default)

    def __len__(self) -> int:
        return len(self._data)

    def keys(self):
        return self._data.keys()

    def values(self):
        return self._data.values()

    def items(self):
        return self._data.items()

    def clear(self):
        self._data.clear()
