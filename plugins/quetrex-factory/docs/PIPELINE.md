# PIPELINE — The Quetrex Factory Engine

**Status:** authoritative. This document defines the pipeline that runs a task from
plan to auto-merge. `commands/quetrex-task-build.md` *enacts* this state machine; every
other command that builds code (`quetrex-task-rework`) re-enters it. When this doc and a
command disagree, this doc wins — fix the command.

**Design axiom (repeated from the system blueprint):** every gate in this pipeline is
enforced by a **hook or an on-disk artifact a hook reads**, never by an agent's prose.
Agents navigate; deterministic checkers decide. A stage "passes" only when it has
written its `.quetrex/*` artifact and that artifact is green — the next stage reads the
artifact, not the previous stage's chat output. "Done" is mechanically impossible while
any artifact is red.

**Merge policy (read this first).** A clean review **auto-merges — automatically, with no
human in the loop.** Issues send the work back through the pipeline as **REWORK**.
Genuinely uncertain or risky diffs **escalate to a human**, who merges on GitHub. The
*only* manual gate in the whole system is a **PRODUCTION deploy**. There is no
"human approves every PR" step and no merge-approval artifact — the reviewer's
`review-verdict.json` is the sole source of truth for whether a PR may merge.

---

## 0. The truth store — `./.quetrex/`

Every stage communicates through machine-readable artifacts under the repo root. Hooks
resolve `$ROOT` from `git rev-parse --show-toplevel` (worktree-safe), never from a `cwd`
guess. See `docs/ARTIFACTS.md` for the full schema; the pipeline-relevant subset:

| Artifact | Written by | Read by | Meaning |
|---|---|---|---|
| `project.json` | `/quetrex-init` | orchestrator | repo↔project binding |
| `verify.json` | `/quetrex-init` | verify-gate, qa, qa-verify skill | **single source of truth** for the ordered verify chain (`.verify[]`), coverage threshold, `.format` cmd |
| `state.json` | orchestrator | orchestrator, git-workflow | `{task, route, stage, qa_iter, review_iter, security_iter}` |
| `plan/<TASK>.json` | architect | developer, qa, reviewer, security-reviewer, git-workflow | ownership map, acceptance criteria, security surface, verify chain, flags |
| `verify-ledger.jsonl` | verify-gate (append-only) | verify-gate, git-workflow, merge-gate | every verify run `{ts,cmd,cwd,exit,tail20,sha}` — `sha` is the `git rev-parse HEAD` at run time, so the merge gate can commit-pin green to the PR head |
| `verify-attempts` | verify-gate | verify-gate | integer self-heal counter; reset to 0 on green |
| `security-findings.json` | reviewer (via `/security-review`) | merge-gate, orchestrator | `[{severity,category,cwe,file,line,exploit,status}]` |
| `review-verdict.json` | reviewer (fresh context) | merge-gate, orchestrator | `{verdict:"AUTO_MERGE"\|"REWORK"\|"ESCALATE_HUMAN", confirmed:[…], plausible:[…]}` — the sole merge authority |
| `ESCALATION` | verify-gate / orchestrator | merge-gate, orchestrator | present ⇒ a bounded loop hit its cap; blocks merge, surfaces to user |

**Rule of the store:** a stage that has not written its artifact has not passed,
regardless of what it said in chat. git-workflow and the merge hook read files; they do
not read the transcript.

---

## 1. Routing — the entry decision (SPEED pillar)

Before any stage runs, the task is sized. Sizing is deterministic and happens in the
`right-size-router.sh` hook on `UserPromptSubmit` (sub-100ms, no model call in the common
case). The router injects an authoritative `ROUTE:` line as `additionalContext`; the
orchestrator **does not re-decide** — it obeys the injected route.

### 1.1 Classification

