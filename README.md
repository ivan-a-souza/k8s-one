*[🇧🇷 Português](README.pt-BR.md)*

# K8s-One

A **complete single-node Kubernetes cluster**, built **from scratch** using individual components — no K3s, KIND, kubeadm, or any pre-packaged distribution.

Packaged in a **distroless-style image** via multi-stage build.

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
│  CNI: Calico  │  DNS: CoreDNS  │  SC: local-path │
│         Ingress: HAProxy (Ports 8080/8443)       │
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

# Follow startup logs (~90s on first run)
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
kube-system          calico-kube-controllers-...                 1/1     Running
kube-system          calico-node-...                             1/1     Running
kube-system          coredns-...                                 1/1     Running
local-path-storage   local-path-provisioner-...                  1/1     Running
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
| **Calico** | v3.29.2 | projectcalico/calico | CNI — networking + network policy |
| **CoreDNS** | v1.12.0 | registry.k8s.io | Cluster DNS |
| **local-path-provisioner** | v0.0.35 | rancher/local-path-provisioner | Dynamic PV provisioning via hostPath |
| **HAProxy Ingress** | latest | haproxytech/kubernetes-ingress | Ingress Controller |

---

## Architecture

### Multi-Stage Build (Distroless)

```
┌─────────────────────────────────────┐
│  Stage 1: Builder (alpine:3.21)     │
│                                     │
│  • curl, tar, gzip                  │
│  • Downloads all binaries           │
│  • Downloads manifests              │
│  • Discarded in final image         │
└──────────────┬──────────────────────┘
               │ COPY binaries
               ▼
┌─────────────────────────────────────┐
│  Stage 2: Runtime (alpine:3.21)     │
│                                     │
│  • iptables, conntrack, iproute2    │
│  • openssl, socat, util-linux       │
│  • gcompat (glibc compat)           │
│  • NO apk (removed at build)       │
│  • NO docs, man pages, caches      │
│  • = "distroless-style" image       │
└─────────────────────────────────────┘
```

The final image **has no package manager** — `apk` is removed after installing runtime dependencies. This eliminates the possibility of installing packages at runtime, reducing the attack surface.

### Startup Process

The `entrypoint.sh` orchestrates **7 processes** running simultaneously inside the container:

```
entrypoint.sh
├── setup_mounts()        # mount --make-rshared /, /sys, bpf
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
└── apply_manifests() [background]
    ├── taint removal (allows workloads)
    ├── kubectl apply calico.yaml
    ├── waits for Node Ready
    ├── kubectl apply coredns.yaml
    ├── kubectl apply local-path-storage.yaml
    └── kubectl apply haproxy-ingress.yaml
```

---

## Persistent Volumes

All state data is mounted on named Docker volumes, ensuring persistence across restarts:

| Volume | Container Mount | Contents |
|---|---|---|
| `etcd-data` | `/var/lib/etcd` | etcd data (cluster state) |
| `containerd-data` | `/var/lib/containerd` | Images and containers |
| `kubelet-data` | `/var/lib/kubelet` | Kubelet state and pods |
| `k8s-pki` | `/etc/kubernetes/pki` | TLS certificates (CAs, certs, keys) |
| `k8s-configs` | `/etc/kubernetes` | Kubeconfigs (admin, scheduler, etc.) |
| `local-path-data` | `/opt/local-path-provisioner` | PersistentVolumes created by local-path |

Additionally, the container bind-mounts:

| Host Path | Container Path | Mode | Reason |
|---|---|---|---|
| `/sys` | `/sys` | `rw` | Calico BPF, cgroups |
| `/lib/modules` | `/lib/modules` | `ro` | Kernel modules (iptables, etc.) |

### Clean everything

```bash
docker compose down -v   # removes container + all volumes
```

---

## Configuration

### Build Args

All versions are configurable via build args in the Dockerfile:

