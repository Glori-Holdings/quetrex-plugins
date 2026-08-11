#!/usr/bin/env bash
# secret-scan.sh — PreToolUse secret gate.
#
# Registered on BOTH Write|Edit AND Bash:
#   - Write / Edit: scans .tool_input.content (Write) and .tool_input.new_string
#     (Edit) — the file body being written.
#   - Bash:         scans .tool_input.command — this closes the audited gap where
#     a secret is written via a redirect / heredoc (e.g. `cat > .env <<EOF ...`)
#     bypassing the Write/Edit matcher entirely.
#
# HOOK CONTRACT (course L5): PreToolUse decides by printing
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":...}}
# on stdout and exiting 0. That runs BENEATH the permission engine, so it fires
# even under dontAsk / bypassPermissions / --dangerously-skip-permissions.
# Exit 2 = blocking error whose stderr is handed back. Exit 1 does NOT block.
#
# Detection has two tiers:
#   (A) PROVIDER-PREFIX regexes — unambiguous, fire unconditionally.
#   (B) HIGH-ENTROPY heuristic — a long base64/hex blob assigned to a
#       secret-looking key. Scoped to an assignment context with a secret
#       keyword so ordinary hashes / lockfile digests / git SHAs do NOT trip it
#       (false positives erode trust in the gate).
# Plus (C) SECRET EGRESS — a secret FILE PATH referenced in the same command as
#       an egress verb. The secret never appears in the command string there
#       (`curl -d @$HOME/.claude/secrets.env`), so neither tier can see it.
#
# WHAT EACH HIT DOES (finding #29 — updatedInput redaction):
#   Tier A on Bash     -> REWRITE the command with the secret replaced by a
#                         placeholder and return `updatedInput`, so the work
#                         still happens and the command fails at the remote with
#                         a clear auth error instead of the agent thrashing
#                         against a refusal it cannot diagnose. The rewrite is
#                         NEVER silent: the masked hit is stated in
#                         permissionDecisionReason. Three constraints, all load
#                         bearing:
#                           (a) updatedInput REPLACES the whole input object, so
#                               it is built as `.tool_input | .command = $red` —
#                               every other field is echoed back untouched;
#                           (b) EVERY match is substituted, not just the first —
#                               a `head -n1` rewrite leaks the second secret;
#                           (c) a redaction that cannot be built safely (no jq)
#                               degrades to deny, never to allow.
#   Tier A on Write|Edit -> DENY. A silently placeholdered key written into
#                         source produces a file the agent believes holds a
#                         working credential — worse than a refusal.
#   Tier B anywhere    -> DENY. It is heuristic and false-positive-prone by
#                         design; it must never rewrite a value it guessed at.
#   Egress (Bash)      -> ASK. Legitimate `.env` reads are common, so this is
#                         not a deny. Under the product's `dontAsk` profile an
#                         `ask` is auto-denied without prompting, so an
#                         unattended pipeline is never left hanging on it.
#
# FAIL-CLOSED INPUT HANDLING (finding #9): the old form was
#   CONTENT=$(jq -r ... 2>/dev/null); [ -z "$CONTENT" ] && exit 0
# so a missing or erroring jq silently disabled the gate. Now jq is preferred,
# merge-gate.sh's jq-free `sed` extraction is the fallback, and a payload that
# carries content but cannot be parsed exits 2 with a message on stderr.
set -o pipefail

input=""
if [ ! -t 0 ]; then input=$(cat); fi
[ -z "$input" ] && exit 0

JQ_OK=0
if command -v jq >/dev/null 2>&1 && printf '%s' "$input" | jq . >/dev/null 2>&1; then
  JQ_OK=1
fi

TOOL_NAME=""
CONTENT=""
if [ "$JQ_OK" -eq 1 ]; then
  TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
  case "$TOOL_NAME" in
    Write) CONTENT=$(printf '%s' "$input" | jq -r '.tool_input.content // empty' 2>/dev/null) ;;
    Edit)  CONTENT=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty' 2>/dev/null) ;;
    Bash)  CONTENT=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) ;;
    *)     CONTENT=$(printf '%s' "$input" | jq -r '(.tool_input.content // .tool_input.new_string // .tool_input.command // empty)' 2>/dev/null) ;;
  esac
  # jq parsed the payload: empty really means "nothing to scan" (e.g. writing an
  # empty file), not a parse failure.
  [ -z "$CONTENT" ] && exit 0
