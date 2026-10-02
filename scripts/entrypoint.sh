#!/bin/bash
set -euo pipefail

# ===========================================================================
# K8s-One: Single-Node Kubernetes Cluster — Entrypoint
# Starts all control-plane + node components from scratch.
# ===========================================================================

NODE_NAME="${NODE_NAME:-k8s-one}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.1}"
# Pod CIDR — precisa CONTER o podCIDR já alocado ao(s) nó(s): o
# kube-controller-manager recusa iniciar se o podCIDR do nó ficar fora deste
# range (node-ipam-controller -> "Error building controllers" -> processo morre,
# e sem controller-manager nenhum DaemonSet — nem o Cilium — é agendado).
# O nó k8s-one tem podCIDR 192.168.0.0/24, logo 192.168.0.0/16. Deve ser
# disjunto do SERVICE_CIDR abaixo (10.96.0.0/12) — por isso NÃO usar 10.0.0.0/8,
# que contém o 10.96.0.0/12. O IPAM do Cilium recebe este mesmo valor (cilium
# install --set ipam.operator.clusterPoolIPv4PodCIDRList), mantendo tudo alinhado.
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

# Finalizers de namespace vivem em spec.finalizers (NÃO metadata.finalizers) e
# só são alteráveis pelo subrecurso /finalize — um `patch --type merge` em
# metadata é silenciosamente ignorado ("no change"), deixando o namespace preso
# em Terminating para sempre. Foi o que travou o reinstall do Cilium
# (cilium-secrets) e abortou o boot com FATAL. Sem jq/python na imagem, o corpo
# mínimo do /finalize é montado com printf.
force_remove_namespace() {
  local ns=$1
  [ -n "$ns" ] || return 0
  printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"%s"},"spec":{"finalizers":[]}}' "$ns" \
    | kubectl --kubeconfig "$KUBE/admin.conf" replace --raw \
        "/api/v1/namespaces/$ns/finalize" -f - >/dev/null 2>&1 || true
  kubectl --kubeconfig "$KUBE/admin.conf" delete ns "$ns" \
    --force --grace-period=0 --wait=false >/dev/null 2>&1 || true
}

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

  # Graceful pod termination (postgres/vaultwarden preStop hooks) is handled
  # by the kubelet via SIGTERM; local-path volumes are hostPath, so there is no
  # remote storage to detach before the runtime stops.
  stop_pid "kubelet" "$KUBELET_PID" 20
  stop_pid "kube-proxy" "$KUBE_PROXY_PID" 10
  stop_containerd_tasks

  # The control plane and runtime can now stop in reverse dependency order.
  stop_pid "kube-apiserver" "$APISERVER_PID" 20
  stop_pid "etcd" "$ETCD_PID" 20
  stop_pid "containerd" "$CONTAINERD_PID" 20

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
  # device nodes for kernel block devices. Mounting devtmpfs makes the kernel
  # create them instantly.
  if ! grep -q ' /dev devtmpfs ' /proc/self/mounts 2>/dev/null; then
    if mount -t devtmpfs devtmpfs /dev 2>/dev/null; then
      log "devtmpfs mounted on /dev."
      # Restore convenience symlinks that devtmpfs does not provide.
      ln -sf /proc/self/fd /dev/fd 2>/dev/null || true
      ln -sf fd/0 /dev/stdin 2>/dev/null || true
      ln -sf fd/1 /dev/stdout 2>/dev/null || true
      ln -sf fd/2 /dev/stderr 2>/dev/null || true
    else
      log "WARNING: could not mount devtmpfs on /dev"
    fi
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
  # keyUsage adicionado: clientes TLS estritos (OpenSSL 3.x / Python 3.13+)
  # rejeitam CA sem a extensão. Ex.: sidecars do Grafana (kiwigrid/k8s-sidecar).
  openssl req -x509 -new -nodes -key "$dir/$name.key" -sha256 -days 3650 \
    -out "$dir/$name.crt" -subj "/CN=$cn" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}

