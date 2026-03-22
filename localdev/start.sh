#!/usr/bin/env bash
# Usage:
#   ./start.sh          — start on latest release
#   ./start.sh 4        — start on a specific release version
#   ./start.sh pull     — pull release images then start
#   ./start.sh sync     — fetch latest release files from fakestore-deployment, then start
#   ./start.sh infra    — infrastructure only (Postgres + Kafka) for IDE dev
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "No .env found — created one from .env.example."
  echo "Fill in the values in deployment/localdev/.env, then re-run."
  exit 1
fi

RELEASES_DIR="$(cd .. && pwd)/releases"

# ── Load release tags ──────────────────────────────────────────────────────────

load_release() {
  local version="${1:-}"
  local file

  if [[ -n "$version" ]]; then
    file="$RELEASES_DIR/v${version}.yml"
    if [[ ! -f "$file" ]]; then
      echo "ERROR: release file not found: $file"
      exit 1
    fi
  else
    file=$(ls "$RELEASES_DIR"/v*.yml 2>/dev/null | sed 's/.*v\([0-9]*\)\.yml/\1 &/' | sort -n | tail -1 | awk '{print $2}')
    if [[ -z "$file" ]]; then
      echo "ERROR: no release files found in $RELEASES_DIR"
      exit 1
    fi
  fi

  get_tag() { awk "/^  $1:/,/tag:/" "$file" | grep "tag:" | head -1 | awk '{print $2}'; }

  export PAYMENTS_TAG=$(get_tag "payments")
  export USERS_TAG=$(get_tag "users")
  export WEBSITE_TAG=$(get_tag "website")
  export ORDERS_TAG=$(get_tag "orders")
  export SHIPPING_TAG=$(get_tag "shipping")
  export NOTIFICATIONS_TAG=$(get_tag "notifications")
  export CATALOG_TAG=$(get_tag "catalog")

  local ver
  ver=$(grep "^version:" "$file" | awk '{print $2}')
  echo "Release v${ver}:"
  echo "  users:         $USERS_TAG"
  echo "  payments:      $PAYMENTS_TAG"
  echo "  orders:        $ORDERS_TAG"
  echo "  website:       $WEBSITE_TAG"
  echo "  shipping:      $SHIPPING_TAG"
  echo "  catalog:       $CATALOG_TAG"
  echo "  notifications: $NOTIFICATIONS_TAG"
  echo
}

# ── Helpers ────────────────────────────────────────────────────────────────────

SERVICES=(users payments orders shipping catalog website)

start_infra() {
  docker compose up -d postgres kafka kafka-ui
}

pull_services() {
  for svc in "${SERVICES[@]}"; do
    local output
    if output=$(docker compose pull "$svc" 2>&1); then
      echo "  [pulled]  $svc"
    else
      echo "  [skipped] $svc — $(echo "$output" | grep -o 'no matching manifest[^$]*' | head -1)"
    fi
  done
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
  echo "  website     -> http://localhost"
  echo "  users       -> http://localhost:8081"
  echo "  payments    -> http://localhost:8082"
  echo "  orders      -> http://localhost:8083"
  echo "  shipping    -> http://localhost:8084"
  echo "  catalog     -> http://localhost:8085"
  echo "  Kafka UI    -> http://localhost:9094"
}

# ── Entry point ────────────────────────────────────────────────────────────────

sync_releases() {
  echo "Syncing release files from fakestore-deployment..."
  local api_url="https://api.github.com/repos/fake-store/fakestore-deployment/contents/releases"
  local auth_header=""
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth_header="-H \"Authorization: Bearer $GITHUB_TOKEN\""
  fi

  local files
  files=$(curl -fsSL $auth_header "$api_url" | grep '"name"' | grep -o 'v[0-9]*\.yml' | sort -V)

  if [[ -z "$files" ]]; then
    echo "ERROR: could not fetch release list from GitHub"
    exit 1
  fi

  local count=0
  for name in $files; do
    local dest="$RELEASES_DIR/$name"
    if [[ ! -f "$dest" ]]; then
      curl -fsSL $auth_header \
        "https://raw.githubusercontent.com/fake-store/fakestore-deployment/main/releases/$name" \
        -o "$dest"
      echo "  fetched $name"
      ((count++))
    fi
  done

  if [[ $count -eq 0 ]]; then
    echo "  already up to date"
  else
    echo "  $count new release(s) fetched"
  fi
  echo ""
}

ARG="${1:-}"

if [[ "$ARG" == "infra" ]]; then
  start_infra
  echo "Infrastructure running:"
  echo "  PostgreSQL  -> localhost:5432  (admin: fakestore_admin)"
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

elif [[ "$ARG" == "sync" ]]; then
  sync_releases
  load_release
  pull_services
  start_infra
  echo "Starting services:"
  for svc in "${SERVICES[@]}"; do
    start_service "$svc"
  done
  print_urls

elif [[ "$ARG" == "pull" ]]; then
  load_release
  pull_services
  start_infra
  echo "Starting services:"
  for svc in "${SERVICES[@]}"; do
    start_service "$svc"
  done
  print_urls

elif [[ "$ARG" =~ ^[0-9]+$ ]]; then
  load_release "$ARG"
  start_infra
  echo "Starting services:"
  for svc in "${SERVICES[@]}"; do
    start_service "$svc"
  done
  print_urls

else
  load_release
  start_infra
  echo "Starting services:"
  for svc in "${SERVICES[@]}"; do
    start_service "$svc"
  done
  print_urls
fi
