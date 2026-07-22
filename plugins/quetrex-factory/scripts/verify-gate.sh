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
#
# Single source of truth for the chain (in priority order):
#   1. $ROOT/.quetrex/verify.json  -> .verify[]   (canonical; written by init)
#      On SubagentStop, if .verifyQuick[] is present and non-empty it is used
#      instead (a QUICK per-subagent chain) — a strict SUBSET that still blocks
#      red; it never weakens the gate below the full chain when unconfigured.
#   2. $ROOT/.claude/CLAUDE.md      "## Verification" fenced command block
#   3. autodetect (package.json scripts / Makefile / pyproject / go.mod / Cargo)
# If none resolves, there is nothing to gate -> allow finish (exit 0).
#
# Worktree-safe root: $CLAUDE_PROJECT_DIR first, then `git rev-parse` from the
# session cwd. All artifacts live under $ROOT/.quetrex/.
#
# The ONLY conditions that allow finish without a block:
#   - not a git repo / no verify chain resolvable anywhere (nothing to gate), or
#   - the chain resolved AND every command exited 0 (PROVEN green by exit codes).
#
# Contract: Stop/SubagentStop hooks BLOCK via {"decision":"block","reason":...}
# printed on EXIT 0. Printing block JSON then exiting non-zero DISCARDS the JSON.
# This script therefore always `exit 0` after emitting, and emits nothing to
# stdout when it allows the finish.

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

# On SubagentStop we may run a QUICK subset chain if the project defines one.
QUICK=0
[ "$EVENT" = "SubagentStop" ] && QUICK=1

# --- helpers ---------------------------------------------------------------

# Emit a Stop/SubagentStop block and exit 0 (the only honored form).
block() {
  jq -cn --arg r "$1" '{decision:"block",reason:$r}'
  exit 0
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
  local sel='.verify'
  if [ "$QUICK" -eq 1 ] \
     && jq -e '.verifyQuick | type == "array" and length > 0' "$f" >/dev/null 2>&1; then
    sel='.verifyQuick'
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
  local extracted
  extracted=$(awk '
    /^#{1,6}[[:space:]]/ {
      insec = (tolower($0) ~ /verification/) ? 1 : 0
      next
    }
    /^[[:space:]]*```/ { infence = !infence; next }
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

# --- run the chain ---------------------------------------------------------
# Always run — no fast-skip, no stale-green. Every non-zero exit is RED. There
# is no env-error laundering: a command that exits non-zero fails the gate even
# if its output mentions ENOENT / "No such file or directory" / "command not
# found". Missing tooling/deps are handed to the agent to fix (bounded), not
# excused into a green finish.
RED=0
FAILED_CMD=""
FAILED_TAIL=""
FAILED_CODE=0

for cmd in "${CHAIN[@]}"; do
  out=$( ( cd "$ROOT" && eval "$cmd" ) 2>&1 ); code=$?
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  t20=$(tail20 "$out")

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
  break
done

# --- decision --------------------------------------------------------------
if [ "$RED" -eq 0 ]; then
  echo 0 > "$ATTEMPTS_FILE" 2>/dev/null   # reset self-heal counter on green
  rm -f "$ESCALATION" 2>/dev/null         # green clears any prior escalation
  exit 0                                   # PROVEN green by exit codes -> finish
fi

# RED path — bounded self-heal.
n=0
[ -f "$ATTEMPTS_FILE" ] && n=$(cat "$ATTEMPTS_FILE" 2>/dev/null)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
echo "$n" > "$ATTEMPTS_FILE" 2>/dev/null

if [ "$n" -lt "$MAX_ATTEMPTS" ]; then
  block "$(printf 'VERIFY FAILED (attempt %d/%d): `%s` exited %d.\nYou cannot finish while the verification chain is red. Fix the cause and it will re-run on your next stop.\n\n--- last 20 lines ---\n%s' \
    "$n" "$MAX_ATTEMPTS" "$FAILED_CMD" "$FAILED_CODE" "$FAILED_TAIL")"
fi

# Cap reached -> escalate. Persist a marker the merge gate reads so red code
# physically cannot merge even once the agent is finally allowed to stop.
touch "$ESCALATION" 2>/dev/null
block "$(printf 'ESCALATE: `%s` is STILL red (exit %d) after %d self-heal attempts.\nSTOP self-healing now. Do NOT report this task as done. Surface this failure to the user verbatim, including the output below, and wait for direction.\n\n--- last 20 lines ---\n%s' \
  "$FAILED_CMD" "$FAILED_CODE" "$MAX_ATTEMPTS" "$FAILED_TAIL")"
