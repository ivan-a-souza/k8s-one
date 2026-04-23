# K8s-One

Cluster Kubernetes **completo de nó único**, construído **do zero** a partir dos componentes individuais — sem K3s, KIND, kubeadm ou qualquer distribuição pronta.

Empacotado numa **imagem distroless-style** via multi-stage build.

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
└──────────────────────────────────────────────────┘
```

---

## Sumário

- [Quick Start](#quick-start)
- [Componentes](#componentes)
- [Arquitetura](#arquitetura)
- [Volumes Persistentes](#volumes-persistentes)
- [Configuração](#configuração)
- [Acesso ao Cluster](#acesso-ao-cluster)
- [Exemplos de Uso](#exemplos-de-uso)
- [Estrutura do Projeto](#estrutura-do-projeto)
- [Sequência de Inicialização](#sequência-de-inicialização)
- [PKI e Certificados](#pki-e-certificados)
- [Networking](#networking)
- [Storage](#storage)
- [Customização](#customização)
- [Troubleshooting](#troubleshooting)
- [Requisitos](#requisitos)
- [Limitações](#limitações)

---

## Quick Start

```bash
# Build
docker compose build

# Start
docker compose up -d

# Acompanhar inicialização (~90s na primeira vez)
docker compose logs -f

# Obter kubeconfig
docker cp k8s-one:/etc/kubernetes/admin-external.conf ./kubeconfig

# Usar
export KUBECONFIG=./kubeconfig
kubectl get nodes
kubectl get pods -A
```

**Saída esperada:**

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

## Componentes

Todos os binários são baixados de fontes oficiais no build. Nenhum componente pré-empacotado é usado.

| Componente | Versão | Fonte | Função |
|---|---|---|---|
| **kube-apiserver** | v1.36.0 | dl.k8s.io | API REST do Kubernetes |
| **kube-controller-manager** | v1.36.0 | dl.k8s.io | Controladores (replication, endpoints, etc.) |
| **kube-scheduler** | v1.36.0 | dl.k8s.io | Agendamento de pods nos nós |
| **kubelet** | v1.36.0 | dl.k8s.io | Agente do nó, gerencia containers |
| **kube-proxy** | v1.36.0 | dl.k8s.io | Proxy de rede (iptables mode) |
| **kubectl** | v1.36.0 | dl.k8s.io | CLI para interação com o cluster |
| **etcd** | v3.5.21 | github.com/etcd-io | Key-value store do cluster |
| **containerd** | 1.7.27 | github.com/containerd | Container runtime (CRI) |
| **runc** | v1.2.6 | github.com/opencontainers | OCI runtime |
| **CNI plugins** | v1.6.2 | github.com/containernetworking | Plugins de rede base |
| **Calico** | v3.29.2 | projectcalico/calico | CNI — networking + network policy |
| **CoreDNS** | v1.12.0 | registry.k8s.io | DNS do cluster |
| **local-path-provisioner** | v0.0.35 | rancher/local-path-provisioner | Dynamic PV provisioning via hostPath |

---

## Arquitetura

### Multi-Stage Build (Distroless)

```
┌─────────────────────────────────────┐
│  Stage 1: Builder (alpine:3.21)     │
│                                     │
│  • curl, tar, gzip                  │
│  • Download de todos os binários    │
│  • Download dos manifests           │
│  • Descartado no build final        │
└──────────────┬──────────────────────┘
               │ COPY binários
               ▼
