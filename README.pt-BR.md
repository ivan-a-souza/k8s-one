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
│  Storage: local-path-provisioner (hostPath)      │
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
- [kt-connect (ktctl)](#kt-connect-ktctl)
- [Exemplos de Uso](#exemplos-de-uso)
- [Estrutura do Projeto](#estrutura-do-projeto)
- [Sequência de Inicialização](#sequência-de-inicialização)
- [PKI e Certificados](#pki-e-certificados)
- [Networking](#networking)
- [Workloads](#workloads)
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
local-path-storage   local-path-provisioner-...                   1/1     Running
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
| **local-path-provisioner** | v0.0.30 | github.com/rancher/local-path-provisioner | Provisionamento dinâmico via hostPath (StorageClass default) |
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
│  • Descartado no build final        │
└──────────────┬──────────────────────┘
               │ COPY binários
               ▼
┌─────────────────────────────────────┐
│  Stage 2: Runtime (debian:bookworm) │
│                                     │
│  • bash, openssl, iptables          │
│  • socat, conntrack                 │
│  • apt/dpkg removidos no build      │
│  • = imagem mínima, sem pkg manager │
└─────────────────────────────────────┘
```

A imagem final **não possui package manager** — `apt`/`dpkg` são removidos após instalar as dependências de runtime, reduzindo a superfície de ataque.

### Processo de Inicialização

O `entrypoint.sh` orquestra os processos do control-plane e a aplicação dos manifests:

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
└── apply_manifests() [background]
    ├── taint removal (permite workloads)
    ├── cilium install (CNI, reinstalação limpa a cada boot)
    ├── aguarda Node Ready
    ├── kubectl apply -f coredns/
    ├── kubectl apply -k local-path/ (provisioner + StorageClass default)
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
| `./data/local-path/` | `/opt/local-path-provisioner` | Volumes provisionados pela StorageClass `local-path` |

Além dos bind mounts, o container monta paths do sistema host:

| Host Path | Container Path | Modo | Motivo |
|---|---|---|---|
| `/sys` | `/sys` | `rw` | Cilium BPF, cgroups |
| `/lib/modules` | `/lib/modules` | `ro` | Módulos do kernel (iptables, etc.) |

> ⚠️ `./data/` contém segredos do cluster (chaves privadas da PKI, kubeconfigs) e, junto com `./data/local-path/`, todos os dados dos volumes. Ambos estão **gitignored** — nunca commitar.

### Limpar tudo

```bash
docker compose down -v   # remove container + volumes nomeados (bind mounts em ./data/ e ./data/local-path/ são mantidos)
# Para apagar totalmente os dados do cluster: rm -rf data/* data/local-path/*   (irreversível!)
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
| `TARGETARCH` | `amd64` | Arquitetura alvo |

### Variáveis de Ambiente (runtime)

| Variável | Default | Descrição |
|---|---|---|
| `NODE_NAME` | `k8s-one` | Nome do nó no cluster |
| `ARGOCD_VERSION` | `v3.5.1` | Versão do Argo CD instalada no boot (formato: `vX.Y.Z`) |

Defina `ARGOCD_VERSION` no arquivo `.env` da raiz. Depois de alterar a versão,
recrie o container para que ela seja aplicada durante a inicialização:

```bash
docker compose up -d --force-recreate
```

### Parâmetros de Rede (entrypoint.sh)

| Parâmetro | Valor | Descrição |
|---|---|---|
| `CLUSTER_CIDR` | `192.168.0.0/16` | CIDR dos pods (precisa conter o podCIDR alocado aos nós; vai para o IPAM do Cilium e é disjunto do `SERVICE_CIDR`) |
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
um chart pode injetar sidecars próprios (proxies de service mesh, exporters, coletores
de log) que somam requests no pod sem nunca aparecer nos valores que você escreveu.

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
| `authentik-postgresql-auth` | `platform` + `data` | `manifests/argocd/authentik/secrets/postgresql-auth.yaml` | role `authentik` no PostgreSQL (script de init, `data`) |
| `grafana-admin` | `monitoring` | `manifests/argocd/prometheus-stack/secrets/grafana-admin.yaml` | `grafana.admin.existingSecret` |
| `grafana-oidc` | `monitoring` | `manifests/argocd/prometheus-stack/secrets/grafana-oidc.env` | `grafana.envFromSecret` (env `GF_AUTH_GENERIC_OAUTH_*`) |
| `litellm-env` | `platform` | `manifests/argocd/litellm/secrets/litellm.env` | `litellm.environmentSecrets` |
| `litellm-db` | `platform` + `data` | `manifests/argocd/litellm/secrets/litellm-db.yaml` | `litellm.db.secret` + init do PostgreSQL (`data`) |
| `litellm-masterkey` | `platform` | `manifests/argocd/litellm/secrets/litellm-masterkey.yaml` | `litellm.masterkeySecretName` |
| `mkcert-ca` | `cert-manager` | `manifests/built-in/cert-manager/secrets/mkcert-ca.yaml` | CA raiz do ClusterIssuer `local-ca` |
| `postgres-superuser` | `data` | `manifests/argocd/postgres/secrets/postgres-superuser.yaml` | superusuário do PostgreSQL (`POSTGRES_PASSWORD`) |
| `headlamp-oidc` | `ops` | `manifests/ops/headlamp/secrets/headlamp-oidc.env` | client OIDC do Headlamp (`HEADLAMP_CONFIG_OIDC_*`) |
| `oauth2-proxy` | `ops` | `manifests/ops/headlamp/secrets/oauth2-proxy.env` | client OIDC do oauth2-proxy + `cookie_secret` |
| `odoo-db` | `odoo` + `data` | `manifests/argocd/odoo/secrets/odoo-db.yaml` | role `odoo` no PostgreSQL |
| `redis-auth` | `data` | `manifests/argocd/redis/secrets/redis-auth.yaml` | `requirepass` do Redis |
| `pgadmin-credentials` | `data` | `manifests/argocd/pgadmin/secrets/pgadmin-credentials.yaml` | login inicial (interno) do pgAdmin |
| `pgadmin-oidc` | `data` | `manifests/argocd/pgadmin/secrets/pgadmin-oidc.env` | client OIDC do pgAdmin (`PGADMIN_OIDC_*`), lido via `secretKeyRef` |
| `argocd-oidc` | `argocd` | `manifests/ops/argocd/secrets/argocd-oidc.env` | client OIDC do Argo CD (`ARGOCD_OIDC_*`); referenciado por `$argocd-oidc:ARGOCD_OIDC_CLIENT_SECRET` |
| `vaultwarden-env` | `vaultwarden` | `manifests/argocd/vaultwarden/secrets/vaultwarden.env` | env do Vaultwarden (`ADMIN_TOKEN`, `DOMAIN`, …) |

Formatos:
- `*.env` → criado com `kubectl create secret generic --from-env-file` (ex.: `authentik.env`).
- `*.yaml` → manifest `kind: Secret` (com `stringData`) aplicado com `kubectl apply -f`.

> **Uma credencial, dois namespaces.** Secret é namespaced, e o banco vive em `data` enquanto os consumidores vivem em `platform` — por isso o `create-secrets.sh` aplica `litellm-db.yaml` e `postgresql-auth.yaml` nos **dois** namespaces (`apply_yaml_secret_in_ns`, que reescreve o campo `namespace:` do manifesto na hora). O arquivo-fonte continua sendo a verdade única: rotacione a senha num lugar só, nunca num namespace só.

> **Uma credencial, dois secrets.** O `authentik-config` também carrega as credenciais OIDC com que o LiteLLM se autentica (`LITELLM_OIDC_CLIENT_ID` / `LITELLM_OIDC_CLIENT_SECRET`) — precisam ter os **mesmos valores** que `GENERIC_CLIENT_ID` / `GENERIC_CLIENT_SECRET` no `litellm-env`. Quem registra o client (o blueprint) e quem o apresenta (o proxy) são apps diferentes, então o par existe dos dois lados: rotacione um, rotacione os dois.

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
  reiniciar o workload. Para uma role de aplicação no PostgreSQL compartilhado a
  senha é gravada no banco na inicialização: além do Secret, rode `ALTER USER` no
  banco (o script de init só cria role que ainda não existe).
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

## kt-connect (ktctl)

O [kt-connect](https://github.com/alibaba/kt-connect) liga a máquina local à
rede do cluster sem expor nada na LAN: o `ktctl` cria um *shadow pod*
temporário (`kt-connect-shadow`) no namespace alvo e monta o túnel por
**port-forward da API**. Serve para acessar ClusterIPs/Pod IPs a partir do host,
redirecionar o tráfego de um Service para um processo local (`exchange`/`mesh`) e
expor um serviço local no cluster (`preview`/`forward`).

Nada é instalado permanentemente no cluster: o RBAC dedicado vive em
`manifests/ops/kt-connect/` (namespace `kt-connect`, ServiceAccount + ClusterRole
escopados ao que o ktctl usa — **não é cluster-admin**) e é aplicado junto do
domínio `ops`:

```bash
scripts/deploy-apps.sh ops
```

### Cliente (neste host)

```bash
curl -OL https://github.com/alibaba/kt-connect/releases/download/v0.3.7/ktctl_0.3.7_Linux_x86_64.tar.gz
tar zxf ktctl_0.3.7_Linux_x86_64.tar.gz
sudo mv ktctl /usr/local/bin/ && ktctl --version
```

### kubeconfig da ServiceAccount

O ktctl não usa o `admin.conf`: usa um kubeconfig da SA `kt-connect`. Gere com:

```bash
scripts/kt-connect-kubeconfig.sh
export KUBECONFIG=$PWD/kubeconfig.kt-connect
```

O script aplica o RBAC, espera o controller popular o token do Secret
`kt-connect-token` (token de longa duração — o k8s 1.24+ não cria mais o Secret
sozinho) e escreve `kubeconfig.kt-connect` com server/CA do cluster + token da
SA. É gitignored.

### Uso

O wrapper `scripts/kt.sh` fixa o kubeconfig, a imagem do shadow e o DNS em modo
`hosts` (escreve só no `/etc/hosts`, sem tocar no `/etc/resolv.conf` do host).
Para `connect`, o shadow nasce no namespace `kt-connect`:

```bash
sudo scripts/kt.sh connect                     # root; acessa ClusterIP/Pod IP do host
scripts/kt.sh preview minha-api --expose 8080 -n apps
scripts/kt.sh forward minha-api 6060:8080 -n apps
scripts/kt.sh exchange minha-api --expose 8080 -n apps
scripts/kt.sh mesh minha-api --expose 8080 -n apps
scripts/kt.sh clean
```

> `connect` exige root (`/dev/net/tun` + alteração de rotas); `preview`,
> `forward`, `exchange` e `mesh` não.
>
> O ktctl **não segue o namespace do contexto do kubeconfig**: o flag
> `--namespace` tem default `default` e é ele que decide onde o shadow/Service
> nasce. Para `exchange`/`mesh` é o namespace do serviço alvo; para `preview` é
> onde o serviço local é publicado. O wrapper só fixa `-n kt-connect` no
> `connect`; os demais aceitam `-n <ns>`.

### Expor uma aplicação local no cluster (dev com live-reload)

Alternativa a rodar a app num pod com `hostPath` — que neste cluster apontaria
para dentro do **container do nó**, não para o host — é **rodar a app na sua
máquina e publicá-la no cluster** via kt-connect. O código fica onde o
live-reload funciona: nenhum volume, nenhum PV, nada montado do host.

```bash
# 1) rode a app local com live-reload (ex.: tsx watch index.ts) na porta 3000

# 2) dê à app acesso aos serviços do cluster (postgres/redis/opensearch do ns data):
#    o host passa a resolver *.data.svc.cluster.local e rotear os ClusterIPs
sudo scripts/kt.sh connect --dnsMode hosts:data

# 3) publique a app local no cluster como um Service
scripts/kt.sh preview minha-api --expose 3000 -n minha-ns
```

- `preview` cria o Service `minha-api` no namespace alvo apontando para a porta
  local (3000). Quem está no cluster alcança por `minha-api.minha-ns.svc`; para
  expor por hostname, aponte um Ingress para esse Service.
- Já existe um Service no cluster e você quer **desviar** o tráfego para o local?
  `scripts/kt.sh exchange <svc> --expose 3000 -n <ns>` (todo o tráfego) ou
  `scripts/kt.sh mesh <svc> --expose 3000 -n <ns>` (só requisições com o header
  que o comando imprime).
- Editar o código dispara o live-reload local e o cluster já vê a nova versão
  (o Service encaminha para o processo local). `Ctrl-C` remove o Service e o
  shadow pod; `scripts/kt.sh clean` limpa resíduos.
- A app roda **na sua máquina** (precisa estar ligada); o cluster só roteia.
  Envs como `DB_HOST=postgres.data.svc.cluster.local` funcionam graças ao passo 2.

### Notas

- **Imagem**: o default é
  `registry.cn-hangzhou.aliyuncs.com/rdc-incubator/kt-connect-shadow:v0.3.7`
  (não existe no ghcr/Docker Hub). Sobrescreva com `KT_SHADOW_IMAGE=...`.
- **Rotas**: o `connect` deriva o CIDR dos IPs reais. Alguns pods usam
  `hostNetwork` (cilium, cilium-envoy, cilium-operator, adguard) e reportam o IP
  do nó (`192.168.32.2`) como podIP — com isso o range de pods computado vira
  `192.168.0.0/16` e engoliria a rede docker. O wrapper já passa
  `--excludeIps 192.168.32.0/20` (ajustável em `KT_EXCLUDE_IPS`), e o IP da API é
  excluído automaticamente. A LAN (`192.168.1.0/24`) tem rota mais específica e
  não é afetada. Se a rede local usar `192.168.0.x`, ajuste `KT_EXCLUDE_IPS`.
- **Nomes vs IPs**: o roteamento cobre todo o cluster por IP/ClusterIP. A
  resolução de nomes via `/etc/hosts` (`--dnsMode hosts`) é limitada ao
  `--namespace`; para resolver outros namespaces, passe
  `--dnsMode hosts:default,apps,data,platform,ops,argocd,monitoring,networking`.
- **Compatibilidade**: kt-connect v0.3.7 é de 2022; no k8s 1.36 `connect`,
  `forward` e `preview` funcionam, mas `exchange`/`mesh` devem ser validados na
  prática.
- O shadow pod e o ConfigMap são removidos ao encerrar o comando (`Ctrl-C`);
  `ktctl clean` limpa resíduos de execuções interrompidas.

---

## Exemplos de Uso

### Deploy de um Pod simples

```bash
kubectl run nginx --image=nginx:alpine --port=80
kubectl get pods -w
```

### PVC com local-path (ReadWriteOnce)

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

### Volumes compartilhados (ReadWriteMany)

O `local-path` provisiona diretórios hostPath locais do nó, então um PVC é
**ReadWriteOnce** apenas. Não há filesystem de cluster para `ReadWriteMany` — use
um mecanismo em nível de aplicação (object storage, NFS ou um banco) para dados
compartilhados.

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
│   ├── deploy-apps.sh                  # Aplica kustomize sob demanda (manifests/<domínio>)
│   ├── create-secrets.sh               # Cria/atualiza Secrets a partir de manifests/**/secrets/
│   ├── kt-connect-kubeconfig.sh        # Gera o kubeconfig da SA usada pelo ktctl
│   └── kt.sh                           # Wrapper do ktctl (kt-connect)
│
├── configs/
│   └── containerd-config.toml          # containerd: runc + cgroupfs + overlayfs
│
└── manifests/                          # Montado ro no container (só manifests/apps/ é gitignored)
    ├── built-in/                       # Núcleo: aplicado pelo entrypoint.sh no boot
    │   ├── argocd/                     # Namespace do Argo CD
    │   ├── cert-manager/               # Certificados internos *.lan (CA mkcert)
    │   ├── coredns/                    # CoreDNS + bloco hosts .lan
    │   ├── haproxy-ingress/            # HAProxy Ingress Controller
    │   ├── local-path/                 # local-path-provisioner + StorageClass default
    │   ├── metallb/                    # MetalLB L2 (VIP do LoadBalancer)
    │   └── metrics-server/             # API metrics.k8s.io
    ├── argocd/                         # Applications do Argo CD (uma pasta por app)
    │   ├── authentik/                  # chart Helm + blueprint + secrets/
    │   ├── litellm/                    # chart OCI + secrets/
    │   ├── odoo/                       # Application (source: este repo)
    │   ├── opensearch/                 # Application (source: este repo)
    │   ├── pgadmin/                    # Application (source: este repo)
    │   ├── postgres/                   # Application (source: este repo)
    │   ├── prometheus-stack/           # chart Helm + ingress/cert
    │   ├── redis/                      # Application (source: este repo)
    │   └── vaultwarden/                # Application (source: este repo)
    ├── networking/
    │   └── adguard/                    # AdGuard Home (DNS da LAN/tailnet)
    ├── ops/
    │   ├── argocd/                     # Ingress + Certificate do argocd.lan (versionado)
    │   ├── headlamp/                   # Dashboard, oauth2-proxy, ingress/cert
    │   │   └── plugin-logout/          # Plugin "Sair" próprio (ConfigMap)
    │   └── kt-connect/                 # RBAC do ktctl (SA + ClusterRole + token)
    ├── odoo/                           # Odoo (manifestos próprios — fonte da Application)
    ├── opensearch/                     # OpenSearch + Dashboards (manifestos próprios)
    ├── pgadmin/                        # pgAdmin 4 (manifestos próprios)
    ├── postgres/                       # PostgreSQL 18 compartilhado (manifestos próprios)
    ├── redis/                          # Redis (manifestos próprios)
    ├── vaultwarden/                    # Vaultwarden (manifestos próprios)
    └── apps/                           # GITIGNORED — sob demanda via deploy-apps.sh
        └── tileserver/                 # TileServer GL (PVC hostpath-tiles)
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
10s   ▶ cilium install (reinstalação limpa a cada boot)
35s   ▶ Node Ready ✓
40s   ▶ CoreDNS, local-path-provisioner, HAProxy aplicados
```

> Em restarts subsequentes (imagens já em cache), o boot cai para ~1-2 min. Os dados dos volumes sobrevivem via `data/local-path/`.

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
- **Pod CIDR**: `192.168.0.0/16` (definido explicitamente via `ipam.operator.clusterPoolIPv4PodCIDRList`; precisa conter os podCIDRs dos nós e ser disjunto do `SERVICE_CIDR`)
- **Network Policy**: ✅ suportado (CiliumNetworkPolicy + k8s NetworkPolicy)
- **IPAM**: cluster-pool (padrão)
- **kube-proxy replacement**: desabilitado (kube-proxy roda junto)
- **Hubble**: ✅ observabilidade & monitoramento

O Cilium é instalado via Cilium CLI, que gerencia o Helm chart e fornece monitoramento de status. O entrypoint o reinstala a **cada boot**: o check `cilium_healthy()` roda `cilium status --brief`, flag que não existe no CLI v0.19.4, então o check sempre falha e força uma reinstalação limpa. Essa reinstalação é load-bearing — depois que o container `k8s-one` é recriado, o datapath pod→ClusterIP fica obsoleto e só reinstalar o Cilium o restaura.

### kube-proxy

- **Modo**: iptables
- **Service CIDR**: `10.96.0.0/12`

### CoreDNS

- **ClusterIP**: `10.96.0.10`
- **Forward**: `8.8.8.8`, `1.1.1.1` (Google DNS, Cloudflare)
- **Domínio**: `cluster.local`
- **Nomes `.lan`**: resolvidos dentro do cluster por um bloco `hosts` apontando para o VIP do MetalLB (`192.168.1.200`)

O bloco `hosts` existe porque o `forward` acima vai direto para resolvedores públicos, que não conhecem `.lan` (TLD privado que só o AdGuard serve) — sem ele nenhum pod alcança `authentik.lan`, `grafana.lan` etc. **pelo nome**, só por ClusterIP. O IP é o **VIP do MetalLB** (o service LoadBalancer do `haproxy-kubernetes-ingress`), e **não** o `192.168.1.20` dos rewrites do AdGuard: `.20` é o IP da LAN do host e não é alcançável de dentro do cluster (dá timeout). O VIP é alcançável, e roteia por Host header com os certificados mkcert.

É uma lista explícita, não um curinga: o plugin `hosts` só ganhou suporte a wildcard no **`master`** do CoreDNS — nenhum release tem (este cluster roda v1.12.0), então `*.lan` ali viraria um nome literal que nunca casa, silenciosamente. A alternativa (`template`) funcionaria, mas faria *todo* `*.lan` responder o VIP, incluindo `router.lan` (que o AdGuard aponta para `192.168.1.1`), sem como abrir exceção (Go/RE2 não tem lookahead). Serviço `.lan` novo = uma palavra a mais nessa linha, em `manifests/built-in/coredns/04-configmap.yaml`. O plugin `reload` pega a mudança em ~30 s, sem restart.

### DNS Local (AdGuard) & Certificados Internos

O **AdGuard Home** (`networking/adguard`) é o DNS da LAN/tailnet e resolve os domínios internos `*.lan` apontando para o cluster. O CoreDNS continua responsável por `cluster.local` (DNS interno do cluster) — o AdGuard é para acesso das aplicações por nome.

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
- **Certificados (cert-manager + mkcert)**: o `ClusterIssuer local-ca` usa a **CA raiz do mkcert** (`~/.local/share/mkcert/rootCA.pem`, importada no Secret `cert-manager/mkcert-ca`). O `Certificate dns-lan` emite `dns.lan` + `*.lan` no Secret `networking/dns-lan-tls`, referenciado pelo Ingress. Para o navegador aceitar sem aviso, instale a CA do mkcert no trust store de cada dispositivo (no host já está via `mkcert -install`).
- **Tailscale**: global nameserver = `192.168.1.20` e a rota `192.168.1.0/24` anunciada + aprovada — assim devices do tailnet resolvem `*.lan` via AdGuard e alcançam `192.168.1.20`. **IPv6 (RA) deve ficar desligado no roteador**: o anúncio de DNS IPv6 (`fc00::a/b`) é preferido pelo Android e interrompe a resolução de `*.lan`.

### Acesso remoto (fora da LAN, via Tailnet)

Funciona de qualquer lugar com Tailscale ligado: o DNS do tailnet (global nameserver `192.168.1.20`) resolve `*.lan` via AdGuard, e a rota de sub-rede `192.168.1.0/24` encaminha o tráfego até `192.168.1.20` (host) → Ingress → app. Ex.: `https://argocd.lan` fora de casa.

> **Gotcha (Termux):** o Termux usa o **próprio** `resolv.conf` (`$PREFIX/etc/resolv.conf`, aponta para `8.8.8.8`) — então `nslookup`/`curl` no Termux **não resolvem** `.lan`, mesmo com o navegador funcionando. Diagnóstico:
> - `nslookup argocd.lan 192.168.1.20` → consulta o AdGuard direto (funciona).
> - `nslookup argocd.lan 100.100.100.100` → MagicDNS do tailnet (funciona se o DNS do tailnet estiver aplicado no aparelho).
> Para testar acesso, use o **navegador** (usa o DNS do sistema).
- **Roteador (LAN)**: DHCP entrega `192.168.1.20` como DNS primário (fallback `1.1.1.1` opcional). Observação: com o host off, clientes com só o `192.168.1.20` perdem DNS.

## Workloads

### Visão geral

As cargas são entregues de duas formas:

- **Applications do Argo CD** — o padrão: nove Applications, cada uma apontando para um chart Helm (de terceiros ou OCI) ou para um caminho deste repositório. Os manifestos das Applications ficam em `manifests/argocd/<app>/`.
- **`scripts/deploy-apps.sh`** — kustomize, sob demanda: aplica as árvores de domínio em `manifests/` do AdGuard (**networking**), do Headlamp e do Ingress do Argo CD (**ops**) e do TileServer (**apps**).

| Application | Fonte |
|---|---|
| `authentik` | chart Helm `authentik` (`goauthentik`) |
| `kube-prometheus-stack` | chart Helm `kube-prometheus-stack` (`prometheus-community`) |
| `litellm` | chart Helm OCI `ghcr.io/berriai/litellm-helm` |
| `odoo` | este repo — `manifests/odoo` |
| `opensearch` | este repo — `manifests/opensearch` |
| `pgadmin` | este repo — `manifests/pgadmin` |
| `postgres` | este repo — `manifests/postgres` |
| `redis` | este repo — `manifests/redis` |
| `vaultwarden` | este repo — `manifests/vaultwarden` |

### Argo CD (`argocd.lan`)

Acessível em `https://argocd.lan` (Ingress ns `argocd` → `argocd-server:80`, TLS mkcert `argocd.lan`). **Requer `--insecure` no `argocd-server`**: sem ele, o ingress (que termina TLS e encaminha HTTP ao backend) causa loop de redirect 307. O patch é reaplicado pelo `entrypoint.sh` após aplicar o `install.yaml` upstream (persistente entre reboots).

Login: usuário `admin`, senha:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```
> **Dica:** o login usa o usuário `admin` + a senha do secret acima (confere com o hash em `argocd-secret`/`admin.password`). Se o browser rejeitar, confira **autofill/cache** (digite a senha manualmente; hard refresh ou aba anônima) — não é a senha do headlamp/dns.

Manifestos do ingress/certificado: `manifests/ops/argocd/` (versionado neste repo).

**SSO pelo Authentik** (provider `Argo CD`, blueprint `argocd-oidc.yaml`). O Argo CD fala OIDC **nativamente** (`oidc.config` no `argocd-cm`) — não usa o Dex nem proxy:

- Acesso pelo grupo **`argocd-admins`** (binding da Application) → `role:admin`, via `argocd-rbac-cm` (`g, argocd-admins, role:admin`, `scopes: '[groups]'`).
- **Config aplicada pelo entrypoint:** o Argo CD é instalado do `install.yaml` upstream a cada boot, que recria o `argocd-cm`, então `scripts/entrypoint.sh` reaplica dois merge patches — `manifests/built-in/argocd/oidc-patch.yaml` (`url`, `issuer`, `clientID`, `rootCA` do mkcert e `requestedIDTokenClaims: groups`) e `rbac-patch.yaml`. **Não** é gerido por uma Application do próprio Argo.
- O `clientSecret` **não fica no patch**: referencia o Secret `argocd-oidc` via `$argocd-oidc:ARGOCD_OIDC_CLIENT_SECRET` — por isso o Secret leva o label `app.kubernetes.io/part-of: argocd` (senão a referência é ignorada). Os valores `ARGOCD_OIDC_*` são os mesmos do `authentik.env` (uma credencial, dois secrets).
- O RBAC lê o claim **`groups`** do id_token (o provider do Authentik usa `include_claims_in_id_token: true`). Redirect registrado: `https://argocd.lan/auth/callback`. O logout encerra a sessão no Authentik (`logoutURL` → end-session).
- O login local `admin` (senha do `argocd-initial-admin-secret`) continua como **emergência**.

### Headlamp (`headlamp.lan`)

Dashboard em `https://headlamp.lan` (ingress roteia pelo Host; cert mkcert `headlamp.lan`). O login é **SSO pelo Authentik**, feito por um **oauth2-proxy** na frente do Headlamp.

**Arquitetura (por que o proxy):** o Headlamp tem dois modos de OIDC, mutuamente exclusivos:
- **OIDC nativo**: exige login e encaminha o token do usuário para a API. Como o `kube-apiserver` deste cluster **não** tem flags `--oidc-*`, a API rejeita o token (401, "the cluster did not accept your sign-in").
- **Service account** (`HEADLAMP_CONFIG_UNSAFE_USE_SERVICE_ACCOUNT_TOKEN=true`): autentica todos pelo SA, mas **não exige login** — só é seguro atrás de um auth proxy.

Escolhemos o 2º + um proxy: `navegador → ingress → oauth2-proxy → Headlamp`. O `oauth2-proxy` (ns `ops`, `09-oauth2-proxy.yaml`) faz o OIDC contra o Authentik (provider "Headlamp", redirect `https://headlamp.lan/oauth2/callback`) e guarda a sessão num cookie; o ingress aponta para ele, não para o Headlamp. Sem sessão válida, nada chega ao Headlamp.

RBAC: SA `headlamp-admin` (ns `ops`) → ClusterRole **`headlamp-admin`** — admin amplo, mas **sem `delete` em namespaces, PVs e PVCs** (guarda-corpo de dados; ver `03-cluster-role.yaml`). O login controla quem entra; a permissão na API é a do SA (admin compartilhado).

Env relevante do Headlamp (`05-deployment.yaml`): `HEADLAMP_CONFIG_UNSAFE_USE_SERVICE_ACCOUNT_TOKEN=true` + `HEADLAMP_CONFIG_PROXY_AUTH=true` (confia nos headers `X-Forwarded-*` do proxy). O client_id/secret é o mesmo par `HEADLAMP_OIDC_*` do blueprint, guardado no Secret gitignored `oauth2-proxy` (`create-secrets.sh`), junto do `cookie_secret`.

> Alternativa per-user (não usada): configurar OIDC no próprio `kube-apiserver` (`--oidc-*`) + RBAC por identidade — muda o modelo para per-user e exige rebuild/recreate do container.

**Logout ("Sair"):** o Headlamp não tem logout no servidor (o botão nativo só limpa o token local, e a sessão real é o cookie `_oauth2_proxy`). Por isso há um **plugin próprio** (`plugin-logout/`, montado em `/headlamp/static-plugins/logout` via ConfigMap) que adiciona um botão **Sair** no app bar. Ele vai para `/oauth2/sign_out?rd=<end-session do Authentik>`: limpa o cookie do proxy **e** encerra a sessão SSO no Authentik, voltando para o login. O plugin é escrito à mão em UMD (o Headlamp injeta os módulos em `window.pluginLib`), sem toolchain/npm.

Fallback por token (quando o prompt pede token):

```bash
kubectl -n ops get secret headlamp-admin-token -o jsonpath='{.data.token}' | base64 -d
```

O secret `headlamp-admin-token` (tipo `kubernetes.io/service-account-token`) é long-lived (K8s 1.24+). Como o Headlamp roda com `--in-cluster`, ele pode autenticar sozinho via token projetado — o comando acima serve quando o prompt pedir token.

### Authentik (`authentik.lan`)

Provedor de identidade em `https://authentik.lan` (chart `authentik` 2026.8.1, ns `platform`, cert mkcert `authentik-tls`). O banco é o **PostgreSQL 18 compartilhado do namespace `data`** (ver [PostgreSQL (data)](#postgresql-data) abaixo) — banco `authentik`, dono a role `authentik` — por isso o `postgresql:` embutido do chart está `enabled: false` e a conexão vem inteira do Secret `authentik-config` (`AUTHENTIK_POSTGRESQL__*`, entregue ao server e ao worker por `envFrom`). Está aqui para ser o **login único** dos apps do cluster; ligados nele até agora: LiteLLM, Headlamp, Grafana, pgAdmin e Argo CD.

Grupos, providers e applications são **declarativos**, via um blueprint que o chart monta no worker:

```bash
kubectl apply -f manifests/argocd/authentik/03-blueprint.yaml    # o ConfigMap do blueprint
kubectl apply -f manifests/argocd/authentik/02-application.yaml  # depois deixa o Argo CD sincronizar o chart
```

- `manifests/argocd/authentik/03-blueprint.yaml` é um ConfigMap com **cinco** blueprints, um por app: `litellm-oidc.yaml` (grupo `litellm-users`, provider OAuth2 `LiteLLM`, application e bindings), `headlamp-oidc.yaml` (idem, para o Headlamp — lá com o oauth2-proxy fazendo o fluxo), `grafana-oidc.yaml` (idem, para o Grafana, que fala OIDC nativamente), `pgadmin-oidc.yaml` (idem, para o pgAdmin, também OIDC nativo) e `argocd-oidc.yaml` (idem, para o Argo CD — grupo `argocd-admins` → `role:admin`).
- **Entrar e poder mexer são duas perguntas, com duas peças.** `litellm-users` + o binding da Application respondem *quem entra*; o *que pode fazer dentro* vem de um claim, não do grupo. Por isso o blueprint cria também o grupo `litellm-admins` (com binding próprio — sem ele um admin do LiteLLM seria admin de um app onde não consegue entrar) e um scope mapping `LiteLLM Role` (`scope_name: litellm_role`) que devolve `proxy_admin` para quem está nele e `internal_user_viewer` para o resto. O claim só chega no token se o scope estiver em `property_mappings` do provider **e** o client pedir no `scope=` do `/authorize` — o `/authorize` faz a **interseção** dos dois, então faltando um dos lados o claim não sai e não há erro nenhum (do lado do LiteLLM é a variável `GENERIC_SCOPE`; ver a seção dele abaixo).
- É aplicado com **`kubectl`, nunca pelo Helm**: as tags do blueprint (`!Find`, `!KeyOf`, `!Env`) são YAML customizado, e o caminho `values → toYaml` do Helm as destrói (chegam no cluster como string solta e o blueprint falha).
- O chart monta cada nome de `blueprints.configMaps` (no `02-application.yaml`) dentro do **worker**, em `/blueprints/mounted/cm-<nome>`; o worker descobre todo `*.yaml` de lá.
- **A descoberta é por evento, não no boot.** Quem dispara é o watcher de arquivos (`on_created`/`on_modified`) mais uma rodada **de hora em hora**. Um ConfigMap que já está populado quando o worker sobe não gera evento nenhum — o mount acontece antes do processo existir. Para forçar sem esperar: mude os **dados** do ConfigMap (ex.: um comentário no blueprint) e o kubelet re-sincroniza o volume, gerando os eventos. `kubectl annotate` **não** serve: metadado não faz o kubelet re-sincronizar.
- **A idempotência vem do `identifiers`**, não do `id`: o importer monta um `filter()` com ele e, se achar o objeto, atualiza (`partial=True`); se não, cria. O `id` da entry só existe para outras entries apontarem com `!KeyOf`. Entry sem `identifiers` aborta com "No or invalid identifiers".
- **Campos de lista têm default vazio e precisam ser declarados.** O `grant_types` é `ArrayField(..., default=list)` no modelo: o wizard da UI preenche, um blueprint não. Omitido, o provider nasce com `grant_types = {}` e passa a recusar todo grant (`Invalid grant_type for provider` no log do server) — e o `/authorize` responde `invalid_request`, o que parece um bug completamente outro. Mesma armadilha para qualquer `ArrayField` (o `property_mappings` acima é a mesma forma, com sintoma menos óbvio: token sem o claim `email`).
- **As credenciais do client são `!Env`**, resolvidas contra o ambiente do worker — que recebe **todas as chaves** do Secret `authentik-config` (`envFrom`). Elas ficam em `secrets/authentik.env` (gitignored). Atenção: o `!Env` devolve `None` quando a variável não existe, em vez de falhar alto — o sal está do outro lado: o serializer do authentik recusa `client_secret` nulo e o sync dá erro.
- **O e-mail do admin fica em sincronia com o Secret.** O `AUTHENTIK_BOOTSTRAP_EMAIL` só é consumido quando o banco é criado — corrigir o e-mail depois deixa o usuário com o antigo. Isso importa além da arrumação: é o e-mail que o LiteLLM usa para provisionar o usuário dele no primeiro login. Por isso o blueprint tem uma entry `authentik_core.user` que seta `email: !Env AUTHENTIK_BOOTSTRAP_EMAIL` (o valor fica no Secret gitignored em vez de escrito num arquivo versionado). O `partial=True` do importer garante que só esse campo é tocado no usuário admin.

Login de admin é o `akadmin`:

```bash
kubectl -n platform get secret authentik-config -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_EMAIL}' | base64 -d; echo
kubectl -n platform get secret authentik-config -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}' | base64 -d; echo
```

> A senha acima é a de **bootstrap**: ela é consumida quando o banco é criado. Editá-la no `secrets/authentik.env` depois **não** muda a senha de um `akadmin` que já existe — isso é feito na UI (`Settings → Password`).

### LiteLLM (`litellm.lan`)

Proxy compatível com a API da OpenAI em `https://litellm.lan` (Ingress ns `platform` → `litellm:4000`, certificado mkcert dedicado `litellm-tls`). O banco é o **PostgreSQL 18 compartilhado do cluster** (ns `data`, banco `litellm`, `?schema=litellm`) — a mesma instância que serve o Authentik, num banco só dele.

**DNS:** `litellm.lan` precisa ser adicionado como rewrite no AdGuard (`Filters → DNS rewrites` → `192.168.1.20`), como os outros nomes `.lan`. Os rewrites do AdGuard são **por host, não wildcard**, e a config vive dentro do PVC `adguard-conf-fs` (não está no repo) — então esse é um passo manual, uma vez só.

```bash
# master key — o bearer token da API (NÃO é login da UI, ver abaixo)
kubectl -n platform get secret litellm-masterkey -o jsonpath='{.data.masterkey}' | base64 -d
# lista os modelos
curl -sk https://litellm.lan/v1/models -H "Authorization: Bearer $MASTER_KEY"
```

**O login da UI é SSO pelo Authentik** (provider `LiteLLM`, ver a seção do Authentik acima). Redirect URI: `https://litellm.lan/sso/callback`; o acesso é restrito aos grupos `litellm-users` e `litellm-admins`. A troca é toda por variável de ambiente:

- As chaves são `GENERIC_*`, **não** `GOOGLE_*`. O LiteLLM escolhe o provedor num `if/elif` na ordem **Google → Microsoft → Generic**, então enquanto `GOOGLE_CLIENT_ID` existir o bloco genérico é código morto — remover as duas chaves do Google é o que de fato troca o provedor.
- São três endpoints configurados à mão (`authorize`, `token`, `userinfo`): o LiteLLM **não** usa discovery de OIDC, não há consulta a `/.well-known`.
- O `PROXY_BASE_URL` (`https://litellm.lan`) é quem compõe o redirect URI; tem que bater com o que está registrado no provider.
- **O papel do usuário vem de um claim, não do grupo.** Entrar e poder mexer são perguntas diferentes: o grupo é o binding que deixa entrar (o Authentik), a role vem no claim `litellm_role` do userinfo (o LiteLLM). Sem role no token o LiteLLM **não** recusa o login — cai no default embutido dele, `internal_user_viewer` (UI em modo leitura), que era o que todo mundo ganhava, inclusive o admin, até 24/09/2026. Por isso as duas variáveis andam juntas: `GENERIC_USER_ROLE_ATTRIBUTE=litellm_role` diz qual campo ler, e `GENERIC_SCOPE=openid email profile litellm_role` faz o pedido que traz o claim. Os quatro valores válidos são exatos (`proxy_admin`, `proxy_admin_viewer`, `internal_user`, `internal_user_viewer`) — valor escrito errado não dá erro nenhum, só volta pro default.
- **A role é regravada no banco a cada login de usuário que já existe** (`_build_sso_user_update_data`), não só na criação. Consequência prática: mudar a role pela UI do LiteLLM é temporário — o próximo login SSO sobrescreve com o que o IdP disser. A fonte da verdade é o grupo no Authentik.
- A **master key não é afetada pelo SSO** — continua sendo o bearer token da API. Ela não é senha da UI: `POST /login` com `admin` + master key devolve 401 aqui.
- Sem `LITELLM_LICENSE`, o SSO tem teto de **5 usuários** (o `ui_sso.py` recusa acima disso). A `LiteLLM_UserTable` começa vazia, então só importa se mais gente for logar.

**TLS para falar com o Authentik.** O pod alcança o Authentik em `https://authentik.lan`, que dentro do cluster resolve para o VIP do MetalLB e serve um certificado **mkcert** — que não é confiado pelo bundle de CAs do Debian da imagem, então a troca de token falharia na verificação. Por isso o deployment monta a raiz do mkcert (o `ca.crt` do secret `litellm-tls`, que já está no ns `platform`) e um initContainer **concatena** com o bundle do sistema, apontando `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` para o resultado. Concatenar em vez de substituir importa: o proxy também chama `api.openai.com`, cujo certificado não é mkcert.

Detalhes do deploy que importam antes de mexer:
- **Chart**: `litellm-helm` oficial, puxado como chart **OCI** de `ghcr.io/berriai` (o índice Helm clássico `berriai.github.io/litellm-helm` dá 404). A `url` do repo Secret é o **pai** do chart no path OCI — o Argo CD monta `oci://<url>/<chart>`, daí `url: ghcr.io/berriai` + `chart: litellm-helm`. O `targetRevision` tem que ser tag exata (OCI não aceita range semver).
- **Não existe IngressClass neste cluster**: todo Ingress roteia pela annotation `haproxy.org/ingress.class` e fica com CLASS `<none>`. Por isso o `ingress.className` do chart está como `""` (o default `nginx` renderizaria `ingressClassName: nginx` e quebraria o roteamento).
- **Um hook PreSync roda antes de cada sync**: o job `litellm-migrations` do próprio chart, que roda o `prisma migrate deploy` antes do Deployment. Pode rodar de novo sem problema. Nada cria a role/banco/schema na hora do sync — eles nascem com a instância, no script de init do PostgreSQL compartilhado (`manifests/postgres/03-configmap-initdb.yaml`).
- **`ENFORCE_PRISMA_MIGRATION_CHECK=true` também é obrigatório.** Sem ela o LiteLLM loga "migration failed but continuing startup" e **sai com 0** — o Job aparece como `Completed` com o banco pela metade. Com ela, falha de migration falha o hook e para o sync.
- **Memória**: limite de 2Gi, não menos. Tanto o job de migrations (~1,7Gi de pico) quanto o proxy são OOMKilled com 1Gi. O `strategy: Recreate` evita dois proxies num rollout neste nó único e apertado de memória.
- **Métricas precisam do callback**: o `/metrics` só existe com `litellm_settings.callbacks: [prometheus]` — sem ele o LiteLLM devolve 404 e o target do Prometheus fica DOWN (o ServiceMonitor em si funciona: o scrape acontece). Com o callback ligado o endpoint também passa a exigir a API key, daí o `require_auth_for_metrics_endpoint: false` (o endpoint é ClusterIP).

Manifestos: `manifests/argocd/litellm/`. Secrets: ver a tabela acima.

### Grafana (`grafana.lan`)

Métricas e dashboards do cluster: `kube-prometheus-stack` (chart 90.0.0, ns `monitoring`), com o Grafana `13.2.1-distroless`, PVC `local-path` de 10Gi e os sidecars de datasources/dashboards lendo ConfigMaps. Acessível em `https://grafana.lan` — Ingress `grafana` + Certificate `grafana-tls` (`manifests/argocd/prometheus-stack/03-certificate.yaml` e `04-ingress.yaml`, aplicados com `kubectl apply -f`, porque a Application aponta para o chart de terceiros e não para este repo).

**SSO pelo Authentik** (provider `Grafana`, blueprint `grafana-oidc.yaml`). O Grafana fala OIDC **nativamente** — não tem proxy na frente como o Headlamp; o Authentik só entrega os claims:

- Acesso pelo grupo **`grafana-users`** (binding da Application, um lugar só: o Grafana não usa `allowed_groups`).
- **Papel por grupo**, com `role_attribute_path` (JMESPath): `grafana-admins` → `GrafanaAdmin`, o resto → `Viewer`. Diferente do LiteLLM, aqui **não** existe scope mapping próprio: o Grafana avalia o claim `groups`, e esse claim já vem do scope `profile` (que devolve a lista de grupos do usuário). O que o Grafana compara é o **nome do grupo**, então o mapeamento grupo→papel mora no `grafana.ini`, não no blueprint.
- `role_attribute_strict = true`: se o claim `groups` faltar, o login é **negado** em vez de rebaixar todo mundo para `Viewer` em silêncio (é a lição do LiteLLM, que caía em `internal_user_viewer` sem avisar ninguém). `allow_assign_grafana_admin = true` é o que faz o `GrafanaAdmin` acima valer como admin **de servidor**; sem ela seria só Admin da organização.
- A role é re-sincronizada a cada login: promover/rebaixar alguém é mexer no grupo no Authentik, não no Grafana.
- O login local (`admin` + secret `grafana-admin`) **continua valendo** — é o break-glass (não passa pelo Authentik) e é com ele que os sidecars de dashboards falam com a API local.

Três detalhes que custam caro se errados:

- **`root_url` é obrigatório.** O `redirect_uri` do fluxo é derivado dele; sem `root_url`, o Grafana monta a URL a partir do `Host` do request (que chega como `http`, atrás do ingress) e o Authentik recusa por não bater com o `https://grafana.lan/login/generic_oauth` registrado no provider.
- **A CA do mkcert entra montada, via `extraSecretMounts`.** O pod é distroless (sem shell) e roda com rootfs read-only, então não dá para concatenar um bundle como o LiteLLM faz: monta-se o `ca.crt` do próprio secret `grafana-tls` (todo secret tls do cert-manager carrega o `ca.crt` da emissora) e aponta-se `tls_client_ca` para ele — o equivalente Go do `--provider-ca-file` do oauth2-proxy. **Não** use `extraVolumes` para isso: o template do chart só renderiza `existingClaim`/`hostPath`/`csi`/`configMap`/`emptyDir` e um volume `secret:` cai silenciosamente em `emptyDir` vazio — o pod sobe, o arquivo não existe e o SSO falha só no login, longe da causa.
- **A credencial não entra no `grafana.ini`.** O par client_id/secret vem do Secret `grafana-oidc` como env `GF_AUTH_GENERIC_OAUTH_*` (`envFromSecret`), que sobrepõe o ini — é o que o `assertNoLeakedSecrets` do chart confere no render.

Manifestos: `manifests/argocd/prometheus-stack/`. Secrets: ver a tabela acima.

### Namespace `data`

Os apps do namespace `data` são "app-style": manifestos próprios em `manifests/<app>/` mais uma Application em `manifests/argocd/<app>/`, com PVCs `local-path`. Ele abriga o banco compartilhado e os serviços de apoio ao redor dele.

#### PostgreSQL (data)

A **instância de banco compartilhada** do cluster: um PostgreSQL 18.6 — a imagem oficial `postgres:18.6`, sem chart — no namespace `data`, servindo as aplicações que precisam de um banco SQL de verdade, cada uma no seu **próprio banco e com a própria role**: `litellm` (role `litellm`, schema `litellm`, do Prisma), `authentik` (role `authentik`, do Django) e `odoo` (role `odoo`). Uma instância, três clientes: as roles nascem com o mínimo de privilégio (`NOSUPERUSER NOCREATEDB NOCREATEROLE`) e o superusuário nunca sai do pod.

Os manifestos são versionados neste repo, em `manifests/postgres/`, porque aqui não há chart de terceiros para pinar — só a imagem oficial. Por isso a Application `postgres` (`manifests/argocd/postgres/02-application.yaml`) segue o padrão do vaultwarden: `source` apontando para este repositório, `path: manifests/postgres`, onde um `kustomization.yaml` compõe o PVC, o Deployment, o ConfigMap de init e o Service (o Argo CD detecta kustomize sozinho). O PVC carrega `Prune=false,Delete=false` — ele guarda dado de verdade e não pode sumir quando a Application for podada ou excluída.

Dentro do cluster o endereço é `postgres.data.svc.cluster.local:5432`, que é como o LiteLLM, o Authentik e o Odoo se conectam. Do host, o Service é um NodePort (`30432`) que o `docker-compose` publica como `127.0.0.1:5432:30432` — **loopback de propósito**: todas as outras portas publicadas existem para a LAN alcançar o host, mas o banco não pode sair dele. NodePort e não LoadBalancer pelo mesmo motivo dos ingresses: o VIP do MetalLB é anunciado dentro da rede docker do cluster e não é alcançável da LAN. E `30432` e não `5432` porque porta de NodePort tem que ficar no range 30000-32767 do apiserver.

A autenticação é `scram-sha-256` para toda conexão remota: o entrypoint da imagem anexa `host all all all scram-sha-256` ao `pg_hba.conf`, e essa linha pega todo TCP — inclusive o que chega pelo NodePort. O único `trust` que sobra é o socket unix e o loopback *dentro* do pod (o default do initdb), inalcançável de fora, já que tráfego do NodePort chega com o IP de origem do cliente, nunca `127.0.0.1`. O `POSTGRES_HOST_AUTH_METHOD` não é definido de propósito — apontá-lo para `trust` seria um superusuário sem senha. A senha do superusuário vive no Secret gitignored `postgres-superuser`; cada aplicação recebe só as credenciais da própria role, em Secrets aplicados **nos dois** namespaces, `platform` e `data` (ver [Segredos](#segredos)).

> **O volume monta em `/var/lib/postgresql`, não em `/var/lib/postgresql/data`.** Na 18 a imagem moveu o `PGDATA` para `/var/lib/postgresql/18/docker`, com o `VOLUME` declarado no pai, e montar no caminho das v15–v17 faz o entrypoint abortar no boot com "there appears to be PostgreSQL data in: /var/lib/postgresql/data (unused mount/volume)". Deixar o `PGDATA` no default é também o que mantém viável o `pg_upgrade --link` num upgrade de major.

#### Redis

Cache de nó único no namespace `data`: um StatefulSet `redis:8-alpine` com persistência AOF+RDB, PVC `local-path` de 1Gi e Service ClusterIP em `redis.data.svc:6379`. A senha vem do Secret `redis-auth` e é passada como `--requirepass` na linha de comando — o `redis.conf` não expande variável de ambiente, então ela não pode ficar no ConfigMap. **Acesso somente in-cluster**: sem NodePort, sem Ingress, sem exposição externa — decisão deliberada.

#### OpenSearch + Dashboards

`opensearchproject/opensearch:3.3.2`, single-node, com o plugin de segurança **desabilitado** (`DISABLE_SECURITY_PLUGIN=true` — sem auth/TLS interno), heap de 512m e `bootstrap.memory_lock`, PVC `local-path` de 10Gi e Service ClusterIP em 9200/9600. A UI é o `opensearchproject/opensearch-dashboards:3.0.0` em `https://opensearch.lan` (Ingress + Certificate no namespace `data`). Requer `vm.max_map_count>=262144` no host (já setado).

#### pgAdmin

`dpage/pgadmin4:9.18.0`, login pelo Secret `pgadmin-credentials`, com um ConfigMap `servers.json` que já aponta para o PostgreSQL do cluster (`postgres:5432`), PVC `local-path` de 2Gi e UI em `https://pgadmin.lan`. Roda **não-root** (uid 5050) sem escalonamento: como o Python da imagem tem a file-capability `cap_net_bind_service`, mantém-se `drop [ALL] + add NET_BIND_SERVICE` na bounding set (senão o exec do Python falha com EPERM); o `PGADMIN_DISABLE_POSTFIX=1` elimina o único `sudo`, e ele escuta em 8080 (`PGADMIN_LISTEN_PORT`). Medido no pod: uid 5050 e CapEff=0.

**SSO pelo Authentik** (provider `PgAdmin`, blueprint `pgadmin-oidc.yaml`). O pgAdmin fala OIDC **nativamente** com discovery (`OAUTH2_SERVER_METADATA_URL`), como o Grafana — não tem proxy na frente. Acesso restrito ao grupo **`pgadmin-users`**:

- **Gate duplo**: o binding da Application no Authentik decide *quem entra*; do lado do pgAdmin, `OAUTH2_ADDITIONAL_CLAIMS = {'groups': ['pgadmin-users']}` recusa o login se o id_token não trouxer o grupo (por isso o provider tem `include_claims_in_id_token: true` — senão o claim só viria no userinfo).
- O provider é lido **somente** da env `PGADMIN_CONFIG_OAUTH2_CONFIG` (a lista inteira, literal Python). Variáveis individuais (`PGADMIN_CONFIG_OAUTH2_CLIENT_ID` etc.) são **ignoradas** — o pgAdmin só loga um warning no boot. Armadilha documentada na doc oficial.
- O par client_id/secret vem do Secret `pgadmin-oidc` (os mesmos valores `PGADMIN_OIDC_*` do `authentik.env`) e é injetado no manifesto via `$(PGADMIN_OIDC_CLIENT_ID)`/`$(PGADMIN_OIDC_CLIENT_SECRET)` — o segredo não aparece versionado.
- **TLS**: o pod valida o id_token contra o JWKS do `authentik.lan`, então monta o `ca.crt` do secret `pgadmin-tls` (todo secret tls do cert-manager carrega a CA da emissora) em `/etc/pgadmin/mkcert-ca`, apontado por `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE`. Sem isso a troca de token morre em erro x509 (a imagem não conhece o mkcert). Alternativa menos segura: `'OAUTH2_SSL_CERT_VERIFICATION': False` no provider.
- O login local (`pgadmin-credentials`) continua como **emergência** (`AUTHENTICATION_SOURCES = ['oauth2', 'internal']`, como no Grafana/ArgoCD).
- O redirect registrado no provider é `https://pgadmin.lan/oauth2/authorize`. Em OAuth2 não há senha do usuário, então para **salvar** a senha do Postgres o pgAdmin pede um *master password* no primeiro acesso (`MASTER_PASSWORD_REQUIRED`, default).

**Registrar um server (conexão com o PostgreSQL do cluster).** O pgAdmin já sobe com um server compartilhado (`servers.json`): **`Postgres k8s-one`**, `Host=postgres`, `Port=5432`, `MaintenanceDB=postgres`, `Username=postgres`. Como o `pg_hba.conf` exige **`scram-sha-256`** em todo TCP (o `trust` só vale no socket local, dentro do pod), normalmente basta clicar nesse server e digitar a senha — que fica guardada por usuário, cifrada com o *master password*. Para adicionar/editar à mão (*Register → Server → Connection*):

| Campo | Valor |
|---|---|
| **Host name/address** | `postgres` (o pod está no mesmo ns `data`; ou `postgres.data.svc.cluster.local`) |
| **Port** | `5432` |
| **Maintenance database** | `postgres` |
| **Username** | `postgres` (superusuário) ou a role de app (`litellm`, `authentik`, `odoo`, `naesquina`) |
| **Password** | a do Secret correspondente (abaixo) |
| **SSL mode** (aba SSL) | `prefer` (o PG não serve TLS aqui) |

As senhas vivem em Secrets no ns `data` (nunca no repo). Para ler uma no host:

```bash
# superusuário (acesso total)
kubectl -n data get secret postgres-superuser -o jsonpath='{.data.postgres-password}' | base64 -d; echo
# role odoo
kubectl -n data get secret odoo-db -o jsonpath='{.data.password}' | base64 -d; echo
# role litellm
kubectl -n data get secret litellm-db -o jsonpath='{.data.password}' | base64 -d; echo
# role authentik
kubectl -n data get secret authentik-postgresql-auth -o jsonpath='{.data.password}' | base64 -d; echo
```

Bancos e donos atuais: `postgres`→postgres, `authentik`→authentik, `litellm`→litellm, `odoo`→odoo (`CREATEDB`), `naesquina`/`naesquina_test`→naesquina. As roles de app são `NOSUPERUSER/NOCREATEDB` (*least privilege*); o `postgres` só é necessário para administração da instância.

### Vaultwarden (`vault.lan`)

Cofre Bitwarden em `https://vault.lan` (namespace `vaultwarden`). Application do Argo CD deste repositório (`manifests/vaultwarden`), com PVC `local-path` de 1Gi e TLS mkcert.

### Odoo (`odoo.lan`)

ERP em `https://odoo.lan` (namespace `odoo`). Application do Argo CD deste repositório (`manifests/odoo`), com PVC `local-path` de 5Gi; o banco fica no PostgreSQL compartilhado (banco/role `odoo`, credenciais em `odoo-db`).

### TileServer (`tiles.naesquina.com.br`)

Tiles de mapa em `https://tiles.naesquina.com.br` (namespace `tileserver`). Aplicado **sob demanda** pelo `scripts/deploy-apps.sh` (`manifests/apps/tileserver`, a única árvore gitignored), a partir de um PVC `hostpath-tiles` (Reclaim `Retain`, `ReadOnlyMany`) — não é `local-path`.

---

## Storage

### local-path-provisioner

O storage é fornecido pelo **local-path-provisioner** (Rancher v0.0.30) no
namespace `local-path-storage`. Ele provisiona volumes dinamicamente como
diretórios hostPath em `/opt/local-path-provisioner`, persistidos no host pelo
bind mount `./data/local-path`.

- **Provisioner**: `rancher.io/local-path`
- **Data path**: `/opt/local-path-provisioner` (bind mount de `./data/local-path`)

| StorageClass | Provisioner | Access | Binding | Reclaim | Expansão |
|---|---|---|---|---|---|
| `local-path` (**default**) | `rancher.io/local-path` | RWO | `WaitForFirstConsumer` | `Delete` | não suportada |

```bash
kubectl get sc
# NAME                   PROVISIONER             RECLAIMPOLICY  VOLUMEBINDINGMODE
# local-path (default)   rancher.io/local-path   Delete         WaitForFirstConsumer
```

Os volumes **não são redundantes**: são diretórios comuns no disco do host, sob
`data/local-path/`. Faça backup desse diretório se os dados importarem. Como o
`local-path` não tem expansão online, os tamanhos dos PVCs são fixos
(`allowVolumeExpansion` não é definido).

---

## Problemas Conhecidos

### local-path não tem expansão online

- **Sintoma:** editar `resources.requests.storage` de um PVC é rejeitado.
- **Causa:** a StorageClass `local-path` não define `allowVolumeExpansion`.
- **Contorno:** recriar o PVC e restaurar os dados (ou migrar para um PVC maior).
  Os tamanhos são fixos na criação.

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

### PVC preso em Pending

O `local-path` usa `volumeBindingMode: WaitForFirstConsumer`, então um PVC fica
`Pending` até que um pod que o consome seja agendado. Isso é esperado, não é falha.

```bash
kubectl describe pvc <nome-do-pvc> -n <namespace>
kubectl -n local-path-storage logs deploy/local-path-provisioner
```

Causas comuns:
- Nenhum pod consumindo o PVC ainda → é o `WaitForFirstConsumer` funcionando
- Provisioner não está Running → ver os logs acima
- Dados do volume sumiram após recriar o container → confirmar que o bind mount `./data/local-path` existe

### CoreDNS CrashLoopBackOff

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns
```

Causas comuns:
- Loop detection → já resolvido com forward para 8.8.8.8
- Corefile syntax error → verificar `manifests/built-in/coredns/04-configmap.yaml`

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
docker compose down -v   # remove container + volumes nomeados (bind mounts ./data/ e ./data/local-path/ são mantidos)
docker compose up -d     # fresh start
# Para apagar também os dados dos volumes: rm -rf data/* data/local-path/*  (irreversível!)
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
| **Disco** | 10 GB (imagem + dados dos volumes) | 20 GB+ |
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
| `5432` | TCP | PostgreSQL (→ NodePort 30432, **só no loopback do host**) |

---

## Limitações

- **Não é HA**: nó único, sem redundância. etcd, apiserver, etc. são single-instance.
- **Não para produção**: destinado a desenvolvimento, testes, CI/CD, laboratório.
- **Storage sem redundância**: volumes `local-path` são diretórios hostPath comuns no disco do host.
- **Privileged mode**: o container roda com `--privileged` (necessário para kubelet/containerd).
- **Apenas amd64**: arm64 pode funcionar com `--build-arg TARGETARCH=arm64` mas não foi testado.
- **Sem systemd**: usa `cgroupfs` como cgroup driver (sem systemd dentro do container).
- **Cert rotation**: desabilitada. Certificados duram 10 anos. Para clusters de longa duração, considere implementar rotação.

---

## Licença

MIT
