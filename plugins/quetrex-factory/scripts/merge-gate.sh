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
#   2. .quetrex/review-verdict.json exists, .verdict == "AUTO_MERGE", its
#      .sha == HEAD of the repo (so a verdict for an OLDER commit — i.e. new
#      commits landed after review — cannot authorize this merge), AND an
#      INDEPENDENT security pass is on record: either
#      .inputs.nativeSecurityReview is "clean"/"issues" (the native pass ran),
#      or the separate security-reviewer agent's HEAD-pinned
#      security-findings.json is clean, or no security review was required at
#      all. The reviewer still cannot self-exempt and auto-merge (see GATE 2b).
#   3. .quetrex/verify-ledger.jsonl is GREEN: for every command in the current
#      verify chain, its MOST RECENT ledger entry exited 0 (a never-run or
#      stale-red command blocks — this closes the stale-green hole).
#   4. .quetrex/security-findings.json has NO finding with severity "critical"
#      AND status "open"; if it exists it must be for HEAD (.head_sha == HEAD);
#      and if the plan set security_review_required:true it MUST exist.
#   5. Every file in the diff being merged is covered by the architect's
#      ownership map in .quetrex/plan/<TASK>.json — a developer that edited
#      outside its lane cannot ship (see GATE 5 for the exemptions and for what
#      happens when a task ran without a plan).
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
# AND IT GOVERNS ONLY ACTUAL MERGES, IN THE REPO THE COMMAND ACTUALLY TARGETS.
# Both halves were broken, and both mattered more than any gate this file adds:
#   - It matched `push` and the token `main` anywhere in the command string, so
#     `git push <feature-branch> && gh pr create --base main` was denied as a
#     "push to main". Detection is now per-invocation and anchored.
#   - It resolved the repo from the SESSION's project dir, not the directory the
#     command names, so one repo's stale verdict blocked another repo's work.
#     Resolution is now most-specific-first, and a `gh pr merge --repo` naming
#     a different repository is refused rather than judged by these artifacts.
# A gate that fires on non-merges gets routed around on reflex, and then it is
# not gating anything. Precision IS the safety property here.
#
# HOOK SCHEMA: PreToolUse denies via
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#     "permissionDecision":"deny","permissionDecisionReason":"..."}}
# emitted on stdout with exit 0. A deny wins over any allowlist/auto-mode allow
# (precedence: deny > ask > allow), and a blocking PreToolUse hook runs BEFORE
# the permission engine — so this fires even under --permission-mode auto,
# bypassPermissions, or --dangerously-skip-permissions.
# When jq is absent the JSON form is unavailable, so deny() falls back to the
# contract's OTHER blocking channel — stderr + exit 2 — rather than hand-rolling
# JSON escaping that a control character in the reason would malform (a
# malformed payload is dropped, and a dropped payload reads as ALLOW).
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
#
# Evaluated PER INVOCATION, never against the whole command string.
#
# THE DEFECT THIS REPLACES. The previous version asked two questions of the
# entire command: does it contain a `git push`, and does it contain the token
# `main`. So this — the standard "push a feature branch, then open its PR" —
#
#     git -C /wt push -u origin claude/my-feature && gh pr create --base main
#
# was classified "push to main" because `--base main` belonged to a DIFFERENT
# sub-command. Opening a PR for a feature branch is not a merge. It denied with
# a stale REWORK verdict from an unrelated task, and the workaround (`gh api`)
# became routine. That is the worst failure mode a ship gate has: one that
# cries wolf gets bypassed on reflex, and then it is not gating anything.
#
# Now: split the command on shell operators, normalize away wrappers, and
# require the invocation to BEGIN its segment. The token `main` inside another
# sub-command's flags, a commit message, a PR body, or a heredoc line can no
# longer trigger the gate — while every genuine vector still does.
#
# Residual, and deliberately so: a vector constructed to hide from a regex
# (git plumbing, a script file, a library binding) is not detected. This gate
# mechanizes the pipeline's own policy against the pipeline's own commands; it
# is not a sandbox, and pretending otherwise is what produced the false
# positives in the first place.

# Split on && || ; and |. awk, not sed: BSD sed does not interpret \n in a
# replacement, so `sed 's/&&/\n/'` yields a literal "n" on macOS.
SEGMENTS=$(printf '%s' "$COMMAND" | awk '{gsub(/&&|\|\||;|\|/, "\n"); print}')

