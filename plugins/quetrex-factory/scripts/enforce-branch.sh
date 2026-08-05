#!/bin/bash
# enforce-branch.sh — blocks `git commit` / `git push` while ON main/master.
# PreToolUse (Bash matcher).
#
# HOOK CONTRACT (course L5): block by printing
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#     "permissionDecision":"deny","permissionDecisionReason":"..."}}
# on stdout and exiting 0 — evaluated beneath the permission engine, so it
# fires under dontAsk / bypassPermissions too. Exit 2 = blocking error whose
# stderr is handed back. Exit 1 does NOT block.
#
# FAIL-CLOSED INPUT HANDLING (finding #9): jq preferred, merge-gate.sh's
# jq-free `sed` extraction as the fallback, and exit 2 (never a silent exit 0)
# when the payload plainly carries a command that cannot be parsed. The deny
# path emits well-formed JSON with or without jq.
#
# TOKEN MATCHING, NOT SUBSTRING MATCHING (finding #15): the old test was
#   [[ "$COMMAND" == *"git commit"* ]]
# which denied `echo "docs say: git commit early" >> README` — a command that
# only MENTIONS committing. The command is now split into quote-aware pipeline
# segments and only a segment whose actual leading command is `git commit` /
# `git push` is inspected.
#
# FRESH-REPO EXEMPTION (finding #15): in a repo with no commits yet, HEAD is
# unborn (`git rev-parse HEAD` fails) and the default branch is already named
# main. There is no history to protect and no branch to have branched from, so
# the FIRST commit is allowed. Pushes are never exempted on this ground.
#
# Tag pushes (deploy/version rollback tags) stay exempt.

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
COMMAND=""
SESSION_CWD=""
if [ "$JQ_OK" -eq 1 ]; then
  TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
  COMMAND=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  SESSION_CWD=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
  [ -n "$TOOL_NAME" ] && [ "$TOOL_NAME" != "Bash" ] && exit 0
  [ -z "$COMMAND" ] && exit 0
else
  COMMAND=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')
  SESSION_CWD=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [ -z "$COMMAND" ]; then
    if printf '%s' "$input" | grep -q '"command"'; then
      echo "enforce-branch: could not parse this tool call (jq unavailable or malformed hook JSON), so the branch guard cannot tell whether this commits or pushes on main. Refusing to run it unchecked. Install jq, then retry." >&2
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

