## Verification

<!--
  QA and the verify-gate read this section. The canonical, machine-read source of
  truth is `.quetrex/verify.json` -> `.verify[]` (written by /quetrex-init from the
  quetrex-rust pack). This block mirrors that ordered chain for humans and for the
  CLAUDE.md fallback resolver. Keep the two in sync.

  Single command: `cargo make verify` or run the steps below. Every step must exit 0;
  a non-zero on ANY step fails QA. Gated on REAL process exit codes only — never
  scraped stdout, no `|| true`.
-->

Run this exact, ordered, fail-fast chain — every step must exit 0:

```
cargo fmt --all --check
cargo clippy --all-targets --all-features -- -D warnings
cargo build --all-targets
cargo test --all-targets
```

Why each step earns its place:

1. **`cargo fmt --all --check`** — rustfmt in check mode across every crate in the workspace. Exits non-zero on any unformatted file **without** rewriting it, so CI never silently reformats. Cheapest, broadest gate; runs first.
2. **`cargo clippy --all-targets --all-features -- -D warnings`** — lints every target (lib, bins, tests, examples, benches) with all features enabled. `-D warnings` promotes **all** warnings (clippy lints *and* rustc warnings) to hard errors, so nothing merges dirty. Clippy type-checks as it lints, making this the fast compile-error gate before the full build.
3. **`cargo build --all-targets`** — the authoritative compile of every target. Proves the crate and its test/example/bench targets actually build, catching what an analysis-only clippy pass can miss: link errors, build scripts, proc-macro expansion, and `cfg`-gated code paths.
4. **`cargo test --all-targets`** — runs unit and integration tests against that build. `--all-targets` gives deterministic target selection (lib/bin/test/example); a green run proves behavior, not just that it compiles.

> **Order is load-bearing.** Format and lint (cheap, broad) run first and fail fast; the full build runs once; tests run against that build. Never wrap a step in `|| true` or scrape stdout — the gate trusts the process exit code alone.

> **Doctests:** `--all-targets` does **not** run doctests. If the crate documents public APIs with runnable examples, also run a plain `cargo test` locally to keep doctests green; the gate standardizes on `--all-targets` for deterministic selection.
