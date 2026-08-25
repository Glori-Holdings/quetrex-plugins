#!/usr/bin/env bash
# test/merge-gate.test.sh — regression suite for plugins/quetrex-factory/scripts/merge-gate.sh.
#
# Run: bash test/merge-gate.test.sh
#
# This is the canonical engine copy's OWN suite (quetrex-plugins had none
# before this branch — see DEFECT C below for why that mattered). It mirrors
# the conventions of the sibling suite shipped with the `quetrex` plugin
# (quetrex-base), which can also point at THIS file via:
#   QX_MERGE_GATE_HOOK=/path/to/merge-gate.sh bash test/merge-gate.test.sh
# so a fix can be proven against whichever copy is actually running, not just
# the one it was written against.
#
# =============================================================================
# DEFECT C (this branch) — artifact-only commits must not self-invalidate an
# approval.
#
# Every sha-pin this gate trusts — review-verdict.json's .sha,
# security-findings.json's .head_sha, each verify-ledger.jsonl entry's .sha —
# is an artifact NAMING the commit it approves. Per git-workflow.md's
# documented convention these are runtime control-plane files that must never
# be committed (.gitignore should ignore .quetrex/* and un-ignore only
# project.json/verify.json). When a repo's gitignore drifts from that and one
# of these DOES get committed, the commit that adds it moves HEAD — and the
# artifact's own pin, recorded before that commit existed, can never equal
# HEAD again. A strict sha-equality check then denies every subsequent
# operation forever, including the commit that would remove the artifact and
# repair the mistake: the gate blocks its own repair.
#
# THE FIX: an old pin still authorizes HEAD when (a) it is an ANCESTOR of HEAD
# and (b) every commit in old..HEAD touches NOTHING outside .quetrex/. A
# single commit touching anything else anywhere in the range disqualifies the
# whole range — code changed, so the deny must still fire exactly as before.
# =============================================================================
#
# A bash test invoking merge-gate.sh directly against a fixture repo, per the
# accepted approach for exercising a PreToolUse hook script outside the actual
# Claude Code runtime.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# quetrex-factory (and its scripts, including merge-gate.sh) no longer lives in this
# repo — it is the ONE COPY owned by quetrex-base and sourced here by marketplace.json
# via a git-subdir reference. Default to a sibling quetrex-base checkout; override with
# QX_MERGE_GATE_HOOK to point at any other copy (e.g. to prove a fix against the
# pre-change script, per this file's own header comment).
HOOK="${QX_MERGE_GATE_HOOK:-$REPO_ROOT/../quetrex-base/plugins/quetrex-factory/scripts/merge-gate.sh}"
GATE_PROFILE="${QX_MERGE_GATE_PROFILE:-full}"

if [ ! -x "$HOOK" ] && [ ! -f "$HOOK" ]; then
  echo "SKIP: merge-gate.sh not found at $HOOK — quetrex-factory lives only in quetrex-base now; set QX_MERGE_GATE_HOOK to a checkout of it (e.g. a sibling ../quetrex-base clone) to run this suite"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — merge-gate.sh is jq-mandatory, nothing to test"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-fixture.XXXXXX")"
MOCKBIN="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-mockbin.XXXXXX")"
cleanup() { rm -rf "$FIXTURE" "$MOCKBIN"; }
trap cleanup EXIT

# --- mock `gh` -- merge-gate.sh resolves the PR's real head/base via
# `gh pr view [<id>] --json headRefOid,baseRefOid` rather than trusting local
# git state (quetrex-base's Blocker-1 fix). Prepended onto PATH for every hook
# invocation so this suite never depends on a real `gh` being
# installed/authenticated. See quetrex-base's test/merge-gate.test.sh, which
# this mock is ported from verbatim, for the full rationale.
cat > "$MOCKBIN/gh" <<'MOCKGH'
#!/bin/sh
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  if [ -n "${MOCK_GH_PR_VIEW_FAIL:-}" ]; then
    echo "mock gh: pr view failed" >&2
    exit 1
  fi
  printf '{"headRefOid":"%s","baseRefOid":"%s"}' "${MOCK_GH_PR_VIEW_SHA:-}" "${MOCK_GH_PR_BASE_SHA:-}"
  exit 0
