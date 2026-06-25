# Brainstorm: Enhanced Git-Blame Command with Decision Log Context

**Generated:** 2026-06-25

## Option A: Git-Native Wrapper with Timestamp Matching

**Summary:** Thin wrapper around `git blame` that parses commit timestamps and performs a straightforward filesystem scan of decision logs to find related entries by timestamp proximity.

**Key design decisions:**
- Wraps existing `git blame` command (shell out to native git) rather than reimplementing blame logic
- Parses `git blame` output line-by-line to extract commit hash and date
- Scans decision log filenames (YYYYMMDD_HHMM format) in a chronological window around commit timestamp
- Lightweight regex matching on filenames; no full-text indexing
- Returns raw git blame output plus annotated decision log excerpts appended below
- Does not cache or persist log metadata; rescans on each query

**Trade-offs:**
- Extensibility: Very limited; each query rescans filesystem; no preprocessing or caching
- Complexity: Minimal; straightforward bash script with `git blame` pipe and simple date arithmetic
- Blast radius / risk: Zero impact on existing tools; pure wrapper with no persistence

**Risks or prerequisites:** 
- Performance degrades with large numbers of decision logs (hundreds+)
- Simple timestamp matching may miss related logs if there's a time gap between commit and log creation
- No fuzzy matching on commit message or author; relies purely on timing proximity

---

## Option B: Cached Decision Log Index with Smart Heuristics

**Summary:** Build an optional JSON/SQLite metadata index of decision logs (indexed by commit hash, phase, date range, topics) that gets lazily constructed and cached. The tool queries this index and uses multi-factor heuristics (timestamp, commit message keywords, branch name, phase context) to surface relevant decisions.

**Key design decisions:**
- Generate a `.claude/decision-log-index.json` on first run (or on-demand with `--rebuild-index`)
- Index includes commit-to-logs reverse mapping, extracted keywords/phase tags from log content, date ranges
- When querying a file:line, first identify the commit, then consult the index for logs mentioning that commit hash, phase, or keyword tokens
- Fall back to timestamp windows if no index entry matches
- Return ranked results (high confidence first) based on heuristic match score
- Use `lib/log-search.sh` as foundation; extend it with indexing capability

**Trade-offs:**
- Extensibility: High; index can be extended with new metadata (tags, topics, severity); supports incremental updates
- Complexity: Moderate; requires index generation, maintenance logic, and ranking heuristic tuning
- Blast radius / risk: Adds a `.claude/` artifact (in .gitignore) that must stay in sync with decision logs

**Risks or prerequisites:**
- Index can become stale if logs are manually edited or deleted
- Multi-factor heuristics may return false positives if keywords overlap across unrelated decisions
- Requires upfront index generation time on first run (can be mitigated with --lazy-index flag)

---

## Option C: Full-Text Search Engine with Schema-Based Extraction

**Summary:** Treat decision logs as structured documents in a lightweight search database (grep-based inverted index or SQLite FTS5 full-text search). Extract decision log schema fields (commit hashes, branch, phase, decision statement, implementation notes) and index them. Query interface supports both simple "why line 42" and advanced Boolean queries (e.g., "phase:decide AND branch:main AND keyword:auth").

**Key design decisions:**
- Parse decision log files into structured fields (date, pipeline, model, task, commits, decision, rationale, links)
- Build an FTS5 (SQLite full-text search) database or grep-based inverted index of logs
- Support both natural language "explain line 42" and structured queries ("--phase architect --commit abc123")
- Return results ranked by relevance (BM25-style scoring or pattern matching confidence)
- Offer rich output formats (JSON, markdown, YAML) for downstream consumption
- Integrate with `lib/log-search.sh` as a backend; provide unified CLI

**Trade-offs:**
- Extensibility: Very high; can extend query language, add new indexed fields, add output formats; supports programmatic query from other tools
- Complexity: High; requires schema definition, index maintenance, query parser, ranking algorithm
- Blast radius / risk: Database file artifact; more moving parts to maintain; potential for index corruption

**Risks or prerequisites:**
- Requires consistent schema in decision log files (may need migrations if format changes)
- SQLite dependency (or complex grep-based index maintenance)
- Query parser may be confusing for users if not well-documented
- Schema extraction may fail on malformed or legacy logs
