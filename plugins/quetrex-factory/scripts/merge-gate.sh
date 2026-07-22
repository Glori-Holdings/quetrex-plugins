#!/usr/bin/env bash
# merge-gate.sh — PreToolUse hook (Bash matcher). THE merge boundary.
#
# SUPERSEDES enforce-merge-approval.sh. That hook implemented the OLD policy —
# "always prompt a human on every merge." The NEW policy is a 3-way decision
# made by a SEPARATE review-gate agent (fresh context, native /review +
# /security-review) that writes .quetrex/review-verdict.json:
#
#     AUTO_MERGE      → clean; the pipeline may merge with NO human in the loop.
#     REWORK          → defects found; work returns to the pipeline (developer).
#     ESCALATE_HUMAN  → uncertain/risky/loop-exhausted; a human must decide.
#
# Only PRODUCTION deploy remains a manual human gate (handled elsewhere — out of
# scope here). Merge to the default branch is now GATED BY ARTIFACT, not by a
# prompt: this hook allows `gh pr merge` (and a direct merge/push to main) ONLY
# when EVERY on-disk gate is green for the EXACT commit being merged, and denies
# with a REWORK- or ESCALATE_HUMAN-classified reason otherwise.
#
# ALLOW iff ALL of the following hold (read from disk — never from chat):
#   1. No .quetrex/ESCALATION file (a bounded loop hit its cap).
#   2. .quetrex/review-verdict.json exists, .verdict == "AUTO_MERGE", and its
#      .sha == HEAD of the repo (so a verdict for an OLDER commit — i.e. new
#      commits landed after review — cannot authorize this merge).
#   3. .quetrex/verify-ledger.jsonl is GREEN: for every command in the current
#      verify chain, its MOST RECENT ledger entry exited 0 (a never-run or
#      stale-red command blocks — this closes the stale-green hole).
#   4. .quetrex/security-findings.json has NO finding with severity "critical"
#      AND status "open"; if it exists it must be for HEAD (.head_sha == HEAD);
#      and if the plan set security_review_required:true it MUST exist.
#
# DESIGN AXIOM (from the blueprint): the merge boundary is decided by hooks
# reading artifacts, never by an agent's prose. A Critical/BLOCK/REWORK from any
# stage MECHANICALLY prevents the ship. There is NO human-approval override that
# can bypass a red ledger, an open Critical, or a non-AUTO_MERGE verdict — the
# only way to merge is to make the artifacts genuinely green at the head commit.
#
# SCOPE: this hook only governs a repo that quetrex manages — one that has a
# ./.quetrex/ directory. A repo without it is not gated (exit 0, silent).
#
# HOOK SCHEMA: PreToolUse denies via
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#     "permissionDecision":"deny","permissionDecisionReason":"..."}}
# emitted on stdout with exit 0. A deny wins over any allowlist/auto-mode allow
# (precedence: deny > ask > allow), and a blocking PreToolUse hook runs BEFORE
# the permission engine — so this fires even under --permission-mode auto,
# bypassPermissions, or --dangerously-skip-permissions.
#
# FAIL-CLOSED at the ship boundary: if the gate cannot evaluate a real
# quetrex-managed merge (jq missing, artifacts unreadable), it DENIES and tells
# the orchestrator to escalate — it never lets a merge through unevaluated.

set -uo pipefail

# --- read hook input (absence is fine) -------------------------------------
input=""
if [ ! -t 0 ]; then input=$(cat); fi
[ -z "$input" ] && exit 0

# jq is mandatory for every hook in this system. At the SHIP boundary we cannot
# silently pass an unevaluated merge, so if jq is absent we still must be able to
# tell whether this is even a merge command. Grab the command with a jq-free
# fallback, then decide.
if command -v jq >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  SESSION_CWD=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
else
  COMMAND=""
  SESSION_CWD=""
fi
# jq-free extraction fallback (best-effort) so a missing jq cannot blind the gate
# to a merge command. Not exhaustive — only used to detect the merge intent.
if [ -z "$COMMAND" ]; then
  COMMAND=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')