```bash
# Use a specific Kubernetes version
docker compose build --build-arg KUBE_VERSION=v1.35.0

# Use a specific Calico version
docker compose build --build-arg CALICO_VERSION=v3.28.0

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
| `CALICO_VERSION` | `v3.29.2` | Calico version |
| `LOCAL_PATH_VERSION` | `v0.0.35` | local-path-provisioner version |
| `TARGETARCH` | `amd64` | Target architecture |

### Environment Variables (runtime)

| Variable | Default | Description |
|---|---|---|
| `NODE_NAME` | `k8s-one` | Node name in the cluster |

### Network Parameters (entrypoint.sh)

| Parameter | Value | Description |
|---|---|---|
| `CLUSTER_CIDR` | `192.168.0.0/16` | Pod CIDR (Calico default compatible) |
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

### PVC with local-path-provisioner

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
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

### Network Policy with Calico

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
curl -H "Host: my-app.local" http://localhost:8080/
```
```

---

## Project Structure

```
k8s-one/
├── Dockerfile                          # Multi-stage build (builder + runtime)
├── docker-compose.yaml                 # Execution with persistent volumes
├── README.md                           # Documentation (Portuguese)
├── README.en.md                        # Documentation (English)
│
├── scripts/
│   └── entrypoint.sh                   # Orchestration: PKI, configs, processes, manifests
│
├── configs/
│   └── containerd-config.toml          # containerd: runc + cgroupfs + overlayfs
│
└── manifests/
    └── coredns.yaml                    # CoreDNS (ServiceAccount, RBAC, Deployment, Service)
    # calico.yaml                       # (downloaded at build — projectcalico/calico)
    # local-path-storage.yaml           # (downloaded at build — rancher/local-path-provisioner)
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
 7s   ▶ kube-controller-manager start
 7s   ▶ kube-scheduler start
 7s   ▶ kubelet start → node registered
 8s   ▶ kube-proxy start
 8s   ▶ kubectl apply calico.yaml
30s   ▶ Calico images pulled + calico-node Running
35s   ▶ Node Ready ✓
35s   ▶ kubectl apply coredns.yaml
40s   ▶ kubectl apply local-path-storage.yaml
90s   ▶ All pods Running ✓
```

> On subsequent restarts (images already cached), total time drops to ~30-40s.

---

## PKI & Certificates

The entrypoint generates the full PKI on first run. Certificates are persisted in the `k8s-pki` volume and reused across restarts.

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

### Calico

- **Mode**: VXLAN (manifest default)
- **Pod CIDR**: `192.168.0.0/16`
- **Network Policy**: ✅ supported
- **IPAM**: Calico IPAM

Calico is installed via raw manifest (no Tigera Operator), which simplifies installation but requires manual upgrade management.

### kube-proxy

- **Mode**: iptables
- **Service CIDR**: `10.96.0.0/12`

### CoreDNS

- **ClusterIP**: `10.96.0.10`
- **Forward**: `8.8.8.8`, `1.1.1.1` (Google DNS, Cloudflare)
- **Domain**: `cluster.local`

---

## Storage

### local-path-provisioner

- **StorageClass**: `local-path` (default)
- **Provisioner**: `rancher.io/local-path`
- **Reclaim Policy**: `Delete`
- **Bind Mode**: `WaitForFirstConsumer`
- **Host path**: `/opt/local-path-provisioner` (persisted in Docker volume)

```bash
# Check StorageClass
kubectl get sc
# NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

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

### Change Pod CIDR

Update in **two places**:
1. `scripts/entrypoint.sh` → `CLUSTER_CIDR`
2. Calico manifest (rebuild required, or edit the downloaded manifest)

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
- Calico hasn't installed the CNI yet → wait for calico-node to be Running
- Mount propagation error → check that `/sys` is mounted rw

### CoreDNS CrashLoopBackOff

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns
```

Common causes:
- Loop detection → already fixed with forward to 8.8.8.8
- Corefile syntax error → check `manifests/coredns.yaml`

### Node NotReady

```bash
kubectl describe node k8s-one
```

Common causes:
- CNI not installed → Calico still initializing
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
docker compose down -v   # removes container + all volumes
docker compose up -d     # fresh start
```

---

## Requirements

### Host

| Requirement | Minimum | Recommended |
|---|---|---|
| **Docker** | 24.0+ | 27.0+ |
| **Docker Compose** | v2.20+ | v2.30+ |
| **RAM** | 2 GB | 4 GB |
| **CPU** | 2 cores | 4 cores |
| **Disk** | 5 GB (image) | 10 GB+ |
| **OS** | Linux (kernel 5.10+) | Linux (kernel 6.x) |
| **Arch** | amd64 | amd64 |

### Ports

| Port | Protocol | Usage |
|---|---|---|
| `6443` | TCP | Kubernetes API Server |
| `8080` | TCP | HAProxy Ingress HTTP |
| `8443` | TCP | HAProxy Ingress HTTPS |

---

## Limitations

- **Not HA**: single node, no redundancy. etcd, apiserver, etc. are single-instance.
- **Not for production**: intended for development, testing, CI/CD, lab environments.
- **Privileged mode**: the container runs with `--privileged` (required for kubelet/containerd).
- **amd64 only**: arm64 may work with `--build-arg TARGETARCH=arm64` but is untested.
- **No systemd**: uses `cgroupfs` as cgroup driver (no systemd inside the container).
- **Cert rotation**: disabled. Certificates last 10 years. For long-lived clusters, consider implementing rotation.

---

## License

MIT
