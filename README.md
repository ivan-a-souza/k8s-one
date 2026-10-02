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
│  Storage: local-path-provisioner (hostPath)      │
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
- [kt-connect (ktctl)](#kt-connect-ktctl)
- [Usage Examples](#usage-examples)
- [Project Structure](#project-structure)
- [Startup Sequence](#startup-sequence)
- [PKI & Certificates](#pki--certificates)
- [Networking](#networking)
- [Workloads](#workloads)
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
local-path-storage   local-path-provisioner-...                   1/1     Running
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
| **local-path-provisioner** | v0.0.30 | github.com/rancher/local-path-provisioner | Dynamic hostPath provisioning (default StorageClass) |
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
│  • Discarded in final image         │
└──────────────┬──────────────────────┘
               │ COPY binaries
               ▼
┌─────────────────────────────────────┐
│  Stage 2: Runtime (debian:bookworm) │
│                                     │
│  • bash, openssl, iptables          │
│  • socat, conntrack                 │
│  • apt/dpkg removed at build        │
│  • = minimal image, no pkg manager  │
└─────────────────────────────────────┘
```

The final image **has no package manager** — `apt`/`dpkg` are removed after installing runtime dependencies, reducing the attack surface.

### Startup Process

The `entrypoint.sh` orchestrates the control-plane processes and manifest deployment:

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
└── apply_manifests() [background]
    ├── taint removal (allows workloads)
    ├── cilium install (CNI, clean reinstall every boot)
    ├── waits for Node Ready
    ├── kubectl apply -f coredns/
    ├── kubectl apply -k local-path/ (provisioner + default StorageClass)
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
| `./data/local-path/` | `/opt/local-path-provisioner` | Volumes provisioned by the `local-path` StorageClass |

Additionally, the container bind-mounts host system paths:

| Host Path | Container Path | Mode | Reason |
|---|---|---|---|
| `/sys` | `/sys` | `rw` | Cilium BPF, cgroups |
| `/lib/modules` | `/lib/modules` | `ro` | Kernel modules (iptables, etc.) |

> ⚠️ `./data/` contains cluster secrets (PKI private keys, kubeconfigs) and, alongside `./data/local-path/`, all volume data. Both are **gitignored** — never commit them.

### Clean everything

```bash
docker compose down -v   # removes container + named volumes (bind mounts under ./data/ and ./data/local-path/ are kept)
# To fully wipe cluster data: rm -rf data/* data/local-path/*   (irreversible!)
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
| `TARGETARCH` | `amd64` | Target architecture |

### Environment Variables (runtime)

| Variable | Default | Description |
|---|---|---|
| `NODE_NAME` | `k8s-one` | Node name in the cluster |
| `ARGOCD_VERSION` | `v3.5.1` | Argo CD version installed at boot (format: `vX.Y.Z`) |

Set `ARGOCD_VERSION` in the root `.env` file. After changing it, recreate the
container so the selected version is applied during startup:

```bash
docker compose up -d --force-recreate
```

### Network Parameters (entrypoint.sh)

| Parameter | Value | Description |
|---|---|---|
| `CLUSTER_CIDR` | `192.168.0.0/16` | Pod CIDR (must contain the nodes' allocated podCIDR; passed to the Cilium IPAM and disjoint from `SERVICE_CIDR`) |
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
requests here, so keep an eye on the ratio — and remember that a chart can inject
sidecars of its own (service-mesh proxies, exporters, log shippers) whose requests
land in the pod without ever appearing in the values you wrote.

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
| `authentik-postgresql-auth` | `platform` + `data` | `manifests/argocd/authentik/secrets/postgresql-auth.yaml` | PostgreSQL role `authentik` (init script, `data`) |
| `grafana-admin` | `monitoring` | `manifests/argocd/prometheus-stack/secrets/grafana-admin.yaml` | `grafana.admin.existingSecret` |
| `grafana-oidc` | `monitoring` | `manifests/argocd/prometheus-stack/secrets/grafana-oidc.env` | `grafana.envFromSecret` (`GF_AUTH_GENERIC_OAUTH_*` env) |
| `litellm-env` | `platform` | `manifests/argocd/litellm/secrets/litellm.env` | `litellm.environmentSecrets` |
| `litellm-db` | `platform` + `data` | `manifests/argocd/litellm/secrets/litellm-db.yaml` | `litellm.db.secret` + PostgreSQL init (`data`) |
| `litellm-masterkey` | `platform` | `manifests/argocd/litellm/secrets/litellm-masterkey.yaml` | `litellm.masterkeySecretName` |
| `mkcert-ca` | `cert-manager` | `manifests/built-in/cert-manager/secrets/mkcert-ca.yaml` | root CA for ClusterIssuer `local-ca` |
| `postgres-superuser` | `data` | `manifests/argocd/postgres/secrets/postgres-superuser.yaml` | PostgreSQL superuser (`POSTGRES_PASSWORD`) |
| `headlamp-oidc` | `ops` | `manifests/ops/headlamp/secrets/headlamp-oidc.env` | Headlamp OIDC client (`HEADLAMP_CONFIG_OIDC_*`) |
| `oauth2-proxy` | `ops` | `manifests/ops/headlamp/secrets/oauth2-proxy.env` | oauth2-proxy OIDC client + `cookie_secret` |
| `odoo-db` | `odoo` + `data` | `manifests/argocd/odoo/secrets/odoo-db.yaml` | Odoo's PostgreSQL role (`odoo`) |
| `redis-auth` | `data` | `manifests/argocd/redis/secrets/redis-auth.yaml` | Redis `requirepass` |
| `pgadmin-credentials` | `data` | `manifests/argocd/pgadmin/secrets/pgadmin-credentials.yaml` | pgAdmin initial login |
| `vaultwarden-env` | `vaultwarden` | `manifests/argocd/vaultwarden/secrets/vaultwarden.env` | Vaultwarden env (`ADMIN_TOKEN`, `DOMAIN`, …) |

Formats:
- `*.env` → created with `kubectl create secret generic --from-env-file` (e.g. `authentik.env`).
- `*.yaml` → a `kind: Secret` manifest (with `stringData`) applied with `kubectl apply -f`.

> **One credential, two namespaces.** A Secret is namespaced, and the database lives in `data` while its consumers live in `platform` — so `create-secrets.sh` applies `litellm-db.yaml` and `postgresql-auth.yaml` to **both** namespaces (`apply_yaml_secret_in_ns`, which rewrites the `namespace:` field of the manifest on the fly). The source file stays the single truth: rotate the password in one place, never in one namespace only.

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
  restart the workload. For an application role on the shared PostgreSQL the
  password is written to the database at init: besides the Secret, run `ALTER USER`
  on the database (the init script only creates a role that does not exist yet).
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

## kt-connect (ktctl)

[kt-connect](https://github.com/alibaba/kt-connect) connects the local machine to
the cluster network without exposing anything on the LAN: `ktctl` creates a
temporary *shadow pod* (`kt-connect-shadow`) in the target namespace and builds
the tunnel over the **API server's port-forward**. It lets you reach
ClusterIPs/Pod IPs from the host, redirect a Service's traffic to a local process
(`exchange`/`mesh`), and expose a local service inside the cluster
(`preview`/`forward`).

Nothing is installed permanently in the cluster: the dedicated RBAC lives in
`manifests/ops/kt-connect/` (`kt-connect` namespace, ServiceAccount + ClusterRole
scoped to what ktctl uses — **not cluster-admin**) and is applied with the `ops`
domain:

```bash
scripts/deploy-apps.sh ops
```

### Client (on this host)

```bash
curl -OL https://github.com/alibaba/kt-connect/releases/download/v0.3.7/ktctl_0.3.7_Linux_x86_64.tar.gz
tar zxf ktctl_0.3.7_Linux_x86_64.tar.gz
sudo mv ktctl /usr/local/bin/ && ktctl --version
```

### ServiceAccount kubeconfig

ktctl does not use `admin.conf`: it uses a kubeconfig for the `kt-connect` SA.
Generate it with:

```bash
scripts/kt-connect-kubeconfig.sh
export KUBECONFIG=$PWD/kubeconfig.kt-connect
```

The script applies the RBAC, waits for the controller to populate the token of
the `kt-connect-token` Secret (a long-lived token — k8s 1.24+ no longer creates
the Secret automatically) and writes `kubeconfig.kt-connect` with the cluster
server/CA + the SA token. It is gitignored.

### Usage

The `scripts/kt.sh` wrapper pins the kubeconfig, the shadow image and the DNS in
`hosts` mode (writes only to `/etc/hosts`, leaving the host's `/etc/resolv.conf`
alone). For `connect`, the shadow is created in the `kt-connect` namespace:

```bash
sudo scripts/kt.sh connect                     # root; reach ClusterIP/Pod IP from the host
scripts/kt.sh preview my-api --expose 8080 -n apps
scripts/kt.sh forward my-api 6060:8080 -n apps
scripts/kt.sh exchange my-api --expose 8080 -n apps
scripts/kt.sh mesh my-api --expose 8080 -n apps
scripts/kt.sh clean
```

> `connect` requires root (`/dev/net/tun` + route changes); `preview`, `forward`,
> `exchange` and `mesh` do not.
>
> ktctl **does not follow the kubeconfig context namespace**: the `--namespace`
> flag defaults to `default` and it is what decides where the shadow/Service is
> created. For `exchange`/`mesh` it is the target service's namespace; for
> `preview` it is where the local service is published. The wrapper only pins
> `-n kt-connect` for `connect`; the other commands take `-n <ns>`.

### Notes

- **Image**: the default is
  `registry.cn-hangzhou.aliyuncs.com/rdc-incubator/kt-connect-shadow:v0.3.7`
  (it does not exist on ghcr/Docker Hub). Override with `KT_SHADOW_IMAGE=...`.
- **Routes**: `connect` derives the CIDR from the actual IPs. Some pods use
  `hostNetwork` (cilium, cilium-envoy, cilium-operator, adguard) and report the
  node IP (`192.168.32.2`) as their podIP — so the computed pod range becomes
  `192.168.0.0/16` and would swallow the docker network. The wrapper already
  passes `--excludeIps 192.168.32.0/20` (tunable via `KT_EXCLUDE_IPS`), and the
  API IP is excluded automatically. The LAN (`192.168.1.0/24`) has a more
  specific route and is unaffected. If the local network uses `192.168.0.x`,
  adjust `KT_EXCLUDE_IPS`.
- **Names vs IPs**: routing covers the whole cluster by IP/ClusterIP. Name
  resolution via `/etc/hosts` (`--dnsMode hosts`) is limited to `--namespace`;
  to resolve other namespaces, pass
  `--dnsMode hosts:default,apps,data,platform,ops,argocd,monitoring,networking`.
- **Compatibility**: kt-connect v0.3.7 dates from 2022; on k8s 1.36 `connect`,
  `forward` and `preview` work, but `exchange`/`mesh` should be validated in
  practice.
- The shadow pod and ConfigMap are removed when the command exits (`Ctrl-C`);
  `ktctl clean` sweeps leftovers from interrupted runs.

---

## Usage Examples

### Simple Pod deployment

```bash
kubectl run nginx --image=nginx:alpine --port=80
kubectl get pods -w
```

### PVC with local-path (ReadWriteOnce)

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

### Shared volumes (ReadWriteMany)

`local-path` provisions node-local hostPath directories, so a PVC is **ReadWriteOnce**
only. There is no cluster filesystem for `ReadWriteMany` — use an application-level
mechanism (object storage, NFS, or a database) for shared data.

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
│   ├── deploy-apps.sh                  # On-demand kustomize apply (manifests/<domain>)
│   ├── create-secrets.sh               # Creates/updates Secrets from manifests/**/secrets/
│   ├── kt-connect-kubeconfig.sh        # Generates the SA kubeconfig used by ktctl
│   └── kt.sh                           # ktctl wrapper (kt-connect)
│
├── configs/
│   └── containerd-config.toml          # containerd: runc + cgroupfs + overlayfs
│
└── manifests/                          # Mounted ro into the container (only manifests/apps/ is gitignored)
    ├── built-in/                       # Core: applied by entrypoint.sh on every boot
    │   ├── argocd/                     # Namespace for Argo CD
    │   ├── cert-manager/               # Internal *.lan certificates (mkcert CA)
    │   ├── coredns/                    # CoreDNS + .lan hosts block
    │   ├── haproxy-ingress/            # HAProxy Ingress Controller
    │   ├── local-path/                 # local-path-provisioner + default StorageClass
    │   ├── metallb/                    # MetalLB L2 (LoadBalancer VIP)
    │   └── metrics-server/             # metrics.k8s.io API
    ├── argocd/                         # Argo CD Applications (one dir per app)
    │   ├── authentik/                  # Helm chart + blueprint + secrets/
    │   ├── litellm/                    # OCI chart + secrets/
    │   ├── odoo/                       # Application (source: this repo)
    │   ├── opensearch/                 # Application (source: this repo)
    │   ├── pgadmin/                    # Application (source: this repo)
    │   ├── postgres/                   # Application (source: this repo)
    │   ├── prometheus-stack/           # Helm chart + ingress/cert
    │   ├── redis/                      # Application (source: this repo)
    │   └── vaultwarden/                # Application (source: this repo)
    ├── networking/
    │   └── adguard/                    # AdGuard Home (LAN/tailnet DNS)
    ├── ops/
    │   ├── argocd/                     # Ingress + Certificate for argocd.lan (versioned)
    │   ├── headlamp/                   # Dashboard, oauth2-proxy, ingress/cert
    │   │   └── plugin-logout/          # Custom "Sair" plugin (ConfigMap)
    │   └── kt-connect/                 # ktctl RBAC (SA + ClusterRole + token)
    ├── odoo/                           # Odoo (own manifests — source of the Application)
    ├── opensearch/                     # OpenSearch + Dashboards (own manifests)
    ├── pgadmin/                        # pgAdmin 4 (own manifests)
    ├── postgres/                       # PostgreSQL 18 shared instance (own manifests)
    ├── redis/                          # Redis (own manifests)
    ├── vaultwarden/                    # Vaultwarden (own manifests)
    └── apps/                           # GITIGNORED — on demand via deploy-apps.sh
        └── tileserver/                 # TileServer GL (hostpath-tiles PVC)
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
10s   ▶ cilium install (clean reinstall every boot)
35s   ▶ Node Ready ✓
40s   ▶ CoreDNS, local-path-provisioner, HAProxy applied
```

> On subsequent restarts (images already cached), boot drops to ~1-2 min. Provisioned volume data survives via `data/local-path/`.

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
- **Pod CIDR**: `192.168.0.0/16` (set explicitly via `ipam.operator.clusterPoolIPv4PodCIDRList`; must contain nodes' podCIDRs and be disjoint from `SERVICE_CIDR`)
- **Network Policy**: ✅ supported (CiliumNetworkPolicy + k8s NetworkPolicy)
- **IPAM**: cluster-pool (default)
- **kube-proxy replacement**: disabled (kube-proxy runs alongside)
- **Hubble**: ✅ observability & monitoring

Cilium is installed via the Cilium CLI, which manages the Helm chart and provides status monitoring. The entrypoint reinstalls it on **every boot**: its `cilium_healthy()` check runs `cilium status --brief`, a flag that does not exist in CLI v0.19.4, so the check always fails and forces a clean reinstall. That reinstall is load-bearing — after the `k8s-one` container is recreated, the pod→ClusterIP datapath is left stale and only reinstalling Cilium restores it.

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

**AdGuard Home** (`networking/adguard`) is the LAN/tailnet DNS and resolves the internal `*.lan` names to the cluster. CoreDNS still owns `cluster.local` (in-cluster DNS) — AdGuard is for accessing apps by name.

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
- **Certificates (cert-manager + mkcert)**: the `ClusterIssuer local-ca` uses the **mkcert root CA** (`~/.local/share/mkcert/rootCA.pem`, imported into Secret `cert-manager/mkcert-ca`). The `Certificate dns-lan` issues `dns.lan` + `*.lan` into Secret `networking/dns-lan-tls`, referenced by the Ingress. To avoid browser warnings, install the mkcert CA into each device's trust store (already done on the host via `mkcert -install`).
- **Tailscale**: global nameserver = `192.168.1.20` and the `192.168.1.0/24` route advertised + approved — tailnet devices resolve `*.lan` via AdGuard and reach `192.168.1.20`. **IPv6 (RA) must be off on the router**: the IPv6 DNS advertisement (`fc00::a/b`) is preferred by Android and breaks `*.lan` resolution.

### Remote access (outside the LAN, via Tailnet)

Works from anywhere with Tailscale on: the tailnet DNS (global nameserver `192.168.1.20`) resolves `*.lan` via AdGuard, and the `192.168.1.0/24` subnet route forwards traffic to `192.168.1.20` (host) → Ingress → app. E.g. `https://argocd.lan` away from home.

> **Gotcha (Termux):** Termux uses its **own** `resolv.conf` (`$PREFIX/etc/resolv.conf`, pointing at `8.8.8.8`) — so `nslookup`/`curl` inside Termux do **not** resolve `.lan`, even though the browser works. Diagnosis:
> - `nslookup argocd.lan 192.168.1.20` → queries AdGuard directly (works).
> - `nslookup argocd.lan 100.100.100.100` → tailnet MagicDNS (works if the tailnet DNS is applied on the device).
> To test access, use the **browser** (it uses the system DNS).
- **Router (LAN)**: DHCP hands out `192.168.1.20` as primary DNS (optional `1.1.1.1` fallback). Note: with the host down, clients that only have `192.168.1.20` lose DNS.

## Workloads

### Overview

Workloads are delivered two ways:

- **Argo CD Applications** — the default: nine Applications, each pointing at a Helm chart (third-party or OCI) or at a path in this repository. The Application manifests live under `manifests/argocd/<app>/`.
- **`scripts/deploy-apps.sh`** — kustomize, on demand: applies the domain trees under `manifests/` for AdGuard (**networking**), Headlamp and the Argo CD Ingress (**ops**) and the TileServer (**apps**).

| Application | Source |
|---|---|
| `authentik` | Helm chart `authentik` (`goauthentik`) |
| `kube-prometheus-stack` | Helm chart `kube-prometheus-stack` (`prometheus-community`) |
| `litellm` | OCI Helm chart `ghcr.io/berriai/litellm-helm` |
| `odoo` | this repo — `manifests/odoo` |
| `opensearch` | this repo — `manifests/opensearch` |
| `pgadmin` | this repo — `manifests/pgadmin` |
| `postgres` | this repo — `manifests/postgres` |
| `redis` | this repo — `manifests/redis` |
| `vaultwarden` | this repo — `manifests/vaultwarden` |

### Argo CD (`argocd.lan`)

Accessible at `https://argocd.lan` (Ingress ns `argocd` → `argocd-server:80`, mkcert TLS `argocd.lan`). **Requires `--insecure` on `argocd-server`**: without it, the ingress (which terminates TLS and forwards plain HTTP to the backend) causes a 307 redirect loop. The patch is re-applied by `entrypoint.sh` after applying the upstream `install.yaml` (persistent across reboots).

Login: user `admin`, password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```
> **Tip:** login uses user `admin` + the password from the secret above (it matches the hash in `argocd-secret`/`admin.password`). If the browser rejects it, check **autofill/cache** (type the password manually; hard refresh or incognito) — it is not the headlamp/dns password.

Ingress/cert manifests: `manifests/ops/argocd/` (versioned in this repo).

### Headlamp (`headlamp.lan`)

Dashboard at `https://headlamp.lan` (ingress routes by Host; mkcert cert `headlamp.lan`). Login is **SSO through Authentik**, via an **oauth2-proxy** in front of Headlamp.

**Architecture (why the proxy):** Headlamp has two mutually exclusive OIDC modes:
- **Native OIDC**: requires login and forwards the user's token to the API. Since this cluster's `kube-apiserver` has **no** `--oidc-*` flags, the API rejects the token (401, "the cluster did not accept your sign-in").
- **Service account** (`HEADLAMP_CONFIG_UNSAFE_USE_SERVICE_ACCOUNT_TOKEN=true`): authenticates everyone through the SA, but **requires no login** — safe only behind an auth proxy.

We chose the 2nd + a proxy: `browser → ingress → oauth2-proxy → Headlamp`. The `oauth2-proxy` (ns `ops`, `09-oauth2-proxy.yaml`) runs the OIDC against Authentik (provider "Headlamp", redirect `https://headlamp.lan/oauth2/callback`) and keeps the session in a cookie; the ingress points at it, not at Headlamp. Without a valid session, nothing reaches Headlamp.

RBAC: SA `headlamp-admin` (ns `ops`) → ClusterRole **`headlamp-admin`** — broad admin, but **without `delete` on namespaces, PVs and PVCs** (a data guardrail; see `03-cluster-role.yaml`). Login controls who gets in; the API permission is the SA's (shared admin).

Relevant Headlamp env (`05-deployment.yaml`): `HEADLAMP_CONFIG_UNSAFE_USE_SERVICE_ACCOUNT_TOKEN=true` + `HEADLAMP_CONFIG_PROXY_AUTH=true` (trusts the proxy's `X-Forwarded-*` headers). The client_id/secret is the same `HEADLAMP_OIDC_*` pair from the blueprint, stored in the gitignored `oauth2-proxy` Secret (`create-secrets.sh`), together with the `cookie_secret`.

> Per-user alternative (not used): configure OIDC on the `kube-apiserver` itself (`--oidc-*`) + per-identity RBAC — it changes the model to per-user and requires rebuilding/recreating the container.

**Logout ("Sair"):** Headlamp has no server-side logout (the native button only clears the local token, and the real session is the `_oauth2_proxy` cookie). That is why there is a **custom plugin** (`plugin-logout/`, mounted at `/headlamp/static-plugins/logout` via ConfigMap) that adds a **Sair** button to the app bar. It goes to `/oauth2/sign_out?rd=<Authentik end-session>`: it clears the proxy cookie **and** ends the SSO session at Authentik, returning to the login. The plugin is hand-written in UMD (Headlamp injects the modules into `window.pluginLib`), with no toolchain/npm.

Token fallback (when the prompt asks for a token):

```bash
kubectl -n ops get secret headlamp-admin-token -o jsonpath='{.data.token}' | base64 -d
```

The `headlamp-admin-token` secret (type `kubernetes.io/service-account-token`) is long-lived (K8s 1.24+). Since Headlamp runs with `--in-cluster`, it may authenticate automatically via the projected token — the command above is for when the login prompt asks for a token.

### Authentik (`authentik.lan`)

Identity provider at `https://authentik.lan` (chart `authentik` 2026.8.1, ns `platform`, mkcert cert `authentik-tls`). Its database is the **shared PostgreSQL 18 of the `data` namespace** (see [PostgreSQL (data)](#postgresql-data) below) — database `authentik`, owned by the role `authentik` — so the chart's embedded `postgresql:` is `enabled: false` and the connection comes entirely from the `authentik-config` Secret (`AUTHENTIK_POSTGRESQL__*`, delivered to server and worker by `envFrom`). It is here to be the **single login** for the cluster's apps; wired to it so far: LiteLLM, Headlamp, Grafana and pgAdmin (Argo CD planned).

Groups, providers and applications are **declarative**, via a blueprint the chart mounts into the worker:

```bash
kubectl apply -f manifests/argocd/authentik/03-blueprint.yaml    # the blueprint ConfigMap
kubectl apply -f manifests/argocd/authentik/02-application.yaml  # then let Argo CD sync the chart
```

- `manifests/argocd/authentik/03-blueprint.yaml` is a ConfigMap holding **four** blueprints, one per app: `litellm-oidc.yaml` (group `litellm-users`, OAuth2 provider `LiteLLM`, application and bindings), `headlamp-oidc.yaml` (same, for Headlamp — with oauth2-proxy running the flow), `grafana-oidc.yaml` (same, for Grafana, which speaks OIDC natively) and `pgadmin-oidc.yaml` (same, for pgAdmin, also OIDC-native — see its section below).
- It is applied with **`kubectl`, never through Helm**: blueprint tags (`!Find`, `!KeyOf`, `!Env`) are custom YAML, and Helm's `values → toYaml` round-trip destroys them (they arrive in the cluster as bare strings and the blueprint fails).
- The chart mounts every name in `blueprints.configMaps` (in `02-application.yaml`) into the **worker** at `/blueprints/mounted/cm-<name>`; the worker discovers all `*.yaml` there.
- **Discovery is event-driven, not boot-time.** What triggers it is the file watcher (`on_created`/`on_modified`) plus an **hourly** scheduled run. A ConfigMap that is already populated when the worker starts fires nothing — the mount happens before the process is up. To force it without waiting: change the ConfigMap **data** (e.g. a comment in the blueprint) and the kubelet resyncs the volume, producing the events. `kubectl annotate` does **not** work: metadata does not make the kubelet resync.
- **Idempotency comes from `identifiers`**, not from `id`: the importer builds a `filter()` from `identifiers` and, if it finds the object, updates it (`partial=True`); otherwise it creates. The entry `id` exists only so other entries can point at it with `!KeyOf`. An entry without `identifiers` aborts with "No or invalid identifiers".
- **List-valued fields have an empty default and must be declared.** `grant_types` is `ArrayField(..., default=list)` on the model: the UI wizard fills it in, a blueprint does not. Omit it and the provider is created with `grant_types = {}` — it then rejects every grant (`Invalid grant_type for provider` in the server log) and `/authorize` answers `invalid_request`, which looks like a completely unrelated bug. Same trap for any other `ArrayField` (`property_mappings` above is the same shape, with a less obvious symptom: a token without the `email` claim).
- **The client credentials are `!Env`**, resolved against the worker's environment — which receives **every key** of the `authentik-config` Secret (`envFrom`). They live in `secrets/authentik.env` (gitignored). Note `!Env` returns `None` for a missing variable instead of failing loudly, so the salt is on the other side: the authentik serializer rejects a null `client_secret`, and the sync errors out.
- **The admin's email is kept in sync with the Secret.** `AUTHENTIK_BOOTSTRAP_EMAIL` is only consumed when the database is created — fix the email afterwards and the user keeps the old one. That matters beyond tidiness: the email is what LiteLLM uses to provision its own user on first login. So the blueprint carries an `authentik_core.user` entry setting `email: !Env AUTHENTIK_BOOTSTRAP_EMAIL` (the value stays in the gitignored Secret rather than being written into a tracked file). The importer's `partial=True` means only that field is touched on the admin user.

Admin login is `akadmin`:

```bash
kubectl -n platform get secret authentik-config -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_EMAIL}' | base64 -d; echo
kubectl -n platform get secret authentik-config -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}' | base64 -d; echo
```

> The password above is the **bootstrap** value: it is consumed when the database is created. Editing it in `secrets/authentik.env` afterwards does **not** change the password of an existing `akadmin` — that is done in the UI (`Settings → Password`) or by resetting the flow.

### LiteLLM (`litellm.lan`)

OpenAI-compatible proxy at `https://litellm.lan` (Ingress ns `platform` → `litellm:4000`, dedicated mkcert cert `litellm-tls`). The database is **the cluster's shared PostgreSQL 18** (ns `data`, database `litellm`, `?schema=litellm`) — the same instance that serves the Authentik, in a database of its own.

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
- **One PreSync hook runs before every sync**: the chart's own `litellm-migrations` job, which runs `prisma migrate deploy` before the Deployment. It is safe to re-run. Nothing creates the role/database/schema at sync time — they are born with the instance, from the init script of the shared PostgreSQL (`manifests/postgres/03-configmap-initdb.yaml`).
- **`ENFORCE_PRISMA_MIGRATION_CHECK=true` is required too.** Without it LiteLLM logs "migration failed but continuing startup" and **exits 0** — the Job shows as `Completed` against a half-migrated database. With it, a migration failure fails the hook and stops the sync.
- **Memory**: 2Gi limit, not less. Both the migration job (~1.7Gi peak) and the proxy are OOMKilled at 1Gi. `strategy: Recreate` avoids two proxies during a rollout on this single, memory-tight node.
- **Metrics need the callback**: `/metrics` only exists when `litellm_settings.callbacks: [prometheus]` is set — without it LiteLLM returns 404 and the Prometheus target stays DOWN (the ServiceMonitor itself works: the scrape does happen). With the callback on, the endpoint also demands the API key, hence `require_auth_for_metrics_endpoint: false` (it is a ClusterIP endpoint).

Manifests: `manifests/argocd/litellm/`. Secrets: see the table above.

### Grafana (`grafana.lan`)

Cluster metrics and dashboards: `kube-prometheus-stack` (chart 90.0.0, ns `monitoring`), with Grafana `13.2.1-distroless`, a 10Gi `local-path` PVC and the datasource/dashboard sidecars reading ConfigMaps. Served at `https://grafana.lan` — Ingress `grafana` + Certificate `grafana-tls` (`manifests/argocd/prometheus-stack/03-certificate.yaml` and `04-ingress.yaml`, applied with `kubectl apply -f`, because the Application points at the third-party chart and not at this repo).

**SSO through Authentik** (provider `Grafana`, blueprint `grafana-oidc.yaml`). Grafana speaks OIDC **natively** — no proxy in front like Headlamp; Authentik only delivers the claims:

- Access through the **`grafana-users`** group (Application binding, a single place: Grafana does not use `allowed_groups`).
- **Role from the group**, via `role_attribute_path` (JMESPath): `grafana-admins` → `GrafanaAdmin`, everyone else → `Viewer`. Unlike LiteLLM there is **no** custom scope mapping here: Grafana evaluates the `groups` claim, and that claim already comes from the `profile` scope. What Grafana compares is the **group name**, so the group→role mapping lives in `grafana.ini`, not in the blueprint.
- `role_attribute_strict = true`: if the `groups` claim is missing the login is **denied** instead of silently demoting everyone to `Viewer` (the LiteLLM lesson, which fell back to `internal_user_viewer` without telling anyone). `allow_assign_grafana_admin = true` is what makes the `GrafanaAdmin` above count as a **server** admin; without it it would only be org Admin.
- The role is re-synced on every login: promoting/demoting someone means editing the group in Authentik, not Grafana.
- The local login (`admin` + the `grafana-admin` secret) **still works** — it is the break-glass path (it does not go through Authentik) and it is what the dashboard sidecars use to talk to the local API.

Three details that are expensive to get wrong:

- **`root_url` is mandatory.** The flow's `redirect_uri` is derived from it; without `root_url` Grafana builds the URL from the request `Host` (which arrives as `http`, behind the ingress) and Authentik rejects it for not matching the `https://grafana.lan/login/generic_oauth` registered on the provider.
- **The mkcert CA is mounted, through `extraSecretMounts`.** The pod is distroless (no shell) and runs with a read-only rootfs, so there is no way to concatenate a bundle the way LiteLLM does: the `ca.crt` from the `grafana-tls` secret itself is mounted (every cert-manager tls secret carries the issuer's `ca.crt`) and `tls_client_ca` points at it — the Go equivalent of oauth2-proxy's `--provider-ca-file`. Do **not** use `extraVolumes` for this: the chart template only renders `existingClaim`/`hostPath`/`csi`/`configMap`/`emptyDir`, and a `secret:` volume falls silently into an empty `emptyDir` — the pod comes up, the file does not exist, and SSO only fails at login time, far from the cause.
- **The credential never enters `grafana.ini`.** The client_id/secret pair comes from the `grafana-oidc` Secret as `GF_AUTH_GENERIC_OAUTH_*` env vars (`envFromSecret`), which override the ini — that is what the chart's `assertNoLeakedSecrets` checks at render time.

Manifests: `manifests/argocd/prometheus-stack/`. Secrets: see the table above.

### Namespace `data`

The apps in namespace `data` are "app-style": their own manifests in `manifests/<app>/` plus an Application in `manifests/argocd/<app>/`, with `local-path` PVCs. It hosts the shared database and the supporting services around it.

#### PostgreSQL (data)

The cluster's **shared database instance**: one PostgreSQL 18.6 — the official `postgres:18.6` image, no chart — in namespace `data`, serving the apps that need a real SQL database, each in its **own database and role**: `litellm` (role `litellm`, schema `litellm`, Prisma's), `authentik` (role `authentik`, Django's) and `odoo` (role `odoo`). One instance, three tenants: the roles are created with least privilege (`NOSUPERUSER NOCREATEDB NOCREATEROLE`) and the superuser never leaves the pod.

Its manifests are versioned in this repo, under `manifests/postgres/`, because there is no upstream chart to pin — only the official image. The Application `postgres` (`manifests/argocd/postgres/02-application.yaml`) therefore follows the vaultwarden pattern: `source` pointing at this repository, `path: manifests/postgres`, where a `kustomization.yaml` composes the PVC, the Deployment, the init ConfigMap and the Service (Argo CD detects kustomize on its own). The PVC carries `Prune=false,Delete=false` — it holds real data and must not vanish when the Application is pruned or deleted.

In-cluster the address is `postgres.data.svc.cluster.local:5432`, which is how LiteLLM, Authentik and Odoo connect. From the host, the Service is a NodePort (`30432`) that `docker-compose` publishes as `127.0.0.1:5432:30432` — **loopback on purpose**: every other published port exists so the LAN can reach the host, but the database must not leave it. NodePort and not LoadBalancer for the same reason the ingresses are: the MetalLB VIP is announced inside the cluster's docker network and is unreachable from the LAN. And `30432` and not `5432` because a NodePort has to sit in the apiserver's 30000-32767 range.

Authentication is `scram-sha-256` for every remote connection: the image's entrypoint appends `host all all all scram-sha-256` to `pg_hba.conf`, and that line catches all TCP — including the traffic that arrives through the NodePort. The only `trust` left is the unix socket and the loopback *inside* the pod (initdb's default), unreachable from outside, since NodePort traffic arrives with the client's source IP, never `127.0.0.1`. `POSTGRES_HOST_AUTH_METHOD` is deliberately left unset — setting it to `trust` would be a passwordless superuser. The superuser password lives in the gitignored Secret `postgres-superuser`; each application only ever receives the credentials of its own role, in Secrets applied to **both** `platform` and `data` (see [Secrets](#secrets)).

> **The volume mounts at `/var/lib/postgresql`, not at `/var/lib/postgresql/data`.** In PostgreSQL 18 the image moved `PGDATA` to `/var/lib/postgresql/18/docker` with the `VOLUME` declared on the parent, and mounting at the v15–v17 path makes the entrypoint abort at boot with "there appears to be PostgreSQL data in: /var/lib/postgresql/data (unused mount/volume)". Leaving `PGDATA` at its default is also what keeps `pg_upgrade --link` viable for a future major upgrade.

#### Redis

Single-node cache in namespace `data`: a `redis:8-alpine` StatefulSet with AOF+RDB persistence, a 1Gi `local-path` PVC and a ClusterIP Service at `redis.data.svc:6379`. The password comes from the `redis-auth` Secret and is passed as `--requirepass` on the command line — `redis.conf` does not expand environment variables, so it cannot live in the ConfigMap. **In-cluster access only**: no NodePort, no Ingress, no external exposure — a deliberate decision.

#### OpenSearch + Dashboards

`opensearchproject/opensearch:3.3.2`, single-node, with the security plugin **disabled** (`DISABLE_SECURITY_PLUGIN=true` — no internal auth/TLS), a 512m heap and `bootstrap.memory_lock`, a 10Gi `local-path` PVC and a ClusterIP Service on 9200/9600. The UI is `opensearchproject/opensearch-dashboards:3.0.0` at `https://opensearch.lan` (Ingress + Certificate in namespace `data`). Requires `vm.max_map_count>=262144` on the host (already set).

#### pgAdmin

`dpage/pgadmin4:9.18.0`, login from the `pgadmin-credentials` Secret, with a `servers.json` ConfigMap that already points at the cluster's PostgreSQL (`postgres:5432`), a 2Gi `local-path` PVC and a UI at `https://pgadmin.lan`. It runs **non-root** (uid 5050) without privilege escalation: because the image's Python carries the file capability `cap_net_bind_service`, `drop [ALL] + add NET_BIND_SERVICE` is kept in the bounding set (otherwise the Python exec fails with EPERM); `PGADMIN_DISABLE_POSTFIX=1` removes the only `sudo`, and it listens on 8080 (`PGADMIN_LISTEN_PORT`). Measured in the pod: uid 5050 and CapEff=0.

**SSO via Authentik** (provider `PgAdmin`, blueprint `pgadmin-oidc.yaml`). pgAdmin speaks OIDC **natively** with discovery (`OAUTH2_SERVER_METADATA_URL`), like Grafana — no proxy in front. Access is restricted to the **`pgadmin-users`** group:

- **Double gate**: the Application binding in Authentik decides *who gets in*; on the pgAdmin side, `OAUTH2_ADDITIONAL_CLAIMS = {'groups': ['pgadmin-users']}` rejects the login if the id_token lacks the group (which is why the provider sets `include_claims_in_id_token: true` — otherwise the claim would only be in the userinfo).
- The provider is read **only** from the `PGADMIN_CONFIG_OAUTH2_CONFIG` env (the whole list, a Python literal). Individual variables (`PGADMIN_CONFIG_OAUTH2_CLIENT_ID` etc.) are **ignored** — pgAdmin only logs a warning at boot. Documented gotcha.
- The client_id/secret pair comes from the `pgadmin-oidc` Secret (the same `PGADMIN_OIDC_*` values as `authentik.env`) and is injected into the manifest via `$(PGADMIN_OIDC_CLIENT_ID)`/`$(PGADMIN_OIDC_CLIENT_SECRET)` — the secret is never committed.
- **TLS**: the pod validates the id_token against the `authentik.lan` JWKS, so it mounts the `ca.crt` of the `pgadmin-tls` secret (every cert-manager tls secret carries the issuer CA) at `/etc/pgadmin/mkcert-ca`, pointed to by `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE`. Without it the token exchange dies with an x509 error (the image does not know mkcert). Less secure alternative: `'OAUTH2_SSL_CERT_VERIFICATION': False` in the provider.
- The local login (`pgadmin-credentials`) remains as an **emergency** fallback (`AUTHENTICATION_SOURCES = ['oauth2', 'internal']`, like Grafana/ArgoCD).
- The redirect registered in the provider is `https://pgadmin.lan/oauth2/authorize`. With OAuth2 there is no user password, so to **save** the Postgres password pgAdmin asks for a *master password* on first use (`MASTER_PASSWORD_REQUIRED`, default).

### Vaultwarden (`vault.lan`)

Bitwarden vault at `https://vault.lan` (namespace `vaultwarden`). An Argo CD Application from this repository (`manifests/vaultwarden`), with a 1Gi `local-path` PVC and mkcert TLS.

### Odoo (`odoo.lan`)

ERP at `https://odoo.lan` (namespace `odoo`). An Argo CD Application from this repository (`manifests/odoo`), with a 5Gi `local-path` PVC; its database lives in the shared PostgreSQL (database/role `odoo`, credentials in `odoo-db`).

### TileServer (`tiles.naesquina.com.br`)

Map tiles at `https://tiles.naesquina.com.br` (namespace `tileserver`). Applied **on demand** by `scripts/deploy-apps.sh` (`manifests/apps/tileserver`, the only gitignored tree), from a `hostpath-tiles` PVC (Reclaim `Retain`, `ReadOnlyMany`) — not `local-path`.

---

## Storage

### local-path-provisioner

Storage is provided by **local-path-provisioner** (Rancher v0.0.30) in the
`local-path-storage` namespace. It dynamically provisions volumes as hostPath
directories under `/opt/local-path-provisioner`, persisted on the host by the
`./data/local-path` bind mount.

- **Provisioner**: `rancher.io/local-path`
- **Data path**: `/opt/local-path-provisioner` (bind mount from `./data/local-path`)

| StorageClass | Provisioner | Access | Binding | Reclaim | Expansion |
|---|---|---|---|---|---|
| `local-path` (**default**) | `rancher.io/local-path` | RWO | `WaitForFirstConsumer` | `Delete` | not supported |

```bash
kubectl get sc
# NAME                   PROVISIONER             RECLAIMPOLICY  VOLUMEBINDINGMODE
# local-path (default)   rancher.io/local-path   Delete         WaitForFirstConsumer
```

Volumes are **not redundant**: they live as plain directories on the host disk
under `data/local-path/`. Back that directory up if the data matters. Since
`local-path` has no online expansion, PVC sizes are fixed (`allowVolumeExpansion`
is unset).

---

## Known Issues

### local-path has no online expansion

- **Symptom:** editing a PVC's `resources.requests.storage` is rejected.
- **Cause:** the `local-path` StorageClass does not set `allowVolumeExpansion`.
- **Workaround:** recreate the PVC and restore the data (or migrate to a new
  larger PVC). Sizes are fixed at creation.

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

### PVC stuck in Pending

`local-path` uses `volumeBindingMode: WaitForFirstConsumer`, so a PVC stays
`Pending` until a pod that consumes it is scheduled. That is expected, not a failure.

```bash
kubectl describe pvc <pvc-name> -n <namespace>
kubectl -n local-path-storage logs deploy/local-path-provisioner
```

Common causes:
- No pod consuming the PVC yet → `WaitForFirstConsumer` is doing its job
- Provisioner not Running → check the logs above
- Volume data missing after a container recreate → confirm the `./data/local-path` bind mount exists

### CoreDNS CrashLoopBackOff

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns
```

Common causes:
- Loop detection → already fixed with forward to 8.8.8.8
- Corefile syntax error → check `manifests/built-in/coredns/04-configmap.yaml`

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
docker compose down -v   # removes container + all named volumes (keeps ./data/local-path/)
docker compose up -d     # fresh start
# To also wipe volume data: rm -rf data/local-path/*  (irreversible!)
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
| **Disk** | 10 GB (image + volume data) | 20 GB+ |
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
| `5432` | TCP | PostgreSQL (→ NodePort 30432, **host loopback only**) |

---

## Limitations

- **Not HA**: single node, no redundancy. etcd, apiserver, etc. are single-instance.
- **Not for production**: intended for development, testing, CI/CD, lab environments.
- **Storage without redundancy**: `local-path` volumes are plain hostPath directories on the host disk.
- **Privileged mode**: the container runs with `--privileged` (required for kubelet/containerd).
- **amd64 only**: arm64 may work with `--build-arg TARGETARCH=arm64` but is untested.
- **No systemd**: uses `cgroupfs` as cgroup driver (no systemd inside the container).
- **Cert rotation**: disabled. Certificates last 10 years. For long-lived clusters, consider implementing rotation.

---

## License

MIT
