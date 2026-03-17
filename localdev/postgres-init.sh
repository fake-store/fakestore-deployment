#!/bin/bash
set -e

# ── fakestore_users ────────────────────────────────────────────────────────────
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER fakestore_users_user WITH PASSWORD '$POSTGRES_DATA_PASSWORD';
    GRANT CONNECT ON DATABASE fakestore_users TO fakestore_users_user;
    GRANT USAGE ON SCHEMA public TO fakestore_users_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fakestore_users_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT EXECUTE ON FUNCTIONS TO fakestore_users_user;
EOSQL

# ── fakestore_orders ───────────────────────────────────────────────────────────
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE fakestore_orders;
    CREATE USER fakestore_orders_user WITH PASSWORD '$POSTGRES_DATA_PASSWORD';
    GRANT CONNECT ON DATABASE fakestore_orders TO fakestore_orders_user;
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "fakestore_orders" <<-EOSQL
    GRANT USAGE ON SCHEMA public TO fakestore_orders_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fakestore_orders_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT EXECUTE ON FUNCTIONS TO fakestore_orders_user;
EOSQL

# ── fakestore_catalog ──────────────────────────────────────────────────────────
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE fakestore_catalog;
    CREATE USER fakestore_catalog_app WITH PASSWORD '$POSTGRES_DATA_PASSWORD';
    GRANT CONNECT ON DATABASE fakestore_catalog TO fakestore_catalog_app;
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "fakestore_catalog" <<-EOSQL
    GRANT USAGE ON SCHEMA public TO fakestore_catalog_app;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fakestore_catalog_app;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT EXECUTE ON FUNCTIONS TO fakestore_catalog_app;
EOSQL