fi
[ -z "$COMMAND" ] && exit 0

# --- is this a merge-to-main vector at all? --------------------------------
# A git subcommand invoked bare (`git merge`) or with a leading `-C <dir>`
# (`git -C /worktree push`) — the form this workflow uses inside worktrees.
GIT_PFX='git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+'

# Tag pushes (deploy/version rollback tags) are exempt — they are not merges.
is_tag_push() {
  [[ "$COMMAND" == *"git tag"* ]] || \
  [[ "$COMMAND" == *"refs/tags/"* ]] || \
  [[ "$COMMAND" =~ push[[:space:]]+(origin[[:space:]]+)?deploy/ ]] || \
  [[ "$COMMAND" =~ push[[:space:]]+(origin[[:space:]]+)?v[0-9] ]]
}

is_merge_vector=0
merge_kind=""

# (a) gh pr merge — the primary vector under the new policy.
if [[ "$COMMAND" == *"gh pr merge"* ]]; then
  is_merge_vector=1; merge_kind="gh pr merge"
fi

# (b) git push targeting master/main (push straight to the protected branch,
#     including from a feature branch — which enforce-branch does not catch).
if [ "$is_merge_vector" -eq 0 ] && [[ "$COMMAND" =~ ${GIT_PFX}push ]] && ! is_tag_push; then
  if [[ "$COMMAND" =~ (^|[[:space:]:/])(master|main)([[:space:]]|$) ]] || \
     [[ "$COMMAND" =~ :(refs/heads/)?(master|main)([[:space:]]|$) ]]; then
    is_merge_vector=1; merge_kind="push to main"
  fi
fi

