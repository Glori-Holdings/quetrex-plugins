---
name: preview-e2e
description: Stand up an EPHEMERAL, production-fidelity preview and run Playwright E2E against its live URL, then tear it ALL down. Use in QA when a task changes user-facing behavior, Server Actions, routes, or data flow — async Server Components and the RSC/client boundary can only be proven end-to-end. An ephemeral per-branch Fly app + a fresh seeded Neon branch. Teardown is mandatory — never leak a Fly app or a Neon branch.
allowed-tools: Bash, Read, mcp__playwright
---

# Preview E2E

QA's live-URL gate. Vitest cannot render **async** Server Components and `next build` cannot exercise auth, Server Actions, Redis, or a real Postgres round-trip. This skill provisions a throwaway production build wired to a throwaway database, drives Playwright against its **live URL**, proves each acceptance test genuinely fails when the feature breaks, then destroys everything.

**Golden rule: never leak.** Every provisioned Fly app and Neon branch is torn down in a `trap`, even on failure or interrupt. A dangling preview app burns money and a dangling Neon branch counts against the project's branch quota. End every run with the §6 leak audit.

**The preview is an ephemeral Fly app** — the same standalone Docker image you ship to prod, wired to a fresh seeded Neon branch. That is the only path; there is no non-Fly alternative.

---

## 0. Preconditions (read, don't guess)

- `.quetrex/verify.json` and the project `.claude/CLAUDE.md` `## Verification` section are the source of truth for scripts. This skill runs **after** `pnpm verify` is green locally — the preview proves runtime behavior verify structurally can't reach.
- **`FLY_API_TOKEN` is per-company, sourced inline, never `fly auth login`.** Grep the var from the project vault / `.env.local` (the name can change per project) into a shell var and pass it inline on every `fly` call. Never persist it, never echo it.
  ```bash
  TOK=$(grep -E '^FLY_API_TOKEN=' .env.local | cut -d= -f2- | tr -d '"')
  [ -n "$TOK" ] || { echo "No FLY_API_TOKEN in vault"; exit 1; }
  FLY_API_TOKEN="$TOK" fly status --app "$FLY_APP" >/dev/null 2>&1 || true   # confirm token can see the org
  ```
- **Neon** needs `NEON_API_KEY` and the project id. Use `neonctl` (`pnpm dlx neonctl@latest`). The base branch to fork is the project's staging/preview branch, never `production`.
- Required build/runtime inputs (pull from the vault, never hardcode):
  - `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` — **must** be a pinned value passed as a Docker **build ARG** (not just runtime env). Multi-machine App Router apps otherwise fail Server Actions non-deterministically ("Failed to find Server Action"). Pin the SAME key for the whole preview.
  - Any `NEXT_PUBLIC_*` — inlined at build time → passed as `--build-arg`, not runtime secret. The preview URL is deterministic from the app name, so `NEXT_PUBLIC_APP_URL` is known before deploy.
  - `UPSTASH_REDIS_REST_URL` / `UPSTASH_REDIS_REST_TOKEN` (the Upstash HTTP client, running on Fly). Use a **preview-namespaced** key prefix so ephemeral traffic never collides with staging (`app:rl:preview:<branch>`).

Name everything deterministically off the branch/PR so a re-run reuses (or cleanly replaces) rather than piling up:
```bash
SLUG=$(git rev-parse --abbrev-ref HEAD | tr '/_' '--' | tr -cd 'a-z0-9-' | cut -c1-30)
FLY_APP="${APP_BASE}-preview-${SLUG}"        # e.g. acme-preview-feature-billing
NEON_BRANCH="preview/${SLUG}"
PREVIEW_URL="https://${FLY_APP}.fly.dev"
```

---

## 1. Fresh seeded Neon branch FIRST (app needs its URL to boot)

Branch off staging so you get a real, populated schema baseline, then apply this branch's migrations and seed deterministic fixtures the E2E asserts against.

