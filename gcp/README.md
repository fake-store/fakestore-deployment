# GCP Deployment

> **Note:** This deployment is not currently active. Fakestore migrated to a GCE VM
> (Docker Compose + nginx) to reduce cost from ~$130/month to ~$16/month.
> See [`../gce/`](../gce/) for the active deployment.
>
> This directory is retained as reference — the scripts and manifests are fully functional
> and can be used to bring GKE back up at any time.

Fakestore on **GKE Autopilot** — a fully managed Kubernetes cluster with no node provisioning required.
This directory contains all scripts to create the cluster, apply secrets, and deploy services.

---

## Architecture

```
Internet
  │
  └─► Global Static IP (fakestore-ip)
        │
        └─► GCP HTTP(S) Global Load Balancer  (provisioned by GKE Ingress)
              │  TLS terminated here (Google-managed cert for fakestore.route36.com)
              │
              └─► website-service  (NodePort — only externally exposed service)
                    │
                    ├─► users-service         (ClusterIP, internal only)
                    ├─► payments-service      (ClusterIP, internal only)
                    ├─► orders-service        (ClusterIP, internal only)
                    ├─► shipping-service      (ClusterIP, internal only)
                    ├─► notifications-service (ClusterIP, internal only)
                    └─► catalog-service       (ClusterIP, internal only)

Cluster internals:
  kafka          — StatefulSet, ClusterIP headless, in-cluster message bus
  postgres       — StatefulSet, ClusterIP, shared by users / orders / catalog
```

**What runs in GKE Autopilot:**
- All fakestore services (payments, users, website, orders, shipping, notifications, catalog)
- PostgreSQL StatefulSet (in-cluster — same as pi-cluster)
- Kafka StatefulSet (in-cluster — same as pi-cluster)

**What stays the same:**
- Images are pulled from `ghcr.io/fake-store/` — no changes to CI/CD
- Release files (`releases/v*.yml`) drive deployments — same as pi-cluster
- Secrets pattern — `secrets.env` → `kubectl apply`

**Key differences from pi-cluster:**
| | Pi Cluster | GCP |
|--|--|--|
| Cluster | k3s, self-managed | GKE Autopilot, fully managed |
| Nodes | Raspberry Pi 4 (ARM64) | Google-managed (x86_64) |
| Images | `linux/arm64` | `linux/amd64` (multi-arch images work on both) |
| Storage | `local-storage` (SSD on pi3) | `standard-rwo` (managed Persistent Disk) |
| External access | Traefik Ingress | GKE Ingress + Global Load Balancer |
| TLS | none | Google-managed certificate (auto-provisioned, auto-renewed) |

---

## GCP Account Setup

### 1. Create a project

