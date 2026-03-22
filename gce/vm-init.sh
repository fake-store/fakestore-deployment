#!/usr/bin/env bash
# One-time VM setup for fakestore on GCE.
# Creates the VM, installs Docker + nginx + certbot, and configures HTTPS.
#
# Prerequisites:
#   - gcloud CLI installed and authenticated
#   - secrets.env filled in (copy from secrets.env.example)
#   - DNS A record for $DOMAIN must point to the new static IP before certbot runs
#
# Usage: ./vm-init.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/.log"
LOG="$LOG_DIR/vm-init.log"
LOCALDEV_DIR="$SCRIPT_DIR/../localdev"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

# ── Load and validate secrets ──────────────────────────────────────────────────

SECRETS_FILE="$SCRIPT_DIR/secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: secrets.env not found."
  echo "  cp $SCRIPT_DIR/secrets.env.example $SECRETS_FILE"
  exit 1
fi

source "$SECRETS_FILE"

MISSING=()
[[ -z "${GCP_PROJECT:-}" ]]    && MISSING+=("GCP_PROJECT")
[[ -z "${VM_ZONE:-}" ]]        && MISSING+=("VM_ZONE")
[[ -z "${VM_NAME:-}" ]]        && MISSING+=("VM_NAME")
[[ -z "${DOMAIN:-}" ]]         && MISSING+=("DOMAIN")
[[ -z "${CERTBOT_EMAIL:-}" ]]  && MISSING+=("CERTBOT_EMAIL")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: fill in the following variables in secrets.env before running:"
  for v in "${MISSING[@]}"; do echo "  - $v"; done
  exit 1
fi

echo "=== VM Init: fakestore on GCE ==="
echo "Project:  $GCP_PROJECT"
echo "Zone:     $VM_ZONE"
echo "VM:       $VM_NAME"
echo "Domain:   $DOMAIN"
echo "Log:      $LOG"
echo

# ── Step 1: Reserve static IP ─────────────────────────────────────────────────

IP_NAME="${VM_NAME}-ip"
REGION="${VM_ZONE%-*}"  # strip last segment: us-central1-a → us-central1

echo "--- Step 1: Reserve regional static IP ($IP_NAME) ---"
if gcloud compute addresses describe "$IP_NAME" \
    --region="$REGION" --project="$GCP_PROJECT" &>/dev/null; then
  echo "  Static IP already exists — skipping"
else
  gcloud compute addresses create "$IP_NAME" \
    --region="$REGION" \
    --project="$GCP_PROJECT"
  echo "  Created"
fi

STATIC_IP=$(gcloud compute addresses describe "$IP_NAME" \
  --region="$REGION" \
  --project="$GCP_PROJECT" \
  --format="value(address)")
echo "  IP address: $STATIC_IP"
echo

# ── Step 2: Create VM ─────────────────────────────────────────────────────────

echo "--- Step 2: Create VM ($VM_NAME) ---"
if gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$GCP_PROJECT" &>/dev/null; then
  echo "  VM already exists — skipping"
else
  gcloud compute instances create "$VM_NAME" \
    --zone="$VM_ZONE" \
    --project="$GCP_PROJECT" \
    --machine-type=e2-small \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --boot-disk-size=30GB \
    --address="$IP_NAME" \
    --tags=http-server,https-server
  echo "  Created"
fi
echo

# ── Step 3: Firewall rules ────────────────────────────────────────────────────

echo "--- Step 3: Firewall rules ---"
# GCP default network includes default-allow-http (tcp:80, tag: http-server)
# and default-allow-https (tcp:443, tag: https-server). Verify they exist.
for rule in default-allow-http default-allow-https; do
  if gcloud compute firewall-rules describe "$rule" \
      --project="$GCP_PROJECT" &>/dev/null; then
    echo "  $rule: exists"
  else
    echo "  WARNING: $rule not found — you may need to create it manually."
    echo "    gcloud compute firewall-rules create $rule --allow tcp:80 --target-tags http-server"
  fi
done
echo

# ── Step 4: Install Docker, nginx, certbot ────────────────────────────────────

echo "--- Step 4: Configure swap + install software ---"
gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --project="$GCP_PROJECT" -- \
  sudo bash -s << 'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "  Configuring 2GB swap..."
if [[ ! -f /swapfile ]]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "  Updating apt..."
apt-get update -qq

echo "  Installing nginx and certbot..."
apt-get install -y -qq nginx certbot python3-certbot-nginx

echo "  Installing Docker..."
curl -fsSL https://get.docker.com | sh

echo "  Enabling Docker service..."
systemctl enable --now docker

echo "  Creating /opt/fakestore..."
mkdir -p /opt/fakestore
REMOTE
echo

# ── Step 5: Upload files ──────────────────────────────────────────────────────

echo "--- Step 5: Upload docker-compose.yml and postgres-init.sh ---"
gcloud compute scp "$SCRIPT_DIR/docker-compose.yml" \
  "$VM_NAME:/tmp/docker-compose.yml" \
  --zone="$VM_ZONE" --project="$GCP_PROJECT"

gcloud compute scp "$LOCALDEV_DIR/postgres-init.sh" \
  "$VM_NAME:/tmp/postgres-init.sh" \
  --zone="$VM_ZONE" --project="$GCP_PROJECT"

gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --project="$GCP_PROJECT" -- \
  sudo bash -s << 'REMOTE'
mv /tmp/docker-compose.yml /opt/fakestore/docker-compose.yml
mv /tmp/postgres-init.sh   /opt/fakestore/postgres-init.sh
chmod +x /opt/fakestore/postgres-init.sh
REMOTE
echo

# ── Step 6: Configure nginx ───────────────────────────────────────────────────

echo "--- Step 6: Configure nginx ---"

NGINX_CONF=$(mktemp)
cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass         http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
EOF

gcloud compute scp "$NGINX_CONF" \
  "$VM_NAME:/tmp/fakestore-nginx.conf" \
  --zone="$VM_ZONE" --project="$GCP_PROJECT"
rm -f "$NGINX_CONF"

gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --project="$GCP_PROJECT" -- \
  sudo bash -s << 'REMOTE'
mv /tmp/fakestore-nginx.conf /etc/nginx/sites-available/fakestore
ln -sf /etc/nginx/sites-available/fakestore /etc/nginx/sites-enabled/fakestore
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx
REMOTE
echo

# ── Step 7: DNS update prompt ─────────────────────────────────────────────────

echo "============================================================"
echo "  VM is ready. Static IP: $STATIC_IP"
echo
echo "  Before continuing, update your DNS A record:"
echo "    fakestore.route36.com → $STATIC_IP"
echo
echo "  Then wait for DNS to propagate (check with: dig $DOMAIN)"
echo "============================================================"
echo
read -rp "Press Enter once DNS is pointing to $STATIC_IP and propagated..."
echo

# ── Step 8: Obtain TLS certificate ───────────────────────────────────────────

echo "--- Step 8: Obtain TLS certificate (certbot) ---"
gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --project="$GCP_PROJECT" -- \
  sudo certbot --nginx \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$CERTBOT_EMAIL"
echo

# ── Done ──────────────────────────────────────────────────────────────────────

echo "=== VM init complete ==="
echo
echo "Next steps:"
echo "  1. Deploy the app:    ./deploy-fakestore.sh <version>"
echo "  2. Bootstrap the DB:  ./bootstrap-db.sh  (after first deploy)"
echo "  3. Verify:            ./diag.sh"
echo "  4. Check HTTPS:       curl -I https://$DOMAIN"
