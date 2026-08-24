#!/usr/bin/env bash
# verify-gate-quick-chain.sh — sourced-only helper for .claude/hooks/verify-gate.sh.
#
# WHY A SEPARATE FILE (2026-08-21, HOOKFIX, structural AC10 fix): the bounded
# quick-chain machinery (declarative env-skip eligibility + the heavy-command
# filter + the quick-chain wall-clock cap) is a cohesive, self-contained unit
# — every function here is a pure function of $ROOT/$HEAD_SHA/env plus the
# arguments verify-gate.sh passes in, with no dependency on anything defined
# LATER in that file (LOG, LEDGER, the run loop). Extracting it keeps
# verify-gate.sh itself under the size-regression guard (AC10 /
# test/verify-gate.test.sh) without cutting the fail-closed rationale
# comments that guard exists to protect. UNLIKE merge-gate.sh's tokenizer
# (which protected-files-guard.sh COPIES rather than sources — see that
# file's header), verify-gate.sh has no load-time execution that a second
# file could break: it never computes anything at `source` time, so sourcing
# this file costs nothing structurally.
#
# NOT SELF-EXECUTING. This file defines functions only and must be SOURCED,
# never invoked directly — `set -uo pipefail` is inherited from the caller,
# nothing here runs until verify-gate.sh calls a function.
#
# CROSS-REPO PUBLISH (same class as verify-gate.sh's own note): this file
# must ship ALONGSIDE verify-gate.sh in the published quetrex-factory copy
# (plugins/quetrex-factory/scripts/), or the published verify-gate.sh's
# `source "$(dirname ...)/verify-gate-quick-chain.sh"` fails at runtime. That
# republish is a cross-repo follow-up outside this workstream's file
# ownership — see the developer's report.

# --- qx_apply_quick_cap: narrow BUDGET_TOTAL on the QUICK path only --------
# Reads/writes globals: QUICK (in), BUDGET_TOTAL (in/out), QUETREX_VERIFY_QUICK_CAP (env).
# Own var, never overloaded into BUDGET_DEFAULT (fixed-regex parsed by
# verify-gate-timeout-margin.test.sh). This is the STRUCTURAL bound — see the
# AMENDMENT note in verify-gate.sh's own header.
qx_apply_quick_cap() {
  QUICK_CAP_DEFAULT=90
  QUICK_CAP="${QUETREX_VERIFY_QUICK_CAP:-$QUICK_CAP_DEFAULT}"
  case "$QUICK_CAP" in ''|*[!0-9]*) QUICK_CAP="$QUICK_CAP_DEFAULT" ;; esac
  [ "$QUICK_CAP" -gt 0 ] 2>/dev/null || QUICK_CAP="$QUICK_CAP_DEFAULT"
  [ "$QUICK" -eq 1 ] && [ "$QUICK_CAP" -lt "$BUDGET_TOTAL" ] && BUDGET_TOTAL="$QUICK_CAP"
  return 0
}

