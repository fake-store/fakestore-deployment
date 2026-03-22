#!/usr/bin/env bash
# Bootstraps service databases, DDL accounts, and app users in postgres.
# Run once after postgres is ready and secrets are applied, before deploying services.
# Safe to re-run — all operations are idempotent.
#
# Usage: ./bootstrap-db.sh
set -euo pipefail

NAMESPACE="fakestore"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/bootstrap-db.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

# ── Read credentials from k8s secrets ─────────────────────────────────────────

get_secret() {
  local secret="$1" key="$2"
  kubectl get secret "$secret" -n "$NAMESPACE" \
    -o jsonpath="{.data.$key}" | base64 -d
}

echo "Reading credentials from k8s secrets..."
PG_ADMIN_PASSWORD=$(get_secret "postgres-secret" "admin-password")

USERS_DB_ADMIN_PASSWORD=$(get_secret  "users-secret"   "DB_ADMIN_PASSWORD")
USERS_DB_PASSWORD=$(get_secret        "users-secret"   "DB_PASSWORD")

ORDERS_DB_ADMIN_PASSWORD=$(get_secret "orders-secret"  "DB_ADMIN_PASSWORD")
ORDERS_DB_PASSWORD=$(get_secret       "orders-secret"  "DB_PASSWORD")

CATALOG_DB_ADMIN_PASSWORD=$(get_secret "catalog-secret" "DB_ADMIN_PASSWORD")
CATALOG_DB_PASSWORD=$(get_secret       "catalog-secret" "DB_PASSWORD")

# ── Wait for postgres ──────────────────────────────────────────────────────────

echo "Waiting for postgres-0..."
kubectl wait pod/postgres-0 -n "$NAMESPACE" --for=condition=Ready --timeout=180s
echo

# ── Helpers ────────────────────────────────────────────────────────────────────

psql_admin() {
  local db="$1"
  shift
  kubectl exec -i postgres-0 -n "$NAMESPACE" -- \
    env PGPASSWORD="$PG_ADMIN_PASSWORD" \
    psql -U fakestore_admin -d "$db" -v ON_ERROR_STOP=1 "$@"
}

db_exists() {
  kubectl exec postgres-0 -n "$NAMESPACE" -- \
    env PGPASSWORD="$PG_ADMIN_PASSWORD" \
    psql -U fakestore_admin -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='$1'" | grep -q 1
}

user_exists() {
  kubectl exec postgres-0 -n "$NAMESPACE" -- \
    env PGPASSWORD="$PG_ADMIN_PASSWORD" \
    psql -U fakestore_admin -d postgres -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='$1'" | grep -q 1
}

# ── Bootstrap ──────────────────────────────────────────────────────────────────

bootstrap() {
  local db="$1"
  local ddl_user="$2"
  local ddl_password="$3"
  local app_user="$4"
  local app_password="$5"

  echo "[ $db ]"

  if db_exists "$db"; then
    echo "  database already exists"
  else
    psql_admin postgres -c "CREATE DATABASE $db" > /dev/null
    echo "  created database"
  fi

  if user_exists "$ddl_user"; then
    echo "  ddl user already exists"
  else
    psql_admin postgres <<SQL > /dev/null
CREATE USER $ddl_user WITH PASSWORD '$ddl_password';
GRANT CONNECT ON DATABASE $db TO $ddl_user;
SQL
    echo "  created ddl user"
  fi
  psql_admin postgres -c "ALTER USER $ddl_user WITH PASSWORD '$ddl_password';" > /dev/null

  if user_exists "$app_user"; then
    echo "  app user already exists"
  else
    psql_admin postgres <<SQL > /dev/null
CREATE USER $app_user WITH PASSWORD '$app_password';
GRANT CONNECT ON DATABASE $db TO $app_user;
SQL
    echo "  created app user"
  fi
  psql_admin postgres -c "ALTER USER $app_user WITH PASSWORD '$app_password';" > /dev/null

  psql_admin "$db" <<SQL > /dev/null
GRANT CREATE, USAGE ON SCHEMA public TO $ddl_user;
GRANT ALL ON ALL TABLES IN SCHEMA public TO $ddl_user;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO $ddl_user;

GRANT USAGE ON SCHEMA public TO $app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO $app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO $app_user;

ALTER DEFAULT PRIVILEGES FOR ROLE $ddl_user IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $app_user;
ALTER DEFAULT PRIVILEGES FOR ROLE $ddl_user IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO $app_user;
ALTER DEFAULT PRIVILEGES FOR ROLE $ddl_user IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO $app_user;
SQL
  echo "  granted privileges"
  echo "  [ok]"
  echo
}

# ── Bootstrap each service database ───────────────────────────────────────────

echo "=== Bootstrap databases ==="
echo

bootstrap "fakestore_users" \
  "fakestore_users_admin"  "$USERS_DB_ADMIN_PASSWORD" \
  "fakestore_users_user"   "$USERS_DB_PASSWORD"

bootstrap "fakestore_orders" \
  "fakestore_orders_admin" "$ORDERS_DB_ADMIN_PASSWORD" \
  "fakestore_orders_user"  "$ORDERS_DB_PASSWORD"

bootstrap "fakestore_catalog" \
  "fakestore_catalog_admin" "$CATALOG_DB_ADMIN_PASSWORD" \
  "fakestore_catalog_app"   "$CATALOG_DB_PASSWORD"

echo "=== Done ==="
