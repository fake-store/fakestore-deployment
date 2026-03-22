#!/usr/bin/env bash
# Quick cluster status: nodes, pods, services, external IP.
set -euo pipefail

NAMESPACE="fakestore"

echo "=== Nodes ==="
kubectl get nodes -o wide
echo

echo "=== Pods ($NAMESPACE) ==="
kubectl get pods -n "$NAMESPACE" -o wide
echo

echo "=== Services ($NAMESPACE) ==="
kubectl get services -n "$NAMESPACE"
echo

echo "=== External IP ==="
EXTERNAL_IP=$(kubectl get service website-service -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [[ -n "$EXTERNAL_IP" ]]; then
  echo "  http://$EXTERNAL_IP"
else
  echo "  (pending — load balancer not yet provisioned)"
fi
echo

echo "=== Recent events (warnings only) ==="
kubectl get events -n "$NAMESPACE" --field-selector type=Warning \
  --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || true