# --- DECLARATIVE ENV SKIP (fix part c) --------------------------------------
# Moved ABOVE the heavy filter in the caller's invocation order: a missing-env
# skip must be RECORDED by the run loop, never silently dropped by the
# filter. Pre-flight only — NEVER inferred from a command's output. Returns 0
# (skip) and sets MISSING_ENV_VAR when `cmd` has a requiredEnv entry in
# verify.json and every constraint below is satisfied; returns 1 (run it)
# otherwise, which is the fail-closed default for anything ambiguous.
#
# DECLARATIVE ENV SKIP, full contract (unabridged, matches verify-gate.sh's
# own former inline copy byte-for-byte): a command whose verify.json
# `requiredEnv` entry names a variable that is genuinely unavailable in THIS
# checkout is never executed — skipped pre-flight, never inferred from output
# (that would be env-error laundering). The ENTIRE requiredEnv mapping (and
# the verify[] membership check) is read from the COMMITTED .quetrex/verify.json
# blob at the ONE sha this invocation pinned up front ($HEAD_SHA) — NEVER the
# working-tree file, NEVER a fresh `HEAD` re-resolved mid-run (SEC-2), so a
# command that commits mid-chain cannot author the authorization for a LATER
# command in the SAME run. A skip fires ONLY when ALL of:
#   1. `cmd` is byte-for-byte a member of the COMMITTED verify[] ARRAY
#      (type-asserted — a STRING `.verify` degrades jq's index() to a
#      SUBSTRING search, which would let a merely-containing command pass);
#   2. the variable name appears as a NAME= key in the COMMITTED blob of a
#      tracked $ROOT/.env.example or $ROOT/.env.sample at HEAD (a reviewed
#      diff must show the declaration; an uncommitted edit to the declaring
#      line does not count);
#   3. the variable is unset-or-empty in the hook's own environment AND is
#      not a key in $ROOT/.env, .env.local, .env.development, .env.test that
#      exist in this checkout (their presence means the command would have
#      had the value).
# If the committed verify.json cannot be read at all, NOTHING is treated as
# declared and no command is ever skipped.
MISSING_ENV_VAR=""
should_skip_for_env() {
  local cmd="$1"
  MISSING_ENV_VAR=""
  command -v jq >/dev/null 2>&1 || return 1
  # EMPTY-HEAD TRAP (SEC-2): empty $HEAD_SHA would degrade the show below to
  # `git show ":path"` (reads the INDEX, fail-OPEN). Return before any show.
  [ -n "$HEAD_SHA" ] || return 1
  local committed_verify_json
  committed_verify_json=$(git -C "$ROOT" show "$HEAD_SHA:.quetrex/verify.json" 2>/dev/null) || return 1
  [ -n "$committed_verify_json" ] || return 1
  printf '%s' "$committed_verify_json" | jq -e --arg c "$cmd" \
    '(.verify // []) as $v | ($v | type) == "array" and (($v | index($c)) != null)' \
    >/dev/null 2>&1 || return 1
  local vars
  vars=$(printf '%s' "$committed_verify_json" | jq -r --arg c "$cmd" '
      if (.requiredEnv // {}) | type == "object"
      then (.requiredEnv[$c] // []) | if type == "array" then .[] else empty end
      else empty end
    ' 2>/dev/null)
  [ -n "$vars" ] || return 1
  local v declared exfile committed
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    # Only well-formed shell identifiers are safe to look up.
    case "$v" in
      [A-Za-z_]*) : ;;
      *) continue ;;
    esac
    case "$v" in *[!A-Za-z0-9_]*) continue ;; esac
    declared=0
    for exfile in .env.example .env.sample; do
      committed=$(git -C "$ROOT" show "$HEAD_SHA:$exfile" 2>/dev/null) || continue
      if printf '%s\n' "$committed" | grep -qE "^${v}="; then
        declared=1
        break
      fi
    done
    [ "$declared" -eq 1 ] || continue
    local val="${!v-}"
    [ -z "$val" ] || continue
    local envfile skip_this=0
    for envfile in "$ROOT/.env" "$ROOT/.env.local" "$ROOT/.env.development" "$ROOT/.env.test"; do
      if [ -f "$envfile" ] && grep -qE "^${v}=" "$envfile" 2>/dev/null; then
        skip_this=1
        break
      fi
    done
    [ "$skip_this" -eq 0 ] || continue
    MISSING_ENV_VAR="$v"
    return 0
  done <<EOF
$vars
EOF
  return 1
}

