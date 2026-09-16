*[🇺🇸 English](README.md)*

# K8s-One

Cluster Kubernetes **completo de nó único**, construído **do zero** a partir dos componentes individuais — sem K3s, KIND, kubeadm ou qualquer distribuição pronta.

Empacotado numa **imagem mínima baseada em Debian** via multi-stage build (sem package manager em runtime).

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
│  Ingress: HAProxy (Portas host 8082/8443)        │
│  Metrics: metrics-server (API metrics.k8s.io)    │
└──────────────────────────────────────────────────┘
```

---

## Sumário

- [Quick Start](#quick-start)
- [Componentes](#componentes)
- [Arquitetura](#arquitetura)
- [Volumes Persistentes](#volumes-persistentes)
- [Configuração](#configuração)
- [Segredos](#segredos)
- [Acesso ao Cluster](#acesso-ao-cluster)
- [Exemplos de Uso](#exemplos-de-uso)
- [Estrutura do Projeto](#estrutura-do-projeto)
- [Sequência de Inicialização](#sequência-de-inicialização)
- [PKI e Certificados](#pki-e-certificados)
- [Networking](#networking)
- [Storage](#storage)
- [Problemas Conhecidos](#problemas-conhecidos)
- [Customização](#customização)
- [Troubleshooting](#troubleshooting)
- [Requisitos](#requisitos)
- [Limitações](#limitações)

---

## Quick Start

Copie `.env.example` para `.env` e informe o IP Tailscale desta máquina
(`tailscale ip -4`):

```dotenv
ARGOCD_VERSION=v3.5.1
TAILSCALE_IP=100.x.y.z
```

O Docker Compose carrega esse arquivo automaticamente. Ele é ignorado pelo Git
para que cada ambiente possa escolher sua versão do Argo CD e seu endereço
Tailscale.

```bash
# Build
docker compose build

# Start
docker compose up -d

# Acompanhar inicialização (~2-3 min na primeira vez)
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
| **Cilium** | v1.19.5 | github.com/cilium/cilium | CNI — networking + network policy (eBPF) |
| **Cilium CLI** | v0.19.4 | github.com/cilium/cilium-cli | Instalação & gerenciamento do Cilium |
| **CoreDNS** | v1.12.0 | registry.k8s.io | DNS do cluster |
| **Rook** | v1.20.3 | github.com/rook/rook | Operador do Ceph (CRDs, operator, CSI) |
| **Ceph** | v20.2.2 | quay.io/ceph/ceph | Daemons de storage (mon, mgr, osd, mds) |
| **Ceph CSI** | v3.17.0 | quay.io/cephcsi | Drivers CSI (RBD block + CephFS) |
| **HAProxy Ingress** | pinado por digest | haproxytech/kubernetes-ingress | Ingress Controller (HAProxy 3.2.21) |
| **metrics-server** | v0.9.0 (pinado por digest) | registry.k8s.io | API metrics.k8s.io — kubectl top / HPA |

---

## Arquitetura

### Multi-Stage Build (Runtime mínimo)

```
┌─────────────────────────────────────┐
│  Stage 1: Builder (alpine:3.21)     │
│                                     │
│  • curl, tar, gzip                  │
│  • Download de todos os binários    │
│  • Download dos manifests do Rook   │
│  • Descartado no build final        │
└──────────────┬──────────────────────┘
               │ COPY binários
               ▼
┌─────────────────────────────────────┐
│  Stage 2: Runtime (debian:bookworm) │
│                                     │
│  • bash, openssl, iptables, udev    │
│  • losetup, socat, conntrack        │
│  • apt/dpkg removidos no build      │
│  • = imagem mínima, sem pkg manager │
└─────────────────────────────────────┘
```

A imagem final **não possui package manager** — `apt`/`dpkg` são removidos após instalar as dependências de runtime, reduzindo a superfície de ataque.

### Processo de Inicialização

O `entrypoint.sh` orquestra os processos do control-plane, o loop device do OSD do Ceph e a aplicação dos manifests:

```
entrypoint.sh
├── setup_mounts()        # mount --make-rshared /, /sys, bpf (Cilium)
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
├── setup_ceph_osd_loop() # cria/attach /dev/loop0 ← osd.img (30G sparse)
├── start_udevd()         # udev + watcher de device-nodes RBD
│
└── apply_manifests() [background]
    ├── taint removal (permite workloads)
    ├── cilium install (CNI, reinstalação limpa a cada boot)
    ├── aguarda Node Ready
    ├── kubectl apply -f coredns/
    ├── kubectl apply rook CRDs + common + CSI operator + operator
    ├── patch ROOK_CEPH_ALLOW_LOOP_DEVICES=true (verificado)
    ├── kubectl apply -k ceph/ (cluster Ceph + pools + SC + dashboard)
    ├── kubectl apply -f haproxy-ingress/
    └── kubectl apply -f metrics-server/
```

---

## Volumes Persistentes

Todo o estado do cluster é armazenado em **bind mounts** em `./data/`, garantindo persistência entre restarts e deixando os dados diretamente visíveis/backupeáveis no host:

