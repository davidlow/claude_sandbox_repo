"""
Tests for BoundedQueue.

The single-threaded tests pass reliably.  The thread-safety test
(test_concurrent_puts_never_exceed_maxsize) is a probabilistic race detector:
it fails intermittently with the buggy implementation and consistently with
a correct one.  Run with pytest-repeat or a loop to increase confidence.
"""

import threading
import pytest
from queue import BoundedQueue, Full, Empty


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

def test_construct_valid():
    q = BoundedQueue(5)
    assert q.size() == 0


def test_construct_zero_maxsize_raises():
    with pytest.raises(ValueError, match="positive"):
        BoundedQueue(0)


def test_construct_negative_maxsize_raises():
    with pytest.raises(ValueError, match="positive"):
        BoundedQueue(-1)


# ---------------------------------------------------------------------------
# Basic put / get
# ---------------------------------------------------------------------------

def test_put_then_get():
    q = BoundedQueue(3)
    q.put("hello")
    assert q.get() == "hello"


def test_fifo_ordering():
    q = BoundedQueue(10)
    for i in range(5):
        q.put(i)
    for i in range(5):
        assert q.get() == i


def test_put_to_capacity():
    q = BoundedQueue(2)
    q.put("a")
    q.put("b")
    assert q.size() == 2


def test_put_beyond_capacity_raises_full():
    q = BoundedQueue(1)
    q.put("only")
    with pytest.raises(Full):
        q.put("overflow")


def test_get_from_empty_raises_empty():
    q = BoundedQueue(3)
    with pytest.raises(Empty):
        q.get()


def test_put_get_put_get_cycles():
    q = BoundedQueue(1)
    for i in range(10):
        q.put(i)
        assert q.get() == i


# ---------------------------------------------------------------------------
# Peek
# ---------------------------------------------------------------------------

def test_peek_returns_front_item():
    q = BoundedQueue(5)
    q.put(42)
    assert q.peek() == 42
    assert q.size() == 1  # peek must not remove


def test_peek_on_empty_raises():
    q = BoundedQueue(3)
    with pytest.raises(Empty):
        q.peek()


# ---------------------------------------------------------------------------
# State predicates
# ---------------------------------------------------------------------------

def test_is_empty_true_when_new():
    assert BoundedQueue(5).is_empty()


def test_is_empty_false_after_put():
    q = BoundedQueue(5)
    q.put(1)
    assert not q.is_empty()


def test_is_full_false_when_new():
    assert not BoundedQueue(5).is_full()


def test_is_full_true_at_capacity():
    q = BoundedQueue(2)
    q.put("x")
    q.put("y")
    assert q.is_full()


# ---------------------------------------------------------------------------
# Clear
# ---------------------------------------------------------------------------

def test_clear_empties_queue():
    q = BoundedQueue(5)
    for i in range(3):
        q.put(i)
    q.clear()
    assert q.is_empty()
    assert q.size() == 0


# ---------------------------------------------------------------------------
# Thread safety (probabilistic race detector)
# ---------------------------------------------------------------------------

def test_concurrent_puts_never_exceed_maxsize():
    """
    Five threads each try to put 200 items into a queue of maxsize=10.
    With correct locking, size never exceeds 10.
    With the buggy implementation, size can exceed 10 (race condition).
    """
    MAXSIZE = 10
    THREADS = 5
    PUTS_PER_THREAD = 200

    q = BoundedQueue(MAXSIZE)
    overflow_detected = threading.Event()

    def producer():
        for _ in range(PUTS_PER_THREAD):
            try:
                q.put(1)
            except Full:
                pass
            if q.size() > MAXSIZE:
                overflow_detected.set()

    threads = [threading.Thread(target=producer) for _ in range(THREADS)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert not overflow_detected.is_set(), (
        f"Queue exceeded maxsize={MAXSIZE}: detected size > maxsize during concurrent puts"
    )
    assert q.size() <= MAXSIZE


def test_concurrent_gets_no_index_error():
    """
    Pre-fill the queue, then drain it with multiple threads.
    With the buggy get(), concurrent pops on a nearly-empty queue cause IndexError.
    """
    MAXSIZE = 20
    q = BoundedQueue(MAXSIZE)
    for i in range(MAXSIZE):
        q.put(i)

    errors = []

    def consumer():
        for _ in range(MAXSIZE):
            try:
                q.get()
            except Empty:
                pass
            except Exception as e:
                errors.append(e)

    threads = [threading.Thread(target=consumer) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert not errors, f"Unexpected exceptions during concurrent gets: {errors}"