```bash
export NEON_API_KEY   # from vault
NEON_PROJECT=<project-id>

pnpm dlx neonctl@latest branches create \
  --project-id "$NEON_PROJECT" --name "$NEON_BRANCH" --parent staging

# Two URLs — pooled for the app runtime, DIRECT/unpooled for migrations (never mix them):
POOLED=$(pnpm dlx neonctl@latest connection-string "$NEON_BRANCH" --project-id "$NEON_PROJECT" --pooled)
DIRECT=$(pnpm dlx neonctl@latest connection-string "$NEON_BRANCH" --project-id "$NEON_PROJECT")

# Apply THIS branch's committed migrations against the DIRECT url, then seed against it:
DATABASE_URL_UNPOOLED="$DIRECT" pnpm exec drizzle-kit migrate
DATABASE_URL="$DIRECT" pnpm db:seed        # deterministic fixtures the E2E specs expect
```
Migrations run via committed `drizzle-kit migrate` files only — never `push`, never migrate-at-boot in a preview you're about to assert against. If `drizzle-kit migrate` errors here, the schema-change discipline is broken; fail the preview now, not in Playwright.

---

## 2. Provision + deploy the ephemeral Fly app (the standalone image)

Create the app, stage its runtime secrets, then deploy the **same multi-stage standalone Docker image** the project ships to prod — the preview must be production-fidelity, not `next dev`.

```bash
FLY_API_TOKEN="$TOK" fly apps create "$FLY_APP" --org "$FLY_ORG"

# Runtime secrets (staged so the app doesn't boot before deploy). Pooled URL for the app;
# DIRECT url for the release_command migration; Upstash HTTP creds; the pinned encryption key.
FLY_API_TOKEN="$TOK" fly secrets set --app "$FLY_APP" --stage \
  DATABASE_URL="$POOLED" \
  DATABASE_URL_UNPOOLED="$DIRECT" \
  UPSTASH_REDIS_REST_URL="$UPSTASH_REDIS_REST_URL" \
  UPSTASH_REDIS_REST_TOKEN="$UPSTASH_REDIS_REST_TOKEN" \
  NEXT_SERVER_ACTIONS_ENCRYPTION_KEY="$ACTIONS_KEY"

# Deploy. Encryption key + every NEXT_PUBLIC_* MUST also be build ARGs (inlined at build).
# --ha=false: one machine is plenty for a preview. --strategy immediate: no rolling wait for a throwaway.
FLY_API_TOKEN="$TOK" fly deploy --app "$FLY_APP" \
  --ha=false --strategy immediate \
  --build-arg NEXT_SERVER_ACTIONS_ENCRYPTION_KEY="$ACTIONS_KEY" \
  --build-arg NEXT_PUBLIC_APP_URL="$PREVIEW_URL"
```

The Fly `release_command` (`node ./drizzle/migrate.js`, DIRECT url) runs on the new image before traffic shifts — a non-zero exit **aborts the deploy**, which is correct: a preview whose migration failed must never serve. (§1 already applied them; the release_command is the same forward-only path the prod deploy uses, exercised here for real.)

Gate on health before touching Playwright — don't test a still-booting app:
```bash
for i in $(seq 1 30); do
  curl -fsS "$PREVIEW_URL/api/health" && break
  sleep 4
  [ "$i" -eq 30 ] && { echo "preview never became healthy"; exit 1; }
done
```

---

## 3. Run Playwright against the LIVE preview URL