In the [GCP Console](https://console.cloud.google.com):

1. Create a new project (e.g. `fakestore-prod`) or use an existing one
2. Note the **Project ID** (not display name — it's the unique slug like `fakestore-prod-123456`)
3. Link a billing account to the project

### 2. Enable APIs

Run once (or enable in Console under "APIs & Services"):

```bash
gcloud services enable container.googleapis.com \
  compute.googleapis.com \
  --project=YOUR_PROJECT_ID
```

### 3. Reserve a global static IP

Required for HTTPS with a Google-managed certificate. Must be **global** (not regional).

```bash
gcloud compute addresses create fakestore-ip \
  --global \
  --project=YOUR_PROJECT_ID
```

Point your DNS A record at the resulting IP before deploying — GCP needs to verify domain
ownership to provision the managed certificate.

### 4. GitHub Packages — make images public

GKE nodes need to pull images from `ghcr.io/fake-store/`. The easiest approach:

Go to `https://github.com/orgs/fake-store/packages`, select each package, and under
**Package settings → Danger Zone**, change visibility to **Public**.

If you prefer private packages, create a GitHub PAT with `read:packages` scope and
add `GHCR_TOKEN` to `secrets.env`. The deploy script will create an `imagePullSecret`.

---

## CLI Tools

Install the following on your Mac:

```bash
# Google Cloud SDK — includes gcloud
brew install --cask google-cloud-sdk

# kubectl — Kubernetes CLI (if not already installed)
brew install kubectl

# envsubst — for tag substitution in manifests
brew install gettext
```

After installing `gcloud`, authenticate:

```bash
gcloud auth login
gcloud auth application-default login
```

Verify:

```bash
gcloud version
kubectl version --client
envsubst --version
```

---

## Files

| File | Purpose |
|------|---------|
| `cluster-init.sh` | Create GKE Autopilot cluster and fetch kubeconfig. Exits early if cluster exists. |
| `deploy-fakestore.sh` | Deploy the app: namespace + secrets + all services. Safe to re-run. |
| `apply-secrets.sh` | Apply k8s secrets from `secrets.env`. Called by deploy, useful standalone. |
| `bootstrap-db.sh` | Create service databases, DDL accounts, and app users in Postgres. Idempotent. |
| `diag.sh` | Show cluster health: nodes, pods, services. |
| `secrets.env.example` | Template — copy to `secrets.env` and fill in. |
| `k8s/postgres.yml` | GCP override: no nodeAffinity, `standard-rwo` StorageClass. |
| `k8s/catalog-images-pvc.yml` | GCP override: catalog image storage PVC, `standard-rwo` StorageClass. |
| `k8s/website-service.yml` | GCP override: website-service as `NodePort` (required for GKE Ingress). |
| `k8s/managed-cert.yml` | Google-managed TLS certificate for `fakestore.route36.com`. |
| `k8s/ingress.yml` | GKE Ingress: binds global static IP, managed cert, routes traffic to website-service. |

---

## Deployment Steps

### 1. Prepare secrets

```bash
cp secrets.env.example secrets.env
# fill in all values
```

### 2. Create the cluster

```bash
./cluster-init.sh
```

Creates a GKE Autopilot cluster in the project and region from `secrets.env`.
Fetches kubeconfig into `~/.kube/config`. Takes 5–10 minutes on first run.

### 3. Deploy fakestore

```bash
./deploy-fakestore.sh        # list available releases
./deploy-fakestore.sh 7      # deploy a specific release
```

Applies namespace, secrets, all services, and the GCP load balancer.
The external IP appears under `EXTERNAL-IP` in:

```bash
kubectl get service website-service -n fakestore
```

It may show `<pending>` for a minute while GCP provisions the load balancer.

### 4. Bootstrap databases

Run once after Postgres is ready (after first deploy):

```bash
./bootstrap-db.sh
```

Creates service databases, DDL accounts, and app accounts. Services will
`CrashLoopBackOff` until this completes — they recover automatically.

### 5. Check status

```bash
./diag.sh
```

---

## Image Architecture

The pi-cluster CI/CD builds `linux/arm64` images. GKE Autopilot uses `linux/amd64`.

**To support both clusters**, update each service's `build.yml` to build multi-arch:

```yaml
# In .github/workflows/build.yml, update the build-push-action step:
- name: Build and push
  uses: docker/build-push-action@v6
  with:
    platforms: linux/amd64,linux/arm64   # was: linux/arm64
    push: true
    tags: ${{ steps.meta.outputs.tags }}
```

This increases CI build time (QEMU emulation for the non-native arch) but produces
a single image tag that works on both clusters.

---

## GCP Components and Pricing

All prices are approximate, based on us-central1. Verify current rates at
[cloud.google.com/pricing](https://cloud.google.com/pricing).

### GKE Autopilot
The cluster itself — Google manages all nodes, scaling, and upgrades.

| Charge | Rate | ~Monthly |
|--------|------|----------|
| Cluster management fee | $0.10/hour | ~$73 |
| Pod CPU | $0.0445/vCPU-hour | varies |
| Pod memory | $0.0049/GB-hour | varies |

GKE Autopilot has a minimum per-pod resource floor (0.25 vCPU, 0.5 GB RAM). With 8 active
pods at minimums, expect **~$30–40/month** in pod charges on top of the cluster fee.

> The cluster management fee dominates. **Delete the cluster when not in use** — pod charges
> stop immediately but the $0.10/hour fee runs as long as the cluster exists.

### GCP HTTP(S) Global Load Balancer
Provisioned automatically by the GKE Ingress resource. Handles TLS termination and routes
external traffic into the cluster.

| Charge | Rate | ~Monthly |
|--------|------|----------|
| Forwarding rule (first 5) | $0.025/hour each | ~$18 |
| Ingress data processing | $0.008/GB | negligible at low traffic |

### Global Static IP
The reserved external IP address (`fakestore-ip`).

| State | Rate | ~Monthly |
|-------|------|----------|
| In-use (attached to LB) | free | $0 |
| Unused / released | $0.010/hour | ~$7 (if cluster is deleted but IP is kept) |

> Release the IP if you tear down the cluster permanently:
> `gcloud compute addresses delete fakestore-ip --global --project=YOUR_PROJECT_ID`

### Persistent Disks (standard-rwo = pd-balanced)
Used for PostgreSQL data and catalog image storage.

| Disk | Size | Rate | ~Monthly |
|------|------|------|----------|
| postgres-data | 20 GB | $0.100/GB | ~$2 |
| catalog-images | 20 GB | $0.100/GB | ~$2 |
| kafka-data | 5 GB | $0.100/GB | ~$0.50 |
| **Total** | 45 GB | | **~$4.50** |

PVCs persist after cluster deletion. Delete them explicitly if you want to stop paying:
```bash
kubectl delete pvc --all -n fakestore
```

### Google-Managed SSL Certificate
Free. GCP provisions and auto-renews the TLS cert for `fakestore.route36.com`.

### Container Images (ghcr.io)
Images are stored on GitHub Container Registry (`ghcr.io/fake-store/`), not GCP.
Public packages on ghcr.io are free.

---

### Total Estimated Cost

| Component | ~Monthly |
|-----------|----------|
| GKE cluster management | ~$73 |
| Pod resources (8 pods at minimum) | ~$35 |
| Global Load Balancer | ~$18 |
| Persistent Disks | ~$5 |
| Static IP (in-use) | $0 |
| Managed SSL cert | $0 |
| **Total** | **~$130/month** |

> **To minimize cost:** Delete the cluster between sessions.
> PVCs and the static IP can be kept cheaply (~$5.50/month) so you don't lose data or your IP.

---

## Teardown

```bash
gcloud container clusters delete fakestore \
  --project=YOUR_PROJECT_ID \
  --region=YOUR_REGION
```

Stops all pod and cluster management charges. The static IP and PVCs continue to exist
(and accrue small charges) until deleted explicitly.

---

## Runbooks

### Get the external IP

```bash
kubectl get ingress fakestore-ingress -n fakestore
```

Or check the reserved static IP directly:
```bash
gcloud compute addresses describe fakestore-ip --global --project=YOUR_PROJECT_ID
```

### Check HTTPS / certificate status

```bash
kubectl describe managedcertificate fakestore-cert -n fakestore
```

Certificate status progresses: `Provisioning` → `Active`. Takes 10–15 minutes after DNS
is pointed at the static IP. HTTPS will not work until status is `Active`.

### Rotate a secret

1. Update value in `secrets.env`
2. Run `./apply-secrets.sh`
3. Restart the affected pod: `kubectl rollout restart deployment/<service> -n fakestore`

### View logs

```bash
kubectl logs -n fakestore deployment/website -f
kubectl logs -n fakestore deployment/users -f
```

### Adding a new service with a database

Same process as pi-cluster:
1. Add DB passwords to `secrets.env`
2. Add `patch_secret` block to `apply-secrets.sh`
3. Add `bootstrap` call to `bootstrap-db.sh`
4. Add k8s manifests to `../k8s/<service>/`
5. Add `export <SERVICE>_TAG` and `apply_versioned` call to `deploy-fakestore.sh`
