#!/usr/bin/env bash
# right-size-router.sh — UserPromptSubmit hook. THE SPEED fix (Pillar #4).
#
# Classifies every incoming user prompt into a routing tier and injects an
# AUTHORITATIVE `ROUTE:` line into the model's context so the orchestrator does
# NOT re-decide how much ceremony a task deserves:
#
#   TRIVIAL   -> one agent, direct edit in the working tree. NO worktree,
#               architect, ownership map, parallel devs, separate QA, or reviewer.
#   STANDARD  -> one worktree, one developer + qa (+ security-reviewer if flagged).
#   COMPLEX   -> full line: architect -> parallel developers -> qa -> reviewer
#               -> security-reviewer -> git-workflow.
#   AMBIGUOUS -> deterministic heuristic cannot size it; orchestrator invokes the
#               `triage` agent for one token (TRIVIAL|STANDARD|COMPLEX).
#
# DESIGN AXIOM: this hook lowers ORCHESTRATION cost only. It NEVER lowers the
# safety floor — verify-gate, deny-guard, secret-scan, enforce-branch, and
# enforce-merge-approval fire on every tier regardless of what is routed here.
#
# CONSERVATIVE ASYMMETRY: mis-sizing a hard task as TRIVIAL ships silent bad
# code; mis-sizing an easy task as COMPLEX only wastes tokens. So every
# uncertain or contradictory signal ROUNDS UP a tier, and any sensitive path
# (auth/authz/secret/migration/infra/ci/payment/crypto) is a HARD OVERRIDE that
# forces at least STANDARD and forces security_review_required=true — the
# security gate is mandatory-by-detection, not by architect discretion.
#
# Deterministic, no model call, sub-100ms. stdout of a UserPromptSubmit hook is
# added to context; we emit the documented additionalContext JSON envelope.
#
# INPUT  (stdin JSON):  {"prompt":"...", "cwd":"...", ...}
# OUTPUT (stdout JSON): {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit",
#                        "additionalContext":"ROUTE: <TIER> — <guidance>. Reasons: ..."}}
# A silent `exit 0` (no JSON) means: nothing to route — do not pollute context.

set -euo pipefail

# --- read + parse ----------------------------------------------------------
input=$(cat 2>/dev/null || true)
[ -z "$input" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0   # fail-open: never block a prompt

prompt=$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)
[ -z "$prompt" ] && exit 0

# lower-cased, whitespace-collapsed copy for matching
lc=$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')