| Tier | Trigger signals | Path taken |
|---|---|---|
| **TRIVIAL** | typo/comment/copy fix, single-value config change, dependency version bump, rename within one file, docs-only, single-function edit in one named file | single agent, direct edit in the working tree — **no** worktree, architect, parallel devs, or reviewer |
| **STANDARD** | everything not caught by the TRIVIAL or COMPLEX signal sets | one worktree, one developer + qa; reviewer only if security paths are touched |
| **COMPLEX** | any one of: new dependency; schema/DB migration; >3 files or crosses layers (api+ui+db); ambiguous/underspecified ask; public-API change; prompt/paths touch **auth / authz / payment / crypto / secrets / infra / CI** | full architect → parallel developers → qa → preview+E2E → reviewer → git-workflow |

### 1.2 Two rules that keep the fast path safe

1. **Conservative round-up.** Low-confidence or contradictory signals round **up** one
   tier. Mis-sizing a hard task as trivial ships silent bad code; the reverse only wastes
   tokens. If genuinely ambiguous the router emits `AMBIGUOUS`, and the orchestrator
   spawns the `triage` agent (haiku) for one token: `TRIVIAL|STANDARD|COMPLEX`.
2. **Hard security override.** Any path matching `auth|authz|secret|migration|infra|ci|payment`
   forces **minimum STANDARD** and forces `security_review_required=true`, regardless of
   score and regardless of the architect's own judgment. Security is mandatory
   **by detection**, not by discretion.

### 1.3 Ceremony is optional; the floor is not

The fast path lowers *orchestration* cost, never the *safety* floor. On **every** tier —
including TRIVIAL — these hooks still fire:

- `verify-gate.sh` (Stop + SubagentStop) — no red finish
- `deny-guard.sh` — destructive-command deny
- `secret-scan.sh` — secret/entropy deny on Write/Edit **and** Bash
- `enforce-branch.sh` — no commit on `main`/`master`
- `merge-gate.sh` — artifact-gated merge boundary

A TRIVIAL edit that breaks the build is blocked by verify-gate exactly like a COMPLEX one.

---

## 2. The state machine

```
route (hook) ──TRIVIAL──▶ [single agent: edit → verify-gate green] ──▶ PR ──▶ auto-merge (clean) / escalate
             ──STANDARD─▶ architect(light) → developer → qa ─┐
             ──COMPLEX──▶ architect → developers(∥ disjoint) → qa ─┐
                                                                    ▼
                                        ┌──────── qa proves green (ledger) ────────┐
                                        │  fail → developer (bounded: qa_iter ≤3)  │
                                        └──────────────┬───────────────────────────┘
                                                       ▼
                              preview deploy (EPHEMERAL) + E2E against the live preview
                                 fail → developer (bounded)   [teardown MANDATORY]
                                                       ▼
                             reviewer — FRESH context (native /review + /security-review)
                                        writes review-verdict.json
                                REWORK         → developer (bounded: review_iter ≤3)
                                ESCALATE_HUMAN → pause; a human merges on GitHub
                                                       ▼ AUTO_MERGE
                                              git-workflow  (artifact gate → squash PR)
                                                       ▼
                             merge-gate (commit-pinned, verdict=AUTO_MERGE) → AUTO squash-merge to main
                                                       ▼
                                    worktree-workflow teardown (audit: no dangling worktree/branch/PR)
                                                       ▼
                          (PRODUCTION deploy stays a MANUAL gate — /quetrex-deploy production)
```

---

## 3. Stage-by-stage contract

Each stage below states: **entry** (what must be true to run it), **agent + I/O
artifacts**, **the gate that decides pass/fail**, and the **exit transition**. A stage
never advances on chat — only on its written, green artifact.

### 3.0 TRIVIAL fast path (bypasses stages 3.1–3.6)

- **Entry:** `ROUTE: TRIVIAL`.
- **Do:** a single agent (sonnet, direct Edit in the working tree) makes the change.
  No worktree, no architect, no ownership map, no parallel devs, no separate QA agent,
  no reviewer.
- **Gate:** `verify-gate.sh` fires on that agent's Stop. It runs the `verify.json` chain
  by exit code; a red chain blocks the finish (bounded self-heal, §4). The agent cannot
  report "done" while any command is non-zero.
