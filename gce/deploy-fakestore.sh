#!/usr/bin/env bash
# Deploys fakestore to the GCE VM.
# Writes .env, uploads docker-compose.yml, pulls images, restarts containers.
# Safe to re-run — all steps are idempotent.
#
# Usage:
#   ./deploy-fakestore.sh        fetch latest releases and show available versions
#   ./deploy-fakestore.sh 7      deploy release 7
#   ./deploy-fakestore.sh 6      rollback to release 6
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASES_DIR="$SCRIPT_DIR/../releases"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/deploy-fakestore.log"

mkdir -p "$LOG_DIR"

# ── No args: fetch and show available releases ────────────────────────────────

if [[ $# -eq 0 ]]; then
  echo "Fetching latest releases..."
  git -C "$SCRIPT_DIR/.." fetch --quiet || \
    echo "  (could not fetch — showing local releases)"
  git -C "$SCRIPT_DIR/.." fetch origin main:main --update-head-ok 2>/dev/null || \
    echo "  (could not fast-forward main — showing local releases)"
  echo

  release_files=$(
    git -C "$SCRIPT_DIR/.." ls-tree --name-only main releases/ 2>/dev/null |
    grep '^releases/v[0-9]*\.yml$' |
    sed 's/.*v\([0-9]*\)\.yml/\1 &/' |
    sort -n |
    awk '{print $2}' |
    tail -10
  )

  if [[ -z "$release_files" ]]; then
    echo "No releases found on main"
    exit 1
  fi

  echo "Recent releases:"
  echo
  while IFS= read -r gitpath; do
    content=$(git -C "$SCRIPT_DIR/.." show "main:$gitpath")
    ver=$(echo "$content" | grep "^version:" | awk '{print $2}')
    services=$(echo "$content" | awk '
      /^  [a-z]/ { svc = $1; gsub(/:/, "", svc) }
      /^    version:/ { printf "  %s:v%s", svc, $2 }
    ')
    printf "  v%-4s %s\n" "$ver" "$services"
  done <<< "$release_files"

  exit 0
fi

# ── Version provided: deploy ──────────────────────────────────────────────────

exec > >(tee -a "$LOG") 2>&1

VERSION_ARG="${1}"
RELEASE_GITPATH="releases/v${VERSION_ARG}.yml"

git -C "$SCRIPT_DIR/.." fetch --quiet 2>/dev/null || true
git -C "$SCRIPT_DIR/.." fetch origin main:main --update-head-ok 2>/dev/null || true

RELEASE_CONTENT=$(git -C "$SCRIPT_DIR/.." show "main:$RELEASE_GITPATH" 2>/dev/null)
if [[ -z "$RELEASE_CONTENT" ]]; then
  echo "ERROR: No release file found for version ${VERSION_ARG}"
  echo "  Looked in git main:$RELEASE_GITPATH"
  echo "  Run ./deploy-fakestore.sh with no args to see available versions."
  exit 1
fi

RELEASE_FILE=$(mktemp)
echo "$RELEASE_CONTENT" > "$RELEASE_FILE"
trap 'rm -f "$RELEASE_FILE"' EXIT

echo "Release: v${VERSION_ARG}"

# ── Load image tags ───────────────────────────────────────────────────────────

get_tag() {
  local service="$1"
  awk -v svc="$service" '
    $0 ~ "^  " svc ":$" { found=1; next }
    found && /^    tag:/ { gsub(/.*tag: */, ""); print; exit }
    found && /^  [a-z]/ { exit }
  ' "$RELEASE_FILE"
}

PAYMENTS_TAG=$(get_tag "payments")
USERS_TAG=$(get_tag "users")
WEBSITE_TAG=$(get_tag "website")
ORDERS_TAG=$(get_tag "orders")
SHIPPING_TAG=$(get_tag "shipping")
NOTIFICATIONS_TAG=$(get_tag "notifications")  # fetched but not deployed (ARM64-only image)
CATALOG_TAG=$(get_tag "catalog")

MISSING_TAGS=()
[[ -z "$PAYMENTS_TAG" ]] && MISSING_TAGS+=("payments")
[[ -z "$USERS_TAG" ]]    && MISSING_TAGS+=("users")
[[ -z "$WEBSITE_TAG" ]]  && MISSING_TAGS+=("website")
[[ -z "$ORDERS_TAG" ]]   && MISSING_TAGS+=("orders")
[[ -z "$SHIPPING_TAG" ]] && MISSING_TAGS+=("shipping")
[[ -z "$CATALOG_TAG" ]]  && MISSING_TAGS+=("catalog")
# NOTIFICATIONS_TAG not checked — notifications excluded from GCE (ARM64-only image)

if [[ ${#MISSING_TAGS[@]} -gt 0 ]]; then
  echo "ERROR: missing tags in release file for: ${MISSING_TAGS[*]}"
  exit 1
fi

echo "Image tags:"
echo "  payments:      $PAYMENTS_TAG"
echo "  users:         $USERS_TAG"
echo "  website:       $WEBSITE_TAG"
echo "  orders:        $ORDERS_TAG"
echo "  shipping:      $SHIPPING_TAG"
echo "  notifications: $NOTIFICATIONS_TAG"
echo "  catalog:       $CATALOG_TAG"
echo

# ── Validate secrets.env ──────────────────────────────────────────────────────

SECRETS_FILE="$SCRIPT_DIR/secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: secrets.env not found."
  echo "  cp $SCRIPT_DIR/secrets.env.example $SECRETS_FILE"
  exit 1
fi

source "$SECRETS_FILE"

MISSING=()
[[ -z "${GCP_PROJECT:-}" ]]                && MISSING+=("GCP_PROJECT")
[[ -z "${VM_ZONE:-}" ]]                    && MISSING+=("VM_ZONE")
[[ -z "${VM_NAME:-}" ]]                    && MISSING+=("VM_NAME")
[[ -z "${JWT_SECRET:-}" ]]                 && MISSING+=("JWT_SECRET")
[[ -z "${PG_ADMIN_PASSWORD:-}" ]]          && MISSING+=("PG_ADMIN_PASSWORD")
[[ -z "${USERS_DB_ADMIN_PASSWORD:-}" ]]    && MISSING+=("USERS_DB_ADMIN_PASSWORD")
[[ -z "${ORDERS_DB_ADMIN_PASSWORD:-}" ]]   && MISSING+=("ORDERS_DB_ADMIN_PASSWORD")
[[ -z "${CATALOG_DB_ADMIN_PASSWORD:-}" ]]  && MISSING+=("CATALOG_DB_ADMIN_PASSWORD")
[[ -z "${USERS_DB_PASSWORD:-}" ]]          && MISSING+=("USERS_DB_PASSWORD")
[[ -z "${ORDERS_DB_PASSWORD:-}" ]]         && MISSING+=("ORDERS_DB_PASSWORD")
[[ -z "${CATALOG_DB_PASSWORD:-}" ]]        && MISSING+=("CATALOG_DB_PASSWORD")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: fill in the following variables in secrets.env before running:"
  for v in "${MISSING[@]}"; do echo "  - $v"; done
  exit 1
fi

# ── Write .env for docker compose ─────────────────────────────────────────────

ENV_FILE=$(mktemp)
trap 'rm -f "$RELEASE_FILE" "$ENV_FILE"' EXIT

cat > "$ENV_FILE" << EOF
PAYMENTS_TAG=$PAYMENTS_TAG
USERS_TAG=$USERS_TAG
WEBSITE_TAG=$WEBSITE_TAG
ORDERS_TAG=$ORDERS_TAG
SHIPPING_TAG=$SHIPPING_TAG
CATALOG_TAG=$CATALOG_TAG
JWT_SECRET=$JWT_SECRET
PG_ADMIN_PASSWORD=$PG_ADMIN_PASSWORD
USERS_DB_ADMIN_PASSWORD=$USERS_DB_ADMIN_PASSWORD
USERS_DB_PASSWORD=$USERS_DB_PASSWORD
ORDERS_DB_ADMIN_PASSWORD=$ORDERS_DB_ADMIN_PASSWORD
ORDERS_DB_PASSWORD=$ORDERS_DB_PASSWORD
CATALOG_DB_ADMIN_PASSWORD=$CATALOG_DB_ADMIN_PASSWORD
CATALOG_DB_PASSWORD=$CATALOG_DB_PASSWORD
PAYMENTS_DB_ADMIN_PASSWORD=${PAYMENTS_DB_ADMIN_PASSWORD:-}
PAYMENTS_DB_PASSWORD=${PAYMENTS_DB_PASSWORD:-}
SHIPPING_DB_ADMIN_PASSWORD=${SHIPPING_DB_ADMIN_PASSWORD:-}
SHIPPING_DB_PASSWORD=${SHIPPING_DB_PASSWORD:-}
EOF

# ── Upload and deploy ─────────────────────────────────────────────────────────

echo "=== Deploy fakestore (GCE) ==="
echo "Log: $LOG"
echo

echo "--- Uploading files ---"
gcloud compute scp "$ENV_FILE" \
  "$VM_NAME:/tmp/fakestore.env" \
  --zone="$VM_ZONE" --project="$GCP_PROJECT"

gcloud compute scp "$SCRIPT_DIR/docker-compose.yml" \
  "$VM_NAME:/tmp/docker-compose.yml" \
  --zone="$VM_ZONE" --project="$GCP_PROJECT"

gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --project="$GCP_PROJECT" -- \
  sudo bash -s << 'REMOTE'
mv /tmp/fakestore.env      /opt/fakestore/.env
mv /tmp/docker-compose.yml /opt/fakestore/docker-compose.yml
chmod 600 /opt/fakestore/.env
REMOTE
echo

echo "--- Pulling images and restarting containers ---"
gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --project="$GCP_PROJECT" -- \
  sudo bash -s << 'REMOTE'
set -euo pipefail
cd /opt/fakestore
docker compose pull
docker compose up -d
REMOTE
echo

echo "=== Deployment complete ==="
echo
echo "Monitor containers:   ./diag.sh"
echo "Check HTTPS:          curl -I https://${DOMAIN:-fakestore.route36.com}"