# (c) git merge while ON master/main (a local merge into the protected branch).
if [ "$is_merge_vector" -eq 0 ] && [[ "$COMMAND" =~ ${GIT_PFX}merge ]]; then
  TDIR=""
  if [[ "$COMMAND" =~ cd[[:space:]]+([^\&\;]+)[[:space:]]*\&\& ]]; then
    TDIR=$(printf '%s' "${BASH_REMATCH[1]}" | sed 's/^[ "'\'']*//;s/[ "'\'']*$//')
  elif [[ "$COMMAND" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
    TDIR="${BASH_REMATCH[1]}"
  fi
  BR=""
  if [ -n "$TDIR" ] && [ -d "$TDIR" ]; then
    BR=$(git -C "$TDIR" branch --show-current 2>/dev/null)
  elif [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
    BR=$(git -C "$SESSION_CWD" branch --show-current 2>/dev/null)
  else
    BR=$(git branch --show-current 2>/dev/null)
  fi
  if [ "$BR" = "master" ] || [ "$BR" = "main" ]; then
    is_merge_vector=1; merge_kind="merge into main"
  fi
fi

# Not a merge-to-main command -> nothing to gate.
[ "$is_merge_vector" -eq 1 ] || exit 0

# --- resolve repo root (worktree-safe) -------------------------------------
ROOT=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  ROOT=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || ROOT="$CLAUDE_PROJECT_DIR"
fi
if [ -z "$ROOT" ] && [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  ROOT=$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null)
fi
[ -z "$ROOT" ] && ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

QDIR="$ROOT/.quetrex"
# Only quetrex-managed repos are gated. No .quetrex/ -> not our concern, allow.
{ [ -n "$ROOT" ] && [ -d "$QDIR" ]; } || exit 0

# --- deny helper (correct PreToolUse schema; exit 0) -----------------------
# Falls back to a raw-JSON emit if jq is unavailable, so the ship boundary is
# never blinded by a missing dependency.
deny() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    # Minimal manual JSON escaping for the fail-closed path.
    local esc
    esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$esc"
  fi
  exit 0
}

# FAIL-CLOSED: a real quetrex merge with no jq cannot be evaluated -> deny.
if ! command -v jq >/dev/null 2>&1; then
  deny "MERGE GATE (ESCALATE_HUMAN): jq is not installed, so the merge gate cannot verify the review verdict, verify ledger, or security findings for '$merge_kind'. A merge must never proceed unevaluated. Install jq, then re-run the pipeline's review-gate."
fi

LEDGER="$QDIR/verify-ledger.jsonl"
RV="$QDIR/review-verdict.json"
SEC="$QDIR/security-findings.json"
ESCALATION="$QDIR/ESCALATION"

HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)

# ===========================================================================
# GATE 1 — no ESCALATION marker
# ===========================================================================
if [ -f "$ESCALATION" ]; then
  reason="ESCALATE_HUMAN"
  detail=$(head -c 800 "$ESCALATION" 2>/dev/null)
  deny "MERGE GATE ($reason): .quetrex/ESCALATION is present — a bounded self-heal/review loop hit its cap and the pipeline stopped. This merge is BLOCKED until a human resolves the escalation. Surface it to the user and run /quetrex-task-rework; do not delete ESCALATION to force the merge.${detail:+ --- escalation note --- $detail}"
fi

# ===========================================================================
# GATE 2 — review verdict must be AUTO_MERGE, for THIS head commit
# ===========================================================================
if [ ! -f "$RV" ]; then
  deny "MERGE GATE (REWORK): .quetrex/review-verdict.json is missing — the review-gate never ran on this branch. Run the pipeline's review-gate (native /review + /security-review) before merging '$merge_kind'."
fi
VERDICT=$(jq -r '.verdict // empty' "$RV" 2>/dev/null)
RV_SHA=$(jq -r '.sha // .head_sha // empty' "$RV" 2>/dev/null)

# The review-gate (agents/reviewer.md) writes EXACTLY one of:
#   AUTO_MERGE | REWORK | ESCALATE_HUMAN
# These strings are the contract; they must match here byte-for-byte. Legacy
# reviewer strings (BLOCK/APPROVE/ESCALATE) are still recognized defensively so
# an older artifact never silently falls through the catch-all as "AUTO_MERGE".
case "$VERDICT" in
  AUTO_MERGE)
    : ;; # candidate — sha check below still applies
  REWORK|BLOCK)
    # BLOCK is the legacy reviewer verdict; treat as REWORK under the new policy.
    conf=$(jq -rc '(.confirmed // [] | length) as $c | "\($c) confirmed finding(s)"' "$RV" 2>/dev/null)
    deny "MERGE GATE (REWORK): review verdict is '$VERDICT'${conf:+ ($conf)}, not AUTO_MERGE. Defects were found — this merge is denied. Send the task back through the pipeline (developer → qa → review-gate); it will merge automatically once the verdict is AUTO_MERGE."
    ;;
  ESCALATE_HUMAN|ESCALATE)
    # ESCALATE_HUMAN is the current contract string; ESCALATE is the legacy alias.
    deny "MERGE GATE (ESCALATE_HUMAN): review verdict is '$VERDICT' — the review-gate was uncertain, hit its rework cap, or referred this to a human. Do NOT auto-merge. Surface the verdict and its findings to the user and let them decide (/quetrex-task-rework)."
    ;;
  APPROVE)
    # Legacy reviewer verdict. Under the NEW merge policy only the review-gate's
    # explicit AUTO_MERGE authorizes a human-free merge; a bare APPROVE is not
    # that decision, so escalate rather than auto-ship.
    deny "MERGE GATE (ESCALATE_HUMAN): review verdict is the legacy 'APPROVE', but the new merge policy authorizes an auto-merge ONLY on an explicit 'AUTO_MERGE' verdict from the review-gate. Run the review-gate to produce a 3-way decision (AUTO_MERGE | REWORK | ESCALATE_HUMAN), or have a human confirm."
    ;;
  ""|*)
    deny "MERGE GATE (ESCALATE_HUMAN): review verdict is '${VERDICT:-<missing>}', which is not a recognized decision (AUTO_MERGE | REWORK | ESCALATE_HUMAN). The review artifact is malformed or partial — do not merge. Surface to the user and re-run the review-gate."
    ;;
esac

# Verdict is AUTO_MERGE. Bind it to the exact commit being merged: if new commits
# landed after review, the verdict no longer describes what would ship.
if [ -z "$RV_SHA" ]; then
  deny "MERGE GATE (REWORK): review-verdict.json has verdict AUTO_MERGE but records no commit sha, so it cannot be pinned to what is being merged. Re-run the review-gate so it records the reviewed HEAD sha."