| Host Path | Mount no Container | Conteúdo |
|---|---|---|
| `./data/etcd/` | `/var/lib/etcd` | Dados do etcd (state do cluster) |
| `./data/containerd/` | `/var/lib/containerd` | Imagens e containers |
| `./data/kubelet/` | `/var/lib/kubelet` | Estado do kubelet e pods |
| `./data/pki/` | `/etc/kubernetes/pki` | Certificados TLS (CAs, certs, keys) |
| `./data/kubernetes/` | `/etc/kubernetes` | Kubeconfigs (admin, scheduler, etc.) |
| `./data/rook/` | `/var/lib/rook` | Dados do Ceph: imagem OSD + keyrings |

Além dos bind mounts, o container monta paths do sistema host:

| Host Path | Container Path | Modo | Motivo |
|---|---|---|---|
| `/sys` | `/sys` | `rw` | Cilium BPF, cgroups |
| `/lib/modules` | `/lib/modules` | `ro` | Módulos do kernel (iptables, etc.) |

> ⚠️ `./data/` e `./data/rook/` contêm segredos do cluster (keyrings do Ceph, chaves privadas da PKI, kubeconfigs). Ambos estão **gitignored** — nunca commitar.

### Limpar tudo

```bash
docker compose down -v   # remove container + volumes nomeados (bind mounts em ./data/ e ./data/rook/ são mantidos)
# Para apagar totalmente os dados do cluster: rm -rf data/* data/rook/*   (irreversível!)
```

---

## Configuração

### Build Args

Todas as versões são configuráveis via build args no Dockerfile:

```bash
# Usar uma versão específica do Kubernetes
docker compose build --build-arg KUBE_VERSION=v1.35.0

# Usar uma versão específica do Cilium
docker compose build --build-arg CILIUM_VERSION=v1.18.0

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
| `CILIUM_VERSION` | `v1.19.5` | Versão do Cilium |
| `CILIUM_CLI_VERSION` | `v0.19.4` | Versão do Cilium CLI |
| `ROOK_VERSION` | `v1.20.3` | Versão do operador Rook (manifests baixados dessa tag) |
| `TARGETARCH` | `amd64` | Arquitetura alvo |

> A **versão da imagem do Ceph** é definida em `manifests/built-in/ceph/01-ceph-cluster.yaml` (`quay.io/ceph/ceph:v20.2.2` — pinada na versão oficialmente testada com o Rook 1.20.3; **não** usar a tag flutuante `:v20`).

### Variáveis de Ambiente (runtime)

| Variável | Default | Descrição |
|---|---|---|
| `NODE_NAME` | `k8s-one` | Nome do nó no cluster |
| `ROOK_OSD_SIZE` | `30G` | Tamanho da imagem sparse do OSD (`/var/lib/rook/osd.img`) |
| `ARGOCD_VERSION` | `v3.5.1` | Versão do Argo CD instalada no boot (formato: `vX.Y.Z`) |

Defina `ARGOCD_VERSION` no arquivo `.env` da raiz. Depois de alterar a versão,
recrie o container para que ela seja aplicada durante a inicialização:

```bash
docker compose up -d --force-recreate
```

### Parâmetros de Rede (entrypoint.sh)

| Parâmetro | Valor | Descrição |
|---|---|---|
| `CLUSTER_CIDR` | `192.168.0.0/16` | CIDR dos pods (Cilium auto-detecta do controller-manager) |
| `SERVICE_CIDR` | `10.96.0.0/12` | CIDR dos ClusterIPs |
| `CLUSTER_DNS` | `10.96.0.10` | IP do CoreDNS |

### Reservas de Recursos (kubelet)

O kubelet anuncia a memória do **host** como capacidade do nó (o container não tem
limite de memória próprio), então as reservas abaixo são a forma que o cluster tem
de contar a verdade ao scheduler: elas "mentem para baixo" de propósito, para que
os pods recebam um orçamento realista e o host fique protegido.

| Configuração | Valor | Efeito |
|---|---|---|
| `systemReserved` | `750m` / `12Gi` | Reservado para o host (sessão do desktop, daemons) |
| `kubeReserved` | `250m` / `2Gi` | Reservado para control plane + runtime (etcd, apiserver, kubelet, containerd) |
| `evictionHard` | `memory.available: 1Gi` | Kubelet começa a evictar pods abaixo disso |
| `enforceNodeAllocatable` | `[pods]` | Faz o kubelet escrever as reservas no cgroup `kubepods` (veja abaixo o que de fato vai parar lá) |

Num host de 4 CPU / 23,2 GiB isso resulta em:

```
capacidade        4 cpu      24346668Ki (23,2 GiB)
 - kubeReserved    250m        2 GiB
 - systemReserved  750m       12 GiB
 - evictionHard      --        1 GiB
 = allocatable     3 cpu      ~8,2 GiB   <- o orçamento de scheduling
