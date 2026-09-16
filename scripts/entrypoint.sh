#!/bin/bash
set -euo pipefail

# ===========================================================================
# K8s-One: Single-Node Kubernetes Cluster — Entrypoint
# Starts all control-plane + node components from scratch.
# ===========================================================================

NODE_NAME="${NODE_NAME:-k8s-one}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.1}"
CLUSTER_CIDR="192.168.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
CLUSTER_DNS="10.96.0.10"
API_PORT=6443

PKI="/etc/kubernetes/pki"
KUBE="/etc/kubernetes"
MANIFESTS="/opt/manifests"

declare -a PIDS=()
CONTAINERD_PID=""
ETCD_PID=""
APISERVER_PID=""
CONTROLLER_MANAGER_PID=""
SCHEDULER_PID=""
KUBELET_PID=""
KUBE_PROXY_PID=""
APPLY_PID=""
SHUTTING_DOWN=0

log()  { echo "[k8s-one] $(date -u '+%H:%M:%S') $*"; }
die()  { log "FATAL: $*"; exit 1; }

if [[ ! "$ARGOCD_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "ARGOCD_VERSION must use the vX.Y.Z format (received: $ARGOCD_VERSION)"
fi

# ── Ordered shutdown ──────────────────────────────────────────────────────
stop_pid() {
  local label=$1 pid=${2:-} tries=${3:-20}
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0

  log "Stopping $label..."
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$tries" -gt 0 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    tries=$((tries - 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    log "WARNING: $label did not stop gracefully; sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

storage_mounts_active() {
  # RBD-backed filesystems and CephFS mounts must disappear before the Ceph
  # pods are stopped. Otherwise krbd/ceph can remain blocked in the kernel and
  # prevent the outer Docker container from being recreated.
  findmnt -rn -o SOURCE,FSTYPE,TARGET 2>/dev/null | awk '
    $1 ~ /^\/dev\/rbd/ || $2 == "ceph" || $2 == "fuse.ceph" { found=1 }
    END { exit !found }
  '
}

stop_storage_consumers() {
  if ! kubectl --kubeconfig="$KUBE/admin.conf" get --raw=/readyz >/dev/null 2>&1; then
    log "API unavailable; skipping Kubernetes storage drain."
    return 0
  fi

  local kc="kubectl --kubeconfig=$KUBE/admin.conf"
  log "Cordoning $NODE_NAME and stopping pods that use PVCs..."
  $kc cordon "$NODE_NAME" >/dev/null 2>&1 || true

  local -A consumers=()
  local namespace pod claim key
  while IFS=$'\t' read -r namespace pod claim; do
    [ -n "${namespace:-}" ] && [ -n "${pod:-}" ] && [ -n "${claim:-}" ] || continue
    consumers["$namespace/$pod"]+="$claim,"
  done < <($kc get pods -A -o go-template='{{range .items}}{{ $namespace := .metadata.namespace }}{{ $pod := .metadata.name }}{{range .spec.volumes}}{{if .persistentVolumeClaim}}{{printf "%s\t%s\t%s\n" $namespace $pod .persistentVolumeClaim.claimName}}{{end}}{{end}}{{end}}' 2>/dev/null || true)

  for key in "${!consumers[@]}"; do
    namespace=${key%%/*}
    pod=${key#*/}
    log "Stopping storage consumer $key (PVC: ${consumers[$key]%,})"
    $kc -n "$namespace" delete pod "$pod" --grace-period=30 --wait=false >/dev/null 2>&1 || true
  done

  local tries=120
  while [ "$tries" -gt 0 ]; do
    if ! storage_mounts_active && ! compgen -G '/sys/bus/rbd/devices/*' >/dev/null; then
      log "RBD and CephFS volumes are cleanly detached."
      return 0
    fi
    sleep 1
    tries=$((tries - 1))
  done
  log "WARNING: storage mounts did not detach within 120s; continuing shutdown."
}

stop_containerd_tasks() {
  local -a tasks=()
  mapfile -t tasks < <(ctr -n k8s.io tasks list -q 2>/dev/null || true)
  [ "${#tasks[@]}" -gt 0 ] || return 0

  log "Stopping ${#tasks[@]} remaining Kubernetes container task(s)..."
  local task
  for task in "${tasks[@]}"; do
    ctr -n k8s.io tasks kill --signal SIGTERM "$task" >/dev/null 2>&1 || true
  done

  local tries=30
  while [ "$tries" -gt 0 ]; do
    mapfile -t tasks < <(ctr -n k8s.io tasks list -q 2>/dev/null || true)
    [ "${#tasks[@]}" -eq 0 ] && return 0
    sleep 1
    tries=$((tries - 1))
  done

  log "WARNING: forcing ${#tasks[@]} container task(s) to stop."
  for task in "${tasks[@]}"; do
    ctr -n k8s.io tasks kill --signal SIGKILL "$task" >/dev/null 2>&1 || true
  done
}

cleanup() {
  [ "$SHUTTING_DOWN" -eq 0 ] || return 0
  SHUTTING_DOWN=1
  trap - SIGTERM SIGINT
  log "Starting ordered cluster shutdown..."

  # Stop reconciliation first so deleted storage consumers are not recreated.
  stop_pid "manifest reconciler" "$APPLY_PID" 5
  if kubectl --kubeconfig="$KUBE/admin.conf" get --raw=/readyz >/dev/null 2>&1; then
    kubectl --kubeconfig="$KUBE/admin.conf" cordon "$NODE_NAME" >/dev/null 2>&1 || true
  fi
  stop_pid "kube-scheduler" "$SCHEDULER_PID" 10
  stop_pid "kube-controller-manager" "$CONTROLLER_MANAGER_PID" 10

  # Keep kubelet, the API and Ceph alive until every application volume has
  # been unpublished by CSI.
  stop_storage_consumers
  stop_pid "kubelet" "$KUBELET_PID" 20
  stop_pid "kube-proxy" "$KUBE_PROXY_PID" 10
  stop_containerd_tasks

  # The control plane and runtime can now stop in reverse dependency order.
  stop_pid "kube-apiserver" "$APISERVER_PID" 20
  stop_pid "etcd" "$ETCD_PID" 20
  stop_pid "containerd" "$CONTAINERD_PID" 20
  losetup -d /dev/loop0 2>/dev/null || true

  log "Ordered cluster shutdown complete."
  exit 0
}
trap cleanup SIGTERM SIGINT

# ── Setup mount propagation (required for Cilium BPF + kubelet) ───────────
setup_mounts() {
  mount --make-rshared / 2>/dev/null || true
  mount --make-rshared /sys 2>/dev/null || true
  # Ensure BPF filesystem is mounted
  if ! mountpoint -q /sys/fs/bpf 2>/dev/null; then
    mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
  fi

  # Docker hands the container a plain tmpfs /dev, which does NOT auto-create
  # device nodes for kernel block devices (e.g. /dev/nbdN for the rbd-nbd
  # mounter, /dev/rbdN for krbd). Mounting devtmpfs makes the kernel create
  # them instantly (and also exposes loop devices for the Ceph OSD).
  if ! grep -q ' /dev devtmpfs ' /proc/self/mounts 2>/dev/null; then
    if mount -t devtmpfs devtmpfs /dev 2>/dev/null; then
      log "devtmpfs mounted on /dev."
      # Restore convenience symlinks that devtmpfs does not provide.
      ln -sf /proc/self/fd /dev/fd 2>/dev/null || true
      ln -sf fd/0 /dev/stdin 2>/dev/null || true
      ln -sf fd/1 /dev/stdout 2>/dev/null || true
      ln -sf fd/2 /dev/stderr 2>/dev/null || true
    else
      log "WARNING: could not mount devtmpfs on /dev (RBD mounts may fail)"
    fi
  fi

  # Loop devices are registered lazily by the kernel; ensure the nodes exist
  # so `losetup /dev/loop0` in setup_ceph_osd_loop never fails.
  for i in 0 1 2 3 4 5 6 7; do
    [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
  done
  [ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237 2>/dev/null || true

  log "Mount propagation configured."
}

# ── Detect node IP ────────────────────────────────────────────────────────
detect_ip() {
  NODE_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || echo "127.0.0.1")
  [ -z "$NODE_IP" ] && NODE_IP="127.0.0.1"
  log "Node IP: $NODE_IP"
}

# ── PKI helpers ───────────────────────────────────────────────────────────
gen_ca() {
  local name=$1 cn=$2 dir=${3:-$PKI}
  [ -f "$dir/$name.crt" ] && return 0
  openssl genrsa -out "$dir/$name.key" 2048 2>/dev/null
  openssl req -x509 -new -nodes -key "$dir/$name.key" -sha256 -days 3650 \
    -out "$dir/$name.crt" -subj "/CN=$cn" 2>/dev/null
}

gen_cert() {
  local name=$1 ca=$2 cn=$3 org=${4:-} san=${5:-} dir=${6:-$PKI}
  [ -f "$dir/$name.crt" ] && return 0
  local subj="/CN=$cn"
  [ -n "$org" ] && subj="/O=$org$subj"
  openssl genrsa -out "$dir/$name.key" 2048 2>/dev/null
  local ext="extendedKeyUsage=clientAuth,serverAuth"
  [ -n "$san" ] && ext="subjectAltName=$san\n$ext"
  openssl req -new -key "$dir/$name.key" -subj "$subj" 2>/dev/null | \
    openssl x509 -req -CA "$PKI/$ca.crt" -CAkey "$PKI/$ca.key" -CAcreateserial \
      -days 3650 -sha256 -extfile <(printf "$ext") -out "$dir/$name.crt" 2>/dev/null
}

gen_kubeconfig() {
  local file=$1 user=$2 cert=$3 key=$4 server=${5:-https://127.0.0.1:$API_PORT}
  [ -f "$file" ] && return 0
  local ca_b64=$(base64 -w0 < "$PKI/ca.crt")
  local cert_b64=$(base64 -w0 < "$cert")
  local key_b64=$(base64 -w0 < "$key")
  cat > "$file" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${ca_b64}
    server: ${server}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: ${user}
  name: ${user}@kubernetes
current-context: ${user}@kubernetes
users:
- name: ${user}
  user:
    client-certificate-data: ${cert_b64}
    client-key-data: ${key_b64}
EOF
}

# ── Generate all certificates ─────────────────────────────────────────────
generate_pki() {
  [ -f "$PKI/ca.crt" ] && { log "PKI already exists, skipping."; return 0; }
  log "Generating PKI certificates..."
  mkdir -p "$PKI/etcd"

  # CAs
  gen_ca ca kubernetes-ca
  gen_ca etcd/ca etcd-ca
  gen_ca front-proxy-ca front-proxy-ca

  # SA key pair
  if [ ! -f "$PKI/sa.key" ]; then
    openssl genrsa -out "$PKI/sa.key" 2048 2>/dev/null
    openssl rsa -in "$PKI/sa.key" -pubout -out "$PKI/sa.pub" 2>/dev/null
  fi

  local api_san="DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,DNS:$NODE_NAME,IP:127.0.0.1,IP:$NODE_IP,IP:10.96.0.1"

  # Certs signed by kubernetes-ca
  gen_cert apiserver                ca kube-apiserver  "" "$api_san"
  gen_cert apiserver-kubelet-client ca apiserver-kubelet-client system:masters
  gen_cert admin                    ca kubernetes-admin system:masters

  # Controller-manager, scheduler, kubelet, kube-proxy
  gen_cert controller-manager ca system:kube-controller-manager
  gen_cert scheduler          ca system:kube-scheduler
  gen_cert kubelet             ca "system:node:$NODE_NAME" system:nodes
  gen_cert kube-proxy          ca system:kube-proxy

  # Front-proxy
  gen_cert front-proxy-client front-proxy-ca front-proxy-client

  # etcd certs
  gen_cert etcd/server  etcd/ca etcd-server "" "DNS:localhost,DNS:$NODE_NAME,IP:127.0.0.1,IP:$NODE_IP"
  gen_cert etcd/client  etcd/ca etcd-client
  gen_cert apiserver-etcd-client etcd/ca apiserver-etcd-client

  log "PKI generation complete."
}

# ── Generate kubeconfigs ──────────────────────────────────────────────────
generate_kubeconfigs() {
  [ -f "$KUBE/admin.conf" ] && { log "Kubeconfigs exist, skipping."; return 0; }
  log "Generating kubeconfigs..."
  gen_kubeconfig "$KUBE/admin.conf"              kubernetes-admin             "$PKI/admin.crt"              "$PKI/admin.key"
  gen_kubeconfig "$KUBE/controller-manager.conf" system:kube-controller-manager "$PKI/controller-manager.crt" "$PKI/controller-manager.key"
  gen_kubeconfig "$KUBE/scheduler.conf"          system:kube-scheduler        "$PKI/scheduler.crt"          "$PKI/scheduler.key"
  gen_kubeconfig "$KUBE/kubelet.conf"            "system:node:$NODE_NAME"     "$PKI/kubelet.crt"            "$PKI/kubelet.key"
  gen_kubeconfig "$KUBE/kube-proxy.conf"         system:kube-proxy            "$PKI/kube-proxy.crt"         "$PKI/kube-proxy.key"

  # External kubeconfig (uses NODE_IP)
  gen_kubeconfig "$KUBE/admin-external.conf" kubernetes-admin "$PKI/admin.crt" "$PKI/admin.key" "https://$NODE_IP:$API_PORT"
  log "Kubeconfigs generated. External: $KUBE/admin-external.conf"
}

# ── Write kubelet config ──────────────────────────────────────────────────
write_kubelet_config() {
  [ -f /var/lib/kubelet/config.yaml ] && return 0
  mkdir -p /var/lib/kubelet
  cat > /var/lib/kubelet/config.yaml <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: $PKI/ca.crt
authorization:
  mode: Webhook
cgroupDriver: cgroupfs
clusterDNS:
  - $CLUSTER_DNS
clusterDomain: cluster.local
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
resolvConf: /etc/resolv.conf
rotateCertificates: false
serverTLSBootstrap: false
failSwapOn: false
enforceNodeAllocatable: []
EOF
}

# ── Wait helpers ──────────────────────────────────────────────────────────
wait_for_socket() {
  local sock=$1 tries=60
  while [ $tries -gt 0 ]; do
    [ -S "$sock" ] && return 0
    sleep 1; tries=$((tries - 1))
  done
  die "Timeout waiting for $sock"
}

wait_for_url() {
  local url=$1 tries=${2:-120}
  while [ $tries -gt 0 ]; do
    if curl -sk "$url" >/dev/null 2>&1; then return 0; fi
    sleep 1; tries=$((tries - 1))
  done
  die "Timeout waiting for $url"
}

wait_for_node_ready() {
  local tries=300
  log "Waiting for node to become Ready..."
  while [ $tries -gt 0 ]; do
    local status=$(kubectl --kubeconfig="$KUBE/admin.conf" get node "$NODE_NAME" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ "$status" = "True" ] && { log "Node is Ready!"; return 0; }
    sleep 2; tries=$((tries - 2))
  done
  die "Timeout waiting for node Ready"
}

# ── Start components ──────────────────────────────────────────────────────
start_containerd() {
  log "Starting containerd..."
  containerd --config /etc/containerd/config.toml &
  CONTAINERD_PID=$!
  PIDS+=("$CONTAINERD_PID")
  wait_for_socket /run/containerd/containerd.sock
  log "containerd ready."
}

cleanup_orphaned_containerd_records() {
  local -a tasks=() containers=()
  mapfile -t tasks < <(ctr -n k8s.io tasks list -q 2>/dev/null || true)
  mapfile -t containers < <(ctr -n k8s.io containers list -q 2>/dev/null || true)

  # After the outer container or host stops, nested tasks are gone but their
  # CRI metadata remains on the persistent containerd volume. Kubelet cannot
  # recreate those sandboxes until only these stale container records are
  # removed. Images, snapshots and Kubernetes/PVC data are deliberately kept.
  if [ "${#tasks[@]}" -eq 0 ] && [ "${#containers[@]}" -gt 0 ]; then
    log "Removing ${#containers[@]} orphaned containerd record(s)..."
    local container
    for container in "${containers[@]}"; do
      ctr -n k8s.io containers delete "$container" >/dev/null 2>&1 || true
    done
    log "Orphaned records removed; images and snapshots preserved."
  fi
}

start_etcd() {
  log "Starting etcd..."
  etcd \
    --name="$NODE_NAME" \
    --data-dir=/var/lib/etcd \
    --advertise-client-urls=https://127.0.0.1:2379 \
    --listen-client-urls=https://127.0.0.1:2379 \
    --listen-peer-urls=https://127.0.0.1:2380 \
    --initial-advertise-peer-urls=https://127.0.0.1:2380 \
    --initial-cluster="$NODE_NAME=https://127.0.0.1:2380" \
    --cert-file="$PKI/etcd/server.crt" \
    --key-file="$PKI/etcd/server.key" \
    --client-cert-auth=true \
    --trusted-ca-file="$PKI/etcd/ca.crt" \
    --peer-cert-file="$PKI/etcd/server.crt" \
    --peer-key-file="$PKI/etcd/server.key" \
    --peer-client-cert-auth=true \
    --peer-trusted-ca-file="$PKI/etcd/ca.crt" &
  ETCD_PID=$!
  PIDS+=("$ETCD_PID")
  # Wait for etcd with proper client certs
  local tries=60
  while [ $tries -gt 0 ]; do
    if etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert="$PKI/etcd/ca.crt" \
      --cert="$PKI/etcd/client.crt" \
      --key="$PKI/etcd/client.key" \
      endpoint health >/dev/null 2>&1; then
      break
    fi
    sleep 1; tries=$((tries - 1))
  done
  [ "$tries" -gt 0 ] || die "Timeout waiting for etcd"
  log "etcd ready."
}

start_apiserver() {
  log "Starting kube-apiserver..."
  kube-apiserver \
    --advertise-address="$NODE_IP" \
    --allow-privileged=true \
    --authorization-mode=Node,RBAC \
    --client-ca-file="$PKI/ca.crt" \
    --enable-admission-plugins=NodeRestriction \
    --etcd-cafile="$PKI/etcd/ca.crt" \
    --etcd-certfile="$PKI/apiserver-etcd-client.crt" \
    --etcd-keyfile="$PKI/apiserver-etcd-client.key" \
    --etcd-servers=https://127.0.0.1:2379 \
    --kubelet-client-certificate="$PKI/apiserver-kubelet-client.crt" \
    --kubelet-client-key="$PKI/apiserver-kubelet-client.key" \
    --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname \
    --proxy-client-cert-file="$PKI/front-proxy-client.crt" \
    --proxy-client-key-file="$PKI/front-proxy-client.key" \
    --requestheader-allowed-names=front-proxy-client \
    --requestheader-client-ca-file="$PKI/front-proxy-ca.crt" \
    --requestheader-extra-headers-prefix=X-Remote-Extra- \
    --requestheader-group-headers=X-Remote-Group \
    --requestheader-username-headers=X-Remote-User \
    --secure-port=$API_PORT \
    --service-account-issuer=https://kubernetes.default.svc.cluster.local \
    --service-account-key-file="$PKI/sa.pub" \
    --service-account-signing-key-file="$PKI/sa.key" \
    --service-cluster-ip-range="$SERVICE_CIDR" \
    --tls-cert-file="$PKI/apiserver.crt" \
    --tls-private-key-file="$PKI/apiserver.key" &
  APISERVER_PID=$!
  PIDS+=("$APISERVER_PID")
  wait_for_url "https://127.0.0.1:$API_PORT/healthz" 120
  log "kube-apiserver ready."
}

start_controller_manager() {
  log "Starting kube-controller-manager..."
  kube-controller-manager \
    --allocate-node-cidrs=true \
    --authentication-kubeconfig="$KUBE/controller-manager.conf" \
    --authorization-kubeconfig="$KUBE/controller-manager.conf" \
    --bind-address=127.0.0.1 \
    --client-ca-file="$PKI/ca.crt" \
    --cluster-cidr="$CLUSTER_CIDR" \
    --cluster-signing-cert-file="$PKI/ca.crt" \
    --cluster-signing-key-file="$PKI/ca.key" \
    --controllers='*,bootstrapsigner,tokencleaner' \
    --kubeconfig="$KUBE/controller-manager.conf" \
    --leader-elect=false \
    --requestheader-client-ca-file="$PKI/front-proxy-ca.crt" \
    --root-ca-file="$PKI/ca.crt" \
    --service-account-private-key-file="$PKI/sa.key" \
    --service-cluster-ip-range="$SERVICE_CIDR" \
    --use-service-account-credentials=true &
  CONTROLLER_MANAGER_PID=$!
  PIDS+=("$CONTROLLER_MANAGER_PID")
  log "kube-controller-manager started."
}

start_scheduler() {
  log "Starting kube-scheduler..."
  kube-scheduler \
    --authentication-kubeconfig="$KUBE/scheduler.conf" \
    --authorization-kubeconfig="$KUBE/scheduler.conf" \
    --bind-address=127.0.0.1 \
    --kubeconfig="$KUBE/scheduler.conf" \
    --leader-elect=false &
  SCHEDULER_PID=$!
  PIDS+=("$SCHEDULER_PID")
  log "kube-scheduler started."
}

start_kubelet() {
  log "Starting kubelet..."
  write_kubelet_config
  kubelet \
    --config=/var/lib/kubelet/config.yaml \
    --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
    --kubeconfig="$KUBE/kubelet.conf" \
    --hostname-override="$NODE_NAME" \
    --node-ip="$NODE_IP" \
    --register-node=true \
    --v=2 &
  KUBELET_PID=$!
  PIDS+=("$KUBELET_PID")
  log "kubelet started."
}

start_kube_proxy() {
  log "Starting kube-proxy..."
  kube-proxy \
    --kubeconfig="$KUBE/kube-proxy.conf" \
    --cluster-cidr="$CLUSTER_CIDR" \
    --conntrack-max-per-core=0 \
    --proxy-mode=iptables &
  KUBE_PROXY_PID=$!
  PIDS+=("$KUBE_PROXY_PID")
  log "kube-proxy started."
}

# ── Setup loop device for Ceph OSD ────────────────────────────────────────
# Creates a 30G sparse file in /var/lib/rook and attaches it as a loop device
# so the Rook OSD has a raw block device without touching host disks.
setup_ceph_osd_loop() {
  local img="/var/lib/rook/osd.img"
  local size="${ROOK_OSD_SIZE:-30G}"

  if ! command -v losetup >/dev/null 2>&1; then
    log "WARNING: losetup not found, skipping OSD loop device"
    return 0
  fi

  mkdir -p /var/lib/rook

  # Create sparse image if missing
  if [ ! -f "$img" ]; then
    log "Creating OSD sparse image ($size)..."
    truncate -s "$size" "$img"
  fi

  # The rook manifest declares the OSD device EXCLUSIVELY as /dev/loop0
  # (devicePathFilter + devices[].name=loop0). If osd.img ends up attached to
  # any OTHER loop device, the OSD silently never finds its disk and stays in
  # Init:CrashLoopBackOff ("no disk found with OSD ID 0"). Enforce loop0.
  # NOTE: compare by INODE (losetup -j), never by backing-file string — the
  # kernel may report the path differently than $img (e.g. "/osd.img").

  # 1. Which loop device is backing osd.img right now?
  local cur=""
  cur=$(losetup -j "$img" 2>/dev/null | cut -d: -f1 | head -1) || true

  # 2. If osd.img is on a different loop device, detach it first.
  if [ -n "$cur" ] && [ "$cur" != "/dev/loop0" ]; then
    log "osd.img attached to $cur — moving to /dev/loop0..."
    losetup -d "$cur" 2>/dev/null || true
    cur=""
  fi

  # 3. If /dev/loop0 is busy with a DIFFERENT file, detach it.
  if losetup -a 2>/dev/null | grep -q '^/dev/loop0:'; then
    if [ "$cur" != "/dev/loop0" ]; then
      log "Detaching /dev/loop0 (occupied by another file)..."
      losetup -d /dev/loop0 2>/dev/null || true
    fi
  fi

  # 4. Attach if /dev/loop0 is not backing osd.img (inode check).
  if ! losetup -j "$img" 2>/dev/null | grep -q '^/dev/loop0:'; then
    log "Attaching /dev/loop0 to $img..."
    if ! losetup /dev/loop0 "$img" 2>&1; then
      die "FATAL: cannot attach /dev/loop0 to $img (device busy with another file?)"
    fi
  fi

  # 5. Verify the attach REALLY happened and points at loop0.
  if losetup -j "$img" 2>/dev/null | grep -q '^/dev/loop0:'; then
    log "OSD loop device ready (/dev/loop0 -> $img)"
  else
    die "FATAL: OSD loop device NOT attached to /dev/loop0"
  fi
}

# ── Wait for Ceph OSD ────────────────────────────────────────────────────
# After the CephCluster manifest is applied, the Rook operator creates the
# OSD pod. Wait for it to be Ready; if it crash-loops (init "activate" can't
# find the disk), re-attach the loop backing and force-restart the pod.
wait_for_ceph_osd() {
  local kc="kubectl"
  local tries=150   # ~5 min
  log "Waiting for Ceph OSD to become Ready..."
  while [ $tries -gt 0 ]; do
    local osd_pod osd_ready osd_restarts
    osd_pod=$($kc -n rook-ceph get pods -l app=rook-ceph-osd \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$osd_pod" ]; then
      osd_ready=$($kc -n rook-ceph get pod "$osd_pod" \
        -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "")
      if [ "$osd_ready" = "true" ]; then
        log "Ceph OSD is Ready ($osd_pod)."
        return 0
      fi
      osd_restarts=$($kc -n rook-ceph get pod "$osd_pod" \
        -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)
      if [ "${osd_restarts:-0}" -ge 4 ]; then
        log "OSD $osd_pod crash-looping ($osd_restarts restarts) — re-attaching loop0 and restarting pod..."
        setup_ceph_osd_loop
        $kc -n rook-ceph delete pod "$osd_pod" --force --grace-period=0 2>/dev/null || true
      fi
    fi
    sleep 2; tries=$((tries - 1))
  done
  log "WARNING: Ceph OSD did not become Ready in time (boot continues)."
  return 1
}

# ── Start udevd (required by ceph-volume for device identification) ───────
start_udevd() {
  if command -v /usr/lib/systemd/systemd-udevd >/dev/null 2>&1; then
    local udevd=/usr/lib/systemd/systemd-udevd
  elif command -v /sbin/udevd >/dev/null 2>&1; then
    local udevd=/sbin/udevd
  elif command -v udevd >/dev/null 2>&1; then
    local udevd=udevd
  else
    log "WARNING: udevd not found, Ceph OSD may fail to detect devices"
    return 0
  fi

  # Start udevd if not already running (comm is "systemd-udevd")
  if ! grep -q systemd-udevd /proc/*/comm 2>/dev/null; then
    log "Starting udevd..."
    rm -rf /run/udev; mkdir -p /run/udev
    # Fake systemctl so udevd doesn't try to talk to systemd
    if [ ! -f /bin/systemctl ]; then
      cat > /bin/systemctl << 'SYSTEMCTL'
#!/bin/sh
exit 0
SYSTEMCTL
      chmod +x /bin/systemctl
    fi
    "$udevd" --resolve-names=never --daemon 2>/dev/null || "$udevd" --daemon 2>/dev/null
    sleep 2
    if grep -q systemd-udevd /proc/*/comm 2>/dev/null; then
      log "udevd started OK"
    else
      log "WARNING: udevd failed to start"
    fi
  fi

  # Trigger uevents so /run/udev/data gets populated for the loop device
  if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger --action=add --subsystem-match=block 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true
  fi
}

# ── Cilium CNI health check ──────────────────────────────────────────────
# Returns 0 only when the CNI is actually serving NEW pods. Three layers:
#   1. DaemonSet exists with desired == ready
#   2. Agent answers on its local socket (cilium status)
#   3. End-to-end: a fresh probe pod gets a PodIP and completes. This is the
#      layer that catches a dead BPF datapath after a container restart,
#      where old pods may still report Running but no new pod can get a
#      network sandbox.
cilium_healthy() {
  local kc="kubectl"

  $kc -n kube-system get ds cilium >/dev/null 2>&1 || return 1
  local desired ready
  desired=$($kc -n kube-system get ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
  ready=$($kc -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
  [ "${desired:-0}" -gt 0 ] && [ "$desired" = "$ready" ] || return 1

  cilium status --kubeconfig "$KUBE/admin.conf" --brief >/dev/null 2>&1 || return 1

  # Probe pod: must be created, get a PodIP and reach Succeeded.
  $kc -n kube-system delete pod cilium-health-probe --force --grace-period=0 >/dev/null 2>&1 || true
  if ! $kc -n kube-system run cilium-health-probe --image=busybox:1.36 --restart=Never \
      --command -- /bin/sh -c "sleep 5" >/dev/null 2>&1; then
    return 1
  fi
  local tries=45
  while [ $tries -gt 0 ]; do
    local phase ip
    phase=$($kc -n kube-system get pod cilium-health-probe -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    ip=$($kc -n kube-system get pod cilium-health-probe -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
    if [ "$phase" = "Succeeded" ] && [ -n "$ip" ] && [ "$ip" != "<none>" ]; then
      $kc -n kube-system delete pod cilium-health-probe --force --grace-period=0 >/dev/null 2>&1 || true
      return 0
    fi
    sleep 2; tries=$((tries - 1))
  done
  $kc -n kube-system delete pod cilium-health-probe --force --grace-period=0 >/dev/null 2>&1 || true
  return 1
}

# ── Stale APIService cleanup ──────────────────────────────────────────────
# A broken aggregated APIService makes the namespace controller fail
# discovery, which wedges ANY namespace stuck in Terminating (cilium-secrets
# -> cilium reinstall hangs). An APIService is stale when its backing Service
# has no Ready endpoints OR it reports itself unavailable (FailedDiscoveryCheck)
# — the latter catches pods that are dead but still registered (stale IP after
# a container/host restart). Safe: the owning Deployment re-registers, or the
# manifest is re-applied later in the boot.
# NOTE: only called EARLY (before the cilium reinstall), NOT in the final
# cleanup pass — otherwise it deletes a freshly-applied APIService that is
# still warming up (metrics-server applied at the end of apply_manifests).
cleanup_stale_apiservices() {
  local kc="kubectl"

  for api in $($kc get apiservice -o name 2>/dev/null | awk -F/ '{print $2}'); do
    local svc ns avail endpoints
    svc=$($kc get apiservice "$api" -o jsonpath='{.spec.service.name}' 2>/dev/null || echo "")
    ns=$($kc get apiservice "$api" -o jsonpath='{.spec.service.namespace}' 2>/dev/null || echo "")
    [ -z "$svc" ] || [ -z "$ns" ] && continue
    avail=$($kc get apiservice "$api" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
    endpoints=$($kc get endpoints -n "$ns" "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
    if [ "$avail" != "True" ] || [ -z "$endpoints" ]; then
      log "Deleting stale APIService $api (available=$avail endpoints='$endpoints')"
      $kc delete apiservice "$api" 2>/dev/null || true
    fi
  done
}

# ── Stale state cleanup ───────────────────────────────────────────────────
# Removes leftovers that poison a boot: pods the kubelet lost track of
# (Unknown) and namespaces stuck in Terminating from interrupted installs.
# Deliberately does NOT touch VolumeAttachments of bound PVCs — those are
# live data and must be handled individually, never swept blindly.
cleanup_stale_state() {
  local kc="kubectl"

  # Pods in Unknown phase — force-recreate so they pick up fresh tokens
  $kc delete pods -A --field-selector=status.phase=Unknown --force --grace-period=0 2>/dev/null || true

  # cilium-secrets stuck in Terminating (interrupted reinstall) — drop finalizers
  if $kc get ns cilium-secrets >/dev/null 2>&1; then
    local phase
    phase=$($kc get ns cilium-secrets -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$phase" = "Terminating" ]; then
      log "Removing cilium-secrets stuck in Terminating..."
      $kc patch ns cilium-secrets --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
      # --wait=false: kubectl would otherwise block until the namespace is gone,
      # and a wedged namespace hangs the boot indefinitely.
      $kc delete ns cilium-secrets --force --grace-period=0 --wait=false 2>/dev/null || true
    fi
  fi

  # Orphan VolumeAttachments (PV no longer exists) — safe to drop; the CSI
  # controller recreates any that are still needed.
  for va in $($kc get volumeattachment -o name 2>/dev/null | awk -F/ '{print $2}'); do
    local pv
    pv=$($kc get volumeattachment "$va" -o jsonpath='{.spec.source.persistentVolumeName}' 2>/dev/null || echo "")
    if [ -n "$pv" ] && ! $kc get pv "$pv" >/dev/null 2>&1; then
      log "Deleting orphan VolumeAttachment $va (PV $pv gone)"
      $kc delete volumeattachment "$va" 2>/dev/null || true
    fi
  done
}

# ── Start the rbd-nbd orphan reaper ───────────────────────────────────────
# The ceph-block StorageClass uses mounter=rbd-nbd (krbd can't reach the mon
# from inside the container). Stale rbd-nbd mappings can survive pod/plugin
# restarts and leave PVCs stuck in ContainerCreating ("is still being used" /
# "cookie mismatch"). The reaper unmaps mappings whose volumeHandle has no
# VolumeAttachment in Attached=true state for this node. Dry-run by default;
# set RBD_REAPER_DRY_RUN=0 to actually unmap.
start_rbd_reaper() {
  [ -x /usr/local/bin/rbd-nbd-reaper.sh ] || { log "WARNING: rbd-nbd-reaper.sh not found"; return 0; }
  # comm is truncated to 15 chars: "rbd-nbd-reaper"
  if grep -q rbd-nbd-reaper /proc/*/comm 2>/dev/null; then
    log "rbd-nbd reaper already running."
    return 0
  fi
  log "Starting rbd-nbd reaper (dry_run=${RBD_REAPER_DRY_RUN:-1})..."
  KUBECONFIG="$KUBE/admin.conf" NODE_NAME="$NODE_NAME" \
    /usr/local/bin/rbd-nbd-reaper.sh >/tmp/rbd-reaper.out 2>&1 &
  sleep 1
  grep -q rbd-nbd-reaper /proc/*/comm 2>/dev/null && log "rbd-nbd reaper started." \
    || log "WARNING: rbd-nbd reaper failed to start"
}

# ── Post-init: apply manifests ────────────────────────────────────────────
apply_manifests() {
  export KUBECONFIG="$KUBE/admin.conf"
  local kc="kubectl"

  # Wait for node registration
  log "Waiting for node to register..."
  local tries=60
  while [ $tries -gt 0 ]; do
    $kc get node "$NODE_NAME" >/dev/null 2>&1 && break
    sleep 2; tries=$((tries - 2))
  done

  # Remove control-plane taint so workloads can be scheduled
  $kc taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
  # Ordered shutdown cordons the node before draining PVC consumers. Restore
  # scheduling only after kubelet has registered again on this boot.
  $kc uncordon "$NODE_NAME" >/dev/null 2>&1 || true

  # Clean up stale state from previous boots BEFORE deciding about Cilium.
  # Order matters: stale aggregated APIServices (e.g. metrics.k8s.io) break
  # namespace finalization, so remove them FIRST or the cilium-secrets removal
  # below can wedge (DiscoveryFailed -> Terminating namespace stuck forever).
  cleanup_stale_apiservices
  cleanup_stale_state

  # Cilium CNI. Reinstall ONLY when unhealthy — a blind reinstall on every
  # boot recreates Cilium ServiceAccounts and invalidates the tokens mounted
  # in running agent pods (Unauthorized -> CrashLoopBackOff -> every pod in
  # the cluster flips to Unknown because the CNI cannot create sandboxes).
  if cilium_healthy; then
    log "Cilium CNI healthy, skipping reinstall."
  else
    log "Cilium CNI unhealthy, reinstalling..."
    cilium uninstall --kubeconfig "$KUBE/admin.conf" 2>/dev/null || true
    rm -rf /sys/fs/bpf/cilium/devices/* 2>/dev/null || true

    # Uninstall is async: the cilium-secrets namespace can linger in
    # Terminating and make the install fail with "unable to create content in
    # namespace ... because it is being terminated". Wait for it to be fully
    # gone, force-dropping finalizers if the namespace controller is stuck.
    local ns_tries=30
    while [ $ns_tries -gt 0 ]; do
      if ! $kc get ns cilium-secrets >/dev/null 2>&1; then
        log "cilium-secrets namespace fully removed."
        break
      fi
      local ns_phase
      ns_phase=$($kc get ns cilium-secrets -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      if [ "$ns_phase" = "Terminating" ]; then
        log "Forcing removal of cilium-secrets (Terminating)..."
        $kc patch ns cilium-secrets --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        # --wait=false: never block on a possibly-wedged namespace.
        $kc delete ns cilium-secrets --force --grace-period=0 --wait=false 2>/dev/null || true
      fi
      sleep 2; ns_tries=$((ns_tries - 1))
    done

    # Force-delete Cilium pods left Terminating by a previous (un)install.
    # "Terminating" is not a pod phase, so a status.phase field selector never
    # matches it; deletionTimestamp is the authoritative signal. Stale Cilium
    # pods hold hostPorts (e.g. 4244), leaving the replacement pods Pending.
    local terminating_pod
    while IFS= read -r terminating_pod; do
      [ -n "$terminating_pod" ] || continue
      case "$terminating_pod" in
        cilium-*)
          log "Force-deleting stale pod kube-system/$terminating_pod"
          $kc -n kube-system delete pod "$terminating_pod" \
            --force --grace-period=0 --wait=false 2>/dev/null || true
          ;;
      esac
    done < <($kc -n kube-system get pods \
      -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null || true)

    if ! cilium install \
      --kubeconfig "$KUBE/admin.conf" \
      --version v1.19.5 \
      --set cluster.name="$NODE_NAME" \
      --set cluster.id=1 \
      --set kubeProxyReplacement=false \
      --wait 2>&1; then
      if ! $kc -n kube-system get ds cilium >/dev/null 2>&1; then
        log "FATAL: Cilium is not available and install failed"
        return 1
      fi
    fi

    # `cilium install --wait` can time out while the kubelet is recovering
    # stale runtime state even though the resources were created successfully.
    # Do not continue with CoreDNS and the remaining workloads until the agent,
    # operator and an end-to-end probe all confirm that the CNI is functional.
    log "Waiting for Cilium CNI to become functional..."
    if ! cilium status --kubeconfig "$KUBE/admin.conf" \
        --wait --wait-duration 5m --brief >/dev/null 2>&1 || ! cilium_healthy; then
      log "FATAL: Cilium resources exist, but the CNI did not become functional"
      return 1
    fi
  fi
  log "Cilium ready."

  # Wait for node Ready (Cilium will install CNI and make the node Ready)
  wait_for_node_ready

  # Apply CoreDNS
  log "Applying CoreDNS..."
  $kc apply -f "$MANIFESTS/built-in/coredns" 2>&1 | tail -6
  log "CoreDNS applied."

  # Deploy Rook-Ceph operator
  log "Deploying Rook-Ceph operator..."
  $kc apply -f "$MANIFESTS/rook-crds.yaml" 2>&1 | tail -2
  $kc apply -f "$MANIFESTS/rook-common.yaml" 2>&1 | tail -2
  $kc apply -f "$MANIFESTS/rook-csi-operator.yaml" 2>&1 | tail -2

  # Wait for rook-ceph namespace to exist
  local rook_tries=60
  while [ $rook_tries -gt 0 ]; do
    $kc get ns rook-ceph >/dev/null 2>&1 && break
    sleep 2; rook_tries=$((rook_tries - 2))
  done

  $kc apply -f "$MANIFESTS/rook-operator.yaml" 2>&1 | tail -2

  # Allow loop devices for OSD storage (required for the 30G loop device).
  # NOTE: must run AFTER applying rook-operator.yaml, since that manifest ships
  # its own rook-ceph-operator-config with ROOK_CEPH_ALLOW_LOOP_DEVICES=false.
  $kc -n rook-ceph create configmap rook-ceph-operator-config \
    --from-literal=ROOK_CEPH_ALLOW_LOOP_DEVICES=true 2>/dev/null || \
    $kc -n rook-ceph patch configmap rook-ceph-operator-config --type merge \
      -p '{"data":{"ROOK_CEPH_ALLOW_LOOP_DEVICES":"true"}}' 2>/dev/null

  # Verify the operator config actually has loop devices enabled. A silent
  # failure here means the OSD can never be created (default is false), which
  # is exactly the class of bug that left the cluster with 0 OSDs before.
  if [ "$($kc -n rook-ceph get configmap rook-ceph-operator-config \
        -o jsonpath='{.data.ROOK_CEPH_ALLOW_LOOP_DEVICES}' 2>/dev/null)" != "true" ]; then
    die "FATAL: ROOK_CEPH_ALLOW_LOOP_DEVICES is not 'true' in rook-ceph-operator-config"
  fi
  log "ROOK_CEPH_ALLOW_LOOP_DEVICES=true confirmed"

  log "Waiting for Rook operator..."
  $kc -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=300s 2>&1 | tail -2
  log "Rook operator deployed."

  # Create Ceph cluster, storage resources and dashboard.
  log "Creating Ceph cluster (single-node, loop OSD) and dashboard..."
  $kc apply -k "$MANIFESTS/built-in/ceph" 2>&1 | tail -9
  log "Ceph manifests applied (operator will reconcile the cluster)."

  # Idempotent OSD recovery: wait for the OSD to be Ready; if it crash-loops
  # (loop backing lost after a container restart), re-attach /dev/loop0 and
  # force-restart the pod automatically.
  wait_for_ceph_osd

  # Apply HAProxy Ingress Controller
  log "Applying HAProxy Ingress Controller..."
  $kc apply -f "$MANIFESTS/built-in/haproxy-ingress" 2>&1 | tail -7
  log "HAProxy Ingress Controller applied."

  # Apply MetalLB (Layer 2 — LoadBalancer IPs for ingress/DNS). CRDs first to
  # avoid a race with the IPAddressPool/L2Advertisement custom resources.
  log "Applying MetalLB CRDs..."
  $kc apply -f "$MANIFESTS/built-in/metallb/00-crds.yaml" 2>&1 | tail -3
  $kc -n metallb-system wait --for=condition=Established \
    crd/ipaddresspools.metallb.io --timeout=90s 2>&1 | tail -1 || \
    log "WARN: MetalLB IPAddressPool CRD not established yet (continuing)"
  log "Applying MetalLB (controller, speaker, pool, advert)..."
  $kc apply -k "$MANIFESTS/built-in/metallb" 2>&1 | tail -9
  log "MetalLB applied."

  # Apply metrics-server (metrics.k8s.io API — kubectl top / HPA)
  log "Applying metrics-server..."
  $kc apply -f "$MANIFESTS/built-in/metrics-server" 2>&1 | tail -9
  log "metrics-server applied."

  # Apply cert-manager (issues internal TLS certs for *.lan from the mkcert
  # CA). CRDs first, then wait for the controller before ClusterIssuer/Cert.
  # NOTE: *.lan is used instead of *.local because Android/macOS resolve
  # .local via mDNS, never via unicast DNS (AdGuard) — see README.
  log "Applying cert-manager..."
  $kc apply -f "$MANIFESTS/built-in/cert-manager/00-crds.yaml" 2>&1 | tail -3
  $kc apply -f "$MANIFESTS/built-in/cert-manager/01-namespace.yaml" 2>&1 | tail -1
  $kc apply -k "$MANIFESTS/built-in/cert-manager" 2>&1 | tail -9
  $kc -n cert-manager rollout status deploy/cert-manager --timeout=180s 2>&1 | tail -1
  log "cert-manager applied."

  # Apply Argo CD (server-side apply is required for its large CRDs). The
  # version is supplied at runtime so upgrades do not require editing files.
  log "Applying Argo CD $ARGOCD_VERSION..."
  $kc apply --server-side --force-conflicts \
    -f "$MANIFESTS/built-in/argocd/namespace.yaml" 2>&1 | tail -2
  $kc apply --server-side --force-conflicts -n argocd \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
    2>&1 | tail -5
  # Serve the UI via the ingress without an HTTP->HTTPS redirect loop: the
  # ingress terminates TLS (mkcert) and forwards plain HTTP to the backend, so
  # Argo must run with --insecure. Idempotent (args stay patched across reboots).
  $kc -n argocd patch deployment argocd-server --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["/usr/local/bin/argocd-server","--insecure"]}]' \
    2>&1 | tail -1 || log "WARN: could not patch argocd-server --insecure"
  log "Argo CD $ARGOCD_VERSION applied."

  # Final stale-state pass: pods only get marked Unknown once the kubelet
  # finishes reconciling (async), so the early cleanup can miss them — a
  # leftover Unknown pod blocks its Deployment/StatefulSet from scaling a
  # replacement and the app stays down. Retry a few times with a gap to catch
  # stragglers. Idempotent: only touches Unknown pods, Terminating
  # cilium-secrets and VolumeAttachments whose PV no longer exists.
  for _ in 1 2 3; do
    cleanup_stale_state
    sleep 10
  done
  log "Stale-state cleanup finished."

  # Start the rbd-nbd orphan reaper (dry-run unless RBD_REAPER_DRY_RUN=0)
  start_rbd_reaper

  log "============================================="
  log "  K8s-One cluster is READY!"
  log "  API Server: https://$NODE_IP:$API_PORT"
  log "  Kubeconfig: docker cp k8s-one:/etc/kubernetes/admin-external.conf ./kubeconfig"
  log "============================================="
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
  log "Starting K8s-One single-node cluster..."
  setup_mounts
  detect_ip
  generate_pki
  generate_kubeconfigs

  # Storage prerequisites must exist before kubelet can revive persisted Rook
  # and CSI pods from containerd state.
  setup_ceph_osd_loop
  start_udevd

  start_containerd
  cleanup_orphaned_containerd_records
  start_etcd
  start_apiserver
  start_controller_manager
  start_scheduler
  start_kubelet
  start_kube_proxy

  # Apply manifests in background so we can `wait` on main processes
  apply_manifests &
  APPLY_PID=$!

  log "All components running. Waiting..."
  wait "${PIDS[@]}"
}

main "$@"
