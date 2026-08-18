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
#   3. .quetrex/verify-ledger.jsonl is GREEN: for every command in the verify
#      chain THE MERGED COMMIT ITSELF defines (read from the committed
#      .quetrex/verify.json at that sha — never the operator's working tree,
#      which during a `gh pr merge` is the BASE branch's copy), the most recent
#      ledger entry THAT DESCRIBES THAT COMMIT exited 0. A never-run command, a
#      red one, and a chain with no evidence for the merged commit at all all
#      block — this closes the stale-green hole. Entries pinned to some OTHER
#      commit (e.g. the local Stop-hook verify cycle appending against the
#      operator's main between the fetch and the merge) are evidence about
#      other code: they neither authorize this merge nor shadow the proof of it.
#   4. .quetrex/security-findings.json has NO finding with severity "critical"
#      AND status "open"; if it exists it must be for HEAD (.head_sha == HEAD);
#      and if the plan set security_review_required:true it MUST exist.
#   5. Every file in the diff being merged is covered by the architect's
#      ownership map in .quetrex/plan/<TASK>.json — a developer that edited
#      outside its lane cannot ship (see GATE 5 for the exemptions and for what
#      happens when a task ran without a plan). That plan, and the
#      .quetrex/state.json that names which task this merge is for, are
#      TRANSPORTED HOME from the cloud build on the <prefix><TASK>-gates branch
#      alongside the other artifacts; a plan whose approved base_sha is provably
#      not an ancestor of the merged commit is another task's leftover and is
#      refused rather than applied.
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
# sub-command's flags or a commit message can no longer trigger the gate.
#
# ============================================================================
# THE BOUNDARY OF WHAT THIS HOOK CAN GUARANTEE — read before extending it.
# ============================================================================
# This hook parses a COMMAND STRING. It does not execute a shell, does not
# track variable state across separate tool calls, and cannot see anything
# that happens outside the text it was handed. Every round of hardening this
# file has been through — segment splitting, quote-aware tokenizing, pflag-
# accurate flag parsing — has been about closing gaps WITHIN that boundary:
# making the hook's understanding of a command's own text match what a real
# shell/gh would do with that same text. None of it moves the boundary
# itself. Concretely:
#
# This list is corrected as of the round that fixed findings 1-4 below (a
# segment-splitter feeding the parser a TRUNCATED or CORRUPTED string, three
# distinct ways) — a previous version of this text claimed coverage the code
# did not actually have; treat any future gap between this comment and the
# tests in test/merge-gate.test.sh as a bug in ONE of the two, not a license
# to trust either blindly.
#
# COVERED (this hook DOES catch these, and is tested against them): ordinary
# and accidental cross-repo/cross-commit merges when the vector begins with
# a BARE, unwrapped `gh pr merge` (see NOT COVERED for what "bare" excludes)
# — a `--repo`/`-R` flag in any form gh accepts (separated, attached,
# `=`-joined, clustered with other short flags), a repeated flag (last
# wins, matching real gh), an inherited `GH_REPO` already in this process's
# own environment, a `GH_REPO=` assignment inline on the SAME segment
# (`GH_REPO=x gh pr merge`, `env GH_REPO=x gh pr merge`), a PR identifier
# given as a URL, a backslash-continued command split across physical
# lines, a value containing `&&`/`;`/`|`/`#` inside quotes (no longer
# corrupts the split), and a trailing `#` shell comment (no longer read as
# real flags). EVERY vector a compound command names is independently
# evaluated — `<merge> A && <merge> B`, `<merge> A && git push origin
# main`, and the reverse order, are each fully gated, not just the first.
#
# ALSO COVERED, deliberately, as a documented DECISION rather than an
# oversight: a `--repo` value that still looks like an unexpanded shell
# variable or command substitution (`$SLUG`, `${SLUG}`, `$(...)`, a
# backtick expression) is NOT treated as a literal repo name — this hook
# parses text before a shell would expand it, so it genuinely cannot know
# what `$SLUG` resolves to. It fails OPEN for that one signal (dropped, not
# compared) rather than closed, specifically so this engine's own
# `/quetrex:merge` command — which emits exactly this shape — can pass its
# own gate; the reasoning and the bounded residual risk are written at
# looks_like_shell_expr's call site. Where the LITERAL portion of such a
# value (everything before the first `$`/backtick) already disagrees with
# this repo's origin, that partial evidence IS still used to deny — an
# unexpandable SUFFIX doesn't rescue a wrong PREFIX.
#
# NOT COVERED, by design, and no amount of further pattern-matching fixes
# this — it needs either server-side enforcement (branch protection; tracked
# separately) or literally executing the shell to know the answer, which a
# PreToolUse hook that runs BEFORE execution structurally cannot do:
#   - A vector NOT anchored on a bare `gh`/`git` token: a path-qualified
#     binary (`/opt/homebrew/bin/gh pr merge ...` — reached GitHub for real
#     during review), an escaped name (`\gh pr merge ...`, a common way to
#     bypass a shell alias/function), or a wrapper whose OWN flags this
#     hook doesn't understand (`env -u SOMEVAR gh pr merge ...`, `sudo -E
#     gh pr merge ...` — normalize_segment strips the bare wrapper WORD but
#     does not parse the wrapper's own arguments, so a flag sitting between
#     the wrapper and `gh` defeats the anchor).
#   - The whole vector wrapped in command substitution or a subshell:
#     `RESULT=$(gh pr merge ...)`, `(gh pr merge ...)`. The text is present
#     in the command string, but not in a shape this hook's segment
#     anchoring recognizes as "a command that begins with gh".
#   - `export GH_REPO=x; gh pr merge ...` as ONE command whose earlier
#     segment sets the variable this command then relies on. Bounded in
#     principle (same command string), but this hook does not track
#     arbitrary variable assignments across segments — seeing a `GH_REPO=`
#     prefix ON THE MERGE SEGMENT ITSELF is covered (above); an `export` in
#     an EARLIER segment of the same line is not.
#   - A shell FUNCTION, a sourced `.env`, direnv, or `gh`'s own persisted
#     config (`gh config set`, `~/.config/gh/hosts.yml`) changing what a
#     bare `gh pr merge` resolves to. None of these appear in the command
#     text at all.
#   - `export GH_REPO=x` in an EARLIER, SEPARATE tool call, then `gh pr
#     merge` in a LATER one. This hook only ever sees one command at a time
#     — no memory of prior calls. (In practice this is PARTIALLY covered as
#     a side effect: if the session's shell persists environment between
#     tool calls, that earlier export is often still exported when the later
#     command's hook invocation runs, and the "inherited env" check above
#     catches it then — but that is incidental, not a guarantee this hook
#     makes.)
#   - A vector deliberately obfuscated to defeat text matching beyond the
#     above — git plumbing, a wrapper script, a library binding,
#     base64/eval tricks.
#
# A command-string parser answers "does this LOOK like an ordinary or
# accidental cross-repo/cross-commit merge" — it cannot answer "is there ANY
# way, considering the full state of this shell session and every file it
# could read, that this command ends up targeting a different repo or
# commit than it appears to." Treat this hook as a strong guard against
# operator mistakes and routine pipeline commands, not as a security
# boundary against a determined, capable adversary who controls the shell
# session — that boundary belongs server-side (GitHub branch protection),
# where it cannot be talked around by clever command construction, and
# where enforcement does not depend on parsing text correctly at all.
# ============================================================================
#
# Residual, and deliberately so: a vector constructed to hide from a regex
# (git plumbing, a script file, a library binding) is not detected. This gate
# mechanizes the pipeline's own policy against the pipeline's own commands; it
# is not a sandbox, and pretending otherwise is what produced the false
# positives in the first place.

