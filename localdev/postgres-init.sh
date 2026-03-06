#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER fakestore_users_user WITH PASSWORD '$POSTGRES_DATA_PASSWORD';
    GRANT CONNECT ON DATABASE fakestore_users TO fakestore_users_user;
    GRANT USAGE ON SCHEMA public TO fakestore_users_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fakestore_users_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT EXECUTE ON FUNCTIONS TO fakestore_users_user;
EOSQL
