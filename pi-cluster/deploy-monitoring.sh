#!/usr/bin/env bash
# OPTIONAL — monitoring stack is not required to run fakestore.
#
# Deploys Loki + Grafana + Promtail via Helm.
# Run once after cluster-init, or to upgrade the monitoring stack.
# Safe to re-run — helm upgrade --install is idempotent.
#
# Usage: ./deploy-monitoring.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v helm &>/dev/null; then
  echo "ERROR: helm not found. Install and try again."
  exit 1
fi

if [[ "${1:-}" == "--teardown" ]]; then
  echo "=== Teardown monitoring ==="
  helm uninstall loki-stack --namespace monitoring 2>/dev/null || echo "  (loki-stack not installed)"
  kubectl delete -f "$SCRIPT_DIR/../k8s/monitoring/storage.yml" --ignore-not-found
  kubectl delete namespace monitoring --ignore-not-found
  echo "=== Done ==="
  exit 0
fi

K8S_DIR="$SCRIPT_DIR/../k8s/monitoring"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/deploy-monitoring.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

SECRETS_FILE="$SCRIPT_DIR/secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: secrets.env not found."
  exit 1
fi

set -a
source "$SECRETS_FILE"
set +a

if [[ -z "${GRAFANA_PASSWORD:-}" ]]; then
  echo "ERROR: GRAFANA_PASSWORD not set in secrets.env"
  exit 1
fi

echo "=== Deploy monitoring ==="
echo

echo "[ namespace ]"
kubectl apply -f "$K8S_DIR/namespace.yml"
echo

echo "[ storage — ensuring data directory exists on pi3 ]"
ssh -i ~/.ssh/pi_cluster_key -o StrictHostKeyChecking=accept-new \
  "${PI_USER}@192.168.0.163" \
  "sudo mkdir -p /mnt/sata/data/loki"
kubectl apply -f "$K8S_DIR/storage.yml"
echo

echo "[ loki-stack (Helm) ]"
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update grafana

envsubst '${GRAFANA_PASSWORD}' < "$K8S_DIR/loki-stack-values.yml" | \
  helm upgrade --install loki-stack grafana/loki-stack \
    --namespace monitoring \
    --values -
echo

echo "=== Monitoring deployed ==="
echo "Grafana: http://192.168.0.163:30030"
echo "  user: admin"
echo "  pass: (from GRAFANA_PASSWORD in secrets.env)"
echo
echo "Loki is pre-configured as the default datasource."
echo "All pod logs are shipped automatically via Promtail."