# Strip leading wrappers so `sudo git push …`, `FOO=1 git push …` and
# `bash -c "git push …"` still anchor on the real invocation.
normalize_segment() {
  local s="$1" first
  s=$(printf '%s' "$s" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  while [ -n "$s" ]; do
    first="${s%%[[:space:]]*}"
    case "$first" in
      sudo|env|eval|command|nohup|time)
        s="${s#"$first"}" ;;
      bash|sh|zsh)
        # bash -c '<payload>' — unwrap the payload, then keep normalizing it.
        if [[ "$s" =~ ^(bash|sh|zsh)[[:space:]]+-c[[:space:]]+(.*)$ ]]; then
          s="${BASH_REMATCH[2]}"
          s="${s#[\"\']}"; s="${s%[\"\']}"
        else
          break
        fi ;;
      *)
        # A leading VAR=value assignment only — matched with a regex, not a
        # case glob: `git commit -m "a=b"` also contains `=`, and stripping to
        # the first space there would drop the `git` and silently un-detect a
        # real vector.
        if [[ "$first" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          s="${s#"$first"}"
        else
          break
        fi ;;
    esac
    s=$(printf '%s' "$s" | sed 's/^[[:space:]]*//')
  done
  printf '%s' "$s"
}

# Tag pushes (deploy/version rollback tags) are exempt — they are not merges.
# Takes the SEGMENT, not the whole command: a `git tag` earlier in a compound
# command must not exempt a real push to main later in it.
is_tag_push() {
  local seg="$1"
  [[ "$seg" == *"refs/tags/"* ]] || \
  [[ "$seg" =~ ^git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+tag([[:space:]]|$) ]] || \
  [[ "$seg" =~ push[[:space:]]+(--[^[:space:]]+[[:space:]]+)*(origin[[:space:]]+)?deploy/ ]] || \
  [[ "$seg" =~ push[[:space:]]+(--[^[:space:]]+[[:space:]]+)*(origin[[:space:]]+)?v[0-9] ]]
}

# Does this segment's own argument list target the protected branch?
targets_protected_branch() {
  local seg="$1"
  [[ "$seg" =~ (^|[[:space:]:/])(master|main)([[:space:]]|$) ]] || \
  [[ "$seg" =~ :(refs/heads/)?(master|main)([[:space:]]|$) ]]
}

GIT_ANCHOR='^git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?([[:space:]]+-[^[:space:]]+)*[[:space:]]+'

is_merge_vector=0
merge_kind=""
VECTOR_SEG=""
PENDING_CD=""

while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  norm=$(normalize_segment "$seg")
  [ -z "$norm" ] && continue

  # Track `cd <dir>` so a later `git merge` in the same compound command is
  # evaluated against the directory it will actually run in.
  if [[ "$norm" =~ ^cd[[:space:]]+([^[:space:]]+) ]]; then
    PENDING_CD=$(printf '%s' "${BASH_REMATCH[1]}" | sed 's/^["'\'']*//; s/["'\'']*$//')
    continue
  fi

  # (a) gh pr merge — the primary vector under the new policy.
  if [[ "$norm" =~ ^gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]]; then
    is_merge_vector=1; merge_kind="gh pr merge"; VECTOR_SEG="$norm"; break
  fi

  # (b) git push whose OWN arguments target master/main (a push straight to the
  #     protected branch, including from a feature branch — which
  #     enforce-branch does not catch).
  if [[ "$norm" =~ ${GIT_ANCHOR}push([[:space:]]|$) ]] && ! is_tag_push "$norm"; then
    if targets_protected_branch "$norm"; then
      is_merge_vector=1; merge_kind="push to main"; VECTOR_SEG="$norm"; break
    fi
  fi

  # (c) git merge while ON master/main (a local merge into the protected branch).
  if [[ "$norm" =~ ${GIT_ANCHOR}merge([[:space:]]|$) ]]; then
    TDIR=""
    if [[ "$norm" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
      TDIR=$(printf '%s' "${BASH_REMATCH[1]}" | sed 's/^["'\'']*//; s/["'\'']*$//')
    elif [ -n "$PENDING_CD" ]; then
      TDIR="$PENDING_CD"
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
      # SYNCING the protected branch from its OWN upstream is not a ship.
      # `git merge --ff-only origin/main` while on main brings down commits that
      # ALREADY went through a PR and this very gate; there is nothing left to
      # gate, and the artifacts on disk describe a feature branch that is now
      # merged. Denying it blocked the routine post-merge return to main — which
      # is a large part of why post-merge cleanup never became automatic, and
      # why `git pull` on main was reported as "the gate blocking everything".
      #
      # Exempt only when EVERY ref argument is this branch's own remote-tracking
      # ref (origin/main, upstream/main, @{u}). A merge of anything else into
      # main — a feature branch, a sha, another branch's ref — is still a ship
      # and is still gated.
      merge_args=$(printf '%s' "$norm" | sed -e 's/.*[[:space:]]merge//')
      sync_only=1; have_ref=0
      for a in $merge_args; do
        case "$a" in
          -*) continue ;;
        esac
        have_ref=1
        case "$a" in
          '@{u}'|'@{upstream}') ;;
          */"$BR") ;;
          *) sync_only=0 ;;
        esac
      done
      if [ "$have_ref" -eq 1 ] && [ "$sync_only" -eq 1 ]; then
        continue
      fi
      is_merge_vector=1; merge_kind="merge into main"; VECTOR_SEG="$norm"; break
    fi
  fi
