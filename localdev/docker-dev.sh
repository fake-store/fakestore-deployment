#!/usr/bin/env bash
# Build users, website, orders, payments locally and run them in Docker.
# Does not require committing, pushing, or merging.
#
# Usage:
#   ./docker-dev.sh            — build all 4 and (re)start them
#   ./docker-dev.sh users      — build + restart only users
#   ./docker-dev.sh website orders  — build + restart a subset
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "ERROR: No .env found. Run start.sh first."
  exit 1
fi

REPO_ROOT="$(cd ../.. &&
  pwd)"
ALL_SERVICES=(users website orders payments)
TAG=dev

TARGETS=("${@:-${ALL_SERVICES[@]}}")

# ── Build ──────────────────────────────────────────────────────────────────────

echo "Building images..."
for svc in "${TARGETS[@]}"; do
  echo -n "  $svc ... "
  docker build -t "ghcr.io/fake-store/fakestore-${svc}:${TAG}" "${REPO_ROOT}/${svc}" -q
  echo "done"
done

# ── Start infra (no-recreate — don't disturb running postgres/kafka) ───────────

echo ""
echo "Starting infrastructure..."
docker compose up -d --no-recreate postgres kafka kafka-ui

# ── Start/recreate target services ────────────────────────────────────────────

echo ""
echo "Starting services..."
USERS_TAG=$TAG WEBSITE_TAG=$TAG ORDERS_TAG=$TAG PAYMENTS_TAG=$TAG \
  docker compose up -d --force-recreate "${TARGETS[@]}"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "  website  -> http://localhost"
echo "  users    -> http://localhost:8081"
echo "  payments -> http://localhost:8082"
echo "  orders   -> http://localhost:8083"