┌─────────────────────────────────────┐
│  Stage 2: Runtime (alpine:3.21)     │
│                                     │
│  • iptables, conntrack, iproute2    │
│  • openssl, socat, util-linux       │
│  • gcompat (glibc compat)           │
│  • SEM apk (removido no build)      │
│  • SEM docs, man pages, caches      │
│  • = Imagem "distroless-style"      │
└─────────────────────────────────────┘
```

A imagem final **não possui package manager** — `apk` é removido após instalar as dependências de runtime. Isso elimina a possibilidade de instalar pacotes em runtime, reduzindo a superfície de ataque.

### Processo de Inicialização

O `entrypoint.sh` orquestra **7 processos** que rodam simultaneamente dentro do container:

```
entrypoint.sh
├── setup_mounts()        # mount --make-rshared /, /sys, bpf
├── detect_ip()           # detecta IP do container
├── generate_pki()        # gera 3 CAs + 11 certs + SA keys
├── generate_kubeconfigs() # gera 6 kubeconfigs
│
├── containerd ──────────▶ aguarda socket
├── etcd ────────────────▶ aguarda health (via etcdctl + TLS)
├── kube-apiserver ──────▶ aguarda /healthz
├── kube-controller-manager
├── kube-scheduler
├── kubelet
├── kube-proxy
│
└── apply_manifests() [background]
    ├── taint removal (permite workloads)
    ├── kubectl apply calico.yaml
    ├── aguarda Node Ready
    ├── kubectl apply coredns.yaml
    └── kubectl apply local-path-storage.yaml
```

---

## Volumes Persistentes

Todos os dados de estado são montados em Docker volumes nomeados, garantindo persistência entre restarts:

| Volume | Mount no Container | Conteúdo |
|---|---|---|
| `etcd-data` | `/var/lib/etcd` | Dados do etcd (state do cluster) |
| `containerd-data` | `/var/lib/containerd` | Imagens e containers |
| `kubelet-data` | `/var/lib/kubelet` | Estado do kubelet e pods |
| `k8s-pki` | `/etc/kubernetes/pki` | Certificados TLS (CAs, certs, keys) |
| `k8s-configs` | `/etc/kubernetes` | Kubeconfigs (admin, scheduler, etc.) |
| `local-path-data` | `/opt/local-path-provisioner` | PersistentVolumes criados pelo local-path |

Além dos volumes nomeados, o container monta:

| Host Path | Container Path | Modo | Motivo |
|---|---|---|---|
| `/sys` | `/sys` | `rw` | Calico BPF, cgroups |
| `/lib/modules` | `/lib/modules` | `ro` | Módulos do kernel (iptables, etc.) |

### Limpar tudo

```bash
docker compose down -v   # remove container + todos os volumes
```

---

## Configuração

### Build Args

Todas as versões são configuráveis via build args no Dockerfile:

```bash
# Usar uma versão específica do Kubernetes
docker compose build --build-arg KUBE_VERSION=v1.35.0

# Usar uma versão específica do Calico
docker compose build --build-arg CALICO_VERSION=v3.28.0

# Build para arm64 (não testado)
docker compose build --build-arg TARGETARCH=arm64
```

| Build Arg | Default | Descrição |
|---|---|---|
| `KUBE_VERSION` | `v1.36.0` | Versão do Kubernetes |
| `ETCD_VERSION` | `v3.5.21` | Versão do etcd |
| `CONTAINERD_VERSION` | `1.7.27` | Versão do containerd |
| `RUNC_VERSION` | `v1.2.6` | Versão do runc |
| `CNI_VERSION` | `v1.6.2` | Versão dos CNI plugins |
| `CALICO_VERSION` | `v3.29.2` | Versão do Calico |
| `LOCAL_PATH_VERSION` | `v0.0.35` | Versão do local-path-provisioner |
| `TARGETARCH` | `amd64` | Arquitetura alvo |

### Variáveis de Ambiente (runtime)

| Variável | Default | Descrição |
|---|---|---|
| `NODE_NAME` | `k8s-one` | Nome do nó no cluster |

### Parâmetros de Rede (entrypoint.sh)

| Parâmetro | Valor | Descrição |
|---|---|---|
| `CLUSTER_CIDR` | `192.168.0.0/16` | CIDR dos pods (compatível com Calico default) |
| `SERVICE_CIDR` | `10.96.0.0/12` | CIDR dos ClusterIPs |
| `CLUSTER_DNS` | `10.96.0.10` | IP do CoreDNS |

---

## Acesso ao Cluster

### Kubeconfig Externo

```bash
# Copiar kubeconfig do container
docker cp k8s-one:/etc/kubernetes/admin-external.conf ./kubeconfig

