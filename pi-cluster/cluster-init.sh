#!/usr/bin/env bash
# Initialises a bare k3s cluster on the Pi nodes.
# Runs the Ansible setup playbook then fetches kubeconfig.
# Run once after SD cards are flashed and Pis are booted.
#
# If the cluster is already reachable this script exits early —
# run ./deploy-fakestore.sh to deploy the app.
#
# Usage: ./cluster-init.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVENTORY="$SCRIPT_DIR/inventory.ini"
PLAYBOOK="$SCRIPT_DIR/k3s-install.yml"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/cluster-init.log"
# TODO: consider structured log rotation or timestamped log files

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

# ── Already running? ──────────────────────────────────────────────────────────

if kubectl cluster-info &>/dev/null 2>&1; then
  echo "Cluster is already running."
  echo ""
  echo "  Deploy fakestore:     ./deploy-fakestore.sh"
  echo "  Check cluster status: ./diag.sh"
  exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────

if ! command -v ansible-playbook &>/dev/null; then
  echo "ERROR: ansible-playbook not found. Install ansible and try again."
  exit 1
fi

# TODO: SSH into each node in inventory.ini and verify first-boot is complete
# (check /var/lib/firstboot/boot-configured). Exit with clear message if any node not ready.

# ── Run Ansible playbook ──────────────────────────────────────────────────────

echo "=== Cluster Init ==="
echo "Log: $LOG"
echo ""
echo "--- Step 1/2: Ansible setup ---"
echo "Running: ansible-playbook -i $INVENTORY $PLAYBOOK"
echo ""

ansible-playbook -i "$INVENTORY" "$PLAYBOOK"

# ── Fetch kubeconfig ──────────────────────────────────────────────────────────

echo ""
echo "--- Step 2/2: Fetch kubeconfig ---"
"$SCRIPT_DIR/fetch-kubeconfig.sh"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "=== Cluster init complete ==="
echo ""
echo "Verify the cluster with hello-world:"
echo "  ./hello-world/deploy.sh"
echo "  ./hello-world/verify.sh"
echo "  ./hello-world/teardown.sh"
echo ""
echo "Deploy fakestore:"
echo "  ./deploy-fakestore.sh"
echo ""
echo "Check cluster status:"
echo "  ./diag.sh"