```

Três consequências que vale internalizar:

- **O `kubectl top nodes` reporta mais de 100% de memória.** O `/proc/meminfo` não é
  namespaced, então o kubelet lê o uso do *host* enquanto o denominador é os 8,2 GiB
  alocáveis. Um valor como `207%` não é vazamento — é o desktop inteiro.
- **A memória tem exatamente um teto real, e ele é ~9,2 GiB — não os 8,2 GiB alocáveis.**
  O `enforceNodeAllocatable` faz o kubelet setar `memory.max` no cgroup `kubepods` como
  *capacidade − reservas* (`9898602496` = 9440 MiB), e os 8,2 GiB do scheduler são esse
  valor menos a margem de eviction de 1 GiB. O driver é `cgroupfs`, então o caminho é
  `/sys/fs/cgroup/kubepods` (sem `.slice`). O container em si é ilimitado (`Memory: 0`),
  e os processos do control plane rodam *fora* do `kubepods`, cobertos apenas pela
  *reserva* de `systemReserved` — não por um limite imposto.
- **A CPU não tem teto em camada nenhuma.** O `cpu.max` está sem quota (`max 100000`)
  tanto no container quanto no `kubepods`, então os pods podem estourar os 3 cores
  alocáveis sempre que o host tiver ciclos ociosos. Só o *scheduling* é limitado a
  3 cores — o consumo, não.

**Os requests são o orçamento de scheduling.** São eles que travam rollouts: quando
se aproximam do allocatable, o pod de substituição do `maxSurge` não consegue ser
agendado e aparecem eventos `0/1 nodes are available: 1 Insufficient cpu`. O uso real
aqui fica bem abaixo dos requests, então vale acompanhar essa razão — e lembrar que
sidecars injetados por chart (ex.: o `ybCleanup` do Yugabyte) somam requests que não
aparecem nos valores que você escreveu.

A config é escrita por `write_kubelet_config()` em `scripts/entrypoint.sh` para
`/var/lib/kubelet/config.yaml`, que fica no bind mount `./data/kubelet` e portanto
**persiste entre restarts do container**. A função regenera o arquivo no boot sempre
que o conteúdo divergir do heredoc (guardando um `.bak` com timestamp). Um kubelet em
execução não recarrega a config, então **mudanças só valem após reiniciar o container**.

> Não reduza o `systemReserved` para aumentar o allocatable. Ele existe justamente
> porque o nó divide RAM com o desktop; espera-se que os pods caibam em ~8 GiB.

---

## Segredos

Nenhuma credencial é versionada. Os valores vivem em `manifests/**/secrets/`
(ignorado pelo `.gitignore`) e são aplicados ao cluster por
`scripts/create-secrets.sh`. As Applications do Argo CD apenas **referenciam**
os Secrets via `existingSecret` — nunca contêm senha.

### Onde ficam

| Secret | Namespace | Arquivo-fonte (gitignored) | Usado por |
|---|---|---|---|
| `authentik-config` | `platform` | `manifests/argocd/authentik/secrets/authentik.env` | `authentik.existingSecret` |
| `authentik-postgresql-auth` | `platform` | `manifests/argocd/authentik/secrets/postgresql-auth.yaml` | `postgresql.auth.existingSecret` |
| `grafana-admin` | `monitoring` | `manifests/argocd/prometheus-stack/secrets/grafana-admin.yaml` | `grafana.admin.existingSecret` |
| `mkcert-ca` | `cert-manager` | `manifests/built-in/cert-manager/secrets/mkcert-ca.yaml` | CA raiz do ClusterIssuer `local-ca` |

Formatos:
- `*.env` → criado com `kubectl create secret generic --from-env-file` (ex.: `authentik.env`).
- `*.yaml` → manifest `kind: Secret` (com `stringData`) aplicado com `kubectl apply -f`.

### Criar/atualizar

```bash
scripts/create-secrets.sh          # idempotente; usa ./kubeconfig (ou $KUBECONFIG)
```

Rodar **antes** de aplicar as Applications do Argo CD (o `existingSecret`
precisa existir). Manualmente:

```bash
kubectl -n platform create secret generic authentik-config \
  --from-env-file=manifests/argocd/authentik/secrets/authentik.env \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/argocd/authentik/secrets/postgresql-auth.yaml
