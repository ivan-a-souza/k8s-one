*[🇧🇷 Português](README.pt-BR.md)*

# K8s-One

A **complete single-node Kubernetes cluster**, built **from scratch** using individual components — no K3s, KIND, kubeadm, or any pre-packaged distribution.

Packaged in a **minimal Debian-based image** via multi-stage build (no package manager at runtime).

```
┌──────────────────────────────────────────────────┐
│                  k8s-one container               │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │   etcd   │  │ apiserver│  │ ctrl-mgr │       │
│  └──────────┘  └──────────┘  └──────────┘       │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │scheduler │  │  kubelet │  │kube-proxy│       │
│  └──────────┘  └──────────┘  └──────────┘       │
│  ┌──────────┐  ┌──────────┐                      │
│  │containerd│  │   runc   │                      │
│  └──────────┘  └──────────┘                      │
│                                                  │
│  CNI: Cilium  │  DNS: CoreDNS                    │
│  Storage: Rook-Ceph (RBD + CephFS)               │
│  Ingress: HAProxy (Host ports 8082/8443)         │
│  Metrics: metrics-server (metrics.k8s.io API)    │
└──────────────────────────────────────────────────┘
```

---

## Table of Contents

- [Quick Start](#quick-start)
- [Components](#components)
- [Architecture](#architecture)
- [Persistent Volumes](#persistent-volumes)
- [Configuration](#configuration)
- [Secrets](#secrets)
- [Cluster Access](#cluster-access)
- [Usage Examples](#usage-examples)
- [Project Structure](#project-structure)
- [Startup Sequence](#startup-sequence)
- [PKI & Certificates](#pki--certificates)
- [Networking](#networking)
- [Storage](#storage)
- [Known Issues](#known-issues)
- [Customization](#customization)
- [Troubleshooting](#troubleshooting)
- [Requirements](#requirements)
- [Limitations](#limitations)

---

## Quick Start

Copy `.env.example` to `.env` and set this machine's Tailscale IP address
(`tailscale ip -4`):

```dotenv
ARGOCD_VERSION=v3.5.1
TAILSCALE_IP=100.x.y.z
```

Docker Compose loads this file automatically. It is ignored by Git so each
environment can choose its Argo CD version and Tailscale address.

```bash
# Build
docker compose build

# Start
docker compose up -d

# Follow startup logs (~2-3 min on first run)
docker compose logs -f

# Get kubeconfig
docker cp k8s-one:/etc/kubernetes/admin-external.conf ./kubeconfig

# Use it
export KUBECONFIG=./kubeconfig
kubectl get nodes
kubectl get pods -A
```

**Expected output:**

```
NAME      STATUS   ROLES    AGE   VERSION
k8s-one   Ready    <none>   2m    v1.36.0

NAMESPACE            NAME                                       READY   STATUS
kube-system          cilium-operator-...                          1/1     Running
kube-system          cilium-...                                   1/1     Running
kube-system          coredns-...                                 1/1     Running
rook-ceph            rook-ceph-operator-...                       1/1     Running
rook-ceph            rook-ceph-mon-a-...                          1/1     Running
rook-ceph            rook-ceph-mgr-a-...                          1/1     Running
rook-ceph            rook-ceph-osd-0-...                          1/1     Running
haproxy-controller   haproxy-kubernetes-ingress-...               1/1     Running
```

---

## Components

All binaries are downloaded from official sources during build. No pre-packaged components are used.

| Component | Version | Source | Role |
|---|---|---|---|
| **kube-apiserver** | v1.36.0 | dl.k8s.io | Kubernetes REST API |
| **kube-controller-manager** | v1.36.0 | dl.k8s.io | Controllers (replication, endpoints, etc.) |
| **kube-scheduler** | v1.36.0 | dl.k8s.io | Pod scheduling on nodes |
| **kubelet** | v1.36.0 | dl.k8s.io | Node agent, manages containers |
| **kube-proxy** | v1.36.0 | dl.k8s.io | Network proxy (iptables mode) |
| **kubectl** | v1.36.0 | dl.k8s.io | CLI for cluster interaction |
| **etcd** | v3.5.21 | github.com/etcd-io | Cluster key-value store |
| **containerd** | 1.7.27 | github.com/containerd | Container runtime (CRI) |
| **runc** | v1.2.6 | github.com/opencontainers | OCI runtime |
| **CNI plugins** | v1.6.2 | github.com/containernetworking | Base network plugins |
| **Cilium** | v1.19.5 | github.com/cilium/cilium | CNI — networking + network policy (eBPF) |
| **Cilium CLI** | v0.19.4 | github.com/cilium/cilium-cli | Cilium installation & management |
| **CoreDNS** | v1.12.0 | registry.k8s.io | Cluster DNS |
| **Rook** | v1.20.3 | github.com/rook/rook | Ceph operator (CRDs, operator, CSI) |
| **Ceph** | v20.2.2 | quay.io/ceph/ceph | Storage daemons (mon, mgr, osd, mds) |
| **Ceph CSI** | v3.17.0 | quay.io/cephcsi | CSI drivers (RBD block + CephFS) |
| **HAProxy Ingress** | pinned by digest | haproxytech/kubernetes-ingress | Ingress Controller (HAProxy 3.2.21) |
| **metrics-server** | v0.9.0 (pinned by digest) | registry.k8s.io | metrics.k8s.io API — kubectl top / HPA |

---

## Architecture

### Multi-Stage Build (Minimal runtime)

```
┌─────────────────────────────────────┐
│  Stage 1: Builder (alpine:3.21)     │
│                                     │
│  • curl, tar, gzip                  │
│  • Downloads all binaries           │
│  • Downloads Rook manifests         │
│  • Discarded in final image         │
└──────────────┬──────────────────────┘
               │ COPY binaries
               ▼
┌─────────────────────────────────────┐
│  Stage 2: Runtime (debian:bookworm) │
│                                     │
│  • bash, openssl, iptables, udev    │
│  • losetup, socat, conntrack        │
│  • apt/dpkg removed at build        │
│  • = minimal image, no pkg manager  │
└─────────────────────────────────────┘
```

The final image **has no package manager** — `apt`/`dpkg` are removed after installing runtime dependencies, reducing the attack surface.

### Startup Process

The `entrypoint.sh` orchestrates the control-plane processes, the Ceph OSD loop device, and manifest deployment:

```
entrypoint.sh
├── setup_mounts()        # mount --make-rshared /, /sys, bpf (Cilium)
├── detect_ip()           # detects container IP
├── generate_pki()        # generates 3 CAs + 11 certs + SA keys
├── generate_kubeconfigs() # generates 6 kubeconfigs
│
├── containerd ──────────▶ waits for socket
├── etcd ────────────────▶ waits for health (via etcdctl + TLS)
├── kube-apiserver ──────▶ waits for /healthz
├── kube-controller-manager
├── kube-scheduler
├── kubelet
├── kube-proxy
│
├── setup_ceph_osd_loop() # creates/attaches /dev/loop0 ← osd.img (30G sparse)
├── start_udevd()         # udev + RBD device-node watcher
│
└── apply_manifests() [background]
    ├── taint removal (allows workloads)
    ├── cilium install (CNI, clean reinstall every boot)
    ├── waits for Node Ready
    ├── kubectl apply -f coredns/
    ├── kubectl apply rook CRDs + common + CSI operator + operator
    ├── patches ROOK_CEPH_ALLOW_LOOP_DEVICES=true (verified)
    ├── kubectl apply -k ceph/ (Ceph cluster + pools + SC + dashboard)
    ├── kubectl apply -f haproxy-ingress/
    └── kubectl apply -f metrics-server/
```

---

## Persistent Volumes

All cluster state is stored in **bind mounts** under `./data/`, ensuring persistence across restarts and making the data directly visible/backable on the host:

| Host Path | Container Mount | Contents |
|---|---|---|
| `./data/etcd/` | `/var/lib/etcd` | etcd data (cluster state) |
| `./data/containerd/` | `/var/lib/containerd` | Images and containers |
| `./data/kubelet/` | `/var/lib/kubelet` | Kubelet state and pods |
| `./data/pki/` | `/etc/kubernetes/pki` | TLS certificates (CAs, certs, keys) |
| `./data/kubernetes/` | `/etc/kubernetes` | Kubeconfigs (admin, scheduler, etc.) |
| `./data/rook/` | `/var/lib/rook` | Ceph data: OSD image + keyrings |

Additionally, the container bind-mounts host system paths:

| Host Path | Container Path | Mode | Reason |
|---|---|---|---|
| `/sys` | `/sys` | `rw` | Cilium BPF, cgroups |
| `/lib/modules` | `/lib/modules` | `ro` | Kernel modules (iptables, etc.) |

> ⚠️ `./data/` and `./data/rook/` contain cluster secrets (Ceph keyrings, PKI private keys, kubeconfigs). Both are **gitignored** — never commit them.

### Clean everything

```bash
docker compose down -v   # removes container + named volumes (bind mounts under ./data/ and ./data/rook/ are kept)
# To fully wipe cluster data: rm -rf data/* data/rook/*   (irreversible!)
```

---

## Configuration

### Build Args

All versions are configurable via build args in the Dockerfile:

```bash
# Use a specific Kubernetes version
docker compose build --build-arg KUBE_VERSION=v1.35.0

# Use a specific Cilium version
docker compose build --build-arg CILIUM_VERSION=v1.18.0

# Build for arm64 (untested)
docker compose build --build-arg TARGETARCH=arm64
```

| Build Arg | Default | Description |
|---|---|---|
| `KUBE_VERSION` | `v1.36.0` | Kubernetes version |
| `ETCD_VERSION` | `v3.5.21` | etcd version |
| `CONTAINERD_VERSION` | `1.7.27` | containerd version |
| `RUNC_VERSION` | `v1.2.6` | runc version |
| `CNI_VERSION` | `v1.6.2` | CNI plugins version |
| `CILIUM_VERSION` | `v1.19.5` | Cilium version |
| `CILIUM_CLI_VERSION` | `v0.19.4` | Cilium CLI version |
| `ROOK_VERSION` | `v1.20.3` | Rook operator version (manifests downloaded from this tag) |
| `TARGETARCH` | `amd64` | Target architecture |

> The **Ceph image version** is set in `manifests/built-in/ceph/01-ceph-cluster.yaml` (`quay.io/ceph/ceph:v20.2.2` — pinned to the version officially tested with Rook 1.20.3; do **not** use the floating `:v20` tag).

### Environment Variables (runtime)

| Variable | Default | Description |
|---|---|---|
| `NODE_NAME` | `k8s-one` | Node name in the cluster |
| `ROOK_OSD_SIZE` | `30G` | Size of the sparse OSD image (`/var/lib/rook/osd.img`) |
| `ARGOCD_VERSION` | `v3.5.1` | Argo CD version installed at boot (format: `vX.Y.Z`) |

Set `ARGOCD_VERSION` in the root `.env` file. After changing it, recreate the
container so the selected version is applied during startup:

```bash
docker compose up -d --force-recreate
```

### Network Parameters (entrypoint.sh)

| Parameter | Value | Description |
|---|---|---|
| `CLUSTER_CIDR` | `192.168.0.0/16` | Pod CIDR (Cilium auto-detects from controller-manager) |
| `SERVICE_CIDR` | `10.96.0.0/12` | ClusterIP CIDR |
| `CLUSTER_DNS` | `10.96.0.10` | CoreDNS IP |

### Resource Reserves (kubelet)

The kubelet advertises the **host's** memory as node capacity (the container has no
memory limit of its own), so the reserves below are how the cluster tells the
scheduler the truth: they deliberately "lie downward" so that pods get a realistic
budget while the host stays protected.

| Setting | Value | Effect |
|---|---|---|
| `systemReserved` | `750m` / `12Gi` | Reserved for the host's own workload (desktop session, daemons) |
| `kubeReserved` | `250m` / `2Gi` | Reserved for control plane + runtime (etcd, apiserver, kubelet, containerd) |
| `evictionHard` | `memory.available: 1Gi` | Kubelet starts evicting pods below this |
| `enforceNodeAllocatable` | `[pods]` | Makes the kubelet write the reserves into the `kubepods` cgroup (see below for what actually lands there) |

On a 4 CPU / 23.2 GiB host that resolves to:

```
capacity         4 cpu      24346668Ki (23.2 GiB)
 - kubeReserved    250m        2 GiB
 - systemReserved  750m       12 GiB
 - evictionHard      --        1 GiB
 = allocatable     3 cpu      ~8.2 GiB   <- the scheduling budget
```

Three consequences worth internalising:

- **`kubectl top nodes` reports more than 100% memory.** `/proc/meminfo` is not
  namespaced, so the kubelet reads the *host's* usage while the denominator is the
  8.2 GiB allocatable. A figure like `207%` is not a leak — it is the entire desktop.
- **Memory has exactly one hard cap, and it is ~9.2 GiB — not the allocatable 8.2 GiB.**
  `enforceNodeAllocatable` makes the kubelet set `memory.max` on the `kubepods` cgroup
  to *capacity − reserves* (`9898602496` = 9440 MiB), and the scheduler's 8.2 GiB is
  that figure minus the 1 GiB eviction margin. The cgroup driver is `cgroupfs`, so the
  path is `/sys/fs/cgroup/kubepods` (no `.slice`). The container itself is unbounded
  (`Memory: 0`), and control-plane processes run *outside* `kubepods`, covered only by
  the `systemReserved` reservation — not by an enforced limit.
- **CPU has no cap at any layer.** `cpu.max` is unset (`max 100000`) on both the
  container and on `kubepods`, so pods can burst past the 3 CPU allocatable whenever
  the host has idle cycles. Only *scheduling* is bounded by the 3 CPU — consumption
  is not.

**Requests are the scheduling budget.** The node's requests are what block rollouts:
when they approach allocatable, a `maxSurge` replacement pod cannot be placed and
matches `0/1 nodes are available: 1 Insufficient cpu`. Actual usage is far below
requests here, so keep an eye on the ratio — and remember that chart-injected
sidecars (e.g. Yugabyte's `ybCleanup`) add requests that do not appear in the
values you wrote.

The config is written by `write_kubelet_config()` in `scripts/entrypoint.sh` to
`/var/lib/kubelet/config.yaml`, which lives on the `./data/kubelet` bind mount and
therefore **persists across container restarts**. The function regenerates the file
at boot whenever its content differs from the heredoc (keeping a timestamped
`.bak`). A running kubelet does not reload its config, so **changes take effect only
after a container restart**.

> Do not shrink `systemReserved` to raise allocatable. It exists precisely because
> the node shares RAM with the desktop; pods are expected to fit in ~8 GiB.

---

## Secrets

No credential is versioned. Values live in `manifests/**/secrets/` (ignored by
`.gitignore`) and are applied to the cluster by `scripts/create-secrets.sh`.
The Argo CD Applications only **reference** the Secrets via `existingSecret` —
they never contain a password.

### Where they live

| Secret | Namespace | Source file (gitignored) | Used by |
|---|---|---|---|
| `authentik-config` | `platform` | `manifests/argocd/authentik/secrets/authentik.env` | `authentik.existingSecret` |
| `authentik-postgresql-auth` | `platform` | `manifests/argocd/authentik/secrets/postgresql-auth.yaml` | `postgresql.auth.existingSecret` |
| `grafana-admin` | `monitoring` | `manifests/argocd/prometheus-stack/secrets/grafana-admin.yaml` | `grafana.admin.existingSecret` |
| `litellm-env` | `platform` | `manifests/argocd/litellm/secrets/litellm.env` | `litellm.environmentSecrets` |
| `litellm-db` | `platform` | `manifests/argocd/litellm/secrets/litellm-db.yaml` | `litellm.db.secret` |
| `litellm-masterkey` | `platform` | `manifests/argocd/litellm/secrets/litellm-masterkey.yaml` | `litellm.masterkeySecretName` |
| `mkcert-ca` | `cert-manager` | `manifests/built-in/cert-manager/secrets/mkcert-ca.yaml` | root CA for ClusterIssuer `local-ca` |

Formats:
- `*.env` → created with `kubectl create secret generic --from-env-file` (e.g. `authentik.env`).
- `*.yaml` → a `kind: Secret` manifest (with `stringData`) applied with `kubectl apply -f`.

> **One credential, two secrets.** `authentik-config` also carries the OIDC client credentials that LiteLLM authenticates with (`LITELLM_OIDC_CLIENT_ID` / `LITELLM_OIDC_CLIENT_SECRET`) — they must be the **same values** as `GENERIC_CLIENT_ID` / `GENERIC_CLIENT_SECRET` in `litellm-env`. Whoever registers the client (the blueprint) and whoever presents it (the proxy) are different apps, so the pair has to exist on both sides: rotate one, rotate both.

### Create/update

```bash
scripts/create-secrets.sh          # idempotent; uses ./kubeconfig (or $KUBECONFIG)
```

Run it **before** applying the Argo CD Applications (the `existingSecret` must
exist). Manually:

```bash
kubectl -n platform create secret generic authentik-config \
  --from-env-file=manifests/argocd/authentik/secrets/authentik.env \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/argocd/authentik/secrets/postgresql-auth.yaml
kubectl apply -f manifests/argocd/prometheus-stack/secrets/grafana-admin.yaml
```

### Read

```bash
# one key of the authentik env
kubectl -n platform get secret authentik-config -o jsonpath='{.data.AUTHENTIK_POSTGRESQL__PASSWORD}' | base64 -d
# Grafana password
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
# every key of a secret
kubectl -n platform get secret authentik-postgresql-auth -o jsonpath='{.data}' | jq
```

### Rules

- **Never** commit files under `secrets/` nor embed a password in `02-application.yaml`.
- Rotating a password = edit the source file in `secrets/`, run the script and
  restart the workload. For the authentik PostgreSQL the password is written to
  the database at init: besides the Secret, run `ALTER USER` on the database (or
  rotate via `postgresql.passwordUpdateJob`).
- Make sure nothing is tracked: `git check-ignore manifests/argocd/*/secrets/*`.

---

## Cluster Access

### External Kubeconfig

```bash
# Copy kubeconfig from container
docker cp k8s-one:/etc/kubernetes/admin-external.conf ./kubeconfig

# Use it
export KUBECONFIG=./kubeconfig
kubectl get nodes
kubectl get pods -A
kubectl get sc
```

The external kubeconfig uses the container's IP as endpoint. To access from outside the Docker host, replace the IP in the kubeconfig with the host IP:

```bash
# Check the current IP in the kubeconfig
grep server kubeconfig

# Replace with the host IP (port 6443 is exposed in docker-compose)
sed -i 's|https://.*:6443|https://<HOST_IP>:6443|' kubeconfig
```

### Internal Kubeconfig (inside the container)

```bash
docker exec k8s-one kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A
```

---

## Usage Examples

### Simple Pod deployment

```bash
kubectl run nginx --image=nginx:alpine --port=80
kubectl get pods -w
```

### PVC with Ceph RBD (block, ReadWriteOnce)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-block
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'Hello from K8s-One!' > /data/hello.txt && cat /data/hello.txt && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-data
```

```bash
kubectl apply -f app.yaml
kubectl logs app
# Hello from K8s-One!
```

### PVC with CephFS (ReadWriteMany)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-data
spec:
  accessModes: [ReadWriteMany]
  storageClassName: cephfs
  resources:
    requests:
      storage: 100Mi
```

Any number of pods across the node can mount `shared-data` simultaneously (validated: 2 replicas reading/writing the same volume).

### Network Policy with Cilium

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
```

### Deployment with Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
```

### Ingress with HAProxy

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  annotations:
    haproxy.org/ingress.class: haproxy
spec:
  rules:
  - host: my-app.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web
            port:
              number: 80
```

```bash
kubectl apply -f ingress.yaml
curl -H "Host: my-app.local" http://localhost:8082/
```

---

## Project Structure

```
k8s-one/
├── Dockerfile                          # Multi-stage build (alpine builder + debian runtime)
├── docker-compose.yaml                 # Execution with persistent volumes
├── README.md                           # Documentation (English)
├── README.pt-BR.md                     # Documentation (Portuguese)
│
├── scripts/
│   ├── entrypoint.sh                   # Orchestration: PKI, configs, processes, manifests
│   ├── deploy-apps.sh                  # Applies manifests/apps via kustomize (no docker cp)
│   ├── create-secrets.sh               # Creates/updates Secrets from manifests/**/secrets/
│   ├── rbd-nbd-reaper.sh               # Unmaps orphaned rbd-nbd (boot; dry-run by default)
│   ├── fix-rbd-stale.sh                # Manual recovery of orphaned rbd-nbd mappings
│   └── fix-nbd-stuck.sh                # Disconnects dead nbd (stuck container/Docker)
│
├── configs/
│   └── containerd-config.toml          # containerd: runc + cgroupfs + overlayfs
│
└── manifests/                          # GITIGNORED — mounted ro into the container
    ├── built-in/                       # Core: applied by entrypoint.sh on every boot
    │   ├── coredns/                    # CoreDNS (one Kubernetes resource per file)
    │   │   ├── 01-service-account.yaml
    │   │   ├── 02-cluster-role.yaml
    │   │   ├── 03-cluster-role-binding.yaml
    │   │   ├── 04-configmap.yaml
    │   │   ├── 05-deployment.yaml
    │   │   └── 06-service.yaml
    │   ├── haproxy-ingress/            # HAProxy Ingress (one Kubernetes resource per file)
    │   │   ├── 01-namespace.yaml
    │   │   ├── 02-service-account.yaml
    │   │   ├── 03-cluster-role.yaml
    │   │   ├── 04-cluster-role-binding.yaml
    │   │   ├── 05-configmap.yaml
    │   │   ├── 06-deployment.yaml
    │   │   └── 07-service.yaml
    │   ├── metrics-server/             # Metrics API (one Kubernetes resource per file)
    │   │   ├── 01-service-account.yaml
    │   │   ├── 02-aggregated-metrics-reader-cluster-role.yaml
    │   │   ├── 03-metrics-server-cluster-role.yaml
    │   │   ├── 04-auth-reader-role-binding.yaml
    │   │   ├── 05-auth-delegator-cluster-role-binding.yaml
    │   │   ├── 06-metrics-server-cluster-role-binding.yaml
    │   │   ├── 07-service.yaml
    │   │   ├── 08-deployment.yaml
    │   │   └── 09-api-service.yaml
    │   └── ceph/                       # Ceph cluster, storage and dashboard
    │       ├── 01-ceph-cluster.yaml
    │       ├── 02-ceph-block-pool.yaml
    │       ├── 03-block-storage-class.yaml
    │       ├── 04-ceph-filesystem.yaml
    │       ├── 05-filesystem-storage-class.yaml
    │       ├── 06-dashboard-namespace.yaml
    │       ├── 07-dashboard-service.yaml
    │       ├── 08-dashboard-ingress.yaml
    │       └── 09-dashboard-certificate.yaml
    │       └── kustomization.yaml
    │   ├── metallb/                     # MetalLB L2 (LB for services; see "Local DNS" — not the external path)
    │   │   ├── 00-crds.yaml … 07-webhook.yaml
    │   │   ├── 02-ipaddresspool.yaml   # 192.168.1.200-250 (LAN)
    │   │   └── kustomization.yaml
    │   └── cert-manager/                # Internal *.lan certificates (mkcert CA)
    │       ├── 00-crds.yaml … 05-webhooks.yaml
    │       ├── cluster-issuer.yaml     # ClusterIssuer "local-ca" (mkcert CA)
    │       ├── certificate-dns-lan.yaml# dns.lan + *.lan → secret dns-lan-tls
    │       ├── kustomization.yaml
    │       └── secrets/
    │           └── mkcert-ca.yaml      # mkcert root CA (never commit)
    ├── argocd/                          # Applications (Argo CD) — Helm charts
    │   ├── authentik/
    │   │   ├── 02-application.yaml      # existingSecret: authentik-config / authentik-postgresql-auth
    │   │   ├── 03-blueprint.yaml        # OIDC provider/group/app (kubectl apply — never through Helm)
    │   │   └── secrets/                 # GITIGNORED (never commit)
    │   │       ├── authentik.env        # app env (AUTHENTIK_* + LITELLM_OIDC_*)
    │   │       └── postgresql-auth.yaml # PostgreSQL auth (postgres-password/password)
    │   ├── litellm/
    │   │   ├── 01-repo-secret.yaml      # OCI repo (ghcr.io/berriai, enableOCI)
    │   │   ├── 02-application.yaml      # litellm-helm chart + db-bootstrap hook (PreSync)
    │   │   └── secrets/                 # GITIGNORED (never commit)
    │   │       ├── litellm.env          # app env (OPENAI_API_KEY, PROXY_BASE_URL, OIDC...)
    │   │       ├── litellm-db.yaml      # YugabyteDB creds (username/password)
    │   │       └── litellm-masterkey.yaml # proxy master key (masterkey)
    │   ├── prometheus-stack/
    │   │   ├── 02-application.yaml      # existingSecret: grafana-admin
    │   │   └── secrets/
    │   │       └── grafana-admin.yaml   # Grafana admin (admin-user/admin-password)
    │   └── yugabyte/
    │       └── 02-application.yaml
    ├── apps/                           # On-demand; one Kubernetes resource per YAML file
    │   ├── kustomization.yaml          # Composes the app directories
    │   └── tileserver/                 # TileServer GL
    # rook-crds/common/csi-operator/operator.yaml  (downloaded at build from Rook v1.20.3)
```

---

## Startup Sequence

Typical timeline for a first run (cold start, no image cache):

```
 0s   ▶ Mount propagation (rshared /, /sys, bpf)
 0s   ▶ PKI generation (3 CAs, 11 certs, SA keypair)
 1s   ▶ Kubeconfig generation (6 files)
 1s   ▶ containerd start → socket ready
 2s   ▶ etcd start → health check OK
 5s   ▶ kube-apiserver start → /healthz OK
 7s   ▶ kube-controller-manager / scheduler / kubelet / kube-proxy
 8s   ▶ OSD loop device attach (/dev/loop0 ← osd.img) + udevd
10s   ▶ cilium install (clean reinstall every boot)
35s   ▶ Node Ready ✓
40s   ▶ CoreDNS, Rook operator, Ceph cluster, HAProxy applied
~2-3m ▶ Rook-Ceph healthy (mon, mgr, osd) — Ceph cluster Ready
```

> On subsequent restarts (images already cached), boot drops to ~1-2 min. The Ceph OSD data survives via `data/rook/`.

---

## PKI & Certificates

The entrypoint generates the full PKI on first run. Certificates are persisted in the `./data/pki/` bind mount and reused across restarts.

### CAs (Certificate Authorities)

| CA | CN | Usage |
|---|---|---|
| `ca` | `kubernetes-ca` | Cluster root CA |
| `etcd/ca` | `etcd-ca` | etcd CA (separate) |
| `front-proxy-ca` | `front-proxy-ca` | Aggregation layer CA |

### Certificates

| Cert | CA | CN | O (Org) | SANs |
|---|---|---|---|---|
| `apiserver` | `ca` | `kube-apiserver` | — | kubernetes, kubernetes.default, *.svc, 127.0.0.1, NODE_IP, 10.96.0.1 |
| `apiserver-kubelet-client` | `ca` | `apiserver-kubelet-client` | `system:masters` | — |
| `admin` | `ca` | `kubernetes-admin` | `system:masters` | — |
| `controller-manager` | `ca` | `system:kube-controller-manager` | — | — |
| `scheduler` | `ca` | `system:kube-scheduler` | — | — |
| `kubelet` | `ca` | `system:node:k8s-one` | `system:nodes` | — |
| `kube-proxy` | `ca` | `system:kube-proxy` | — | — |
| `front-proxy-client` | `front-proxy-ca` | `front-proxy-client` | — | — |
| `etcd/server` | `etcd/ca` | `etcd-server` | — | localhost, NODE_NAME, 127.0.0.1, NODE_IP |
| `etcd/client` | `etcd/ca` | `etcd-client` | — | — |
| `apiserver-etcd-client` | `etcd/ca` | `apiserver-etcd-client` | — | — |

### Service Account

| File | Type |
|---|---|
| `sa.key` | RSA 2048 private key |
| `sa.pub` | Public key (for token verification) |

All certificates have a validity of **10 years** (3650 days).

---

## Networking

### Cilium

- **Datapath**: eBPF
- **Pod CIDR**: `192.168.0.0/16` (auto-detected from kube-controller-manager)
- **Network Policy**: ✅ supported (CiliumNetworkPolicy + k8s NetworkPolicy)
- **IPAM**: cluster-pool (default)
- **kube-proxy replacement**: disabled (kube-proxy runs alongside)
- **Hubble**: ✅ observability & monitoring

Cilium is installed via the Cilium CLI, which manages the Helm chart and provides status monitoring. It is **fully uninstalled and reinstalled on every boot** (the in-memory BPF datapath does not survive a container restart).

### kube-proxy

- **Mode**: iptables
- **Service CIDR**: `10.96.0.0/12`

### CoreDNS

- **ClusterIP**: `10.96.0.10`
- **Forward**: `8.8.8.8`, `1.1.1.1` (Google DNS, Cloudflare)
- **Domain**: `cluster.local`
- **`.lan` names**: resolved in-cluster by a `hosts` block pointing at the MetalLB VIP (`192.168.1.200`)

The `hosts` block is needed because the `forward` above goes straight to public resolvers, which do not know `.lan` (a private TLD only AdGuard serves) — without it no pod reaches `authentik.lan`, `grafana.lan` etc. **by name**, only by ClusterIP. The IP is the **MetalLB VIP** (the `haproxy-kubernetes-ingress` LoadBalancer service), **not** the `192.168.1.20` used by the AdGuard rewrites: `.20` is the host's LAN IP and is unreachable from inside the cluster (it times out). The VIP is reachable, and routes by Host header with the mkcert certs.

It is an explicit list, not a wildcard: the `hosts` plugin only gained wildcard support on CoreDNS **`master`** — no release has it (this cluster runs v1.12.0), so `*.lan` there would be stored as a literal name and silently never match. The `template` alternative would work but makes *every* `*.lan` answer the VIP, including `router.lan` (AdGuard points that at `192.168.1.1`), with no way to carve an exception (Go/RE2 has no lookahead). A new `.lan` service is one more word on that line, in `manifests/built-in/coredns/04-configmap.yaml`. The `reload` plugin picks the change up in ~30 s, no restart.

### Local DNS (AdGuard) & Internal Certificates

**AdGuard Home** (`apps/adguard`) is the LAN/tailnet DNS and resolves the internal `*.lan` names to the cluster. CoreDNS still owns `cluster.local` (in-cluster DNS) — AdGuard is for accessing apps by name.

Flow of a request to `https://dns.lan` (AdGuard dashboard):

```
device → AdGuard (192.168.1.20:53)
       → rewrite "dns.lan → 192.168.1.20"         (config in AdGuardHome.yaml, PVC adguard-conf-fs)
       → browser → 192.168.1.20:443 (host-published port)
       → HAProxy Ingress (Host: dns.lan) → service adguard:80 → UI (3000)
```

- **Why `.lan`, not `.local`**: `.local` is reserved for mDNS (RFC 6762). Android and macOS resolve `.local` via mDNS and **never** via unicast DNS — so `dns.local` fails on those devices even with the right DNS. `.lan` goes through the normal unicast resolver.
- **AdGuard rewrite**: `dns.lan → 192.168.1.20` (the host's fixed LAN IP — not the MetalLB IP; see below).
- **External access = host-published ports**: the cluster runs inside an isolated docker network (`192.168.32.0/20`). MetalLB (in `built-in/metallb`) announces its LoadBalancer IP (`192.168.1.200`) **inside that docker network, not on the WiFi** — so it is **not reachable from the LAN**. The real path is `docker-compose` publishing `0.0.0.0:80/443 → NodePort 30080/30443` on the host's physical IP (`192.168.1.20`). The rewrite points to `192.168.1.20`, **not** `192.168.1.200`.
- **Certificates (cert-manager + mkcert)**: the `ClusterIssuer local-ca` uses the **mkcert root CA** (`~/.local/share/mkcert/rootCA.pem`, imported into Secret `cert-manager/mkcert-ca`). The `Certificate dns-lan` issues `dns.lan` + `*.lan` into Secret `infra/dns-lan-tls`, referenced by the Ingress. To avoid browser warnings, install the mkcert CA into each device's trust store (already done on the host via `mkcert -install`).
- **Tailscale**: global nameserver = `192.168.1.20` and the `192.168.1.0/24` route advertised + approved — tailnet devices resolve `*.lan` via AdGuard and reach `192.168.1.20`. **IPv6 (RA) must be off on the router**: the IPv6 DNS advertisement (`fc00::a/b`) is preferred by Android and breaks `*.lan` resolution.

### Remote access (outside the LAN, via Tailnet)

Works from anywhere with Tailscale on: the tailnet DNS (global nameserver `192.168.1.20`) resolves `*.lan` via AdGuard, and the `192.168.1.0/24` subnet route forwards traffic to `192.168.1.20` (host) → Ingress → app. E.g. `https://argocd.lan` away from home.

> **Gotcha (Termux):** Termux uses its **own** `resolv.conf` (`$PREFIX/etc/resolv.conf`, pointing at `8.8.8.8`) — so `nslookup`/`curl` inside Termux do **not** resolve `.lan`, even though the browser works. Diagnosis:
> - `nslookup argocd.lan 192.168.1.20` → queries AdGuard directly (works).
> - `nslookup argocd.lan 100.100.100.100` → tailnet MagicDNS (works if the tailnet DNS is applied on the device).
> To test access, use the **browser** (it uses the system DNS).
- **Router (LAN)**: DHCP hands out `192.168.1.20` as primary DNS (optional `1.1.1.1` fallback). Note: with the host down, clients that only have `192.168.1.20` lose DNS.

### Headlamp (`headlamp.lan`)

Dashboard at `https://headlamp.lan` (ingress routes by Host; mkcert cert `headlamp.lan`). HAProxy basic-auth was removed — login is **Headlamp's own login** (bearer token). RBAC: SA `headlamp-admin` (ns `headlamp`) bound to ClusterRole **`view`** (read-only).

Extract the persistent Service Account token to log in:

```bash
kubectl -n headlamp get secret headlamp-admin-token -o jsonpath='{.data.token}' | base64 -d
```

The `headlamp-admin-token` secret (type `kubernetes.io/service-account-token`) is long-lived (K8s 1.24+). Since Headlamp runs with `--in-cluster`, it may authenticate automatically via the projected token — the command above is for when the login prompt asks for a token.

### Argo CD (`argocd.lan`)

Accessible at `https://argocd.lan` (Ingress ns `argocd` → `argocd-server:80`, mkcert TLS `argocd.lan`). **Requires `--insecure` on `argocd-server`**: without it, the ingress (which terminates TLS and forwards plain HTTP to the backend) causes a 307 redirect loop. The patch is re-applied by `entrypoint.sh` after applying the upstream `install.yaml` (persistent across reboots).

Login: user `admin`, password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```
> **Tip:** login uses user `admin` + the password from the secret above (it matches the hash in `argocd-secret`/`admin.password`). If the browser rejects it, check **autofill/cache** (type the password manually; hard refresh or incognito) — it is not the headlamp/dns password.

Ingress/cert manifests: `manifests/apps/argocd/` (gitignored).

### Ceph Dashboard (`ceph.lan`)

Ceph web dashboard at `https://ceph.lan` (Ingress ns `ceph-dashboard` → `ceph-dashboard-svc` → `rook-ceph-mgr-dashboard:7000`). TLS uses a **dedicated** mkcert cert `ceph-dashboard-tls` (issued by `local-ca` for `ceph.lan`). The `*.lan` wildcard (`dns-lan-tls`) is **not** used: validators reject single-label wildcards such as `*.lan` (`.lan` is treated as an apex domain), so each `.lan` app has its own Certificate (same pattern as headlamp/argocd). HAProxy basic-auth was removed; authentication is the Ceph dashboard's own login.

Login: user `admin`, password:
```bash
docker exec k8s-one kubectl --kubeconfig=/etc/kubernetes/admin.conf -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 -d
```

> **Note:** the **Orchestrator** tab shows "Orchestrator is not available: Module not found" — expected. The `rook` mgr module is disabled (crash workaround, see Known Issues).

Manifests: `manifests/built-in/ceph/` (`06-dashboard-namespace.yaml`, `07-dashboard-service.yaml`, `08-dashboard-ingress.yaml`, `09-dashboard-certificate.yaml`), applied at boot by `entrypoint.sh`.

### Authentik (`authentik.lan`)

Identity provider at `https://authentik.lan` (chart `authentik` 2026.8.1, ns `platform`, embedded bitnami PostgreSQL — not the cluster's YugabyteDB, because Django migrations need a real PG — mkcert cert `authentik-tls`). It is here to be the **single login** for the cluster's apps; the only app wired to it so far is LiteLLM.

Groups, providers and applications are **declarative**, via a blueprint the chart mounts into the worker:

```bash
kubectl apply -f manifests/argocd/authentik/03-blueprint.yaml    # the blueprint ConfigMap
kubectl apply -f manifests/argocd/authentik/02-application.yaml  # then let Argo CD sync the chart
```

- `manifests/argocd/authentik/03-blueprint.yaml` is a ConfigMap holding the blueprint (`litellm-oidc.yaml`): group `litellm-users`, OAuth2 provider `LiteLLM`, the application and the group binding.
- It is applied with **`kubectl`, never through Helm**: blueprint tags (`!Find`, `!KeyOf`, `!Env`) are custom YAML, and Helm's `values → toYaml` round-trip destroys them (they arrive in the cluster as bare strings and the blueprint fails).
- The chart mounts every name in `blueprints.configMaps` (in `02-application.yaml`) into the **worker** at `/blueprints/mounted/cm-<name>`; the worker discovers all `*.yaml` there.
- **Discovery is event-driven, not boot-time.** What triggers it is the file watcher (`on_created`/`on_modified`) plus an **hourly** scheduled run. A ConfigMap that is already populated when the worker starts fires nothing — the mount happens before the process is up. To force it without waiting: touch the ConfigMap (`kubectl annotate cm authentik-blueprints k8s-one/reload="$(date -Iseconds)" --overwrite`) and the kubelet resync produces the create events.
- **Idempotency comes from `identifiers`**, not from `id`: the importer builds a `filter()` from `identifiers` and, if it finds the object, updates it (`partial=True`); otherwise it creates. The entry `id` exists only so other entries can point at it with `!KeyOf`. An entry without `identifiers` aborts with "No or invalid identifiers".
- **List-valued fields have an empty default and must be declared.** `grant_types` is `ArrayField(..., default=list)` on the model: the UI wizard fills it in, a blueprint does not. Omit it and the provider is created with `grant_types = {}` — it then rejects every grant (`Invalid grant_type for provider` in the server log) and `/authorize` answers `invalid_request`, which looks like a completely unrelated bug. Same trap for any other `ArrayField` (`property_mappings` above is the same shape, with a less obvious symptom: a token without the `email` claim).
- **The client credentials are `!Env`**, resolved against the worker's environment — which receives **every key** of the `authentik-config` Secret (`envFrom`). They live in `secrets/authentik.env` (gitignored). Note `!Env` returns `None` for a missing variable instead of failing loudly, so the salt is on the other side: the authentik serializer rejects a null `client_secret`, and the sync errors out.

Admin login is `akadmin`:

```bash
kubectl -n platform get secret authentik-config -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_EMAIL}' | base64 -d; echo
kubectl -n platform get secret authentik-config -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}' | base64 -d; echo
```

> The password above is the **bootstrap** value: it is consumed when the database is created. Editing it in `secrets/authentik.env` afterwards does **not** change the password of an existing `akadmin` — that is done in the UI (`Settings → Password`) or by resetting the flow.

### LiteLLM (`litellm.lan`)

OpenAI-compatible proxy at `https://litellm.lan` (Ingress ns `platform` → `litellm:4000`, dedicated mkcert cert `litellm-tls`). It replaces the LiteLLM that used to run in the `infra/` docker-compose stack; the database is **the cluster's own YugabyteDB** (ns `data`, YSQL `:5433`) — which is why that DB exists here in the first place.

**DNS:** `litellm.lan` must be added as a rewrite in AdGuard (`Filters → DNS rewrites` → `192.168.1.20`), like the other `.lan` names. AdGuard rewrites are **per host, not wildcards**, and the config lives inside the `adguard-conf-fs` PVC (not in this repo), so this is a manual one-time step.

```bash
# master key — the API bearer token (NOT a UI login, see below)
kubectl -n platform get secret litellm-masterkey -o jsonpath='{.data.masterkey}' | base64 -d
# list models
curl -sk https://litellm.lan/v1/models -H "Authorization: Bearer $MASTER_KEY"
```

**UI login is SSO through Authentik** (provider `LiteLLM`, see the Authentik section above). Redirect URI: `https://litellm.lan/sso/callback`; access is restricted to the `litellm-users` group. The whole switch is environment:

- The keys are `GENERIC_*`, **not** `GOOGLE_*`. LiteLLM picks the provider in a **Google → Microsoft → Generic** `if/elif`, so while `GOOGLE_CLIENT_ID` exists the generic block is dead code — removing the two Google keys is what actually flips the provider.
- Three endpoints are configured by hand (`authorize`, `token`, `userinfo`): LiteLLM does **not** use OIDC discovery, so there is no `/.well-known` lookup.
- `PROXY_BASE_URL` (`https://litellm.lan`) is what composes the redirect URI; it must match what is registered on the provider.
- The **master key is unaffected by SSO** — it stays the API bearer token. It is not a UI password: `POST /login` with `admin` + master key returns 401 here.
- Without a `LITELLM_LICENSE`, SSO is capped at **5 users** (`ui_sso.py` refuses beyond that). The `LiteLLM_UserTable` starts empty, so it only matters if more people ever log in.

**TLS when calling Authentik.** The pod reaches Authentik at `https://authentik.lan`, which inside the cluster resolves to the MetalLB VIP and serves a **mkcert** certificate — not trusted by the Debian CA bundle in the image, so the token exchange would fail hostname/issuer verification. The deployment therefore mounts the mkcert root (the `ca.crt` of the `litellm-tls` secret, already in the `platform` namespace) and an initContainer **concatenates** it with the system bundle, pointing `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` at the result. Concatenating rather than replacing matters: the proxy also calls `api.openai.com`, whose cert is not mkcert-signed.

Deployment details worth knowing before touching it:
- **Chart**: official `litellm-helm`, pulled as an **OCI** chart from `ghcr.io/berriai` (the classic Helm index `berriai.github.io/litellm-helm` is 404). The repo Secret's `url` is the **parent** of the chart in the OCI path — Argo CD builds `oci://<url>/<chart>`, so `url: ghcr.io/berriai` + `chart: litellm-helm`. `targetRevision` must be an exact tag (OCI has no semver ranges).
- **No IngressClass in this cluster**: every Ingress routes via the `haproxy.org/ingress.class` annotation and has CLASS `<none>`. The chart's `ingress.className` is therefore set to `""` (its default, `nginx`, would render `ingressClassName: nginx` and break routing).
- **Two PreSync hooks run before every sync.** `litellm-db-bootstrap` (wave `-1`, `postgres:17-alpine`) idempotently creates the `litellm` role/database/schema on the YugabyteDB; then the chart's own `litellm-migrations` job runs `prisma migrate deploy`. Both are safe to re-run.
- **`PRISMA_SCHEMA_DISABLE_ADVISORY_LOCK=true` is required.** YugabyteDB does not block on `pg_advisory_lock` the way Postgres does: once an attempt is killed by timeout while holding the lock, every later attempt dies in 10s with `P1002 ... postgres advisory lock`. Without the flag the first deploy stalls with ~88 of 127 migrations applied. Safe here because there is exactly one writer (the PreSync hook) and the proxy starts with `DISABLE_SCHEMA_UPDATE=true`.
- **`ENFORCE_PRISMA_MIGRATION_CHECK=true` is required too.** Without it LiteLLM logs "migration failed but continuing startup" and **exits 0** — the Job shows as `Completed` against a half-migrated database. With it, a migration failure fails the hook and stops the sync.
- **Memory**: 2Gi limit, not less. Both the migration job (~1.7Gi peak) and the proxy are OOMKilled at 1Gi. `strategy: Recreate` avoids two proxies during a rollout on this single, memory-tight node.
- **Metrics need the callback**: `/metrics` only exists when `litellm_settings.callbacks: [prometheus]` is set — without it LiteLLM returns 404 and the Prometheus target stays DOWN (the ServiceMonitor itself works: the scrape does happen). With the callback on, the endpoint also demands the API key, hence `require_auth_for_metrics_endpoint: false` (it is a ClusterIP endpoint).

Manifests: `manifests/argocd/litellm/`. Secrets: see the table above.

---

## Storage

### Rook-Ceph

Ceph is deployed by Rook as a single-node cluster with **one OSD on a loop device** (30G sparse image, `osd.img`) — no host disks are touched.

- **Operator**: Rook v1.20.3 · **Ceph**: v20.2.2 (pinned — see Known Issues)
- **OSD**: 1 bluestore OSD on `/dev/loop0` ← `/var/lib/rook/osd.img` (persisted in `./data/rook/`)
- **Data path**: `/var/lib/rook` (bind mount)

| StorageClass | Provisioner | Access | Pool | Use |
|---|---|---|---|---|
| `ceph-block` (**default**) | `rook-ceph.rbd.csi.ceph.com` | RWO | `replicapool` | Block volumes (RBD) |
| `cephfs` | `rook-ceph.cephfs.csi.ceph.com` | **RWX** | `cephfs-data0` | Shared filesystem volumes |

```bash
kubectl get sc
# NAME                 PROVISIONER                        RECLAIMPOLICY  VOLUMEBINDINGMODE
# ceph-block (default) rook-ceph.rbd.csi.ceph.com         Delete         Immediate
# cephfs               rook-ceph.cephfs.csi.ceph.com      Delete         Immediate
```

Replication is `size: 1` (single node) — data is **not redundant**; the OSD lives on a loop file on the host disk. Back up `data/rook/` if the data matters.

---

## Known Issues

### mgr "rook" module disabled (workaround)

- **Symptom:** `ceph mgr` crash-loop every ~15s: `NotImplementedError` in `node_proxy_fullreport` (crash dumps filling the data dir).
- **Cause:** Ceph v20.2.3 + Rook 1.20.3 — the Ceph `prometheus` mgr module calls `node_proxy_fullreport()`, which the Rook mgr module does not implement. Upstream: [rook/rook#18124](https://github.com/rook/rook/issues/18124) / [tracker 79106](https://tracker.ceph.com/issues/79106).
- **Current state:** the `rook` mgr module is **disabled** (`spec.mgr.modules[0].enabled: false` in `ceph/01-ceph-cluster.yaml`) — this is the maintainer-recommended workaround. The Rook operator does **not** depend on the module; only `ceph orch` CLI/dashboard integration is lost.
- **Re-enable** when the upstream fix ([ceph/ceph#70967](https://github.com/ceph/ceph/pull/70967)) is released.

---

## Customization

### Change upstream DNS

Edit `manifests/built-in/coredns/04-configmap.yaml`, `forward` section:

```
forward . 8.8.8.8 1.1.1.1 {
```

### Change containerd runtime

Edit `configs/containerd-config.toml`:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = false   # set to true if host uses systemd cgroups
```

### Change OSD size

```bash
docker compose build --build-arg ROOK_OSD_SIZE=50G   # env var at runtime; affects osd.img on first boot
```

### Change Pod CIDR

Update in **two places**:
1. `scripts/entrypoint.sh` → `CLUSTER_CIDR`
2. Cilium install command (entrypoint.sh → `cilium install --set ipam.operator.clusterPoolIPv4PodCIDRList=...`)
   Rebuild required.

---

## Troubleshooting

### Container dies immediately

```bash
docker compose logs --tail 50
```

Common causes:
- Missing `--privileged` in docker-compose
- `/sys` not mounted as shared

### Pods stuck in ContainerCreating

```bash
kubectl describe pod <pod-name> -n <namespace>
```

Common causes:
- Cilium hasn't installed the CNI yet → wait for cilium-agent to be Running
- Mount propagation error → check that `/sys` is mounted rw

### PVC stuck in ContainerCreating (`rbd image ... is still being used`)

Pod events show: `rbd image ... is still being used` or `rbd-nbd: cookie mismatch`.

Cause: the `ceph-block` StorageClass uses `mounter: rbd-nbd`; rbd-nbd mappings can
survive pod/plugin restarts and cephcsi's healer fails to reclaim them.

**The bundled tooling does not reliably catch this case.** Both `fix-rbd-stale.sh` and
`rbd-nbd-reaper.sh` decide a mapping is orphaned by looking for a `volumeHandle` with
no `VolumeAttachment` in `Attached=true`. But a `VolumeAttachment` is node-scoped: it
survives the replacement of the pod using it, staying `Attached=true` for a volume no
live pod is using. Replaying that heuristic against live state during an affected
rollout reports **zero orphans** while the stale mappings sit right there. Do not reach
for `--all` as a workaround — it unmaps every device, including the ones serving
running pods (Prometheus, Grafana, authentik-postgresql).

The definitive test is whether the device is **actually mounted**:

```bash
# device -> volumeHandle, and how many times it is mounted (0 = orphan)
for d in /sys/block/nbd[0-9]*; do
  b=$(cat "$d/backend" 2>/dev/null); [ -z "$b" ] && continue
  n=$(basename "$d")
  echo "$n ${b##*-} mounts=$(docker exec k8s-one grep -c "/dev/$n " /proc/mounts)"
done

# which PV each volumeHandle belongs to
kubectl get pv -o go-template='{{range .items}}{{if .spec.csi}}{{.spec.csi.volumeHandle}} {{.metadata.name}}{{"\n"}}{{end}}{{end}}'
```

`nbd` numbering is not chronological and carries no meaning — never infer staleness
from a device's number. Unmap only the devices showing `mounts=0`:

```bash
PLUGIN=rook-ceph.rbd.csi.ceph.com-nodeplugin-<hash>
kubectl -n rook-ceph exec $PLUGIN -c csi-rbdplugin -- rbd-nbd unmap /dev/nbdN
```

That detaches the block device only — the RBD image and its contents are untouched,
and the waiting pod picks it up within seconds.

> `rbd-nbd-reaper.sh` runs at boot and is **enabled** in this deployment
> (`RBD_REAPER_DRY_RUN=0` in `.env`). It shares the `VolumeAttachment` heuristic
> above, so treat it as a safety net for leftovers, not as coverage for this failure
> mode. `fix-rbd-stale.sh` remains useful for the case its heuristic does fit.

### Container/Docker stuck on rebuild (`did not receive an exit event`)

Symptoms: `docker compose up -d` fails with `cannot stop container ... tried to kill
container, but did not receive an exit event`, and/or `dockerd` hangs on
"Loading containers". Cause: the Ceph CSI `rbd-nbd` uses `--io-timeout=0` (no
timeout); if the container is terminated with pending I/O, `systemd-udevd` gets
stuck in D-state on a dead nbd and the container never finishes.

Recovery (host, with `sudo`):

```bash
# 1. Stop Docker (if it hangs: sudo systemctl kill -s SIGKILL docker)
sudo systemctl stop docker.socket docker

# 2. Remove the stuck containerd task
sudo ctr -n moby tasks list          # note the ID (STATUS RUNNING/STOPPED)
sudo ctr -n moby tasks rm <ID>
sudo ctr -n moby containers rm <ID>

# 3. Disconnect the dead nbd devices
sudo scripts/fix-nbd-stuck.sh --apply --yes

# 4. Start Docker and recreate the cluster
sudo systemctl start docker
docker compose up -d
```

`rbd-nbd-reaper.sh` prevents most cases; the procedure above is the last resort
when the container will not die.

### CoreDNS CrashLoopBackOff

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns
```

Common causes:
- Loop detection → already fixed with forward to 8.8.8.8
- Corefile syntax error → check `manifests/built-in/coredns/04-configmap.yaml`

### OSD not created after reboot (0 OSDs)

```bash
docker exec k8s-one losetup -a          # must show /dev/loop0 ← /var/lib/rook/osd.img
docker exec k8s-one kubectl --kubeconfig=/etc/kubernetes/admin.conf -n rook-ceph get pod -l app=rook-ceph-osd
```

Common causes:
- Loop device not attached → `losetup /dev/loop0 /var/lib/rook/osd.img` then delete the `rook-ceph-osd-prepare` job and restart the operator
- `ROOK_CEPH_ALLOW_LOOP_DEVICES` not `true` → verify `rook-ceph-operator-config` configmap

### Node NotReady

```bash
kubectl describe node k8s-one
```

Common causes:
- CNI not installed → Cilium still initializing
- kubelet can't communicate with apiserver → check certs

### View logs for a specific component

```bash
# All logs mixed
docker compose logs -f

# Filter by component
docker compose logs -f | grep apiserver
docker compose logs -f | grep kubelet
docker compose logs -f | grep etcd
```

### Full reset

```bash
docker compose down -v   # removes container + all named volumes (keeps ./data/rook/)
docker compose up -d     # fresh start
# To also wipe Ceph data: rm -rf data/rook/*  (irreversible!)
```

---

## Requirements

### Host

| Requirement | Minimum | Recommended |
|---|---|---|
| **Docker** | 24.0+ | 27.0+ |
| **Docker Compose** | v2.20+ | v2.30+ |
| **RAM** | 16 GB | 24 GB |
| **CPU** | 2 cores | 4 cores |
| **Disk** | 10 GB (image + 30G sparse OSD) | 20 GB+ |
| **OS** | Linux (kernel 5.10+) | Linux (kernel 6.x) |
| **Arch** | amd64 | amd64 |

> The RAM figures follow from the kubelet reserves, not from the cluster's own
> footprint: `systemReserved` (12Gi) + `kubeReserved` (2Gi) + `evictionHard` (1Gi)
> are subtracted from *host* capacity before pods get anything. A 16 GB host leaves
> ~1 GiB for pods; 24 GB leaves ~9 GiB. See
> [Resource Reserves](#resource-reserves-kubelet) for the full math.

### Ports

| Port | Protocol | Usage |
|---|---|---|
| `6443` | TCP | Kubernetes API Server |
| `8082` | TCP | HAProxy Ingress HTTP (→ NodePort 30080) |
| `8443` | TCP | HAProxy Ingress HTTPS (→ NodePort 30443) |

---

## Limitations

- **Not HA**: single node, no redundancy. etcd, apiserver, etc. are single-instance.
- **Not for production**: intended for development, testing, CI/CD, lab environments.
- **Storage without redundancy**: Ceph replication `size: 1`, single OSD on a loop file.
- **Privileged mode**: the container runs with `--privileged` (required for kubelet/containerd + loop devices).
- **amd64 only**: arm64 may work with `--build-arg TARGETARCH=arm64` but is untested.
- **No systemd**: uses `cgroupfs` as cgroup driver (no systemd inside the container).
- **Cert rotation**: disabled. Certificates last 10 years. For long-lived clusters, consider implementing rotation.

---

## License

MIT
