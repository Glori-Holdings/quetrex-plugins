# quetrex-nextjs

**A Next.js stack pack for the Quetrex agent pipeline.** This plugin layers Next.js knowledge — the App Router + RSC mental model, a real verify chain, Drizzle/Neon + Upstash Redis conventions, and a Fly.io preview/E2E flow — on top of the stack-agnostic **quetrex-factory** engine.

The engine runs the pipeline (`architect → developer(s) → QA → reviewer → git-workflow`), owns the verify **gate**, worktrees, and kanban glue. It knows nothing about your stack. This pack is the stack: it **defines the verify chain the gate executes**, ships the templates a Next.js repo needs, and teaches the agents the RSC / Drizzle / TanStack / Redis conventions to prefer.

> **Two plugins, one job.** `quetrex-factory` is the engine (how work flows). `quetrex-nextjs` is the stack (what the work is made of). Pin both.

---

## What this pack adds

| Layer | What ships | Why it's here and not in the engine |
|---|---|---|
| **Verify chain** | `.quetrex/verify.json` template + the project `## Verification` section | The engine's verify-gate reads `.verify[]` and runs each command for a real exit code. This pack **defines that ordered chain for Next.js.** The engine doesn't know `next build` exists. |
| **Project `CLAUDE.md`** | Lean ~110-line, 6-section skeleton (Stack · Verification · Architecture · Conventions · Off-limits · LESSONS) | Always-true stack facts only. Orchestrator / pipeline / workflow prose stays in global `~/.claude/CLAUDE.md` — never duplicated per repo. |
| **Path-scoped rules** | `.claude/rules/data-layer.md`, `.claude/rules/client-boundary.md` | Context-heavy RSC + data-layer guidance loads only when the agent touches `src/db/**` or `app/**` — the always-loaded core stays lean. |
| **Toolchain templates** | `tsconfig.json` (strict + `noUncheckedIndexedAccess`), `eslint.config.mjs` (ESLint 9 flat), `package.json` scripts, `scripts/db-drift.sh` | The exact config the verify chain depends on. One linter (ESLint), one formatter (Prettier) — no Biome. |
| **Skills** | `shadcn-add`, `drizzle-migrate`, `deploy` (Fly \| Vercel) | Encode taste the model lacks or make a fragile op reproducible. `qa-verify` / `worktree-cleanup` come from the engine. |
| **Conventions** | Drizzle DAL + migration discipline · TanStack `queryOptions()` factory + non-zero `staleTime` · Upstash Redis namespaced+TTL keys, fail-closed rate limit · authN→authZ→validate · `import 'server-only'` guards | The correctness rules the reviewer and security-reviewer enforce **when a lib is actually used** (see below). |
| **Deploy flow** | Fly.io standalone-Docker primary (Vercel secondary) + the ephemeral per-branch **preview/E2E** flow | Playwright can't test async RSC in-process — E2E must run against a live preview URL. |

### The stack

- **Next.js latest** (App Router + RSC) · React 19 · **TypeScript strict** + `noUncheckedIndexedAccess`
- **Tailwind v4** (CSS-first) + **shadcn/ui** · **Framer Motion** (`motion/react`)
- **TanStack Query** — server state · **Zustand** — client / UI state (never mix the two)
- **Drizzle ORM** on **Neon/Postgres** · **Zod v4** at every trust boundary
- **Upstash Redis** — `@upstash/redis` + `@upstash/ratelimit`, HTTP transport. **One client on Fly AND Vercel** — no ioredis split, no connection-exhaustion footgun.
- Package manager: **pnpm**

---

## Conventions are PREFER, not MANDATE

The single most important thing to understand about this pack.

**A simple app should use none of these libraries — and that is correct.** The architect flags which libs a task actually warrants:

- Task fetches/caches server data → **TanStack Query**
- Task holds ephemeral client UI state → **Zustand**
- Task touches the database → **Drizzle**
- Task needs a cache or rate limit → **Upstash Redis**

Correctness is enforced **only if the lib is used** — and then it is non-negotiable:

