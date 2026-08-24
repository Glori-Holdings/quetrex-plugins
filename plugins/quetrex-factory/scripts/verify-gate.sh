#!/usr/bin/env bash
# verify-gate.sh — Stop + SubagentStop hook. THE core non-negotiable gate.
#
# PILLAR #1 (EXCELLENT CODE): an agent must NOT be able to finish while the
# project's verification chain is red. This hook binds the finish decision to
# the REAL exit codes of the project's verify commands — never to chat prose
# like "tests passing". If ANY command exits non-zero it emits
#   {"decision":"block","reason":"<failing tail>"}
# on exit 0 (the ONLY form Stop/SubagentStop honor), so the agent is handed the
# failure and told to fix it. A bounded self-heal counter caps the loop at
# QUETREX_VERIFY_MAX (default 3); on the cap it writes .quetrex/ESCALATION and
# blocks one final time telling the agent to STOP self-healing and surface to
# the user — so red code can never be silently reported as done.
#
# NON-NEGOTIABLE: there is NO way for red to pass and NO way to skip a fresh
# verification and coast on a stale-green ledger. Specifically:
#   - There is NO fast-skip. Every Stop/SubagentStop runs the chain and writes a
#     fresh ledger cycle. A clean working tree does NOT let a prior green stand
#     in for the current state (a green ledger line can be stale — from an older
#     commit, or written before the current change landed). Correctness beats the
#     cost of a rebuild; the right-size router already trims orchestration.
#   - There is NO env-error laundering. A command that exits non-zero is RED,
#     full stop — including exit 127 / "command not found" / ENOENT / "No such
#     file or directory". A real test or build failure that happens to mention a
#     missing file is a genuine failure, not a toolchain excuse. Missing tooling
#     or deps therefore surface as an honest block: the agent installs/fixes
#     (bounded self-heal) or, at the cap, escalates to the user.
#   - There is NO fail-open on a missing `jq`. With jq, block() emits a
#     well-formed {"decision":"block",...} on exit 0. WITHOUT jq it does not
#     hand-roll JSON escaping (a failing build's stderr carries tabs/CRs/ANSI
#     that would malform the payload, and a malformed payload is DROPPED and
#     read as ALLOW); it prints the reason to stderr and exits 2 — the hook
#     contract's other blocking channel, which has no JSON to malform. Either
#     way a missing dependency can never silently allow a red finish.
#   - There is NO fail-open on a hook timeout. The whole chain runs against an
#     internal wall-clock budget (QUETREX_VERIFY_BUDGET, default well under the
#     external Stop/SubagentStop hook timeout) with each command capped via
#     `timeout`/`gtimeout` (or a kill-watchdog fallback). Exhausting the budget
#     is RED, blocked with a clear time-budget reason — the chain can never
#     run long enough to be killed by the external timeout before it emits.
#
# Single source of truth for the chain (in priority order):
#   1. $ROOT/.quetrex/verify.json  -> .verify[]   (canonical; written by init)
#      On SubagentStop, if .verifyQuick[] is present and non-empty it is used
#      instead (a QUICK per-subagent chain) — a strict SUBSET that still blocks
#      red; it never weakens the gate below the full chain when unconfigured.
#      Subset-ness is MECHANICALLY ENFORCED here, not assumed: every
#      verifyQuick entry must be a byte-for-byte member of verify[]. verify.json
#      is a customer-editable file, so an unchecked verifyQuick would be an
#      arbitrary REPLACEMENT for the chain (`verifyQuick:["true"]` passes every
#      SubagentStop). On any mismatch the quick chain is discarded, the FULL
#      verify[] chain runs, and the block reason says why.
#      An OPTIONAL sibling field, `requiredEnv`, declares per-command env
#      dependencies: {"requiredEnv": {"<exact command string from verify[]>":
#      ["VAR_NAME", ...]}}. See "DECLARATIVE ENV SKIP" below.
#   2. $ROOT/.claude/CLAUDE.md      "## Verification" fenced command block
#   3. autodetect (package.json scripts / Makefile / pyproject / go.mod / Cargo)
# If none resolves, there is nothing to gate -> allow finish (exit 0).
#
# Worktree-safe root: $CLAUDE_PROJECT_DIR first, then `git rev-parse` from the
# session cwd. All artifacts live under $ROOT/.quetrex/.
#
# The ONLY conditions that allow finish without a block:
#   - not a git repo / no verify chain resolvable anywhere (nothing to gate), or
#   - the chain resolved AND every command either exited 0 or was declaratively
#     SKIPPED for a genuinely-absent required env var (PROVEN green by exit
#     codes; a skip is never itself a pass — see "DECLARATIVE ENV SKIP").
#
# Contract: Stop/SubagentStop hooks BLOCK via {"decision":"block","reason":...}
# printed on EXIT 0. Printing block JSON then exiting non-zero DISCARDS the JSON.
# This script therefore always `exit 0` after emitting, and emits nothing to
# stdout when it allows the finish.
#
# QUIET OUTPUT (no raw interpreter stack traces to the operator). A failing
# command's full captured stdout+stderr is written to $ROOT/.quetrex/verify-gate.log
# (mode 600, one run's worth per invocation) and NEVER interpolated into the
# block reason. The reason is a short, labelled summary (what ran, which
# checkout/branch, whether it BLOCKS) that references a log by path, capped
# at 3 lines, so an agent's closing message can report the summary and the log
# path without ever pasting a stack trace back at the operator.
#
# THE LOG SURVIVES THE VERY NEXT INVOCATION. verify-gate.log is recreated
# fresh EVERY run, so an agent's next SubagentStop (dispatched to investigate
# a block) would otherwise erase the failure. On RED only, the failing
# command's own output is ALSO preserved into verify-gate-failed.log (mode
# 600, same symlink-safe unlink-before-redirect), and the reason points there
# instead. A green/skip-only run never touches it; a new RED run replaces it.
#
# THERE IS NO PRIMARY-CHECKOUT DEFERRAL. This hook used to skip the chain in
# the repo's primary checkout whenever a linked worktree on the project's
# branchPrefix looked like it was "proven" by its own ledger. That skip was
# removed outright (SEC-1, high): `git worktree add -b claude/x decoy` is on
# the Bash allow-list and cost the gated agent exactly one command to
# permanently ungate the primary checkout, and every attempted proof
# requirement (a ledger line sha-pinned to the candidate's own HEAD) was
# fabricable by the same agent writing a JSON line into a file it fully
# controls, or by leaving a once-genuinely-proven worktree abandoned on disk
# forever. No attestation scheme can fix this class: any secret the check
# reads is readable by the agent it polices. There is now NO code path in
# this file that skips the chain based on any worktree, branch,
# project.json field, or environment override — every checkout, including
# the one with no linked worktree, always runs the chain here. The only skip
# that survives is the declarative, per-command, committed-only requiredEnv
# skip below.
#
# DECLARATIVE ENV SKIP. A command whose verify.json `requiredEnv` entry names a
# variable that is genuinely unavailable in THIS checkout is never executed —
# it is skipped pre-flight and reported with one plain "VERIFY SKIPPED" line
# naming the variable (never its value). This is PRE-FLIGHT and DECLARATIVE
# ONLY: it is never inferred by pattern-matching a command's output (that would
# be exactly the env-error laundering banned above). The ENTIRE requiredEnv
# mapping (and the `verify[]` membership check below) is read from the
# COMMITTED `.quetrex/verify.json` blob at the ONE sha this invocation pinned
# up front ($HEAD_SHA, captured once at the top of the script) — NEVER the
# working-tree file, and NEVER a fresh `HEAD` re-resolved mid-run (SEC-2), so a
# command that commits mid-chain cannot author the authorization for a LATER
# command in the SAME run. Trap: an EMPTY $HEAD_SHA (no commits yet) degrades
# `git show "$HEAD_SHA:path"` to `git show ":path"` (reads the INDEX,
# fail-OPEN), so should_skip_for_env returns 1 before any git show when
# $HEAD_SHA is empty. Reading the mapping live would let an agent
# pair a genuinely innocuous, reviewable one-line .env.example addition with
# an UNCOMMITTED command-to-variable association that skips an unrelated,
# already-failing command — the association, not the variable, is the part
# that must be visible in a reviewed diff. A skip fires ONLY when ALL of the
# following hold, so `requiredEnv` cannot be used to weaken the gate:
#   1. the command is byte-for-byte a member of the COMMITTED verify[] ARRAY
#      (type-asserted: a STRING `.verify` degrades jq's `index()` to a
#      SUBSTRING search, which would let any command that merely CONTAINS the
#      target as a substring pass this check — the type must be checked, not
#      assumed);
#   2. the variable name also appears as a NAME= key in the COMMITTED blob of
#      a tracked $ROOT/.env.example or $ROOT/.env.sample at HEAD (the repo
#      itself must declare it as required config, visible in a reviewed
#      diff — a tracked PATH with an uncommitted edit to the declaring line
#      does not count either);
#   3. the variable is unset-or-empty in the hook's own environment AND is not
#      a key in any of $ROOT/.env, .env.local, .env.development, .env.test that
#      exist in this checkout (those are dotenv-loaded at runtime, so their
#      presence means the command would have had the value).
# If the committed verify.json cannot be read at all (no HEAD, unreadable),
# NOTHING is treated as declared and no command is ever skipped.
# A skip writes a ledger line marked skipped:true / skipReason:requiredEnv / exit:null for that command (it is recorded, and it is not a pass), and a run
# that skipped anything must NOT clear a prior .quetrex/ESCALATION — only a run
# where every chain command genuinely executed and exited 0 may clear one.
#
# AMENDMENT (operator-approved, 2026-08-21, HOOKFIX): "no fast-skip" narrows to
# "no SKIP" — Stop/SubagentStop runs a BOUNDED QUICK chain under a wall-clock
# cap instead (see the heavy-filter/cap/QUETREX_VERIFY_FULL comments below).

