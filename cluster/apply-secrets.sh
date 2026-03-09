#!/usr/bin/env bash
set -euo pipefail

# Prompts for cluster secrets and applies them via kubectl.
# Leave a value blank to skip that individual key — existing keys are preserved.
# Safe to re-run — only the keys you fill in are updated.

NAMESPACE="fakestore"

prompt() {
  local label="$1"
  local varname="$2"
  read -r -s -p "$label: " value
  echo " (${#value} chars)"
  printf -v "$varname" '%s' "$value"
}

# Patches individual keys into a secret without touching other keys.
# Usage: patch_secret <secret-name> key=value [key=value ...]
# Creates the secret if it does not exist yet.
patch_secret() {
  local name="$1"
  shift

  # Ensure the secret exists (create empty shell if needed)
  kubectl get secret "$name" -n "$NAMESPACE" &>/dev/null || \
    kubectl create secret generic "$name" -n "$NAMESPACE"

  # Build JSON data map of base64-encoded values
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

echo "=== Fakestore Secrets Setup ==="
echo "Leave a field blank to skip it — existing values are preserved."
echo

# --- postgres-secret ---
echo "[ postgres-secret ]"
echo "  admin-password : fakestore_admin      (Flyway DDL account)"
echo "  data-password  : fakestore_users_user (app read/write account)"
prompt "PostgreSQL admin password" ADMIN_PASSWORD
prompt "PostgreSQL data-access password" DATA_PASSWORD

POSTGRES_ARGS=()
[[ -n "$ADMIN_PASSWORD" ]] && POSTGRES_ARGS+=("admin-password=$ADMIN_PASSWORD")
[[ -n "$DATA_PASSWORD" ]]  && POSTGRES_ARGS+=("data-password=$DATA_PASSWORD")

if [[ ${#POSTGRES_ARGS[@]} -gt 0 ]]; then
  patch_secret "postgres-secret" "${POSTGRES_ARGS[@]}"
  echo "  -> applied (${#POSTGRES_ARGS[@]} key(s))"
else
  echo "  -> skipped"
fi

# --- JWT secret (shared by users + payments) ---
echo
echo "[ JWT secret (shared by users-secret and payments-secret) ]"
prompt "JWT secret (min 32 chars)" JWT_SECRET

# --- users-secret ---
echo
echo "[ users-secret ]"
echo "  Keys: JWT_SECRET, DB_PASSWORD (data account), DB_ADMIN_PASSWORD (admin account)"
USERS_ARGS=()
[[ -n "$JWT_SECRET" ]]     && USERS_ARGS+=("JWT_SECRET=$JWT_SECRET")
[[ -n "$DATA_PASSWORD" ]]  && USERS_ARGS+=("DB_PASSWORD=$DATA_PASSWORD")
[[ -n "$ADMIN_PASSWORD" ]] && USERS_ARGS+=("DB_ADMIN_PASSWORD=$ADMIN_PASSWORD")

if [[ ${#USERS_ARGS[@]} -gt 0 ]]; then
  patch_secret "users-secret" "${USERS_ARGS[@]}"
  echo "  -> applied (${#USERS_ARGS[@]} key(s))"
else
  echo "  -> skipped"
fi

# --- payments-secret ---
echo
echo "[ payments-secret ]"
echo "  Keys: JWT_SECRET"
PAYMENTS_ARGS=()
[[ -n "$JWT_SECRET" ]] && PAYMENTS_ARGS+=("JWT_SECRET=$JWT_SECRET")

if [[ ${#PAYMENTS_ARGS[@]} -gt 0 ]]; then
  patch_secret "payments-secret" "${PAYMENTS_ARGS[@]}"
  echo "  -> applied (${#PAYMENTS_ARGS[@]} key(s))"
else
  echo "  -> skipped"
fi

echo
echo "Done."