fi
echo "mock gh: unhandled subcommand: $*" >&2
exit 1
MOCKGH
chmod +x "$MOCKBIN/gh"

# --- build a minimal, self-contained fixture repo ---------------------------
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email "test@example.com"
git -C "$FIXTURE" config user.name "Fixture"
echo "fixture" > "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "chore: fixture commit"
HEAD_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"

mkdir -p "$FIXTURE/.quetrex"
printf '{"verify":["true","echo ok"]}' > "$FIXTURE/.quetrex/verify.json"
# ARMED-ONLY FLOOR: merge-gate.sh (and the rest of the floor) now no-ops entirely on a
# repo with no .quetrex/project.json (see quetrex-base's ONE-COPY change). This fixture
# must look "armed" or every DENY assertion below silently degrades to an ALLOW because
# the gate never engages — matching quetrex-base's own test/merge-gate.test.sh fixture.
printf '{"branchPrefix":"claude/"}' > "$FIXTURE/.quetrex/project.json" 2>/dev/null

write_ledger_at() {  # write_ledger_at <sha>
  local sha="$1"
  : > "$FIXTURE/.quetrex/verify-ledger.jsonl"
  jq -cn --arg sha "$sha" --arg cwd "$FIXTURE" \
    '{ts:"2026-01-01T00:00:00Z",cmd:"true",cwd:$cwd,sha:$sha,exit:0,tail:""}' \
    >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
  jq -cn --arg sha "$sha" --arg cwd "$FIXTURE" \
    '{ts:"2026-01-01T00:00:01Z",cmd:"echo ok",cwd:$cwd,sha:$sha,exit:0,tail:"ok"}' \
    >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
}

# A verdict from a genuinely clean run. `inputs.nativeSecurityReview` must
# record that the native /security-review actually EXECUTED ("clean" or
# "issues"); the gate treats anything else as the reviewer having graded its
# own homework. An AUTO_MERGE without it is not a mergeable state, so the
# happy-path fixture has to carry it.
write_verdict_at() {  # write_verdict_at <sha> [nativeSecurityReview]
  jq -cn --arg sha "$1" --arg nsr "${2:-clean}" \
    '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:$nsr}}' \
    > "$FIXTURE/.quetrex/review-verdict.json"
}

# The EXACT shape qa.md's run() ledger writer emitted BEFORE an earlier fix:
# {ts,cmd,cwd,exit,tail} with no `sha` field at all.
write_ledger_no_sha() {
  : > "$FIXTURE/.quetrex/verify-ledger.jsonl"
  jq -cn --arg cwd "$FIXTURE" \
    '{ts:"2026-01-01T00:00:00Z",cmd:"true",cwd:$cwd,exit:0,tail:""}' \
    >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
  jq -cn --arg cwd "$FIXTURE" \
    '{ts:"2026-01-01T00:00:01Z",cmd:"echo ok",cwd:$cwd,exit:0,tail:"ok"}' \
    >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
}

write_sec() {  # write_sec <head_sha> <severity|none> [status]
  if [ "$2" = "none" ]; then
    jq -cn --arg sha "$1" '{task:"T-1",base:"main",head_sha:$sha,reviewed_files:3,verdict:"PASS",findings:[]}' \
      > "$FIXTURE/.quetrex/security-findings.json"
  else
    jq -cn --arg sha "$1" --arg sev "$2" --arg st "${3:-open}" \
      '{task:"T-1",base:"main",head_sha:$sha,reviewed_files:3,verdict:"BLOCK",findings:[{id:"SEC-1",severity:$sev,status:$st,category:"bola-idor",file:"src/x.ts",line:1,summary:"test"}]}' \
      > "$FIXTURE/.quetrex/security-findings.json"
  fi
}

