#!/usr/bin/env bash
set -euo pipefail

# Prompts for cluster secrets and applies them via kubectl.
# Leave a value blank to skip that secret.
# Safe to re-run — existing secrets are updated in place.

NAMESPACE="fakestore"

prompt() {
  local label="$1"
  local varname="$2"
  read -r -s -p "$label: " value
  echo
  printf -v "$varname" '%s' "$value"
}

apply_secret() {
  local name="$1"
  shift
  local args=()
  while [[ $# -gt 0 ]]; do
    args+=("--from-literal=$1")
    shift
  done

  kubectl create secret generic "$name" \
    --namespace="$NAMESPACE" \
    "${args[@]}" \
    --dry-run=client -o yaml \
    | kubectl apply -f -
}

echo "=== Fakestore Secrets Setup ==="
echo "Press Enter to skip a secret."
echo

# --- postgres-secret ---
echo "[ postgres + users secrets ]"
echo "  Admin account: fakestore_admin (used by Flyway)"
echo "  Data account:  fakestore_users_user (used by app)"
prompt "PostgreSQL admin password" ADMIN_PASSWORD
prompt "PostgreSQL data-access password" DATA_PASSWORD
prompt "JWT secret (min 32 chars)" JWT_SECRET

POSTGRES_ARGS=()
[[ -n "$ADMIN_PASSWORD" ]] && POSTGRES_ARGS+=("admin-password=$ADMIN_PASSWORD")
[[ -n "$DATA_PASSWORD" ]]  && POSTGRES_ARGS+=("data-password=$DATA_PASSWORD")

if [[ ${#POSTGRES_ARGS[@]} -gt 0 ]]; then
  apply_secret "postgres-secret" "${POSTGRES_ARGS[@]}"
  echo "  -> postgres-secret applied"
else
  echo "  -> skipped"
fi

USERS_ARGS=()
[[ -n "$JWT_SECRET" ]]    && USERS_ARGS+=("JWT_SECRET=$JWT_SECRET")
[[ -n "$DATA_PASSWORD" ]] && USERS_ARGS+=("DB_PASSWORD=$DATA_PASSWORD")
[[ -n "$ADMIN_PASSWORD" ]] && USERS_ARGS+=("DB_ADMIN_PASSWORD=$ADMIN_PASSWORD")

if [[ ${#USERS_ARGS[@]} -gt 0 ]]; then
  apply_secret "users-secret" "${USERS_ARGS[@]}"
  echo "  -> users-secret applied"
else
  echo "  -> skipped"
fi

echo
echo "Done."