Point Playwright at the deployed URL — **no local `webServer`** (that's for the local verify build). The config must skip its `webServer` when `PLAYWRIGHT_BASE_URL` is set:

```typescript
// playwright.config.ts — remote-aware
const base = process.env.PLAYWRIGHT_BASE_URL
export default defineConfig({
  use: { baseURL: base ?? 'http://localhost:3000', trace: 'on-first-retry' },
  webServer: base ? undefined : { command: 'pnpm start', url: 'http://localhost:3000', reuseExistingServer: !process.env.CI },
})
```

```bash
PLAYWRIGHT_BASE_URL="$PREVIEW_URL" pnpm exec playwright test --reporter=line
rc=$?
```

**Assert both halves of the spec:**
- **Acceptance criteria (happy path):** every criterion from the task's spec, exercised through the real UI/API against real seeded data — including async Server Components (which only render here).
- **Unhappy paths (required, not optional):** unauthenticated request → 401/redirect; wrong-owner/insufficient-role → 403 (authZ, not merely "logged in"); invalid payload → Zod 400, no partial write; rate-limited endpoint → 429 after the window, and **auth fails closed** (Redis unreachable ⇒ denied, never allowed). These are the security floor; a preview that only proves the happy path has proven nothing about safety.

Prefer accessibility-snapshot assertions over pixel screenshots. Read console/network on failure to distinguish a server 500 from a client error.

---

## 4. Prove each test can FAIL (negative control — do NOT skip)

A green E2E that cannot go red is worthless — it may be asserting on nothing, or matching a substring that's always present. QA does not trust a spec until it has watched it fail for the right reason.

For **every new/changed acceptance test**, demonstrate red-before-green:
- **Preferred (mutation against the live preview):** perturb the running system so the feature is genuinely broken, re-run just that spec, confirm it FAILS, then restore:
  - flip a seeded fixture in the Neon branch to a value that violates the assertion (`DATABASE_URL="$DIRECT" psql -c "…"`), or
  - hit the endpoint with a tampered id / stripped auth cookie and confirm the authZ/validation spec catches it, or
  - point the spec's expected text at a known-wrong string and confirm it reports a mismatch (not a load error masquerading as a failure).
- Confirm the failure message names the real assertion, then revert the perturbation and re-run to green.

Record, per acceptance criterion: **PASS on real preview + demonstrated FAIL under mutation.** A criterion with only a green run is not verified. If a spec stays green even when you break the feature, the test is wrong — fix the test before trusting the feature.

---

## 5. Teardown — MANDATORY, in a trap, always

Wrap the whole run so teardown fires on success, failure, and interrupt. **Both** resources must go:

```bash
teardown() {
  set +e
  FLY_API_TOKEN="$TOK" fly apps destroy "$FLY_APP" --yes 2>/dev/null
  pnpm dlx neonctl@latest branches delete "$NEON_BRANCH" --project-id "$NEON_PROJECT" 2>/dev/null
}
trap teardown EXIT INT TERM
```
Put the trap in place **before** §2 provisioning so a mid-provision crash still cleans up. Deleting the Neon branch also drops the ephemeral rate-limit/cache data; if Upstash keys were written outside a per-branch prefix, `DEL` the `app:*:preview:<branch>:*` namespace too. Never leave `--stage`d secrets on a destroyed app (destroy removes them with the app).

The preview's pass/fail is decided by Playwright's exit code from §3 (and the §4 negative-control result), **not** by teardown succeeding — but teardown must still run. Report the real `rc`.

---

## 6. Leak audit — prove it's clean

After teardown, confirm nothing survived (a re-run must start from zero):
```bash
FLY_API_TOKEN="$TOK" fly apps list | grep -F "$FLY_APP" && echo "LEAK: fly app survived" || echo "fly clean"
pnpm dlx neonctl@latest branches list --project-id "$NEON_PROJECT" | grep -F "$NEON_BRANCH" \
  && echo "LEAK: neon branch survived" || echo "neon clean"
```
If either survived, destroy it explicitly and re-audit. Do not report the task green while a preview resource is leaking.

---

## Gotchas (all hit in practice)

- **"Failed to find Server Action" intermittently** → `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` wasn't a build ARG (or differed between machines). Pin it, pass it as `--build-arg`, keep it identical across the preview.
- **App boots but every DB call hangs/errors** → app pointed at the DIRECT (unpooled) url, or migrations at the pooled one. App = `--pooled`; migrations = DIRECT.
- **Playwright silently spins up a local server** → `PLAYWRIGHT_BASE_URL` not set, so the config's `webServer` branch ran. Set it; the config must return `undefined` webServer when it's present.
- **Green suite but the feature is broken** → you skipped §4. A test that can't fail isn't a test.
- **Neon branch quota exceeded on next run** → a prior run leaked. Run §6; delete stragglers; move the teardown trap earlier.
- **`fly` can't see the app / org** → you fell back to `fly auth login`. Always inline `FLY_API_TOKEN="$TOK"`; confirm with `fly status --app "$FLY_APP"` first.
- **Health check passes but pages 500** → seed didn't run or ran against the wrong url. Re-check §1 ran `db:seed` against `$DIRECT` and migrations succeeded.
