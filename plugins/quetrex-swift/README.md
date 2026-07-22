# quetrex-swift

A **thin** Claude Code stack pack that layers a single language — Swift — on top of the
stack-agnostic **quetrex-factory** engine. The engine owns the pipeline, the worktree
workflow, and the verify-gate; this pack's one job is to **define the verify chain and
conventions** for Swift.

## What it adds

- **Verify chain** (`docs/verify.template.json`) — the ordered, fail-fast command list
  `/quetrex-init` writes into `<repo>/.quetrex/verify.json` → `.verify[]`. The engine's
  verify-gate runs each command string verbatim and blocks the finish on the **real**
  non-zero exit code of any step:

  ```
  swiftlint --strict   # lint (— strict: warnings are errors)
  swift build          # type + compile + strict-concurrency data-race check
  swift test           # XCTest / Swift Testing suite
  ```

  App targets (Xcode project, asset catalogs, entitlements) swap steps 2–3 for a single
  `xcodebuild test` — see the notes in the template and the Verification doc.

- **Verification section** (`docs/CLAUDE-verification-section.md`) — the human-readable
  `## Verification` block mirroring the chain with a one-line rationale per step, for the
  project `CLAUDE.md`.

- **Conventions & security lenses** (`rules/conventions.md`) — PREFER-not-mandate Swift
  style, concurrency/actor/Sendable guidance for the architect, and a Keychain /
  URLSession / ATS security checklist for reviewers.

- **`format`** — `swiftformat`, invoked by the format-on-save hook with the changed file
  path appended.

## How to pin it

This pack is distributed via the private marketplace
`github.com/Glori-Holdings/quetrex-plugins`. Pin it per-project alongside the engine in
your project settings' `enabledPlugins`:

```json
{
  "enabledPlugins": [
    "quetrex-factory@quetrex",
    "quetrex-swift@quetrex"
  ]
}
```

Then run `/quetrex-init`, which reads this pack's `docs/verify.template.json` and writes
the Swift verify chain into `<repo>/.quetrex/verify.json`. From there the generic pipeline
(architect → developer(s) → QA → reviewer → git-workflow) runs the work to a PR, with QA
and the verify-gate enforcing the chain above.

Use exactly one language pack per repo.