# Usar
export KUBECONFIG=./kubeconfig
kubectl get nodes
kubectl get pods -A
kubectl get sc
```

O kubeconfig externo usa o IP do container como endpoint. Para acessar de fora do host Docker, substitua o IP no kubeconfig pelo IP do host:

```bash
# Ver o IP atual no kubeconfig
grep server kubeconfig

# Substituir pelo IP do host (a porta 6443 é exposta no docker-compose)
sed -i 's|https://.*:6443|https://<HOST_IP>:6443|' kubeconfig
```

### Kubeconfig Interno (dentro do container)

```bash
docker exec k8s-one kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A
```

---

## Exemplos de Uso

### Deploy de um Pod simples

```bash
kubectl run nginx --image=nginx:alpine --port=80
kubectl get pods -w
```

### PVC com local-path-provisioner

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

### Network Policy com Calico

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
```

### Deployment com Service

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

---

## Estrutura do Projeto

```
k8s-one/
├── Dockerfile                          # Multi-stage build (builder + runtime)
├── docker-compose.yaml                 # Execução com volumes persistentes
├── README.md                           # Este arquivo
│
├── scripts/
│   └── entrypoint.sh                   # Orquestração: PKI, configs, processos, manifests
│
├── configs/
│   └── containerd-config.toml          # containerd: runc + cgroupfs + overlayfs
│
└── manifests/
    └── coredns.yaml                    # CoreDNS (ServiceAccount, RBAC, Deployment, Service)
    # calico.yaml                       # (baixado no build — projectcalico/calico)
    # local-path-storage.yaml           # (baixado no build — rancher/local-path-provisioner)
```

---

## Sequência de Inicialização

Timeline típica da primeira execução (cold start, sem cache de imagens):

```
 0s   ▶ Mount propagation (rshared /, /sys, bpf)
 0s   ▶ PKI generation (3 CAs, 11 certs, SA keypair)
 1s   ▶ Kubeconfig generation (6 arquivos)
 1s   ▶ containerd start → socket ready
 2s   ▶ etcd start → health check OK
 5s   ▶ kube-apiserver start → /healthz OK
 7s   ▶ kube-controller-manager start
 7s   ▶ kube-scheduler start
 7s   ▶ kubelet start → node registrado
 8s   ▶ kube-proxy start
 8s   ▶ kubectl apply calico.yaml
30s   ▶ Calico images pulled + calico-node Running
35s   ▶ Node Ready ✓
35s   ▶ kubectl apply coredns.yaml
40s   ▶ kubectl apply local-path-storage.yaml
90s   ▶ Todos os pods Running ✓
```

> Em restarts subsequentes (imagens já em cache), o tempo total cai para ~30-40s.

---

## PKI e Certificados

O entrypoint gera toda a PKI na primeira execução. Certificados são persistidos no volume `k8s-pki` e reutilizados em restarts.

### CAs (Certificate Authorities)

| CA | CN | Uso |
|---|---|---|
| `ca` | `kubernetes-ca` | CA raiz do cluster |
| `etcd/ca` | `etcd-ca` | CA do etcd (separada) |
| `front-proxy-ca` | `front-proxy-ca` | CA para aggregation layer |

### Certificados

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

| Arquivo | Tipo |
|---|---|
| `sa.key` | RSA 2048 private key |
| `sa.pub` | Public key (para verificação de tokens) |

Todos os certificados têm validade de **10 anos** (3650 dias).

---

## Networking

### Calico

- **Modo**: VXLAN (default do manifest)
- **Pod CIDR**: `192.168.0.0/16`
- **Network Policy**: ✅ suportado
- **IPAM**: Calico IPAM

