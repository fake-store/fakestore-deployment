#!/usr/bin/env bash
# Deploys the fakestore app to the k3s cluster.
# Creates the namespace, applies secrets, and deploys all services.
# Requires the cluster to be running (run ./cluster-init.sh first).
# Safe to re-run — all steps are idempotent.
#
# Usage: ./deploy-fakestore.sh
set -euo pipefail

NAMESPACE="fakestore"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$SCRIPT_DIR/../k8s"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/deploy-fakestore.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

# ── Validate secrets.env ──────────────────────────────────────────────────────

SECRETS_FILE="$SCRIPT_DIR/secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: secrets.env not found."
  echo "  cp $SCRIPT_DIR/secrets.env.example $SECRETS_FILE"
  echo "  Then fill in all values and re-run."
  exit 1
fi

source "$SECRETS_FILE"

MISSING=()
[[ -z "${JWT_SECRET:-}" ]]               && MISSING+=("JWT_SECRET")
[[ -z "${PG_ADMIN_PASSWORD:-}" ]]        && MISSING+=("PG_ADMIN_PASSWORD")
[[ -z "${USERS_DB_ADMIN_PASSWORD:-}" ]]  && MISSING+=("USERS_DB_ADMIN_PASSWORD")
[[ -z "${ORDERS_DB_ADMIN_PASSWORD:-}" ]] && MISSING+=("ORDERS_DB_ADMIN_PASSWORD")
[[ -z "${CATALOG_DB_ADMIN_PASSWORD:-}" ]] && MISSING+=("CATALOG_DB_ADMIN_PASSWORD")
[[ -z "${USERS_DB_PASSWORD:-}" ]]        && MISSING+=("USERS_DB_PASSWORD")
[[ -z "${ORDERS_DB_PASSWORD:-}" ]]       && MISSING+=("ORDERS_DB_PASSWORD")
[[ -z "${CATALOG_DB_PASSWORD:-}" ]]      && MISSING+=("CATALOG_DB_PASSWORD")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: fill in the following variables in secrets.env before running:"
  for v in "${MISSING[@]}"; do
    echo "  - $v"
  done
  exit 1
fi

# ── Verify cluster is reachable ───────────────────────────────────────────────

if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found. Run ./cluster-init.sh first."
  exit 1
fi

if ! kubectl cluster-info &>/dev/null 2>&1; then
  echo "ERROR: Cannot reach cluster. Run ./cluster-init.sh first."
  exit 1
fi

# ── Deploy ────────────────────────────────────────────────────────────────────

apply() {
  local target="$1"
  echo "  applying: $target"
  kubectl apply -f "$target"
  echo
}

echo "=== Deploy fakestore ==="
echo "Log: $LOG"
echo

echo "--- Step 1/3: Namespace ---"
apply "$K8S_DIR/namespace.yml"

echo "--- Step 2/3: Secrets ---"
"$SCRIPT_DIR/apply-secrets.sh"

echo "--- Step 3/3: Services ---"
echo "[ storage (requires SSD on pi3) ]"
apply "$K8S_DIR/storage.yml"

echo "[ kafka ]"
apply "$K8S_DIR/kafka/"

echo "[ postgres ]"
apply "$K8S_DIR/postgres/"

echo "[ payments ]"
apply "$K8S_DIR/payments/"

echo "[ users ]"
apply "$K8S_DIR/users/"

echo "[ orders ]"
apply "$K8S_DIR/orders/"

echo "[ shipping ]"
apply "$K8S_DIR/shipping/"

echo "[ notifications ]"
apply "$K8S_DIR/notifications/"

echo "[ website ]"
apply "$K8S_DIR/website/"

echo "[ ingress ]"
apply "$K8S_DIR/ingress.yml"

echo "=== Deployment complete ==="
echo
echo "Monitor rollout:"
echo "  kubectl get pods -n $NAMESPACE -w"
echo
echo "Check service status:"
echo "  ./diag.sh"