- **Exit:** if the change touches the repo, open a squash PR (git-workflow may be invoked
  directly, or the orchestrator opens it). A clean docs/comment-only change **auto-merges**
  once the verify ledger is green (§6); if anything looks risky it escalates to a human.
  A change with no shippable artifact may skip the PR only if the project does not require
  a PR for that path — otherwise it PRs like anything else.

TRIVIAL skips ceremony, not gates. The four floor hooks (§1.3) all fire.

### 3.1 architect — the plan (STANDARD light / COMPLEX full)

- **Entry:** `ROUTE: STANDARD` or `COMPLEX`. (STANDARD gets a *light* plan — a single
  workstream, minimal ownership map; COMPLEX gets the full parallel decomposition.)
- **Agent:** `architect` (opus, high). Read/Grep/Glob + Write scoped to the plan file.
- **IN:** task id, refined spec, repo snapshot, path to `.quetrex/verify.json`. The
  delegation message **restates all load-bearing rules** — subagents are context-blind.
- **OUT:** `.quetrex/plan/<TASK>.json` (see `docs/ARTIFACTS.md` for the schema):
  `workstreams[]`, a total `ownership` map, `acceptance[]` (Given/When/Then + numeric
  `measure`), `security_surface[]`, `verify[]`, `security_review_required`, `db_migration`.
- **Gate (mechanical contract rules):**
  1. `ownership` is a **total function over every touched file with zero overlap** — two
     workstreams may not name the same path. Overlap ⇒ plan rejected, re-run.
  2. Every acceptance criterion is Given/When/Then with a **numeric `measure`**. Any
     criterion containing an unquantified adjective (`fast`, `secure`, `reasonable`) ⇒
     the architect returns **`needs_clarity`** (the one valid early exit — §5) instead of
     a plan.
  3. `security_review_required` is advisory; the router's path-detection can force it on
     (§1.2) and the architect cannot turn it off.
- **Exit:** valid plan written → developer(s). `needs_clarity` → pause, ask the user.

### 3.2 developer(s) — implementation (parallel, disjoint)

- **Entry:** a valid `plan/<TASK>.json` exists.
- **Agent:** `developer` (sonnet, high, `isolation: worktree`). On COMPLEX, **one
  developer per workstream, all in parallel**, each in its own worktree on a sub-branch
  (`feature/<desc>-<workstream>`). Each is told: *you may write ONLY files whose ownership
  maps to your workstream.* Disjoint ownership guarantees no write conflicts.
- **IN:** `plan/<TASK>.json` + the single workstream id it owns. Not the reasoning of
  other developers.
- **OUT:** commits on its sub-branch. **Definition of Done — all must hold:**
  (a) every owned acceptance criterion has a test that **fails before, passes after**;
  (b) the full `verify` chain exits 0 locally;
  (c) no secret literals; all external inputs validated; every user-scoped query carries
  an ownership predicate; no whole-body binding to models.
- **Gate:** the developer's own **SubagentStop verify-gate** runs the chain by exit code.
  (b) is not a claim — the gate blocks the subagent from finishing while the chain is red
  (bounded self-heal, §4). A developer physically cannot end green on a red tree.
- **Exit:** all developers green → regular-merge sub-branches into the feature branch →
  qa. (Merge order is arbitrary because ownership is disjoint; conflicts are impossible by
  construction — a conflict means the architect's map overlapped, a §3.1 gate failure.)

### 3.3 qa — prove green, independently (EXCELLENT CODE pillar)

- **Entry:** developer work merged onto the feature branch.
- **Agent:** `qa` (sonnet, high). **Has Write/Edit** — QA authors its own tests; it does
  not merely re-run the developer's suite.
- **IN:** `plan/<TASK>.json`, the acceptance criteria, and the developer's **diff** (via
  `git diff`). It does **not** receive the developer's reasoning transcript
  (anchoring prevention).
- **OUT:** additional, independently-authored adversarial/edge tests, then a green
  `verify-ledger.jsonl` run. Verification ladder, in order:
  `grep/static → typecheck → lint → build → test (real exit codes) →
  changed-file coverage ≥ threshold (`verify.json`, default 80%) →
  mutation (`npx stryker`) where configured`.