done <<< "$SEGMENTS"

# Not a merge-to-main command -> nothing to gate.
[ "$is_merge_vector" -eq 1 ] || exit 0

# --- resolve the repo THIS COMMAND TARGETS (worktree-safe) ------------------
#
# THE SECOND DEFECT THIS REPLACES: resolution used to start from
# CLAUDE_PROJECT_DIR — the SESSION's primary repo — so a command operating on
# another checkout was judged against the session repo's artifacts. Observed in
# the wild: branch cleanup in quetrex-plugins denied by quetrex-base's stale
# review verdict. One repo's REWORK must never block another repo's merge.
#
# Order is now most-specific-first: the directory named by the command itself,
# then the session cwd, and only then the project dir.
TARGET_DIR=""
if [[ "$VECTOR_SEG" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
  TARGET_DIR=$(printf '%s' "${BASH_REMATCH[1]}" | sed 's/^["'\'']*//; s/["'\'']*$//')
elif [ -n "$PENDING_CD" ]; then
  TARGET_DIR="$PENDING_CD"
fi

ROOT=""
if [ -n "$TARGET_DIR" ] && [ -d "$TARGET_DIR" ]; then
  ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)
fi
if [ -z "$ROOT" ] && [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  ROOT=$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null)
fi
if [ -z "$ROOT" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  ROOT=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || ROOT="$CLAUDE_PROJECT_DIR"
fi
[ -z "$ROOT" ] && ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

QDIR="$ROOT/.quetrex"
# Only quetrex-managed repos are gated. No .quetrex/ -> not our concern, allow.
{ [ -n "$ROOT" ] && [ -d "$QDIR" ]; } || exit 0

# --- deny helper (correct PreToolUse schema; exit 0) -----------------------
# With jq: the documented permissionDecision:"deny" object on exit 0.
#
# WITHOUT jq: deliberately NO JSON. A hand-rolled escaper is a fail-open in
# disguise — the reasons this gate emits embed the tail of a failing build, a
# security finding summary, or an ESCALATION note, all of which routinely carry
# tabs, carriage returns and ANSI escapes. Those are raw control bytes, illegal
# unescaped inside a JSON string (RFC 8259 requires U+0000–U+001F to be
# escaped), so the payload is malformed, the runtime DROPS the undecodable
# hook output, and "exit 0 + no decision" is read as ALLOW — the merge sails
# through at exactly the moment the gate meant to stop it. So the fallback uses
# the other blocking channel the hook contract provides instead: exit 2 is a
# blocking error whose stderr is fed back to the agent. It blocks the tool call
# outright and there is no JSON to malform.
deny() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
  fi
  printf '%s\n' "$reason" >&2
  exit 2
}

# --- artifact_only_range_ok — the self-invalidation escape hatch ------------
#
# THE TRAP: every sha-pin in this gate (review-verdict.json's .sha,
# security-findings.json's .head_sha, each verify-ledger.jsonl entry's .sha)
# is an artifact NAMING the commit it approves. By design these are runtime
# control-plane files and git-workflow.md instructs every stage to NEVER
# commit them (`.gitignore` should ignore `.quetrex/*` and un-ignore only
# `project.json`/`verify.json`). But when a repo's gitignore drifts from that
# recommendation — observed in the wild — one of these DOES get committed.
# The commit that adds it moves HEAD to a new sha; the artifact's own pin,
# recorded before that commit existed, can now NEVER equal HEAD again. A
# straight sha-equality check then denies every subsequent operation
# forever, including the commit that would remove the artifact and repair
# the mistake — the gate blocks its own repair.
#
# THE FIX IS NARROW ON PURPOSE: an old pin still authorizes the current HEAD
# ONLY when nothing that could have invalidated the approval happened since —
# i.e. $old is an ancestor of (or equal to) $new, AND every commit in
# $old..$new touches NOTHING outside .quetrex/. A single commit that touches
# so much as one file outside .quetrex/ anywhere in that range disqualifies
# the WHOLE range: code changed, so the old approval no longer describes what
# would ship, and the ordinary stale-verdict/stale-ledger/stale-findings deny
# applies exactly as before. This property must never weaken — it is the
# entire point of the sha pin.
#
# FAIL-CLOSED on every unresolved condition: a missing commit object (shallow
# clone, a sha this checkout never fetched), a merge-base error, or a
# diff-tree that can't be read all `return 1` (not-ok) rather than assume
# safety. Never let an error path open the gate.
#
# Correctness details that matter:
#   - Path scope uses an ANCHORED case-glob (`.quetrex/*`), not a string
#     prefix test, so `.quetrexfoo/x` and `src/.quetrex/x` do NOT count as
#     in-scope — only the literal top-level `.quetrex/` directory does.
#   - Merge commits are diffed with `-m` (one diff per parent) so a change
#     that would otherwise vanish from a plain no-flags merge-commit diff
#     (git only shows nothing for a merge by default) cannot hide a
#     disqualifying path.
#   - `--no-renames` so a rename is seen as its literal old+new paths rather
#     than compressed to a single "new name only" line, which could hide a
#     source path outside .quetrex/ that a rename moved OUT of scope.
#   - `--root` so a range that happens to start at the repo's very first
#     commit is still diffed correctly.
artifact_only_range_ok() {
  local old="$1" new="$2"
  [ -n "$old" ] && [ -n "$new" ] || return 1
  [ "$old" = "$new" ] && return 0

  git -C "$ROOT" rev-parse --verify --quiet "${old}^{commit}" >/dev/null 2>&1 || return 1
  git -C "$ROOT" rev-parse --verify --quiet "${new}^{commit}" >/dev/null 2>&1 || return 1

  git -C "$ROOT" merge-base --is-ancestor "$old" "$new" >/dev/null 2>&1 || return 1

  local commits commit paths p
  commits=$(git -C "$ROOT" rev-list "${old}..${new}" 2>/dev/null) || return 1
  [ -n "$commits" ] || return 1

  while IFS= read -r commit; do
    [ -z "$commit" ] && continue
    paths=$(git -C "$ROOT" diff-tree --no-commit-id --name-only -r -m --root --no-renames "$commit" 2>/dev/null)
    [ $? -eq 0 ] || return 1
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      case "$p" in
        .quetrex/*) : ;;
        *) return 1 ;;
      esac
    done <<< "$paths"
  done <<< "$commits"

  return 0
}

# FAIL-CLOSED: a real quetrex merge with no jq cannot be evaluated -> deny.
if ! command -v jq >/dev/null 2>&1; then
  deny "MERGE GATE (ESCALATE_HUMAN): jq is not installed, so the merge gate cannot verify the review verdict, verify ledger, or security findings for '$merge_kind'. A merge must never proceed unevaluated. Install jq, then re-run the pipeline's review-gate."
fi

# --- a --repo pointing somewhere else is not this repo's merge to judge -----
# `gh pr merge --repo owner/name` can target a repository that is not the one
# resolved above, and this repo's artifacts say nothing about that one. Judging
# it by these artifacts is precisely the cross-repo leak fixed above, so refuse
# to judge it at all — and refuse LOUDLY rather than allowing, because it IS a
# merge and the gate must never wave one through unevaluated.
if [ "$merge_kind" = "gh pr merge" ] && [[ "$VECTOR_SEG" =~ --repo[[:space:]=]+([^[:space:]]+) ]]; then
  GH_REPO=$(printf '%s' "${BASH_REMATCH[1]}" | sed 's/^["'\'']*//; s/["'\'']*$//' | tr 'A-Z' 'a-z')
  ORIGIN_SLUG=$(git -C "$ROOT" remote get-url origin 2>/dev/null \
    | sed -e 's#\.git$##' -e 's#.*[:/]\([^/][^/]*/[^/][^/]*\)$#\1#' | tr 'A-Z' 'a-z')
  if [ -n "$ORIGIN_SLUG" ] && [ -n "$GH_REPO" ] && [ "$GH_REPO" != "$ORIGIN_SLUG" ]; then
    deny "MERGE GATE (ESCALATE_HUMAN): this command merges a PR in '$GH_REPO', but it is running against a checkout of '$ORIGIN_SLUG'. The gate artifacts here (review verdict, verify ledger, security findings) describe '$ORIGIN_SLUG' and say NOTHING about '$GH_REPO', so it cannot evaluate this merge — and it will not judge one repo by another repo's verdict. Run the merge from inside a checkout of '$GH_REPO' so that repo's own gates apply."
  fi
fi

LEDGER="$QDIR/verify-ledger.jsonl"
RV="$QDIR/review-verdict.json"
SEC="$QDIR/security-findings.json"
ESCALATION="$QDIR/ESCALATION"

HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)

# ===========================================================================
# PREAMBLE — is a security review REQUIRED for this diff, and what does the
#            independent security artifact say?
# ===========================================================================
# Computed HERE, before GATE 2b, because 2b now needs both answers (it used to
# demand a field the reviewer structurally cannot fill — see GATE 2b). Pure
# reads, no side effects; GATE 4 and GATE 5 reuse the same values below.
#
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

# sec_artifact_state — what the INDEPENDENT security-reviewer artifact proves
# about the exact commit being merged. Echoes exactly one of:
#   missing | malformed | unpinned | stale | critical | clean
# Stricter than GATE 4 on one point: a head_sha is MANDATORY here, because in
# GATE 2b this artifact is load-bearing as proof of an independent pass, and an
# unpinned finding set proves nothing about this commit.
sec_artifact_state() {
  [ -f "$SEC" ] || { printf 'missing'; return; }
  local findings sha crit
  findings=$(jq -c 'if type == "object" then (.findings // []) else . end' "$SEC" 2>/dev/null)
  if [ -z "$findings" ] || [ "$findings" = "null" ]; then printf 'malformed'; return; fi
  sha=$(jq -r 'if type == "object" then (.head_sha // .sha // empty) else empty end' "$SEC" 2>/dev/null)
  if [ -z "$sha" ]; then printf 'unpinned'; return; fi
  if [ -n "$HEAD_SHA" ] && [ "$sha" != "$HEAD_SHA" ] && ! artifact_only_range_ok "$sha" "$HEAD_SHA"; then printf 'stale'; return; fi
  crit=$(printf '%s' "$findings" | jq '[ .[] | select((.severity // "" | ascii_downcase) == "critical" and (.status // "open" | ascii_downcase) == "open") ] | length' 2>/dev/null)
  case "$crit" in ''|*[!0-9]*) printf 'malformed'; return ;; esac
  if [ "$crit" -gt 0 ]; then printf 'critical'; return; fi
  printf 'clean'
}

# ===========================================================================
# GATE 1 — no ESCALATION marker
# ===========================================================================
if [ -f "$ESCALATION" ]; then
  reason="ESCALATE_HUMAN"
  detail=$(head -c 800 "$ESCALATION" 2>/dev/null)
  deny "MERGE GATE ($reason): .quetrex/ESCALATION is present — a bounded self-heal/review loop hit its cap and the pipeline stopped. This merge is BLOCKED until a human resolves the escalation. Surface it to the user and run /quetrex:task-rework; do not delete ESCALATION to force the merge.${detail:+ --- escalation note --- $detail}"
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
    deny "MERGE GATE (ESCALATE_HUMAN): review verdict is '$VERDICT' — the review-gate was uncertain, hit its rework cap, or referred this to a human. Do NOT auto-merge. Surface the verdict and its findings to the user and let them decide (/quetrex:task-rework)."
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
if [ -n "$HEAD_SHA" ] && [ "$RV_SHA" != "$HEAD_SHA" ] && ! artifact_only_range_ok "$RV_SHA" "$HEAD_SHA"; then
  deny "MERGE GATE (REWORK): the AUTO_MERGE verdict is for commit ${RV_SHA:0:12}, but HEAD is now ${HEAD_SHA:0:12} — commits landed after review, so the approval is stale. Re-run the review-gate against the current HEAD before merging."
fi
# else: either RV_SHA already equals HEAD, or every commit since RV_SHA only
# touched .quetrex/ (e.g. committing review-verdict.json itself moved HEAD
# without changing any reviewed code) — the verdict still describes what
# would actually ship, so it stands.

# --- GATE 2b — the reviewer may not self-exempt from independent review ------
# reviewer.md's decision rule 4 mandates ESCALATE_HUMAN when the native /review
# or /security-review "errored or could not run on a non-trivial change". But
# the agent that decides the verdict is ALSO the agent that reports whether
# independent review ran — so that rule is self-graded, and it has already been
# broken in the wild: a live verdict artifact recorded AUTO_MERGE over 18
# reviewed files with nativeSecurityReview "not_available_in_env" and
# nativeReview "not_run_no_pr".
#
# Mechanize it here. An AUTO_MERGE is only honored when the artifact
# AFFIRMATIVELY records that the native security pass actually executed:
#   "clean"  -> it ran and found nothing
#   "issues" -> it ran and found something the reviewer then adjudicated
# WHY THIS NO LONGER DEMANDS THE NATIVE FIELD *ONLY*. Requiring
# nativeSecurityReview to be "clean"/"issues" made AUTO_MERGE UNREACHABLE, and
# so made this whole pipeline a manual one. `/security-review` is a
# SlashCommand, and the reviewer subagent does not have SlashCommand in its
# runtime tool set — observed repeatedly, the agent reporting "my tool set is
# Read and Bash only" — even though reviewer.md declares it. The field is
# therefore STRUCTURALLY unfillable: every verdict recorded
# "not_available_in_env", every clean pipeline was denied, every merge was done
# by hand on GitHub, and none of the pipeline's post-merge bookkeeping ever ran
# (which is also why tasks stranded in in_progress).
#
# The requirement this gate actually encodes is INDEPENDENCE: the agent that
# decided the verdict must not be the only thing asserting security was
# reviewed. The dedicated security-reviewer AGENT satisfies that on its own —
# a different agent, fresh context, whose ONLY write is
# .quetrex/security-findings.json. So independence may now be proven EITHER
# way, and nothing else:
#
#   1. the native pass actually ran            -> nativeSecurityReview clean|issues
#   2. the independent security-reviewer ran   -> security-findings.json, pinned
#                                                 to HEAD, zero open Critical
#   3. no security review was required at all  -> neutral diff AND no plan flag
#                                                 AND no artifact to contradict
#
# Everything else still denies, including a missing field with no artifact, an
# unpinned or stale artifact, and any open Critical. Omitting a field remains
# no cheaper than filling it in honestly, and an open Critical is still
# unbypassable (GATE 4 re-checks it independently of this gate).
RV_NATIVE_SEC=$(jq -r '(.inputs.nativeSecurityReview // .nativeSecurityReview // empty) | ascii_downcase' "$RV" 2>/dev/null)
case "$RV_NATIVE_SEC" in
  clean|issues) : ;;
  *)
    SEC_STATE=$(sec_artifact_state)
    case "$SEC_STATE" in
      clean)
        # (2) An independent pass IS on record for this exact commit.
        : ;;
      missing)
        if [ "$NEED_SEC" = "true" ]; then
          deny "MERGE GATE (REWORK): the verdict is AUTO_MERGE and the native /security-review did not run (inputs.nativeSecurityReview = '${RV_NATIVE_SEC:-<missing>}'), so the independent security-reviewer artifact is the only thing that could back this merge — and .quetrex/security-findings.json does not exist. A security review is required here because $SEC_WHY. Run the security-reviewer agent against the current HEAD, then re-run the review-gate."
        fi
        # (3) Not required, nothing sensitive, no artifact to contradict: there
        #     is no security review to be independent ABOUT. Allow.
        ;;
      *)
        deny "MERGE GATE (ESCALATE_HUMAN): the verdict is AUTO_MERGE and the native /security-review did not run (inputs.nativeSecurityReview = '${RV_NATIVE_SEC:-<missing>}'), so .quetrex/security-findings.json must supply the independent pass — but that artifact is '$SEC_STATE'$([ "$SEC_STATE" = "stale" ] && printf ' (it records a different commit than HEAD %s)' "${HEAD_SHA:0:12}")$([ "$SEC_STATE" = "unpinned" ] && printf ' (it records no head_sha, so it proves nothing about this commit)')$([ "$SEC_STATE" = "critical" ] && printf ' (it has open Critical finding(s) — see GATE 4)'). Re-run the security-reviewer against the current HEAD so a pinned, clean finding set exists, or have a human decide."
        ;;
    esac
    ;;
