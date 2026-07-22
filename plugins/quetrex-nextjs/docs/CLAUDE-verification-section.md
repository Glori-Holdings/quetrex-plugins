## Verification

<!--
  QA and the verify-gate read this section. The canonical, machine-read source of
  truth is `.quetrex/verify.json` -> `.verify[]` (written by /quetrex-init from the
  quetrex-nextjs pack). This block mirrors that ordered chain for humans and for the
  CLAUDE.md fallback resolver. Keep the two in sync.

  Single command: `pnpm verify`. Every step must exit 0; a non-zero on ANY step
  fails QA. Gated on REAL process exit codes only — never scraped stdout, no `|| true`.
-->

Run `pnpm verify`. It runs this exact, ordered, fail-fast chain — every step must exit 0:

```
pnpm exec tsc --noEmit
pnpm exec eslint .
pnpm exec prettier --check .
pnpm exec next build
pnpm exec drizzle-kit check
bash scripts/db-drift.sh
pnpm exec vitest run --reporter=dot
pnpm exec playwright test --reporter=line
```

Why each step earns its place:

1. **`tsc --noEmit`** — `strict` + `noUncheckedIndexedAccess` across the whole repo (test files, scripts, config, dead-but-committed code). 10–50× faster than a build; runs first.
2. **`eslint .`** — ESLint 9 flat config (`eslint-config-next/core-web-vitals` + `/typescript`). Next 16 **removed `next lint`** and `next build` **no longer lints**, so ESLint is its own step and uniquely catches react-hooks / core-web-vitals violations.
3. **`prettier --check .`** — one formatter, one lint engine, never overlapping. Catches anything not saved through the format-on-save hook.
4. **`next build`** — the RSC/boundary gate. The **only** step that catches `server-only` imported into a client tree and non-serializable props across a `"use client"` boundary. Never set `typescript.ignoreBuildErrors`. **The app is built exactly once, here** — Playwright's `webServer` runs `pnpm start` against this artifact and does not rebuild.
5. **`drizzle-kit check`** — validates migration-history integrity.
6. **`scripts/db-drift.sh`** — **read-only** drift guard. Generates into a throwaway temp copy of the migrations dir and never mutates the tracked tree; fails if `schema.ts` changed without a committed migration (the most common Drizzle prod incident). Never `drizzle-kit push`.
7. **`vitest run`** — unit tests and **synchronous** components only. **Async React Server Components are unsupported in Vitest — they are E2E-only (see step 8).** Always `vitest run`, never watch.
8. **`playwright test`** — E2E against the **production** build from step 4 (`webServer: 'pnpm start'`, `reuseExistingServer: !process.env.CI`, `trace: 'on-first-retry'`). This is where **async RSC behavior**, rate-limit/cache behavior, and full server/client boundary rendering are actually proven — Vitest cannot reach them.

> **Async Server Components are E2E-only.** Vitest cannot render an `async` RSC, so never assert RSC output in a unit test — cover it with a Playwright test against the live build instead. This is why `next build` + `playwright test` are non-negotiable steps, not optional extras.
