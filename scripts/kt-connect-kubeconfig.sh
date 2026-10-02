#!/bin/bash
# kt-connect-kubeconfig.sh — gera o kubeconfig da ServiceAccount usada pelo
# ktctl (kt-connect) a partir do kubeconfig admin (./kubeconfig), SEM client
# certificates de admin: é um token de SA, escopado pelo ClusterRole kt-connect
# (ver manifests/ops/kt-connect/).
#
# Passos:
#   1. aplica o RBAC do kt-connect (namespace, SA, ClusterRole, binding, Secret);
#   2. espera o kube-controller-manager popular o token do Secret legado;
#   3. monta ./kubeconfig.kt-connect com server/CA do cluster e o token da SA.
#
# Uso:  scripts/kt-connect-kubeconfig.sh
# Saída: ./kubeconfig.kt-connect (gitignored). Depois:
#   export KUBECONFIG=$PWD/kubeconfig.kt-connect
set -euo pipefail

cd "$(dirname "$0")/.."

ADMIN_KUBECONFIG="${KUBECONFIG:-$PWD/kubeconfig}"
OUT="${KT_KUBECONFIG:-$PWD/kubeconfig.kt-connect}"

NS=kt-connect
SA=kt-connect
SECRET=kt-connect-token
MANIFESTS=manifests/ops/kt-connect

if [ ! -f "$ADMIN_KUBECONFIG" ]; then
  echo "ERRO: kubeconfig admin não encontrado em '$ADMIN_KUBECONFIG'." >&2
  echo "      Rode: docker cp k8s-one:/etc/kubernetes/admin-external.conf ./kubeconfig" >&2
  exit 1
fi

KC=(kubectl --kubeconfig "$ADMIN_KUBECONFIG")

echo "Aplicando RBAC do kt-connect ($MANIFESTS)..."
"${KC[@]}" apply -k "$MANIFESTS"

echo "Aguardando o token da SA $NS/$SA ficar pronto..."
token=""
for _ in $(seq 1 30); do
  token=$("${KC[@]}" -n "$NS" get secret "$SECRET" \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [ -n "$token" ] && break
  sleep 1
done

if [ -z "$token" ]; then
  echo "ERRO: o Secret $NS/$SECRET não foi populado com um token." >&2
  echo "      Confira o controller serviceaccount-token do kube-controller-manager." >&2
  exit 1
fi

# Server do cluster (não é redigido no config view) e CA a partir do próprio
# Secret do token — assim funciona mesmo se o kubeconfig admin referenciar a CA
# por arquivo em vez de certificate-authority-data.
server=$("${KC[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
ca=$("${KC[@]}" -n "$NS" get secret "$SECRET" -o jsonpath='{.data.ca\.crt}')

if [ -z "$server" ] || [ -z "$ca" ]; then
  echo "ERRO: não foi possível extrair server/CA do kubeconfig admin." >&2
  exit 1
fi

umask 077
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: k8s-one
    cluster:
      server: $server
      certificate-authority-data: $ca
contexts:
  - name: kt-connect
    context:
      cluster: k8s-one
      user: $SA
      namespace: $NS
current-context: kt-connect
users:
  - name: $SA
    user:
      token: $token
EOF
chmod 600 "$OUT"

echo "OK: kubeconfig da SA escrita em $OUT"
echo "    export KUBECONFIG=$OUT"