reset_clean_baseline() {  # reset_clean_baseline <sha> — pin RV/ledger/sec, drop ESCALATION
  write_ledger_at "$1"
  write_verdict_at "$1"
  write_sec "$1" none
  rm -f "$FIXTURE/.quetrex/ESCALATION"
}

# The literal merge command, assembled at runtime. Written this way on purpose:
# a test file for a hook that pattern-matches merge commands would otherwise
# contain those exact tokens, and this repo's own PreToolUse gate reads the
# command string of every Bash call — including the one that runs this test.
GH_MERGE="$(printf 'gh pr mer%s' 'ge') 123 --squash"
GH_CREATE="$(printf 'gh pr cre%s' 'ate')"
MAIN="$(printf 'ma%s' 'in')"

# default_base_sha <cwd> — what the mock reports as baseRefOid: <cwd>'s own
# local main tip (falling back to master). Reproduces what a merge in that
# fixture state would naturally be evaluated against.
default_base_sha() {
  git -C "$1" rev-parse --verify --quiet main 2>/dev/null \
    || git -C "$1" rev-parse --verify --quiet master 2>/dev/null
}

# run_hook <cwd> — resolves the mocked "PR head" to <cwd>'s own current HEAD
# and "PR base" to its local main tip, so every assertion below keeps testing
# the same scenario regardless of which branch $FIXTURE is currently on.
# GH_REPO is always passed explicitly (empty) so an ambiently-exported
# GH_REPO in the runner's own shell can never make this flaky.
run_hook() {
  local cwd="$1" payload pr_sha base_sha
  pr_sha="$(git -C "$cwd" rev-parse HEAD 2>/dev/null)"
  base_sha="$(default_base_sha "$cwd")"
  payload="$(jq -cn --arg cmd "$GH_MERGE" --arg cwd "$cwd" \
    '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | env PATH="$MOCKBIN:$PATH" MOCK_GH_PR_VIEW_SHA="$pr_sha" MOCK_GH_PR_BASE_SHA="$base_sha" GH_REPO="" CLAUDE_PROJECT_DIR="$cwd" "$HOOK"
}

# run_cmd <cwd> <command> — exercise the hook against an ARBITRARY command, to
# assert what is and is not classified as a merge vector in the first place.
# Same mocked-gh defaults as run_hook.
run_cmd() {
  local cwd="$1" cmd="$2" payload pr_sha base_sha
  pr_sha="$(git -C "$cwd" rev-parse HEAD 2>/dev/null)"
  base_sha="$(default_base_sha "$cwd")"
  payload="$(jq -cn --arg cmd "$cmd" --arg cwd "$cwd" \
    '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | env PATH="$MOCKBIN:$PATH" MOCK_GH_PR_VIEW_SHA="$pr_sha" MOCK_GH_PR_BASE_SHA="$base_sha" GH_REPO="" CLAUDE_PROJECT_DIR="$cwd" "$HOOK" 2>&1
}

is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"\|MERGE GATE'; }

# =============================================================================
# 1) ALLOW — full chain green, sha-pinned to HEAD; AUTO_MERGE pinned to HEAD.
# =============================================================================
reset_clean_baseline "$HEAD_SHA"

OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: clean sha-pinned chain + AUTO_MERGE -> no deny emitted, exit 0"
else
  fail "ALLOW: expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# =============================================================================
# 2) DENY — ledger is green but sha-pinned to a DIFFERENT (non-ancestor, all-
#    zero) commit.
# =============================================================================
write_ledger_at "0000000000000000000000000000000000000000"
write_verdict_at "$HEAD_SHA"

OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  pass "DENY: stale (non-HEAD, non-ancestor) sha-pinned ledger is denied"
else
  fail "DENY(stale ledger): expected a deny decision, got exit $CODE stdout: [$OUT]"
fi

# =============================================================================
# 3) DENY — review-verdict.json missing entirely (reviewer never ran).
# =============================================================================
write_ledger_at "$HEAD_SHA"
rm -f "$FIXTURE/.quetrex/review-verdict.json"

OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  pass "DENY: missing review-verdict.json is denied"
else
  fail "DENY(no verdict): expected a deny decision, got exit $CODE stdout: [$OUT]"