else
  # jq missing or the payload is not valid JSON — best-effort jq-free extraction
  # (merge-gate.sh:70-75), then FAIL CLOSED if the payload plainly carries a
  # field we were supposed to scan.
  TOOL_NAME=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  for k in command content new_string; do
    CONTENT=$(printf '%s' "$input" | tr -d '\n' | sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\\(.*\\)\".*/\\1/p")
    [ -n "$CONTENT" ] && break
  done
  if [ -z "$CONTENT" ]; then
    if printf '%s' "$input" | grep -qE '"(command|content|new_string)"'; then
      echo "secret-scan: could not parse this tool call (jq unavailable or malformed hook JSON), so the secret gate cannot inspect what is about to be written or executed. Refusing to run it unchecked. Install jq, then retry." >&2
      exit 2
    fi
    exit 0
  fi
fi

# Mask a token for safe display: keep a 4-char prefix, hide the rest.
# Built from literals only — no `tr`/`cut` over a multibyte character, which
# emits invalid UTF-8 under a C locale (e.g. a hook run via `env -i`) and would
# make this hook's own JSON unparseable, i.e. a fail-OPEN in the deny path.
mask() {
  local t="$1"
  if [ "${#t}" -le 8 ]; then printf '%s' "********"; else printf '%s...%s' "${t:0:4}" "********"; fi
}

emit() {                       # emit <decision> <reason>
  local decision="$1" reason="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg d "$decision" --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  else
    local esc
    esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$decision" "$esc"
  fi
  exit 0
}
deny() { emit deny "$1"; }
ask()  { emit ask  "$1"; }

# ---------------------------------------------------------------------------
# (A) Provider-prefix patterns — high-confidence.
# ---------------------------------------------------------------------------
PATTERN='AKIA[0-9A-Z]{16}'                                   # AWS access key id
PATTERN="$PATTERN"'|ASIA[0-9A-Z]{16}'                        # AWS temp key id
PATTERN="$PATTERN"'|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'   # PEM private keys
PATTERN="$PATTERN"'|sk_live_[0-9a-zA-Z]{16,}'                # Stripe live
PATTERN="$PATTERN"'|sk_test_[0-9a-zA-Z]{16,}'                # Stripe test
PATTERN="$PATTERN"'|rk_live_[0-9a-zA-Z]{16,}'                # Stripe restricted
PATTERN="$PATTERN"'|sk-ant-[0-9a-zA-Z_-]{20,}'              # Anthropic
PATTERN="$PATTERN"'|sk-[0-9a-zA-Z]{40,}'                     # OpenAI-style
PATTERN="$PATTERN"'|ghp_[0-9a-zA-Z]{36}'                     # GitHub PAT
PATTERN="$PATTERN"'|gho_[0-9a-zA-Z]{36}'                     # GitHub OAuth
PATTERN="$PATTERN"'|ghs_[0-9a-zA-Z]{36}'                     # GitHub server
PATTERN="$PATTERN"'|github_pat_[0-9a-zA-Z_]{40,}'           # GitHub fine-grained PAT
PATTERN="$PATTERN"'|glpat-[0-9a-zA-Z_-]{20,}'              # GitLab PAT
PATTERN="$PATTERN"'|xox[baprs]-[0-9a-zA-Z-]{10,}'           # Slack token
PATTERN="$PATTERN"'|AIza[0-9A-Za-z_-]{35}'                 # Google API key
PATTERN="$PATTERN"'|ya29\.[0-9A-Za-z_-]+'                   # Google OAuth
PATTERN="$PATTERN"'|SG\.[0-9A-Za-z_-]{22}\.[0-9A-Za-z_-]{43}' # SendGrid
PATTERN="$PATTERN"'|lin_api_[0-9a-zA-Z]{20,}'              # Linear
PATTERN="$PATTERN"'|FlyV1 [a-zA-Z0-9+/_-]{20,}'             # Fly.io
PATTERN="$PATTERN"'|rnd_[0-9a-zA-Z]{20,}'                   # Render
PATTERN="$PATTERN"'|dop_v1_[0-9a-f]{64}'                    # DigitalOcean
PATTERN="$PATTERN"'|npm_[0-9a-zA-Z]{36}'                    # npm token
PATTERN="$PATTERN"'|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' # JWT
# Credentials embedded in a DB/AMQP connection URI: scheme://user:PASSWORD@host
PATTERN="$PATTERN"'|(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqps?):\/\/[^:@/[:space:]]+:[^@/[:space:]]+@'

