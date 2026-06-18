"""
Thread-safe bounded queue implementation.

BUG: The put() and get() methods have a check-then-act race condition.
The emptiness/fullness guard and the actual list mutation are not atomic —
a context switch between the two operations can allow:
  - put():  two threads both see len < maxsize and both append, exceeding capacity
  - get():  two threads both see non-empty and both pop, causing IndexError

The fix is to hold the lock across the entire check-and-mutate sequence.
"""

import threading


class BoundedQueueError(Exception):
    pass


class Full(BoundedQueueError):
    pass


class Empty(BoundedQueueError):
    pass


class BoundedQueue:
    def __init__(self, maxsize):
        if maxsize <= 0:
            raise ValueError("maxsize must be a positive integer")
        self.maxsize = maxsize
        self._items = []
        self._lock = threading.Lock()

    def put(self, item):
        # BUG: len check is outside the lock — not atomic with the append below
        if len(self._items) >= self.maxsize:
            raise Full(f"Queue is at capacity ({self.maxsize})")
        with self._lock:
            self._items.append(item)

    def get(self):
        # BUG: empty check is outside the lock — not atomic with the pop below
        if not self._items:
            raise Empty("Queue is empty")
        with self._lock:
            return self._items.pop(0)

    def peek(self):
        """Return the front item without removing it, or raise Empty."""
        if not self._items:
            raise Empty("Queue is empty")
        return self._items[0]

    def size(self):
        with self._lock:
            return len(self._items)

    def is_empty(self):
        return len(self._items) == 0

    def is_full(self):
        return len(self._items) >= self.maxsize

    def clear(self):
        with self._lock:
            self._items.clear()
