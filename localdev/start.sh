#!/bin/bash
# Usage:
#   ./start.sh          — start everything; skips services whose port is already in use
#   ./start.sh build    — (re)build all images then start
#   ./start.sh infra    — infrastructure only (Postgres + Kafka) for IDE dev
set -e

cd "$(dirname "$0")"

SERVICES=(users payments orders shipping catalog website)

start_infra() {
  docker compose up -d postgres kafka kafka-ui
}

# Attempt to start a single service. Skips gracefully if the port is already bound.
start_service() {
  local svc="$1"
  local output
  if output=$(docker compose up -d --no-recreate "$svc" 2>&1); then
    echo "  [up]      $svc"
  elif echo "$output" | grep -qiE "address already in use|port is already allocated|bind:"; then
    echo "  [skipped] $svc — port in use (IDE?)"
  else
    echo "  [error]   $svc"
    echo "$output" | sed 's/^/              /'
  fi
}

print_urls() {
  echo ""
  echo "  website     -> http://localhost:8080"
  echo "  users       -> http://localhost:8081"
  echo "  payments    -> http://localhost:8082"
  echo "  orders      -> http://localhost:8083"
  echo "  shipping    -> http://localhost:8084"
  echo "  catalog     -> http://localhost:8085"
  echo "  Kafka UI    -> http://localhost:9094"
}

if [ "${1:-}" = "infra" ]; then
  start_infra
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
  echo "  shipping    -> http://localhost:8084"
  echo "  catalog     -> http://localhost:8085"

elif [ "${1:-}" = "build" ]; then
  docker compose build
  start_infra
  echo "Starting services:"
  for svc in "${SERVICES[@]}"; do
    start_service "$svc"
  done
  print_urls

else
  start_infra
  echo "Starting services:"
  for svc in "${SERVICES[@]}"; do
    start_service "$svc"
  done
  print_urls
fi
