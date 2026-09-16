#!/bin/bash
# deploy-apps.sh — aplica os manifests por domínio do k8s-one (kustomize).
#
# Os manifests vivem em ./manifests/<domínio> (networking, ops, data, apps, ...)
# e a árvore de cada domínio é montada read-only no container em
# /opt/manifests/<domínio> — NÃO usa docker cp.
#
# Domínio = namespace funcional agregado por kustomization.yaml na raiz da pasta
# (ex.: networking/ agrega adguard; ops/ agrega headlamp+argocd; apps/ = negócio).
#
# Uso:  scripts/deploy-apps.sh [--delete]
set -euo pipefail

CONTAINER="${K8S_ONE_CONTAINER:-k8s-one}"
KUBECONFIG_IN="/etc/kubernetes/admin.conf"

# Ordem de aplicação (delete em ordem inversa)
DOMAINS=(apps networking ops data platform)

cd "$(dirname "$0")/.."

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERRO: container '$CONTAINER' não está rodando" >&2
  exit 1
fi

kustom_apply() { # $1 = domínio
  local dir="/opt/manifests/$1"
  [ -f "$dir/kustomization.yaml" ] || { echo "skip: $dir (sem kustomization)"; return 0; }
  docker exec "$CONTAINER" kubectl --kubeconfig="$KUBECONFIG_IN" apply -k "$dir"
}

kustom_delete() { # $1 = domínio
  local dir="/opt/manifests/$1"
  [ -f "$dir/kustomization.yaml" ] || return 0
  docker exec "$CONTAINER" kubectl --kubeconfig="$KUBECONFIG_IN" delete -k "$dir" --ignore-not-found
}

if [ "${1:-}" = "--delete" ]; then
  for d in $(echo "${DOMAINS[@]}" | tr ' ' '\n' | tac); do
    echo "Deletando domínio $d..."
    kustom_delete "$d"
  done
  exit $?
fi

for d in "${DOMAINS[@]}"; do
  echo "Aplicando domínio $d (kustomize)..."
  kustom_apply "$d"
done
