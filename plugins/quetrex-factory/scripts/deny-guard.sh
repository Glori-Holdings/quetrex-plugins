#!/bin/bash
# deny-guard.sh — blocks ONLY catastrophic, irreversible commands.
# PreToolUse (Bash). Emits permissionDecision:"deny" (the correct PreToolUse
# schema) so it fires even under bypassPermissions / dontAsk. Targeted deletes
# and all normal work pass through with NO prompt — this replaces the blunt
# `ask: rm -rf *` rule that stopped every recursive delete.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# collapse whitespace and pad with spaces so token boundaries are simple
c=" $(printf '%s' "$cmd" | tr -s '[:space:]' ' ') "

# Inspect only recursive rm (a flag group containing r or R)
if printf '%s' "$c" | grep -qE '[^[:alnum:]_]rm +-[a-zA-Z]*[rR][a-zA-Z]* '; then
  # root / home-shorthand / current / parent
  if printf '%s' "$c" | grep -qE ' (/|/\*|~|~/|\.|\.\.|\$HOME)( |;|&|\||\)|$)'; then
    deny "Refusing recursive delete of a root/home/current/parent path — name a specific subpath instead."
  fi
  # true system roots (NOT /Users — home lives there and targeted deletes are fine)
  if printf '%s' "$c" | grep -qE ' (/System|/Applications|/Library|/etc|/usr|/bin|/sbin|/opt)( |/|;|&|\||$)'; then
    deny "Refusing recursive delete of a system directory."
  fi
  # the home directory itself (subpaths under it are allowed)
  case "$c" in *" $HOME "*|*" $HOME/ "*) deny "Refusing recursive delete of your home directory." ;; esac
fi

# other irreversible operations
case "$c" in
  *"reset --hard"*) deny "git reset --hard is blocked — stash or commit first." ;;
  *"clean -f"*|*"clean -df"*|*"clean -fd"*|*"clean -xf"*|*"clean -fx"*) deny "git clean -f is blocked (irreversible)." ;;
  *"push --force"*|*"push -f"*|*"--force-with-lease"*) deny "Force-push is blocked — use a PR + branch protection." ;;
esac

exit 0