fi
if [ -n "$HEAD_SHA" ] && [ "$RV_SHA" != "$HEAD_SHA" ]; then
  deny "MERGE GATE (REWORK): the AUTO_MERGE verdict is for commit ${RV_SHA:0:12}, but HEAD is now ${HEAD_SHA:0:12} — commits landed after review, so the approval is stale. Re-run the review-gate against the current HEAD before merging."
fi

# ===========================================================================
# GATE 3 — verify ledger green AND commit-pinned to HEAD (closes stale-green)
# ===========================================================================
# Rule: for EVERY command in the current verify chain, its MOST RECENT ledger
# entry must (a) have exited 0 AND (b) carry a `sha` equal to the CURRENT HEAD.
# A chain command that never ran (absent from the ledger), whose latest run was
# non-zero, OR whose latest green was proven against a DIFFERENT commit than the
# one being merged, all BLOCK. The sha pin is what makes this immune to a green
# line written for an earlier commit: if new commits landed after QA proved
# green, that green no longer describes HEAD and cannot authorize the merge.
if [ ! -s "$LEDGER" ]; then
  deny "MERGE GATE (REWORK): .quetrex/verify-ledger.jsonl is missing or empty — QA never proved the verify chain green. Run the pipeline's QA stage before merging."
fi

# Resolve the current verify chain (single source of truth: verify.json).
CHAIN_JSON=$(jq -c 'if (.verify | type) == "array" and (.verify | length) > 0 then .verify else empty end' "$QDIR/verify.json" 2>/dev/null)