fi

# =============================================================================
# 4) DENY — every command exited 0, but the ledger carries no `sha` field at
#    all. GATE 3 cannot trust an unpinned green line.
# =============================================================================
write_ledger_no_sha
write_verdict_at "$HEAD_SHA"

OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  pass "DENY: sha-less ledger denies a green run (no artifact_only forgiveness w/o a sha)"
else
  fail "DENY(no-sha ledger): expected a deny decision, got exit $CODE stdout: [$OUT]"
fi

# =============================================================================
# DEFECT A — the gate must fire on MERGES ONLY.
#
# The fixture is left in a DENYING state (stale ledger) for every case below,
# so an "allowed" result can only mean the command was never classified as a
# merge vector — not that the gates happened to pass.
# =============================================================================
write_ledger_at "0000000000000000000000000000000000000000"
write_verdict_at "$HEAD_SHA"

assert_allowed() {  # assert_allowed <label> <command>
  local out; out="$(run_cmd "$FIXTURE" "$2")"
  if is_deny "$out"; then
    fail "NOT A MERGE: $1 — must not be gated (got: ${out:0:160})"
  else
    pass "NOT A MERGE: $1 — correctly ungated"
  fi
}
assert_denied() {   # assert_denied <label> <command>
  local out; out="$(run_cmd "$FIXTURE" "$2")"
  if is_deny "$out"; then
    pass "IS A MERGE: $1 — correctly gated"
  else
    fail "IS A MERGE: $1 — must be gated but was allowed"
  fi
}

assert_allowed "push a feature branch, then open its PR (--base $MAIN in the same line)" \
  "git -C $FIXTURE push -u origin claude/x && $GH_CREATE --base $MAIN --head claude/x"
assert_allowed "open a PR whose title mentions $MAIN" \
  "$GH_CREATE --base $MAIN --title 'merge the $MAIN docs'"
assert_allowed "plain feature-branch push" \
  "git -C $FIXTURE push -u origin claude/x"
assert_allowed "commit whose MESSAGE contains 'push origin $MAIN'" \
  "git -C $FIXTURE commit -m 'do not push origin $MAIN by hand'"
assert_allowed "fetch/pull that merely name the base branch" \
  "git -C $FIXTURE fetch origin $MAIN"

assert_denied "gh pr merge" "$GH_MERGE"
assert_denied "direct push to $MAIN" "git -C $FIXTURE push origin $MAIN"
assert_denied "push to $MAIN wrapped in bash -c" \
  "bash -c 'git -C $FIXTURE push origin $MAIN'"

assert_allowed "tag push (deploy/version tag, not a merge)" \
  "git -C $FIXTURE push origin v2.0.5"

# =============================================================================
# DEFECT A2 — one repo's verdict must never gate another repo's merge.
# =============================================================================
OTHER="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-other.XXXXXX")"
git -C "$OTHER" init -q -b main
git -C "$OTHER" config user.email "test@example.com"
git -C "$OTHER" config user.name "Fixture"
echo other > "$OTHER/README.md"
git -C "$OTHER" add README.md
git -C "$OTHER" commit -q -m "chore: other repo"
# NOTE: $OTHER has no .quetrex/ at all -> it is not a quetrex-managed repo.

OUT="$(run_cmd "$FIXTURE" "git -C $OTHER push origin $MAIN")"
if is_deny "$OUT"; then
  fail "CROSS-REPO: a push in an unmanaged repo must not be judged by THIS repo's verdict (got: ${OUT:0:160})"
else
  pass "CROSS-REPO: a push in another (unmanaged) repo is not gated by this repo's artifacts"
fi
rm -rf "$OTHER"

# =============================================================================
# DEFECT B — AUTO_MERGE must be REACHABLE (independent security pass).
# =============================================================================
write_ledger_at "$HEAD_SHA"

