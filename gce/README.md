# GCE Deployment

Fakestore on a **single GCE e2-small VM** running Docker Compose with nginx + Let's Encrypt.
Replaces GKE Autopilot to cut hosting cost from ~$130/month to ~$16/month.

---

## Architecture

```
Internet
  │
  └─► Regional Static IP (fakestore-vm-ip)
        │
        └─► nginx  (VM host, ports 80 + 443)
              │  TLS terminated here (Let's Encrypt cert, auto-renewed by certbot)
              │  HTTP → HTTPS redirect
              │
              └─► website  (Docker container, 127.0.0.1:8080, internal only)
                    │
                    ├─► users        (Docker container, internal only)
                    ├─► payments     (Docker container, internal only)
                    ├─► orders       (Docker container, internal only)
                    ├─► shipping     (Docker container, internal only)
                    └─► catalog      (Docker container, internal only)

Docker network internals:
  kafka     — message bus, internal only
  postgres  — shared by users / orders / catalog, internal only
```

All containers share a single Docker bridge network. Only the website container
is reachable from the host (bound to 127.0.0.1:8080). nginx is the sole public
entry point.

**Key differences from GKE:**
| | GKE Autopilot | GCE VM |
|--|--|--|
| Runtime | Kubernetes | Docker Compose |
| TLS | Google-managed cert | Let's Encrypt (certbot) |
| IP type | Global static | Regional static |
| Scaling | Horizontal (pods) | Single VM |
| Cost | ~$130/month | ~$16/month |

---

## Prerequisites

Install on your Mac:

```bash
# Google Cloud SDK — includes gcloud
brew install --cask google-cloud-sdk
```

Authenticate:

```bash
gcloud auth login
gcloud auth application-default login
```

Enable required GCP APIs (once per project):

```bash
gcloud services enable compute.googleapis.com --project=YOUR_PROJECT_ID
```

---

## Files

| File | Purpose |
|------|---------|
| `vm-init.sh` | One-time VM setup: reserve IP, create VM, install Docker/nginx/certbot, configure HTTPS. |
| `deploy-fakestore.sh` | Deploy a release: upload `.env` + `docker-compose.yml`, pull images, restart containers. |
| `bootstrap-db.sh` | One-time DB setup via `docker exec`. Postgres init script handles this automatically on first start; use this to re-run. |
| `diag.sh` | SSH into VM: container status + website logs. |
| `docker-compose.yml` | All services with heap limits, `restart: always`, internal container-name URLs. |
| `secrets.env.example` | Template — copy to `secrets.env` and fill in. |

---

## Deployment Steps

### 1. Prepare secrets

```bash
cp secrets.env.example secrets.env
# fill in all values
```

### 2. Initialize the VM

```bash
./vm-init.sh
```

This will:
1. Reserve a regional static IP (`fakestore-vm-ip`)
2. Create an e2-small VM (Debian 12, 30 GB disk)
3. Create firewall rules for ports 80 and 443
4. Install Docker, nginx, and certbot
5. Upload `docker-compose.yml` and `postgres-init.sh`
6. Configure nginx as a reverse proxy to `localhost:8080`
7. **Pause** — prompts you to update DNS before continuing
8. Run certbot to obtain a Let's Encrypt certificate

> After step 7, update your DNS A record to point to the new static IP,
> wait for propagation, then press Enter to continue.

Takes ~5 minutes excluding DNS propagation time.

### 3. Deploy fakestore

```bash
./deploy-fakestore.sh        # list available releases
./deploy-fakestore.sh 16     # deploy a specific release
```

Uploads the `.env` and `docker-compose.yml` to the VM, pulls all images, and
starts all containers. First deploy takes a few minutes for image pulls.

### 4. Bootstrap databases

Run once after the first deploy:

```bash
./bootstrap-db.sh
```

Postgres runs `postgres-init.sh` automatically on first container start, which
creates all databases and users. This script is an idempotent fallback if that
fails or needs to be re-run.

### 5. Check status

```bash
./diag.sh
```

---

## Memory

The e2-small has 2 GB RAM. All Spring Boot services set `-Xmx200m` (website: `-Xmx256m`)
and Kafka is capped at `-Xmx200m`. A 2 GB swap file is created during `vm-init.sh` to
handle startup bursts.

Total steady-state memory budget:

| Service | ~RAM |
|---------|------|
| OS + Docker + nginx | ~350 MB |
| postgres | ~200 MB |
| kafka | ~200 MB |
| users | ~200 MB |
| payments | ~200 MB |
| orders | ~200 MB |
| website | ~256 MB |
| shipping (.NET) | ~150 MB |
| catalog (Node) | ~100 MB |
| **Total** | **~1856 MB** |

---

## Pricing

All prices are approximate, based on us-central1.

| Component | Rate | ~Monthly |
|-----------|------|----------|
| e2-small VM | $0.0134/hour | ~$10 |
| 30 GB boot disk (balanced PD) | $0.100/GB | ~$3 |
| Regional static IP (in-use) | free | $0 |
| Egress (low traffic) | ~$0.08/GB | ~$1 |
| Let's Encrypt cert | free | $0 |
| **Total** | | **~$14–16/month** |

---

## Runbooks

### Redeploy (new release)

```bash
./deploy-fakestore.sh 17
```

### View logs

```bash
./diag.sh
# or for a specific service:
gcloud compute ssh fakestore-vm --zone=us-central1-a --project=YOUR_PROJECT_ID -- \
  "sudo docker logs fakestore-users --tail=50 -f"
```

### SSH into VM

```bash
gcloud compute ssh fakestore-vm --zone=us-central1-a --project=YOUR_PROJECT_ID
```

### Rotate a secret

1. Update value in `secrets.env`
2. Run `./deploy-fakestore.sh <version>` — rewrites `.env` on VM and restarts containers

### Renew TLS certificate manually

Certbot auto-renews via a systemd timer. To force renewal:

```bash
gcloud compute ssh fakestore-vm --zone=us-central1-a --project=YOUR_PROJECT_ID -- \
  sudo certbot renew --force-renewal
```

### Resize VM (if OOM)

```bash
gcloud compute instances stop fakestore-vm --zone=us-central1-a
gcloud compute instances set-machine-type fakestore-vm \
  --zone=us-central1-a \
  --machine-type=e2-medium   # 4 GB RAM, ~$26/month
gcloud compute instances start fakestore-vm --zone=us-central1-a
```

### Teardown

```bash
gcloud compute instances delete fakestore-vm --zone=us-central1-a --project=YOUR_PROJECT_ID
gcloud compute addresses delete fakestore-vm-ip --region=us-central1 --project=YOUR_PROJECT_ID
```
