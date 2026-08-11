#!/bin/bash
# deny-guard.sh — blocks ONLY catastrophic, irreversible commands.
# PreToolUse (Bash matcher).
#
# HOOK CONTRACT (course L5): a PreToolUse hook blocks by printing
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#     "permissionDecision":"deny","permissionDecisionReason":"..."}}
# on stdout and exiting 0. A deny is evaluated BENEATH the permission engine,
# so it fires even under defaultMode "dontAsk", bypassPermissions and
# --dangerously-skip-permissions. Exit 2 = blocking error with stderr handed
# back to the agent. Exit 1 does NOT block. Anything but 0 or 2 is non-blocking.
#
# FAIL-CLOSED INPUT HANDLING (finding #9). The old form was
#   cmd=$(jq -r ... 2>/dev/null); [ -z "$cmd" ] && exit 0
# so a missing or erroring jq silently disabled the gate with no trace. Now:
#   - jq is preferred, with the jq-free `sed` extraction merge-gate.sh uses
#     as the fallback, and
#   - input that carries a command but cannot be parsed exits 2 with a message
#     on stderr — it is never treated as "nothing to inspect".
#   - deny() also emits well-formed JSON without jq, so the DENY path itself
#     cannot fail open on a missing dependency.
#
# TOKEN MATCHING, NOT SUBSTRING MATCHING (finding #15). The old matcher looked
# for `reset --hard` / `push --force` / `git commit` anywhere in an arbitrary
# shell string, which denied real, safe commands:
#   grep -rn "git reset --hard" docs/      (the phrase is the SEARCH PATTERN)
#   git push --force-with-lease origin/x   (the SAFE form, the standard remedy)
# This script now splits the command into pipeline segments (quote-aware, so a
# separator inside a quoted literal does not split, and quoted text is never
# read as a command) and inspects the FIRST TOKEN of each segment — the same
# shape the `rm` rule already used. Text that merely MENTIONS a dangerous
# command is not a dangerous command.
#
# Escape hatch that is NOT weakened: if a segment pipes into a bare shell
# (`... | bash`), the segment's literal text really is about to be executed, so
# the legacy whole-string substring scan is applied as a backstop.

set -o pipefail

# --- read hook input -------------------------------------------------------
input=""
if [ ! -t 0 ]; then input=$(cat); fi
[ -z "$input" ] && exit 0

JQ_OK=0
if command -v jq >/dev/null 2>&1 && printf '%s' "$input" | jq . >/dev/null 2>&1; then
  JQ_OK=1
fi

TOOL_NAME=""
cmd=""
if [ "$JQ_OK" -eq 1 ]; then
  TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  # jq parsed the payload: an absent/empty command genuinely means there is no
  # shell command to inspect.
  [ -n "$TOOL_NAME" ] && [ "$TOOL_NAME" != "Bash" ] && exit 0
  [ -z "$cmd" ] && exit 0
else
  # jq missing or the payload is not valid JSON. Best-effort jq-free extraction
  # (same shape as merge-gate.sh:70-75), then FAIL CLOSED if that finds nothing
  # while the payload plainly carries a command.
  cmd=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')
  if [ -z "$cmd" ]; then
    if printf '%s' "$input" | grep -q '"command"'; then
      echo "deny-guard: could not parse this tool call (jq unavailable or malformed hook JSON), so the catastrophic-command guard cannot evaluate it. Refusing to run it unchecked. Install jq, then retry." >&2
      exit 2
    fi
    exit 0
  fi
fi

# --- deny (fail-closed even without jq) ------------------------------------
deny() {
  reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
  fi
  exit 0
}

# --- quote-aware segmentation ----------------------------------------------
# Emits one pipeline segment per line. Quote characters are dropped but their
# CONTENTS are preserved verbatim, and separators inside quotes do NOT split —
# so `grep -rn "git reset --hard" docs/` is one segment whose first token is
# `grep`, while `rm -rf "/"` still presents `/` as an argument.
split_segments() {
  s="$1"; out=""; inq=""; i=0; n=${#s}
  while [ "$i" -lt "$n" ]; do
    ch="${s:$i:1}"
    if [ -n "$inq" ]; then
      if [ "$ch" = "$inq" ]; then inq=""; else out="$out$ch"; fi
    else
      case "$ch" in
        "'"|'"') inq="$ch" ;;
        ';'|'&'|'|'|'('|')'|'{'|'}'|'`') out="$out
" ;;
        *) out="$out$ch" ;;
      esac
    fi
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

PIPE_TO_SHELL=0

