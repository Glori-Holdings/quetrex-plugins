# quetrex-python

A **thin** Claude Code stack pack that layers a single language — Python — on top of the stack-agnostic **quetrex-factory** ENGINE. The ENGINE owns the pipeline, worktrees, and the verify-gate; this pack's one job is to **define the Python verify chain and conventions** the gate runs.

## What it adds

- **`docs/verify.template.json`** — the ordered, fail-fast verify chain, written by `/quetrex-init` into `<repo>/.quetrex/verify.json`. The ENGINE's verify-gate reads `.verify[]` verbatim and honors **real process exit codes** — a non-zero on any step blocks the finish.

  ```
  ruff check .        # lint (pyflakes/pycodestyle/isort/pyupgrade/bugbear)
  ruff format --check .   # formatter drift guard (Black-compatible)
  mypy .              # static types (swap pyright if the project prefers it)
  pytest -q           # authoritative behavior gate
  ```

  `format` = `ruff format` (invoked by the format-on-save hook with the changed file appended).

- **`docs/CLAUDE-verification-section.md`** — the `## Verification` block mirroring the chain, with a one-line rationale per step, for humans and the CLAUDE.md fallback resolver.
- **`rules/conventions.md`** — PREFER-not-mandate Python conventions (packaging/venv-aware) plus an injection / deserialization / secret security checklist.

## How to pin it

The marketplace is **github.com/Glori-Holdings/quetrex-plugins** (private). Pin this pack per-project alongside the ENGINE in `enabledPlugins`:

```json
{
  "enabledPlugins": [
    "quetrex-factory@quetrex",
    "quetrex-python@quetrex"
  ]
}
```

Then run `/quetrex-init` — it writes the Python chain from this pack into `<repo>/.quetrex/verify.json` and the `## Verification` section into the project `.claude/CLAUDE.md`. Adjust the type checker (mypy ↔ pyright), coverage floor, and env-manager prefix (`uv run` / `poetry run`) to match the repo — keep exactly one type checker in the chain.
