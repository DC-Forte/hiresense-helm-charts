#!/usr/bin/env bash
# =============================================================================
# Hiresense — bootstrap the new prod Postgres instance's schema from staging
#
# Prod's DB is meant to be a structural mirror of staging (same combined
# instance shape — public/interviewhandoff/matchengine/recruiterreport
# schemas, same roles, same extensions), just with zero business data. Rather
# than replaying every historical `ops/*.sql` grant fix + fighting each
# service's own migrate-binary env wiring, this takes a schema-only pg_dump
# of staging and restores it into prod — much faster and byte-identical to
# what staging actually has today, ownership/grants included.
#
# One-time bootstrap for a *fresh, empty* prod instance. Re-running it wipes
# and recreates all 4 schemas (safe only while prod still has no real data —
# do not run this again once prod is live).
#
# Usage: ./bootstrap-prod-db-from-staging.sh
#   Requires: STAGING_DB_ID and PROD_DB_ID env vars (DO database cluster IDs),
#   doctl authed, psql/pg_dump/pg_restore on PATH, and the 4 app roles
#   (hiresense_app, interviewhandoff_app, matchengine_app, recruiterreport_app)
#   already created on the prod instance with LOGIN PASSWORD set — this
#   script does not create roles/passwords, only schema objects.
# =============================================================================
set -euo pipefail

STAGING_DB_ID="${STAGING_DB_ID:?set STAGING_DB_ID to the staging Postgres cluster's doctl database ID}"
PROD_DB_ID="${PROD_DB_ID:?set PROD_DB_ID to the prod Postgres cluster's doctl database ID}"
DB_NAME="${DB_NAME:-hiresense}"
SCRATCH_DIR="${SCRATCH_DIR:-$(mktemp -d)}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

for cmd in doctl psql pg_dump; do
  command -v "$cmd" &>/dev/null || { echo "$cmd is required" >&2; exit 1; }
done

info "Resolving connection strings via doctl..."
STAGING_URI="$(doctl databases connection "$STAGING_DB_ID" --format URI --no-header)"
STAGING_URI="$(echo "$STAGING_URI" | sed -E "s#(://[^/]+/)[^?]+(\?.*)#\1${DB_NAME}\2#")"
PROD_URI="$(doctl databases connection "$PROD_DB_ID" --format URI --no-header)"
PROD_URI="$(echo "$PROD_URI" | sed -E "s#(://[^/]+/)[^?]+(\?.*)#\1${DB_NAME}\2#")"

info "Dumping staging schema (structure/ownership/grants only, zero row data)..."
pg_dump "$STAGING_URI" --schema-only \
  --schema=public --schema=interviewhandoff --schema=matchengine --schema=recruiterreport \
  -f "$SCRATCH_DIR/schema.sql"

info "Dumping migration-tracking table data (version bookkeeping, not business data)..."
pg_dump "$STAGING_URI" --data-only \
  -t public.hb_migrations -t public.migrations_history \
  -t interviewhandoff.hb_migrations -t matchengine.hb_migrations -t recruiterreport.hb_migrations \
  -f "$SCRATCH_DIR/tracking-data.sql"

info "Wiping any existing schemas on prod (safe only pre-launch)..."
psql "$PROD_URI" -v ON_ERROR_STOP=1 -q <<'SQL'
DROP SCHEMA IF EXISTS interviewhandoff CASCADE;
DROP SCHEMA IF EXISTS matchengine CASCADE;
DROP SCHEMA IF EXISTS recruiterreport CASCADE;
DROP SCHEMA IF EXISTS public CASCADE;
SQL

info "Recreating schemas with matching owners..."
psql "$PROD_URI" -v ON_ERROR_STOP=1 -q <<'SQL'
CREATE SCHEMA interviewhandoff AUTHORIZATION doadmin;
CREATE SCHEMA matchengine AUTHORIZATION doadmin;
CREATE SCHEMA recruiterreport AUTHORIZATION recruiterreport_app;
CREATE SCHEMA public AUTHORIZATION hiresense_app;
SQL

# Schema-level ACLs must exist BEFORE table creation: Postgres requires the
# target role of "ALTER TABLE ... OWNER TO x" to already have CREATE on that
# table's schema (see PG docs on ALTER TABLE OWNER TO) — a bare pg_dump
# schema-only dump does not reliably carry these schema-level grants, only
# table/sequence-level ones, so they're applied explicitly here, matching
# staging's real pg_namespace.nspacl exactly (confirmed 2026-09-11).
info "Applying schema-level ACLs (matches staging's pg_namespace.nspacl)..."
psql "$PROD_URI" -v ON_ERROR_STOP=1 -q <<'SQL'
GRANT USAGE, CREATE ON SCHEMA interviewhandoff TO interviewhandoff_app;
GRANT USAGE ON SCHEMA interviewhandoff TO hiresense_app;
GRANT USAGE ON SCHEMA interviewhandoff TO matchengine_app;

GRANT USAGE, CREATE ON SCHEMA matchengine TO matchengine_app;

GRANT USAGE, CREATE ON SCHEMA public TO hiresense_app;
GRANT USAGE ON SCHEMA public TO PUBLIC;
GRANT USAGE ON SCHEMA public TO matchengine_app;
GRANT USAGE ON SCHEMA public TO interviewhandoff_app;
SQL

info "Installing extensions (matches staging's \\dx)..."
psql "$PROD_URI" -v ON_ERROR_STOP=1 -q <<'SQL'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
SQL

info "Restoring schema (types, tables, indexes, table/sequence grants)..."
grep -v -E '^(CREATE SCHEMA|ALTER SCHEMA)' "$SCRATCH_DIR/schema.sql" > "$SCRATCH_DIR/schema-notop.sql"
psql "$PROD_URI" -v ON_ERROR_STOP=1 -q -f "$SCRATCH_DIR/schema-notop.sql"

info "Restoring migration-tracking data..."
psql "$PROD_URI" -v ON_ERROR_STOP=1 -q -f "$SCRATCH_DIR/tracking-data.sql"

info "Verifying table counts match staging..."
psql "$STAGING_URI" -t -c "SELECT schemaname, count(*) FROM pg_tables WHERE schemaname IN ('public','interviewhandoff','matchengine','recruiterreport') GROUP BY schemaname ORDER BY 1;"
psql "$PROD_URI" -t -c "SELECT schemaname, count(*) FROM pg_tables WHERE schemaname IN ('public','interviewhandoff','matchengine','recruiterreport') GROUP BY schemaname ORDER BY 1;"

warn "Dump files left at $SCRATCH_DIR — delete once you've confirmed the counts above match."
info "DONE. Any future golang-migrate migrations run identically against prod as staging (same mage migrateAll, just pointed at prod's connection env vars)."
