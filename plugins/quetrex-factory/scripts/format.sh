#!/usr/bin/env bash
# format.sh — PostToolUse (Write|Edit) hook. Auto-formats the file that was
# just written, using the PROJECT'S OWN formatter when one is available.
#
# PILLAR #4 (SPEED / low-friction excellence): every file an agent touches
# lands already-formatted, so the diff a human reviews is signal — not
# whitespace churn — and `lint`/`format --check` steps in the verify chain
# don't bounce the pipeline on style. This runs AFTER the tool succeeded, so it
# can never gate the write; its only job is a best-effort tidy.
#
# HARD CONTRACT — this hook NEVER blocks and NEVER fails the turn:
#   - PostToolUse fires after the tool already ran; there is nothing to deny.
#   - Every code path ends at `exit 0`. No formatter error, missing binary,
#     missing jq, timeout, or unwritable file can make this hook non-zero or
#     emit a blocking decision. It is a no-op whenever it cannot help.
#
# Formatter selection is by file extension, using ONLY binaries already present
# (project-local node_modules/.bin, then PATH). It NEVER installs anything and
# NEVER reaches the network (no npx/pnpm-dlx/bunx auto-install), so it stays
# fast and deterministic:
#   .js/.jsx/.ts/.tsx/.mjs/.cjs/.json/.jsonc/.css/.scss/.less/.html/.vue/
#   .svelte/.md/.mdx/.yaml/.yml/.graphql  -> biome or prettier
#   .go                                    -> gofmt
#   .rs                                    -> rustfmt
#   .py/.pyi                               -> black, else ruff format
# Anything else, or no formatter on the box -> silent no-op.

set -uo pipefail

# --- read hook input ---------------------------------------------------------
# jq is required to parse the event; if it's absent we simply do nothing.
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$fp" ] || exit 0

# Resolve a relative path against the hook's working directory (the session cwd).
case "$fp" in
  /*) : ;;
  *)  fp="$PWD/$fp" ;;
esac

# Only format a real, regular, writable file that still exists.
[ -f "$fp" ] || exit 0
[ -w "$fp" ] || exit 0

dir=$(dirname "$fp")

# lowercase extension (last .segment); no extension -> nothing keyed off it
base=$(basename "$fp")
ext="${base##*.}"
[ "$ext" = "$base" ] && ext=""            # no dot at all
ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')

# --- bounded, non-fatal runner ----------------------------------------------
# Wrap every formatter call so it (a) is time-boxed and (b) can never abort
# this script. `timeout` is Linux-native; macOS coreutils ships `gtimeout`.
TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT="timeout 30"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT="gtimeout 30"
fi
run() {
  if [ -n "$TIMEOUT" ]; then
    $TIMEOUT "$@" >/dev/null 2>&1 || true
  else
    "$@" >/dev/null 2>&1 || true
  fi
}

# --- resolution helpers ------------------------------------------------------
# Prefer a project-local binary (walking up from the file toward the repo root,
# so monorepo package-level installs win), then fall back to PATH.
find_local_bin() {
  local tool="$1" d="$dir"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -x "$d/node_modules/.bin/$tool" ]; then
      printf '%s' "$d/node_modules/.bin/$tool"; return 0
    fi
    d=$(dirname "$d")
  done
  return 1
}
resolve_bin() {
  local tool="$1" p
  if p=$(find_local_bin "$tool"); then printf '%s' "$p"; return 0; fi
  if p=$(command -v "$tool" 2>/dev/null); then printf '%s' "$p"; return 0; fi
  return 1
}
# Does any of the named config files exist from the file's dir up to the root?
has_config_up() {
  local d="$dir" f
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    for f in "$@"; do [ -e "$d/$f" ] && return 0; done
    d=$(dirname "$d")
  done
  return 1
}

# --- format by extension -----------------------------------------------------
case "$ext" in
  js|jsx|ts|tsx|mjs|cjs|json|jsonc|css|scss|less|html|vue|svelte|md|mdx|yaml|yml|graphql|gql)
    biome_bin=$(resolve_bin biome || true)
    prettier_bin=$(resolve_bin prettier || true)

    biome_cfg=false;    has_config_up biome.json biome.jsonc && biome_cfg=true
    prettier_cfg=false; has_config_up .prettierrc .prettierrc.json .prettierrc.yaml .prettierrc.yml \
        .prettierrc.json5 .prettierrc.js .prettierrc.cjs .prettierrc.mjs .prettierrc.toml \
        prettier.config.js prettier.config.cjs prettier.config.mjs && prettier_cfg=true

    # Choose the tool the project actually configured; default to prettier, the
    # most widely installed. Never run both (they'd fight over style).
    if [ "$biome_cfg" = true ] && [ -n "$biome_bin" ]; then
      run "$biome_bin" format --write --skip-errors "$fp"
    elif [ "$prettier_cfg" = true ] && [ -n "$prettier_bin" ]; then
      run "$prettier_bin" --write --ignore-unknown --log-level silent "$fp"
    elif [ -n "$prettier_bin" ]; then
      run "$prettier_bin" --write --ignore-unknown --log-level silent "$fp"
    elif [ -n "$biome_bin" ]; then
      run "$biome_bin" format --write --skip-errors "$fp"
    fi
    ;;

  go)
    bin=$(resolve_bin gofmt || true)
    [ -n "$bin" ] && run "$bin" -w "$fp"
    ;;

  rs)
    bin=$(resolve_bin rustfmt || true)
    # Default to a modern edition so 2018/2021 syntax reformats correctly when
    # invoked file-at-a-time (rustfmt can't read the crate edition from Cargo.toml here).
    [ -n "$bin" ] && run "$bin" --edition 2021 "$fp"
    ;;

  py|pyi)
    if bin=$(resolve_bin black); then
      run "$bin" --quiet "$fp"
    elif bin=$(resolve_bin ruff); then
      run "$bin" format "$fp"
    fi
    ;;

  *)
    : # no known formatter for this extension — silent no-op
    ;;
esac

exit 0