kubectl apply -f manifests/argocd/prometheus-stack/secrets/grafana-admin.yaml
```

### Ler

```bash
# uma chave do env do authentik
kubectl -n platform get secret authentik-config -o jsonpath='{.data.AUTHENTIK_POSTGRESQL__PASSWORD}' | base64 -d
# senha do Grafana
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
# todas as chaves de um secret
kubectl -n platform get secret authentik-postgresql-auth -o jsonpath='{.data}' | jq
```

### Regras

- **Nunca** commitar arquivos em `secrets/` nem embutir senha em `02-application.yaml`.
- Trocar uma senha = editar o arquivo-fonte em `secrets/`, rodar o script e
  reiniciar o workload. Para o PostgreSQL do authentik a senha é gravada no
  banco na inicialização: além do Secret, rode `ALTER USER` no banco (ou
  rotacione via `postgresql.passwordUpdateJob`).
- Confirme que nada está rastreado: `git check-ignore manifests/argocd/*/secrets/*`.

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

### PVC com Ceph RBD (block, ReadWriteOnce)

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

### PVC com CephFS (ReadWriteMany)

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

Qualquer número de pods no nó pode montar `shared-data` simultaneamente (validado: 2 réplicas lendo/escrevendo o mesmo volume).

### Network Policy com Cilium

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

### Ingress com HAProxy

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  annotations:
    haproxy.org/ingress.class: haproxy
spec:
  rules:
  - host: meu-app.local
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
curl -H "Host: meu-app.local" http://localhost:8082/
```

---

## Estrutura do Projeto

```
k8s-one/
├── Dockerfile                          # Multi-stage build (builder alpine + runtime debian)
├── docker-compose.yaml                 # Execução com volumes persistentes
├── README.md                           # Documentação (Inglês)
├── README.pt-BR.md                     # Documentação (Português)
│
├── scripts/
│   ├── entrypoint.sh                   # Orquestração: PKI, configs, processos, manifests
│   ├── deploy-apps.sh                  # Aplica manifests/apps via kustomize (sem docker cp)
│   ├── create-secrets.sh               # Cria/atualiza Secrets a partir de manifests/**/secrets/
│   ├── rbd-nbd-reaper.sh               # Desmapeia rbd-nbd órfãos (boot; dry-run por padrão)
│   ├── fix-rbd-stale.sh                # Recuperação manual de mapeamentos rbd-nbd órfãos
│   └── fix-nbd-stuck.sh                # Desconecta nbd mortos (container/Docker travado)
│
├── configs/
│   └── containerd-config.toml          # containerd: runc + cgroupfs + overlayfs
│
└── manifests/                          # GITIGNORED — montado ro no container
    ├── built-in/                       # Núcleo: aplicado pelo entrypoint.sh no boot
    │   ├── coredns/                    # CoreDNS (um recurso Kubernetes por arquivo)
    │   │   ├── 01-service-account.yaml
    │   │   ├── 02-cluster-role.yaml
    │   │   ├── 03-cluster-role-binding.yaml
    │   │   ├── 04-configmap.yaml
    │   │   ├── 05-deployment.yaml
    │   │   └── 06-service.yaml
    │   ├── haproxy-ingress/            # HAProxy Ingress (um recurso Kubernetes por arquivo)
    │   │   ├── 01-namespace.yaml
    │   │   ├── 02-service-account.yaml
    │   │   ├── 03-cluster-role.yaml
    │   │   ├── 04-cluster-role-binding.yaml
    │   │   ├── 05-configmap.yaml
    │   │   ├── 06-deployment.yaml
    │   │   └── 07-service.yaml
    │   ├── metrics-server/             # API de métricas (um recurso Kubernetes por arquivo)
    │   │   ├── 01-service-account.yaml
    │   │   ├── 02-aggregated-metrics-reader-cluster-role.yaml
    │   │   ├── 03-metrics-server-cluster-role.yaml
    │   │   ├── 04-auth-reader-role-binding.yaml
    │   │   ├── 05-auth-delegator-cluster-role-binding.yaml
    │   │   ├── 06-metrics-server-cluster-role-binding.yaml
    │   │   ├── 07-service.yaml
    │   │   ├── 08-deployment.yaml
    │   │   └── 09-api-service.yaml
    │   └── ceph/                       # Cluster Ceph, storage e dashboard
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
    │   ├── metallb/                     # MetalLB L2 (LB p/ serviços; ver "DNS Local" — não é o caminho externo)
    │   │   ├── 00-crds.yaml … 07-webhook.yaml
    │   │   ├── 02-ipaddresspool.yaml   # 192.168.1.200-250 (LAN)
    │   │   └── kustomization.yaml
    │   └── cert-manager/                # Certificados internos *.lan (CA mkcert)
    │       ├── 00-crds.yaml … 05-webhooks.yaml
    │       ├── cluster-issuer.yaml     # ClusterIssuer "local-ca" (CA do mkcert)
    │       ├── certificate-dns-lan.yaml# dns.lan + *.lan → secret dns-lan-tls
    │       ├── kustomization.yaml
    │       └── secrets/
    │           └── mkcert-ca.yaml      # CA raiz do mkcert (nunca commitar)
    ├── argocd/                          # Applications (Argo CD) — Helm charts
    │   ├── authentik/
    │   │   ├── 02-application.yaml      # existingSecret: authentik-config / authentik-postgresql-auth
    │   │   └── secrets/                 # GITIGNORED (nunca commitar)
    │   │       ├── authentik.env        # env do app (AUTHENTIK_*)
    │   │       └── postgresql-auth.yaml # auth do PostgreSQL (postgres-password/password)
    │   ├── prometheus-stack/
    │   │   ├── 02-application.yaml      # existingSecret: grafana-admin
    │   │   └── secrets/
    │   │       └── grafana-admin.yaml   # admin do Grafana (admin-user/admin-password)
    │   └── yugabyte/
    │       └── 02-application.yaml
    ├── apps/                           # Sob demanda; um recurso Kubernetes por arquivo YAML
    │   ├── kustomization.yaml          # Compõe as pastas dos apps
    │   └── tileserver/                 # TileServer GL
    # rook-crds/common/csi-operator/operator.yaml  (baixados no build do Rook v1.20.3)
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
 7s   ▶ kube-controller-manager / scheduler / kubelet / kube-proxy
 8s   ▶ Attach do loop device do OSD (/dev/loop0 ← osd.img) + udevd
