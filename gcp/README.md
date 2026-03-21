# GCP Deployment

Fakestore on **GKE Autopilot** — a fully managed Kubernetes cluster with no node provisioning required.
This directory contains all scripts to create the cluster, apply secrets, and deploy services.

---

## Architecture

```
Internet
  │
  └─► GCP HTTP(S) Load Balancer  (created automatically by GKE when website-service type=LoadBalancer)
        │
        └─► website-service  (LoadBalancer — only externally exposed service)
              │
              ├─► users-service      (ClusterIP, internal only)
              ├─► payments-service   (ClusterIP, internal only)
              ├─► orders-service     (ClusterIP, internal only)
              └─► ...

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
| Images | `linux/arm64` | `linux/amd64` — see note below |
| Storage | `local-storage` (SSD on pi3) | `standard-rwo` (managed PD) |
| External access | Traefik Ingress | GCP Load Balancer (type=LoadBalancer) |
| Ingress | Traefik (k3s built-in) | GCP HTTP(S) LB (auto-provisioned) |

> **⚠️ ARM64 vs AMD64:** The pi-cluster builds `linux/arm64` images. GKE Autopilot nodes are
> `linux/amd64`. You will need to update the GitHub Actions build workflows to also push
> `linux/amd64` images (either multi-arch or a separate tag). See **Image Architecture** below.

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

### 3. Reserve a static IP (optional but recommended)

If you want a stable external IP address that survives cluster teardowns:

```bash
gcloud compute addresses create fakestore-ip \
  --project=YOUR_PROJECT_ID \
  --region=YOUR_REGION
```

Then add `fakestore-ip` to `GCP_STATIC_IP_NAME` in `secrets.env`.
Leave `GCP_STATIC_IP_NAME` blank to use an ephemeral IP.

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
| `k8s/website-service.yml` | GCP override: website-service as `LoadBalancer` for external access. |

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

## Teardown

```bash
gcloud container clusters delete fakestore \
  --project=YOUR_PROJECT_ID \
  --region=YOUR_REGION
```

> **Note:** GKE Autopilot charges per pod (CPU + memory), not per node.
> Cost for all fakestore pods at minimum resources is roughly **$15–25/month**.
> Delete the cluster when not in use.

---

## Runbooks

### Get the external IP

```bash
kubectl get service website-service -n fakestore
```

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