# --- skip non-routable prompts --------------------------------------------
# Slash commands drive their own flow (they own the pipeline); do not route.
case "$prompt" in
  /*) exit 0 ;;
esac

emit() {  # $1 = full additionalContext string
  jq -cn --arg c "$1" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
  exit 0
}

# grep helper: case-insensitive extended regex against the prompt
has() { printf '%s' "$lc" | grep -qiE "$1"; }

# =========================================================================
# 1. WORK-INTENT DETECTION — is this a code-change request at all?
# =========================================================================
# A change verb, OR a named file/path, signals real work. Pure questions,
# greetings, and status checks route to nothing (keeps chat context clean).
INTENT_VERB='(^| )(fix|patch|correct|repair|add|adds|adding|change|changes|update|updates|updating|implement|implements|build|builds|create|creates|creating|write|edit|edits|refactor|refactors|rename|renames|remove|removes|delete|deletes|drop|bump|upgrade|downgrade|migrate|migrates|wire|hook up|integrate|support|introduce|replace|adjust|modify|modifies|tweak|rework|revamp|redesign|overhaul|extend|extends|make (it|the|a )|convert|move|split|extract|inline)'

# Extract file-path-ish tokens (contain a slash, or end in a code-ish ext),
# excluding version strings, prose abbreviations, and framework brand names.
files=$(printf '%s' "$prompt" \
  | grep -oiE '[A-Za-z0-9_@][A-Za-z0-9_./@-]*\.[A-Za-z0-9]{1,6}\b' \
  | grep -viE '^(e\.g|i\.e|etc|vs|a\.k\.a)\.?$' \
  | grep -viE '^(node|next|nest|vue|nuxt|d3|three|socket)\.[a-z]+$' \
  | grep -viE '^v?[0-9][0-9.]*$' \
  | grep -viE '^[0-9][0-9.]*$' \
  | sort -u || true)
filecount=$(printf '%s\n' "$files" | grep -c . || true)
# also honor an explicit count phrase like "across 5 files" / "3 files"
explicit_n=$(printf '%s' "$lc" | grep -oiE '([0-9]+) (files|modules|components|services|endpoints)' \
  | grep -oiE '^[0-9]+' | sort -rn | head -n1 || true)
if [ -n "$explicit_n" ] && [ "$explicit_n" -gt "$filecount" ] 2>/dev/null; then
  filecount="$explicit_n"
fi

work_intent=0
has "$INTENT_VERB" && work_intent=1
[ "$filecount" -ge 1 ] 2>/dev/null && work_intent=1
# nothing actionable -> stay silent
[ "$work_intent" -eq 0 ] && exit 0

# =========================================================================
# 2. SIGNAL SCAN
# =========================================================================
reasons=""
add_reason() { reasons="${reasons:+$reasons; }$1"; }

# ---- 2a. HARD SECURITY OVERRIDE (forces >= STANDARD + security review) ----
SECURITY_RE='(auth[a-z]*|authz|oauth|openid|saml|sso|login|logout|sign[ -]?in|session|cookie|jwt|bearer|token|api[ -]?key|secret|credential|password|passwd|hash(ing)?|bcrypt|argon2|crypto|encrypt|decrypt|cipher|tls|ssl|certificate|private[ -]?key|payment|billing|invoice|stripe|paypal|charge|checkout|card|permission|role|rbac|access control|tenant|migration|migrate|infra(structure)?|terraform|pulumi|kubernetes|k8s|helm|dockerfile|docker-compose|\.github/workflows|ci/cd|ci pipeline|pipeline\.yml|secrets? scan)'
security=0
if has "$SECURITY_RE"; then
  security=1
  add_reason "touches a sensitive surface (auth/secret/migration/infra/ci/payment/crypto) -> security_review_required"
fi

# ---- 2b. COMPLEX signals (any one -> COMPLEX) ----------------------------
complex=0
mark_complex() { complex=1; add_reason "$1"; }

# new dependency / third-party service integration
has '(npm|pnpm|yarn) (install|i|add) [a-z@]|pip install |go get |cargo add |add(ing)? (a )?(new )?(dependency|dependencies|package|library|lib|framework|sdk)|new dependency|pull in [a-z]+ (library|package)|install (the )?[a-z][a-z0-9@/_-]+ (package|library|sdk|module|integration)|(install|integrate|add|set ?up|wire (in|up)) (the )?(stripe|paypal|braintree|square|plaid|twilio|sendgrid|mailgun|auth0|okta|firebase|supabase|clerk|cognito|sentry)' \
  && mark_complex "adds a new dependency / third-party integration"

# schema / DB migration
has '(db|database|schema) (change|migration)|migrat(e|ion)|alter table|create table|drop (table|column)|add column|add(ing)? (a )?(table|column|index|constraint|foreign key)|prisma|drizzle|typeorm|sequelize|new (table|model|entity|schema)' \
  && mark_complex "schema/DB migration"

# public API / contract / breaking change
has 'public api|api contract|breaking change|breaking-change|new endpoint|new route|change the (response|request) (shape|schema|contract)|version the api|deprecat(e|ion)' \
  && mark_complex "public-API / contract change"

# large-surface refactor / sweeping change
has 'refactor|re-?architect|overhaul|revamp|redesign|rewrite|throughout|across the (codebase|app|project|repo)|entire (codebase|app|project|repo)|whole (codebase|app|project|repo)|everywhere|and also|as well as' \
  && mark_complex "large-surface refactor / sweeping change"

# crosses architectural layers (>= 2 of api / ui / data)
layer_hits=0
has '(^| )(api|backend|server|endpoint|route|controller|handler|graphql|rest)( |$)' && layer_hits=$((layer_hits+1))
has '(^| )(ui|frontend|front-end|component|page|screen|view|react|vue|svelte|css|styl(e|ing)|button|form|modal)( |$)' && layer_hits=$((layer_hits+1))
has '(^| )(db|database|schema|migration|sql|query|model|repository|orm|table)( |$)' && layer_hits=$((layer_hits+1))
if [ "$layer_hits" -ge 2 ]; then
  mark_complex "crosses architectural layers"
fi

# many files
if [ "$filecount" -ge 4 ] 2>/dev/null; then
  mark_complex "touches ${filecount}+ files"
fi
has 'multiple files|several files|many files|a bunch of files|lots of files' \
  && mark_complex "spans multiple files"

# ambiguous / underspecified -> round UP to COMPLEX (silent bad code is worse)
has '(figure (it|this) out|not sure (how|what|where)|somehow|some kind of|whatever (works|makes sense)|a bunch of (stuff|things)|various (things|stuff)|clean ?up everything|do the needful|you decide|as you see fit)' \
  && mark_complex "underspecified / open-ended ask"

# =========================================================================
# 3. TRIVIAL signals (only consulted if NOT complex)
# =========================================================================
trivial=0
mark_trivial() { trivial=1; add_reason "$1"; }

if [ "$complex" -eq 0 ]; then
  # typo / comment / copy / docs wording
  has '(fix|correct) (a )?typo|typos?( |$)|misspell|spelling|grammar|reword|rephrase|wording|copy(-| )?edit|comment(s)?( |$)|update (the )?(readme|docs|documentation|changelog)|docs?[ -]only' \
    && mark_trivial "typo/comment/docs/copy edit"

  # version bump / single config value
  has 'bump ([a-z@/-]+ )?(to |from )?v?[0-9]|upgrade [a-z@/-]+ to v?[0-9]|update [a-z@/-]+ to v?[0-9]|version bump|bump the version|change (the )?(config|setting|value|constant|flag|env var) |single (config|value|constant)' \
    && mark_trivial "version bump / single config value"

  # rename within one place
  has 'rename\b.{0,40}\b(to|into|->)\b|rename (the |a )?(variable|function|method|field|constant|file|class|type|prop|param|argument)' \
    && mark_trivial "rename"

  # explicitly-scoped single-function / single-file edit
  has '(one|single|a single|just (one|the)) (line|function|method|file|value|string|field)|in (the|this) (one )?file|only (touch|edit|change) (one|the) (file|function)' \
    && mark_trivial "explicitly single-file / single-function scope"

  # conventional-commit trivial prefix (the `chore:` / `docs:` / `style:` FORM,
  # requiring the colon) with tight scope. NB: bare English "fix the bug" is NOT
  # trivial — a real single-file bug fix rounds up to STANDARD (still fast, but
  # gets QA), because "fix" is the most common verb for genuine defects.
  has '^(fix|chore|docs|style)(\([a-z0-9_-]+\))?:' && [ "$filecount" -le 1 ] 2>/dev/null \
    && mark_trivial "conventional-commit trivial prefix, tight scope"
fi

# =========================================================================
# 4. DECISION — conservative round-up
# =========================================================================
GATE_NOTE='SAFETY FLOOR unchanged: verify-gate (Stop+SubagentStop), deny-guard, secret-scan, and enforce-branch STILL fire on this tier.'

# Sensitive-path clause, gated on the VALUE (the vars hold "0"/"1", both of
# which are non-empty — so ${var:+...} would always expand; test the value).
if [ "$security" -eq 1 ]; then
  sec_clause=" A sensitive path was detected, so security-reviewer IS required."
else
  sec_clause=""
fi

if [ "$complex" -eq 1 ]; then
  tier="COMPLEX"
  guidance="run the FULL line — architect (plan + zero-overlap file-ownership map + acceptance criteria) -> parallel developers on disjoint worktrees -> qa (proves the verify chain green by exit code, authors independent tests) -> reviewer (adversarial) -> security-reviewer (MANDATORY) -> git-workflow (artifact-gated squash PR). Do NOT skip a stage.${sec_clause}"
elif [ "$trivial" -eq 1 ] && [ "$security" -eq 0 ] && [ "$filecount" -le 1 ] 2>/dev/null; then
  # TRIVIAL requires: a clear trivial signal, NO sensitive path, <=1 file.
  tier="TRIVIAL"
  guidance="handle with a SINGLE agent doing a direct edit in the working tree. Skip the worktree, architect, ownership map, parallel developers, separate QA agent, and reviewer. Still verify green before finishing."
elif [ "$trivial" -eq 1 ] && [ "$filecount" -le 1 ] 2>/dev/null; then
  # trivial-looking but on a sensitive path -> round UP to STANDARD + security.
  tier="STANDARD"
  guidance="one worktree, one developer + qa; security-reviewer IS required despite the small scope. Reviewer optional.${sec_clause}"
elif [ "$filecount" -ge 1 ] 2>/dev/null || has "$INTENT_VERB"; then
  # Clear work intent, no complex signal, not clearly trivial -> STANDARD default.
  tier="STANDARD"
  guidance="one worktree, one developer + qa (light architect plan is fine). reviewer only if security paths are involved.${sec_clause}"
else
  # Genuine ambiguity: actionable but the heuristic cannot size it. Round up via triage.
  tier="AMBIGUOUS"
  guidance="the deterministic router could not size this. Invoke the \`triage\` agent for one token (TRIVIAL|STANDARD|COMPLEX) BEFORE choosing a path; on any doubt, prefer the higher tier."
fi

[ -z "$reasons" ] && reasons="general change request"

sec_flag="false"; [ "$security" -eq 1 ] && sec_flag="true"

emit "ROUTE: ${tier} (security_review_required=${sec_flag}) — ${guidance} Reasons: ${reasons}. ${GATE_NOTE}"
