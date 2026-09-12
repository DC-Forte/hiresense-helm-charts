#!/usr/bin/env bash
# =============================================================================
# Hiresense — split the shared "hiresense" DO Spaces bucket into per-env
# buckets, per Phase 2b of docs/superpowers/specs/
# 2026-09-11-hiresense-staging-prod-buildout-design.md (chapter-interview-backend-go).
#
# Uses rclone, per DigitalOcean's own documented method for bucket-to-bucket
# Spaces transfers (docs.digitalocean.com/products/spaces/how-to/transfer-between-regions/
# — same tool/commands, just same-region here so one connection string covers
# both buckets instead of two named remotes). Credentials are passed via an
# on-the-fly rclone connection string (":s3,provider=DigitalOcean,..."), never
# written to ~/.config/rclone/rclone.conf.
#
# DO Spaces has no bucket-rename API (confirmed) — this creates
# "hiresense-staging" fresh and copies only the real app-data prefixes from
# "hiresense" into it, and creates "hiresense-prod" empty (prod has no data
# yet). It does NOT touch/delete the original "hiresense" bucket or update
# any values.secrets.yaml — that's a separate manual step, do it only after
# confirming the copy is verified complete below.
#
# "hiresense" holds 7 top-level prefixes as of 2026-09-11:
#   recordings/ (1684 obj, ~2.7GB), resumes/ (115 obj, ~27MB), logos/ (6),
#   index/ (27)                          <- real app data, COPIED
#   loki/ (2725 obj, ~5MB), tempo/ (1938 obj, ~531MB)
#                                         <- the monitoring chart's own S3
#                                            backend storage (values-prod.yaml:139
#                                            hardcodes bucket: hiresense) — shared
#                                            across ALL namespaces/envs via one
#                                            monitoring install, NOT per-env data.
#                                            Never copied, never deleted here.
#   fake/ (17269 obj, ~391MB)            <- test/placeholder data, NOT copied
# Only the 4 app-data prefixes are synced: ~1832 objects / ~2.7GB, not the
# full 23,764 / 3.6GB the bucket actually holds.
#
# Usage: ./split-spaces-buckets.sh
#   Requires: doctl authed, rclone + aws CLI on PATH (aws s3api only used for
#   bucket creation — rclone has no create-bucket command). Creates a
#   temporary full-access DO Spaces key for the duration of the run and
#   deletes it again after — no long-lived broad credential is left behind.
# =============================================================================
set -euo pipefail

REGION="fra1"
ENDPOINT="${REGION}.digitaloceanspaces.com"
SOURCE_BUCKET="hiresense"
STAGING_BUCKET="hiresense-staging"
PROD_BUCKET="hiresense-prod"
KEY_NAME="spaces-bootstrap-$(date +%s 2>/dev/null || echo tmp)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

for cmd in doctl aws rclone; do
  command -v "$cmd" &>/dev/null || { echo "$cmd is required" >&2; exit 1; }
done

info "Creating temporary full-access Spaces key ($KEY_NAME)..."
KEY_JSON=$(doctl spaces keys create "$KEY_NAME" --grants 'bucket=;permission=fullaccess' -o json)
AWS_ACCESS_KEY_ID=$(echo "$KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["access_key"])')
AWS_SECRET_ACCESS_KEY=$(echo "$KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["secret_key"])')
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

cleanup() {
  info "Deleting temporary Spaces key..."
  doctl spaces keys delete "$AWS_ACCESS_KEY_ID" &>/dev/null || warn "Could not delete temp key $AWS_ACCESS_KEY_ID — remove it manually (doctl spaces keys list)"
}
trap cleanup EXIT

# rclone on-the-fly remote — credentials never touch a config file.
RC=":s3,provider=DigitalOcean,env_auth=false,access_key_id=${AWS_ACCESS_KEY_ID},secret_access_key=${AWS_SECRET_ACCESS_KEY},endpoint=${ENDPOINT},acl=private:"

info "Creating $STAGING_BUCKET (if it doesn't already exist)..."
aws s3api create-bucket --bucket "$STAGING_BUCKET" --endpoint-url "https://${ENDPOINT}" --region "$REGION" 2>&1 \
  | grep -qv "BucketAlreadyOwnedByYou\|BucketAlreadyExists" || true

info "Creating $PROD_BUCKET (if it doesn't already exist)..."
aws s3api create-bucket --bucket "$PROD_BUCKET" --endpoint-url "https://${ENDPOINT}" --region "$REGION" 2>&1 \
  | grep -qv "BucketAlreadyOwnedByYou\|BucketAlreadyExists" || true

APP_DATA_PREFIXES=(recordings resumes logos index)

info "Copying app-data prefixes only (${APP_DATA_PREFIXES[*]}) from $SOURCE_BUCKET -> $STAGING_BUCKET..."
info "(loki/, tempo/ deliberately skipped — monitoring's own storage, shared across all envs;"
info " fake/ deliberately skipped — test/placeholder data, not real app data)"
for prefix in "${APP_DATA_PREFIXES[@]}"; do
  # acl=private on the remote means every copied object gets a private ACL
  # regardless of the source object's ACL (see resume_acl_exposure_fix in
  # memory) — this does not preserve a public ACL if one existed on the source.
  rclone sync "${RC}${SOURCE_BUCKET}/${prefix}" "${RC}${STAGING_BUCKET}/${prefix}" --progress
done

info "Verifying with rclone check (compares both buckets' app-data prefixes)..."
CHECK_FAILED=0
for prefix in "${APP_DATA_PREFIXES[@]}"; do
  echo "--- ${prefix}/ ---"
  rclone check "${RC}${SOURCE_BUCKET}/${prefix}" "${RC}${STAGING_BUCKET}/${prefix}" || CHECK_FAILED=1
done
if [ "$CHECK_FAILED" = "1" ]; then
  warn "rclone check found a mismatch on at least one prefix — re-run this script (rclone sync"
  warn "is safe to re-run, only copies diffs) before proceeding."
  exit 1
fi

info "DONE. All app-data prefixes verified identical."
warn "Next manual steps (NOT done by this script):"
warn "  1. Update hiresense-helm-charts/charts/hiresense/values-staging.secrets.yaml"
warn "     secrets.spaces.bucket: \"${STAGING_BUCKET}\" (currently \"${SOURCE_BUCKET}\")"
warn "  2. Update hiresense-helm-charts/charts/interviewhandoff/values-staging.secrets.yaml"
warn "     s3Bucket / recordingS3Bucket: \"${STAGING_BUCKET}\""
warn "  3. Redeploy staging (make upgrade-hiresense-staging / upgrade-interviewhandoff-staging)"
warn "     in one sitting — don't leave the bucket reference mismatched with live traffic."
warn "  4. Only after staging is confirmed healthy on the new bucket for a while: delete the"
warn "     ${APP_DATA_PREFIXES[*]} PREFIXES ONLY from the original \"${SOURCE_BUCKET}\" bucket —"
warn "     NEVER delete the whole bucket, loki/ and tempo/ must stay (monitoring depends on them)."
warn "  ${PROD_BUCKET} is created empty and ready — already referenced by values-prod.secrets.yaml."