- **Gate:**
  1. The ledger's last run must be all-exit-0 (verify-gate writes the ledger; git-workflow
     and the merge hook read it).
  2. **Vacuous-suite guard:** every changed unit must have ≥1 test with a **non-trivial
     assertion**. A suite that passes with zero assertions on changed code is a **FAIL**,
     not a pass — QA must reject it.
  3. QA ends by explicitly listing **what it did NOT verify** (honest coverage boundary).
- **Exit:** green ledger + coverage met + no vacuous suites → preview + E2E. Red or vacuous
  → developer (bounded, `qa_iter`, §4).

### 3.3b preview deploy + E2E — prove it runs live (before review)

- **Entry:** qa green.
- **Do:** deploy the branch to an **ephemeral preview environment** and run the E2E suite
  **against the live preview**, not against a mock. Preview topology:
  - **Fly.io (primary)** — a per-branch app backed by a **seeded Neon branch** database.
  - **Vercel (secondary)** — for stacks/targets where it is the natural preview host.
- **OUT:** the E2E run appends to `verify-ledger.jsonl` like any other verify command
  (real exit codes, commit-pinned `sha`), so a red E2E is a red ledger and cannot pass.
- **Gate:** E2E green against the live preview. Red → developer (bounded, `qa_iter`, §4).
- **Teardown is MANDATORY.** The ephemeral Fly app and the seeded Neon branch are torn
  down when the run ends, pass or fail. A leaked preview app/DB branch is a defect.
- **Exit:** green live E2E → reviewer.

### 3.4 reviewer — refute the diff in a FRESH context (adversarial)

- **Entry:** qa green **and** live-preview E2E green.
- **Agent:** `reviewer` (opus, xhigh) running in a **fresh context** — it sees the diff,
  not the build transcript. It drives the **native `/review` and `/security-review`**
  slash commands: `/review` for correctness/logic/architecture, `/security-review` for the
  OWASP pass. Read-only (`disallowedTools: Write, Edit` for the review itself; the
  `/security-review` step writes only the findings artifact; Bash is read-only — `git diff`,
  running the existing suite).
- **IN:** the diff + minimal spec + acceptance criteria **only**. Explicitly **not** the
  developer's or QA's narrative. Function-level and dependency context around the hunks is
  provided.
- **Stance:** assume the diff is broken. **REFUTE it.** Construct concrete failing inputs.
- **OUT:**
  - `.quetrex/review-verdict.json` — `{verdict, confirmed:[…], plausible:[…]}`, plus a
    `ReportFindings` call. Each finding carries `file:line` + a reproducible
    `failure_scenario`, tagged `CONFIRMED` (a repro was built and run) or `PLAUSIBLE`
    (reasoned but not executed).
  - `.quetrex/security-findings.json` — produced by the `/security-review` pass (§3.5).
- **Gate — the verdict decides the merge (§6):**
  - **`AUTO_MERGE`** — no CONFIRMED correctness/security defect survives and nothing about
    the diff is judged uncertain or risky. The PR merges automatically.
  - **`REWORK`** — ≥1 CONFIRMED correctness/security defect survives. Back to the pipeline.
  - **`ESCALATE_HUMAN`** — the diff is uncertain or risky in a way the reviewer will not
    auto-clear (e.g. subtle plausible-but-unproven risk, judgment call a human should own).
    A human merges it on GitHub.
  Default stance is suspicion, not approval.
- **Exit:** `AUTO_MERGE` → security-reviewer gate check (if required) then git-workflow.
  `REWORK` → developer (bounded, `review_iter`, §4). `ESCALATE_HUMAN` → pause; surface the
  PR and let a human decide/merge (§5, §7).

### 3.5 security-reviewer — mandatory when flagged/detected (SECURITY pillar)

The security pass runs as the **`/security-review` half of the fresh-context reviewer**
(§3.4). It is broken out here because its trigger and its artifact contract are their own
gate.