esac

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

# A candidate above is flagged red for exiting non-zero, never running, OR
# carrying a sha that isn't HEAD. That last case is only GENUINELY stale when
# code actually changed since that green run: if the ledger itself is what
# got committed (moving HEAD) and nothing outside .quetrex/ changed since,
# the green proof still describes the code being merged. Re-check each
# sha-only mismatch against artifact_only_range_ok before treating it as
# red — a non-zero exit or a never-ran (null/empty sha) command is never
# rescued by this and always stays red.
if [ "$RED" != "[]" ]; then
  STILL_RED="[]"
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    e_exit=$(printf '%s' "$entry" | jq -r '.exit')
    e_sha=$(printf '%s' "$entry" | jq -r '.sha // empty')
    genuinely_red=1
    if [ "$e_exit" = "0" ] && [ -n "$e_sha" ] && [ -n "$HEAD_SHA" ] && artifact_only_range_ok "$e_sha" "$HEAD_SHA"; then
      genuinely_red=0
    fi
    if [ "$genuinely_red" -eq 1 ]; then
      STILL_RED=$(printf '%s' "$STILL_RED" | jq -c --argjson e "$entry" '. + [$e]' 2>/dev/null)
      [ -n "$STILL_RED" ] || STILL_RED="[]"
    fi
  done < <(printf '%s' "$RED" | jq -c '.[]' 2>/dev/null)
  RED="$STILL_RED"
