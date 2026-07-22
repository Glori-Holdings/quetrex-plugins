#!/bin/bash
# HARD-RULE #6: Block git commit/push on main/master
# Runs on PreToolUse hook for Bash
# Work should happen in worktrees, not on main

# Read hook input from stdin
input=$(cat)

# Get the command being executed
COMMAND=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only check git commit and git push commands
if [[ "$COMMAND" != *"git commit"* ]] && [[ "$COMMAND" != *"git push"* ]]; then
  exit 0
fi

# Allow pushing tags from main (deploy rollback tags, version tags)
# The command may use shell variables ($TAG) so we check for tag patterns in the full command:
# 1. Command contains "git tag" (creating + pushing a tag in same pipeline)
# 2. Command pushes refs/tags/ explicitly
# 3. Command pushes deploy/* or v[0-9] tag patterns literally
if [[ "$COMMAND" == *"git push"* ]]; then
  if [[ "$COMMAND" == *"git tag"* ]] || \
     [[ "$COMMAND" == *"refs/tags/"* ]] || \
     [[ "$COMMAND" =~ git[[:space:]]+push[[:space:]]+origin[[:space:]]+deploy/ ]] || \
     [[ "$COMMAND" =~ git[[:space:]]+push[[:space:]]+origin[[:space:]]+v[0-9] ]]; then
    exit 0
  fi
fi

# Determine the working directory: prefer the session's cwd from hook input,
# then check for cd/git -C patterns in the command, then fall back to $PWD.
SESSION_CWD=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)

# Extract target directory from command patterns:
#   cd /path && git commit ...
#   git -C /path commit ...
TARGET_DIR=""
if [[ "$COMMAND" =~ cd[[:space:]]+([^&\;]+)[[:space:]]*\&\& ]]; then
  TARGET_DIR="${BASH_REMATCH[1]}"
  # Trim whitespace and quotes
  TARGET_DIR=$(echo "$TARGET_DIR" | sed 's/^[ "'\'']*//;s/[ "'\'']*$//')
elif [[ "$COMMAND" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
  TARGET_DIR="${BASH_REMATCH[1]}"
fi

# Check current branch: explicit target dir > session cwd > hook's own CWD
if [ -n "$TARGET_DIR" ] && [ -d "$TARGET_DIR" ]; then
  CURRENT_BRANCH=$(git -C "$TARGET_DIR" branch --show-current 2>/dev/null)
elif [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  CURRENT_BRANCH=$(git -C "$SESSION_CWD" branch --show-current 2>/dev/null)
else
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
fi

if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
  jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"Never commit or push on main/master — use a feature branch or worktree."}}'
  exit 0
fi

# Not on main/master -- allow
exit 0
