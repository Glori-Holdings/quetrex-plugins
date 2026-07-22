---
paths:
  - "src/db/**/*.ts"
  - "src/env.ts"
  - "src/lib/auth.ts"
  - "src/lib/ratelimit.ts"
  - "src/lib/redis.ts"
  - "app/**/route.ts"
  - "app/**/actions.ts"
  - "app/**/*.actions.ts"
  - "src/actions/**/*.ts"
---

# Backend & data conventions

**PREFER, not mandate.** The architect flags which of these libraries a task actually warrants — persistence → Drizzle; cache / rate-limit / sessions → Upstash Redis; any trust boundary → Zod. A task that needs none of them uses none, and that is correct: do not add a database, a Redis client, or a validation layer to an app that has no server data surface. But **once a library is in play, the discipline below is non-negotiable** — it is exactly the discipline the security-reviewer enforces (see the checklist at the end). "We used Drizzle but skipped the migration" or "we used Redis but the keys have no TTL" is a review failure, not a style nit.

The single always-true rule: **anything that reads or writes server state does so through a `server-only` module, behind a validated boundary, with authorization checked next to the query.**

---

## 1. Drizzle — schema is the single source of truth

The schema in `src/db/schema/*.ts` is the one source of truth for the database shape. The **only** path from a schema edit to Postgres is a committed migration file produced by `drizzle-kit generate` and applied by `drizzle-kit migrate`.

**Migration flow — generate → review → migrate. Never `push`:**

1. Edit the schema in `src/db/schema/*.ts`.
2. `pnpm db:generate` (`drizzle-kit generate`) — writes SQL into `src/db/migrations/`.
3. **Read the generated SQL.** This is a mandatory human/reviewer checkpoint, not a formality — a rename Drizzle can't infer shows up as a `DROP` + `ADD` (silent data loss). The `drizzle-migrate` skill stops here and shows the diff.
4. Commit the schema change **and its migration together**, in the same commit.
5. `pnpm db:migrate` applies it against the target env's **unpooled** URL.

- **`drizzle-kit push` is banned** outside a throwaway local scratch DB. It mutates the database directly with no reviewable, replayable artifact and no history. It is denied in CI/deploy, and `deny-guard.sh` blocks it even inside the `bypassPermissions` developer agent. Do not reach for it.
- **Never edit an applied migration.** Once a migration has run anywhere shared, it is immutable. Fix-forward with a new migration.
- **Never run migrations at app boot or in the request path.** Migrations run in a release/CI step (Fly `release_command`), never inside `next start` or a route handler.
- **Destructive changes (drop / rename / narrow a column) require a hand-written expand → migrate-data → contract sequence**, staging-tested. Because `release_command` migrations are forward-only, every migration must be backward-compatible with the previously-deployed image (the old code runs against the new schema during a rolling/bluegreen shift).
- The read-only **drift guard** (`pnpm db:check` + `pnpm db:drift`) in `pnpm verify` fails the build if `schema.ts` changed without a committed migration — the most common Drizzle production incident. `db-drift.sh` generates into a throwaway temp copy and never mutates the tracked migrations dir.
- **`src/db/migrations/**` is off-limits** to hand-editing — it is generated output.
- Wrap any multi-statement write in `db.transaction(...)` so a partial failure can't leave a half-written record.
- Export inferred types from every table (`typeof posts.$inferSelect` / `$inferInsert`) rather than restating column types by hand.

---

## 2. Neon — long-lived pool, pooled vs unpooled

The database handle is created **once** in a `server-only` module and reused for the process lifetime. The app ships to Fly.io as a standalone Node server (a long-lived process), so use a **module-level** connection pool — not an HTTP-per-query client.

```typescript
// src/db/index.ts
import 'server-only'
import { drizzle } from 'drizzle-orm/neon-serverless'   // WebSocket Pool — long-lived Fly Node process
import { Pool } from '@neondatabase/serverless'
import { env } from '@/env'
import * as schema from './schema'

// One module-level pool over the POOLED host, reused for the process lifetime.
const pool = new Pool({ connectionString: env.DATABASE_URL })
export const db = drizzle(pool, { schema })
```

- **Fly.io / any long-lived Node process:** one **module-level** `neon-serverless` `Pool` (or `postgres-js`) over the pooled host, reused for the process lifetime. It supports interactive multi-statement transactions (`db.transaction()`), which the app needs for safe multi-step writes. A per-request `Pool` exhausts connections — create it once at module scope.

**Pooled vs unpooled — the load-bearing distinction:**

- **App runtime → pooled host** (the `-pooler` hostname / PgBouncer). Many concurrent workers must go through the pooler or they exhaust Postgres's connection ceiling.
- **Migrations → direct / unpooled host** (`DATABASE_URL_UNPOOLED`). PgBouncer's transaction pooling mode breaks the session-level operations migrations rely on (advisory locks, some DDL). Point `drizzle.config.ts` at `DATABASE_URL_UNPOOLED`, and keep `DATABASE_URL` (pooled) for the app.

