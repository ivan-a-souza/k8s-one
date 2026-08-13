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
└──────────────────────────────────────────────────┘
```

---

## Table of Contents

- [Quick Start](#quick-start)
- [Components](#components)
- [Architecture](#architecture)
- [Persistent Volumes](#persistent-volumes)
- [Configuration](#configuration)
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
    ├── kubectl apply coredns.yaml
    ├── kubectl apply rook CRDs + common + CSI operator + operator
    ├── patches ROOK_CEPH_ALLOW_LOOP_DEVICES=true (verified)
    ├── kubectl apply rook-ceph-cluster.yaml (Ceph cluster + pools + SC)
    └── kubectl apply haproxy-ingress.yaml
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
| `./rook-data/` | `/var/lib/rook` | Ceph data: OSD image + keyrings |

Additionally, the container bind-mounts host system paths:

| Host Path | Container Path | Mode | Reason |
|---|---|---|---|
| `/sys` | `/sys` | `rw` | Cilium BPF, cgroups |
| `/lib/modules` | `/lib/modules` | `ro` | Kernel modules (iptables, etc.) |

> ⚠️ `./data/` and `./rook-data/` contain cluster secrets (Ceph keyrings, PKI private keys, kubeconfigs). Both are **gitignored** — never commit them.

### Clean everything

```bash
docker compose down -v   # removes container + named volumes (bind mounts under ./data/ and ./rook-data/ are kept)
# To fully wipe cluster data: rm -rf data/* rook-data/*   (irreversible!)
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

> The **Ceph image version** is set in `manifests/rook-ceph-cluster.yaml` (`quay.io/ceph/ceph:v20.2.2` — pinned to the version officially tested with Rook 1.20.3; do **not** use the floating `:v20` tag).

### Environment Variables (runtime)

| Variable | Default | Description |
|---|---|---|
| `NODE_NAME` | `k8s-one` | Node name in the cluster |
| `ROOK_OSD_SIZE` | `30G` | Size of the sparse OSD image (`/var/lib/rook/osd.img`) |

### Network Parameters (entrypoint.sh)

| Parameter | Value | Description |
|---|---|---|
| `CLUSTER_CIDR` | `192.168.0.0/16` | Pod CIDR (Cilium auto-detects from controller-manager) |
| `SERVICE_CIDR` | `10.96.0.0/12` | ClusterIP CIDR |
| `CLUSTER_DNS` | `10.96.0.10` | CoreDNS IP |

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
│   └── rbd-device-watch.sh             # Creates /dev/rbdN nodes (krbd with noudev)
│
├── configs/
│   └── containerd-config.toml          # containerd: runc + cgroupfs + overlayfs
│
└── manifests/
    ├── coredns.yaml                    # CoreDNS (ServiceAccount, RBAC, Deployment, Service)
    ├── haproxy-ingress.yaml            # HAProxy Ingress Controller (image pinned by digest)
    └── rook-ceph-cluster.yaml          # CephCluster CR (single-node, loop OSD) + pools + SCs
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

> On subsequent restarts (images already cached), boot drops to ~1-2 min. The Ceph OSD data survives via `rook-data/`.

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

---

## Storage

### Rook-Ceph

Ceph is deployed by Rook as a single-node cluster with **one OSD on a loop device** (30G sparse image, `osd.img`) — no host disks are touched.

- **Operator**: Rook v1.20.3 · **Ceph**: v20.2.2 (pinned — see Known Issues)
- **OSD**: 1 bluestore OSD on `/dev/loop0` ← `/var/lib/rook/osd.img` (persisted in `./rook-data/`)
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

Replication is `size: 1` (single node) — data is **not redundant**; the OSD lives on a loop file on the host disk. Back up `rook-data/` if the data matters.

---

## Known Issues

### mgr "rook" module disabled (workaround)

- **Symptom:** `ceph mgr` crash-loop every ~15s: `NotImplementedError` in `node_proxy_fullreport` (crash dumps filling the data dir).
- **Cause:** Ceph v20.2.3 + Rook 1.20.3 — the Ceph `prometheus` mgr module calls `node_proxy_fullreport()`, which the Rook mgr module does not implement. Upstream: [rook/rook#18124](https://github.com/rook/rook/issues/18124) / [tracker 79106](https://tracker.ceph.com/issues/79106).
- **Current state:** the `rook` mgr module is **disabled** (`spec.mgr.modules[0].enabled: false` in `rook-ceph-cluster.yaml`) — this is the maintainer-recommended workaround. The Rook operator does **not** depend on the module; only `ceph orch` CLI/dashboard integration is lost.
- **Re-enable** when the upstream fix ([ceph/ceph#70967](https://github.com/ceph/ceph/pull/70967)) is released.

---

## Customization

### Change upstream DNS

Edit `manifests/coredns.yaml`, `forward` section:

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

### CoreDNS CrashLoopBackOff

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns
```

Common causes:
- Loop detection → already fixed with forward to 8.8.8.8
- Corefile syntax error → check `manifests/coredns.yaml`

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
docker compose down -v   # removes container + all named volumes (keeps ./rook-data/)
docker compose up -d     # fresh start
# To also wipe Ceph data: rm -rf rook-data/*  (irreversible!)
```

---

## Requirements

### Host

| Requirement | Minimum | Recommended |
|---|---|---|
| **Docker** | 24.0+ | 27.0+ |
| **Docker Compose** | v2.20+ | v2.30+ |
| **RAM** | 4 GB | 8 GB |
| **CPU** | 2 cores | 4 cores |
| **Disk** | 10 GB (image + 30G sparse OSD) | 20 GB+ |
| **OS** | Linux (kernel 5.10+) | Linux (kernel 6.x) |
| **Arch** | amd64 | amd64 |

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
