#!/usr/bin/env bash
# Apply hello-world manifests and wait for rollout.
# Equivalent to deploy.py
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

echo '=== hello-world: deploy ==='
echo ''

echo '[applying manifests]'
kubectl apply -f "$HERE/deploy.yml"
kubectl apply -f "$HERE/ingress.yml"
echo ''

echo '[waiting for rollout]'
if ! kubectl rollout status deployment/hello-world -n hello-world --timeout=120s; then
  echo 'ERROR: rollout did not complete within 120s'
  echo '  kubectl get pods -n hello-world'
  exit 1
fi

echo ''
echo 'Deployment ready. Run verify.sh to check pod distribution.'
echo ''
echo 'To reach the service, add this to /etc/hosts on your Mac:'
echo '  <any-node-ip>  hello.fakestore.local'
echo 'Then: curl http://hello.fakestore.local'