# --- split on && || ; and | -- OUTSIDE quotes and comments, joining --------
# --- backslash-newline continuations along the way -------------------------
#
# THE DEFECT THIS REPLACES. The previous splitter was a quote-BLIND
# `awk gsub(/&&|\|\||;|\|/, "\n")` over the raw command string. A value that
# happens to contain one of those substrings inside quotes —
#
#     gh pr merge 7 --squash -t 'build && test'
#
# — got split MID-QUOTE, corrupting a legitimate command into a truncated,
# unparseable one purely because of what a commit-message-style flag's VALUE
# said. Reusing a second, independently-written quoting implementation here
# was explicitly rejected: this file already has ONE character-by-character
# quote-tracking state machine (tokenize_argv, defined below, used to parse
# gh's own argv) and a second one for segment-splitting is exactly the kind
# of duplicated logic that drifts out of sync with the first — which is how
# this file accumulated five rounds of "one more spelling of the same hole."
# split_segments_quote_aware below is a SIBLING state machine with THE SAME
# quoting rules (single quotes: no escapes; double quotes: backslash escapes
# `"\$`\`` only) applied to a different job (finding operator boundaries
# instead of finding word boundaries) — kept in that shape, not literally
# shared code, because a bash function call per character would cost real
# time for two different consumers; if the quoting RULES ever change, both
# functions must change together, and this comment is the reminder.
#
# BACKSLASH-NEWLINE CONTINUATIONS are joined HERE, in the SAME character
# scan, rather than as a separate `sed` pass beforehand. That earlier `sed`
# pass — `sed -e :a -e '/\\$/N; s/\\\n//; ta'`, once documented here as
# "the portable (GNU- and BSD-sed) idiom" — was neither portable nor
# correct, proven by running it against the REAL BSD sed shipped on macOS
# (not just reasoned about):
#   - `N` at the LAST line, with no following line to append, is a
#     documented GNU/BSD divergence: BSD sed's classic behavior is to quit
#     WITHOUT printing the pattern space. `printf 'X Y \' | sed ...` — a
#     command that merely ENDS in a lone backslash, e.g. a typo — produced
#     ZERO BYTES of output. Empty $COMMAND means no segments, means nothing
#     is ever classified as a vector, means the gate is BLIND to the rest
#     of the command — including a bare `push origin main` sharing the same
#     compound line. Worse on macOS, the operator's own machine, than in a
#     GNU-userland cloud container.
#   - A DOUBLED trailing backslash (`A \\` + newline + `B`) is an escaped,
#     LITERAL backslash followed by a real newline in actual shell grammar
#     — the shell keeps these as TWO separate things. `/\\$/` matches any
#     line ending in a single `\` regardless of how many precede it, so the
#     sed version joined this into `A \B`, merging what a real shell keeps
#     separate — and, per finding 1 below, the SECOND thing can be another
#     merge command that must be independently evaluated, not silently
#     concatenated onto the first.
# A character-scanning state machine gets both right for free: it consumes
# an escaping backslash together with the SPECIFIC next character it
# escapes (never re-examining "how many backslashes precede a position"),
# so `\\` is consumed as one escaped-backslash unit BEFORE the following
# real newline is ever looked at (line stays split), while a lone `\`
# directly followed by a newline is recognized and both characters are
# dropped entirely (line joins, with nothing inserted — matching real
# shell continuation semantics exactly). This only applies OUTSIDE quotes,
# matching the specific, reported failure shape; a backslash-newline
# INSIDE a quoted string is left as literal text, unchanged from before.
split_segments_quote_aware() {
  # Two `local` statements, same reason as tokenize_argv below: word
  # expansion for the WHOLE `local` command happens before the builtin
  # runs, against the enclosing scope's state -- `n=${#s}` on the same
  # line as `s="$1"` would see `s` as unset under `set -u`.
  local s="$1"
  local i=0 n=${#s} c two nc out='' in_sq=0 in_dq=0 in_cm=0 have=0
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    if [ "$in_cm" -eq 1 ]; then
      out+="$c"
      if [ "$c" = $'\n' ]; then in_cm=0; have=0; fi
    elif [ "$in_sq" -eq 1 ]; then
      out+="$c"; have=1
      [ "$c" = "'" ] && in_sq=0
    elif [ "$in_dq" -eq 1 ]; then
      out+="$c"; have=1
      if [ "$c" = '\' ] && [ $((i + 1)) -lt "$n" ]; then
        i=$((i + 1)); out+="${s:$i:1}"
      elif [ "$c" = '"' ]; then
        in_dq=0
      fi
    else
      case "$c" in
        ' ' | $'\t')
          out+="$c"; have=0
          ;;
        $'\n')
          out+="$c"; have=0
          ;;
        "'") in_sq=1; out+="$c"; have=1 ;;
        '"') in_dq=1; out+="$c"; have=1 ;;
        '#')
          # A `#` starts a shell comment only at the START of a word --
          # tracked with the SAME `have` flag tokenize_argv uses (whether
          # we're currently mid-token), not by inspecting the last emitted
          # character. Those disagree: `a\ #x` (an ESCAPED space before
          # `#`) leaves the literal character before `#` a space either
          # way, but the escape means we're still INSIDE the word "a x" —
          # `have` correctly stays 1 through an escaped separator (see the
          # `\` case below), while inspecting `${out: -1}` could not tell
          # an escaped separator from a real one and wrongly started a
          # "comment" mid-word. A differential test (DEFECT K) feeds both
          # functions the same corpus and fails on any disagreement.
          if [ "$have" -eq 0 ]; then
            in_cm=1
          fi
          out+="$c"; have=1
          ;;
        '\')
          if [ $((i + 1)) -lt "$n" ]; then
            nc="${s:$((i + 1)):1}"
            if [ "$nc" = $'\n' ]; then
              # Genuine continuation: an unescaped backslash immediately
              # followed by a newline. Drop BOTH characters -- a real shell
              # removes them entirely, joining the two physical lines with
              # nothing inserted between them.
              i=$((i + 1))
            else
              out+="$c"; i=$((i + 1)); out+="$nc"; have=1
            fi
          else
            out+="$c"; have=1
          fi
          ;;
        '&' | '|')
          two="${s:$i:2}"
          if [ "$two" = "&&" ] || [ "$two" = "||" ]; then
            out+=$'\n'
            i=$((i + 1))
          else
            out+=$'\n'
          fi
          have=0
          ;;
        ';')
          out+=$'\n'
          have=0
          ;;
        *)
          out+="$c"; have=1
          ;;
      esac
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

SEGMENTS=$(split_segments_quote_aware "$COMMAND")

# Strip leading wrappers so `sudo git push …`, `FOO=1 git push …` and
# `bash -c "git push …"` still anchor on the real invocation.
# normalize_segment <segment> -- sets NORM_RESULT to the segment with
# leading wrappers/assignments stripped, and NORM_GH_REPO_PREFIX to any
# `GH_REPO=` assignment found along the way (see below). Deliberately a
# global-variable-output function, NOT `printf` + command substitution: an
# earlier version returned via stdout and was called as `norm=$(normalize_
# segment "$seg")`, and `$(...)` always forks a SUBSHELL — any variable this
# function set (NORM_GH_REPO_PREFIX included) was set in that subshell's own
# copy of the environment and vanished the instant the subshell exited,
# never reaching the caller. The bug was silent: bash only complained (an
# "unbound variable" under `set -u`) at the call site that later tried to
# read the never-propagated value, far from where it was actually lost.
normalize_segment() {
  local s="$1" first
  # A leading `GH_REPO=value` (or `env GH_REPO=value`) is stripped below like
  # any other wrapper/assignment prefix — but gh itself reads GH_REPO from
  # the environment when no --repo/-R flag is present, so silently discarding
  # it here would mean `GH_REPO=other-org/other-repo gh pr merge 7` and
  # `env GH_REPO=other-org/other-repo gh pr merge 7` carry a real repo
  # selector that this hook then never sees. Capture it (last one wins, same
  # as gh's own last-assignment-wins semantics) into NORM_GH_REPO_PREFIX so
  # the caller can fold it into the cross-repo signal set. Reset per call —
  # only the assignments IN THIS SEGMENT are in scope; see the boundary note
  # above `normalize_segment`'s call site for what is deliberately NOT (an
  # `export GH_REPO=x;` on an EARLIER, separate segment of the same line).
  NORM_GH_REPO_PREFIX=""
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
          case "$first" in
            GH_REPO=*) NORM_GH_REPO_PREFIX="${first#GH_REPO=}" ;;
          esac
          s="${s#"$first"}"
        else
          break
        fi ;;
    esac
    s=$(printf '%s' "$s" | sed 's/^[[:space:]]*//')
  done
  NORM_RESULT="$s"
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

# --- collect EVERY vector in the command, not just the first ---------------
#
# THE DEFECT THIS REPLACES. Every previous version of this loop `break`s the
# instant it finds ONE vector, and everything downstream evaluates only that
# single (merge_kind, VECTOR_SEG) pair. A compound command naming TWO
# vectors —
#
#     gh pr merge 91 --repo this-repo --squash && \
#     gh pr merge 17 --repo other-repo --squash
#
# — got a real `gh pr view` call logged for BOTH PRs, but the gate only ever
# evaluated the FIRST: it resolved this-repo's clean artifacts, allowed, and
# the SECOND `gh pr merge` — into a repo these artifacts say nothing about —
# rode along, never independently judged. The same shape denies nothing for
# `<merge> ... && git push origin main` or `git push origin main && <merge>
# ... --repo other`, in either order. This is the exact situation a team
# running two PRs in two repos will eventually hit: one command, two ships,
# and a `break` that only ever looks at the first one.
#
# Fixed by NOT breaking: every segment that matches a vector shape is
# appended to parallel arrays (kind/segment/gh-repo-prefix/pending-cd-at-
# that-point, since a `cd` earlier in the SAME compound command can affect
# a LATER vector without affecting an earlier one). Below, evaluate_vector
# runs the ENTIRE gate pipeline once per collected vector; `deny()` inside
# it still exits the whole hook immediately on the FIRST failure — the
# change is that a vector can no longer go unevaluated just because an
# earlier one in the same command happened to be clean.
is_merge_vector=0
VECTOR_KINDS=()
VECTOR_SEGS=()
VECTOR_GH_REPO_PREFIXES=()
VECTOR_PENDING_CDS=()
PENDING_CD=""

while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  normalize_segment "$seg"
  norm="$NORM_RESULT"
  [ -z "$norm" ] && continue

  # Track `cd <dir>` so a later `git merge` in the same compound command is
  # evaluated against the directory it will actually run in.
  if [[ "$norm" =~ ^cd[[:space:]]+([^[:space:]]+) ]]; then
    PENDING_CD=$(printf '%s' "${BASH_REMATCH[1]}" | sed 's/^["'\'']*//; s/["'\'']*$//')
    continue
  fi

  # (a) gh pr merge — the primary vector under the new policy.
  if [[ "$norm" =~ ^gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]]; then
    is_merge_vector=1
    VECTOR_KINDS+=("gh pr merge")
    VECTOR_SEGS+=("$norm")
    VECTOR_GH_REPO_PREFIXES+=("$NORM_GH_REPO_PREFIX")
    VECTOR_PENDING_CDS+=("$PENDING_CD")
    continue
  fi

  # (b) git push whose OWN arguments target master/main (a push straight to the
  #     protected branch, including from a feature branch — which
  #     enforce-branch does not catch).
  if [[ "$norm" =~ ${GIT_ANCHOR}push([[:space:]]|$) ]] && ! is_tag_push "$norm"; then
    if targets_protected_branch "$norm"; then
      is_merge_vector=1
      VECTOR_KINDS+=("push to main")
      VECTOR_SEGS+=("$norm")
      VECTOR_GH_REPO_PREFIXES+=("")
      VECTOR_PENDING_CDS+=("$PENDING_CD")
      continue
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
      is_merge_vector=1
      VECTOR_KINDS+=("merge into main")
      VECTOR_SEGS+=("$norm")
      VECTOR_GH_REPO_PREFIXES+=("")
      VECTOR_PENDING_CDS+=("$PENDING_CD")
      continue
    fi
  fi
done <<< "$SEGMENTS"

# Not a merge-to-main command -> nothing to gate.
[ "$is_merge_vector" -eq 1 ] || exit 0