# =============================================================================
# >>> QX-SEGSPLIT BEGIN — copied verbatim from .claude/hooks/merge-gate.sh
# (split_segments_quote_aware, normalize_segment), the SAME functions
# protected-files-guard.sh already copies from the same source. Needed here
# to find the ACTUAL COMMAND TOKEN of each segment of a (possibly compound)
# verify[] command — see qx_is_heavy_segment below for why a whole-string
# regex was replaced (2026-08-21, operator-directed correction: substring
# matching flagged `echo BUILD_MARKER` as heavy and matched a TMPDIR PATH
# fragment, silently dropping genuinely cheap commands and their block
# coverage — the exact failure mode the cap, not the matcher, is supposed to
# own). Not sourced (merge-gate.sh executes at load); copied and drift-pinned
# the same way protected-files-guard.sh's copy is (byte-identity, by
# function-name boundary — see that file's AC16 for the pattern; this copy
# does not yet have its own mechanical pin, which is a disclosed gap, not an
# oversight — see the developer's report).
# =============================================================================
split_segments_quote_aware() {
  # Two `local` statements, same reason as tokenize_argv below: word
  # expansion for the WHOLE `local` command happens before the builtin
  # runs, against the enclosing scope's state -- `n=${#s}` on the same
  # line as `s="$1"` would see `s` as unset under `set -u`.
  local s="$1"
  local i=0 n=${#s} c two nc out='' in_sq=0 in_dq=0 in_cm=0 have=0 gt=0
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    if [ "$in_cm" -eq 1 ]; then
      out+="$c"; gt=0
      if [ "$c" = $'\n' ]; then in_cm=0; have=0; fi
    elif [ "$in_sq" -eq 1 ]; then
      out+="$c"; have=1; gt=0
      [ "$c" = "'" ] && in_sq=0
    elif [ "$in_dq" -eq 1 ]; then
      out+="$c"; have=1; gt=0
      if [ "$c" = '\' ] && [ $((i + 1)) -lt "$n" ]; then
        i=$((i + 1)); out+="${s:$i:1}"; gt=0
      elif [ "$c" = '"' ]; then
        in_dq=0
      fi
    else
      case "$c" in
        ' ' | $'\t')
          out+="$c"; have=0; gt=0
          ;;
        $'\n')
          out+="$c"; have=0; gt=0
          ;;
        "'") in_sq=1; out+="$c"; have=1; gt=0 ;;
        '"') in_dq=1; out+="$c"; have=1; gt=0 ;;
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
          out+="$c"; have=1; gt=0
          ;;
        '\')
          # SEC-17 (security review, 2026-08-21): an escaped character is
          # emitted VERBATIM here, so `a\>` leaves a literal '>' as the
          # LAST EMITTED character -- indistinguishable, by inspecting
          # `out` alone, from a real unescaped redirect operator. This is
          # exactly the trap the '#' branch's own comment above already
          # warns about ("could not tell an escaped separator from a real
          # one"). `gt` is explicitly cleared on every path through this
          # branch (never inferred from the emitted bytes), so the
          # '&'|'|' branch below never mistakes an escaped '>' for a real
          # one and never wrongly glues away a REAL following pipe.
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
          gt=0
          ;;
        '&' | '|')
          # SEC-13/SEC-17 (security review, 2026-08-21): '>|' is bash own
          # noclobber-override redirect operator, not a pipe -- without
          # this a bare unquoted '|' immediately after a genuine '>' was
          # always read as a pipe/segment separator, splitting
          # "cat x >| protected-path" into two unrelated segments and
          # losing the redirect target entirely. Glue it onto the
          # preceding '>' instead, exactly like '>>' already reaches
          # normalize_segment as one token -- gated on the `gt` flag (set
          # ONLY in the default `*)` branch below when a raw, unescaped,
          # unquoted '>' is emitted; cleared on every other path,
          # including the escape branch above), NEVER by inspecting the
          # last emitted character. SEC-17: `${out: -1}` cannot
          # distinguish `a\>|cmd` (an ESCAPED '>' followed by a REAL pipe)
          # from a genuine `>|` operator, and wrongly glued the real pipe
          # away -- hiding an entire second command from every downstream
          # segment-based scanner (merge-gate GATE 1-4, the floor-script
          # guard) at both DENY sites.
          if [ "$c" = '|' ] && [ "$gt" -eq 1 ]; then
            out+="$c"; have=1; gt=0
          else
            two="${s:$i:2}"
            if [ "$two" = "&&" ] || [ "$two" = "||" ]; then
              out+=$'\n'
              i=$((i + 1))
            else
              out+=$'\n'
            fi
            have=0; gt=0
          fi
          ;;
        ';')
          out+=$'\n'
          have=0; gt=0
          ;;
        *)
          out+="$c"; have=1
          if [ "$c" = '>' ]; then gt=1; else gt=0; fi
          ;;
      esac
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

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
# =============================================================================
# <<< QX-SEGSPLIT END
# =============================================================================

