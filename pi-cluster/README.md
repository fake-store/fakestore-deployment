# Pi Cluster — Cluster Quickstart

Fakestore runs on a **Turing Pi** cluster with four Raspberry Pi compute modules.
This directory contains all scripts to flash SD cards, initialise the cluster, apply secrets, and deploy services.

## Cluster topology

| Node | IP            | Role                              |
|------|---------------|-----------------------------------|
| pi3  | 192.168.0.163 | k3s control plane + SSD storage   |
| pi1  | 192.168.0.161 | worker                            |
| pi2  | 192.168.0.162 | worker                            |
| pi4  | 192.168.0.164 | worker                            |

**Do not power off pi3** — it is the control plane and Postgres storage node.

---

## Prerequisites

- macOS (`flash_sd.sh` uses `hdiutil`, `diskutil`, `/dev/rdisk`)
- `ansible` and `ansible-playbook` on PATH
- `kubectl` on PATH
- `envsubst` on PATH — install via `brew install gettext`
- SD cards and a USB adapter

---

## Files

| File | Purpose |
|------|---------|
| `flash_sd.sh` | Flash and configure SD cards (macOS, interactive) |
| `cluster-init.sh` | Init bare k3s cluster: Ansible + kubeconfig. Exits early if cluster already running. |
| `deploy-fakestore.sh` | Deploy the app: namespace + secrets + all services. Safe to re-run. |
| `fetch-kubeconfig.sh` | Fetch kubeconfig from pi3 and install to `~/.kube/config` |
| `apply-secrets.sh` | Apply secrets from `secrets.env` (called by deploy-fakestore, useful standalone) |
| `bootstrap-db.sh` | Create service databases, DDL accounts, and app users in Postgres. Run once after first deploy, or after wiping Postgres. Safe to re-run — idempotent. |
| `deploy-monitoring.sh` | Deploy Loki + Grafana + Promtail via Helm. Optional. Pass `--teardown` to remove. |
| `diag.sh` | Run diagnostics playbook, collect logs |
| `inventory.ini` | Ansible inventory (hostnames, IPs, roles) |
| `ansible.cfg` | Ansible config (`host_key_checking = False`) |
| `k3s-install.yml` | Ansible playbook: install k3s, containerd, kernel config |
| `diag.yml` | Ansible playbook: collect journals and diagnostics |
| `secrets.env` | Secret values (gitignored, never committed) |
| `secrets.env.example` | Template — copy to `secrets.env` and fill in |

Logs are written to `.log/` in this directory (gitignored).

---

## 1) Prepare secrets

```bash
cp secrets.env.example secrets.env
# fill in all values
```

Values needed: Pi user credentials, JWT secret, PostgreSQL passwords.
See `secrets.env.example` for the full list.

Ensure an SSH key exists at `~/.ssh/pi_cluster_key`:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/pi_cluster_key -N "" -C pi_cluster_key
```

---

## 2) Flash SD cards

```bash
sudo ./flash_sd.sh
```

- Downloads and configures a temp copy of the Pi OS image via `hdiutil`
- For each node: select the SD card, configure (hostname, static IP, SSH key, first-boot script), write to card
- Clears stale `known_hosts` entries for each node after flashing
- macOS only

After flashing, insert SD cards into the Pis and power on the cluster.
First-boot configuration takes a few minutes.

---

## 3) Initialise the cluster

```bash
./cluster-init.sh
```

Installs k3s on the Pi nodes via Ansible and fetches kubeconfig.
Exits early with next-step instructions if the cluster is already running.

## 4) Deploy fakestore

```bash
./deploy-fakestore.sh        # list available releases
./deploy-fakestore.sh 1      # deploy a specific release
```

Run with no args to pull the latest release manifest and see what's available:

```
Recent releases:
  v1     payments:v1  users:v1  website:v1  orders:v1  shipping:v1  notifications:v1
  v2     payments:v2  users:v1  website:v1  orders:v1  shipping:v1  notifications:v1

