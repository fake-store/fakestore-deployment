#!/usr/bin/env bash
# Creates a GKE Autopilot cluster and fetches kubeconfig.
# Safe to re-run — skips cluster creation if it already exists.
#
# Usage: ./cluster-init.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/cluster-init.log"
SECRETS_FILE="$SCRIPT_DIR/secrets.env"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

# ── Load config ────────────────────────────────────────────────────────────────

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: secrets.env not found."
  echo "  cp $SCRIPT_DIR/secrets.env.example $SECRETS_FILE"
  echo "  Then fill in GCP_PROJECT, GCP_REGION, CLUSTER_NAME."
  exit 1
fi

source "$SECRETS_FILE"

MISSING=()
[[ -z "${GCP_PROJECT:-}" ]] && MISSING+=("GCP_PROJECT")
[[ -z "${GCP_REGION:-}" ]]  && MISSING+=("GCP_REGION")
[[ -z "${CLUSTER_NAME:-}" ]] && CLUSTER_NAME="fakestore"

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: fill in the following variables in secrets.env:"
  for v in "${MISSING[@]}"; do echo "  - $v"; done
  exit 1
fi

# ── Verify gcloud is present and authenticated ────────────────────────────────

if ! command -v gcloud &>/dev/null; then
  echo "ERROR: gcloud not found. Install via: brew install --cask google-cloud-sdk"
  exit 1
fi

if ! gcloud auth print-access-token &>/dev/null 2>&1; then
  echo "Not authenticated. Run:"
  echo "  gcloud auth login"
  echo "  gcloud auth application-default login"
  exit 1
fi

# ── Create cluster (or skip) ──────────────────────────────────────────────────

echo "=== GKE Cluster Init ==="
echo "Project: $GCP_PROJECT"
echo "Region:  $GCP_REGION"
echo "Cluster: $CLUSTER_NAME"
echo

if gcloud container clusters describe "$CLUSTER_NAME" \
    --project="$GCP_PROJECT" \
    --region="$GCP_REGION" \
    --format="value(name)" &>/dev/null 2>&1; then
  echo "Cluster '$CLUSTER_NAME' already exists — fetching credentials only."
  echo
else
  echo "Creating GKE Autopilot cluster '$CLUSTER_NAME'..."
  echo "(This takes 5-10 minutes)"
  echo

  gcloud container clusters create-auto "$CLUSTER_NAME" \
    --project="$GCP_PROJECT" \
    --region="$GCP_REGION" \
    --release-channel=regular

  echo
  echo "Cluster created."
  echo
fi

# ── Fetch kubeconfig ──────────────────────────────────────────────────────────

echo "Fetching kubeconfig..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --project="$GCP_PROJECT" \
  --region="$GCP_REGION"
echo

echo "Cluster is ready."
kubectl cluster-info
echo

echo "Next steps:"
echo "  ./deploy-fakestore.sh        — list available releases"
echo "  ./deploy-fakestore.sh 7      — deploy a specific release"
