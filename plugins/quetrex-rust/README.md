# quetrex-rust

A **thin** Claude Code stack pack that layers a single language — Rust — on top of the
stack-agnostic **quetrex-factory** engine. The engine owns the pipeline and the
verify-gate; this pack's job is to **define the verify chain** and lend a little
Rust-shaped judgment to the agents.

## What it adds

- **A verify chain** (`docs/verify.template.json`) — the ordered, fail-fast command
  list `/quetrex-init` writes into `<repo>/.quetrex/verify.json` → `.verify[]`. The
  engine's verify-gate runs each string and honors **real exit codes**; a non-zero on
  any step blocks the finish:

  ```
  cargo fmt --all --check
  cargo clippy --all-targets --all-features -- -D warnings
  cargo build --all-targets
  cargo test --all-targets
  ```

  Fail-fast ordering: format/lint/type → build → test. `format` (`rustfmt`) powers the
  format-on-save hook.

- **A human-readable Verification block** (`docs/CLAUDE-verification-section.md`) that
  mirrors the chain with a one-line rationale per step, for the project `CLAUDE.md`.

- **Rust conventions + a security checklist** (`rules/conventions.md`) — ownership /
  borrowing / lifetime guidance for the architect, and unsafe-block / panic / overflow
  lenses for the reviewer. These are **preferences, not mandates**; the verify chain is
  the only hard gate.

## How to pin it

The pack ships from the private marketplace
`github.com/Glori-Holdings/quetrex-plugins`. Pin it **per project**, alongside the
engine, in your project settings' `enabledPlugins`:

```json
{
  "enabledPlugins": [
    "quetrex-factory@quetrex",
    "quetrex-rust@quetrex"
  ]
}
```

Then run `/quetrex-init` to write the verify chain and Verification section into the
repo. `quetrex-factory@quetrex` provides the engine and pipeline; `quetrex-rust@quetrex`
provides this language layer.