# --- qx_is_heavy_segment: PRECISE, structured command-token matching -------
# (CORRECTED 2026-08-21, operator-directed — replaces a whole-command-string
# substring regex that matched `echo BUILD_MARKER` as heavy and matched a
# TMPDIR PATH fragment ("...-test.XXXXXX") as heavy, silently dropping
# genuinely cheap commands and their block coverage). Anchors on the actual
# command TOKEN — the first word of the (wrapper-stripped) segment, and at
# most the next two words — and ignores every path and argument entirely. A
# MISSED heavy command is harmless (the wall-clock cap, not this matcher, is
# the safety property); a FALSE heavy match is not — it silently drops a
# cheap command's block coverage — so this is intentionally NARROW. Simple
# whitespace tokenization (not full argv quoting) is sufficient and correct
# here: the command verb / subcommand / script name this function inspects
# is never meaningfully quoted in practice; only later arguments are, and
# those are ignored by design ("ignore paths and arguments entirely").
qx_is_heavy_segment() {
  local seg="$1"
  local -a w
  read -ra w <<< "$seg"
  [ "${#w[@]}" -ge 1 ] || return 1
  local bin="${w[0]##*/}"
  # npx wraps a real binary invocation by name; unwrap exactly one level.
  if [ "$bin" = "npx" ] && [ "${#w[@]}" -ge 2 ]; then
    w=("${w[@]:1}")
    bin="${w[0]##*/}"
  fi
  case "$bin" in
    npm|yarn|pnpm|bun)
      case "${w[1]:-}" in
        run)
          case "${w[2]:-}" in
            test|build|e2e|test:*|build:*) return 0 ;;
          esac
          ;;
        test) return 0 ;;   # the well-known bare shorthand ("npm test" et al)
      esac
      return 1
      ;;
    pytest|vitest|jest|cypress) return 0 ;;
    playwright)
      [ "${w[1]:-}" = "test" ] && return 0
      return 1
      ;;
    cargo|go)
      case "${w[1]:-}" in test|build) return 0 ;; esac
      return 1
      ;;
    mvn|gradle)
      [ "${w[1]:-}" = "test" ] && return 0
      return 1
      ;;
  esac
  return 1
}

# qx_is_heavy_command <full-command-string> -- splits on shell operators
# (&&/||/;/|), strips wrapper prefixes from EACH segment, and returns 0
# (heavy) if ANY segment matches a heavy shape. A compound command ("cd app
# && npm test") is heavy if any part of it is.
qx_is_heavy_command() {
  local cmd="$1" seg norm
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    normalize_segment "$seg"
    norm="$NORM_RESULT"
    [ -z "$norm" ] && continue
    qx_is_heavy_segment "$norm" && return 0
  done <<< "$(split_segments_quote_aware "$cmd")"
  return 1
}

