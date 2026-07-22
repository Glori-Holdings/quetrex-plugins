## Verification

<!--
  QA and the verify-gate read this section. The canonical, machine-read source of
  truth is `.quetrex/verify.json` -> `.verify[]` (written by /quetrex-init from the
  quetrex-python pack). This block mirrors that ordered chain for humans and for the
  CLAUDE.md fallback resolver. Keep the two in sync.

  Every step must exit 0; a non-zero on ANY step fails QA. Gated on REAL process exit
  codes only — never scraped stdout, no `|| true`. Run each command through the
  project's env manager (`uv run`, `poetry run`, or an activated venv) so the right
  interpreter and dependencies resolve.
-->

Run this exact, ordered, fail-fast chain — every step must exit 0:

```
ruff check .
ruff format --check .
mypy .
pytest -q
```

Why each step earns its place:

1. **`ruff check .`** — lint. One fast Rust engine subsumes pyflakes, pycodestyle, isort, pyupgrade, and flake8-bugbear. Broadest and cheapest signal, so it runs first.
2. **`ruff format --check .`** — formatter drift guard (Black-compatible). Catches anything not saved through the format-on-save hook. One formatter, one lint engine, never overlapping.
3. **`mypy .`** — static type check across the whole package (src, tests, scripts). Swap to `pyright` if the project standardizes on it, but keep **exactly one** type checker in the chain.
4. **`pytest -q`** — the authoritative behavior gate. Quiet reporter. Add `--cov --cov-fail-under=<n>` when the project enforces a coverage floor.

> Order is load-bearing: the fast static checks (lint → format → types) run before the slow runtime gate (tests) so failures surface as early and cheaply as possible.