fi

if [ "$RED" != "[]" ]; then
  SUMMARY=$(printf '%s' "$RED" | jq -r --arg head "$HEAD_SHA" 'map("  - `\(.cmd)` -> \(if .exit == null then "never ran (no ledger entry)" elif (.exit != 0) then "exit \(.exit)" else "STALE: last green was for commit \((.sha // "?")[0:12]), not HEAD \($head[0:12]) — re-run QA on the current commit" end)") | join("\n")' 2>/dev/null)
  deny "$(printf 'MERGE GATE (REWORK): the verify chain is not green for the commit being merged. The following command(s) are red, never ran, or stale (proven against a different commit):\n%s\nFix the code and let QA re-prove the chain green (every command exit 0) ON THE CURRENT HEAD before merging.' "$SUMMARY")"
fi

# ===========================================================================
# GATE 4 — security findings: no open Critical, pinned to HEAD; required-but-
#          missing is a failure. NON-BYPASSABLE-BY-OMISSION.
# ===========================================================================
# PLAN_SEC, SENSITIVE_DIFF, CHANGED, NEED_SEC and SEC_WHY are all computed in
# the PREAMBLE above (GATE 2b needs them too). This gate consumes them.
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
  if [ -n "$SEC_SHA" ] && [ -n "$HEAD_SHA" ] && [ "$SEC_SHA" != "$HEAD_SHA" ] && ! artifact_only_range_ok "$SEC_SHA" "$HEAD_SHA"; then
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
# GATE 5 — every changed file is covered by the architect's ownership map
# ===========================================================================
# The whole parallel-developer architecture rests on ONE artifact: the
# architect's zero-overlap file-ownership map (architect.md calls it "the
# enforceable contract developers are held to"). Until this gate existed, that
# contract was enforced by nobody — it appeared exactly once downstream, as
# prose in reviewer.md asking an LLM to notice. A developer that edited outside
# its lane produced the classic silent failure: a clean summary, an unexpected
# file, and every other gate green because none of them look at file paths.
#
# This gate looks. It reuses $CHANGED — the same diff GATE 4 already computed
# against the base branch — and asserts each path is claimed either by an
# explicit `ownership` key or by some workstream's `owns` glob.
#
# NO PLAN -> SKIP, NOT FAIL. Deliberate, and the same shape as GATE 4 directly
# above: GATE 4 reads the plan for security_review_required and, when no plan
# exists, does not synthesize a failure — it falls back to a floor derived from
# the diff itself. Here there is no equivalent floor: with no plan there is no
# ownership map, and "unowned" is undefined rather than violated. TRIVIAL and
# SIMPLE routes legitimately run without an architect, so failing closed on a
# missing plan would deny merges for work that never had lanes to stay in —
# a liveness break, not a safety win. When a plan DOES exist the gate is strict:
# a plan carrying no ownership map at all is a malformed artifact and escalates.
#
# WHICH plan governs is resolved more strictly here than in GATE 4. GATE 4 can
# afford `ls | head -n1` because its worst case is requiring a security review
# that was not strictly needed. GATE 5's worst case is denying a clean merge for
# violating ANOTHER task's lanes, so it refuses to guess: it uses the plan named
# by state.json, or the single plan on disk, and escalates when several plans
# exist and nothing says which one this merge is for.
PLAN5=""
if [ -n "$TASK" ] && [ -f "$QDIR/plan/$TASK.json" ]; then
  PLAN5="$QDIR/plan/$TASK.json"
