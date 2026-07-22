---
name: drizzle-migrate
description: >
  Apply a Drizzle schema change to Postgres the ONLY safe way: generate a
  migration, STOP and show the raw SQL diff for human review, then apply it with
  drizzle-kit migrate against the direct (unpooled) URL. Use whenever a task
  edits src/db/schema/*.ts, adds/drops/renames a column or table, or changes a
  type/constraint/index. NEVER drizzle-kit push. Destructive changes go through
  expand → migrate-data → contract across separate deploys.
allowed-tools: Bash, Read, Edit
---

# Drizzle Migrate

The Drizzle schema (`src/db/schema/*.ts`) is the **single source of truth**. The
**only** path from a schema edit to Postgres is a committed migration file
produced by `drizzle-kit generate` and applied by `drizzle-kit migrate`. This
skill is the plan → validate → execute procedure for that path.

## The one rule that outranks everything

**`drizzle-kit push` is banned.** It diffs the live DB against your schema and
mutates it in place with no reviewable artifact and no history — the single most
common cause of a Drizzle production incident. It is blocked by `deny-guard.sh`
(so it dies even in a `bypassPermissions` developer) and denied in settings.
Never reach for it, never suggest it, never "just this once" in dev. If you want
to see what would change, you `generate` and read the SQL — that is the review.

Corollary bans:
- **Never edit an already-applied migration file.** History is append-only. A
  mistake in a shipped migration is fixed by a *new* migration, never by rewriting
  the old one — editing it desyncs every environment that already ran it.
- **Never run migrations at app boot or in the request path.** Migrations run as
  an explicit step (`pnpm db:migrate`) or a deploy `release_command`, never on
  import.
- **`src/db/migrations/**` is generated output.** Do not hand-author the `.sql`;
  edit the schema and regenerate. (The only exception is the deliberate
  hand-written data-migration step in a destructive sequence — see below.)

---

## Step 0 — Confirm the URL split before you touch anything

Migrations and the app runtime use **different** Neon hosts:

- **App runtime** → the **pooled** host (`...-pooler...`), via `DATABASE_URL`.
- **Migrations / `drizzle-kit`** → the **direct/unpooled** host, via
  `DATABASE_URL_UNPOOLED`. DDL over the pooler can hang or fail on advisory
  locks.

`drizzle.config.ts` MUST point migrations at the unpooled URL:

```typescript
// drizzle.config.ts
import { defineConfig } from 'drizzle-kit'
import { env } from '@/env'
export default defineConfig({
  dialect: 'postgresql',
  schema: './src/db/schema',
  out: './src/db/migrations',
  dbCredentials: { url: env.DATABASE_URL_UNPOOLED }, // direct host — NOT the -pooler URL
  strict: true,
  verbose: true,
})
```

Verify before generating:

```bash
grep -n 'DATABASE_URL_UNPOOLED' drizzle.config.ts \
  || echo 'STOP: drizzle.config.ts is not on the unpooled URL — fix it first.'
```

If the config reads `DATABASE_URL` (the pooled one), stop and fix it before any
generate/migrate. Confirm the target env is **dev/staging**, never production,
unless a human has explicitly asked for a production migration.

---

## Step 1 — PLAN: generate the migration (writes SQL, touches nothing live)

`generate` only diffs `schema/*.ts` against the recorded migration history and
writes a new `.sql` + snapshot into `src/db/migrations/`. It does **not** connect
to or change any database.

```bash
pnpm db:generate            # drizzle-kit generate
```

Then confirm exactly one new migration was produced and capture its path:

```bash
git status --porcelain src/db/migrations
NEW_SQL=$(git ls-files --others --exclude-standard src/db/migrations/*.sql | tail -n1)
echo "New migration: ${NEW_SQL:-<none>}"
```

If `generate` produced **no** new file, the schema already matches history —
nothing to do, stop here. If it produced more than one, something is out of sync;
investigate before continuing.

If drizzle-kit asks to disambiguate a rename ("is this a rename or a
drop+create?"), a wrong answer here silently **deletes a column's data**. Do not
guess — if it is a rename, say rename; if you are unsure, stop and ask the human.

---

## Step 2 — VALIDATE: STOP and show the human the raw SQL

This is a **hard stop**. Do not proceed to `migrate` until a human has seen and
approved the exact SQL. Print it raw — never paraphrase:

```bash
cat "$NEW_SQL"
```

Present it and explicitly call out any of these, because they are the ones that
lose data or take locks:

- `DROP TABLE` / `DROP COLUMN` — **destructive**, data gone. Requires the
  expand→migrate→contract path below, not a bare apply.
- `ALTER COLUMN ... SET NOT NULL` on an existing column — fails if any row is
  null; must be backfilled first.
- Type narrowing / `ALTER COLUMN ... TYPE` — can fail on incompatible data or
  rewrite the whole table.
- New `UNIQUE` / non-nullable column without a default — fails on existing rows.
- `CREATE INDEX` (non-`CONCURRENTLY`) on a large table — takes a write lock.

State plainly: "This migration is **safe / destructive**; here is why." If
destructive, do **not** apply it as-is — go to the expand→migrate→contract
section. If safe, ask for the go-ahead, then continue.

---

## Step 3 — EXECUTE: apply, then commit the artifact

Only after approval:

```bash
pnpm db:migrate             # drizzle-kit migrate — applies over DATABASE_URL_UNPOOLED
```

`migrate` runs pending files inside a transaction and records them in the
`__drizzle_migrations` table, so it is idempotent and re-run-safe. Then prove the
DB and schema now agree and that no uncommitted drift remains:

```bash
pnpm db:check               # drizzle-kit check — migration history is consistent
pnpm db:drift               # scripts/db-drift.sh — schema.ts has no ungenerated change (read-only)
```

Both must exit 0. Finally, **commit the generated files with the schema change in
the same commit** — the migration and the schema that produced it travel together:

```bash
git add src/db/schema src/db/migrations
git commit -m "feat(db): <change> + migration"
```

A schema edit committed *without* its migration is exactly what `db:drift` exists
to catch in CI — never split them.

---

## Destructive changes — expand → migrate → contract

Never drop or rename a column/table in the same deploy that stops using it. The
old code is still serving traffic while the new image rolls; a column removed
under it throws. Split every destructive change into separate, individually
shippable migrations:

1. **Expand** — additive only. Add the new column/table (nullable or defaulted).
   Deploy. Old and new code both work.
2. **Migrate data** — backfill the new shape from the old. This is the one place a
   **hand-written** SQL step is legitimate: create an empty migration
   (`drizzle-kit generate --custom --name backfill_<thing>`) and write the
   `UPDATE ... / INSERT ... SELECT` yourself, in batches for large tables. Deploy
   / run it. Then, if the column must become `NOT NULL`, add that constraint in a
   *following* migration once every row is populated.
3. **Contract** — only after all code paths read/write the new shape and the old
   column is provably unused, generate the `DROP`. Deploy.

Rename = expand (add new) → backfill → dual-write window → contract (drop old);
never a bare `ALTER ... RENAME` on a live table. Test the full sequence against a
staging branch before it touches production, and keep each step
**backward-compatible** — deploy `release_command` migrations are forward-only,
so the new migration must be safe against the *previous* running image.

---

## Quick reference

| Situation | Do |
|---|---|
| Edited `schema/*.ts` | `db:generate` → **show SQL** → approve → `db:migrate` → `db:check` + `db:drift` → commit both |
| Want to preview a change | `db:generate` and read the `.sql` — never `push` |
| `generate` made no file | Schema matches history; nothing to apply |
| Rename prompt from drizzle-kit | Answer truthfully; if unsure, stop and ask (wrong answer drops data) |
| Drop / rename / narrow / new NOT NULL | expand → migrate-data → contract, across separate deploys |
| Mistake in a shipped migration | Fix forward with a **new** migration — never edit the applied one |
| Config on `DATABASE_URL` (pooled) | Stop; point drizzle.config at `DATABASE_URL_UNPOOLED` first |

## Never

- `drizzle-kit push` — anywhere, ever (blocked by `deny-guard.sh`).
- Edit or delete an already-applied migration file.
- Run `migrate` before a human has seen the raw SQL.
- Run migrations at boot or in a request handler.
- Apply a `DROP`/destructive migration in the same deploy that stops using the
  column.
- Point `drizzle-kit` at the pooled (`-pooler`) URL.
