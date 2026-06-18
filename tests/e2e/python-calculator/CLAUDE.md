# CLAUDE.md — python-calculator (E2E test workspace)

## Project Purpose
A pure-Python arithmetic calculator module used as a self-contained E2E test
fixture for the `claude-qa` pipeline.  Claude's job is to write a thorough test
suite for `calculator.py` that covers edge cases the original author missed.

## Commands
```bash
# Install dependencies
pip install -r requirements.txt

# Run tests
pytest -v

# Run a single test file
pytest tests/test_calculator.py -v
```

## Module
All functions live in `calculator.py` at the project root.  No imports outside
the standard library and pytest.

## What Good Tests Look Like
- Cover the documented happy paths for every function
- Cover error cases (ValueError for invalid inputs)
- Check boundary conditions (zero, negative numbers, very large numbers)
- Check type edge cases (float vs int, mixed types)
- Use `pytest.raises` for expected exceptions
- Do not use mocking — all functions are pure
