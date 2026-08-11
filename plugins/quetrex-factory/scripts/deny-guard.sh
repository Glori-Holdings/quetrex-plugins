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
#
# ABBREVIATED LONG OPTIONS ARE THE OPTION (finding f1/f3). Matching the
# spelled-out `--delete` was a three-character bypass of the whole ref-deletion
# rule: git's parse-options resolves any UNAMBIGUOUS prefix. Measured against
# git 2.54.0 and a real bare remote:
#   git push origin --delete|--delet|--dele|--del|--de <ref>  -> ref DELETED, exit 0
#   git push origin --d <ref>       -> refused, "ambiguous option: d"
#   git push --mirror|--mirro|--m origin                      -> refs DELETED
#   git push --prune|--pru origin refs/heads/*                -> refs DELETED
#   git reset --hard|--har|--ha|--h -> worktree reset
#   git clean --force|--forc|--for|--fo|--f -> files removed
# So every long-option match in this file is a PREFIX match (opt_is), never an
# equality test. Over-matching a prefix git itself calls ambiguous costs
# nothing: git refuses to run those, so nothing legitimate is lost.
#
# FORCE IS A REFSPEC SYNTAX, NOT ONLY A FLAG. `git push origin +main:main`
# force-updates main and names no flag at all, so a guard that decides "is this
# a force push?" from FLAGS alone waves it through. MEASURED against real git
# and a real bare remote (remote main = A->B, local `rewrite` = A->C):
#   git push origin  rewrite:main -> ! [rejected] (non-fast-forward), exit 1
#   git push origin +rewrite:main -> + 43ca87a...9dac8d5 (forced update), exit 0
# and B was afterwards NOT an ancestor of the remote main. `+refs/heads/*:
# refs/heads/*` does that to every branch at once. Both the parsed push arm and
# the piped-shell backstop therefore judge a `+` refspec on its DESTINATION ref
# (refspec_dst) through the same disposable_ref() predicate the delete arm uses.
# --force-with-lease has no refspec spelling, so `+` is always the unsafe form.

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
#
# An UNQUOTED `#` at the start of a word begins a shell comment, and everything
# after it is not a command. Dropping it here is not cosmetic: with the comment
# left in, `echo '...' | bash # note` handed `bash` the arguments `#` and `note`,
# so check_tokens took the branch for "a shell invoked with a script" instead of
# "text piped into a bare shell" and NEVER SET PIPE_TO_SHELL — one trailing
# comment switched the whole piped-shell backstop off (finding f2).
split_segments() {
  s="$1"; out=""; inq=""; i=0; n=${#s}; prev=" "
  while [ "$i" -lt "$n" ]; do
    ch="${s:$i:1}"
    if [ -n "$inq" ]; then
      if [ "$ch" = "$inq" ]; then inq=""; else out="$out$ch"; fi
    else
      case "$ch" in
        '#') case "$prev" in
               ' '|'	') break ;;          # word-initial: the rest is a comment
               *) out="$out$ch" ;;          # mid-word (`issue#42`): a literal
             esac ;;
        "'"|'"') inq="$ch" ;;
        ';'|'&'|'|'|'('|')'|'{'|'}'|'`') out="$out
" ;;
        *) out="$out$ch" ;;
      esac
    fi
    prev="$ch"
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

PIPE_TO_SHELL=0

# --- long-option PREFIX matching -------------------------------------------
# opt_is <arg> <full-long-option> — true when <arg> is `--` plus a non-empty
# PREFIX of <full-long-option>, i.e. exactly the set of spellings git's
# parse-options resolves to that option. `--de`, `--del`, `--dele`, `--delet`
# and `--delete` all satisfy opt_is "$a" --delete. Any `=value` suffix is cut
# first, so `--force=x` is still --force. The candidate is used QUOTED as a
# case pattern, so a `*` or `?` inside attacker text is matched literally and
# cannot widen the comparison.
opt_is() {
  _oi_a="${1%%=*}"
  case "$_oi_a" in --?*) : ;; *) return 1 ;; esac
  case "$2" in "$_oi_a"*) return 0 ;; esac
  return 1
}