To deploy:   ./deploy-fakestore.sh 2
To rollback: ./deploy-fakestore.sh 1   # ** see Rollback section
```

Releases are cut automatically when a service merges to main — the deployment repo
manifest is updated by CI with no manual steps required.

Each release is a snapshot in `../releases/vN.yml`. Only services whose image tag
changed from the previous deploy will be restarted; others are untouched.

## 5) Bootstrap databases

Run once after first deploy, or any time Postgres data is wiped:

```bash
./bootstrap-db.sh
```

Creates each service database, its DDL account (used by Flyway), and its app account (used by
the running service). Safe to re-run — skips anything that already exists.

Services will be in `CrashLoopBackOff` until this completes. They recover automatically on the
next retry once the databases and accounts are in place.

## 6) Monitoring — optional (Loki + Grafana)

If Helm and a Grafana dashboard are desired:

```bash
# Requires: GRAFANA_PASSWORD set in secrets.env, helm on PATH
./deploy-monitoring.sh
```

Deploys Loki (log aggregation), Grafana (UI), and Promtail (log collector DaemonSet on every node).
All pod logs are shipped automatically — no per-service configuration needed.

Grafana is available at **http://192.168.0.163:30030** (user: `admin`).

```bash
./deploy-monitoring.sh --teardown   # remove monitoring stack and storage
```

---

## Individual scripts

```bash
./fetch-kubeconfig.sh  # Re-fetch kubeconfig from pi3 (e.g. after cluster rebuild)
./apply-secrets.sh     # Re-apply secrets (e.g. after rotating a value)
./diag.sh              # Cluster status and pod placement
```

---

## Runbooks

### Rotating a database password

1. Update the password in `secrets.env`
2. Run `apply-secrets.sh` to push the new value into the k8s secret
3. Run `bootstrap-db.sh` — it always syncs passwords via `ALTER USER`, so postgres is updated automatically
4. Restart the affected service pod to pick up the new secret:
   ```bash
   kubectl rollout restart deployment/<service> -n fakestore
   ```

`bootstrap-db.sh` is safe to re-run at any time. It will not touch databases or users that don't need changes, except to sync passwords.

---

### Adding a new service with a database

1. **`secrets.env`** — add `<SERVICE>_DB_ADMIN_PASSWORD` and `<SERVICE>_DB_PASSWORD`
2. **`apply-secrets.sh`** — add a `patch_secret "<service>-secret"` block with the DB passwords (and any other secrets the service needs, e.g. `JWT_SECRET`)
3. **`bootstrap-db.sh`** — add a `bootstrap` call for the new database
4. **`deployment/k8s/<service>/`** — add k8s manifests; `DB_ADMIN_USER` and `DB_USER` in the ConfigMap must match the account names used in `bootstrap-db.sh`
5. **`deploy-fakestore.sh`** — add `export <SERVICE>_TAG`, include it in the envsubst list, and add an `apply_versioned` call
6. **`releases/`** — the new service will appear in the next release cut by CI

Deploy order:
```bash
./deploy-fakestore.sh <N>   # deploys namespace, secrets, and all services
./bootstrap-db.sh           # creates the new DB and accounts
```

Services crash-loop until bootstrap completes — this is expected.

---

## Troubleshooting

**Nodes not reachable after flash:**
First-boot runs `apt update` and installs packages — allow ~5 minutes before the node is SSH-accessible.

**Host key warnings (`REMOTE HOST IDENTIFICATION HAS CHANGED`):**
Pis were reflashed. Remove old entries:
```bash
ssh-keygen -R 192.168.0.161
ssh-keygen -R 192.168.0.162
ssh-keygen -R 192.168.0.163
ssh-keygen -R 192.168.0.164
```
`flash_sd.sh` does this automatically after flashing each card.

**Postgres data lost:**
Services self-recover — Flyway migrations recreate all schemas on startup. Re-register users and re-seed any required data.

**Logs:**
All scripts write to `.log/` in the `pi-cluster/` directory:
- `.log/cluster-init.log`
- `.log/setup.log`
- `.log/apply-secrets.log`
- `.log/deploy-fakestore.log`
- `.log/diag.log`

---

## Rollback

Rolling back redeploys an older release:

```bash
./deploy-fakestore.sh 1   # deploy release 1
```

**Rollback only affects service images — not the database.**

Flyway migrations are applied on startup and are not reversible by rolling back the app image.
If a release includes database migrations, the older image will start, Flyway will detect that the
schema is ahead of its migration scripts, and the service will refuse to start.

The safe release strategy is to decouple schema changes from application changes:

1. **Release the schema change first** — deploy a migration-only release (or a release where the
   app is backwards-compatible with both the old and new schema).
2. **Release the application change second** — once the schema is stable.

If a rollback is needed after step 2 only (no schema change was involved), the older image is
fully compatible with the current database and the rollback is safe.

If a schema change was already applied and the rollback is unavoidable, the database must be
manually rolled back as well — there is no automated path for this.
