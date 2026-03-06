# Turing Pi POC — Cluster Quickstart

This README explains how to flash SD cards for the Pis, boot the cluster, run the setup playbook, and deploy the hello-world DaemonSet (one instance per node). It also lists common troubleshooting steps and where logs are stored.

Prerequisites
- macOS (the `flash_sd.py` script is written for macOS diskutil/dd flows).
- Python 3.11+ installed and `python3` on PATH.
- `ansible` (the runner will attempt a `pip --user` install if missing).
- `kubectl` available locally (the `hello` command uses kubectl; the script will try to use a fetched kubeconfig).
- SD cards and a way to insert them into your Mac (USB adapter).

Repository layout (important files)
- `flash_sd.py` — interactive script to flash Raspberry Pi OS images and configure first-boot settings (static IPs, SSH, first-run script).
- `inventory.ini` — Ansible inventory with Pi hostnames and IPs (update if necessary).
- `cluster_setup_playbook.yml` — Ansible playbook that prepares nodes, installs containerd, installs k3s and joins workers.
- `cluster_diag_playbook.yml` — Diagnostics playbook (collects journals, kubeconfig, etc.).
- `hello-ds.yml` — DaemonSet manifest (one pod per node, hostNetwork: true) that serves a small HTTP page on port 5678.
- `k3s_setup.py` — Playbook runner and helper. Supports commands: `setup`, `diag`, `hello`.
- `remove_hello_playbook.yml` — playbook to remove the hello DaemonSet (optional).
- `tmp/` — runtime folder where logs, kubeconfigs, and artifacts are written (ignored by git).

## 1) Prepare secrets and SSH keys
- Edit `secrets.json` (a template `secrets-template.json` exists)
- Ensure an SSH key exists at `~/.ssh/pi_cluster_key` and `~/.ssh/pi_cluster_key.pub`.  
  - Generate if missing: 
  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/pi_cluster_key -N "" -C pi_cluster_key
  ```

## 2) Flash SD cards (macOS)
#### flash_sd.py
- Download the Raspberry Pi OS image and set `PI_IMAGE` in `flash_sd.py` or put the image at `~/Downloads/` per script default.
- Run the flashing script as root (it performs disk operations and will call `diskutil`/`dd`):
    ```bash
    sudo python3 flash_sd.py
    ```
- The script is interactive: it will list external disks, prompt you to insert an SD, select the device to flash, and then configure boot partition files (ssh enable, `userconf.txt`, `firstrun.sh`, `cmdline.txt` static IP, etc.).
- The script attempts to update your `~/.ssh/known_hosts` entries for the cluster hosts.
- After flashing all SD cards, insert them into the corresponding Raspberry Pis and power them on.

## 3) Run cluster setup (Ansible)
- Run the setup playbook:
    ```bash
    python3 k3s_setup.py setup
    ```

- This will:
  - Install packages and containerd on each Pi.
  - Ensure kernel settings and sysctl tuned for Kubernetes.
  - Install k3s server on the control node (host with `role=server` in `inventory.ini`).
  - Join worker nodes as agents.
- Logs & artifacts:
  - `cluster/tmp/setup.log` — full playbook run output
  - `cluster/tmp/<host>/k3s-journal.txt` — per-host k3s journal on failure
  - `cluster/tmp/kubeconfig-pi1` (or `kubeconfig-<server>`) — fetched admin kubeconfig from server

## 4) Run diagnostics (optional)
- If setup failed or you want to collect logs:
    ```bash
    python3 k3s_setup.py diag
    ```
- This fetches `/etc/rancher/k3s/k3s.yaml` from the server into `cluster/tmp/` and gathers `journalctl` output from nodes.

## 5) Deploy hello-world test
- Use the `hello` helper which applies the `hello-ds.yml` manifest and tests each node by curling `http://<node-ip>:5678`:
    ```bash
    python3 k3s_setup.py hello
    ```

- What `hello` does:
  - Ensures a kubeconfig is available (if not, runs `diag` to fetch it).
  - If the kubeconfig references `127.0.0.1` or `localhost`, the helper rewrites the server URL to the server IP found in `inventory.ini` (writes to `cluster/tmp/kubeconfig-hello`).
  - Runs `kubectl apply -f hello-ds.yml` and waits for the DaemonSet to roll out.
  - Probes each node (based on `inventory.ini` `ansible_host` values) at `http://<node-ip>:5678` and writes results to `cluster/tmp/curl-results.txt`.
  - Writes the list of instance URLs to `cluster/tmp/hello-urls.txt` and a full log to `cluster/tmp/hello.log`.
- Because `hello-ds.yml` uses `hostNetwork: true`, each instance binds directly to the host network and is reachable at `http://<node-ip>:5678`.