# --- rm ---------------------------------------------------------------------
check_rm() {
  shift                      # drop 'rm'
  recursive=0
  paths=""
  for a in "$@"; do
    case "$a" in
      -R|-r) recursive=1 ;;
      # GNU rm goes through getopt_long, which abbreviates too: `rm --r -f /`
      # is a recursive delete of /.
      --*) opt_is "$a" --recursive && recursive=1 ;;
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
# A ref this pipeline CREATES AND REPLACES by construction, so removing it is
# routine rather than catastrophic:
#   quetrex-spec/*  one dispatch's plan JSON, republished on every dispatch
#   *-gates         one run's gate evidence, republished on every run
# Everything else — main, a unit branch, anything the guard cannot resolve —
# is protected. NOTE the deliberate asymmetry with $VARIABLES: a PreToolUse
# hook is handed the command text BEFORE the shell expands it, so `--delete
# "$SPEC_BRANCH"` is indistinguishable from `--delete "$BASE_BRANCH"` and is
# therefore NOT disposable. Shipped engine commands spell their namespace out
# at the call site (`quetrex-spec/$TASK_ID`, `$BRANCH_PREFIX$TASK-gates`)
# precisely so this rule can see them; test/deny-guard-push-delete.test.sh
# feeds those real lines to this real hook to keep that true.
disposable_ref() {
  r="${1#+}"                  # a leading + (force refspec) is not part of the name
  r="${r#:}"                  # the empty-source delete form, `:<ref>`
  r="${r#refs/heads/}"
  case "$r" in
    quetrex-spec/*|*-gates) return 0 ;;
  esac
  return 1
}

# The ref a refspec UPDATES is its DESTINATION — everything after the colon.
#   +src:dst              -> dst        (`+main:main`, `+HEAD:main`)
#   +ref                  -> ref        (`+main`, src and dst are the same name)
#   +refs/heads/*:refs/heads/*  -> refs/heads/*   (a wildcard is not a name the
#                                 carve-out can clear, so it fails CLOSED)
# A ref name cannot contain a colon, so the first colon is the only colon.
refspec_dst() {
  d="${1#+}"
  case "$d" in
    *:*) d="${d#*:}" ;;
  esac
  printf '%s' "$d"
}

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
        # `--h`, `--ha`, `--har` are all `--hard` to git (measured, 2.54.0).
        opt_is "$a" --hard && deny "git reset --hard is blocked — stash or commit first."
      done
      ;;
    clean)
      for a in "$@"; do
        case "$a" in
          # `--f` is already `--force` to git clean (measured, 2.54.0).
          --*) opt_is "$a" --force && deny "git clean -f is blocked (irreversible)." ;;
          -*) case "$a" in *f*) deny "git clean -f is blocked (irreversible)." ;; esac ;;
        esac
      done
      ;;
    push)
      # DELETION IS MORE DESTRUCTIVE THAN FORCE-PUSH, not less. `push --force`
      # MOVES a ref (the old tip survives in reflogs and in every clone that
      # has it); `push --delete` / `push :<ref>` REMOVES it. Denying the first
      # while waving the second through was a hole, and one the engine's own
      # ls-remote -> delete -> push publication idiom teaches by example.
      delete=0
      skip_next=0
      pos_first=""
      pos_seen=0
      pos_rest=""
      for a in "$@"; do
        if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
        case "$a" in
          # --force-with-lease / --force-if-includes are the SAFE forms (they
          # refuse to clobber work the local ref has not seen) and are the
          # standard post-rebase remedy. They are explicitly NOT blocked. Their
          # own abbreviations fall through the --* arm below and match nothing
          # destructive, so they stay allowed as well.
          --force-with-lease|--force-with-lease=*|--force-if-includes) : ;;
          --*)
            # PREFIX, never equality — see the header. `--del`/`--de` really
            # delete; `--m` really mirrors; `--pru` really prunes.
            if opt_is "$a" --delete; then
              delete=1
            elif opt_is "$a" --mirror; then
              deny "\`git push --mirror\` is blocked. It force-updates the remote to match this repo and DELETES every remote ref that is absent locally — the broadest ref deletion git offers, and one that names no ref for the disposable-namespace carve-out (quetrex-spec/*, *-gates) to clear. Push the specific refs you mean instead."
            elif opt_is "$a" --prune; then
              deny "\`git push --prune\` is blocked. It DELETES every remote ref the pushed refspec does not match, naming no ref for the disposable-namespace carve-out (quetrex-spec/*, *-gates) to clear. Push the specific refs you mean, and retire anything else through a PR + branch protection."
            elif opt_is "$a" --force; then
              deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection."
            # options that take a SEPARATE value, so the value is never mistaken
            # for a remote or a refspec. Only the separated form consumes the
            # next argument: `--push-option=x` carries its own value.
            elif case "$a" in *=*) false ;; *) opt_is "$a" --push-option || opt_is "$a" --receive-pack || opt_is "$a" --exec || opt_is "$a" --repo ;; esac; then
              skip_next=1
            fi ;;
          -o) skip_next=1 ;;
          -*) case "$a" in
                *f*) deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection." ;;
              esac
              case "$a" in
                *d*) delete=1 ;;
              esac ;;
          # a redirection (`2>/dev/null`, `>out`, `2>&1`) is not a refspec —
          # git refuses `<` and `>` in a ref name, so this can never hide one
          *'>'*|*'<'*) : ;;
          *) if [ "$pos_seen" -eq 0 ]; then
               pos_seen=1; pos_first="$a"
             else
               pos_rest="$pos_rest $a"
             fi ;;
        esac
      done
      # The empty-source refspec `:<ref>` is a delete that names no flag at all
      # — `git push origin :main` — so it is checked on its own, always.
      for p in $pos_first $pos_rest; do
        case "$p" in
          :*|+:*)
            disposable_ref "$p" || deny "Deleting the remote ref '$p' is blocked. \`git push <remote> :<ref>\` is a ref DELETION — strictly less recoverable than the force-push this guard already denies. Only the pipeline's disposable namespaces may be deleted: quetrex-spec/* and *-gates." ;;
        esac
      done
      # FORCE BY REFSPEC. `+` is git's OTHER force syntax and it names no flag
      # at all, so every flag test above is blind to it. MEASURED against real
      # git and a real bare remote, remote main = A->B, local `rewrite` = A->C:
      #   git push origin  rewrite:main  -> ! [rejected] rewrite -> main
      #                                     (non-fast-forward), exit 1
      #   git push origin +rewrite:main  ->  + 43ca87a...9dac8d5 rewrite -> main
      #                                     (forced update), exit 0
      # and B was no longer an ancestor of the remote main — history destroyed
      # by a command carrying no --force anywhere. `+refs/heads/*:refs/heads/*`
      # does it to every branch at once.
      #
      # There is no safe-form carve-out to preserve here: --force-with-lease has
      # no refspec equivalent, so `+` is ALWAYS the unconditional force. The
      # only carve-out is the same one the delete arm gets, judged the same way
      # — on the ref itself, via disposable_ref() — because quetrex-spec/* and
      # *-gates are republished by construction. A dst the guard cannot resolve
      # (a wildcard, an unexpanded $VAR) is NOT disposable and fails closed.
      for p in $pos_first $pos_rest; do
        case "$p" in
          +:*) : ;;             # force-delete: already judged by the loop above
          +*)
            fdst=$(refspec_dst "$p")
            disposable_ref "$fdst" || deny "Force-updating the remote ref '$fdst' is blocked. A leading \`+\` on a refspec ('$p') IS a force-push — git reports it as '(forced update)' and it overwrites the remote exactly as \`--force\` does, with no --force flag present. Unconditional force-push is blocked — use --force-with-lease (which has no refspec form, so drop the \`+\` and pass the flag), or a PR + branch protection. Only the pipeline's disposable namespaces may be force-updated this way: quetrex-spec/* and *-gates." ;;
        esac
      done
      if [ "$delete" -eq 1 ]; then
        # `git push [--delete] <remote> <ref>...`: the first positional is the
        # remote. A delete that named only ONE positional is malformed git, so
        # inspect it rather than assuming it was a harmless remote name.
        targets="$pos_rest"
        [ -n "$targets" ] || targets="$pos_first"
        for p in $targets; do
          disposable_ref "$p" || deny "Deleting the remote ref '$p' is blocked — it removes the branch outright, which is strictly less recoverable than the force-push this guard already denies. Only the pipeline's disposable namespaces may be deleted this way: quetrex-spec/* and *-gates. Name the branch literally at the call site (this hook sees the command before the shell expands \$VARS); to retire anything else, go through a PR and branch protection."
        done
      fi
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
  # EVERY RULE BELOW IS DECIDED ON PARSED TOKENS, NOT ON THE COMMAND TEXT.
  #
  # The force, reset and clean arms used to be `case "$c" in *"push --force"*`
  # style substring tests over the whole flattened string, which is this repo's
  # known failure class and the same one the delete arm was already converted
  # away from. Measured against this hook before the change:
  #   ALLOW  echo 'git push origin --force main' | bash
  #             — the substring test needed `push` and `--force` ADJACENT, and
  #               the remote sits between them in perfectly ordinary git
  #   ALLOW  echo 'git push --force origin main # --force-with-lease' | bash
  #             — the safe-form carve-out was judged on the WHOLE TEXT, so
  #               naming the safe form in a COMMENT disabled the force backstop
  #   ALLOW  echo 'git push --fo origin main' | bash
  #   ALLOW  echo 'git reset --har' | bash
  #   ALLOW  echo 'git clean --force' | bash
  #             — no abbreviation handling at all, while the PARSED path gets
  #               all three right via opt_is (see the header: an unambiguous
  #               prefix IS the option to git)
  #   ALLOW  echo 'git push origin +main:main' | bash
  #             — the refspec force form, unguarded here as well
  # So the token loop below carries the force/reset/clean decisions too: the
  # safe-form exemption is applied PER TOKEN (a comment can never reach it,
  # because `#` ends the command), long options go through opt_is exactly as
  # the parsed path does, and a `+` refspec is judged on its destination ref.
  #
  # Ref DELETION, same backstop.
  #
  # THE CARVE-OUT IS EVALUATED AGAINST THE REF, NEVER AGAINST THE COMMAND TEXT
  # (finding f2). This arm used to read `case "$c" in *"quetrex-spec/"*|*"-gates"*) : ;;`
  # BEFORE looking at the push at all, so any occurrence of either namespace
  # ANYWHERE in the flattened text disabled the whole backstop:
  #   echo 'git push origin --delete trunk # see quetrex-spec/notes' | bash
  #   echo 'git push origin --delete trunk' | bash # my-gates
  # both ran. That is this repo's known failure class — matching command TEXT
  # rather than the actual invocation. So tokenise the text, collect the refs
  # the push would actually remove, and hand each one to the same
  # disposable_ref() predicate the parsed path uses. A delete that names no ref
  # the guard can resolve fails CLOSED.
  bs_push=0; bs_del=0; bs_seen=0; bs_first=""; bs_rest=""
  bs_reset=0; bs_clean=0
  BS_TARGETS=""; BS_COLON=""; BS_FORCE=""
  bs_flush() {
    if [ "$bs_del" -eq 1 ]; then
      if [ -n "$bs_rest" ]; then
        BS_TARGETS="$BS_TARGETS$bs_rest"
      elif [ -n "$bs_first" ]; then
        # A delete naming ONE positional is malformed git; inspect it rather
        # than assume it was a harmless remote name (same rule as check_git).
        BS_TARGETS="$BS_TARGETS $bs_first"
      else
        BS_TARGETS="$BS_TARGETS ?"   # names nothing resolvable: not clearable
      fi
    fi
    bs_push=0; bs_del=0; bs_seen=0; bs_first=""; bs_rest=""
    bs_reset=0; bs_clean=0
  }
  set -f                     # no globbing while word-splitting the text
  for tok in $c; do
    tok="${tok//\"/}"; tok="${tok//\'/}"   # quotes are noise once flattened
    case "$tok" in
      '#'*) break ;;                        # a comment ends the command
      *'|'*|*';'*|*'&'*) bs_flush; continue ;;
    esac
    # Which git subcommand are we inside? Latched independently, so a segment
    # that runs several (`git push origin main && git clean -f`) is judged on
    # each of them — the old whole-text scan caught those and this must not
    # narrow that.
    case "$tok" in
      push|git-push)   bs_push=1;  continue ;;
      reset|git-reset) bs_reset=1; continue ;;
      clean|git-clean) bs_clean=1; continue ;;
    esac
    # `--h`, `--ha`, `--har` are all `--hard` to git — the same opt_is the
    # parsed path uses, instead of a `*"reset --hard"*` substring test.
    if [ "$bs_reset" -eq 1 ]; then
      opt_is "$tok" --hard && deny "git reset --hard is blocked — stash or commit first. This text is piped into a shell, so it really is about to run."
    fi
    # `--f` is already `--force` to git clean, and the long form was missing
    # from the old short-flag-only substring list entirely.
    if [ "$bs_clean" -eq 1 ]; then
      case "$tok" in
        --*) opt_is "$tok" --force && deny "git clean -f is blocked (irreversible). This text is piped into a shell, so it really is about to run." ;;
        -*)  case "$tok" in *f*) deny "git clean -f is blocked (irreversible). This text is piped into a shell, so it really is about to run." ;; esac ;;
      esac
    fi
    [ "$bs_push" -eq 1 ] || continue
    case "$tok" in
      # The SAFE forms, exempted PER TOKEN. Judged here the token cannot be a
      # comment (`#` broke the loop above) and cannot be an unrelated word
      # elsewhere in the line — which is exactly how the old whole-text
      # carve-out was disabled by `# --force-with-lease`.
      --force-with-lease|--force-with-lease=*|--force-if-includes) : ;;
      --*)
        if opt_is "$tok" --delete; then
          bs_del=1
        elif opt_is "$tok" --mirror; then
          deny "\`git push --mirror\` is blocked. This text is piped into a shell, so it really is about to run: --mirror DELETES every remote ref that is absent locally, and names no ref for the disposable-namespace carve-out (quetrex-spec/*, *-gates) to clear."
        elif opt_is "$tok" --prune; then
          deny "\`git push --prune\` is blocked. This text is piped into a shell, so it really is about to run: --prune DELETES every remote ref the pushed refspec does not match, and names no ref for the disposable-namespace carve-out (quetrex-spec/*, *-gates) to clear."
        elif opt_is "$tok" --force; then
          deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection. This text is piped into a shell, so it really is about to run."
        fi ;;
      -*) case "$tok" in *f*) deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection. This text is piped into a shell, so it really is about to run." ;; esac
          case "$tok" in *d*) bs_del=1 ;; esac ;;
      :*|+:*) BS_COLON="$BS_COLON $tok" ;;
      # a leading + IS a force-push and names no flag — see check_git's push arm
      +*) BS_FORCE="$BS_FORCE $tok" ;;
      # a redirection is not a refspec — git refuses < and > in a ref name
      *'>'*|*'<'*) : ;;
      *) if [ "$bs_seen" -eq 0 ]; then bs_seen=1; bs_first="$tok"; else bs_rest="$bs_rest $tok"; fi ;;
    esac
  done
  bs_flush
  for p in $BS_COLON; do
    disposable_ref "$p" || deny "Deleting the remote ref '$p' is blocked. This text is piped into a shell, so it really is about to run: \`git push <remote> :<ref>\` is a ref DELETION. Only quetrex-spec/* and *-gates may be deleted this way."
  done
  for p in $BS_FORCE; do
    fdst=$(refspec_dst "$p")
    disposable_ref "$fdst" || deny "Force-updating the remote ref '$fdst' is blocked. This text is piped into a shell, so it really is about to run: a leading \`+\` on a refspec ('$p') IS a force-push — git reports '(forced update)' and it overwrites the remote exactly as \`--force\` does, with no --force flag present. Only quetrex-spec/* and *-gates may be force-updated this way."
  done
  for p in $BS_TARGETS; do
    disposable_ref "$p" || deny "Deleting the remote ref '$p' is blocked. This text is piped into a shell, so it really is about to run: \`git push --delete <ref>\` removes the branch outright, which is strictly less recoverable than the force-push this guard already denies. Only quetrex-spec/* and *-gates may be deleted this way — and that carve-out is judged on the REF, so naming either namespace elsewhere in the command (a comment, a path) does not clear it."
  done
  set +f
fi

exit 0
