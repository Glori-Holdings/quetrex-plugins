# Python conventions (PREFER, not mandate)

These are defaults the architect and developers should lean toward. A project may override any of them in its own `.claude/CLAUDE.md` — prefer the project's stated choice when it conflicts.

## Project & packaging
- **Prefer** a single `pyproject.toml` as the one source of truth for build metadata and tool config (ruff, mypy, pytest all read it). Avoid `setup.py`/`setup.cfg` for new work.
- **Prefer** an isolated environment per repo — `uv` (fastest) or `poetry`; never install into the system interpreter. Commit a lockfile (`uv.lock` / `poetry.lock`) and pin the Python version (`.python-version` or `requires-python`).
- **Prefer** a `src/` layout (`src/<package>/`) so tests import the installed package, not the working tree.
- **Prefer** running every verify command through the env manager (`uv run ruff check .`, `poetry run pytest`) so the right interpreter and deps resolve.

## Style & types
- **Prefer** ruff for both lint and format (Black-compatible) — one tool, configured in `[tool.ruff]`. Don't also run Black/flake8/isort; ruff subsumes them.
- **Prefer** full type hints on public functions and dataclasses; run `mypy` (or `pyright`) in strict-ish mode. Reach for `from __future__ import annotations` on 3.9/3.10 targets.
- **Prefer** `pathlib.Path` over `os.path`, f-strings over `%`/`.format`, and `dataclasses`/`pydantic` over ad-hoc dicts for structured data.
- **Prefer** explicit exceptions over bare `except:`; never swallow errors silently.

## Testing
- **Prefer** `pytest` with plain `assert`, fixtures over setup/teardown, and `parametrize` over copy-pasted cases. Keep tests deterministic (no real network/clock — inject or fake them).

## Security checklist (review every diff against this)
- **Injection** — never build SQL/shell/HTML by string concatenation. Use parameterized queries (DB-API params, SQLAlchemy bound params); pass `subprocess` args as a list with `shell=False`; never `os.system`.
- **Deserialization** — never `pickle.loads`, `yaml.load` (use `yaml.safe_load`), or `eval`/`exec` on untrusted input. Prefer `json` for data interchange.
- **Secrets** — no hardcoded keys/tokens/passwords; read from env or the vault. Keep secrets out of logs and tracebacks; ensure `.env` is gitignored.
- **SSRF / path traversal** — validate and canonicalize user-supplied URLs and file paths before use; constrain to an allowlist / base directory.
- **Dependencies & crypto** — prefer maintained, pinned deps; use `secrets`/`hashlib` (not `random`/`md5`) for anything security-sensitive; verify TLS (never `verify=False`).