| If you use… | You must… |
|---|---|
| **Drizzle** | ship the schema change **with** a committed `drizzle-kit generate` migration — never `push`, never migrate at boot |
| **TanStack Query** | set a **non-zero `staleTime`** and share keys through a `queryOptions()` factory (server prefetch + client hook import the same object) |
| **Upstash Redis** | use **namespaced + versioned + TTL'd** keys (`app:entity:id:v1`); rate limits on auth/mutations **fail closed** |

Reach for a library because the task needs it — not because it's in the stack list. The reviewer flags a library pulled in for a task that didn't warrant it just as readily as a mandated one used wrong.

---

## Installing it — pin both plugins per project

The pack lives in the private marketplace **`github.com/Glori-Holdings/quetrex-plugins`** and is pinned per-project (never installed globally). Every Next.js repo declares both the engine and the stack pack in its project settings:

```jsonc
// .claude/settings.json  (checked in, team-shared)
{
  "enabledPlugins": [
    "quetrex-factory@quetrex",
    "quetrex-nextjs@quetrex"
  ]
}
```

Then, on a repo that doesn't yet have the scaffolding, run `/quetrex-init` — it links the repo to its Quetrex project and materializes this pack's templates (`.quetrex/verify.json`, the `## Verification` section, `tsconfig.json`, `eslint.config.mjs`, `package.json` scripts, `.claude/rules/*`). The pack version is pinned to the marketplace ref, so `quetrex-nextjs@quetrex` resolves the same for everyone on the team and the engine prunes retired assets on update.

> Order matters conceptually, not mechanically: the engine provides the gate, this pack provides the chain the gate runs. Both must be enabled or the pipeline has an engine with no stack (verify chain undefined) or a stack with no runner.

---

## The verify chain

The engine's verify-gate reads `.quetrex/verify.json` `.verify[]` — an **ordered** list of commands — and runs each one for its **real process exit code**. No stdout scraping, no `|| true`, no grepping for "passed". Any non-zero on any step fails QA. This pack defines that chain for Next.js:

```jsonc
// .quetrex/verify.json  (shipped by this pack)
{
  "verify": [
    "pnpm exec tsc --noEmit",
    "pnpm exec eslint .",
    "pnpm exec next build",
    "pnpm exec drizzle-kit check",
    "bash scripts/db-drift.sh",
    "pnpm exec vitest run --reporter=dot",
    "pnpm exec playwright test --reporter=line"
  ]
}
```

Fail-fast, in order. Why each step earns its place:

1. **`tsc --noEmit`** — enforces `strict` + `noUncheckedIndexedAccess` across the *whole* repo (tests, scripts, config, dead-but-committed code), 10–50× faster than a build.
2. **`eslint .`** — ESLint 9 flat config (`eslint-config-next/core-web-vitals` + `/typescript`). Next latest's `next build` **no longer lints**, so ESLint is its own gate and uniquely catches react-hooks + core-web-vitals violations.
3. **`next build`** — **the RSC / boundary gate.** The only step that sees a `server-only` module imported into a client component, or a non-serializable prop crossing a `"use client"` boundary. Also type-checks the build graph. **Never** set `typescript.ignoreBuildErrors`.
4. **`drizzle-kit check`** + **`db-drift.sh`** — the drift guard. `check` validates migration consistency; `db-drift.sh` generates into a **throwaway temp copy** of the migrations dir (never mutating the tracked tree) and fails if `schema.ts` changed without a committed migration — the most common Drizzle prod incident.
5. **`vitest run`** — unit + **synchronous** components. **Async Server Components are unsupported in Vitest** — always `vitest run` (never watch).
6. **`playwright test`** — E2E against a **production build**, and the **only** place async RSC get real coverage. Serves the single artifact the `next build` step already produced (`webServer: 'pnpm start'` — never a second `pnpm build`).

**Build exactly once.** Verify's `next build` produces the artifact; Playwright's `webServer` runs `pnpm start` against it. The `db-drift` step is **read-only** — it never writes a migration into your tree mid-verify.

Locally the same chain is the `pnpm verify` script; the gate and a human run the identical commands.

---

## Fly.io preview & E2E flow

Playwright can't exercise async RSC in-process, so E2E runs against a **live preview URL**. Fly.io is primary; Vercel is the secondary path.

### Fly (primary)

For each branch under test the pipeline stands up a **fully ephemeral** preview and tears it **all** down afterward:

1. **Provision** — spin up an ephemeral per-branch Fly app (Next `output: 'standalone'` multi-stage Docker image) and a **fresh Neon DB branch**, seeded.
2. **Migrate + seed** — Fly `release_command` runs `drizzle-kit migrate` against the new Neon branch's **unpooled/direct** URL on the new image, before traffic shifts. Non-zero exit aborts the deploy.
3. **E2E** — `playwright test` runs against the **live preview URL** (not localhost). This is where async RSC, Server Actions, Redis rate-limits, and real DB reads get proven.
4. **Teardown — MANDATORY, never leaked.** `fly apps destroy <ephemeral-app>` **and** delete the Neon branch. A preview is created and destroyed within the run; nothing survives it.

**Load-bearing invariants (Fly):**

- **`NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` is a pinned Fly secret passed as a Docker build `ARG`.** Without a pinned key, multi-machine App Router apps fail Server Actions non-deterministically ("Failed to find Server Action"). Same for `NEXT_PUBLIC_*` — inlined at build → `--build-arg`, not runtime env.
- **Per-company `FLY_API_TOKEN`, sourced inline — never `fly auth login`.** Grep the token from the project vault, source it in-memory, confirm with `FLY_API_TOKEN="$TOK" fly status --app <app>` before anything, never persist it. The interactive login can't see a given company's apps.
- **Pooled vs unpooled:** the app runtime uses the **pooled** (`-pooler`) Neon host; migrations use the **direct/unpooled** host (`drizzle.config.ts` → `DATABASE_URL_UNPOOLED`).

### Vercel (secondary)

Vercel builds Next natively (no Dockerfile) and gives every branch an **automatic preview URL** — Playwright targets that. Migrations run from CI or an explicit `pnpm db:migrate` **before** `vercel deploy --prod`, gated so a migration failure stops the promote. No release phase, so migrations stay backward-compatible.

### Production deploy

Deploy is a **human-triggered terminal command** (`/deploy [staging|production|rollback]`), never a pipeline stage. Prod gating lives in the skill (it sees the `production` arg), not in a permission pattern. Fly prod uses `strategy = "bluegreen"` for zero-downtime (safe — state lives in Neon/Redis); the `release_command` migration gate aborts the deploy on non-zero exit.

---

## Layout this pack materializes

```
<repo>/
├── .quetrex/verify.json          # the ordered verify chain (engine's gate reads this)
├── .mcp.json                     # Context7 · next-devtools · Playwright (project-scoped)
├── .claude/
│   ├── CLAUDE.md                 # lean 6-section stack facts (## Verification lives here)
│   ├── rules/
│   │   ├── data-layer.md         # paths: src/db/**, app/**/route.ts
│   │   └── client-boundary.md    # paths: app/**, src/components/**
│   └── skills/
│       ├── shadcn-add/SKILL.md
│       ├── drizzle-migrate/SKILL.md
│       └── deploy/SKILL.md        # Fly | Vercel branch
├── tsconfig.json                 # strict + noUncheckedIndexedAccess
├── eslint.config.mjs             # ESLint 9 flat, eslint-config-next
├── package.json                  # verify + per-step scripts
└── scripts/db-drift.sh           # read-only drift check
```

Agents, hooks (`deny-guard`, `enforce-branch`, `typecheck-gate`, `format`, `secret-scan`), worktrees, and the kanban commands (`/quetrex-*`, `/new-task`, `/que-task`, …) come from **quetrex-factory** — this pack does not re-ship them.

---

## Relationship to quetrex-factory

| | quetrex-factory (engine) | quetrex-nextjs (this pack) |
|---|---|---|
| **Owns** | pipeline, agents, worktrees, kanban glue, the verify **gate** (runs `.verify[]` for exit codes) | the verify **chain** for Next.js, project `CLAUDE.md` templates, RSC/Drizzle/TanStack/Redis conventions, Fly preview/E2E + deploy |
| **Knows about your stack?** | No — stack-agnostic | Yes — that's the whole point |
| **Enabled as** | `quetrex-factory@quetrex` | `quetrex-nextjs@quetrex` |

Swap this pack for a different stack pack and the same engine runs a different stack. The engine is the constant; the pack is the variable.
