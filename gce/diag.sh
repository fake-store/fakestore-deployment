#!/usr/bin/env bash
# Quick VM status: container states and recent website logs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SECRETS_FILE="$SCRIPT_DIR/secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: secrets.env not found."
  exit 1
fi

source "$SECRETS_FILE"

MISSING=()
[[ -z "${GCP_PROJECT:-}" ]] && MISSING+=("GCP_PROJECT")
[[ -z "${VM_ZONE:-}" ]]     && MISSING+=("VM_ZONE")
[[ -z "${VM_NAME:-}" ]]     && MISSING+=("VM_NAME")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: fill in the following variables in secrets.env:"
  for v in "${MISSING[@]}"; do echo "  - $v"; done
  exit 1
fi

gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --project="$GCP_PROJECT" -- \
  sudo bash -s << 'REMOTE'
set -euo pipefail
cd /opt/fakestore

echo "=== Containers ==="
docker compose ps
echo

echo "=== Website logs (last 20 lines) ==="
docker compose logs --tail=20 website
echo

echo "=== External ==="
echo "  https://${DOMAIN:-fakestore.route36.com}"
REMOTE
