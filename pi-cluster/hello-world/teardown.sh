#!/usr/bin/env bash
# Remove the hello-world namespace and all resources inside it.
# Equivalent to teardown.py
set -euo pipefail

NAMESPACE="hello-world"

echo '=== hello-world: teardown ==='
echo ''

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  echo "Namespace \"$NAMESPACE\" does not exist — nothing to do."
  exit 0
fi

echo "[deleting namespace \"$NAMESPACE\"]"
kubectl delete namespace "$NAMESPACE"
echo ''

echo '[waiting for namespace to terminate]'
for i in $(seq 1 30); do
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo '  Namespace deleted.'
    break
  fi
  echo "  waiting... ($i/30)"
  sleep 2
done

if kubectl get namespace "$NAMESPACE" &>/dev/null; then
  echo "WARNING: namespace still terminating after 60s."
  echo "  kubectl get namespace $NAMESPACE"
  exit 1
fi

echo ''
echo 'Hello-World teardown complete.'
