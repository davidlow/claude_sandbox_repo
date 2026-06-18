# CLAUDE.md — buggy-python (E2E test workspace)

## Project Purpose
A bounded thread-safe queue implementation used as a self-contained E2E test
fixture for the `claude-refactor` pipeline.  The implementation in `queue.py`
has a deliberate thread-safety bug (check-then-act race condition in `put()`
and `get()`).  Claude's job is to diagnose the bug and apply the correct fix.

## Commands
```bash
# Install dependencies
pip install -r requirements.txt

# Run tests (some will fail or flake with the bug present)
pytest test_queue.py -v

# Run the thread-safety tests repeatedly to expose flakiness
for i in $(seq 1 10); do pytest test_queue.py::test_concurrent_puts_never_exceed_maxsize -v; done
```

## The Bug
`put()` checks `len(self._items) >= self.maxsize` *outside* the lock, then
acquires the lock to append.  A context switch in the gap lets two threads
both pass the check and both append, silently exceeding `maxsize`.

`get()` has the same structure: the emptiness check and `pop()` are not atomic.

## Expected Fix
Hold `self._lock` across the entire check-and-mutate sequence in both `put()`
and `get()`.  The state predicates (`is_empty`, `is_full`, `size`) should also
use the lock for consistency.

## What the Refactor Pipeline Should Do
1. **Phase 1 (haiku)** — diagnose the race condition, propose three options
   (minimal patch, structural fix, rewrite)
2. **Phase 2 (sonnet)** — select "structural fix" and write the implementation plan
3. **Phase 3** — apply the fix; run `pytest test_queue.py -v`; all tests pass
