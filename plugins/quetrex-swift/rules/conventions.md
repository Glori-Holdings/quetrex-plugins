# Swift conventions

These are **preferences, not mandates.** They bias the architect and developers toward
idiomatic Swift; the `verify` chain (`swiftlint --strict → swift build → swift test`) is
what actually gates a finish. Where a convention conflicts with a passing, clearer
solution, ship the clearer solution.

## Style & structure

- **PREFER** `struct` and `enum` value types; reach for `class` only when reference
  semantics, identity, or `deinit` are genuinely needed.
- **PREFER** immutability: `let` over `var`, and expose stored properties as `let` /
  `private(set) var` unless external mutation is part of the contract.
- **PREFER** optionals and `Result`/`throws` over sentinel values; avoid force-unwrap
  (`!`) and `try!`/`as!` outside tests and provably-safe literals.
- **PREFER** protocol-oriented seams over inheritance; keep protocols small and
  composable, and use `protocol ... : Sendable` where values cross concurrency domains.
- **PREFER** `guard` for early exit and to keep the happy path un-indented.
- **PREFER** clear, spelled-out names (Swift API Design Guidelines): methods read as
  phrases, booleans as assertions (`isEmpty`), factory-ish free of `get` prefixes.
- **PREFER** `// MARK:` sections and one primary type per file; extensions to group
  protocol conformances.

## Concurrency (Swift 6 / strict concurrency)

- **PREFER** `async`/`await` and structured concurrency (`async let`, `TaskGroup`) over
  completion handlers and manual `DispatchQueue` hopping.
- **PREFER** `actor` to protect mutable shared state; annotate UI-touching types with
  `@MainActor` rather than dispatching to the main queue by hand.
- **PREFER** making types `Sendable` (or explicitly reasoning about why they are not);
  let `swift build` under `-strict-concurrency=complete` prove data-race safety instead
  of silencing it with `@unchecked Sendable`.
- **PREFER** cancellation-aware code: check `Task.isCancelled` / call
  `try Task.checkCancellation()` in long loops.

## Dependencies & tests

- **PREFER** Swift Package Manager with pinned versions in `Package.resolved` (commit it);
  keep `Package.swift` dependencies to exact or `.upToNextMinor` ranges for apps.
- **PREFER** dependency injection through initializers/protocols over singletons so units
  are testable without global state.
- **PREFER** fast, isolated tests (XCTest or Swift Testing `@Test`); one behavior per test,
  descriptive names, and `async` test methods for `async` code.

## Security checklist

- **Secrets & credentials** — store tokens, keys, and passwords in the **Keychain**
  (`kSecClass...`, ideally with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), never in
  `UserDefaults`, plists, source, or the app bundle. Do not log secrets.
- **URLSession / TLS** — use HTTPS everywhere; do **not** disable **App Transport
  Security** (no blanket `NSAllowsArbitraryLoads` in `Info.plist` — scope any exception to
  a specific domain and justify it). Implement certificate/public-key pinning via
  `URLSessionDelegate` for high-value endpoints, and validate server trust rather than
  returning `.useCredential` unconditionally.
- **Data at rest** — enable Data Protection (`.completeFileProtection` / `.complete`
  file attributes) for sensitive files; avoid caching secrets to disk via `URLCache`.
- **Input & injection** — parameterize SQLite/CoreData queries; validate and encode any
  data crossing into `WKWebView`; never build predicates from raw user strings.
- **Deep links & IPC** — validate and sanitize incoming URLs, universal links, and
  pasteboard content; treat all external input as untrusted.
- **Privacy** — declare purpose strings for every requested permission; request the
  narrowest scope; keep third-party SDK data flows out of sensitive paths.