10s   ▶ cilium install (reinstalação limpa a cada boot)
35s   ▶ Node Ready ✓
40s   ▶ CoreDNS, operador Rook, cluster Ceph, HAProxy aplicados
~2-3m ▶ Rook-Ceph saudável (mon, mgr, osd) — Ceph cluster Ready
```

> Em restarts subsequentes (imagens já em cache), o boot cai para ~1-2 min. Os dados do OSD do Ceph sobrevivem via `data/rook/`.

---

## PKI e Certificados

O entrypoint gera toda a PKI na primeira execução. Certificados são persistidos no bind mount `./data/pki/` e reutilizados em restarts.

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

### Cilium

- **Datapath**: eBPF
- **Pod CIDR**: `192.168.0.0/16` (auto-detectado do kube-controller-manager)
- **Network Policy**: ✅ suportado (CiliumNetworkPolicy + k8s NetworkPolicy)
- **IPAM**: cluster-pool (padrão)
- **kube-proxy replacement**: desabilitado (kube-proxy roda junto)
- **Hubble**: ✅ observabilidade & monitoramento

O Cilium é instalado via Cilium CLI, que gerencia o Helm chart e fornece monitoramento de status. Ele é **totalmente desinstalado e reinstalado a cada boot** (o datapath BPF em memória não sobrevive ao restart do container).

### kube-proxy

- **Modo**: iptables
- **Service CIDR**: `10.96.0.0/12`

### CoreDNS

- **ClusterIP**: `10.96.0.10`
- **Forward**: `8.8.8.8`, `1.1.1.1` (Google DNS, Cloudflare)
- **Domínio**: `cluster.local`

### DNS Local (AdGuard) & Certificados Internos

O **AdGuard Home** (`apps/adguard`) é o DNS da LAN/tailnet e resolve os domínios internos `*.lan` apontando para o cluster. O CoreDNS continua responsável por `cluster.local` (DNS interno do cluster) — o AdGuard é para acesso das aplicações por nome.

Fluxo de uma consulta a `https://dns.lan` (dashboard do AdGuard):

```
device → AdGuard (192.168.1.20:53)
       → rewrite "dns.lan → 192.168.1.20"        (config em AdGuardHome.yaml, PVC adguard-conf-fs)
       → browser → 192.168.1.20:443 (porta publicada do host)
       → Ingress HAProxy (Host: dns.lan) → service adguard:80 → UI (3000)
```

- **Por que `.lan` e não `.local`**: `.local` é reservado para mDNS (RFC 6762). Android e macOS resolvem `.local` via mDNS e **nunca** via o DNS unicast — por isso `dns.local` falha nesses dispositivos mesmo com o DNS certo. `.lan` cai no resolvedor unicast normal.
- **Rewrite no AdGuard**: `dns.lan → 192.168.1.20` (IP fixo do host na LAN — não o IP do MetalLB; ver abaixo).
- **Acesso externo = portas publicadas do host**: o cluster roda numa rede docker isolada (`192.168.32.0/20`). O MetalLB (instalado em `built-in/metallb`) anuncia o IP LoadBalancer (`192.168.1.200`) **dentro dessa rede docker, não na WiFi** — logo **não é alcançável da LAN**. O caminho real é o `docker-compose` publicando `0.0.0.0:80/443 → NodePort 30080/30443` no IP físico do host (`192.168.1.20`). O rewrite aponta para `192.168.1.20`, **não** para `192.168.1.200`.
- **Certificados (cert-manager + mkcert)**: o `ClusterIssuer local-ca` usa a **CA raiz do mkcert** (`~/.local/share/mkcert/rootCA.pem`, importada no Secret `cert-manager/mkcert-ca`). O `Certificate dns-lan` emite `dns.lan` + `*.lan` no Secret `infra/dns-lan-tls`, referenciado pelo Ingress. Para o navegador aceitar sem aviso, instale a CA do mkcert no trust store de cada dispositivo (no host já está via `mkcert -install`).
- **Tailscale**: global nameserver = `192.168.1.20` e a rota `192.168.1.0/24` anunciada + aprovada — assim devices do tailnet resolvem `*.lan` via AdGuard e alcançam `192.168.1.20`. **IPv6 (RA) deve ficar desligado no roteador**: o anúncio de DNS IPv6 (`fc00::a/b`) é preferido pelo Android e interrompe a resolução de `*.lan`.

### Acesso remoto (fora da LAN, via Tailnet)

