## Verification

<!--
  QA and the verify-gate read this section. The canonical, machine-read source of
  truth is `.quetrex/verify.json` -> `.verify[]` (written by /quetrex-init from the
  quetrex-swift pack). This block mirrors that ordered chain for humans and for the
  CLAUDE.md fallback resolver. Keep the two in sync.

  Every step must exit 0; a non-zero on ANY step fails QA. Gated on REAL process
  exit codes only — never scraped stdout, no `|| true`, no `// swiftlint:disable`
  in place of a real fix.
-->

Run this exact, ordered, fail-fast chain — every step must exit 0:

```
swiftlint --strict
swift build
swift test
```

Why each step earns its place:

1. **`swiftlint --strict`** — lint first: cheapest and broadest. `--strict` promotes every warning to an error, so a convention or style violation returns a non-zero exit and blocks the finish. Runs before compilation to fail fast on trivially fixable issues.
2. **`swift build`** — the type and compile gate. The Swift compiler is the authority on types, `@available` platform gating, and — under Swift 6 / `-strict-concurrency=complete` — data-race safety across `actor` and `Sendable` boundaries. This is the step that catches concurrency violations no linter can see.
3. **`swift test`** — runs the XCTest / Swift Testing suite to completion; exits non-zero on the first failing assertion or suite.

> **App targets are `xcodebuild`, not SwiftPM.** A repo with an `.xcodeproj`/`.xcworkspace`, asset catalogs, an `Info.plist`, or entitlements cannot be built by `swift build`/`swift test`. For those, keep step 1 and replace steps 2–3 with a single build-and-test command:
>
> ```
> swiftlint --strict
> xcodebuild test -scheme <Scheme> -destination 'platform=iOS Simulator,name=iPhone 15'
> ```
>
> Pick **one** path per repo: a pure SwiftPM package uses `swift build` + `swift test`; anything driven by an Xcode project uses `xcodebuild test` (it both builds and tests in one step).

Order is load-bearing: lint (fast, broad) → build (authoritative type/concurrency gate) → test (behavior) against that compiled artifact.
