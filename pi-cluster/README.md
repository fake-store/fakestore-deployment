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
./deploy-fakestore.sh
```

Creates the namespace, applies secrets, and deploys all services.
Safe to re-run — all steps are idempotent.

---

## Individual scripts

```bash
./fetch-kubeconfig.sh  # Re-fetch kubeconfig from pi3 (e.g. after cluster rebuild)
./apply-secrets.sh     # Re-apply secrets (e.g. after rotating a value)
./diag.sh              # Cluster status and pod placement
```

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