gen_cert() {
  local name=$1 ca=$2 cn=$3 org=${4:-} san=${5:-} dir=${6:-$PKI}
  [ -f "$dir/$name.crt" ] && return 0
  local subj="/CN=$cn"
  [ -n "$org" ] && subj="/O=$org$subj"
  openssl genrsa -out "$dir/$name.key" 2048 2>/dev/null
  # keyUsage adicionado (digitalSignature,keyEncipherment) além do EKU existente.
  local ext="keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth,serverAuth"
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
# /var/lib/kubelet e bind mount (./data/kubelet) e persiste entre restarts, entao
# a config precisa ser REGENERAVEL: comparamos o conteudo desejado com o do disco
# e so reescrevemos (com backup) quando muda. Sem isso, editar o heredoc abaixo
# nao tinha efeito nenhum num cluster ja inicializado — a config ficava congelada
# no bind mount e as mudancas no repo eram silenciosamente ignoradas.
write_kubelet_config() {
  local cfg=/var/lib/kubelet/config.yaml
  local desired
  desired=$(cat <<EOF
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
# Limites "nativos" do k8s-one (protege o host 23Gi/4cpu):
#  - capacidade reportada = memoria do HOST -> reservas grandes "mentem" pro
#    scheduler (allocatable = 23.2Gi - 12Gi - 2Gi - 1Gi = ~8.2Gi mem / 3 cpu).
#  - enforceNodeAllocatable: [pods] faz o kubelet escrever as reservas no cgroup
#    kubepods, que vira o teto real de memoria dos pods: memory.max =
#    capacidade - reservas (9440Mi) = allocatable + a margem de eviction de 1Gi.
#    CPU nao ganha quota (cpu.max = max), entao pods podem estourar os 3 cores
#    se o host estiver ocioso. Driver e cgroupfs, entao o path e
#    /sys/fs/cgroup/kubepods (sem .slice).
#  - evictionHard protege o host quando a memoria disponivel cai.
enforceNodeAllocatable:
  - pods
kubeReserved:
  cpu: 250m
  memory: 2Gi
systemReserved:
  cpu: 750m
  memory: 12Gi
evictionHard:
  memory.available: 1Gi
EOF
)

  mkdir -p /var/lib/kubelet

  # $(...) remove os newlines finais dos dois lados -> comparacao estavel.
  if [ -f "$cfg" ] && [ "$(cat "$cfg")" = "$desired" ]; then
    log "kubelet config inalterada."
    return 0
  fi

  if [ -f "$cfg" ]; then
    local backup="$cfg.bak.$(date -u '+%Y%m%d%H%M%S')"
    cp -a "$cfg" "$backup"
    log "kubelet config mudou — backup em $backup"
  fi

  # Escrita atomica: nunca deixa config.yaml truncada se o container morrer no meio.
  printf '%s\n' "$desired" > "$cfg.tmp"
  mv "$cfg.tmp" "$cfg"
  log "kubelet config escrita."
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
# Enables cgroup controllers in the container's cgroup root. With `cgroup:
# private` (docker-compose) the container's /sys/fs/cgroup root IS the docker
# scope; controllers must be delegated (subtree_control) before kubelet can
# create pod QoS cgroups under /kubepods. No-op/ignored when running with the
# host cgroup namespace (controllers already enabled at the host root).
enable_cgroup_delegation() {
  local cg=/sys/fs/cgroup
  if [ -w "$cg/cgroup.subtree_control" ]; then
    echo "+cpu +memory +io +pids" > "$cg/cgroup.subtree_control" 2>/dev/null \
      && log "cgroup controllers delegated on $cg" \
      || log "WARN: could not enable cgroup.subtree_control on $cg"
  fi
}

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

# ── Cilium CNI health check ──────────────────────────────────────────────
# Returns 0 only when the CNI is actually serving NEW pods. Three layers:
#   1. DaemonSet exists with desired == ready
#   2. Agent answers on its local socket (cilium status)
#   3. End-to-end: a fresh probe pod gets a PodIP and completes. This is the
#      layer that catches a dead BPF datapath after a container restart,
#      where old pods may still report Running but no new pod can get a
#      network sandbox.
#
# NOTE: `cilium status --brief` is not a flag in this CLI build, so layer 2
# always fails and this function returns non-zero — which forces a Cilium
# reinstall on every boot. That reinstall is load-bearing: after the k8s-one
# container is recreated, the pod->ClusterIP datapath is stale and only a
# reinstall restores it. Do NOT "fix" this into a healthy result without
# first making the datapath recovery explicit elsewhere.
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
      force_remove_namespace cilium-secrets
    fi
  fi

  # Orphan VolumeAttachments (PV no longer exists) — safe to drop; the CSI
  # controller recreates any that are still needed.
  for va in $($kc get volumeattachment -o name 2>/dev/null | awk -F/ '{print $2}'); do
    local pv
    pv=$($kc get volumeattachment "$va" -o jsonpath='{.spec.source.persistentVolumeName}' 2>/dev/null || echo "")
    if [ -n "$pv" ] && ! $kc get pv "$pv" >/dev/null 2>&1; then
      log "Deleting orphan VolumeAttachment $va (PV $pv gone)"
      # Remove finalizers first: um finalizer órfão (ex.: CSI de um driver já
      # removido, como o Rook-Ceph) faz `kubectl delete` bloquear para sempre,
      # travando TODO o apply_manifests (o boot nunca chega ao READY).
      # --wait=false garante que um objeto em finalização nunca bloqueie o boot.
      $kc patch volumeattachment "$va" --type=merge \
        -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      $kc delete volumeattachment "$va" --wait=false 2>/dev/null || true
    fi
  done
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
    log "Cilium CNI not healthy yet; giving it time to warm up before deciding..."
    local grace_tries=24
    while [ "$grace_tries" -gt 0 ] && ! cilium_healthy; do
      sleep 10; grace_tries=$((grace_tries - 1))
    done
    if cilium_healthy; then
      log "Cilium CNI became healthy during the grace period; skipping reinstall."
    else
      log "Cilium CNI still unhealthy, reinstalling..."
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
        force_remove_namespace cilium-secrets
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
      --set ipam.operator.clusterPoolIPv4PodCIDRList="$CLUSTER_CIDR" \
      --wait 2>&1; then
      if ! $kc -n kube-system get ds cilium >/dev/null 2>&1; then
        log "FATAL: Cilium is not available and install failed"
        return 1
      fi
    fi

    # `cilium install --wait` can time out while the kubelet is recovering
    # stale runtime state even though the resources were created successfully.
    # The agent usually comes up moments after the wait expires (observed on a
    # busy boot: "FATAL ... not functional" followed by a fully healthy CNI).
    # So when the resources exist, degrade to a WARN and CONTINUE — aborting
    # here skips the rest of apply_manifests (metrics-server/cert-manager/argo
    # re-apply), which can leave the metrics.k8s.io APIService deleted by
    # cleanup_stale_apiservices and never recreated -> kubectl top broken for
    # the whole run. Next boot retries if the CNI really is dead.
    log "Waiting for Cilium CNI to become functional..."
    if ! cilium status --kubeconfig "$KUBE/admin.conf" \
        --wait --wait-duration 5m --brief >/dev/null 2>&1 || ! cilium_healthy; then
      log "WARN: Cilium resources exist, but the CNI is not yet functional; continuing boot"
    fi
    fi  # reinstall branch (was still unhealthy after the grace period)
  fi
  log "Cilium ready."

  # Wait for node Ready (Cilium will install CNI and make the node Ready)
  wait_for_node_ready

  # Apply CoreDNS
  log "Applying CoreDNS..."
  $kc apply -f "$MANIFESTS/built-in/coredns" 2>&1 | tail -6
  log "CoreDNS applied."

  # Apply local-path-provisioner (default StorageClass). It replaced Rook-Ceph:
  # in a single-node cluster the Ceph daemons (mon/mgr/osd/mds/CSI) consumed
  # ~2GiB of requests and were prone to the nbd/OSD deadlock. local-path
  # provisions hostPath volumes under /opt/local-path-provisioner, persisted on
  # the host by the ./data/local-path bind mount in docker-compose.yaml.
  log "Applying local-path-provisioner..."
  $kc apply -k "$MANIFESTS/built-in/local-path" 2>&1 | tail -9
  log "local-path-provisioner applied."

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

  # Apply metrics-server (metrics.k8s.io API — kubectl top / HPA). Applied at
  # the END of the boot, only once Cilium is up. cleanup_stale_apiservices
  # deletes any leftover metrics APIService early in the boot, so this late
  # apply is the authoritative (re)creation point. It must NOT run earlier:
  # an APIService created while the CNI is still warming/being reinstalled
  # stays unavailable, breaks namespace discovery and wedges cilium-secrets
  # in Terminating (the exact deadlock cleanup_stale_apiservices prevents).
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
  # SSO via Authentik (OIDC direto) + RBAC por grupo. O install.yaml recria o
  # argocd-cm/argocd-rbac-cm a cada boot, entao a config e reaplicada aqui como
  # merge patch (idempotente). O client secret fica no Secret `argocd-oidc`
  # (criado por scripts/create-secrets.sh); o rootCA do mkcert vai inline no
  # oidc-patch. Ver os comentarios em manifests/built-in/argocd/.
  $kc -n argocd patch cm argocd-cm --type merge \
    --patch-file "$MANIFESTS/built-in/argocd/oidc-patch.yaml" 2>&1 | tail -1 \
    || log "WARN: could not patch argocd-cm (OIDC)"
  $kc -n argocd patch cm argocd-rbac-cm --type merge \
    --patch-file "$MANIFESTS/built-in/argocd/rbac-patch.yaml" 2>&1 | tail -1 \
    || log "WARN: could not patch argocd-rbac-cm (RBAC)"
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
  cleanup_orphaned_containerd_records
  start_etcd
  start_apiserver
  start_controller_manager
  start_scheduler
  enable_cgroup_delegation
  start_kubelet
  start_kube_proxy

  # Apply manifests in background so we can `wait` on main processes
  apply_manifests &
  APPLY_PID=$!

  log "All components running. Waiting..."
  wait "${PIDS[@]}"
}

main "$@"