set -uo pipefail

MAX_ATTEMPTS="${QUETREX_VERIFY_MAX:-3}"

# --- read hook input (best-effort; absence is fine) ------------------------
INPUT=""
if [ ! -t 0 ]; then INPUT=$(cat); fi
jqget() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }
SESSION_CWD=$(jqget '.cwd')
EVENT=$(jqget '.hook_event_name')

# --- resolve repo root (worktree-safe) -------------------------------------
ROOT=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  ROOT=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) \
    || ROOT="$CLAUDE_PROJECT_DIR"
fi
if [ -z "$ROOT" ] && [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  ROOT=$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null)
fi
if [ -z "$ROOT" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
fi
# Nothing to gate if we cannot locate a repo root.
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 0

QDIR="$ROOT/.quetrex"
LEDGER="$QDIR/verify-ledger.jsonl"
ATTEMPTS_FILE="$QDIR/verify-attempts"
ESCALATION="$QDIR/ESCALATION"

# The commit this verification run is proving. Recorded on every ledger line so
# the merge gate can COMMIT-PIN a green: a green line for an OLDER commit must
# never authorize a merge of a NEWER HEAD (closes the stale-green hole). Empty
# only if HEAD is unresolvable (e.g. a repo with no commits yet).
HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)
CUR_BRANCH=$(git -C "$ROOT" branch --show-current 2>/dev/null)

