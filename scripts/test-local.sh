#!/usr/bin/env bash
# Runs the migration and the pgTAP suite against plain Postgres (no Supabase CLI).
# Needs: psql, pg_prove and the pgtap extension installed on the server.
# Usage: DATABASE_URL=postgres://postgres@localhost:5432/postgres ./scripts/test-local.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADMIN_URL="${DATABASE_URL:-postgres://postgres@localhost:5432/postgres}"
DB="rls_demo_test"
TEST_URL="${ADMIN_URL%/*}/${DB}"

psql "$ADMIN_URL" -qc "drop database if exists ${DB};" -c "create database ${DB};"
psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f "$ROOT/scripts/local-supabase-shim.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f "$f"
done

pg_prove -d "$TEST_URL" "$ROOT"/supabase/tests/database/*.test.sql
