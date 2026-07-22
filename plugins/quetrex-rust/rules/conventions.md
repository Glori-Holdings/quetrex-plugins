# Rust conventions

These are **preferences, not mandates.** The hard gate is the verify chain in
`docs/verify.template.json` (`cargo fmt --check` → `clippy -D warnings` → `build` →
`test`). Follow the grain of the existing crate first; reach for these when nothing
local overrides them.

## Style & structure

- **Let rustfmt decide.** Never hand-format; formatting is enforced by `cargo fmt --check`. Configure via `rustfmt.toml`, not local nudges.
- **Clippy is the style referee.** The gate runs `-D warnings`; prefer fixing the lint over `#[allow(...)]`. When an allow is genuinely warranted, scope it as narrowly as possible and leave a one-line reason.
- **Modules over mega-files.** Split by responsibility; keep `mod.rs`/`lib.rs` thin re-export surfaces. Prefer `pub(crate)` visibility and widen to `pub` only for the intended API.
- **Edition:** target the workspace's declared `edition` in `Cargo.toml`; don't mix idioms across editions in one crate.

## Ownership, borrowing, lifetimes

- **Borrow before you clone.** Prefer `&T` / `&mut T` and slices (`&[T]`, `&str`) in signatures; reserve `.clone()` for when ownership is actually needed, not to silence the borrow checker.
- **Accept the general, return the concrete.** Take `impl AsRef<Path>`, `&str`, `IntoIterator`, etc.; return owned/concrete types. Avoid leaking lifetimes into public APIs unless the borrow is the point.
- **Elide lifetimes** where the compiler allows; name them only when they clarify a real relationship.
- **Reach for smart pointers deliberately:** `Rc`/`Arc` for shared ownership, `RefCell`/`Mutex` for interior mutability — and only when a plain borrow won't express the design.

## Errors & results

- **`Result` over panics in library code.** Model recoverable failure with `Result<T, E>`; reserve `panic!` for truly unreachable invariants.
- **Prefer `?` propagation.** Use `thiserror` for library error enums and `anyhow` for application-level context; don't hand-roll `impl Error` when these fit.
- **No unwrap/expect on fallible I/O or parsing** in shipping paths. `expect` is acceptable for provably-infallible cases — give it a message that states the invariant.

## Types & API

- Prefer the newtype pattern and enums to encode invariants in the type system over runtime checks.
- Derive `Debug` widely; derive `Clone`/`Copy`/`PartialEq` only where semantically meaningful.
- Keep `async` colored consistently — don't block a runtime thread with sync I/O inside `async fn`.

## Security checklist

- [ ] **`unsafe` is justified and contained.** Every `unsafe` block carries a `// SAFETY:` comment stating the invariant that makes it sound. Keep blocks minimal; never use `unsafe` to bypass the borrow checker for convenience.
- [ ] **No panics on attacker-influenced input.** Audit `unwrap`, `expect`, indexing (`v[i]`), slicing, and integer arithmetic on untrusted data; use `get`, `checked_*`/`saturating_*`, and `Result` instead. A panic across an FFI boundary is UB.
- [ ] **Integer overflow is handled**, not assumed to wrap — release builds wrap silently. Use `checked_add`/`saturating_`/`wrapping_` explicitly where overflow is reachable.
- [ ] **Secrets don't linger or leak.** Keep credentials out of `Debug`/`Display` output and logs; prefer zeroizing wrappers (e.g. `secrecy`, `zeroize`) for key material.
- [ ] **Dependencies are vetted.** Prefer `cargo audit` / `cargo deny` in CI; scrutinize crates that pull in `unsafe`, network, or build-script surface.
- [ ] **Deserialization is bounded.** Validate and size-limit untrusted input (serde) before allocating; don't trust length prefixes.
- [ ] **Concurrency is data-race free by construction** — rely on `Send`/`Sync`; never `unsafe impl` them to paper over a shared-mutability bug.
