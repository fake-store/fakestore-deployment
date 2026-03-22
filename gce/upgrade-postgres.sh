#!/usr/bin/env bash
# Upgrades the Postgres major version on the GCE VM.
#
# PostgreSQL major version upgrades (e.g. 16 → 17) change the on-disk data
# format. You cannot simply swap the Docker image — the new server will refuse
# to start against old data. This script performs a safe dump/restore upgrade:
#
#   1. Dump all databases from the running (old) Postgres container
#   2. Stop all app services (they'll reconnect once Postgres is back)
#   3. Stop and remove the Postgres container + data volume
#   4. Start Postgres with the new image (pulls automatically via compose)
#   5. Restore the dump
#   6. Restart app services
#
# Usage:
#   ./upgrade-postgres.sh        # uses env vars GCP_PROJECT, VM_ZONE, VM_NAME
#                                # (same vars as deploy-fakestore.sh)
#
# Prerequisites:
#   - secrets.env sourced (PG_ADMIN_PASSWORD must be set)
#   - docker-compose.yml on the VM must already reference the new image tag
#     (run deploy-fakestore.sh first, or the upgrade will restore to the same version)
#
# Safe to re-run if interrupted after step 4 (restore is idempotent on a fresh volume).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/upgrade-postgres.log"
mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG") 2>&1
echo "=== upgrade-postgres.sh $(date) ==="

# ── Load secrets ─────────────────────────────────────────────────────────────
SECRETS="$SCRIPT_DIR/secrets.env"
if [[ ! -f "$SECRETS" ]]; then
  echo "ERROR: $SECRETS not found. Run apply-secrets.sh or create it first."
  exit 1
fi
# shellcheck source=/dev/null
source "$SECRETS"

# ── Validate required vars ───────────────────────────────────────────────────
MISSING=()
[[ -z "${GCP_PROJECT:-}" ]]      && MISSING+=("GCP_PROJECT")
[[ -z "${VM_ZONE:-}" ]]          && MISSING+=("VM_ZONE")
[[ -z "${VM_NAME:-}" ]]          && MISSING+=("VM_NAME")
[[ -z "${PG_ADMIN_PASSWORD:-}" ]] && MISSING+=("PG_ADMIN_PASSWORD")
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: missing required variables: ${MISSING[*]}"
  exit 1
fi

ssh() {
  gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --project="$GCP_PROJECT" -- "$@"
}

DUMP_FILE="/tmp/fakestore-pg-upgrade-$(date +%Y%m%d%H%M%S).sql"

# ── Step 1: Dump ─────────────────────────────────────────────────────────────
echo ""
echo "Step 1/6 — Dumping all databases from running Postgres..."
ssh "docker exec fakestore-postgres pg_dumpall -U fakestore_admin" > "$DUMP_FILE"
DUMP_BYTES=$(wc -c < "$DUMP_FILE")
echo "  Dump complete: $DUMP_FILE (${DUMP_BYTES} bytes)"

if [[ "$DUMP_BYTES" -lt 1000 ]]; then
  echo "ERROR: dump looks too small (${DUMP_BYTES} bytes) — aborting to protect data."
  exit 1
fi

# ── Step 2: Stop app services (keep Postgres running for now) ────────────────
echo ""
echo "Step 2/6 — Stopping app services..."
ssh "cd /opt/fakestore && docker compose stop website users orders payments shipping catalog catalog notifications 2>/dev/null || true"
echo "  App services stopped."

# ── Step 3: Stop and remove Postgres container + volume ─────────────────────
echo ""
echo "Step 3/6 — Removing old Postgres container and data volume..."
ssh "cd /opt/fakestore && docker compose stop postgres && docker compose rm -f postgres"
ssh "docker volume rm fakestore_postgres-data 2>/dev/null || docker volume rm fakestore-postgres-data 2>/dev/null || true"
echo "  Old Postgres removed."

# ── Step 4: Start new Postgres ───────────────────────────────────────────────
echo ""
echo "Step 4/6 — Starting new Postgres (pulls image if needed)..."
ssh "cd /opt/fakestore && docker compose pull postgres && docker compose up -d postgres"
echo -n "  Waiting for Postgres to be healthy"
for i in $(seq 1 30); do
  if ssh "docker exec fakestore-postgres pg_isready -U fakestore_admin -q" 2>/dev/null; then
    echo " ready."
    break
  fi
  echo -n "."
  sleep 2
  if [[ $i -eq 30 ]]; then
    echo ""
    echo "ERROR: Postgres did not become healthy after 60 seconds."
    exit 1
  fi
done

# ── Step 5: Restore dump ─────────────────────────────────────────────────────
echo ""
echo "Step 5/6 — Restoring dump..."
gcloud compute scp "$DUMP_FILE" \
  "$VM_NAME:/tmp/pg-restore.sql" \
  --zone="$VM_ZONE" --project="$GCP_PROJECT"
ssh "docker exec -i fakestore-postgres psql -U fakestore_admin -d postgres < /tmp/pg-restore.sql && rm /tmp/pg-restore.sql"
echo "  Restore complete."

# ── Step 6: Restart app services ─────────────────────────────────────────────
echo ""
echo "Step 6/6 — Restarting app services..."
ssh "cd /opt/fakestore && docker compose up -d"
echo "  All services restarted."

echo ""
echo "Upgrade complete. Dump retained locally at: $DUMP_FILE"
echo "Verify the app is healthy, then delete the dump when satisfied."