Funciona de qualquer lugar com Tailscale ligado: o DNS do tailnet (global nameserver `192.168.1.20`) resolve `*.lan` via AdGuard, e a rota de sub-rede `192.168.1.0/24` encaminha o tráfego até `192.168.1.20` (host) → Ingress → app. Ex.: `https://argocd.lan` fora de casa.

> **Gotcha (Termux):** o Termux usa o **próprio** `resolv.conf` (`$PREFIX/etc/resolv.conf`, aponta para `8.8.8.8`) — então `nslookup`/`curl` no Termux **não resolvem** `.lan`, mesmo com o navegador funcionando. Diagnóstico:
> - `nslookup argocd.lan 192.168.1.20` → consulta o AdGuard direto (funciona).
> - `nslookup argocd.lan 100.100.100.100` → MagicDNS do tailnet (funciona se o DNS do tailnet estiver aplicado no aparelho).
> Para testar acesso, use o **navegador** (usa o DNS do sistema).
- **Roteador (LAN)**: DHCP entrega `192.168.1.20` como DNS primário (fallback `1.1.1.1` opcional). Observação: com o host off, clientes com só o `192.168.1.20` perdem DNS.

### Headlamp (`headlamp.lan`)

Dashboard acessível em `https://headlamp.lan` (ingress roteia pelo Host; cert mkcert `headlamp.lan`). O basic-auth do HAProxy foi removido — o login é o **próprio login do Headlamp** (bearer token). RBAC: SA `headlamp-admin` (ns `headlamp`) com ClusterRole **`view`** (somente leitura).

Extrair o token persistente da Service Account para logar:

```bash
kubectl -n headlamp get secret headlamp-admin-token -o jsonpath='{.data.token}' | base64 -d
```

O secret `headlamp-admin-token` (tipo `kubernetes.io/service-account-token`) é long-lived (K8s 1.24+). Se o Headlamp rodar com `--in-cluster`, ele pode autenticar sozinho via token projetado — o comando acima serve quando o prompt pedir token.

### Argo CD (`argocd.lan`)

Acessível em `https://argocd.lan` (Ingress ns `argocd` → `argocd-server:80`, TLS mkcert `argocd.lan`). **Requer `--insecure` no `argocd-server`**: sem ele, o ingress (que termina TLS e encaminha HTTP ao backend) causa loop de redirect 307. O patch é reaplicado pelo `entrypoint.sh` após aplicar o `install.yaml` upstream (persistente entre reboots).

Login: usuário `admin`, senha:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```
> **Dica:** o login usa o usuário `admin` + a senha do secret acima (confere com o hash em `argocd-secret`/`admin.password`). Se o browser rejeitar, confira **autofill/cache** (digite a senha manualmente; hard refresh ou aba anônima) — não é a senha do headlamp/dns.

Manifestos do ingress/certificado: `manifests/apps/argocd/` (gitignored).

### Ceph Dashboard (`ceph.lan`)

Dashboard web do Ceph em `https://ceph.lan` (Ingress ns `ceph-dashboard` → `ceph-dashboard-svc` → `rook-ceph-mgr-dashboard:7000`). TLS usa cert mkcert **dedicado** `ceph-dashboard-tls` (emitido pelo `local-ca` para `ceph.lan`). O wildcard `*.lan` (`dns-lan-tls`) **não** é usado: os validadores rejeitam wildcard de label único como `*.lan` (`.lan` tratado como domínio apex), então cada app `.lan` tem seu próprio Certificate (mesmo padrão headlamp/argocd). O basic-auth do HAProxy foi removido; a autenticação é o **próprio login do dashboard do Ceph**.

Login: usuário `admin`, senha:
```bash
docker exec k8s-one kubectl --kubeconfig=/etc/kubernetes/admin.conf -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 -d
```

> **Nota:** a aba **Orchestrator** mostra "Orchestrator is not available: Module not found" — esperado. O módulo mgr `rook` está desabilitado (workaround de crash, ver Problemas Conhecidos).

Manifestos: `manifests/built-in/ceph/` (`06-dashboard-namespace.yaml`, `07-dashboard-service.yaml`, `08-dashboard-ingress.yaml`, `09-dashboard-certificate.yaml`), aplicados no boot pelo `entrypoint.sh`.

---

## Storage

### Rook-Ceph

O Ceph é implantado pelo Rook como cluster de nó único com **um OSD em loop device** (imagem sparse de 30G, `osd.img`) — nenhum disco do host é tocado.

- **Operador**: Rook v1.20.3 · **Ceph**: v20.2.2 (pinada — ver Problemas Conhecidos)
- **OSD**: 1 OSD bluestore em `/dev/loop0` ← `/var/lib/rook/osd.img` (persistido em `./data/rook/`)
- **Data path**: `/var/lib/rook` (bind mount)

| StorageClass | Provisioner | Access | Pool | Uso |
|---|---|---|---|---|
| `ceph-block` (**default**) | `rook-ceph.rbd.csi.ceph.com` | RWO | `replicapool` | Volumes block (RBD) |
| `cephfs` | `rook-ceph.cephfs.csi.ceph.com` | **RWX** | `cephfs-data0` | Volumes de filesystem compartilhado |

