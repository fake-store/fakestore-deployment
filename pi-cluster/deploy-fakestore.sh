#!/usr/bin/env bash
# Deploys the fakestore app to the k3s cluster.
# Creates the namespace, applies secrets, and deploys all services.
# Requires the cluster to be running (run ./cluster-init.sh first).
# Safe to re-run — all steps are idempotent.
#
# Usage:
#   ./deploy-fakestore.sh        fetch latest releases and show available versions
#   ./deploy-fakestore.sh 47     deploy release 47
#   ./deploy-fakestore.sh 46     rollback to release 46
set -euo pipefail

NAMESPACE="fakestore"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$SCRIPT_DIR/../k8s"
RELEASES_DIR="$SCRIPT_DIR/../releases"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/deploy-fakestore.log"

mkdir -p "$LOG_DIR"

# ── No args: fetch and show available releases ────────────────────────────────

if [[ $# -eq 0 ]]; then
  echo "Fetching latest releases..."
  git -C "$SCRIPT_DIR/.." pull --quiet --ff-only 2>/dev/null || \
    echo "  (could not pull — showing local releases)"
  echo

  release_files=$(
    ls "$RELEASES_DIR"/v*.yml 2>/dev/null |
    sed 's/.*v\([0-9]*\)\.yml/\1 &/' |
    sort -n |
    awk '{print $2}' |
    tail -10
  )

  if [[ -z "$release_files" ]]; then
    echo "No releases found in $RELEASES_DIR"
    exit 1
  fi

  echo "Recent releases:"
  echo
  while IFS= read -r file; do
    ver=$(grep "^version:" "$file" | awk '{print $2}')
    services=$(awk '
      /^  [a-z]/ { svc = $1; gsub(/:/, "", svc) }
      /^    version:/ { printf "  %s:v%s", svc, $2 }
    ' "$file")
    printf "  v%-4s %s\n" "$ver" "$services"
  done <<< "$release_files"

  exit 0
fi

# ── Version provided: deploy ──────────────────────────────────────────────────

exec > >(tee -a "$LOG") 2>&1

VERSION_ARG="${1}"
RELEASE_FILE="$RELEASES_DIR/v${VERSION_ARG}.yml"

if [[ ! -f "$RELEASE_FILE" ]]; then
  echo "ERROR: No release file found for version ${VERSION_ARG}"
  echo "  Expected: $RELEASE_FILE"
  echo "  Run ./deploy-fakestore.sh with no args to see available versions."
  exit 1
fi

echo "Release: v${VERSION_ARG}"

# ── Load image tags from release file ─────────────────────────────────────────

get_tag() {
  local service="$1"
  awk -v svc="$service" '
    $0 ~ "^  " svc ":$" { found=1; next }
    found && /^    tag:/ { gsub(/.*tag: */, ""); print; exit }
    found && /^  [a-z]/ { exit }
  ' "$RELEASE_FILE"
}

export PAYMENTS_TAG=$(get_tag "payments")
export USERS_TAG=$(get_tag "users")
export WEBSITE_TAG=$(get_tag "website")
export ORDERS_TAG=$(get_tag "orders")
export SHIPPING_TAG=$(get_tag "shipping")
export NOTIFICATIONS_TAG=$(get_tag "notifications")

echo "Image tags:"
echo "  payments:      $PAYMENTS_TAG"
echo "  users:         $USERS_TAG"
echo "  website:       $WEBSITE_TAG"
echo "  orders:        $ORDERS_TAG"
echo "  shipping:      $SHIPPING_TAG"
echo "  notifications: $NOTIFICATIONS_TAG"
echo

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
[[ -z "${JWT_SECRET:-}" ]]                && MISSING+=("JWT_SECRET")
[[ -z "${PG_ADMIN_PASSWORD:-}" ]]         && MISSING+=("PG_ADMIN_PASSWORD")
[[ -z "${USERS_DB_ADMIN_PASSWORD:-}" ]]   && MISSING+=("USERS_DB_ADMIN_PASSWORD")
[[ -z "${ORDERS_DB_ADMIN_PASSWORD:-}" ]]  && MISSING+=("ORDERS_DB_ADMIN_PASSWORD")
[[ -z "${CATALOG_DB_ADMIN_PASSWORD:-}" ]] && MISSING+=("CATALOG_DB_ADMIN_PASSWORD")
[[ -z "${USERS_DB_PASSWORD:-}" ]]         && MISSING+=("USERS_DB_PASSWORD")
[[ -z "${ORDERS_DB_PASSWORD:-}" ]]        && MISSING+=("ORDERS_DB_PASSWORD")
[[ -z "${CATALOG_DB_PASSWORD:-}" ]]       && MISSING+=("CATALOG_DB_PASSWORD")

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

# Infrastructure (kafka, postgres, etc.) — apply directly, no tag substitution
apply() {
  local target="$1"
  echo "  applying: $target"
  kubectl apply -f "$target"
  echo
}

# App services — substitute image tags from release file before applying
apply_versioned() {
  local file="$1"
  echo "  applying: $file"
  envsubst '${PAYMENTS_TAG} ${USERS_TAG} ${WEBSITE_TAG} ${ORDERS_TAG} ${SHIPPING_TAG} ${NOTIFICATIONS_TAG}' \
    < "$file" | kubectl apply -f -
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
apply_versioned "$K8S_DIR/payments/payments.yml"

echo "[ users ]"
apply_versioned "$K8S_DIR/users/users.yml"

echo "[ orders ]"
apply_versioned "$K8S_DIR/orders/orders.yml"

echo "[ shipping ]"
apply_versioned "$K8S_DIR/shipping/shipping.yml"

echo "[ notifications ]"
apply_versioned "$K8S_DIR/notifications/notifications.yml"

echo "[ website ]"
apply_versioned "$K8S_DIR/website/website.yml"

echo "[ ingress ]"
apply "$K8S_DIR/ingress.yml"

echo "=== Deployment complete ==="
echo

echo "Monitor rollout:"
echo "  kubectl get pods -n $NAMESPACE -w"
echo

echo "Check service status:"
echo "  ./diag.sh"
