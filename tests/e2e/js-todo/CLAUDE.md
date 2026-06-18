# CLAUDE.md — js-todo (E2E test workspace)

## Project Purpose
An in-memory Node.js todo list used as a self-contained E2E test fixture for
the `claude-architect` pipeline.  The module (`src/todo.js`) currently has no
persistence — all state is lost on process exit.

Claude's job is to **design and implement a persistence layer** so todos survive
restarts, without changing the existing public API (`add`, `get`, `complete`,
`delete`, `list`, `count`).

## Commands
```bash
# Install dependencies
npm install

# Run tests
npm test

# Run a single test file
npx jest tests/todo.test.js --verbose
```

## Constraints
- The public API in `src/todo.js` must not change (callers must keep working).
- Persistence should be file-based (JSON or SQLite) — no external services.
- New tests must cover persistence (data survives a new `TodoList` instance).
- Existing tests in `tests/` must continue passing after the change.

## What the Architect Pipeline Should Do
1. **Phase 1 (haiku)** — propose three distinct persistence approaches
   (flat JSON file, SQLite via `better-sqlite3`, event-sourced append log)
2. **Phase 2 (sonnet)** — select one, write the implementation spec
3. **Phase 3** — implement it; `npm test` must pass