```bash
kubectl get sc
# NAME                 PROVISIONER                        RECLAIMPOLICY  VOLUMEBINDINGMODE
# ceph-block (default) rook-ceph.rbd.csi.ceph.com         Delete         Immediate
# cephfs               rook-ceph.cephfs.csi.ceph.com      Delete         Immediate
```

Replicação `size: 1` (nó único) — os dados **não são redundantes**; o OSD vive num loop file no disco do host. Faça backup de `data/rook/` se os dados importarem.

---

## Problemas Conhecidos

### Módulo mgr "rook" desabilitado (workaround)

- **Sintoma:** crash-loop do `ceph mgr` a cada ~15s: `NotImplementedError` em `node_proxy_fullreport` (crash dumps enchendo o data dir).
- **Causa:** Ceph v20.2.3 + Rook 1.20.3 — o módulo `prometheus` do mgr do Ceph chama `node_proxy_fullreport()`, que o módulo rook não implementa. Upstream: [rook/rook#18124](https://github.com/rook/rook/issues/18124) / [tracker 79106](https://tracker.ceph.com/issues/79106).
- **Estado atual:** o módulo mgr `rook` está **desabilitado** (`spec.mgr.modules[0].enabled: false` em `ceph/01-ceph-cluster.yaml`) — workaround recomendado pelos mantenedores. O operador Rook **não** depende do módulo; só a CLI `ceph orch`/integração com dashboard é perdida.
- **Reabilitar** quando o fix upstream ([ceph/ceph#70967](https://github.com/ceph/ceph/pull/70967)) for lançado.

---

## Customização

### Trocar o DNS upstream

Edite `manifests/built-in/coredns/04-configmap.yaml`, seção `forward`:

```
forward . 8.8.8.8 1.1.1.1 {
```

### Trocar o containerd runtime

Edite `configs/containerd-config.toml`:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = false   # true se o host usa systemd cgroups
```

### Trocar o tamanho do OSD

```bash
docker compose build --build-arg ROOK_OSD_SIZE=50G   # env var em runtime; afeta osd.img no primeiro boot
```

### Trocar o Pod CIDR

Altere em **dois lugares**:
1. `scripts/entrypoint.sh` → `CLUSTER_CIDR`
2. Comando de instalação do Cilium (entrypoint.sh → `cilium install --set ipam.operator.clusterPoolIPv4PodCIDRList=...`)
   Rebuild necessário.

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
- Cilium ainda não instalou o CNI → aguardar cilium-agent ficar Running
- Erro de mount propagation → verificar se `/sys` está montado rw

### PVC preso em ContainerCreating (`rbd image ... is still being used`)

Sintoma nos eventos do pod: `rbd image ... is still being used` ou `rbd-nbd: cookie mismatch`.

Causa: o StorageClass `ceph-block` usa `mounter: rbd-nbd`; mapeamentos `rbd-nbd` podem
sobreviver à recriação de pods/plugin e o healer do cephcsi não consegue reaproveitá-los.

**As ferramentas do repositório não cobrem esse caso de forma confiável.** Tanto o
`fix-rbd-stale.sh` quanto o `rbd-nbd-reaper.sh` decidem que um mapeamento é órfão
procurando um `volumeHandle` sem `VolumeAttachment` em `Attached=true`. Mas o
`VolumeAttachment` tem escopo de nó: ele sobrevive à substituição do pod que usava o
volume, permanecendo `Attached=true` por um volume que nenhum pod vivo está usando.
Reproduzir essa heurística contra o estado ao vivo durante um rollout afetado reporta
**zero órfãos**, com os mapeamentos obsoletos ali na frente. Não use `--all` como
contorno — ele desmapeia todos os dispositivos, inclusive os que servem pods rodando
(Prometheus, Grafana, authentik-postgresql).

O teste definitivo é se o dispositivo está **de fato montado**:

```bash
# dispositivo -> volumeHandle, e quantas vezes está montado (0 = órfão)
for d in /sys/block/nbd[0-9]*; do
  b=$(cat "$d/backend" 2>/dev/null); [ -z "$b" ] && continue
  n=$(basename "$d")
  echo "$n ${b##*-} mounts=$(docker exec k8s-one grep -c "/dev/$n " /proc/mounts)"
done

# a qual PV cada volumeHandle pertence
kubectl get pv -o go-template='{{range .items}}{{if .spec.csi}}{{.spec.csi.volumeHandle}} {{.metadata.name}}{{"\n"}}{{end}}{{end}}'
```

A numeração dos `nbd` não é cronológica e não significa nada — nunca deduza staleness
pelo número do dispositivo. Desmapeie apenas os que mostrarem `mounts=0`:

```bash
PLUGIN=rook-ceph.rbd.csi.ceph.com-nodeplugin-<hash>
kubectl -n rook-ceph exec $PLUGIN -c csi-rbdplugin -- rbd-nbd unmap /dev/nbdN
```

Isso apenas desanexa o block device — a imagem RBD e seu conteúdo não são tocados, e o
pod que aguardava assume o volume em segundos.

> O `rbd-nbd-reaper.sh` roda no boot e está **habilitado** nesta instalação
> (`RBD_REAPER_DRY_RUN=0` no `.env`). Ele compartilha a heurística de
> `VolumeAttachment` descrita acima, então trate-o como rede de segurança para sobras,
> não como cobertura para este modo de falha. O `fix-rbd-stale.sh` continua útil para o
> caso que a heurística dele de fato atende.

### Container/Docker travado no rebuild (`did not receive an exit event`)

Sintomas: `docker compose up -d` falha com `cannot stop container ... tried to kill
container, but did not receive an exit event`, e/ou o `dockerd` fica preso em
"Loading containers". Causa: o `rbd-nbd` do Ceph CSI usa `--io-timeout=0` (sem
timeout); se o container for terminado com I/O pendente, o `systemd-udevd` fica em
D-state num nbd morto e o container não finaliza.

Recuperação (no host, com `sudo`):

```bash
# 1. Parar o Docker (se travar: sudo systemctl kill -s SIGKILL docker)
sudo systemctl stop docker.socket docker

# 2. Remover a task presa no containerd
sudo ctr -n moby tasks list          # anote o ID (STATUS RUNNING/STOPPED)
sudo ctr -n moby tasks rm <ID>
sudo ctr -n moby containers rm <ID>

# 3. Desconectar os nbd mortos
sudo scripts/fix-nbd-stuck.sh --apply --yes

# 4. Subir o Docker e recriar o cluster
sudo systemctl start docker
docker compose up -d
```

O `rbd-nbd-reaper.sh` previne a maioria dos casos; o procedimento acima é o
último recurso quando o container não morre.

### CoreDNS CrashLoopBackOff

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns
```

Causas comuns:
- Loop detection → já resolvido com forward para 8.8.8.8
- Corefile syntax error → verificar `manifests/built-in/coredns/04-configmap.yaml`

### OSD não criado após reboot (0 OSDs)

```bash
docker exec k8s-one losetup -a          # deve mostrar /dev/loop0 ← /var/lib/rook/osd.img
docker exec k8s-one kubectl --kubeconfig=/etc/kubernetes/admin.conf -n rook-ceph get pod -l app=rook-ceph-osd
```

Causas comuns:
- Loop device não attachado → `losetup /dev/loop0 /var/lib/rook/osd.img` e depois deletar o job `rook-ceph-osd-prepare` + reiniciar o operator
- `ROOK_CEPH_ALLOW_LOOP_DEVICES` diferente de `true` → verificar configmap `rook-ceph-operator-config`

### Node NotReady

```bash
kubectl describe node k8s-one
```

Causas comuns:
- CNI não instalado → Cilium ainda inicializando
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
docker compose down -v   # remove container + volumes nomeados (bind mounts ./data/ e ./data/rook/ são mantidos)
docker compose up -d     # fresh start
# Para apagar também os dados do cluster: rm -rf data/* data/rook/*  (irreversível!)
```

---

## Requisitos

### Host

| Requisito | Mínimo | Recomendado |
|---|---|---|
| **Docker** | 24.0+ | 27.0+ |
| **Docker Compose** | v2.20+ | v2.30+ |
| **RAM** | 16 GB | 24 GB |
| **CPU** | 2 cores | 4 cores |
| **Disco** | 10 GB (imagem + OSD sparse 30G) | 20 GB+ |
| **OS** | Linux (kernel 5.10+) | Linux (kernel 6.x) |
| **Arch** | amd64 | amd64 |

> Os valores de RAM decorrem das reservas do kubelet, não do consumo do cluster:
> `systemReserved` (12Gi) + `kubeReserved` (2Gi) + `evictionHard` (1Gi) são subtraídos
> da capacidade do *host* antes de qualquer pod. Um host de 16 GB deixa ~1 GiB para
> pods; 24 GB deixam ~9 GiB. Veja
> [Reservas de Recursos](#reservas-de-recursos-kubelet) para a conta completa.

### Portas

| Porta | Protocolo | Uso |
|---|---|---|
| `6443` | TCP | Kubernetes API Server |
| `8082` | TCP | HAProxy Ingress HTTP (→ NodePort 30080) |
| `8443` | TCP | HAProxy Ingress HTTPS (→ NodePort 30443) |

---

## Limitações

- **Não é HA**: nó único, sem redundância. etcd, apiserver, etc. são single-instance.
- **Não para produção**: destinado a desenvolvimento, testes, CI/CD, laboratório.
- **Storage sem redundância**: replicação Ceph `size: 1`, OSD único em loop file.
- **Privileged mode**: o container roda com `--privileged` (necessário para kubelet/containerd + loop devices).
- **Apenas amd64**: arm64 pode funcionar com `--build-arg TARGETARCH=arm64` mas não foi testado.
- **Sem systemd**: usa `cgroupfs` como cgroup driver (sem systemd dentro do container).
- **Cert rotation**: desabilitada. Certificados duram 10 anos. Para clusters de longa duração, considere implementar rotação.

---

## Licença

MIT