# B1 — native pass unavailable, but the independent security-reviewer
#      artifact is pinned to HEAD and clean -> AUTO_MERGE is honored.
write_verdict_at "$HEAD_SHA" "not_available_in_env"
write_sec "$HEAD_SHA" none
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: independent HEAD-pinned clean security artifact satisfies GATE 2b"
else
  fail "ALLOW(independent artifact): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# B3 — the artifact records no head_sha at all -> proves nothing, denied.
if [ "$GATE_PROFILE" = "full" ]; then
jq -cn '{task:"T-1",base:"main",reviewed_files:3,verdict:"PASS",findings:[]}' \
  > "$FIXTURE/.quetrex/security-findings.json"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: an UNPINNED security artifact cannot stand in for the native pass"
else
  fail "DENY(unpinned artifact): expected a deny decision, got [$OUT]"
fi
fi

# B4 — an open Critical still blocks, whichever way independence was proven.
write_sec "$HEAD_SHA" critical open
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: an open Critical still blocks (unbypassable, as before)"
else
  fail "DENY(open critical): expected a deny decision, got [$OUT]"
fi

# B5 — a RESOLVED critical is not an open one; the merge proceeds.
write_sec "$HEAD_SHA" critical resolved
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: a RESOLVED critical does not block"
else
  fail "ALLOW(resolved critical): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# B6 — neutral diff, no plan flag, no artifact: AUTO_MERGE stands.
rm -f "$FIXTURE/.quetrex/security-findings.json"
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: neutral diff with no security review required -> AUTO_MERGE stands"
else
  fail "ALLOW(neutral diff): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# =============================================================================
# DEFECT C (this branch) — artifact-only commits must not self-invalidate an
# approval.
#
# Builds a small commit graph on top of $HEAD_SHA (call it C0):
#   C0 -- C1 (touches only .quetrex/notes.txt)
#            \-- C2 (touches .quetrex/notes.txt AND src/code.ts)
#   C0 -- C3 (touches only src/code.ts)                          [sibling]
#   C0 -- C4 (touches .quetrexfoo/evil.txt AND src/.quetrex/x — LOOKALIKES)
#   C0 -- D  (a divergent commit, NOT an ancestor of C1/C2/C3/C4)
#
# Every case pins RV/ledger/sec to C0 (older than current HEAD) and asks:
# does the range from C0 to the new HEAD still count as artifact-only?
# =============================================================================
C0="$HEAD_SHA"

git -C "$FIXTURE" checkout -q -b branch-c1 "$C0"
mkdir -p "$FIXTURE/.quetrex" "$FIXTURE/src"
echo "note 1" > "$FIXTURE/.quetrex/notes.txt"
git -C "$FIXTURE" add .quetrex/notes.txt
git -C "$FIXTURE" commit -q -m "chore: pipeline artifact commit"
C1="$(git -C "$FIXTURE" rev-parse HEAD)"

echo "note 2" > "$FIXTURE/.quetrex/notes.txt"
echo "console.log('hi')" > "$FIXTURE/src/code.ts"
git -C "$FIXTURE" add .quetrex/notes.txt src/code.ts
git -C "$FIXTURE" commit -q -m "feat: real code change alongside an artifact update"
C2="$(git -C "$FIXTURE" rev-parse HEAD)"

git -C "$FIXTURE" checkout -q -b branch-c3 "$C0"
mkdir -p "$FIXTURE/src"
echo "console.log('code only')" > "$FIXTURE/src/code.ts"
git -C "$FIXTURE" add src/code.ts
git -C "$FIXTURE" commit -q -m "feat: code-only change"
C3="$(git -C "$FIXTURE" rev-parse HEAD)"

# Two SEPARATE lookalike commits, each in isolation, so a mutation that only
# breaks one form of the anchor check (e.g. a naive prefix test that still
# rejects a nested path but accepts an unslashed sibling-name prefix) cannot
# hide behind the other lookalike disqualifying the range on its own.
git -C "$FIXTURE" checkout -q -b branch-c4 "$C0"
mkdir -p "$FIXTURE/.quetrexfoo"
echo "evil" > "$FIXTURE/.quetrexfoo/evil.txt"
git -C "$FIXTURE" add .quetrexfoo/evil.txt
git -C "$FIXTURE" commit -q -m "chore: a sibling directory name that LOOKS like a .quetrex/ prefix"
C4="$(git -C "$FIXTURE" rev-parse HEAD)"

