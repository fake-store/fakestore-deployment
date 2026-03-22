#!/usr/bin/env bash
# Bootstraps service databases, DDL accounts, and app users in postgres.
# Run once after the first deploy (postgres-init.sh handles this automatically
# on first container start, but this script is useful for re-running if needed).
# Safe to re-run — all operations are idempotent.
#
# Usage: ./bootstrap-db.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/bootstrap-db.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

SECRETS_FILE="$SCRIPT_DIR/secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: secrets.env not found."
  echo "  cp $SCRIPT_DIR/secrets.env.example $SECRETS_FILE"
  exit 1
fi

source "$SECRETS_FILE"

MISSING=()
[[ -z "${GCP_PROJECT:-}" ]] && MISSING+=("GCP_PROJECT")
[[ -z "${VM_ZONE:-}" ]]     && MISSING+=("VM_ZONE")
[[ -z "${VM_NAME:-}" ]]     && MISSING+=("VM_NAME")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: fill in the following variables in secrets.env before running:"
  for v in "${MISSING[@]}"; do echo "  - $v"; done
  exit 1
fi

echo "=== Bootstrap databases ==="
echo "Log: $LOG"
echo

gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --project="$GCP_PROJECT" -- \
  sudo bash -s << 'REMOTE'
set -euo pipefail
cd /opt/fakestore
source .env

psql_admin() {
  local db="$1"; shift
  docker exec -i fakestore-postgres \
    env PGPASSWORD="$PG_ADMIN_PASSWORD" \
    psql -U fakestore_admin -d "$db" -v ON_ERROR_STOP=1 "$@"
}

db_exists() {
  docker exec fakestore-postgres \
    env PGPASSWORD="$PG_ADMIN_PASSWORD" \
    psql -U fakestore_admin -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='$1'" | grep -q 1
}

user_exists() {
  docker exec fakestore-postgres \
    env PGPASSWORD="$PG_ADMIN_PASSWORD" \
    psql -U fakestore_admin -d postgres -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='$1'" | grep -q 1
}

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
REMOTE