# On Stop AND SubagentStop we run the QUICK subset chain when the project
# defines one. QUICK_NOTE is set when a declared verifyQuick was REJECTED for
# not being a subset of verify[]; it is appended to any block reason.
#
# WHY STOP USES IT TOO (2026-08-18). No fast-skip means this fires after every
# turn, including pure conversation: full chain 133s vs quick 0.9s here. NOTHING
# IS SKIPPED — a real chain runs every turn, so there is no "already verified"
# record for the gated agent to forge. Shipping is still decided by the FULL
# chain: merge-gate GATE 3 refuses any merge without a green full-chain ledger
# pinned to HEAD. Trade: a broken test surfaces at the merge boundary.
QUICK=0
QUICK_NOTE=""
case "$EVENT" in Stop|SubagentStop) QUICK=1 ;; esac

[ "${QUETREX_VERIFY_FULL:-}" = "1" ] && QUICK=0  # widen-only: pre-change FULL chain

# --- fail-closed time budget -------------------------------------------------
# The chain below runs synchronously inside a Stop (900s) / SubagentStop
# (600s) hook timeout (wired in quetrex-install-project-gates.sh). If the
# chain runs long enough for the hook to be killed mid-run, no block is ever
# emitted -> the finish is silently allowed with the tree unproven (fail-open
# via timeout). To fail CLOSED instead, every verify command below runs under
# an internal time budget kept safely under the external hook timeout, with
# headroom; exhausting it is treated as RED, not skipped. QUETREX_VERIFY_BUDGET
# (seconds) overrides the default for either event, and lets a single tiny
# value prove the fail-closed path (e.g. QUETREX_VERIFY_BUDGET=2 with a
# `sleep 5` command in the chain produces a block).
BUDGET_DEFAULT=840
[ "$EVENT" = "SubagentStop" ] && BUDGET_DEFAULT=540
BUDGET_TOTAL="${QUETREX_VERIFY_BUDGET:-$BUDGET_DEFAULT}"
case "$BUDGET_TOTAL" in ''|*[!0-9]*) BUDGET_TOTAL="$BUDGET_DEFAULT" ;; esac
[ "$BUDGET_TOTAL" -gt 0 ] 2>/dev/null || BUDGET_TOTAL="$BUDGET_DEFAULT"

# Sourced-only helper (bounded quick-chain machinery: the cap, the
# declarative env-skip, the heavy-command filter) — see its own header for
# why it is a separate file. Never invoked directly.
# SEC-8 FAIL-CLOSED: if the helper is missing/unreadable, `source` fails but
# (with no `set -e`) the script would otherwise CONTINUE past it -- every
# later call to an undefined function (should_skip_for_env, in the run loop,
# once per command) would then print a raw "command not found" interpreter
# line to the operator on every single command, and the requiredEnv skip and
# heavy filter would both silently stop functioning. A missing dependency of
# the gate is a genuine failure, not something to run past: block once, with
# one labelled line, never a raw stack trace.
QX_HELPER="$(dirname "${BASH_SOURCE[0]}")/verify-gate-quick-chain.sh"
# shellcheck source=verify-gate-quick-chain.sh
if ! source "$QX_HELPER" 2>/dev/null || ! command -v qx_apply_quick_cap >/dev/null 2>&1; then
  printf 'VERIFY GATE MISCONFIGURED: required helper %s is missing or failed to load — refusing to run unverified. Reinstall/republish the plugin.