O Calico é instalado via manifest direto (sem Tigera Operator), o que simplifica a instalação mas requer gestão manual de upgrades.

### kube-proxy

- **Modo**: iptables
- **Service CIDR**: `10.96.0.0/12`

### CoreDNS

- **ClusterIP**: `10.96.0.10`
- **Forward**: `8.8.8.8`, `1.1.1.1` (Google DNS, Cloudflare)
- **Domínio**: `cluster.local`

---

## Storage

### local-path-provisioner

- **StorageClass**: `local-path` (default)
- **Provisioner**: `rancher.io/local-path`
- **Reclaim Policy**: `Delete`
- **Bind Mode**: `WaitForFirstConsumer`
- **Path no host**: `/opt/local-path-provisioner` (persistido em volume Docker)

```bash
# Verificar StorageClass
kubectl get sc
# NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

---

## Customização

### Trocar o DNS upstream

Edite `manifests/coredns.yaml`, seção `forward`:

```
forward . 8.8.8.8 1.1.1.1 {
```

### Trocar o containerd runtime

Edite `configs/containerd-config.toml`:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = false   # true se o host usa systemd cgroups
```

### Trocar o Pod CIDR

Altere em **dois lugares**:
1. `scripts/entrypoint.sh` → `CLUSTER_CIDR`
2. Calico manifest (rebuild necessário ou editar o manifest baixado)

---

## Troubleshooting

### Container morre imediatamente

```bash
docker compose logs --tail 50
```

Causas comuns:
- Falta de `--privileged` no docker-compose
- `/sys` não montado como shared

### Pods stuck em ContainerCreating

```bash
kubectl describe pod <pod-name> -n <namespace>
```

Causas comuns:
- Calico ainda não instalou o CNI → aguardar calico-node ficar Running
- Erro de mount propagation → verificar se `/sys` está montado rw

### CoreDNS CrashLoopBackOff

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns
```

Causas comuns:
- Loop detection → já resolvido com forward para 8.8.8.8
- Corefile syntax error → verificar `manifests/coredns.yaml`

### Node NotReady

```bash
kubectl describe node k8s-one
```

Causas comuns:
- CNI não instalado → Calico ainda inicializando
- kubelet não consegue se comunicar com apiserver → verificar certs

### Ver logs de um componente específico

```bash
# Todos os logs misturados
docker compose logs -f

# Filtrar por componente (grep no container)
docker compose logs -f | grep apiserver
docker compose logs -f | grep kubelet
docker compose logs -f | grep etcd
```

### Reset completo

```bash
docker compose down -v   # remove container + todos os volumes
docker compose up -d     # fresh start
```

---

## Requisitos

### Host

| Requisito | Mínimo | Recomendado |
|---|---|---|
| **Docker** | 24.0+ | 27.0+ |
| **Docker Compose** | v2.20+ | v2.30+ |
| **RAM** | 2 GB | 4 GB |
| **CPU** | 2 cores | 4 cores |
| **Disco** | 5 GB (imagem) | 10 GB+ |
| **OS** | Linux (kernel 5.10+) | Linux (kernel 6.x) |
| **Arch** | amd64 | amd64 |

### Portas

| Porta | Protocolo | Uso |
|---|---|---|
| `6443` | TCP | Kubernetes API Server |

---

## Limitações

- **Não é HA**: nó único, sem redundância. etcd, apiserver, etc. são single-instance.
- **Não para produção**: destinado a desenvolvimento, testes, CI/CD, laboratório.
- **Privileged mode**: o container roda com `--privileged` (necessário para kubelet/containerd).
- **Apenas amd64**: arm64 pode funcionar com `--build-arg TARGETARCH=arm64` mas não foi testado.
- **Sem systemd**: usa `cgroupfs` como cgroup driver (sem systemd dentro do container).
- **Cert rotation**: desabilitada. Certificados duram 10 anos. Para clusters de longa duração, considere implementar rotação.

---

## Licença

MIT
