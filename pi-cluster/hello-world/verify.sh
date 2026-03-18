#!/usr/bin/env bash
# Verify hello-world deployment:
#   - Shows pod distribution across nodes
#   - Probes each node via ingress Host header
# Equivalent to verify.py
set -euo pipefail

INVENTORY="$(cd "$(dirname "$0")/.." && pwd)/inventory.ini"
NAMESPACE="hello-world"

echo '=== hello-world: verify ==='
echo ''

# Parse ansible_host= values from [pis] section
parse_hosts() {
  awk '
    /^\[pis\]/ { in_section=1; next }
    /^\[/      { in_section=0; next }
    in_section && /ansible_host=/ {
      name = $1
      for (i=2; i<=NF; i++) {
        if ($i ~ /^ansible_host=/) {
          split($i, a, "=")
          print name " " a[2]
        }
      }
    }
  ' "$INVENTORY"
}

HOSTS=()
while IFS= read -r line; do
  HOSTS+=("$line")
done < <(parse_hosts)
if [ ${#HOSTS[@]} -eq 0 ]; then
  echo "ERROR: could not parse hosts from $INVENTORY"
  exit 1
fi

# ── Pod distribution ──────────────────────────────────────────────────────────
echo '[pod distribution]'
pod_output=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)

if [ -z "$pod_output" ]; then
  echo '  No running pods found. Did you run deploy.sh?'
  exit 1
fi

all_node_count=${#HOSTS[@]}
nodes_seen=()

while IFS=' ' read -r pod_name node_name; do
  # track unique nodes
  already=0
  for n in "${nodes_seen[@]:-}"; do [ "$n" = "$node_name" ] && already=1 && break; done
  [ "$already" -eq 0 ] && nodes_seen+=("$node_name")
  echo "  $node_name: $pod_name"
done <<< "$pod_output"

covered=${#nodes_seen[@]}
if [ "$covered" -lt "$all_node_count" ]; then
  echo "  WARNING: pods missing on $(( all_node_count - covered )) node(s)"
else
  echo "  OK — pods spread across all $all_node_count nodes"
fi
echo ''

# ── Ingress probe ─────────────────────────────────────────────────────────────
echo '[ingress probe — Host: hello.fakestore.local]'
echo '  (Traefik listens on port 80 on every node via klipper-lb)'

ok=0
total=${#HOSTS[@]}
for entry in "${HOSTS[@]}"; do
  name=$(echo "$entry" | awk '{print $1}')
  ip=$(echo "$entry" | awk '{print $2}')
  body=$(curl -s --max-time 5 -H "Host: hello.fakestore.local" "http://$ip/" || echo "ERROR: curl failed")
  if [[ "$body" == pod=* ]]; then
    echo "  [OK]   $name ($ip): $body"
    (( ok++ )) || true
  else
    echo "  [FAIL] $name ($ip): $body"
  fi
done

echo ''
if [ "$ok" -eq "$total" ]; then
  echo "All $ok/$total nodes reachable via ingress."
else
  echo "WARNING: only $ok/$total nodes responded successfully."
fi

echo ''
echo 'Redundancy test:'
echo '  Power off pi1, pi2, or pi4 and re-run verify.sh.'
echo '  The remaining nodes should continue serving traffic.'