else
  PLAN_COUNT=$(ls -1 "$QDIR"/plan/*.json 2>/dev/null | wc -l | tr -d ' ')
  case "$PLAN_COUNT" in ''|*[!0-9]*) PLAN_COUNT=0 ;; esac
  if [ "$PLAN_COUNT" -eq 1 ]; then
    PLAN5=$(ls -1 "$QDIR"/plan/*.json 2>/dev/null | head -n1)
  elif [ "$PLAN_COUNT" -gt 1 ]; then
    deny "MERGE GATE (ESCALATE_HUMAN): .quetrex/plan/ holds $PLAN_COUNT plan artifacts and .quetrex/state.json does not name the task this merge is for${TASK:+ (it names '$TASK', but .quetrex/plan/$TASK.json does not exist)}, so the gate cannot tell which file-ownership map governs this diff. It will not guess — checking the diff against the wrong task's lanes would reject clean work. Repair .quetrex/state.json (or remove the stale plans) and re-run the review-gate."
  fi
  # PLAN_COUNT == 0 -> no plan artifact at all -> skip, per the note above.
fi

if [ -n "$PLAN5" ] && [ -f "$PLAN5" ]; then
  # Does this plan carry an ownership contract at all?
  OWN_KEYS=$(jq -r '(.ownership // {}) | keys_unsorted[]?' "$PLAN5" 2>/dev/null)
  OWN_GLOBS=$(jq -r '(.workstreams // []) | .[]? | (.owns // [])[]?' "$PLAN5" 2>/dev/null)

  if [ -z "$OWN_KEYS" ] && [ -z "$OWN_GLOBS" ]; then
    deny "MERGE GATE (ESCALATE_HUMAN): the plan artifact $(basename "$PLAN5") exists but declares NO file-ownership map (no .ownership entries and no .workstreams[].owns globs). Ownership is the enforceable contract the parallel-developer pipeline depends on, so a plan without it cannot be checked against the diff. The plan is malformed or partial — do not merge. Surface to the user and re-run the architect."
  fi

  # Paths that are never owned by a workstream and must not trip the gate:
  #   .quetrex/**  — the control-plane artifacts this very gate reads. They are
  #                  written by the pipeline itself (plan, ledger, verdict,
  #                  state), not by a developer working a lane.
  #   lockfiles    — regenerated as a side effect of any dependency change, by
  #                  whichever workstream happened to install. Owning them would
  #                  force a false overlap between otherwise-disjoint lanes.
  is_exempt_path() {
    case "$1" in
      .quetrex/*) return 0 ;;
    esac
    case "$(basename "$1")" in
      package-lock.json|npm-shrinkwrap.json|yarn.lock|pnpm-lock.yaml|bun.lock|bun.lockb) return 0 ;;
      Cargo.lock|poetry.lock|uv.lock|Pipfile.lock|Gemfile.lock|composer.lock|go.sum|flake.lock|gradle.lockfile|packages.lock.json) return 0 ;;
    esac
    return 1
  }

  # A path is owned if an `ownership` key matches it exactly, or if it matches
  # any workstream `owns` glob. Bash pattern matching is used unquoted on the
  # right of `==` so the glob expands; `**` behaves as `*` here and matches
  # across `/`, which is the intent for a `src/api/**` style lane.
  is_owned_path() {
    local p="$1" k g
    while IFS= read -r k; do
      [ -n "$k" ] && [ "$k" = "$p" ] && return 0
    done <<< "$OWN_KEYS"
    while IFS= read -r g; do
      [ -z "$g" ] && continue
      # shellcheck disable=SC2053
      [[ "$p" == $g ]] && return 0
    done <<< "$OWN_GLOBS"
    return 1
  }

  UNOWNED=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    is_exempt_path "$f" && continue
    is_owned_path "$f" && continue
    UNOWNED="${UNOWNED}  - ${f}"$'\n'
  done <<< "$CHANGED"

  if [ -n "$UNOWNED" ]; then
    deny "$(printf 'MERGE GATE (REWORK): the diff being merged touches file(s) that NO workstream owns in the architect'"'"'s plan (%s):\n%s\nThe ownership map is the contract that keeps parallel developers from colliding — an edit outside every declared lane is unplanned work that no reviewer signed off on. Send this back through the pipeline: either revert the out-of-lane change, or have the architect re-plan so the file is owned by exactly one workstream, then re-run review. (.quetrex/** and lockfiles are exempt and are not listed here.)' "$(basename "$PLAN5")" "$UNOWNED")"
  fi
fi

# ===========================================================================
# ALL GATES GREEN — allow the merge (no prompt; this IS the auto-merge path).
# ===========================================================================
# Emitting no JSON on a PreToolUse hook means "no decision" -> normal permission
# flow proceeds and the merge runs. Under the new policy an AUTO_MERGE verdict
# with a green ledger and no open Critical is a clean, human-free ship.
exit 0
