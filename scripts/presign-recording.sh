#!/usr/bin/env bash
# Generate a presigned DO Spaces URL for one or more recording objects.
# Reads Spaces creds from a values-*.secrets.yaml (default: hiresense prod).
#
# Usage:
#   ./scripts/presign-recording.sh <object-key> [object-key...]
#   ./scripts/presign-recording.sh -e 3600 <object-key>          # custom expiry (seconds)
#   ./scripts/presign-recording.sh -f path/to/secrets.yaml <key> # different secrets file
#
# <object-key> is the path inside the bucket, e.g.:
#   recordings/proctoring/interview-<id>-<timestamp>.mp4
#
# DO Spaces enforces SigV4's 604800s (7 day) max expiry — this script clamps
# to that ceiling rather than emitting a URL DO will reject as MalformedExpires.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MAX_EXPIRES=604800

secrets_file="${REPO_ROOT}/charts/hiresense/values-prod.secrets.yaml"
expires="${MAX_EXPIRES}"

while getopts "f:e:h" opt; do
  case "$opt" in
    f) secrets_file="$OPTARG" ;;
    e) expires="$OPTARG" ;;
    h) echo "Usage: $(basename "$0") [-f secrets.yaml] [-e expiry_seconds] <object-key> [object-key...]"; exit 0 ;;
    *) exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -eq 0 ]]; then
  echo "Usage: $(basename "$0") [-f secrets.yaml] [-e expiry_seconds] <object-key> [object-key...]" >&2
  exit 1
fi

if (( expires > MAX_EXPIRES )); then
  echo "Note: expiry ${expires}s exceeds DO Spaces' ${MAX_EXPIRES}s (7 day) max — clamping." >&2
  expires="${MAX_EXPIRES}"
fi

[[ -f "$secrets_file" ]] || { echo "Secrets file not found: $secrets_file" >&2; exit 1; }

get_field() {
  awk -v key="$1:" '$1 == key { print $2; exit }' "$secrets_file" | tr -d '"'
}

access_key="$(get_field accessKey)"
secret_key="$(get_field secretKey)"
endpoint="$(get_field endpoint)"
region="$(get_field region)"
bucket="$(get_field bucket)"

for field_name in access_key secret_key endpoint region; do
  [[ -n "${!field_name}" ]] || { echo "Missing spaces.$field_name in $secrets_file" >&2; exit 1; }
done

# The URLs this project actually serves recordings from use bucket "hiresense",
# not the "hiresense-prod" value currently in values-prod.secrets.yaml — override
# with -b if the secrets file's bucket field doesn't match what you need.
bucket="${BUCKET_OVERRIDE:-hiresense}"

export AWS_ACCESS_KEY_ID="$access_key"
export AWS_SECRET_ACCESS_KEY="$secret_key"

for key in "$@"; do
  aws s3 presign --endpoint-url "$endpoint" --region "$region" --expires-in "$expires" \
    "s3://${bucket}/${key}"
done