# EVERY match, de-duplicated — never `head -n1`, which would leak a second
# secret straight through the rewrite (finding #29b).
HITS=$(printf '%s' "$CONTENT" | grep -oE -- "$PATTERN" 2>/dev/null | sort -u)

# ---------------------------------------------------------------------------
# (C) Secret EGRESS — a secret PATH plus an egress verb in the same command.
# ---------------------------------------------------------------------------
EGRESS=0
EGRESS_WHAT=""
if [ "$TOOL_NAME" = "Bash" ]; then
  SECRET_PATH_RE='(^|[[:space:]"'"'"'=@:/(])(secrets\.env|\.env(\.[A-Za-z0-9_-]+)?|auth\.json|credentials\.json|id_rsa|id_ed25519|id_ecdsa|\.npmrc|\.pgpass|\.netrc)([[:space:]"'"'"'&;|)]|$)'
  # An egress verb as the LEADING command of a pipeline segment (not a word that
  # merely appears inside some argument).
  EGRESS_RE='(^|[;&|`(]|&&|\|\|)[[:space:]]*(sudo[[:space:]]+)?(curl|wget|nc|ncat|netcat|telnet|ftp|sftp|http|httpie|xh)([[:space:]]|$)'
  COPY_RE='(^|[;&|`(]|&&|\|\|)[[:space:]]*(sudo[[:space:]]+)?(scp|rsync)([[:space:]]|$)'
  REMOTE_RE='([A-Za-z0-9._%+-]+@[A-Za-z0-9._-]+:|::[A-Za-z0-9]|rsync://|ssh://)'
  if printf '%s' "$CONTENT" | grep -qE -- "$SECRET_PATH_RE" 2>/dev/null; then
    if printf '%s' "$CONTENT" | grep -qE -- "$EGRESS_RE" 2>/dev/null; then
      EGRESS=1; EGRESS_WHAT="a network client (curl/wget/nc/…)"
    elif printf '%s' "$CONTENT" | grep -qE -- "$COPY_RE" 2>/dev/null \
      && printf '%s' "$CONTENT" | grep -qE -- "$REMOTE_RE" 2>/dev/null; then
      EGRESS=1; EGRESS_WHAT="a remote copy (scp/rsync to a remote host)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Tier A decision.
# ---------------------------------------------------------------------------
if [ -n "$HITS" ]; then
  MASKED=""
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    MASKED="$MASKED $(mask "$h")"
  done <<< "$HITS"
  MASKED="${MASKED# }"

  if [ "$TOOL_NAME" != "Bash" ]; then
    deny "Hardcoded secret detected ($MASKED). Never commit credentials — load them from an environment variable or the project secret store (~/.claude/secrets.env / the Quetrex vault) instead."
  fi

  # Two Bash shapes where redaction would be WRONG for the same reason the
  # Write|Edit path denies — the placeholder would be PERSISTED and the agent
  # would believe the resulting file holds a working credential:
  #   1. a multi-line PEM key: only the header line matches, so a rewrite would
  #      strip the marker and leave the key material in the command;
  #   2. the command is writing the secret INTO a file (heredoc / echo|printf|
  #      cat|tee|sed redirect), i.e. the Write|Edit case spelled in shell.
  case "$HITS" in *"-----BEGIN"*)
    deny "A PEM private key is embedded in this command ($MASKED). Write the key to the secret store out of band; never inline it in a shell command." ;;
  esac
  if printf '%s' "$CONTENT" | grep -qE -- '<<-?[[:space:]]*['"'"'"]?[A-Za-z_]' 2>/dev/null \
     || { printf '%s' "$CONTENT" | grep -qE -- '(^|[;&|`(]|&&|\|\|)[[:space:]]*(sudo[[:space:]]+)?(echo|printf|cat|tee|sed)([[:space:]]|$)' 2>/dev/null \
          && printf '%s' "$CONTENT" | grep -qE -- '>>?[[:space:]]*[^&[:space:]]' 2>/dev/null; }; then
    deny "Hardcoded secret detected in a command that WRITES it to a file ($MASKED). Redacting it would leave a file the pipeline believes holds a working credential. Write the placeholder yourself and load the real value from an environment variable or the Quetrex vault at runtime."
  fi

  # Bash + egress: an exfiltration is not something to quietly rewrite.
  if [ "$EGRESS" -eq 1 ]; then
    ask "This command carries a credential ($MASKED) AND sends a secret file out through $EGRESS_WHAT. Confirm this is intended, or route the credential through the project secret store instead."
  fi

  if [ "$JQ_OK" -ne 1 ]; then
    # (finding #29c) a redaction that cannot be built safely degrades to deny.
    deny "Hardcoded secret detected in a shell command ($MASKED), and jq is unavailable so the command cannot be safely redacted. Load the credential from an environment variable or the Quetrex vault instead."
  fi

  PLACEHOLDER='__QUETREX_REDACTED_SECRET__'
  REDACTED="$CONTENT"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    # Quoting the pattern makes it a LITERAL replacement, and `//` replaces
    # EVERY occurrence — both matter (finding #29b).
    REDACTED="${REDACTED//"$h"/$PLACEHOLDER}"
  done <<< "$HITS"

  # Tier B still gets the last word on what survives the rewrite (below), so
  # re-scan the redacted text with the entropy heuristic before allowing it.
  CONTENT_FOR_TIER_B="$REDACTED"
