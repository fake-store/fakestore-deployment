# hello-world — Cluster Verification Demo

A small HTTP app that demonstrates multi-instance deployment with load balancing and ingress routing on the k3s cluster.

## What it deploys

- **Namespace:** `hello-world`
- **Deployment:** 3 replicas of a busybox httpd, each responding with `pod=<name> node=<node>`
- **topologySpreadConstraints:** one pod per node (k8s enforces spread across pi1/pi2/pi3/pi4)
- **Service:** ClusterIP on port 80
- **Ingress:** Traefik routes `hello.fakestore.local` → service

Each response identifies which pod and node handled the request, making it easy to see load balancing and redundancy in action.

---

## Usage

### 1) Deploy
```bash
./deploy.sh
```

### 2) Verify pod distribution and ingress
```bash
./verify.sh
```

Outputs:
- Pod count per node (confirms topology spread)
- Ingress probe result from every node IP (confirms Traefik routing works cluster-wide)

### 3) Tear down
```bash
./teardown.sh
```

Deletes the `hello-world` namespace and all resources. Cluster returns to bare state.

---

## Accessing via browser (optional)

Add any node IP to `/etc/hosts` on your Mac:
```
192.168.0.161  hello.fakestore.local
```

Then open: `http://hello.fakestore.local`

Refresh repeatedly to see responses from different pods/nodes.

---

## Redundancy test

1. Run `./verify.sh` — confirm all nodes serving.
2. Power off **pi1**, **pi2**, or **pi4** (never pi3 — it's the control plane).
3. Re-run `./verify.sh` — remaining nodes continue serving.
4. Power the node back on; k8s reschedules automatically.
