#!/bin/bash
# deploy-apps.sh — aplica os manifests de apps do k8s-one (kustomize).
#
# Os manifests vivem em ./manifests (gitignored) e são montados read-only
# no container (./manifests/apps:/opt/manifests/apps:ro e
# ./manifests/secrets:/opt/manifests/secrets:ro) — NÃO usa docker cp.
#
# Uso:  scripts/deploy-apps.sh [--delete]
set -euo pipefail

CONTAINER="${K8S_ONE_CONTAINER:-k8s-one}"
KUBECONFIG_IN="/etc/kubernetes/admin.conf"

cd "$(dirname "$0")/.."

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERRO: container '$CONTAINER' não está rodando" >&2
  exit 1
fi

if [ "${1:-}" = "--delete" ]; then
  docker exec "$CONTAINER" kubectl --kubeconfig="$KUBECONFIG_IN" delete -k /opt/manifests/apps
  exit $?
fi

echo "Aplicando apps (kustomize) em $CONTAINER..."
docker exec "$CONTAINER" kubectl --kubeconfig="$KUBECONFIG_IN" apply -k /opt/manifests/apps