- **Entry:** `security_review_required == true` — set by the architect **or forced** by
  the router's path-detection (§1.2). When forced, this pass cannot be skipped.
- **IN:** the diff, the plan's `security_surface`, full dependency context on touched
  data-access / auth / input paths.
- **OUT:** `.quetrex/security-findings.json`. Runs the OWASP checklist in `docs/SECURITY.md`
  (loadable via the `security-review` skill). Each Critical/High requires a **concrete
  exploit path** (attacker input → wrong outcome) + `file:line` + CWE/OWASP-API id.
  Unsubstantiated findings are downgraded to `PLAUSIBLE` (so parameterized-query false
  positives don't gridlock merges). Unresolved findings carry `status:"open"`.
- **Gate:** any finding with `severity:"critical", status:"open"` blocks the merge —
  enforced by `merge-gate.sh` reading the artifact (§6), not by prose. It also forces the
  reviewer's verdict away from `AUTO_MERGE` (a live Critical is never auto-merged).
- **Exit:** no open Critical → git-workflow. Open Critical → `REWORK` to developer
  (bounded, `security_iter`, §4). A **CONFIRMED Critical** is also one of the three valid
  reasons to pause the whole pipeline (§5).

**database-architect note:** schema changes route through `database-architect` (opus)
*before* this pass. It authors expand→migrate→contract, forward+reverse, data-preserving
migrations with FK indexes/constraints, runs in a worktree with **no blanket
bypassPermissions** (destructive DDL passes the deny-guard like everyone else), then hands
off to qa (full chain), the live-preview E2E (§3.3b), and the security pass
(migration-safety checklist, §9 of SECURITY). Self-certification is forbidden.

### 3.6 git-workflow — the artifact-gated PR and auto-merge

- **Entry:** all prior stages passed and `review-verdict.json` is `AUTO_MERGE`.
- **Agent:** `git-workflow` (sonnet, medium — Bash + Read only).
- **IN — read from disk, not chat:**
  - `verify-ledger.jsonl` — last run all exit 0, commit-pinned to the PR head `sha`
  - `security-findings.json` — no `severity:"critical", status:"open"`
  - `review-verdict.json` — `verdict == "AUTO_MERGE"`
  - **absence** of `.quetrex/ESCALATION`
- **OUT:** a **squash PR to `main`**, which then **auto-merges** — `merge-gate.sh` permits
  the squash-merge because the verdict is `AUTO_MERGE` and all gates are green (§6). No
  human is involved on this path. If any artifact gate fails → **refuse**, write the
  failing reason to `state.json`, do not open the PR.
- **Escalated path:** when the verdict is `ESCALATE_HUMAN`, git-workflow opens the PR but
  `merge-gate` denies the auto-merge; a human merges it on GitHub, then a status-sync
  reflects the merge on the tracker.
- **Exit:** `AUTO_MERGE` PR merged automatically → teardown. `ESCALATE_HUMAN` PR opened →
  wait for a human to merge on GitHub.

---

## 4. Bounded loops — mechanical, not advisory

Every repair loop is bounded by a counter that lives on disk, so the "max 3 then escalate"
rule from `CLAUDE.md` is enforced by arithmetic, not by an agent remembering it.

**Two counter systems, both real:**

1. **`verify-attempts`** (a file). The verify-gate hook's self-heal loop. Algorithm each
   time a Stop/SubagentStop fires with a red chain:
   ```
   n = read(verify-attempts) + 1 ; write(verify-attempts, n)
   if n < 3:  block  {"decision":"block","reason":"<cmd> exited <code>. Fix and re-verify. Last 20 lines:\n<tail>"}   # exit 0
   else:      touch .quetrex/ESCALATION
              block  {"decision":"block","reason":"ESCALATE: <cmd> still red after 3 self-heal attempts. STOP self-healing. Surface to the user with this output and do not report the task done:\n<tail>"}   # exit 0
   ```
   A green chain resets the counter to 0. The counter *is* the termination mechanism, so
   the hook never loops forever — we do **not** blanket-exit on `stop_hook_active` (that
   would let a blocked agent stop red); we run every time, and the counter guarantees ≤3
   cycles.

2. **`state.json` stage counters** — `qa_iter`, `review_iter`, `security_iter`. The
   orchestrator increments the relevant counter each time it bounces work back to a
   developer from qa / E2E / reviewer / security-reviewer. On **any counter ≥ 3**: write
   `.quetrex/ESCALATION`, **stop the loop**, and surface to the user. Never loop forever.

**`ESCALATION` is load-bearing.** Once written it is read by the merge gate (§6) — red or
unresolved work **physically cannot merge** even after the agent is permitted to stop. The
orchestrator must surface the escalation to the user with the failing output and must not
report the task done.

---

## 5. Pipeline Mode — no stops, and the exits

Once the pipeline starts, run **every** stage to completion without asking for
confirmation, plan review, or approval at any intermediate point. Never ask "does this
look right?", "should I proceed?", or "want to review before continuing?". Fire-and-forget
is the product. A clean run goes all the way to an **automatic merge** with no human touch.

**The valid reasons to pause:**

1. A question **only the user can answer** — no reasonable assumption exists.
2. A **bounded loop hit its cap** (`ESCALATION` written — QA/E2E/reviewer/security 3× or
   verify-attempts 3×). Surface the failing output; do not report done.
3. A **CONFIRMED Critical** security finding.
4. A reviewer verdict of **`ESCALATE_HUMAN`** — the pipeline has done its job and handed a
   judgment call to a human, who merges the PR on GitHub. (Not a failure; the correct
   terminus for a risky-but-unrefuted diff.)

**The one early exit inside a stage:** the architect may return **`needs_clarity`** when a
task's acceptance criteria cannot be made measurable (§3.1). That bounces the task back to
refinement — it is not a pipeline failure, it is the correct terminus for an
unspecifiable ask.

**The one manual deploy gate:** shipping to **PRODUCTION** is always a human-initiated
`/quetrex-deploy production`. Auto-merge lands code on `main`; it does not deploy to prod.

Nothing else pauses the pipeline.

---

## 6. The merge gate — where "done" is finally decided

`merge-gate.sh` (PreToolUse on Bash) intercepts `gh pr merge`, `git merge` into `main`,
and `git push` to `main`. It **allows** the merge **only** when **every** condition holds:

- `.quetrex/review-verdict.json` exists and `verdict == "AUTO_MERGE"` — the sole merge
  authority. A `REWORK` or `ESCALATE_HUMAN` verdict is denied.
- `.quetrex/verify-ledger.jsonl` — last run all exit 0, **commit-pinned**: its `sha` equals
  `git rev-parse HEAD` of the PR head, so a green ledger from an earlier commit can't wave
  through new, unverified work.
- `.quetrex/security-findings.json` — no `severity:"critical", status:"open"`.
- No `.quetrex/ESCALATION` file present.

Any failure ⇒ **deny**, naming the specific failing artifact. This is the artifact-consuming
gate the standard demands: a Critical, a `REWORK`, or an `ESCALATE_HUMAN` from any stage
mechanically prevents the PR from auto-merging. There is **no** human-approval artifact to
AND in — a clean `AUTO_MERGE` verdict *is* the authorization, and an escalated verdict is
merged by a human directly on GitHub (which the gate permits only because the human, not an
agent, performs it).

---

## 7. Merge policy & teardown

- **Clean review → automatic merge.** When the reviewer writes `AUTO_MERGE` and the ledger
  is green + commit-pinned with no open Critical and no `ESCALATION`, `merge-gate` permits
  the squash-merge and git-workflow lands it **with no human in the loop**. This is the
  common path and the point of the product.
- **Issues → REWORK.** A `REWORK` verdict (or a red ledger / open Critical) sends the work
  back through the pipeline to a developer (bounded, §4). Nothing merges.
- **Uncertain/risky → ESCALATE_HUMAN.** The PR is opened and left for a human to review and
  **merge on GitHub**; a status-sync then reflects the merge on the tracker. The old
  `/quetrex-task-merge` command and the `merge-approval.json` artifact are **retired** —
  there is no separate human-approval writer; `review-verdict.json` is the source of truth.
- **Production deploy is the one manual gate.** Merging to `main` is automatic;
  **deploying to production** is always human-initiated via `/quetrex-deploy production`.
- **Teardown is mandatory.** After merge, the `worktree-workflow` skill governs cleanup: no
  dangling worktree, no open/unmerged PR, no stale local or remote branch, and no leaked
  ephemeral preview app / Neon branch (§3.3b). Run its final audit at the end of any
  multi-unit effort. A left-behind worktree/branch/PR/preview is a defect.

---

## 8. Branching rules (enforced by `enforce-branch.sh`)

- All work on feature branches — **never commit directly to `main`/`master`.**
- One branch per unit of work: `feature/<short-description>`.
- Sub-branches for parallel developers: `feature/<desc>-<workstream>`
  (e.g. `-api`, `-ui`, `-db`).
- Regular-merge sub-branches → feature branch. **Squash-merge** feature branch → main.
- Commit inside a worktree with `git -C <worktree>` so the enforce-branch hook resolves the
  worktree's branch (via `git -C <path> rev-parse --abbrev-ref HEAD`) instead of blocking.
- `enforce-branch.sh` matches the **actual command being run**, not the literal substring
  "git commit" appearing in echoed docs, and allows the first commit on a freshly-created
  branch. It uses `permissionDecision:"ask"` (not hard deny) so a human can intentionally
  override.

---

## 9. What each pillar's guarantee reduces to (traceability)

| Pillar | Guaranteed in this pipeline by |
|---|---|
| **1 — Excellent code** | verify-gate on **Stop AND SubagentStop** binds every finish to real exit codes of the `verify.json` chain (§3.2, §3.3, §4); the live-preview E2E run is part of that ledger (§3.3b); merge gate re-reads the ledger and commit-pins it to HEAD (§6). QA authors independent tests + coverage + vacuous-suite guard (§3.3). |
| **2 — Solid process** | this state machine (§2), where each stage's pass = a written green artifact the next stage reads (§0). Zero-overlap ownership → disjoint parallel devs (§3.1–3.2). Bounded loops (§4). A clean run auto-merges; risk escalates to a human (§6–§7). git-workflow gates on artifacts, never prose (§3.6). |
| **3 — Security** | the fresh-context reviewer's `/security-review` pass is **mandatory, force-triggered by path detection** (§1.2, §3.5); its findings artifact hard-blocks Critical at the merge gate (§6). secret-scan + deny-guard fire in auto mode, from the managed floor (§1.3). |
| **4 — Speed** | the deterministic router (§1) routes TRIVIAL to a single direct-edit agent and STANDARD to one dev+qa; only COMPLEX pays the full line — while the five floor hooks still fire on every tier (§1.3), and clean work merges automatically with no human wait (§7). |

---

## 10. Command → pipeline map (for command authors)

- `/quetrex-task-build <TASK>` — **the entrypoint.** Fetches/refines the task, lets the
  router size it, then drives this state machine to an **automatic merge** (or a human
  escalation). Runs in Pipeline Mode (§5).
- `/quetrex-task-rework <TASK>` — re-enters the machine after a `REWORK`/escalation; agrees
  a fix plan with the user, clears `ESCALATION`, resets the relevant counters, re-runs.
- `/quetrex-task-complete <TASK>` — marks a deployed task complete (post-merge tracker
  transition; no pipeline stages).
- `/quetrex-init` — writes `project.json` + `verify.json` (the verify-chain source of
  truth every gate reads).
- `/quetrex-deploy [staging|production|rollback]` — deploy. **Production is the one manual
  gate** in the whole system.

There is **no** `/quetrex-task-merge` command — clean PRs auto-merge and escalated ones are
merged by a human on GitHub (§7). There is **no** `/quetrex-update` command — update the
plugin with the native `/plugin update`.

A command must never re-implement a gate — it delegates to the agents and lets the hooks
decide. If a command needs to know whether a stage passed, it reads the `.quetrex/*`
artifact.
