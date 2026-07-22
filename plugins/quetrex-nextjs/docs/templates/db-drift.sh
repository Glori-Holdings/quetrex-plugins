#!/usr/bin/env bash
# db-drift.sh — READ-ONLY Drizzle drift guard, shipped as a TEMPLATE by the
# quetrex-nextjs pack. /quetrex-init copies this into the project's ./scripts/
# so the verify chain step `bash scripts/db-drift.sh` resolves.
#
# It fails if src/db/schema.ts changed without a committed migration — the most
# common Drizzle prod incident — WITHOUT ever mutating the tracked tree: it
# generates into a throwaway temp copy of the migrations dir and diffs counts.
set -euo pipefail

MIG="${DRIZZLE_MIGRATIONS_DIR:-src/db/migrations}"
if [ ! -d "$MIG" ]; then
  echo "db-drift: no migrations dir at '$MIG' — nothing to check (set DRIZZLE_MIGRATIONS_DIR if it lives elsewhere)."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Seed the temp dir with the existing migration history so generate only emits
# a NEW file when schema.ts has genuinely diverged.
cp -a "$MIG"/. "$TMP"/ 2>/dev/null || true
before=$(find "$TMP" -maxdepth 1 -name '*.sql' | wc -l | tr -d ' ')

# Generate into the THROWAWAY copy — never the tracked tree.
pnpm exec drizzle-kit generate --out="$TMP" >/dev/null 2>&1

after=$(find "$TMP" -maxdepth 1 -name '*.sql' | wc -l | tr -d ' ')

if [ "$before" -ne "$after" ]; then
  echo "DRIFT: src/db/schema.ts changed without a committed migration."
  echo "       Run the drizzle-migrate skill: drizzle-kit generate -> review the SQL -> commit -> drizzle-kit migrate."
  exit 1
fi
echo "db-drift: schema and migrations are in sync."
