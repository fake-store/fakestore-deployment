#!/usr/bin/env bash
# Fetches kubeconfig from the k3s control plane (pi3) and installs it at ~/.kube/config.
# Usage: ./fetch-kubeconfig.sh
set -euo pipefail

SERVER_IP="192.168.0.163"
SSH_KEY="$HOME/.ssh/pi_cluster_key"
SSH_USER="pi"
KUBECONFIG_PATH="$HOME/.kube/config"

echo "fetch kubeconfig"
echo "  - connecting to $SSH_USER@$SERVER_IP"
mkdir -p "$HOME/.kube"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" \
  "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/$SERVER_IP/g" \
  > "$KUBECONFIG_PATH"

chmod 600 "$KUBECONFIG_PATH"
echo "  - written to $KUBECONFIG_PATH"
echo ""
kubectl get nodes