Both URLs are validated in `src/env.ts` (§5) — never read either directly from `process.env`.

---

## 3. Upstash Redis — namespaced, TTL'd, fail-closed

**PREFER Redis only when the task needs cache, rate-limiting, sessions, or idempotency.** Most CRUD features need none. When it is warranted, use the Upstash HTTP client on Fly — `@upstash/redis` speaks HTTP, so it works cleanly in a long-lived Fly process and never holds a TCP connection to leak. One client, no ioredis/HTTP split.

```typescript
// src/lib/redis.ts
import 'server-only'
import { Redis } from '@upstash/redis'
import { env } from '@/env'

export const redis = new Redis({
  url: env.UPSTASH_REDIS_REST_URL,
  token: env.UPSTASH_REDIS_REST_TOKEN,
})
```

```typescript
// src/lib/ratelimit.ts
import 'server-only'
import { Ratelimit } from '@upstash/ratelimit'
import { redis } from './redis'

// Namespaced + versioned prefix so a key-shape change is a new namespace, not a silent collision.
export const ratelimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(10, '10 s'),
  prefix: 'app:rl:v1',
  analytics: true,
})
```

Redis does exactly three jobs, and each has a hard rule:

- **Cache-aside** — Redis is *never* authoritative; Postgres is. Every cached key carries a TTL. A cache miss re-reads the source; a Redis outage degrades to a slower direct read, never to wrong or corrupt data.
- **Rate limiting** — sliding-window on every mutation, every auth attempt, and every expensive read. Key by `user.id` when authenticated, else by client IP. **Auth and mutation limiters fail closed:** if the `ratelimit.limit()` call itself throws (Redis unreachable), treat it as *denied*, not allowed — wrap it and return the rate-limited error on failure. An open-fail rate limiter is not a rate limiter.
- **Sessions / idempotency** — TTL'd keys keyed to the token / idempotency id.

**Every key is namespaced and versioned and TTL'd:** `app:<entity>:<id>:v1`. No bare keys, no immortal keys. The invariant across all three jobs: **losing Redis must degrade, never corrupt.**

Do **not** register a write-capable Redis MCP server — its `SET`/`GET`/`FLUSH` tools are pure attack surface. Prove cache and rate-limit behavior with Playwright E2E against the running app.

---

## 4. Every Server Action and route handler is a public POST endpoint

A Server Action compiles to an unauthenticated HTTP endpoint anyone can call with any arguments. A route handler is the same. Treat every one as hostile input and run the three gates **in order**: **authN → authZ → validate**.

- **authN** — resolve the real user from the session (`requireUser()`), server-side. Never trust a user id, tenant id, or role passed in the payload.
- **authZ** — a well-formed object is not authorization. Check that *this* user owns *this specific row* and has the required role for the specific id. Enforce it in the SQL `WHERE` clause (in the DAL), so the query returns nothing when the check fails — don't fetch-then-compare in app code.
- **validate** — Zod-parse the raw input before it reaches any DB / Redis / external call. Derive write schemas from Drizzle and `.pick()` **only** the client-settable fields, so `id` / `ownerId` / `createdAt` can't be over-posted.

```typescript
'use server'
import { createInsertSchema } from 'drizzle-zod'   // pinned Zod-v4-compatible — see the pack Stack notes
import { posts } from '@/db/schema'
import { requireUser } from '@/lib/auth'
import { ratelimit } from '@/lib/ratelimit'
import { updatePostOwnedBy } from '@/db/dal/posts'

// .pick() the client-settable fields ONLY — no id / ownerId / timestamps over-posting.
const UpdatePost = createInsertSchema(posts).pick({ title: true, body: true })

export async function updatePost(postId: string, raw: unknown) {
  const user = await requireUser()                       // 1. authN

  const { success } = await ratelimit.limit(user.id)     // fail-closed rate limit on the mutation
  if (!success) return { error: 'rate_limited' as const }

  const input = UpdatePost.parse(raw)                    // 3. validate (Zod)

  // 2. authZ lives in the WHERE clause: updates zero rows if this user doesn't own postId.
  const updated = await updatePostOwnedBy(postId, user.id, input)
  if (!updated) return { error: 'not_found' as const }   // don't leak existence vs. ownership

  return { ok: true as const }
}
```

Route handlers follow the identical shape — resolve the user, rate-limit, `Schema.parse(await request.json())`, then call the DAL. Catch DB/Redis errors, log the detail **server-side**, and return a generic message to the client — never echo a raw driver error (it leaks schema and connection details).

---

## 5. Zod at every boundary + validated env

**Zod validates at every trust boundary**, not just form inputs: Server Action / route args, `await request.json()`, webhook and third-party API responses, and environment variables. Anything that crosses from outside your process into it gets parsed first.

- Derive DB-write schemas from Drizzle via `drizzle-zod` `createInsertSchema(table).pick(...)` so the validation shape can't drift from the table shape.
- Pin `drizzle-zod` and `@t3-oss/env-nextjs` to their Zod-v4-compatible releases (confirm exact minimums with Context7 at setup). A Zod v3/v4 mismatch produces silently different schema shapes — the pin makes a bad bump trip `tsc`/`eslint` early instead of at runtime.