# --- rm ---------------------------------------------------------------------
check_rm() {
  shift                      # drop 'rm'
  recursive=0
  paths=""
  for a in "$@"; do
    case "$a" in
      --recursive|--recursive=*|-R|-r) recursive=1 ;;
      --*) : ;;
      -*) case "$a" in *[rR]*) recursive=1 ;; esac ;;
      *) paths="$paths
$a" ;;
    esac
  done
  [ "$recursive" -eq 1 ] || return 0
  printf '%s\n' "$paths" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      '/'|'/*'|'~'|'~/'|'~/*'|'.'|'./'|'./*'|'..'|'../'|'../*'|'$HOME'|'$HOME/'|'$HOME/*')
        echo "ROOTHOME" ;;
      /System|/System/*|/Applications|/Applications/*|/Library|/Library/*|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/opt|/opt/*)
        echo "SYSTEM" ;;
      *)
        if [ -n "$HOME" ]; then
          case "$p" in
            "$HOME"|"$HOME/"|"$HOME/*") echo "ROOTHOME" ;;
          esac
        fi
        ;;
    esac
  done > "$VERDICT_TMP"
  if grep -q ROOTHOME "$VERDICT_TMP" 2>/dev/null; then
    deny "Refusing recursive delete of a root/home/current/parent path — name a specific subpath instead."
  fi
  if grep -q SYSTEM "$VERDICT_TMP" 2>/dev/null; then
    deny "Refusing recursive delete of a system directory."
  fi
  return 0
}

# --- git --------------------------------------------------------------------
check_git() {
  shift                      # drop 'git'
  # skip git's own global options so `git -C /worktree push --force` is seen
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path)
        if [ "$#" -ge 2 ]; then shift 2; else return 0; fi ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  sub="$1"; shift
  case "$sub" in
    reset)
      for a in "$@"; do
        [ "$a" = "--hard" ] && deny "git reset --hard is blocked — stash or commit first."
      done
      ;;
    clean)
      for a in "$@"; do
        case "$a" in
          --force|--force=*) deny "git clean -f is blocked (irreversible)." ;;
          --*) : ;;
          -*) case "$a" in *f*) deny "git clean -f is blocked (irreversible)." ;; esac ;;
        esac
      done
      ;;
    push)
      for a in "$@"; do
        # --force-with-lease / --force-if-includes are the SAFE forms (they
        # refuse to clobber work the local ref has not seen) and are the
        # standard post-rebase remedy. They are explicitly NOT blocked.
        case "$a" in
          --force-with-lease|--force-with-lease=*|--force-if-includes) : ;;
          --force|-f) deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection." ;;
        esac
      done
      ;;
  esac
  return 0
}

# --- one segment ------------------------------------------------------------
check_tokens() {
  depth="$1"; shift
  # strip leading env assignments and benign wrappers
  while [ "$#" -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      sudo|doas|nohup|command|builtin|exec|time|nice|ionice|env) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  head="${1##*/}"            # /bin/rm -> rm
  case "$head" in
    rm) check_rm "$@" ;;
    git) check_git "$@" ;;
    bash|sh|zsh|dash|ksh|eval|xargs)
      # The literal text handed to a shell IS a command. Re-inspect it once.
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in -*) shift ;; *) break ;; esac
      done
      if [ "$#" -eq 0 ]; then
        # `... | bash` — the piped text is executed but is not in this segment.
        PIPE_TO_SHELL=1
      elif [ "$depth" -lt 2 ]; then
        check_tokens $((depth + 1)) "$@"
      fi
      ;;
  esac
  return 0
}

VERDICT_TMP=$(mktemp "${TMPDIR:-/tmp}/quetrex-deny-guard.XXXXXX" 2>/dev/null) || VERDICT_TMP="${TMPDIR:-/tmp}/quetrex-deny-guard.$$"
trap 'rm -f "$VERDICT_TMP" 2>/dev/null' EXIT

set -f                       # no globbing while word-splitting segments
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  # shellcheck disable=SC2086
  check_tokens 0 $seg
done <<< "$(split_segments "$cmd")"
set +f

# --- backstop: text piped into a bare shell really will be executed ---------
if [ "$PIPE_TO_SHELL" -eq 1 ]; then
  c=" $(printf '%s' "$cmd" | tr -s '[:space:]' ' ') "
  case "$c" in
    *"reset --hard"*) deny "git reset --hard is blocked — stash or commit first." ;;
    *"clean -f"*|*"clean -df"*|*"clean -fd"*|*"clean -xf"*|*"clean -fx"*) deny "git clean -f is blocked (irreversible)." ;;
  esac
  case "$c" in
    *"--force-with-lease"*|*"--force-if-includes"*) : ;;
    *"push --force"*|*"push -f"*) deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection." ;;
  esac
fi

exit 0