else
  CONTENT_FOR_TIER_B="$CONTENT"
fi

# ---------------------------------------------------------------------------
# (B) High-entropy heuristic — a long base64/hex blob assigned to a secret-ish
#     key. Requires BOTH: a secret keyword on the line AND Shannon entropy > 4.0
#     over a >=20-char token. This keeps hashes / SHAs / lockfile digests quiet.
#     ALWAYS deny — never rewrite a value the heuristic only guessed at.
# ---------------------------------------------------------------------------
KEYWORD='(secret|token|passwd|password|api[_-]?key|apikey|access[_-]?key|private[_-]?key|client[_-]?secret|auth[_-]?token|bearer|credential)'

SUSPECT=$(printf '%s' "$CONTENT_FOR_TIER_B" | grep -iE "$KEYWORD" 2>/dev/null | grep -oiE "$KEYWORD['\"[:space:]]*[:=]['\"[:space:]]*[A-Za-z0-9+/=_-]{20,}" | head -n40)
if [ -n "$SUSPECT" ]; then
  BAD=$(printf '%s\n' "$SUSPECT" | awk '
    function entropy(s,   i,ch,n,freq,p,h) {
      n=length(s); if (n==0) return 0
      for (i=1;i<=n;i++){ch=substr(s,i,1); freq[ch]++}
      h=0; for (ch in freq){p=freq[ch]/n; h-=p*log(p)/log(2)}
      return h
    }
    {
      # isolate the trailing value token (after the last : or =)
      tok=$0; sub(/.*[:=]['\''"[:space:]]*/,"",tok); gsub(/['\''",;]+$/,"",tok)
      if (length(tok) >= 20 && entropy(tok) > 4.0) { print tok; exit }
    }')
  if [ -n "$BAD" ]; then
    deny "High-entropy value assigned to a secret-named field ($(mask "$BAD")). If this is a real credential, move it to an environment variable / secret store; if it is genuinely non-sensitive test data, rename the field so it is not 'secret/token/key'."
  fi
fi

# ---------------------------------------------------------------------------
# Tier A rewrite (nothing else objected) — allow the call with the secret
# replaced, and SAY SO. A silent rewrite is worse than no rewrite (finding #29c).
# ---------------------------------------------------------------------------
if [ -n "$HITS" ]; then
  NEWINPUT=$(printf '%s' "$input" | jq -c --arg red "$REDACTED" '.tool_input | .command = $red' 2>/dev/null)
  if [ -z "$NEWINPUT" ]; then
    deny "Hardcoded secret detected in a shell command ($MASKED) and the redacted command could not be built. Load the credential from an environment variable or the Quetrex vault instead."
  fi
  REASON="REDACTED: this command contained credential(s) ($MASKED). Every occurrence was replaced with $PLACEHOLDER before execution, so the command runs but will fail authentication at the remote. Do not re-send the literal secret — read it from an environment variable or the Quetrex vault (e.g. \"\$MY_TOKEN\") and re-run."
  jq -cn --argjson ui "$NEWINPUT" --arg r "$REASON" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r,updatedInput:$ui}}'
  exit 0
fi

# ---------------------------------------------------------------------------
# Egress with no literal secret in the string — the case no tier could see.
# ---------------------------------------------------------------------------
if [ "$EGRESS" -eq 1 ]; then
  ask "This command references a secret file (.env / secrets.env / auth.json / an SSH private key) in the same command as $EGRESS_WHAT. The credential never appears in the command text, so no content scan can see it leave. Confirm this egress is intended; if you only need a value, read the single variable rather than sending the file."
fi

exit 0
