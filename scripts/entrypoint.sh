#!/bin/bash
set -euo pipefail

# ===========================================================================
# K8s-One: Single-Node Kubernetes Cluster — Entrypoint
# Starts all control-plane + node components from scratch.
# ===========================================================================

NODE_NAME="${NODE_NAME:-k8s-one}"
CLUSTER_CIDR="192.168.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
CLUSTER_DNS="10.96.0.10"
API_PORT=6443

PKI="/etc/kubernetes/pki"
KUBE="/etc/kubernetes"
MANIFESTS="/opt/manifests"

declare -a PIDS=()

log()  { echo "[k8s-one] $(date -u '+%H:%M:%S') $*"; }
die()  { log "FATAL: $*"; exit 1; }

# ── Cleanup ────────────────────────────────────────────────────────────────
cleanup() {
  log "Shutting down all components..."
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  log "Bye."
  exit 0
}
trap cleanup SIGTERM SIGINT

# ── Setup mount propagation (required for Calico BPF + kubelet) ───────────
setup_mounts() {
  mount --make-rshared / 2>/dev/null || true
  mount --make-rshared /sys 2>/dev/null || true
  # Ensure BPF filesystem is mounted
  if ! mountpoint -q /sys/fs/bpf 2>/dev/null; then
    mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
  fi
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
  PIDS+=($!)
  wait_for_socket /run/containerd/containerd.sock
  log "containerd ready."
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
  PIDS+=($!)
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
  PIDS+=($!)
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
  PIDS+=($!)
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
  PIDS+=($!)
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
  PIDS+=($!)
  log "kubelet started."
}

start_kube_proxy() {
  log "Starting kube-proxy..."
  kube-proxy \
    --kubeconfig="$KUBE/kube-proxy.conf" \
    --cluster-cidr="$CLUSTER_CIDR" \
    --conntrack-max-per-core=0 \
    --proxy-mode=iptables &
  PIDS+=($!)
  log "kube-proxy started."
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

  # Apply Calico
  log "Applying Calico manifest..."
  $kc apply -f "$MANIFESTS/calico.yaml" --server-side 2>&1 | tail -5
  log "Calico applied."

  # Wait for node Ready (Calico will install CNI and make the node Ready)
  wait_for_node_ready

  # Apply CoreDNS
  log "Applying CoreDNS..."
  $kc apply -f "$MANIFESTS/coredns.yaml" 2>&1 | tail -3
  log "CoreDNS applied."

  # Apply local-path-provisioner
  log "Applying local-path-provisioner..."
  $kc apply -f "$MANIFESTS/local-path-storage.yaml" 2>&1 | tail -3

  # Set local-path as default StorageClass
  $kc patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true
  log "local-path-provisioner applied (default StorageClass)."

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

  start_containerd
  start_etcd
  start_apiserver
  start_controller_manager
  start_scheduler
  start_kubelet
  start_kube_proxy

  # Apply manifests in background so we can `wait` on main processes
  apply_manifests &

  log "All components running. Waiting..."
  wait "${PIDS[@]}"
}

main "$@"
