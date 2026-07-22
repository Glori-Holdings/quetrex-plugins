#!/usr/bin/env bash
# secret-scan.sh — PreToolUse deny for hardcoded secrets.
#
# Registered on BOTH Write|Edit AND Bash:
#   - Write / Edit: scans .tool_input.content (Write) and .tool_input.new_string
#     (Edit) — the file body being written.
#   - Bash:         scans .tool_input.command — this closes the audited gap where
#     a secret is written via a redirect / heredoc (e.g. `cat > .env <<EOF ...`)
#     bypassing the Write/Edit matcher entirely.
#
# Emits PreToolUse permissionDecision:"deny" on exit 0, so it fires even under
# bypassPermissions / --dangerously-skip-permissions. The offending token is
# MASKED in the reason (we never echo the secret back in full).
#
# Detection has two tiers:
#   (A) PROVIDER-PREFIX regexes — unambiguous, fire unconditionally.
#   (B) HIGH-ENTROPY heuristic — a long base64/hex blob assigned to a
#       secret-looking key. Scoped to an assignment context with a secret
#       keyword so ordinary hashes / lockfile digests / git SHAs do NOT trip it
#       (false positives erode trust in the gate).
set -uo pipefail

input=$(cat)
TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)

case "$TOOL_NAME" in
  Write) CONTENT=$(printf '%s' "$input" | jq -r '.tool_input.content // empty' 2>/dev/null) ;;
  Edit)  CONTENT=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty' 2>/dev/null) ;;
  Bash)  CONTENT=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) ;;
  *)     CONTENT=$(printf '%s' "$input" | jq -r '(.tool_input.content // .tool_input.new_string // .tool_input.command // empty)' 2>/dev/null) ;;
esac
[ -z "$CONTENT" ] && exit 0

# Mask a token for safe display: keep a 4-char prefix, replace the rest with •.
mask() {
  local t="$1" n
  n=${#t}
  if [ "$n" -le 8 ]; then printf '%s' "••••••••"; else printf '%s…%s' "${t:0:4}" "$(printf '%*s' $((n-4)) '' | tr ' ' '•' | cut -c1-8)"; fi
}

deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# ---------------------------------------------------------------------------
# (A) Provider-prefix patterns — high-confidence, always deny.
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

HIT=$(printf '%s' "$CONTENT" | grep -oE -- "$PATTERN" 2>/dev/null | head -n1)
if [ -n "$HIT" ]; then
  deny "Hardcoded secret detected ($(mask "$HIT")). Never commit credentials — load them from an environment variable or the project secret store (~/.claude/secrets.env / the Quetrex vault) instead."
fi

# ---------------------------------------------------------------------------
# (B) High-entropy heuristic — a long base64/hex blob assigned to a secret-ish
#     key. Requires BOTH: a secret keyword on the line AND Shannon entropy > 4.0
#     over a >=20-char token. This keeps hashes / SHAs / lockfile digests quiet.
# ---------------------------------------------------------------------------
KEYWORD='(secret|token|passwd|password|api[_-]?key|apikey|access[_-]?key|private[_-]?key|client[_-]?secret|auth[_-]?token|bearer|credential)'

SUSPECT=$(printf '%s' "$CONTENT" | grep -iE "$KEYWORD" 2>/dev/null | grep -oiE "$KEYWORD['\"[:space:]]*[:=]['\"[:space:]]*[A-Za-z0-9+/=_-]{20,}" | head -n40)
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

exit 0