' "$QX_HELPER" >&2
  exit 2
fi
qx_apply_quick_cap

# --- helpers ---------------------------------------------------------------

# Emit a Stop/SubagentStop block and exit 0 (the only honored form).
# FAIL-CLOSED even when jq is unavailable: if jq were the only path and it is
# missing, the jq call would fail silently, NOTHING would reach stdout, and
# `exit 0` would still run -> Stop/SubagentStop treat "exit 0 + no decision
# JSON" as ALLOW, so every red build would finish as allowed.
#
# The no-jq fallback deliberately emits NO JSON. A hand-rolled escaper is a
# fail-open in disguise: the string being escaped is the tail of a FAILING
# BUILD's stderr, which routinely carries tabs, carriage returns, ANSI escapes
# and other raw control bytes that are illegal unescaped inside a JSON string.
# One of those produces malformed JSON, the runtime drops the undecodable
# payload, and "exit 0 + no decision" is read as ALLOW — exactly the red-finish
# this function exists to prevent. So instead of trying (and silently failing)
# to build JSON without jq, the fallback uses the OTHER blocking channel the
# hook contract provides: exit 2 is a blocking error whose stderr is fed back
# to the agent. There is no JSON to malform, so it cannot degrade to allow.
# jq stays the primary path because it produces the richer `reason` form.
block() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$reason" '{decision:"block",reason:$r}'
    exit 0
  fi
  printf '%s\n' "$reason" >&2
  exit 2
}

# Last-20-lines of a captured output.
tail20() { printf '%s' "$1" | tail -n 20; }

# --- resolve the verification chain ----------------------------------------
# Populates the array CHAIN with ordered command strings.
CHAIN=()