**Env is validated exactly once**, in `src/env.ts`, and imported everywhere. Never read `process.env` anywhere else.

```typescript
// src/env.ts
import { createEnv } from '@t3-oss/env-nextjs'
import { z } from 'zod'

export const env = createEnv({
  server: {
    DATABASE_URL: z.string().url(),           // pooled — app runtime
    DATABASE_URL_UNPOOLED: z.string().url(),  // direct — migrations
    UPSTASH_REDIS_REST_URL: z.string().url().optional(),
    UPSTASH_REDIS_REST_TOKEN: z.string().min(1).optional(),
  },
  client: {
    NEXT_PUBLIC_APP_URL: z.string().url(),
  },
  experimental__runtimeEnv: {
    NEXT_PUBLIC_APP_URL: process.env.NEXT_PUBLIC_APP_URL,
  },
  emptyStringAsUndefined: true,
})
```

- Server vars and `NEXT_PUBLIC_*` vars are declared separately; `createEnv` throws at build time if a server var is imported into client code — a missing/misplaced var fails the build, not production.
- **No secret ever goes in a `NEXT_PUBLIC_*` var** — those are inlined into the client bundle in plaintext.
- Make Redis vars `.optional()` only for apps that genuinely may run without Redis; if a feature requires Redis, make them required so the build fails fast when they're absent.

---

## 6. Server-only Data Access Layer + DTO mapping

**All SQL lives in `src/db/dal/*.ts`** — a `server-only` Data Access Layer. No ad-hoc Drizzle queries in route handlers, Server Actions, or (especially) components.

- Every DAL module starts with `import 'server-only'`, so an accidental client import is a **build error** (`next build` reports it), not a leaked connection string or query.
- Each DAL function that touches a user-scoped row **re-checks identity next to the query** — take `userId` as a parameter and put it in the `WHERE` clause. The DAL is the last line of authorization defense.
- **Never return raw Drizzle rows to the caller.** Map every row to an explicit DTO that names the exact fields the client may see. A raw row leaks whatever columns exist today and silently leaks whatever columns get added tomorrow — `password_hash`, other-tenant fields, internal flags.

```typescript
// src/db/dal/posts.ts
import 'server-only'
import { and, eq } from 'drizzle-orm'
import { db } from '@/db'
import { posts } from '@/db/schema'

// Explicit DTO — the ONLY shape that leaves the server. Add a field here deliberately, never by accident.
export type PostDTO = { id: string; title: string; body: string; updatedAt: string }

function toPostDTO(row: typeof posts.$inferSelect): PostDTO {
  return { id: row.id, title: row.title, body: row.body, updatedAt: row.updatedAt.toISOString() }
}

export async function updatePostOwnedBy(
  postId: string,
  userId: string,                       // authorization is a query parameter, not an afterthought
  data: { title: string; body: string },
): Promise<PostDTO | null> {
  const [row] = await db
    .update(posts)
    .set(data)
    .where(and(eq(posts.id, postId), eq(posts.ownerId, userId)))  // authZ in the WHERE clause
    .returning()
  return row ? toPostDTO(row) : null
}
```

---

## Security checklist — the authoritative gate

The **security-reviewer** agent runs this list against every diff that touches this surface and **blocks the PR unless every applicable item holds**. Native `/security-review` is the fallback for routine, non-flagged PRs. Each item applies only if the relevant library is used (PREFER-not-mandate) — but where the library is used, the item is mandatory.

- [ ] **authN present** on every Server Action and route handler (real session, resolved server-side — never a payload-supplied id/role).
- [ ] **authZ is row-ownership + role**, enforced in the SQL `WHERE` clause — not merely "is logged in", not fetch-then-compare in app code.
- [ ] **Zod-parse before any DB / Redis / external call**, on every trust boundary (args, `request.json()`, webhook responses, env).
- [ ] **Write schemas `.pick()` only client-settable fields** — no `id` / `ownerId` / timestamp / role over-posting.
- [ ] **DB access only through the `server-only` DAL** — no ad-hoc Drizzle in routes/actions/components.
- [ ] **No raw Drizzle rows returned to the client** — every response goes through an explicit DTO.
- [ ] **Mutations and auth attempts are rate-limited**, keyed by userId else IP, and the limiter **fails closed**.
- [ ] **Env only via the validated module** — no bare `process.env` reads, no secret in a `NEXT_PUBLIC_*` var.
- [ ] **Schema change ships WITH its committed migration** — no `drizzle-kit push`, no migrate at boot or in the request path.
- [ ] **Redis keys are namespaced + versioned + TTL'd** (`app:<entity>:<id>:v1`); losing Redis degrades, never corrupts.
- [ ] **DB/Redis errors caught and logged server-side**, generic message to the client (no raw driver error echoed).
- [ ] **Multi-step writes wrapped in `db.transaction()`**; destructive migrations follow expand → migrate-data → contract and stay backward-compatible.
