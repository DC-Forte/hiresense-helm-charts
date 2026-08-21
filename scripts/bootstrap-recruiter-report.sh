#!/usr/bin/env bash
# =============================================================================
# Recruiter Report — DigitalOcean Infrastructure Bootstrap
#
# Parameterized version of hiresense-infra/scripts/bootstrap.sh, written so
# this SAME script (swap SERVICE, add cluster/registry vars) is what hiresense
# itself would use to gain its own staging/prod split later — see
# RECRUITER_REPORT_EXTRACTION_PLAN.md "Reusable template" section.
#
# Reuses the EXISTING hiresense-cluster and hiresense-registry — this service
# gets its own namespace + own Postgres database, not its own cluster.
#
# Usage: ./bootstrap-recruiter-report.sh <staging|prod> <phase>
#   phases: namespace | postgres | deploy | verify | all
# =============================================================================
set -euo pipefail

SERVICE="recruiter-report"
ENV="${1:?usage: $0 <staging|prod> <namespace|postgres|deploy|verify|all> [image-tag]}"
PHASE="${2:?usage: $0 <staging|prod> <namespace|postgres|deploy|verify|all> [image-tag]}"

case "$ENV" in
  staging|prod) ;;
  *) echo "ENV must be 'staging' or 'prod', got: $ENV" >&2; exit 1 ;;
esac

DO_REGION="${DO_REGION:-fra1}"
CLUSTER_NAME="hiresense-k8s-1-33-9-do-5-fra1"  # shared cluster — also runs kalido/sawit/outline/dc-forte, not hiresense-dedicated
NAMESPACE="${SERVICE}-${ENV}"
# Separate DB cluster per env, matching this account's real naming convention
# (dc-forte-pgsql / dc-forte-dev-pgsql, outline-pgsql, ...) rather than one
# shared cluster with logical databases — consistency with how every other
# product here is actually set up outweighs the marginal cost difference.
PG_CLUSTER_NAME="recruiter-report-pgsql"
DOMAIN_SUFFIX=""
if [ "$ENV" = staging ]; then
  PG_CLUSTER_NAME="recruiter-report-dev-pgsql"
  DOMAIN_SUFFIX="-staging"
fi
PG_DB_NAME="recruiter_report"
DOMAIN="${SERVICE}-api${DOMAIN_SUFFIX}.dc-forte.com"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
require() { command -v "$1" &>/dev/null || { echo -e "${RED}[ERROR]${NC} $1 is required"; exit 1; }; }

for cmd in doctl kubectl helm psql; do require "$cmd"; done
doctl account get &>/dev/null || { warn "Run: doctl auth init"; exit 1; }

setup_namespace() {
  info "Creating namespace $NAMESPACE..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

setup_postgres() {
  info "Ensuring PostgreSQL cluster $PG_CLUSTER_NAME exists..."
  if ! doctl databases list --format Name --no-header | grep -qx "$PG_CLUSTER_NAME"; then
    doctl databases create "$PG_CLUSTER_NAME" \
      --engine pg \
      --version 18 \
      --region "$DO_REGION" \
      --size db-s-1vcpu-1gb \
      --num-nodes 1

    PG_ID=$(doctl databases list --format ID,Name --no-header | grep "$PG_CLUSTER_NAME" | awk '{print $1}')
    info "Waiting for PostgreSQL to come online..."
    until [ "$(doctl databases get "$PG_ID" --format Status --no-header)" = "online" ]; do
      echo -n "."; sleep 15
    done
    echo ""

    K8S_ID=$(doctl kubernetes cluster get "$CLUSTER_NAME" --format ID --no-header)
    doctl databases firewalls append "$PG_ID" --rule "k8s:$K8S_ID"
    info "PostgreSQL cluster ready. PG_ID=$PG_ID"
  else
    info "$PG_CLUSTER_NAME already exists, skipping creation"
    PG_ID=$(doctl databases list --format ID,Name --no-header | grep "$PG_CLUSTER_NAME" | awk '{print $1}')
  fi

  info "Ensuring logical database $PG_DB_NAME exists..."
  doctl databases db create "$PG_ID" "$PG_DB_NAME" 2>/dev/null || info "$PG_DB_NAME already exists"

  warn "MANUAL STEP: 'doctl databases connection' has no --database flag — it always"
  warn "returns the defaultdb URI. Build the $PG_DB_NAME URI from the individual fields:"
  warn "  doctl databases connection $PG_ID --format Host,Port,User,Password --no-header"
  warn "  postgresql://<user>:<password>@<host>:<port>/$PG_DB_NAME?sslmode=require"
  warn "Put it in secrets.databaseUrl in values-${ENV}.secrets.yaml, then run migrations"
  warn "from INSIDE the cluster (the DB firewall only allows k8s traffic) — build"
  warn "cmd/recruiterreportmigrate for linux/amd64, kubectl cp it into a temp pod, and"
  warn "run './recruiterreportmigrate up' with DATABASE_URL set. Same migrate Job the"
  warn "'Run DB migrations' step in .github/workflows/build-recruiterreport.yml runs on"
  warn "every deploy — this manual step is only needed once, before that pipeline exists."
}

deploy_app() {
  local image_tag="${3:-latest}"
  info "Deploying recruiter-report ($ENV, tag: $image_tag)..."
  helm upgrade --install "recruiter-report-${ENV}" ../hiresense-helm-charts/charts/recruiter-report \
    --namespace "$NAMESPACE" \
    --values "../hiresense-helm-charts/charts/recruiter-report/values.yaml" \
    --values "../hiresense-helm-charts/charts/recruiter-report/values-${ENV}.yaml" \
    --values "../hiresense-helm-charts/charts/recruiter-report/values-${ENV}.secrets.yaml" \
    --set image.tag="$image_tag" \
    --atomic \
    --cleanup-on-fail \
    --timeout 10m
  info "Deployed. Point Mobius's caller at https://${DOMAIN} once DNS + cert are ready."
}

verify() {
  info "=== Pods ($NAMESPACE) ==="
  kubectl get pods -n "$NAMESPACE" -o wide
  info "=== Certificate ==="
  kubectl get certificate -n "$NAMESPACE"
  info "=== VirtualService ==="
  kubectl get virtualservice -n "$NAMESPACE"
}

case "$PHASE" in
  namespace) setup_namespace ;;
  postgres)  setup_postgres ;;
  deploy)    deploy_app "$@" ;;
  verify)    verify ;;
  all)
    setup_namespace
    setup_postgres
    warn "Populate values-${ENV}.secrets.yaml (databaseUrl, recruiterReportWebhookUrl, internalServiceToken, encryptionKey, LLM key), run cmd/recruiterreportmigrate up, then run:"
    warn "  ./bootstrap-recruiter-report.sh ${ENV} deploy <image-tag>"
    ;;
  *)
    echo "Usage: $0 <staging|prod> {namespace|postgres|deploy|verify|all} [image-tag]"
    ;;
esac
