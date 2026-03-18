#!/bin/bash
# Usage:
#   ./start.sh          — start everything (images must exist; builds if missing)
#   ./start.sh build    — (re)build all images then start
#   ./start.sh infra    — infrastructure only (Postgres + Kafka) for IDE dev
set -e

cd "$(dirname "$0")"

if [ "${1}" = "infra" ]; then
  docker compose up -d postgres kafka kafka-ui
  echo "Infrastructure running:"
  echo "  PostgreSQL  -> localhost:5432  (admin: fakestore_admin / localadminpassword)"
  echo "  Kafka       -> localhost:9091"
  echo "  Kafka UI    -> http://localhost:9094"
  echo ""
  echo "Run services in your IDE on:"
  echo "  website     -> http://localhost:8080"
  echo "  users       -> http://localhost:8081"
  echo "  payments    -> http://localhost:8082"
  echo "  orders      -> http://localhost:8083"
  echo "  catalog     -> http://localhost:8085"
elif [ "${1}" = "build" ]; then
  docker compose build
  docker compose up -d
  echo "All services running:"
  echo "  website     -> http://localhost:8080"
  echo "  users       -> http://localhost:8081"
  echo "  payments    -> http://localhost:8082"
  echo "  orders      -> http://localhost:8083"
  echo "  catalog     -> http://localhost:8085"
  echo "  Kafka UI    -> http://localhost:9094"
  echo ""
  echo "To develop a service in your IDE:"
  echo "  docker compose stop <service>   (e.g. 'website' or 'payments')"
  echo "  Run it in your IDE — it will connect to Docker infra and other containers"
else
  docker compose up -d
  echo "All services running:"
  echo "  website     -> http://localhost:8080"
  echo "  users       -> http://localhost:8081"
  echo "  payments    -> http://localhost:8082"
  echo "  orders      -> http://localhost:8083"
  echo "  catalog     -> http://localhost:8085"
  echo "  Kafka UI    -> http://localhost:9094"
  echo ""
  echo "To develop a service in your IDE:"
  echo "  docker compose stop <service>   (e.g. 'website' or 'payments')"
  echo "  Run it in your IDE — it will connect to Docker infra and other containers"
fi