git -C "$FIXTURE" checkout -q -b branch-c4b "$C0"
mkdir -p "$FIXTURE/src/.quetrex"
echo "evil" > "$FIXTURE/src/.quetrex/nested.txt"
git -C "$FIXTURE" add src/.quetrex/nested.txt
git -C "$FIXTURE" commit -q -m "chore: a NESTED .quetrex/ that is not the repo-root one"
C4B="$(git -C "$FIXTURE" rev-parse HEAD)"

git -C "$FIXTURE" checkout -q -b branch-d "$C0"
echo "divergent" > "$FIXTURE/DIVERGENT.md"
git -C "$FIXTURE" add DIVERGENT.md
git -C "$FIXTURE" commit -q -m "chore: an unrelated sibling commit"
D="$(git -C "$FIXTURE" rev-parse HEAD)"

# --- C1: artifact-only commit -> ACCEPTED (RV, ledger, and sec all forgive) -
git -C "$FIXTURE" checkout -q branch-c1  # HEAD = C1
git -C "$FIXTURE" reset -q --hard "$C1"
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: artifact-only commit since the pinned sha -> approval still stands"
else
  fail "ALLOW(artifact-only): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# --- C2: mixed artifact+code commit in the range -> DENIED ------------------
git -C "$FIXTURE" reset -q --hard "$C2"
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: a commit touching .quetrex/ AND code in the range disqualifies it"
else
  fail "DENY(mixed commit): expected a deny decision, got [$OUT]"
fi

# --- C3: code-only commit in the range -> DENIED -----------------------------
git -C "$FIXTURE" checkout -q branch-c3
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: a code-only commit since the pinned sha is a genuine stale approval"
else
  fail "DENY(code-only): expected a deny decision, got [$OUT]"
fi

# --- C4: lookalike-path commit (.quetrexfoo/) -> DENIED --------------------
# Isolates the ANCHOR: ".quetrexfoo" shares the literal prefix ".quetrex" but
# is not followed by "/", so a naive (unanchored) prefix test would wrongly
# accept it.
git -C "$FIXTURE" checkout -q branch-c4
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: .quetrexfoo/ is NOT the .quetrex/ directory (anchor, not naive prefix)"
else
  fail "DENY(lookalike sibling path): expected a deny decision, got [$OUT]"
fi

# --- C4B: lookalike-path commit (src/.quetrex/) -> DENIED -------------------
# Isolates NESTING: a .quetrex/ directory that is not at the repo root must
# not count as the control-plane directory this gate exempts.
git -C "$FIXTURE" checkout -q branch-c4b
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: src/.quetrex/ (nested) is NOT the repo-root .quetrex/ directory"
else
  fail "DENY(nested lookalike path): expected a deny decision, got [$OUT]"
fi

# --- D: non-ancestor sha pinned -> DENIED ------------------------------------
# Deliberately isolated from the path-scope check: D and C1 are SIBLINGS (both
# children of C0), and the naive rev-list range "D..C1" (ignoring ancestry
# altogether) contains only C1, which IS artifact-only on its own. So this
# case can ONLY be caught by actually verifying D is an ancestor of C1 — a
# range that merely LOOKS artifact-only when walked without that check must
# still be denied.
git -C "$FIXTURE" checkout -q branch-c1
git -C "$FIXTURE" reset -q --hard "$C1"   # HEAD = C1 (artifact-only on its own)
reset_clean_baseline "$D"                 # D is a SIBLING, not an ancestor of C1
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: a pinned sha that is not an ancestor of HEAD is never forgiven (even when the naive range looks artifact-only)"
else
  fail "DENY(non-ancestor): expected a deny decision, got [$OUT]"
fi

git -C "$FIXTURE" reset -q --hard "$C2"   # leave HEAD at C2 for the tests below