resolve_from_verify_json() {
  local f="$QDIR/verify.json"
  [ -f "$f" ] || return 1
  # Prefer .verifyQuick[] on SubagentStop when it is present and non-empty;
  # otherwise the full .verify[] chain. Never weaken to quick when unconfigured.
  #
  # SUBSET IS ENFORCED, NOT ASSUMED. verify.json lives in the CUSTOMER's repo,
  # so verifyQuick is an untrusted input on the finish path. Without this check
  # `"verifyQuick": ["true"]` — or any command not in the full chain — would
  # pass every SubagentStop, turning the quick chain into an arbitrary
  # replacement for the gate rather than a narrowing of it. A quick chain may
  # only ever be a SUBSET of verify[]: every entry must be a member of
  # verify[], byte-for-byte. On ANY mismatch (a foreign command, a non-array
  # verify, a missing verify) we do NOT trust it — we run the FULL verify[]
  # chain instead and say so in the block reason, so the misconfiguration is
  # visible rather than silently weakening the gate.
  local sel='.verify'
  if [ "$QUICK" -eq 1 ] \
     && jq -e '.verifyQuick | type == "array" and length > 0' "$f" >/dev/null 2>&1; then
    if jq -e '
          ((.verify // null) | type) == "array"
          and ((.verifyQuick - .verify) | length) == 0
        ' "$f" >/dev/null 2>&1; then
      sel='.verifyQuick'
    else
      local foreign
      foreign=$(jq -r '
          (.verifyQuick - ((.verify // []) | if type == "array" then . else [] end))
          | map("`" + (. | tostring) + "`") | join(", ")
        ' "$f" 2>/dev/null)
      # Kept to a single line (no embedded newlines) so it can be appended to
      # a block reason without breaking the <=3-line quiet-output budget.
      QUICK_NOTE=$(printf ' NOTE: verifyQuick in verify.json is not a subset of verify (offending: %s); ran the bounded quick chain derived from verify[] instead.' \
        "${foreign:-<unparseable>}")
    fi
  fi
  jq -e "$sel | type == \"array\" and length > 0" "$f" >/dev/null 2>&1 || return 1
  while IFS= read -r line; do
    [ -n "$line" ] && CHAIN+=("$line")
  done < <(jq -r "$sel[]" "$f" 2>/dev/null)
  [ "${#CHAIN[@]}" -gt 0 ]
}

resolve_from_claude_md() {
  local f="$ROOT/.claude/CLAUDE.md"
  [ -f "$f" ] || return 1
  # Extract commands from fenced code blocks that fall under a heading whose
  # text contains "Verification". Awk state machine: track "in verification
  # section" and "inside a fenced block".
  #
  # RULE ORDER IS LOAD-BEARING. The fence toggle MUST be evaluated first, and
  # the heading rule MUST be gated on !infence. A shell comment inside the
  # fenced block starts with `#` and therefore matches the heading pattern; if
  # the heading rule ran first it would set insec=0 and `next`, silently
  # ENDING the section mid-chain and truncating every command below the
  # comment. That is a fail-open: a subset of the chain runs, reports green,
  # and is written to the ledger, which merge-gate.sh then reads as
  # authoritative for the WHOLE chain. With the fence evaluated first and the
  # heading rule gated on !infence, an in-fence `#` line falls through to the
  # emit rule, which skips it as a comment and keeps the section open.
  local extracted
  extracted=$(awk '
    /^[[:space:]]*```/ { infence = !infence; next }
    (!infence && $0 ~ /^#{1,6}[[:space:]]/) {
      insec = (tolower($0) ~ /verification/) ? 1 : 0
      next
    }
    (insec && infence) {
      line = $0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^#/) next          # skip blanks/comments
      sub(/^\$[[:space:]]*/, "", line)             # strip leading "$ " prompt
      print line
    }
  ' "$f" 2>/dev/null)
  while IFS= read -r line; do
    [ -n "$line" ] && CHAIN+=("$line")
  done < <(printf '%s\n' "$extracted")
  [ "${#CHAIN[@]}" -gt 0 ]
}

resolve_autodetect() {
  local pkg="$ROOT/package.json"
  if [ -f "$pkg" ]; then
    local key
    for key in typecheck type-check tsc lint build test; do
      if jq -e --arg k "$key" '.scripts[$k] // empty' "$pkg" >/dev/null 2>&1; then
        CHAIN+=("npm run $key")
      fi
    done
    [ "${#CHAIN[@]}" -gt 0 ] && return 0
  fi
  if [ -f "$ROOT/Makefile" ] || [ -f "$ROOT/makefile" ]; then
    local mk; mk="$ROOT/Makefile"; [ -f "$mk" ] || mk="$ROOT/makefile"
    grep -qE '^(lint|build|test|check):' "$mk" 2>/dev/null && {
      grep -qE '^lint:'  "$mk" && CHAIN+=("make lint")
      grep -qE '^build:' "$mk" && CHAIN+=("make build")
      grep -qE '^test:'  "$mk" && CHAIN+=("make test")
      grep -qE '^check:' "$mk" && CHAIN+=("make check")
      return 0
    }
  fi
  if [ -f "$ROOT/pyproject.toml" ] || [ -f "$ROOT/setup.cfg" ]; then
    CHAIN+=("python -m pytest -q"); return 0
  fi
  if [ -f "$ROOT/go.mod" ]; then
    CHAIN+=("go build ./..." "go test ./..."); return 0
  fi
  if [ -f "$ROOT/Cargo.toml" ]; then
    CHAIN+=("cargo build" "cargo test"); return 0
  fi
  return 1
}

resolve_from_verify_json || resolve_from_claude_md || resolve_autodetect || {
  # No chain resolvable anywhere -> nothing to gate.
  exit 0
}

mkdir -p "$QDIR"

# DECLARATIVE ENV SKIP (should_skip_for_env) and the heavy-command filter
# (qx_filter_heavy_chain) are defined in verify-gate-quick-chain.sh, sourced
# above — see that file for the full, unabridged contract (SEC-2, the three
# skip constraints, the CORRECTED empty-filter fallback). Order matters: the
# filter must run AFTER should_skip_for_env is defined (it calls it) and
# BEFORE the run loop below (which also calls should_skip_for_env, per
# command, to actually record the skip).
qx_filter_heavy_chain

# --- full-output log (QUIET fix part a) -------------------------------------
# Every command's FULL captured stdout+stderr is written here, never into the
# block reason. Recreated fresh each run so it always reflects THIS attempt.
# Mode 600 from creation: a failing build's output can contain values it
# echoed (the observed case was a database URL), so this file must never be
# group/world readable and must never be referenced by anything that stages
# files (it stays untracked under $ROOT/.quetrex/, which is gitignored).
LOG="$QDIR/verify-gate.log"
# SEC-3: refuse to write THROUGH a symlink. `: > "$LOG"` follows symlinks, so
# a symlink planted at this path would let the hook truncate, chmod 600, and
# append captured build output to any file the user can write. Unlinking
# whatever is at that path first (symlink or regular file) — before ever
# redirecting into it — makes the mode-600 guarantee unconditional instead of
# dependent on whichever inode happened to be there already; `rm -f` on a
# symlink removes the link itself, never the file it points at.
if [ -e "$LOG" ] || [ -L "$LOG" ]; then
  rm -f "$LOG" 2>/dev/null
fi
( umask 077; : > "$LOG" ) 2>/dev/null
chmod 600 "$LOG" 2>/dev/null

# --- run the chain ---------------------------------------------------------
# Always run — no fast-skip, no stale-green. Every non-zero exit is RED. There
# is no env-error laundering: a command that exits non-zero fails the gate even
# if its output mentions ENOENT / "No such file or directory" / "command not
# found". Missing tooling/deps are handed to the agent to fix (bounded), not
# excused into a green finish.
RED=0
SKIPPED=0
SKIP_LINES=""
SKIPPED_CMDS=""
FAILED_CMD=""
FAILED_TAIL=""
FAILED_CODE=0
TIMED_OUT=0
CAP_HIT=0   # QUICK-path cap cut a command short (bounded fail-OPEN, not a green)
CAP_CMD=""

# Run a single command under a wall-clock cap so a hang cannot silently burn
# through the external hook timeout. Prefers GNU `timeout`/`gtimeout`; if
# neither is installed, falls back to a background watchdog that SIGKILLs
# the command when its slice of the budget elapses — the chain must never be
# allowed to run unbounded regardless of what's on PATH. Sets CMD_OUT/CMD_CODE.
run_with_cap() {
  local cmd="$1" cap="$2"
  local tmo=""
  if command -v timeout >/dev/null 2>&1; then tmo="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then tmo="gtimeout"
  fi
  if [ -n "$tmo" ]; then
    CMD_OUT=$( ( cd "$ROOT" && "$tmo" -k 5 "${cap}s" bash -c "$cmd" ) 2>&1 )
    CMD_CODE=$?
  else
    local outfile
    outfile=$(mktemp "${TMPDIR:-/tmp}/quetrex-verify-out.XXXXXX" 2>/dev/null) || outfile="$QDIR/.verify-out.$$"
    ( cd "$ROOT" && bash -c "$cmd" ) >"$outfile" 2>&1 &
    local cpid=$!
    ( sleep "$cap"; kill -9 "$cpid" 2>/dev/null ) &
    local wpid=$!
    wait "$cpid" 2>/dev/null; CMD_CODE=$?
    kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
    CMD_OUT=$(cat "$outfile" 2>/dev/null)
    rm -f "$outfile" 2>/dev/null
  fi
}

BUDGET_START=$(date +%s)

for ((CHAIN_IDX=0; CHAIN_IDX<${#CHAIN[@]}; CHAIN_IDX++)); do
  cmd="${CHAIN[$CHAIN_IDX]}"
  if should_skip_for_env "$cmd"; then
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    {
      printf '=== %s | SKIPPED (requiredEnv %s unavailable) | cmd: %s | cwd: %s ===\n' \
        "$ts" "$MISSING_ENV_VAR" "$cmd" "$ROOT"
    } >> "$LOG" 2>/dev/null
    SKIPPED=1
    SKIP_LINES="${SKIP_LINES}VERIFY SKIPPED: \`${cmd}\` not run in ${ROOT} — required env var ${MISSING_ENV_VAR} is unavailable in this checkout (declared in .env.example, unset here). BLOCKS nothing; the command is never proven and never counted as a pass.
"
    SKIPPED_CMDS="${SKIPPED_CMDS:+$SKIPPED_CMDS, }\`${cmd}\`"
    # RECORD THE SKIP IN THE LEDGER. This `continue` used to return before the ledger
    # append below, so a declared-env skip left NO entry at all — and merge-gate's GATE 3
    # requires an entry per chain command, reading absence as "never ran, deny". The two
    # hooks therefore disagreed about what a sanctioned skip means: this one says "BLOCKS
    # nothing", that one says "unprovable". Measured consequence in quetrex-demo, whose
    # verify.json declares DEMO_DATABASE_URL for `npm run build`: with the var unset, that
    # command was unprovable FOREVER, so no PR in the repo could pass GATE 3 — every
    # ledger in its history carries lint and test and never build.
    #
    # The skip is a legitimate, human-confirmed state (the requiredEnv map is committed and
    # `/quetrex:init` only writes it after an explicit confirmation), so it belongs in the
    # evidence rather than in a log nobody parses. It is recorded as skipped — NOT as
    # exit 0 — so nothing can mistake it for a pass: `exit` stays null and `skipped` is
    # true. merge-gate decides what a skip is worth; this hook's job is to state it.
    if [ -n "${LEDGER:-}" ] && [ -n "${HEAD_SHA:-}" ]; then
      # jq, not node, and NOT swallowed. Every other ledger append in this file uses jq, and
      # should_skip_for_env has already proven jq present to read requiredEnv at all. A
      # `node -e ... || true` here vanished silently in an armed repo without node — and the
      # skip entry vanishing is exactly the deadlock this change exists to close.
      jq -cn \
        --arg ts "$ts" --arg cmd "$cmd" --arg cwd "$ROOT" \
        --arg sha "$HEAD_SHA" --arg v "$MISSING_ENV_VAR" \
        '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:null,skipped:true,skipReason:"requiredEnv",missingEnv:$v,tail:("SKIPPED: required env var "+$v+" is unavailable in this checkout")}' \
        >> "$LEDGER"
    fi
    continue
  fi
  now=$(date +%s)
  remaining=$((BUDGET_TOTAL - (now - BUDGET_START)))
  if [ "$remaining" -le 0 ]; then
    code=124; TIMED_OUT=1
    out="TIME BUDGET EXHAUSTED (${BUDGET_TOTAL}s) before this command could run."
  else
    # SEC-2 FIX: TIMED_OUT must be determined from MEASURED ELAPSED TIME
    # against the cap, never from exit code alone. A command that itself
    # genuinely exits 124/137 (e.g. its own internal `timeout N cmd`, or a
    # self-directed kill) in well under its cap window is a REAL failure —
    # inferring "our watchdog fired" from the bare exit code alone silently
    # laundered exactly that into a CAP-ALLOW (fail-open) in the pre-fix
    # code. Only when the ELAPSED wall-clock time is itself close to (within
    # a small margin of) the cap actually granted is this attributable to
    # OUR OWN timeout wrapper.
    CMD_START=$(date +%s)
    run_with_cap "$cmd" "$remaining"
    CMD_ELAPSED=$(( $(date +%s) - CMD_START ))
    code="$CMD_CODE"
    out="$CMD_OUT"
    CAP_MARGIN=2
    CAP_FLOOR=$(( remaining > CAP_MARGIN ? remaining - CAP_MARGIN : 0 ))
    if { [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; } && [ "$CMD_ELAPSED" -ge "$CAP_FLOOR" ]; then
      TIMED_OUT=1
      out="${out}
TIME BUDGET EXHAUSTED: exceeded its ${remaining}s share of the ${BUDGET_TOTAL}s budget and was killed."
    fi
  fi

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  t20=$(tail20 "$out")

  # Full, UNTRUNCATED output goes to the log file only — never into the block
  # reason (that is the whole point of the quiet fix; see header comment).
  {
    printf '=== %s | cmd: %s | exit: %s | cwd: %s ===\n' "$ts" "$cmd" "$code" "$ROOT"
    printf '%s\n' "$out"
  } >> "$LOG" 2>/dev/null

  # CAP-ALLOW: bounded fail-OPEN, QUICK only — NOT RED. SEC-1/SEC-3 FIX
  # (2026-08-21): writes a boundedQuick SKIP ledger line for THIS cut
  # command and every REMAINING, never-attempted command in the resolved
  # chain — never NO line at all. Absence was indistinguishable from "never
  # configured", which broke merge-gate's ledger-derived-chain fallback in
  # both directions (a red suite could ship when no verify.json existed; a
  # real chain could be denied forever once a command's only evidence
  # vanished). A boundedQuick line is never proof; merge-gate.sh's own
  # arbitration (out of this file's ownership) is what makes that true.
  if [ "$TIMED_OUT" -eq 1 ] && [ "$QUICK" -eq 1 ]; then
    CAP_HIT=1; CAP_CMD="$cmd"
    # SEC-15 (LOW, security review 2026-08-21 — downgraded from an earlier
    # ordering attempt that was CORRECTLY rejected as SEC-19): these
    # boundedQuick lines are a plain, strict append, same as every other
    # ledger write in this file — no read, no truncate, no reordering. The
    # ledger's LAST line can therefore still be a boundedQuick skip even
    # when an earlier command in this SAME run genuinely completed; that
    # residual is accepted, open, LOW severity, per operator directive —
    # append-only wins over exact tail-line ordering. See
    # qx_write_bounded_skips_for_cap in verify-gate-quick-chain.sh.
    qx_write_bounded_skips_for_cap "$CHAIN_IDX"
    break
  fi

  # Append to the append-only ledger (best-effort; failure to log never blocks).
  # `sha` pins this result to the exact commit it was proven against — the merge
  # gate requires the latest GREEN line for each chain command to carry the
  # CURRENT HEAD sha, so a stale green from an earlier commit cannot pass.
  jq -cn \
    --arg ts "$ts" --arg cmd "$cmd" --arg cwd "$ROOT" \
    --arg sha "$HEAD_SHA" \
    --argjson exit "$code" --arg tail "$t20" \
    '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:$exit,tail:$tail}' >> "$LEDGER" 2>/dev/null

  if [ "$code" -eq 0 ]; then
    continue
  fi

  # ANY non-zero exit is a genuine failure. Record it and stop the chain.
  RED=1
  FAILED_CMD="$cmd"
  FAILED_CODE="$code"
  FAILED_TAIL="$t20"

  # Preserve ONLY this failing command's entry (never an earlier, successful
  # command's output) into a second, bounded, mode-600 slot that survives the
  # next invocation — $LOG itself gets unlinked+recreated every run. Same
  # symlink-safe unlink-before-redirect as $LOG (SEC-3).
  FAILLOG="$QDIR/verify-gate-failed.log"
  if [ -e "$FAILLOG" ] || [ -L "$FAILLOG" ]; then
    rm -f "$FAILLOG" 2>/dev/null
  fi
  ( umask 077
    {
      printf '=== %s | cmd: %s | exit: %s | cwd: %s ===\n' "$ts" "$cmd" "$code" "$ROOT"
      printf '%s\n' "$out"
    } > "$FAILLOG"
  ) 2>/dev/null
  chmod 600 "$FAILLOG" 2>/dev/null

  break
done

# CAP-ALLOW decision (checked first): never touches ATTEMPTS_FILE/ESCALATION.
if [ "$CAP_HIT" -eq 1 ]; then
  [ -n "$SKIP_LINES" ] && printf '%s' "$SKIP_LINES"
  printf 'VERIFY QUICK-CAP: the %ss bounded quick-chain time budget (QUETREX_VERIFY_QUICK_CAP) was exhausted running `%s` in %s — allowed to finish; nothing green or red was recorded for it, and the FULL chain still gates shipping at the merge boundary (merge-gate.sh).\n' \
    "$BUDGET_TOTAL" "$CAP_CMD" "$ROOT"
  exit 0
fi

# --- decision --------------------------------------------------------------
if [ "$RED" -eq 0 ]; then
  # A skip's plain "VERIFY SKIPPED" line(s) are printed ONLY on this allow
  # path — never ahead of a block() call, whose stdout must stay pure JSON
  # (the contract's ONLY honored block form; extra leading text risks being
  # unparseable and read as fail-open). They are deliberately plain text,
  # never JSON, so they can never be misread as a decision object.
  [ -n "$SKIP_LINES" ] && printf '%s' "$SKIP_LINES"
  # A skip is NOT a green: it proves nothing about the skipped command, so a
  # run that skipped anything must not reset the self-heal counter or clear a
  # prior escalation. Only a run where every chain command genuinely executed
  # and exited 0 may do either (CONTAINMENT — see header comment / AC7).
  if [ "$SKIPPED" -eq 0 ]; then
    echo 0 > "$ATTEMPTS_FILE" 2>/dev/null   # reset self-heal counter on green
    rm -f "$ESCALATION" 2>/dev/null         # green clears any prior escalation
  fi
  exit 0                                    # allow finish (no block JSON)
fi

# RED path — bounded self-heal.
n=0
[ -f "$ATTEMPTS_FILE" ] && n=$(cat "$ATTEMPTS_FILE" 2>/dev/null)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
echo "$n" > "$ATTEMPTS_FILE" 2>/dev/null

# A time-budget kill is called out explicitly so the agent (and the human on
# escalation) knows this was a fail-closed timeout, not a normal assertion
# failure, and knows to split/speed up the chain rather than "fix a bug".
TIMEOUT_NOTE=""
if [ "$TIMED_OUT" -eq 1 ]; then
  TIMEOUT_NOTE=" This is a TIME-BUDGET kill: verification exceeded the ${BUDGET_TOTAL}s time budget (QUETREX_VERIFY_BUDGET) — treat as red; split or speed up the chain."
fi

# A RED chain can be preceded by earlier commands that were declaratively
# SKIPPED (requiredEnv unavailable). This whole task exists because the
# operator could not tell a real failure from a non-failure, so the block
# reason must say so here too — not just on the (separate, JSON-free) allow
# path. Folded into the reason as a single-line note (never a raw stdout line
# ahead of the block() JSON, which must stay pure — see the allow-path
# comment below) so it stays within the <=3-line quiet-output budget.
SKIP_NOTE=""
if [ -n "$SKIPPED_CMDS" ]; then
  SKIP_NOTE=" NOTE: also SKIPPED before this failure (requiredEnv unavailable, never proven): ${SKIPPED_CMDS}."
fi

# QUIET BLOCK REASONS (fix part a). One labelled summary line — what ran,
# which checkout/branch, whether it blocks — plus a line pointing at
# $FAILLOG, the preserved-failure slot (survives the next invocation, unlike
# the live $LOG). FAILED_TAIL is deliberately never interpolated here.
if [ "$n" -lt "$MAX_ATTEMPTS" ]; then
  block "$(printf 'VERIFY FAILED (attempt %d/%d): `%s` exited %d in %s (branch %s).%s%s%s BLOCKS finish — fix the cause; it re-runs on your next stop.\nFull output: %s' \
    "$n" "$MAX_ATTEMPTS" "$FAILED_CMD" "$FAILED_CODE" "$ROOT" "${CUR_BRANCH:-<detached>}" "$TIMEOUT_NOTE" "$QUICK_NOTE" "$SKIP_NOTE" "$FAILLOG")"
fi

# Cap reached -> escalate. Persist a marker the merge gate reads so red code
# physically cannot merge even once the agent is finally allowed to stop.
touch "$ESCALATION" 2>/dev/null
block "$(printf 'ESCALATE: `%s` is STILL red (exit %d) after %d self-heal attempts in %s (branch %s).%s%s%s BLOCKS finish — STOP self-healing.\nFull output: %s\nReport this one-line summary and the log path to the user; do NOT paste command output into your closing message. Wait for direction.' \
  "$FAILED_CMD" "$FAILED_CODE" "$MAX_ATTEMPTS" "$ROOT" "${CUR_BRANCH:-<detached>}" "$TIMEOUT_NOTE" "$QUICK_NOTE" "$SKIP_NOTE" "$FAILLOG")"