# evaluate_vector <merge_kind> <vector_seg> <gh_repo_prefix> <pending_cd> --
# runs the ENTIRE gate pipeline (repo resolution through GATE 5) against ONE
# collected vector. `local` for exactly these four -- the ones the CALLER
# supplies per-vector -- shadows the loop's own globals of the same name for
# the body below, which otherwise needs NO changes: every other variable the
# body sets (ROOT, HEAD_SHA, EFFECTIVE_REPO, VERDICT, and so on) is freshly
# (re)assigned within this function on every call, so leaving them as plain
# globals is correct too -- there is nothing to accumulate BETWEEN calls,
# since evaluate_vector runs each vector one at a time, never concurrently.
# `deny()` (defined inside, below) still calls `exit` -- a denial on ANY
# vector must terminate the WHOLE hook immediately, exactly as before; what
# changed is that reaching the end of this function cleanly now `return`s
# to the caller's loop instead of `exit`ing the whole script, so a clean
# vector no longer prevents the NEXT one in the same command from being
# evaluated at all.
evaluate_vector() {
  local merge_kind="$1" VECTOR_SEG="$2" VECTOR_GH_REPO_PREFIX="$3" PENDING_CD="$4"

  # THE LEAK THIS CLOSES. DIFF_BASE is assigned ONLY inside the `gh pr
  # merge` branch below (`DIFF_BASE="$PR_BASE_SHA"`), then read via
  # `if [ -z "${DIFF_BASE:-}" ]; then DIFF_BASE="main"; ... fi` — a
  # fallback-if-unset pattern that means a NON-gh-pr-merge vector (push to
  # main, merge into main) never assigns it at all THIS call, so it falls
  # through to whatever a PRIOR vector in the SAME compound command left it
  # as. Two clean-looking vectors targeting DIFFERENT repos, evaluated back
  # to back by the loop below, meant the second one's diff-content gates
  # (sensitive-surface detection, GATE 5 ownership) silently diffed against
  # a base commit from the FIRST repo — an object `git diff` can't find in
  # the second, so it reads as "no changes", and both gates pass by
  # omission on a diff they never actually inspected. Every OTHER variable
  # this function touches was audited for the same shape (see the round's
  # commit message for the full list). Correcting that audit, not
  # retracting it: DIFF_BASE was NOT the only ${VAR:-} read in this
  # function — grep finds several more, including VECTOR_LABEL's own
  # ${VECTOR_ORIGIN_SLUG:-$ROOT} 43 lines below. Every one of them is
  # safe, but because an unconditional assignment PRECEDES the read on
  # the same call, not because the ${VAR:-} shape itself is absent —
  # finding a ${VAR:-} pattern here is not by itself proof of a leak;
  # check for a preceding assignment first. Likewise, ADDED/FINDINGS/
  # SEC_SHA/OPEN_CRIT are each computed inside the single conditional arm
  # that consumes them (arm-scoped, never read outside it), not via an
  # "unconditional command substitution ... even when the result is
  # empty" as the commit message filed them — safe for that reason
  # instead. DIFF_BASE was the one place a ${VAR:-} read had NO
  # assignment, conditional or unconditional, preceding it on a
  # non-gh-pr-merge call; that absence, not the syntax, was the bug.
  DIFF_BASE=""

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
  { [ -n "$ROOT" ] && [ -d "$QDIR" ]; } || return 0

  # A human-readable identity for THIS vector's repo, computed once here so
  # every deny() call below (via the prefix deny() adds — see next) names
  # which repo it's actually about. Origin's owner/repo slug when a remote
  # is configured (the common case, and the same extraction other gates
  # already use), falling back to the absolute checkout path otherwise —
  # still unique, just less pretty.
  # Lowercased to match ORIGIN_SLUG (computed later, same extraction, also
  # lowercased) — otherwise the cross-repo refusal prints the same slug
  # twice in two different casings: deny()'s own [$VECTOR_LABEL] prefix
  # next to ORIGIN_SLUG quoted verbatim in the message body.
  VECTOR_ORIGIN_SLUG=$(git -C "$ROOT" remote get-url origin 2>/dev/null \
    | sed -e 's#\.git$##' -e 's#.*[:/]\([^/][^/]*/[^/][^/]*\)$#\1#' | tr 'A-Z' 'a-z')
  VECTOR_LABEL="${VECTOR_ORIGIN_SLUG:-$ROOT}"

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
  #
  # EVERY deny() reason is prefixed with `[$VECTOR_LABEL]` HERE, once, rather
  # than edited into each of GATE 1-5's ~20 individual call sites. Without
  # it, a compound command naming two repos denied on whichever gate failed
  # in the SECOND one read identically to a same-repo denial — "the verify
  # chain is not green... `true` -> exit 1" says nothing about WHICH repo,
  # and an operator standing in the clean FIRST repo (whose own ledger says
  # exit 0) would be sent to debug a problem that isn't there. The cross-
  # repo refusal already named both slugs explicitly; this gives every
  # other gate the same property for free, and automatically covers any
  # deny() call added later too.
  deny() {
    local reason="$1"
    reason="[$VECTOR_LABEL] $reason"
    if command -v jq >/dev/null 2>&1; then
      jq -cn --arg r "$reason" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0
    fi
    printf '%s\n' "$reason" >&2
    exit 2
  }

  # FAIL-CLOSED: a real quetrex merge with no jq cannot be evaluated -> deny.
  if ! command -v jq >/dev/null 2>&1; then
    deny "MERGE GATE (ESCALATE_HUMAN): jq is not installed, so the merge gate cannot verify the review verdict, verify ledger, or security findings for '$merge_kind'. A merge must never proceed unevaluated. Install jq, then re-run the pipeline's review-gate."
  fi

  # --- gh pr merge argv: TOKENIZE and WALK it like gh's own flag parser ------
  #
  # THE DEFECT THIS REPLACES (five review rounds, five new spellings of the
  # same hole). Every previous version of this section matched a REGEX against
  # the whole command-segment STRING to find a --repo/-R flag. gh's flag
  # parser is pflag (Go), which is not regular: it understands separated
  # (`-R x`), attached (`-Rx`), `=`-joined (`-R=x`), and CLUSTERED short flags
  # (`-dRx` is --delete-branch + --repo, `-sdRx` is --squash + --delete-branch
  # + --repo), and for a repeated flag the LAST occurrence wins. A regex
  # anchored on a literal `-R` cannot represent "-R preceded by other short
  # flags packed into the same token," cannot represent "take the LAST match,
  # not the first" (bash's `=~` is leftmost-only), and — because it scans the
  # whole string rather than discrete tokens — cannot avoid matching "-R"
  # INSIDE the quoted VALUE of an unrelated flag (`-t 'chore: post-Review
  # cleanup'` regexed as if `-Review` were `--repo`). Every one of these was
  # found, independently, by adversarial review against the real `gh` binary.
  #
  # The fix is architectural, not another pattern: TOKENIZE the segment the way
  # a shell would (quote-aware, no `eval` — see tokenize_argv), then WALK the
  # tokens the way pflag does: left to right, tracking clusters, `=`,
  # attachment, and last-wins. FAIL CLOSED on anything that doesn't match a
  # KNOWN gh-pr-merge flag shape — an unrecognized flag, an unterminated
  # quote, or an ambiguous PR-identifier form denies the WHOLE merge rather
  # than guessing which value gh will actually use. A wrong guess here is not
  # a missed detection; it is authorizing a merge in a repo (or against a
  # commit) these artifacts say nothing about.

  # tokenize_argv <string> -- sets TOKENS[] (bash array) and
  # TOKENIZE_UNTERMINATED (1 if a quote was never closed). No eval: a
  # character-by-character state machine, so a $(...)/backtick inside the
  # inspected command string is read as inert text, never executed.
  tokenize_argv() {
    # Split into two `local` statements deliberately: word expansion for an
    # ENTIRE `local` command happens before the builtin runs, all in the
    # enclosing scope's variable state — so `n=${#s}` on the SAME line as
    # `s="$1"` would expand against whatever `s` was BEFORE this declaration
    # (unset, under `set -u` an error) rather than the value just assigned.
    local s="$1"
    local i=0 n=${#s} c token='' in_sq=0 in_dq=0 have=0 nc
    TOKENS=()
    TOKENIZE_UNTERMINATED=0
    while [ "$i" -lt "$n" ]; do
      c="${s:$i:1}"
      if [ "$in_sq" -eq 1 ]; then
        if [ "$c" = "'" ]; then in_sq=0; else token+="$c"; fi
      elif [ "$in_dq" -eq 1 ]; then
        if [ "$c" = '"' ]; then in_dq=0
        elif [ "$c" = '\' ] && [ $((i + 1)) -lt "$n" ]; then
          nc="${s:$((i + 1)):1}"
          case "$nc" in
            '"' | '\' | '$' | '`') token+="$nc"; i=$((i + 1)) ;;
            *) token+="$c" ;;
          esac
        else
          token+="$c"
        fi
      else
        case "$c" in
          ' ' | $'\t')
            [ "$have" -eq 1 ] && { TOKENS+=("$token"); token=''; have=0; }
            ;;
          "'") in_sq=1; have=1 ;;
          '"') in_dq=1; have=1 ;;
          '#')
            # A `#` at the START of a word (not mid-token, outside quotes) is
            # a shell comment — everything after it on this segment is inert.
            # Without this, a trailing `# ... --repo evil/repo` comment reads
            # as a real flag: the same over-match class as finding 3, just in
            # the tokenizer instead of the segment splitter. `foo#bar` (no
            # preceding space) is NOT a comment, matching real shell syntax.
            if [ "$have" -eq 0 ]; then
              break
            fi
            token+="$c"; have=1
            ;;
          '\')
            if [ $((i + 1)) -lt "$n" ]; then
              token+="${s:$((i + 1)):1}"
              i=$((i + 1))
              have=1
            fi
            ;;
          *) token+="$c"; have=1 ;;
        esac
      fi
      i=$((i + 1))
    done
    [ "$have" -eq 1 ] && TOKENS+=("$token")
    { [ "$in_sq" -eq 1 ] || [ "$in_dq" -eq 1 ]; } && TOKENIZE_UNTERMINATED=1
  }

  # gh pr merge's flags, classified value/bool/unknown. `case`, not an
  # associative array: this file targets plain bash (macOS ships bash 3.2 as
  # /usr/bin/bash, no associative arrays), matching the style already used for
  # PR_VALUE_FLAGS elsewhere.
  gh_merge_short_kind() {  # -> prints value|bool|unknown
    case "$1" in
      A | b | F | t | R) printf 'value' ;;
      d | m | r | s) printf 'bool' ;;
      *) printf 'unknown' ;;
    esac
  }
  gh_merge_long_kind() {  # -> prints value|bool|unknown
    case "$1" in
      author-email | body | body-file | subject | match-head-commit | repo) printf 'value' ;;
      admin | auto | delete-branch | disable-auto | merge | rebase | squash | help) printf 'bool' ;;
      *) printf 'unknown' ;;
    esac
  }

  # looks_like_shell_expr <value> -- true if VALUE still looks like a shell
  # variable reference or command substitution ($SLUG, ${SLUG}, $(...), a
  # backtick expression) rather than a literal string. A real repo slug never
  # legitimately contains "$" or a backtick; seeing one means this text was
  # captured from the command's SOURCE before a shell would have expanded it
  # — which a PreToolUse hook, running before execution, always sees. See the
  # boundary note near the top of this file and the comment at this
  # function's call site for why that's handled as UNKNOWN, not fail-closed.
  looks_like_shell_expr() {
    case "$1" in
      *'$'* | *'`'*) return 0 ;;
      *) return 1 ;;
    esac
  }

  # repo_expr_literal_prefix <value> -- prints the literal text before the
  # FIRST "$" or backtick in VALUE -- the part no shell expansion can ever
  # change, regardless of what the variable/substitution after it resolves
  # to. Empty when the expression starts at position 0 (e.g. plain "$SLUG"
  # has no literal prefix at all).
  repo_expr_literal_prefix() {
    local v="$1" p1 p2
    p1="${v%%\$*}"
    p2="${v%%\`*}"
    if [ "${#p1}" -le "${#p2}" ]; then printf '%s' "$p1"; else printf '%s' "$p2"; fi
  }

  # deny_if_literal_prefix_contradicts <raw_value> <source_label> -- called
  # only for a value looks_like_shell_expr already flagged as unresolvable
  # (fail-open: dropped as a signal, not compared -- see the boundary note
  # and the call site below for the full reasoning, including why this is
  # NOT a fail-closed reversal of that decision). Its KNOWN literal prefix
  # is still checked: if ORIGIN_SLUG does not even START WITH that prefix,
  # NO possible expansion of the unresolved remainder could make the
  # finished value equal ORIGIN_SLUG -- that is proof of a mismatch, not an
  # unknown. An unexpandable SUFFIX must not rescue a wrong PREFIX.
  deny_if_literal_prefix_contradicts() {
    local raw="$1" label="$2" prefix lc_prefix
    [ -z "${ORIGIN_SLUG:-}" ] && return 0
    prefix=$(repo_expr_literal_prefix "$raw")
    [ -z "$prefix" ] && return 0
    lc_prefix=$(printf '%s' "$prefix" | tr 'A-Z' 'a-z')
    if [ "${ORIGIN_SLUG#"$lc_prefix"}" = "$ORIGIN_SLUG" ]; then
      deny "MERGE GATE (ESCALATE_HUMAN): the $label value '$raw' is not fully resolvable (it contains an unexpanded shell expression), but its known literal prefix '$prefix' already does not match this checkout's origin '$ORIGIN_SLUG' -- no possible expansion of the rest could make it match. This gate will not guess that the expression conveniently resolves to this repo when its own fixed text already says otherwise."
    fi
  }

  # parse_gh_pr_merge <segment> -- tokenizes and walks a `gh pr merge ...`
  # segment the way pflag would. Sets:
  #   PARSE_OK        1 if every token was classified with confidence
  #   PARSED_PR_ID    the PR identifier (number/URL/branch), or empty
  #   PARSED_REPO     the repo the LAST -R/--repo occurrence named (repeated
  #                   flags: last wins, matching real gh), or empty
  parse_gh_pr_merge() {
    local seg="$1" i n tok kind name val rest letter after_dd=0
    PARSE_OK=1
    PARSED_PR_ID=""
    PARSED_REPO=""

    tokenize_argv "$seg"
    if [ "$TOKENIZE_UNTERMINATED" -eq 1 ]; then
      PARSE_OK=0
      return
    fi

    n=${#TOKENS[@]}
    # First 3 tokens are the already-matched "gh pr merge" prefix.
    if [ "$n" -lt 3 ]; then PARSE_OK=0; return; fi
    i=3
    while [ "$i" -lt "$n" ]; do
      tok="${TOKENS[$i]}"
      if [ "$after_dd" -eq 1 ]; then
        [ -z "$PARSED_PR_ID" ] && PARSED_PR_ID="$tok"
        i=$((i + 1)); continue
      fi
      case "$tok" in
        --)
          after_dd=1 ;;
        --*)
          name="${tok#--}"
          val=""
          case "$name" in
            *=*) val="${name#*=}"; name="${name%%=*}" ;;
          esac
          kind=$(gh_merge_long_kind "$name")
          case "$kind" in
            unknown) PARSE_OK=0; return ;;
            bool)
              [ -n "$val" ] && { PARSE_OK=0; return; }
              ;;
            value)
              if [ -z "$val" ] && [[ "$tok" != *=* ]]; then
                i=$((i + 1))
                [ "$i" -ge "$n" ] && { PARSE_OK=0; return; }
                val="${TOKENS[$i]}"
              fi
              [ "$name" = "repo" ] && PARSED_REPO="$val"
              ;;
          esac
          ;;
        -?*)
          rest="${tok#-}"
          while [ -n "$rest" ]; do
            letter="${rest:0:1}"
            rest="${rest:1}"
            kind=$(gh_merge_short_kind "$letter")
            case "$kind" in
              unknown) PARSE_OK=0; return ;;
              bool) : ;;
              value)
                val="${rest#=}"
                if [ -z "$val" ]; then
                  i=$((i + 1))
                  [ "$i" -ge "$n" ] && { PARSE_OK=0; return; }
                  val="${TOKENS[$i]}"
                fi
                [ "$letter" = "R" ] && PARSED_REPO="$val"
                rest=""
                ;;
            esac
          done
          ;;
        *)
          [ -z "$PARSED_PR_ID" ] && PARSED_PR_ID="$tok"
          ;;
      esac
      i=$((i + 1))
    done
  }

  # --- resolve the PR identifier and any repo selector, ONCE ------------------
  # Both the cross-repo refusal below and the later PR-head/base resolution
  # reuse PARSED_PR_ID / EFFECTIVE_REPO — a single parse, not two independent
  # passes that could (and, historically, did) disagree.
  PARSED_PR_ID=""
  EFFECTIVE_REPO=""
  if [ "$merge_kind" = "gh pr merge" ]; then
    parse_gh_pr_merge "$VECTOR_SEG"
    if [ "$PARSE_OK" -ne 1 ]; then
      deny "MERGE GATE (ESCALATE_HUMAN): could not confidently parse this 'gh pr merge' invocation — an unrecognized flag, an unterminated quote, or an unrecognized PR-identifier URL. A merge must never be evaluated by guessing what its arguments mean. Simplify the command, or run it after confirming the target repo and commit by hand."
    fi

    # A PR URL names a repo too — gh resolves the PR (and the repo) straight
    # from it. A token containing "://" that ISN'T a recognized github.com PR
    # URL is not silently treated as a harmless branch name — same fail-closed
    # rule as an unknown flag.
    URL_REPO=""
    case "$PARSED_PR_ID" in
      https://github.com/*/*/pull/*)
        if [[ "$PARSED_PR_ID" =~ ^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+/?$ ]]; then
          URL_REPO=$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')
        else
          deny "MERGE GATE (ESCALATE_HUMAN): the PR identifier '$PARSED_PR_ID' looks like a GitHub PR URL but doesn't match the recognized github.com owner/repo/pull/number shape. A merge must never be evaluated by guessing which repository a malformed URL names."
        fi
        ;;
      *://*)
        deny "MERGE GATE (ESCALATE_HUMAN): the PR identifier '$PARSED_PR_ID' looks like a URL this gate doesn't recognize as a GitHub PR URL. A merge must never be evaluated by guessing which repository it names."
        ;;
    esac

    # gh ALSO reads GH_REPO from the environment when no --repo/-R flag is on
    # the command line — this hook's OWN process environment is the same one
    # the real `gh pr merge` will run in, so an exported GH_REPO here is a
    # genuine signal, not noise. This is exactly why the flag-parsed value
    # above lives in PARSED_REPO, never in a variable literally named
    # GH_REPO: reusing gh's own environment-variable name for internal state
    # made an ambiently-exported GH_REPO indistinguishable from "the command
    # itself set --repo" — the classic collision. If this fires on a
    # same-repo merge unexpectedly, `unset GH_REPO` in the shell and retry.
    ENV_REPO=$(printf '%s' "${GH_REPO:-}" | tr 'A-Z' 'a-z')

    # An inline/env-wrapped `GH_REPO=` assignment ON THIS SAME SEGMENT
    # (`GH_REPO=x gh pr merge`, `env GH_REPO=x gh pr merge`) is a signal too
    # — captured by normalize_segment above into VECTOR_GH_REPO_PREFIX rather
    # than silently discarded along with the rest of the prefix. An `export
    # GH_REPO=x;` on an EARLIER, separate segment of the same line is NOT
    # covered here — see the boundary note near the top of this file for why.
    PREFIX_REPO_RAW=$(printf '%s' "$VECTOR_GH_REPO_PREFIX" | sed 's/^["'\'']*//; s/["'\'']*$//')
    FLAG_REPO_RAW=$(printf '%s' "$PARSED_REPO" | sed 's/^["'\'']*//; s/["'\'']*$//')

    # Resolved once, here, rather than only inside the sha-compare branch
    # below — deny_if_literal_prefix_contradicts (next) needs it too, and
    # computing it just once for both uses is both cheaper and the only way
    # the two checks can agree on what "this repo" means.
    ORIGIN_SLUG=$(git -C "$ROOT" remote get-url origin 2>/dev/null \
      | sed -e 's#\.git$##' -e 's#.*[:/]\([^/][^/]*/[^/][^/]*\)$#\1#' | tr 'A-Z' 'a-z')

    # An unexpanded shell variable/command-substitution in the repo VALUE
    # position ($SLUG, ${SLUG}, $(...), `...`) is treated as UNKNOWN — not as
    # a literal repo name to compare — and dropped from the signal set (fail
    # OPEN, for this signal only). This hook parses TEXT; it does not execute
    # a shell and cannot know what $SLUG will resolve to. FAIL-CLOSED here was
    # considered and rejected: this exact shape is what this engine's OWN
    # `/quetrex:merge` command emits (`gh pr merge "$PR_NUM" --repo "$SLUG"
    # ...`, with SLUG computed from the local repo's own origin earlier in
    # the same script) — denying on an unresolvable expression would deny
    # that command for the SAME reason every time, breaking the pipeline's
    # own merge step outright. The residual risk is bounded: a value set via
    # a mechanism this hook DOES track (an inherited/inline GH_REPO, above)
    # is still caught by THAT signal independently of what this flag's own
    # value says; a value set via a mechanism this hook does not track at
    # all (a shell function, a sourced file) is already out of bounds
    # regardless — see the boundary note — and fail-closed here would not
    # close that gap, only break the common, legitimate case.
    #
    # STILL DENIES on a value whose KNOWN LITERAL PREFIX already contradicts
    # this repo's origin (`--repo "other-org/$VAR"`, `--repo "other-org/
    # other-repo${EMPTY}"`) — see deny_if_literal_prefix_contradicts. Fail
    # OPEN means "unknown", not "assume it happens to resolve to this repo";
    # when the fixed, un-expandable part of the value already proves it
    # cannot, that is no longer an unknown.
    if looks_like_shell_expr "$FLAG_REPO_RAW"; then
      FLAG_REPO=""
      deny_if_literal_prefix_contradicts "$FLAG_REPO_RAW" "-R/--repo"
    else
      FLAG_REPO=$(printf '%s' "$FLAG_REPO_RAW" | tr 'A-Z' 'a-z')
    fi
    if looks_like_shell_expr "$PREFIX_REPO_RAW"; then
      PREFIX_REPO=""
      deny_if_literal_prefix_contradicts "$PREFIX_REPO_RAW" "GH_REPO= prefix-assignment"
    else
      PREFIX_REPO=$(printf '%s' "$PREFIX_REPO_RAW" | tr 'A-Z' 'a-z')
    fi

    # Collect DISTINCT non-empty repo signals. More than one, disagreeing, is
    # ambiguous — refuse to guess which one gh will actually honor rather
    # than picking one and being wrong.
    SIGNAL_SET=""
    for sig in "$FLAG_REPO" "$PREFIX_REPO" "$URL_REPO" "$ENV_REPO"; do
      [ -z "$sig" ] && continue
      case " $SIGNAL_SET " in
        *" $sig "*) : ;;
        *) SIGNAL_SET="$SIGNAL_SET $sig" ;;
      esac
    done
    SIGNAL_SET=$(printf '%s' "$SIGNAL_SET" | sed 's/^ *//; s/ *$//')
    SIGNAL_COUNT=0
    [ -n "$SIGNAL_SET" ] && SIGNAL_COUNT=$(printf '%s\n' "$SIGNAL_SET" | wc -w | tr -d ' ')

    if [ "$SIGNAL_COUNT" -gt 1 ]; then
      deny "MERGE GATE (ESCALATE_HUMAN): this command's repository selectors disagree — flag/prefix-assignment/PR-URL/environment GH_REPO name different repos ($SIGNAL_SET). This gate will not guess which one 'gh' will actually honor; a wrong guess here means authorizing a merge in a repo these artifacts say nothing about."
    elif [ "$SIGNAL_COUNT" -eq 1 ]; then
      EFFECTIVE_REPO="$SIGNAL_SET"
      if [ -n "$ORIGIN_SLUG" ] && [ "$EFFECTIVE_REPO" != "$ORIGIN_SLUG" ]; then
        deny "MERGE GATE (ESCALATE_HUMAN): this command merges a PR in '$EFFECTIVE_REPO', but it is running against a checkout of '$ORIGIN_SLUG'. The gate artifacts here (review verdict, verify ledger, security findings) describe '$ORIGIN_SLUG' and say NOTHING about '$EFFECTIVE_REPO', so it cannot evaluate this merge — and it will not judge one repo by another repo's verdict. Run the merge from inside a checkout of '$EFFECTIVE_REPO' so that repo's own gates apply."
      fi
    fi
  fi

  LEDGER="$QDIR/verify-ledger.jsonl"
  RV="$QDIR/review-verdict.json"
  SEC="$QDIR/security-findings.json"
  ESCALATION="$QDIR/ESCALATION"

  HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)

  # --- gh pr merge: pin every gate to the PR's HEAD COMMIT, not local HEAD ----
  #
  # THE BUG THIS FIXES (reproduced live 2026-08-07). Every gate below compares
  # its artifact's recorded sha against $HEAD_SHA under the assumption that
  # $HEAD_SHA IS the commit being merged. That holds for `push to main` and
  # `merge into main` — the local checkout literally becomes that commit. It is
  # FALSE for `gh pr merge`: the commit actually being merged is the PR's head
  # commit, but the local checkout is almost always sitting on main (wherever
  # `cd`/`git -C` last left it). A review verdict correctly pinned to the PR's
  # real head (11f84d2) was denied as "stale" solely because it was compared
  # against local main's tip (b7bf116) — nothing was actually stale, and the
  # operator's only escape was to check out the PR head by hand.
  #
  # Resolve the PR's real head commit from the PR itself and, for this vector
  # ONLY, use it as $HEAD_SHA for every gate below — including the diff-content
  # gates (the sensitive-surface preamble and GATE 5's ownership check), which
  # is why the fetch below exists: reading $CHANGED/$ADDED off $ROOT's local
  # `HEAD` was the SAME defect wearing a second hat. A sensitive PR merged with
  # no security review, and a clean PR was denied for touching a file it never
  # touched, because both gates were silently diffing local main's last commit
  # instead of the PR. Non-PR vectors (push to main, merge into main) are
  # untouched — local HEAD keeps governing them exactly as before, because for
  # THEM local HEAD genuinely is the commit being shipped.
  #
  # The BASE end of that diff matters just as much as the head end, and gets
  # the SAME treatment: also resolved from the PR (its baseRefOid — the base
  # branch's CURRENT tip on GitHub), not from $ROOT's local `main`/`master`
  # ref. A checkout that is behind origin is the routine case, not an edge
  # case — the cloud cuts the PR branch off current main while the laptop
  # hasn't pulled — and diffing against a stale local base OVER-reports: files
  # another team already merged to main show up as "changed by this PR" and
  # get denied as unowned, or scanned for sensitivity, when they were never
  # part of it.
  #
  # FAIL CLOSED: if either ref cannot be resolved or fetched (gh missing, PR
  # not found, not authenticated, network hiccup), DENY. A merge that cannot
  # be evaluated against its real content is never let through unevaluated.
  if [ "$merge_kind" = "gh pr merge" ]; then
    # PARSED_PR_ID and EFFECTIVE_REPO were already resolved above — the SAME
    # parse pass that decided the cross-repo refusal — and are reused here
    # rather than re-parsing $VECTOR_SEG a second time with separate logic.
    # Two independent regex passes over the same string disagreeing about
    # which repo/PR-id a command named is exactly the shape of bug this
    # unification closes.

    # One call, both refs — headRefOid AND baseRefOid — parsed locally with jq
    # rather than gh's own --jq, so a single captured payload answers both.
    if [ -n "$EFFECTIVE_REPO" ]; then
      if [ -n "$PARSED_PR_ID" ]; then
        PR_VIEW_JSON=$(cd "$ROOT" 2>/dev/null && gh pr view "$PARSED_PR_ID" --repo "$EFFECTIVE_REPO" --json headRefOid,baseRefOid 2>/dev/null)
      else
        PR_VIEW_JSON=$(cd "$ROOT" 2>/dev/null && gh pr view --repo "$EFFECTIVE_REPO" --json headRefOid,baseRefOid 2>/dev/null)
      fi
    else
      if [ -n "$PARSED_PR_ID" ]; then
        PR_VIEW_JSON=$(cd "$ROOT" 2>/dev/null && gh pr view "$PARSED_PR_ID" --json headRefOid,baseRefOid 2>/dev/null)
      else
        PR_VIEW_JSON=$(cd "$ROOT" 2>/dev/null && gh pr view --json headRefOid,baseRefOid 2>/dev/null)
      fi
    fi
    PR_HEAD_SHA=$(printf '%s' "${PR_VIEW_JSON:-}" | jq -r '.headRefOid // empty' 2>/dev/null)
    PR_BASE_SHA=$(printf '%s' "${PR_VIEW_JSON:-}" | jq -r '.baseRefOid // empty' 2>/dev/null)

    if [ -z "$PR_HEAD_SHA" ] || ! [[ "$PR_HEAD_SHA" =~ ^[0-9a-f]{7,40}$ ]]; then
      deny "MERGE GATE (ESCALATE_HUMAN): could not resolve the PR's head commit (\`gh pr view${PARSED_PR_ID:+ $PARSED_PR_ID}${EFFECTIVE_REPO:+ --repo $EFFECTIVE_REPO} --json headRefOid,baseRefOid\` failed or returned nothing usable). A merge must never be evaluated against the wrong commit, or left unevaluated — check that 'gh' is installed and authenticated and that the PR exists, then retry."
    fi
    if [ -z "$PR_BASE_SHA" ] || ! [[ "$PR_BASE_SHA" =~ ^[0-9a-f]{7,40}$ ]]; then
      deny "MERGE GATE (ESCALATE_HUMAN): resolved the PR's head commit but not its base (\`gh pr view${PARSED_PR_ID:+ $PARSED_PR_ID}${EFFECTIVE_REPO:+ --repo $EFFECTIVE_REPO} --json headRefOid,baseRefOid\` returned no usable baseRefOid). Without the PR's real base, the diff-based gates cannot tell what THIS PR changed versus what was already on main — do not guess by falling back to local HEAD."
    fi
    HEAD_SHA="$PR_HEAD_SHA"
    DIFF_BASE="$PR_BASE_SHA"

    # The diff-content gates below need the ACTUAL commit objects for both ends
    # of the range, not just their sha strings. The primary checkout may never
    # have fetched the PR branch (pushed from a worktree, or built entirely in
    # the cloud) — or may simply be BEHIND origin/main, which is the routine
    # case, not an edge case. Either way, `git diff` against a missing object
    # silently reads as "no changes", and diffing against a stale local base
    # over-reports files someone else already merged. Fetch whatever is
    # missing. FAIL CLOSED: an uninspectable diff must never be treated as
    # clean, or its ownership as violated, by omission — deny rather than
    # evaluate blind.
    #
    # The existence check runs BOTH before AND after the fetch: `git fetch`
    # exiting 0 is not, by itself, proof the object is now present (a wrapper,
    # a partial fetch, or an oddly-configured remote could exit clean without
    # it) — cat-file is what's actually trusted, both times.
    ensure_commit_fetched() {  # ensure_commit_fetched <sha> <label> -> denies on failure
      local sha="$1" label="$2"
      git -C "$ROOT" cat-file -e "${sha}^{commit}" 2>/dev/null && return 0
      if ! git -C "$ROOT" fetch --no-tags -q origin "$sha" 2>/dev/null; then
        deny "MERGE GATE (ESCALATE_HUMAN): resolved the PR's $label commit (${sha:0:12}) but could not fetch it into this checkout ('git fetch origin ${sha:0:12}' failed) — the diff-based gates (sensitive-surface detection, file-ownership) cannot inspect what is actually being merged without it, and evaluating them against local HEAD instead would silently describe the wrong commit. Fetch the PR branch into this checkout (e.g. 'git fetch origin pull/<n>/head') and retry."
      fi
      if ! git -C "$ROOT" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        deny "MERGE GATE (ESCALATE_HUMAN): 'git fetch origin ${sha:0:12}' exited 0 but the $label commit (${sha:0:12}) still is not present in this checkout — refusing to trust the fetch's exit code alone. Fetch the PR branch into this checkout manually and retry."
      fi
    }
    ensure_commit_fetched "$PR_HEAD_SHA" "head"
    ensure_commit_fetched "$PR_BASE_SHA" "base"
  fi

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
  #
  # WHERE THE PLAN COMES FROM. Both this file and .quetrex/state.json are
  # written by the CLOUD session, published onto the <prefix><TASK>-gates
  # branch alongside the verify ledger / review verdict / QA report / security
  # findings, and fetched into the operator's .quetrex/ by /quetrex:merge — the
  # same transport as every other artifact these gates read. Before that
  # transport existed the plan NEVER reached the operator's checkout, so this
  # flag and GATE 5's ownership map were structurally dead on the only
  # supported execution route. A unit that genuinely has no plan (TRIVIAL and
  # SIMPLE routes run without an architect) still lands here with PLAN="" and
  # is still skipped, not failed — see GATE 5's note.
  #
  # plan_is_foreign — is a plan artifact on disk PROVABLY about other work?
  #
  # A plan now being present locally is new, and it introduces a failure mode
  # that could not happen before: /quetrex:merge removes these files in its
  # cleanup step, but an aborted or interrupted merge leaves them behind, and
  # the NEXT merge in that checkout would then be judged against a previous
  # task's lanes — GATE 5 denying clean work for violating a contract it was
  # never party to, which is exactly the failure the multi-plan escalation
  # below exists to prevent.
  #
  # The binding is the plan's own `base_sha` — the approved base the dispatcher
  # stamped, from which the cloud cut the branch. The commit being merged
  # DESCENDS from it. If it provably does not, the plan describes a different
  # line of work.
  #
  # NARROW ON PURPOSE — only a PROVEN mismatch counts. A null/absent/malformed
  # base_sha (older plan schema, a local run the dispatcher never stamped), a
  # commit object this checkout does not have, or any git error all return
  # "not foreign" and leave behavior exactly as it was. Only `merge-base
  # --is-ancestor` answering a definite NO (exit 1) trips it.
  plan_is_foreign() {  # plan_is_foreign <plan-file> -> 0 when PROVABLY another task's
    local pf="$1" pbase rc
    [ -n "$pf" ] && [ -f "$pf" ] || return 1
    [ -n "$HEAD_SHA" ] || return 1
    pbase=$(jq -r '.base_sha // empty' "$pf" 2>/dev/null)
    [[ "$pbase" =~ ^[0-9a-f]{7,40}$ ]] || return 1
    git -C "$ROOT" cat-file -e "${pbase}^{commit}" 2>/dev/null || return 1
    git -C "$ROOT" cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null || return 1
    git -C "$ROOT" merge-base --is-ancestor "$pbase" "$HEAD_SHA" 2>/dev/null
    rc=$?
    [ "$rc" -eq 1 ] && return 0
    return 1
  }
  deny_if_plan_is_foreign() {  # deny_if_plan_is_foreign <plan-file>
    local pf="$1" pbase
    plan_is_foreign "$pf" || return 0
    pbase=$(jq -r '.base_sha // empty' "$pf" 2>/dev/null)
    deny "MERGE GATE (ESCALATE_HUMAN): $(basename "$pf") records base_sha ${pbase:0:12}, which is NOT an ancestor of the commit being merged (${HEAD_SHA:0:12}) — this plan describes a different unit of work, so its security flag and file-ownership map say nothing about this diff. The gate will not judge one task's merge by another task's contract. This is almost always a leftover from an interrupted /quetrex:merge: remove the stale plan from .quetrex/plan/ (and repair .quetrex/state.json) so the plan for THIS task governs, then retry."
  }

  PLAN=""
  TASK=$(jq -r '.task // empty' "$QDIR/state.json" 2>/dev/null)
  if [ -n "$TASK" ] && [ -f "$QDIR/plan/$TASK.json" ]; then
    PLAN="$QDIR/plan/$TASK.json"
  else
    # Fall back to any single plan file if state.json is unavailable.
    PLAN=$(ls -1 "$QDIR"/plan/*.json 2>/dev/null | head -n1)
  fi
  [ -n "$PLAN" ] && deny_if_plan_is_foreign "$PLAN"
  PLAN_SEC="false"
  [ -n "$PLAN" ] && PLAN_SEC=$(jq -r '.security_review_required // false' "$PLAN" 2>/dev/null)

  # --- (b) inspect the real diff for a sensitive surface ---------------------
  # Diff the commit actually being merged ($HEAD_SHA — the PR's head for a
  # `gh pr merge`, local HEAD for everything else; see above) against its real
  # base ($DIFF_BASE — the PR's own baseRefOid for a `gh pr merge`, resolved
  # above; local main/master for everything else). Three-dot range = what
  # $HEAD_SHA changed since it diverged from $DIFF_BASE. Deliberately NOT the
  # literal refs `HEAD`/`main`: for a `gh pr merge`, the local checkout is not
  # on the head commit, and local `main` can be BEHIND the PR's actual base —
  # diffing against a stale local base over-reports files someone else already
  # merged as "changed by this PR" (see the resolution block above).
  if [ -z "${DIFF_BASE:-}" ]; then
    DIFF_BASE="main"
    if ! git -C "$ROOT" rev-parse --verify --quiet main >/dev/null 2>&1; then
      git -C "$ROOT" rev-parse --verify --quiet master >/dev/null 2>&1 && DIFF_BASE="master"
    fi
  fi
  SENSITIVE_DIFF=0
  CHANGED=$(git -C "$ROOT" diff --name-only "$DIFF_BASE"..."$HEAD_SHA" 2>/dev/null)
  # Fall back to the last commit's files if the base range can't be computed.
  [ -z "$CHANGED" ] && CHANGED=$(git -C "$ROOT" diff --name-only "$HEAD_SHA"~1.."$HEAD_SHA" 2>/dev/null)
  SENSITIVE_PATH_RE='(auth|authz|authn|login|logout|signin|sign-in|session|oauth|openid|saml|sso|jwt|token|secret|credential|password|passwd|crypto|encrypt|decrypt|cipher|migration|migrate|schema|\.sql$|payment|billing|invoice|checkout|charge|stripe|paypal|permission|role|rbac|tenant|acl|middleware|guard|policy|webhook|\.github/workflows/|dockerfile|docker-compose|terraform|pulumi|kubernetes|k8s|helm)'
  if [ -n "$CHANGED" ] && printf '%s\n' "$CHANGED" | grep -qiE "$SENSITIVE_PATH_RE"; then
    SENSITIVE_DIFF=1
  fi
  # Also scan ADDED lines for sensitive code patterns even when the path is neutral
  # (data-access by client id, whole-body binding, injection sinks, env/secret use,
  # external calls). Only added (+) lines to avoid flagging deletions.
  if [ "$SENSITIVE_DIFF" -eq 0 ]; then
    ADDED=$(git -C "$ROOT" diff "$DIFF_BASE"..."$HEAD_SHA" 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+')
    [ -z "$ADDED" ] && ADDED=$(git -C "$ROOT" diff "$HEAD_SHA"~1.."$HEAD_SHA" 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+')
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

  # --- artifact_only_range_ok — the self-invalidation escape hatch ----------
  #
  # THE TRAP: every sha-pin this gate trusts (review-verdict.json's .sha,
  # security-findings.json's .head_sha, each verify-ledger.jsonl entry's
  # .sha) is an artifact NAMING the commit it approves. By design these are
  # runtime control-plane files and git-workflow.md instructs every stage to
  # NEVER commit them (.gitignore should ignore .quetrex/* and un-ignore
  # only project.json/verify.json). But when a repo's gitignore drifts from
  # that — observed in the wild — one of these DOES get committed. The
  # commit that adds it moves HEAD to a new sha; the artifact's own pin,
  # recorded before that commit existed, can now NEVER equal HEAD again. A
  # straight sha-equality check then denies every subsequent operation
  # forever, including the commit that would remove the artifact and repair
  # the mistake — the gate blocks its own repair.
  #
  # THE FIX IS NARROW ON PURPOSE: an old pin still authorizes the current
  # HEAD ONLY when nothing that could have invalidated the approval
  # happened since — i.e. $old is an ancestor of (or equal to) $new, AND
  # every commit in $old..$new touches NOTHING outside .quetrex/. A single
  # commit that touches so much as one file outside .quetrex/ anywhere in
  # that range disqualifies the WHOLE range: code changed, so the old
  # approval no longer describes what would ship, and the ordinary
  # stale-verdict/stale-ledger/stale-findings deny applies exactly as
  # before. This property must never weaken — it is the entire point of
  # the sha pin.
  #
  # FAIL-CLOSED on every unresolved condition: a missing commit object
  # (shallow clone, a sha this checkout never fetched), a merge-base
  # error, or a diff-tree that can't be read all `return 1` (not-ok)
  # rather than assume safety. Never let an error path open the gate.
  #
  # Correctness details that matter:
  #   - Path scope uses an ANCHORED case-glob (`.quetrex/*`), not a string
  #     prefix test, so `.quetrexfoo/x` and `src/.quetrex/x` do NOT count
  #     as in-scope — only the literal top-level `.quetrex/` directory
  #     does.
  #   - Merge commits are diffed with `-m` (one diff per parent) so a
  #     change that would otherwise vanish from a plain no-flags
  #     merge-commit diff (git only shows nothing for a merge by default)
  #     cannot hide a disqualifying path.
  #   - `--no-renames` so a rename is seen as its literal old+new paths
  #     rather than compressed to a single "new name only" line, which
  #     could hide a source path outside .quetrex/ that a rename moved OUT
  #     of scope.
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
  # else: either RV_SHA already equals HEAD, or every commit since RV_SHA
  # only touched .quetrex/ (e.g. committing review-verdict.json itself moved
  # HEAD without changing any reviewed code) — the verdict still describes
  # what would actually ship, so it stands.

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

  # --- WHICH CHAIN? the one the COMMIT BEING MERGED defines -------------------
  #
  # THE BUG THIS FIXES (reproduced live). This used to read `$QDIR/verify.json`
  # — the file in the operator's WORKING TREE, which during a `gh pr merge` is
  # the BASE branch's version, not the PR's. The cloud build ran the chain the
  # PR HEAD's verify.json defines and wrote ledger entries for THOSE commands.
  # So any PR that renames or replaces a verify command ("add a lint step",
  # "switch test runner", anything /quetrex:init would regenerate) was
  # PERMANENTLY unmergeable: the gate demanded a ledger entry for a command the
  # merged code no longer defines, the approved build was never supposed to
  # produce one, and the only way to update the local verify.json was to land
  # the PR the gate was blocking. The denial text even sent the operator into a
  # rebuild loop that could never clear it.
  #
  # verify-gate.sh already reads the COMMITTED blob at a pinned sha
  # (`git show "$HEAD_SHA:.quetrex/verify.json"`) for its requiredEnv map, for
  # exactly this class of reason. Reading the working tree here meant the two
  # gates disagreed about what the chain even IS. They no longer do.
  #
  # FALLBACK ORDER IS DELIBERATELY STRICTER-FIRST, NEVER LOOSER:
  #   1. the committed blob at the commit being merged — the authority;
  #   2. the working-tree file — used ONLY when (1) yields nothing, which is
  #      the genuinely-untracked-verify.json repo (no committed blob exists at
  #      ANY sha, so there is nothing stricter to read). A PR that DELETES a
  #      tracked verify.json therefore still faces the base's chain rather than
  #      de-gating itself by removing the file;
  #   3. no chain resolvable at all -> the conservative ledger-derived floor
  #      below.
  # MALFORMED LEDGER IS STILL FAIL-CLOSED. The previous implementation keyed an
  # object by `$e.cmd`, so an entry whose `cmd` was missing or non-string made
  # jq abort ("Cannot index object with null"), RED came back empty, and the
  # merge was denied. The evaluation below uses `select(.cmd == $c)` instead,
  # which would silently IGNORE such an entry — so the check jq used to perform
  # by crashing is made explicit here rather than lost. An unreadable ledger at
  # the ship boundary denies; it never quietly proves less than it looks like.
  if ! jq -se 'all(.[]; type == "object" and (.cmd | type) == "string")' "$LEDGER" >/dev/null 2>&1; then
    deny "MERGE GATE (ESCALATE_HUMAN): .quetrex/verify-ledger.jsonl is malformed — it is not JSON-lines of objects each carrying a string 'cmd'. The verify chain cannot be proven green from evidence that cannot be read, so the merge is denied. Surface to the user."
  fi

  CHAIN_JSON=""
  if [ -n "$HEAD_SHA" ] && [[ "$HEAD_SHA" =~ ^[0-9a-f]{7,40}$ ]]; then
    COMMITTED_VERIFY_JSON=$(git -C "$ROOT" show "$HEAD_SHA:.quetrex/verify.json" 2>/dev/null)
    if [ -n "$COMMITTED_VERIFY_JSON" ]; then
      CHAIN_JSON=$(printf '%s' "$COMMITTED_VERIFY_JSON" \
        | jq -c 'if (.verify | type) == "array" and (.verify | length) > 0 then .verify else empty end' 2>/dev/null)
    fi
  fi
  # --- LOWER BOUND: a PR may ADD requirements, never DELETE them -------------
  # Reading the chain from the merged commit alone let a PR de-gate ITSELF: shrink
  # its own .quetrex/verify.json and the removed command stops being required,
  # while every remaining command is green — so a measurably red suite reaches the
  # base branch with the gate satisfied. Reproduced: the pre-fix hook ALLOWS a
  # branch whose `npm test` exits 1 once `npm test` is dropped from verify[].
  #
  # This needs no adversary. /quetrex:init regenerating a shorter chain silently
  # de-gates the repo, which is the same silent-unarming class the audit found in
  # init's swallowed `git add`.
  #
  # So the effective chain is the UNION of the base's chain and the head's. Adding
  # a command still tightens the gate immediately; removing one cannot loosen it
  # within the PR that removes it. Renaming a command is therefore additive too —
  # the old name must still be proven for this commit, which is the conservative
  # reading at a ship boundary.
  if [ -n "$CHAIN_JSON" ]; then
    BASE_REF_FOR_CHAIN="${DIFF_BASE:-}"
    [ -n "$BASE_REF_FOR_CHAIN" ] || BASE_REF_FOR_CHAIN="$(git -C "$ROOT" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo main)"
    BASE_VERIFY_JSON=$(git -C "$ROOT" show "$BASE_REF_FOR_CHAIN:.quetrex/verify.json" 2>/dev/null)
    if [ -n "$BASE_VERIFY_JSON" ]; then
      BASE_CHAIN_JSON=$(printf '%s' "$BASE_VERIFY_JSON" \
        | jq -c 'if (.verify | type) == "array" and (.verify | length) > 0 then .verify else empty end' 2>/dev/null)
      if [ -n "$BASE_CHAIN_JSON" ]; then
        # --- ESCAPE HATCH: a chain EDIT the review-gate explicitly signed off ---
        # The union above makes a RENAME additive: the old command string must
        # still be proven green for the commit that replaces it. That is the
        # right call for a silent shrink, but it DEADLOCKS the legitimate case --
        # editing a command precisely BECAUSE it is broken. The old form can
        # never go green, so the fix to it can never merge. Reproduced live:
        # glori-evangelists #87, where the chain's pytest step could not pass
        # locally until it set DATABASE_URL, and the gate demanded the pre-fix
        # form be proven green at the very commit that fixed it.
        #
        # A base-only command is dropped from the requirement ONLY when
        # review-verdict.json names that exact command string AND pins the
        # acknowledgement to THIS head sha. /quetrex:init regenerating a shorter
        # chain, or an adversarial shrink, carries no such entry and is still
        # blocked -- de-gating now costs a reviewer naming the command, by hand,
        # at this commit. Subtraction applies to the BASE chain only: if head
        # still lists the command it stays required no matter what the verdict
        # claims.
        ACKED_DROPS='[]'
        if [ -f "$RV" ]; then
          _acked=$(jq -c --arg head "$HEAD_SHA" '
            if (.verify_chain_change.reviewed == true)
               and (.verify_chain_change.sha == $head)
               and ((.verify_chain_change.removed_commands | type) == "array")
            then (.verify_chain_change.removed_commands | map(select(type == "string")))
            else [] end' "$RV" 2>/dev/null)
          if [ -n "$_acked" ] && [ "$_acked" != "null" ]; then
            ACKED_DROPS="$_acked"
          fi
        fi
        MERGED_CHAIN=$(jq -cn --argjson a "$BASE_CHAIN_JSON" --argjson b "$CHAIN_JSON" --argjson d "$ACKED_DROPS" \
          '(($a - $d) + $b) | unique' 2>/dev/null)
        # Only widen. A jq failure must never silently shrink the chain.
        if [ -n "$MERGED_CHAIN" ] && [ "$MERGED_CHAIN" != "null" ]; then
          CHAIN_JSON="$MERGED_CHAIN"
        fi
      fi
    fi
  fi

  if [ -z "$CHAIN_JSON" ]; then
    CHAIN_JSON=$(jq -c 'if (.verify | type) == "array" and (.verify | length) > 0 then .verify else empty end' "$QDIR/verify.json" 2>/dev/null)
  fi

  if [ -z "$CHAIN_JSON" ]; then
    # No canonical chain resolvable at either source — fall back to: every
    # command that appears in the ledger must be proven green for the commit
    # being merged (conservative; a lingering red or an unproven command
    # blocks). Deriving the command set from the ledger keeps ONE evaluation
    # path below instead of a second, subtly-different copy of it.
    CHAIN_JSON=$(jq -sc '[ .[] | .cmd ] | unique' "$LEDGER" 2>/dev/null)
    if [ -z "$CHAIN_JSON" ] || [ "$CHAIN_JSON" = "null" ] || [ "$CHAIN_JSON" = "[]" ]; then
      # A non-empty ledger that yields no evaluable command at all is
      # unreadable evidence at the ship boundary -> fail closed.
      deny "MERGE GATE (ESCALATE_HUMAN): could not evaluate .quetrex/verify-ledger.jsonl (malformed JSONL, or no entry carries a command). The verify chain cannot be proven green, so the merge is denied. Surface to the user."
    fi
  fi

  # --- WHICH LEDGER LINES? the ones that describe the COMMIT BEING MERGED -----
  #
  # THE BUG THIS FIXES (reproduced live). This used to take the LAST entry per
  # command, full stop. verify-gate.sh is a Stop/SubagentStop hook with NO
  # fast-skip — every turn end runs the chain and APPENDS entries pinned to the
  # LOCAL checkout's HEAD. /quetrex:merge writes the transported cloud ledger in
  # step 2 and merges in step 4, so a single Stop firing in between appended a
  # green pinned to local main and SHADOWED every transported green. The merge
  # was then denied as STALE with a reason blaming the cloud build ("last green
  # was for commit X, not HEAD Y — re-run QA on the current commit") while the
  # real cause was the operator's own machine burying the evidence it had just
  # fetched. Non-deterministic, too: it depended on whether the agent's turn
  # happened to end between the fetch and the merge.
  #
  # The rule is now stated in terms of the commit, not of recency: for each
  # chain command, the gate looks at the LATEST entry that DESCRIBES THE COMMIT
  # BEING MERGED and requires it to be exit 0. An entry is "describing" when its
  # sha IS that commit, or when it is an older sha whose range to it is
  # artifact-only (the documented self-invalidation escape hatch — unchanged).
  # An entry pinned to any other commit is evidence about other code and neither
  # proves nor disproves this merge, so it is ignored rather than allowed to
  # shadow the real proof.
  #
  # NOTHING IS WEAKENED BY THIS. Absence of describing evidence is still a hard
  # STALE denial, a command absent from the ledger is still "never ran", and the
  # latest describing entry exiting non-zero is still red and is NOT rescued by
  # a later green pinned to some other commit. What changed is only that noise
  # about OTHER commits can no longer stand in for — or bury — the proof about
  # THIS one.
  #
  # jq emits, per chain command: `athead` (the last entry whose sha is exactly
  # the merged commit, or null) and `persha` (the last entry for each distinct
  # sha, most-recent-first) so bash can walk it against artifact_only_range_ok,
  # which is a shell function jq cannot call.
  RED=$(jq -sc --argjson chain "$CHAIN_JSON" --arg head "$HEAD_SHA" '
    . as $all
    | [ $chain[]
        | . as $c
        | ( [ $all[] | select(.cmd == $c) | {sha: (.sha // ""), rawexit: .exit, skipped: ((.skipped == true) and (.skipReason == "requiredEnv"))} ] ) as $raw
        # A DESCRIBING RED DOMINATES A LATER SKIP AT THE SAME SHA. `athead` takes the LAST
        # entry at $head, so mapping a skip to exit 0 before that selection let a skip appended
        # AFTER a genuine failure at the SAME commit erase it — a command that measurably
        # exited non-zero on the merged commit passed the gate. Reproduced with the real hooks:
        # red run, then the operator clears the env value, then one Stop firing appends the
        # skip. That is the same shape as the transported-evidence shadowing already documented
        # above, and it breaks the invariant this gate states about itself: a red for the merged
        # commit is never rescued. So: if a SKIP shares a sha with a genuine non-skipped
        # failure, that skip stays red no matter what follows it. A non-skipped entry is always
        # real evidence from an actual run — it is NEVER overridden by another shas history, or
        # this gate would deny every future genuine green for a command that failed even once
        # anywhere in the ledger (reproduced: red exit 1, then a genuine re-run at the SAME sha
        # exits 0 — that second run is real proof and must not be buried).
        | ( [ $raw[] | select((.skipped | not) and .rawexit != null and .rawexit != 0) | .sha ] | unique ) as $redshas
        | ( [ $raw[] | . as $e | {sha: $e.sha, exit: (if $e.skipped then (if ($redshas | index($e.sha)) then 1 else 0 end) else $e.rawexit end), skipped: $e.skipped} ] ) as $ent
        # ONLY A CLEAN SKIP AT $head DEFERS TO THE WALK. If any sha carries a genuine failure,
        # a CLEAN skip at $head (one whose own sha carries no failure, so $ent left its exit at
        # 0) cannot stand in as the describing answer — otherwise a red at an artifact-only-range
        # ANCESTOR (which GATE 3 treats as describing) is shadowed entirely and never reaches the
        # bash walk below that would consult it. Leaving $athead null hands the decision to that
        # walk, which owns the ancestor rule; it does NOT deny by itself. With no red anywhere, a
        # clean skip still answers directly. But a skip whose own sha DOES carry a failure was
        # already dominance-forced to exit 1 by $ent above — that is real, already-decided
        # evidence, and must never be nulled away: doing so discarded the ONLY trace of a red at
        # $head itself (reproduced: green at a describing ancestor, red at $head, then a skip
        # ALSO at $head — the null here threw the red away and the merge shipped it).
        | ( ( [ $ent[] | select(.sha == $head and $head != "") ] | last ) as $last
            | if ($last != null and $last.skipped and $last.exit == 0 and ($redshas | length) > 0) then null else $last end ) as $athead
        # THE WALKS OWN CANDIDATE LIST MUST HONOR THE SAME DEFERRAL — AND NO MORE. Nulling
        # $athead above sends the decision to the bash walk below, which picks the FIRST persha
        # candidate connected to $head by an artifact-only range and stops there. But $head
        # trivially satisfies that check against itself (an empty range is vacuously
        # artifact-only), so if $head own CLEAN skip entry were still in $persha, the walk would
        # immediately re-accept the very skip $athead just refused to trust — never reaching the
        # ancestor red that $athead-nulling exists to surface. So: whenever a genuine red exists
        # anywhere for this command, drop only CLEAN skip entries (skipped AND exit 0) from
        # $persha; a skip already dominance-forced to exit 1 IS the red evidence for its sha (not
        # a mask over it) and dropping it too would erase that sha from $persha entirely, hiding
        # a genuine failure behind a stale, unrelated, older describing green — the same defect
        # one level removed, for any sha, not only $head.
        | ( ( reduce ($ent | reverse)[] as $e ({};
              if has($e.sha) then . else .[$e.sha] = $e end) | [ .[] ] )
            | if ($redshas | length) > 0 then [ .[] | select((.skipped | not) or .exit != 0) ] else . end ) as $persha
        | { cmd: $c, athead: $athead, persha: $persha }
        | select(.athead == null or .athead.exit != 0) ]
  ' "$LEDGER" 2>/dev/null)

  if [ -z "$RED" ] || [ "$RED" = "null" ]; then
    # jq failed to evaluate the ledger at the ship boundary -> fail closed.
    deny "MERGE GATE (ESCALATE_HUMAN): could not evaluate .quetrex/verify-ledger.jsonl (malformed JSONL?). The verify chain cannot be proven green, so the merge is denied. Surface to the user."
  fi

  # A candidate above either has a RED entry for the merged commit itself (never
  # rescued — `why=exit`), or has NO entry for it at all, in which case the only
  # thing that can still authorize it is an older, artifact-only-range green
  # (`artifact_only_range_ok`). The per-sha list is walked most-recent-first and
  # the FIRST describing sha decides: a describing red is not skipped over in
  # search of an older describing green.
  if [ "$RED" != "[]" ]; then
    STILL_RED="[]"
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      e_cmd=$(printf '%s' "$entry" | jq -r '.cmd')
      e_athead=$(printf '%s' "$entry" | jq -r 'if .athead == null then "" else (.athead.exit | tostring) end')
      genuinely_red=1
      why="stale"
      red_exit="null"
      red_sha=$(printf '%s' "$entry" | jq -r '(.persha[0].sha // "")')
      if [ -n "$e_athead" ]; then
        # Evidence for the merged commit exists and is non-zero: red, full stop.
        why="exit"; red_exit="$e_athead"; red_sha="$HEAD_SHA"
      elif [ "$(printf '%s' "$entry" | jq -r '.persha | length')" = "0" ]; then
        why="never"
      else
        while IFS= read -r cand; do
          [ -z "$cand" ] && continue
          c_sha=$(printf '%s' "$cand" | jq -r '.sha // empty')
          c_exit=$(printf '%s' "$cand" | jq -r '.exit')
          [ -n "$c_sha" ] || continue
          [ -n "$HEAD_SHA" ] || continue
          artifact_only_range_ok "$c_sha" "$HEAD_SHA" || continue
          # This entry DOES describe the merged commit (artifact-only range).
          if [ "$c_exit" = "0" ]; then
            genuinely_red=0
          else
            why="exit"; red_exit="$c_exit"; red_sha="$c_sha"
          fi
          break
        done < <(printf '%s' "$entry" | jq -c '.persha[]' 2>/dev/null)
      fi
      if [ "$genuinely_red" -eq 1 ]; then
        STILL_RED=$(printf '%s' "$STILL_RED" | jq -c \
          --arg cmd "$e_cmd" --arg why "$why" --arg sha "$red_sha" --argjson ex "$red_exit" \
          '. + [{cmd:$cmd, why:$why, sha:$sha, exit:$ex}]' 2>/dev/null)
        [ -n "$STILL_RED" ] || STILL_RED="[]"
      fi
    done < <(printf '%s' "$RED" | jq -c '.[]' 2>/dev/null)
    RED="$STILL_RED"
  fi

  if [ "$RED" != "[]" ]; then
    # The "stale" branch's `.sha` is whatever ledger entry happened to be most recent for that
    # command — it is NOT necessarily a green run (it could be an unconnected red, or a clean
    # skip for an unrelated commit): "stale" only ever means no recorded entry, of ANY kind,
    # connects to HEAD by an artifact-only range. Saying "last green" here asserted a fact this
    # branch never checked; the honest claim is only that nothing on record describes HEAD.
    SUMMARY=$(printf '%s' "$RED" | jq -r --arg head "$HEAD_SHA" 'map("  - `\(.cmd)` -> \(if .why == "never" then "never ran (no ledger entry)" elif .why == "exit" then "exit \(.exit)" else "STALE: no recorded result for commit \($head[0:12]) or an artifact-only-range ancestor of it (nearest evidence: commit \((.sha // "?")[0:12])) — re-run QA on the current commit" end)") | join("\n")' 2>/dev/null)
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

  # Same binding as the PREAMBLE applies here: a plan whose approved base is
  # provably not an ancestor of the commit being merged is another task's
  # contract, and checking this diff against its lanes would reject clean work.
  # Re-asserted rather than assumed, because GATE 5 can select a DIFFERENT file
  # than the preamble did (it refuses the loose `ls | head -n1` fallback).
  [ -n "$PLAN5" ] && deny_if_plan_is_foreign "$PLAN5"

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
  # THIS VECTOR'S GATES ARE ALL GREEN — return to the caller, not exit.
  # ===========================================================================
  # Emitting no JSON here means "no decision on THIS vector" -- but the hook's
  # ultimate decision isn't made until every collected vector has been run
  # through evaluate_vector (see the loop below). Returning, not exiting, is
  # what lets a compound command naming two merges have BOTH independently
  # judged: a clean first vector must not prevent the second from being
  # evaluated at all. `deny()` above still exits the whole hook immediately —
  # unchanged — the moment ANY vector fails ANY gate.
  return 0
}

# --- evaluate every collected vector; deny() inside exits on the first -----
# failure. Reaching the end of this loop means every vector this command
# names passed every gate -- only THEN does the whole hook allow (emit
# nothing, exit 0).
vi=0
vn=${#VECTOR_KINDS[@]}
while [ "$vi" -lt "$vn" ]; do
  evaluate_vector "${VECTOR_KINDS[$vi]}" "${VECTOR_SEGS[$vi]}" "${VECTOR_GH_REPO_PREFIXES[$vi]}" "${VECTOR_PENDING_CDS[$vi]}"
  vi=$((vi + 1))
done

exit 0
