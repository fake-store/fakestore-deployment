#!/usr/bin/env bash
# Cluster diagnostics — shows node status and what is running where.
# Usage: ./diag.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/diag.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found. Run ./cluster-init.sh first."
  exit 1
fi

echo "=== Nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== Pods ==="
kubectl get pods -n fakestore -o wide

echo ""
echo "=== Services ==="
kubectl get services -n fakestore

echo ""
echo "Log: $LOG"