# --- heredoc bodies are DATA, never commands -------------------------------
# THE DEFECT THIS FIXES. Segmentation below splits on `&`, `;`, `|` and
# newlines, and it used to see the whole payload — including heredoc BODIES. So
# committing with the message supplied on stdin:
#
#     git -C <worktree> commit -F - <<'MSG'
#     fix: ...
#         git -C /wt push -u origin claude/x && gh pr create --base main
#     MSG
#
# had its MESSAGE parsed as commands. The quoted example line became a segment,
# its `-C /wt` did not exist, the resolver fell back to the SESSION cwd (main),
# and the commit was denied — on a feature branch, in a worktree, for text
# inside a commit message. It bites hardest when writing ABOUT git, i.e.
# exactly when documenting a git fix.
#
# A heredoc body is input to a program, not a command line. Strip it before
# anything else looks at the command.
#
# Residual, documented rather than hidden: an opener is detected on the raw
# line, so a literal `<<` inside a quoted string could be mistaken for one and
# swallow the lines that follow. Quote-stripping cannot be used to avoid that,
# because the delimiter itself is normally quoted (`<<'MSG'`). The trade is
# deliberate — the miss requires a quoted `<<` AND a real commit-on-main later
# in the same command, while the false positive above fires constantly.
strip_heredocs() {
  printf '%s\n' "$1" | awk '
    BEGIN { nd = 0 }
    {
      if (nd > 0) {
        line = $0
        sub(/^[ \t]+/, "", line)          # <<- allows a tab-indented terminator
        if (line == delim[nd]) { nd-- }
        next                              # body line: never a command
      }
      scan = $0
      gsub(/<<</, "\001", scan)           # a herestring consumes no lines
      while (match(scan, /<<-?[ \t]*("[^"]+"|\047[^\047]+\047|[A-Za-z_][A-Za-z0-9_]*)/)) {
        tok = substr(scan, RSTART, RLENGTH)
        scan = substr(scan, RSTART + RLENGTH)
        sub(/^<<-?[ \t]*/, "", tok)
        gsub(/["\047]/, "", tok)
        nd++
        delim[nd] = tok
      }
      print $0
    }
  '
}

COMMAND=$(strip_heredocs "$COMMAND")
[ -z "$COMMAND" ] && exit 0

# --- quote-aware segmentation (see deny-guard.sh) --------------------------
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

expand_tilde() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Does the whole command line create a tag? (`git tag v1 && git push origin v1`)
HAS_GIT_TAG=0
case " $(printf '%s' "$COMMAND" | tr -s '[:space:]' ' ') " in
  *" git tag "*) HAS_GIT_TAG=1 ;;
esac

LAST_CD=""

branch_of() {
  d="$1"
  if [ -n "$d" ] && [ -d "$d" ]; then
    git -C "$d" branch --show-current 2>/dev/null
  else
    git branch --show-current 2>/dev/null
  fi
}

has_head() {
  d="$1"
  if [ -n "$d" ] && [ -d "$d" ]; then
    git -C "$d" rev-parse HEAD >/dev/null 2>&1
  else
    git rev-parse HEAD >/dev/null 2>&1
  fi
}

# --- one git invocation -----------------------------------------------------
check_git() {
  shift                       # drop 'git'
  gitdir=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C)
        if [ "$#" -ge 2 ]; then gitdir="$2"; shift 2; else return 0; fi ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path)
        if [ "$#" -ge 2 ]; then shift 2; else return 0; fi ;;
      --git-dir=*) gitdir="${1#--git-dir=}"; shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  sub="$1"; shift
  case "$sub" in
    commit|push) : ;;
    *) return 0 ;;
  esac

  # Tag pushes are not branch work — exempt (deploy/version rollback tags).
  if [ "$sub" = "push" ]; then
    [ "$HAS_GIT_TAG" -eq 1 ] && return 0
    for a in "$@"; do
      case "$a" in
        --tags|--follow-tags|refs/tags/*|*:refs/tags/*|deploy/*|v[0-9]*) return 0 ;;
      esac
    done
  fi

  # Working directory: this invocation's -C > the last `cd` in the pipeline >
  # the session cwd. A relative path resolves against the SESSION cwd, not the
  # hook process's own cwd, so `git -C sub commit` is still checked.
  resolve_dir() {
    d=$(expand_tilde "$1")
    case "$d" in
      /*) ;;
      *) [ -n "$SESSION_CWD" ] && d="$SESSION_CWD/$d" ;;
    esac
    printf '%s' "$d"
  }

  dir=""; explicit=0
  if [ -n "$gitdir" ]; then dir=$(resolve_dir "$gitdir"); explicit=1
  elif [ -n "$LAST_CD" ]; then dir=$(resolve_dir "$LAST_CD"); explicit=1
  elif [ -n "$SESSION_CWD" ]; then dir="$SESSION_CWD"
  fi

  # An invocation that NAMES its directory is about that directory and no other.
  # Falling back to the session cwd here was the second half of the defect
  # above: a `-C` path that does not exist got judged against the session repo
  # (main) and denied. `git` itself cannot commit or push into a directory that
  # is not there, so there is nothing to protect — and judging one repo by
  # another repo's branch is exactly the cross-repo mistake fixed in
  # merge-gate.sh.
  if [ "$explicit" -eq 1 ] && [ ! -d "$dir" ]; then
    return 0
  fi

  br=$(branch_of "$dir")
  [ "$br" = "main" ] || [ "$br" = "master" ] || return 0

  # Fresh repo with no commits: the first commit has no history to protect and
  # no branch it could have been cut from. Allow it (finding #15).
  if [ "$sub" = "commit" ] && ! has_head "$dir"; then
    return 0
  fi

  deny "Never commit or push on $br — use a feature branch or worktree (see the worktree-workflow skill)."
}

check_tokens() {
  depth="$1"; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      sudo|doas|nohup|command|builtin|exec|time|nice|ionice|env) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  head="${1##*/}"
  case "$head" in
    cd) [ "$#" -ge 2 ] && LAST_CD="$2" ;;
    git) check_git "$@" ;;
    bash|sh|zsh|dash|ksh|eval|xargs)
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in -*) shift ;; *) break ;; esac
      done
      [ "$#" -gt 0 ] && [ "$depth" -lt 2 ] && check_tokens $((depth + 1)) "$@"
      ;;
  esac
  return 0
}

set -f
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  # shellcheck disable=SC2086
  check_tokens 0 $seg
done <<< "$(split_segments "$COMMAND")"
set +f

exit 0