if [ -n "$CHAIN_JSON" ]; then
  # For each chain command, its latest ledger entry must be exit 0 AND for HEAD.
  # null exit = never ran = fail; a sha != HEAD = stale-green = fail.
  RED=$(jq -sc --argjson chain "$CHAIN_JSON" --arg head "$HEAD_SHA" '
    (reduce .[] as $e ({}; .[$e.cmd] = {exit:$e.exit, sha:($e.sha // "")})) as $last
    | [ $chain[]
        | ($last[.] // {exit:null, sha:null}) as $l
        | { cmd: ., exit: $l.exit, sha: $l.sha }
        | select(.exit != 0 or (.sha != $head)) ]
  ' "$LEDGER" 2>/dev/null)
else
  # No canonical chain resolvable — fall back to: every command that appears in
  # the ledger must have its latest run green AND pinned to HEAD (conservative;
  # a lingering red or stale-commit command blocks). Still refuses stale-green.
  RED=$(jq -sc --arg head "$HEAD_SHA" '
    (reduce .[] as $e ({}; .[$e.cmd] = {exit:$e.exit, sha:($e.sha // "")}))
    | to_entries
    | map(select(.value.exit != 0 or (.value.sha != $head)) | {cmd:.key, exit:.value.exit, sha:.value.sha})
  ' "$LEDGER" 2>/dev/null)
fi

if [ -z "$RED" ] || [ "$RED" = "null" ]; then
  # jq failed to evaluate the ledger at the ship boundary -> fail closed.
  deny "MERGE GATE (ESCALATE_HUMAN): could not evaluate .quetrex/verify-ledger.jsonl (malformed JSONL?). The verify chain cannot be proven green, so the merge is denied. Surface to the user."
fi
if [ "$RED" != "[]" ]; then
  SUMMARY=$(printf '%s' "$RED" | jq -r --arg head "$HEAD_SHA" 'map("  - `\(.cmd)` -> \(if .exit == null then "never ran (no ledger entry)" elif (.exit != 0) then "exit \(.exit)" else "STALE: last green was for commit \((.sha // "?")[0:12]), not HEAD \($head[0:12]) — re-run QA on the current commit" end)") | join("\n")' 2>/dev/null)
  deny "$(printf 'MERGE GATE (REWORK): the verify chain is not green for the commit being merged. The following command(s) are red, never ran, or stale (proven against a different commit):\n%s\nFix the code and let QA re-prove the chain green (every command exit 0) ON THE CURRENT HEAD before merging.' "$SUMMARY")"
fi

# ===========================================================================
# GATE 4 — security findings: no open Critical, pinned to HEAD; required-but-
#          missing is a failure. NON-BYPASSABLE-BY-OMISSION.
# ===========================================================================
# A security review is REQUIRED when EITHER of these holds:
#   (a) the plan set security_review_required:true (router/architect forced it), OR
#   (b) the ACTUAL diff being merged touches a sensitive surface — auth/authz,
#       input handling, secrets/crypto, external calls, data-access, or a DB
#       migration — regardless of what the plan says.
# (b) is the floor that makes security non-bypassable: a plan that simply omits
# the flag (defaulting it false) cannot ship sensitive code unreviewed, because
# the gate inspects the diff itself, not the agent's classification of it.
PLAN=""
TASK=$(jq -r '.task // empty' "$QDIR/state.json" 2>/dev/null)
if [ -n "$TASK" ] && [ -f "$QDIR/plan/$TASK.json" ]; then
  PLAN="$QDIR/plan/$TASK.json"
else
  # Fall back to any single plan file if state.json is unavailable.
  PLAN=$(ls -1 "$QDIR"/plan/*.json 2>/dev/null | head -n1)
fi
PLAN_SEC="false"
[ -n "$PLAN" ] && PLAN_SEC=$(jq -r '.security_review_required // false' "$PLAN" 2>/dev/null)

# --- (b) inspect the real diff for a sensitive surface ---------------------
# Diff the feature tip against the base branch (main, else master). Three-dot
# range = what this branch changed since it diverged.
BASE_BRANCH="main"
if ! git -C "$ROOT" rev-parse --verify --quiet main >/dev/null 2>&1; then
  git -C "$ROOT" rev-parse --verify --quiet master >/dev/null 2>&1 && BASE_BRANCH="master"
fi
SENSITIVE_DIFF=0
CHANGED=$(git -C "$ROOT" diff --name-only "$BASE_BRANCH"...HEAD 2>/dev/null)
# Fall back to the last commit's files if the base range can't be computed.
[ -z "$CHANGED" ] && CHANGED=$(git -C "$ROOT" diff --name-only HEAD~1..HEAD 2>/dev/null)
SENSITIVE_PATH_RE='(auth|authz|authn|login|logout|signin|sign-in|session|oauth|openid|saml|sso|jwt|token|secret|credential|password|passwd|crypto|encrypt|decrypt|cipher|migration|migrate|schema|\.sql$|payment|billing|invoice|checkout|charge|stripe|paypal|permission|role|rbac|tenant|acl|middleware|guard|policy|webhook|\.github/workflows/|dockerfile|docker-compose|terraform|pulumi|kubernetes|k8s|helm)'
if [ -n "$CHANGED" ] && printf '%s\n' "$CHANGED" | grep -qiE "$SENSITIVE_PATH_RE"; then
  SENSITIVE_DIFF=1
fi
# Also scan ADDED lines for sensitive code patterns even when the path is neutral
# (data-access by client id, whole-body binding, injection sinks, env/secret use,
# external calls). Only added (+) lines to avoid flagging deletions.
if [ "$SENSITIVE_DIFF" -eq 0 ]; then
  ADDED=$(git -C "$ROOT" diff "$BASE_BRANCH"...HEAD 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+')
  [ -z "$ADDED" ] && ADDED=$(git -C "$ROOT" diff HEAD~1..HEAD 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+')
  SENSITIVE_CODE_RE='(findById|find_by_id|findOne|req\.(params|query|body)|request\.(args|form|json|params)|Object\.assign|dangerouslySetInnerHTML|innerHTML|v-html|child_process|execSync|spawnSync|[^a-zA-Z]eval\(|process\.env|os\.environ|getenv|jwt\.|bcrypt|scrypt|argon2|createHash|createCipher|\.raw\(|\$where|authorize\(|authenticate|passport|fetch\(|axios|http\.request|urllib|requests\.(get|post))'
  if [ -n "$ADDED" ] && printf '%s' "$ADDED" | grep -qE "$SENSITIVE_CODE_RE"; then
    SENSITIVE_DIFF=1
  fi
fi

NEED_SEC="false"; SEC_WHY=""
if [ "$PLAN_SEC" = "true" ]; then
  NEED_SEC="true"; SEC_WHY="the plan set security_review_required:true"
elif [ "$SENSITIVE_DIFF" -eq 1 ]; then
  NEED_SEC="true"; SEC_WHY="the diff touches a sensitive surface (auth/authz/input/secrets/crypto/external-call/data-access/migration)"
fi

if [ ! -f "$SEC" ]; then
  if [ "$NEED_SEC" = "true" ]; then
    deny "MERGE GATE (REWORK): a security review is required because $SEC_WHY, but .quetrex/security-findings.json is missing — the mandatory security-reviewer stage did not run for this change. Run the security-reviewer against the current HEAD before merging. This requirement cannot be bypassed by omitting the plan flag."
  fi
  # Security review not required (neutral diff, no plan flag) and not present -> Gate 4 passes.
else
  # security-findings.json exists. Support BOTH the documented object shape
  # ({head_sha, verdict, findings:[...]}) and a bare array of findings.
  FINDINGS=$(jq -c 'if type == "object" then (.findings // []) else . end' "$SEC" 2>/dev/null)
  if [ -z "$FINDINGS" ] || [ "$FINDINGS" = "null" ]; then
    deny "MERGE GATE (ESCALATE_HUMAN): .quetrex/security-findings.json is malformed and cannot be parsed. The merge is denied until the security findings are readable. Surface to the user."
  fi

  # Pin to HEAD when the artifact records a head_sha (object shape only).
  SEC_SHA=$(jq -r 'if type == "object" then (.head_sha // .sha // empty) else empty end' "$SEC" 2>/dev/null)
  if [ -n "$SEC_SHA" ] && [ -n "$HEAD_SHA" ] && [ "$SEC_SHA" != "$HEAD_SHA" ]; then
    deny "MERGE GATE (REWORK): the security review is for commit ${SEC_SHA:0:12}, but HEAD is now ${HEAD_SHA:0:12} — the review is stale. Re-run the security-reviewer against the current HEAD before merging."
  fi

  OPEN_CRIT=$(printf '%s' "$FINDINGS" | jq '[ .[] | select((.severity // "" | ascii_downcase) == "critical" and (.status // "open" | ascii_downcase) == "open") ] | length' 2>/dev/null)
  case "$OPEN_CRIT" in ''|*[!0-9]*) OPEN_CRIT=-1 ;; esac
  if [ "$OPEN_CRIT" -lt 0 ]; then
    deny "MERGE GATE (ESCALATE_HUMAN): could not evaluate open Critical findings in security-findings.json. The merge is denied until the artifact is verifiably clean. Surface to the user."
  fi
  if [ "$OPEN_CRIT" -gt 0 ]; then
    LIST=$(printf '%s' "$FINDINGS" | jq -r '[ .[] | select((.severity // "" | ascii_downcase) == "critical" and (.status // "open" | ascii_downcase) == "open") ] | map("  - \(.category // "?") @ \(.file // "?"):\(.line // "?") — \(.summary // .exploit // "critical finding")") | join("\n")' 2>/dev/null)
    deny "$(printf 'MERGE GATE (REWORK): %s open Critical security finding(s) block this merge:\n%s\nFix the vulnerabilit(y/ies) and re-run the security-reviewer until zero Critical remain open. Human approval CANNOT bypass an open Critical.' "$OPEN_CRIT" "$LIST")"
  fi
fi

# ===========================================================================
# ALL GATES GREEN — allow the merge (no prompt; this IS the auto-merge path).
# ===========================================================================
# Emitting no JSON on a PreToolUse hook means "no decision" -> normal permission
# flow proceeds and the merge runs. Under the new policy an AUTO_MERGE verdict
# with a green ledger and no open Critical is a clean, human-free ship.
exit 0
