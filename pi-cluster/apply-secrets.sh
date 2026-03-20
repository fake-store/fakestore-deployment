#!/usr/bin/env bash
# Reads secrets from secrets.env and applies them to the cluster. Idempotent.
#
# Usage: ./apply-secrets.sh
#
# Setup: cp secrets.env.example secrets.env, fill in all values.
#        secrets.env is gitignored and never committed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/secrets.env"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/apply-secrets.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: secrets.env not found."
  echo "  cp $SCRIPT_DIR/secrets.env.example $SECRETS_FILE"
  echo "  Then fill in all values and re-run."
  exit 1
fi

# shellcheck source=/dev/null
source "$SECRETS_FILE"

MISSING=()
[[ -z "${JWT_SECRET:-}" ]]              && MISSING+=("JWT_SECRET")
[[ -z "${PG_ADMIN_PASSWORD:-}" ]]       && MISSING+=("PG_ADMIN_PASSWORD")
[[ -z "${USERS_DB_ADMIN_PASSWORD:-}" ]] && MISSING+=("USERS_DB_ADMIN_PASSWORD")
[[ -z "${ORDERS_DB_ADMIN_PASSWORD:-}" ]] && MISSING+=("ORDERS_DB_ADMIN_PASSWORD")
[[ -z "${CATALOG_DB_ADMIN_PASSWORD:-}" ]] && MISSING+=("CATALOG_DB_ADMIN_PASSWORD")
[[ -z "${USERS_DB_PASSWORD:-}" ]]         && MISSING+=("USERS_DB_PASSWORD")
[[ -z "${ORDERS_DB_PASSWORD:-}" ]]        && MISSING+=("ORDERS_DB_PASSWORD")
[[ -z "${CATALOG_DB_PASSWORD:-}" ]]       && MISSING+=("CATALOG_DB_PASSWORD")
[[ -z "${PAYMENTS_DB_ADMIN_PASSWORD:-}" ]] && MISSING+=("PAYMENTS_DB_ADMIN_PASSWORD")
[[ -z "${PAYMENTS_DB_PASSWORD:-}" ]]      && MISSING+=("PAYMENTS_DB_PASSWORD")
[[ -z "${SHIPPING_DB_ADMIN_PASSWORD:-}" ]] && MISSING+=("SHIPPING_DB_ADMIN_PASSWORD")
[[ -z "${SHIPPING_DB_PASSWORD:-}" ]]      && MISSING+=("SHIPPING_DB_PASSWORD")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: fill in the following variables in secrets.env before running:"
  for v in "${MISSING[@]}"; do
    echo "  - $v"
  done
  exit 1
fi

NAMESPACE="fakestore"

patch_secret() {
  local name="$1"
  shift

  kubectl get secret "$name" -n "$NAMESPACE" &>/dev/null || \
    kubectl create secret generic "$name" -n "$NAMESPACE"

  local data=""
  while [[ $# -gt 0 ]]; do
    local key="${1%%=*}"
    local val="${1#*=}"
    local b64
    b64=$(printf '%s' "$val" | base64 | tr -d '\n')
    [[ -n "$data" ]] && data+=","
    data+="\"${key}\":\"${b64}\""
    shift
  done

  kubectl patch secret "$name" -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{${data}}}"
}

echo "=== Fakestore Secrets ==="
echo

patch_secret "postgres-secret" \
  "admin-password=$PG_ADMIN_PASSWORD"
echo "  [ok] postgres-secret"

patch_secret "users-secret" \
  "JWT_SECRET=$JWT_SECRET" \
  "DB_PASSWORD=$USERS_DB_PASSWORD" \
  "DB_ADMIN_PASSWORD=$USERS_DB_ADMIN_PASSWORD"
echo "  [ok] users-secret"

patch_secret "orders-secret" \
  "JWT_SECRET=$JWT_SECRET" \
  "DB_PASSWORD=$ORDERS_DB_PASSWORD" \
  "DB_ADMIN_PASSWORD=$ORDERS_DB_ADMIN_PASSWORD"
echo "  [ok] orders-secret"

patch_secret "payments-secret" \
  "JWT_SECRET=$JWT_SECRET" \
  "DB_PASSWORD=$PAYMENTS_DB_PASSWORD" \
  "DB_ADMIN_PASSWORD=$PAYMENTS_DB_ADMIN_PASSWORD"
echo "  [ok] payments-secret"

patch_secret "website-secret" \
  "JWT_SECRET=$JWT_SECRET"
echo "  [ok] website-secret"

patch_secret "catalog-secret" \
  "DB_PASSWORD=$CATALOG_DB_PASSWORD" \
  "DB_ADMIN_PASSWORD=$CATALOG_DB_ADMIN_PASSWORD"
echo "  [ok] catalog-secret"

patch_secret "shipping-secret" \
  "JWT__SECRET=$JWT_SECRET" \
  "DB__PASSWORD=$SHIPPING_DB_PASSWORD" \
  "DB__ADMIN__PASSWORD=$SHIPPING_DB_ADMIN_PASSWORD"
echo "  [ok] shipping-secret"

echo
echo "Done."