# --- qx_write_bounded_skip: SEC-1/SEC-3 FIX (2026-08-21, security review) --
# THE DEFECT THIS CLOSES. The bounded quick chain used to leave commands it
# excluded (heavy-filtered, or cut by the cap) with NO ledger line at all.
# That shrinks the ledger, and the ledger is merge-gate.sh's evidence, which
# broke its compensating control in BOTH directions:
#   SEC-1 (repos with NO verify.json): merge-gate.sh derives the required
#   chain FROM the ledger when no verify.json resolves. A Stop whose ledger
#   is missing the one command that would have failed let GATE 3 pass on a
#   genuinely red suite -- a red suite could SHIP.
#   SEC-3 (repos WITH verify.json): the mirror image -- a heavy command's
#   ledger evidence vanishing forever meant GATE 3 could never find a
#   describing entry for it, denying every future merge permanently. The
#   compensating control became a wall.
# THE FIX: the ledger must describe the WHOLE resolved chain, always. Every
# command that is excluded from actually running (heavy-filtered, or never
# reached because the cap expired) gets EXACTLY ONE skipped:true line with a
# DISTINCT skipReason ("boundedQuick", never "requiredEnv" -- the two must
# stay separately recognizable) and exit:null. A boundedQuick line is never
# proof of anything -- merge-gate.sh (out of this file's ownership; tracked
# as a required follow-up in the developer's report) is what must (a) treat
# it as unproven, exactly like "never ran", (b) never let it shadow or
# outrank a genuine executed entry for the same command at the same sha, and
# (c) stop deriving a REQUIRED chain from bounded Stop lines at :1647.
qx_write_bounded_skip() {
  local cmd="$1"
  [ -n "${LEDGER:-}" ] && [ -n "${HEAD_SHA:-}" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -cn \
    --arg ts "$ts" --arg cmd "$cmd" --arg cwd "${ROOT:-}" --arg sha "$HEAD_SHA" \
    '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:null,skipped:true,skipReason:"boundedQuick",tail:"SKIPPED: excluded by the bounded quick chain (heavy filter or wall-clock cap) — never proven, never a pass"}' \
    >> "$LEDGER" 2>/dev/null
  return 0
}

# qx_write_bounded_skips_for_cap <start-idx> -- writes a boundedQuick line
# for CHAIN[start-idx..end], the commands a CAP_HIT excluded.
#
# SEC-15 / SEC-19 (security review, 2026-08-21): an earlier version of this
# function tried to make the ledger's LAST line a genuine result whenever
# one exists in this run, by reading the ledger's current byte size,
# truncating it, writing these boundedQuick lines, then re-appending the
# captured tail. SEC-19 (CONFIRMED, security review) correctly rejected
# that: a read-modify-write against a file other processes also append to
# (parallel subagents sharing one worktree ARE a real writer, not a
# theoretical one) can lose a concurrently-appended line between the byte
# count and the `mv`, and the truncate-then-rewrite itself breaks the
# append-only invariant merge-gate.sh's own reasoning depends on.
#
# THE FIX (operator directive): restore STRICT append-only. Every ledger
# write in this file is a plain `>>` of one complete line, full stop -- no
# read, no truncate, no temp file. This function is back to exactly what
# qx_write_bounded_skip already does in a loop. The residual SEC-15
# ordering concern (a boundedQuick line for the CUT command can still land
# after an earlier genuine line from the SAME run, so the ledger's tail is
# not always the genuine result) is DOWNGRADED to LOW and left OPEN by the
# operator's explicit call: correct ordering is not worth reintroducing a
# read-modify-write on the ledger. The heavy-filter path above stays
# "accidentally correct" because ITS exclusions are known statically before
# the run loop starts, with nothing yet written this run to reorder around
# -- a structural property a wall-clock CAP_HIT (only known dynamically,
# mid-loop, after earlier commands have already genuinely run) cannot
# reproduce without the read-modify-write this fix removes.
qx_write_bounded_skips_for_cap() {
  local start_idx="$1" i
  for ((i = start_idx; i < ${#CHAIN[@]}; i++)); do
    qx_write_bounded_skip "${CHAIN[$i]}"
  done
  return 0
}

# --- qx_filter_heavy_chain: the heavy-command filter (CORRECTED 2026-08-21) -
# QUICK path only, declared verifyQuick included — a declared chain is not
# exempt. A requiredEnv-skip-eligible command is never excluded (kept so the
# run loop records its skip); if filtering would leave the CHAIN array EMPTY,
# the caller's array is left UNTOUCHED (the ORIGINAL selected chain still
# runs, under the cap) — never "filter to empty, run nothing". The matcher
# is an optimization; the cap is the safety property. Reads/writes the
# global array CHAIN in place; no new customer-controlled input.
#
# SEC-1/SEC-3: every command EXCLUDED here (heavy, not skip-eligible) gets a
# qx_write_bounded_skip ledger line -- but ONLY when the filtered result is
# actually used (non-empty). When the empty-result fallback fires instead,
# NOTHING was excluded (the caller's CHAIN is left untouched and every
# command will be genuinely attempted, or get its own boundedQuick line from
# the run loop if the cap cuts it there) -- recording exclusions that never
# actually happened would be its own false evidence.
qx_filter_heavy_chain() {
  [ "$QUICK" -eq 1 ] || return 0
  local _c
  local -a filtered=() excluded=()
  for _c in "${CHAIN[@]}"; do
    if should_skip_for_env "$_c" || ! qx_is_heavy_command "$_c"; then
      filtered+=("$_c")
    else
      excluded+=("$_c")
    fi
  done
  if [ "${#filtered[@]}" -gt 0 ]; then
    CHAIN=("${filtered[@]}")
    for _c in ${excluded[@]+"${excluded[@]}"}; do
      qx_write_bounded_skip "$_c"
    done
  fi
  return 0
}