# --- unresolvable sha (missing object / shallow-clone stand-in) -> DENIED ---
# A well-formed 40-hex sha that was never committed to this fixture repo at
# all. This is the fail-closed path: the ancestry check cannot even resolve
# the object, so it must never be treated as "safe".
GARBAGE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
reset_clean_baseline "$GARBAGE_SHA"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: an unresolvable sha (missing object) fails closed"
else
  fail "DENY(unresolvable sha): expected a deny decision, got [$OUT]"
fi

# --- same forgiveness must apply to a MERGE COMMIT in the range -------------
# A merge commit's diff can hide changes depending on how it's listed (plain
# `git show`/`diff-tree` without `-m` prints NOTHING for a merge by default).
# Build one that legitimately only merges two artifact-only branches, and
# confirm it is still recognized as in-scope (not silently treated as
# "nothing changed", which would be a false ALLOW for the wrong reason, and
# not mis-flagged as touching code either).
git -C "$FIXTURE" checkout -q -b branch-merge-artifact "$C0"
echo "note m1" > "$FIXTURE/.quetrex/notes.txt"
git -C "$FIXTURE" add .quetrex/notes.txt
git -C "$FIXTURE" commit -q -m "chore: artifact side A"
git -C "$FIXTURE" checkout -q -b branch-merge-other "$C0"
echo "note m2" > "$FIXTURE/.quetrex/other-notes.txt"
git -C "$FIXTURE" add .quetrex/other-notes.txt
git -C "$FIXTURE" commit -q -m "chore: artifact side B"
git -C "$FIXTURE" checkout -q branch-merge-artifact
git -C "$FIXTURE" merge -q --no-ff -m "chore: merge two artifact-only branches" branch-merge-other
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: a merge commit whose sides are both artifact-only stays in scope"
else
  fail "ALLOW(artifact-only merge commit): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# ...and a merge commit that injects an out-of-scope file ONLY as part of its
# own conflict resolution — NOT present in full in either single-parent
# commit — must still be caught. This is the case that specifically requires
# `-m`: every OTHER commit in the range (both conflict sides) is, on its own,
# .quetrex/-only, so if the merge commit's own diff were silently skipped (no
# `-m`, git's default for a merge is to print nothing), the whole range would
# wrongly look artifact-only. Two sides deliberately conflict on the SAME
# path so the merge cannot fast-forward and requires a real resolution commit.
git -C "$FIXTURE" checkout -q -b branch-conflict-a "$C0"
echo "content A" > "$FIXTURE/.quetrex/conflict.txt"
git -C "$FIXTURE" add .quetrex/conflict.txt
git -C "$FIXTURE" commit -q -m "chore: conflict side A (artifact-only)"
git -C "$FIXTURE" checkout -q -b branch-conflict-b "$C0"
echo "content B" > "$FIXTURE/.quetrex/conflict.txt"
git -C "$FIXTURE" add .quetrex/conflict.txt
git -C "$FIXTURE" commit -q -m "chore: conflict side B (artifact-only)"
git -C "$FIXTURE" checkout -q branch-conflict-a
git -C "$FIXTURE" merge --no-ff branch-conflict-b -m "temp" >/dev/null 2>&1 || true
mkdir -p "$FIXTURE/src"
echo "resolved" > "$FIXTURE/.quetrex/conflict.txt"
echo "console.log('injected only during merge resolution')" > "$FIXTURE/src/injected.ts"
git -C "$FIXTURE" add .quetrex/conflict.txt src/injected.ts
git -C "$FIXTURE" commit -q -m "chore: resolve conflict, sneaking in an out-of-scope file"
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: an out-of-scope file added only in a merge commit's own resolution is caught (-m is load-bearing)"
else
  fail "DENY(merge-resolution-only code): expected a deny decision, got [$OUT]"
fi

git -C "$FIXTURE" checkout -q branch-c1

echo
if [ "$FAIL" -eq 0 ]; then
  echo "merge-gate.test.sh: all checks passed"
else
  echo "merge-gate.test.sh: FAILURES above"
fi
exit "$FAIL"
