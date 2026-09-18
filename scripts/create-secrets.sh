#!/bin/bash
# create-secrets.sh — cria/atualiza os Secrets do cluster a partir dos arquivos
# gitignored em manifests/**/secrets/. Rodar ANTES de aplicar as Applications do
# ArgoCD (os `existingSecret` precisam existir antes do sync).
#
# As fontes NUNCA são commitadas (.gitignore cobre manifests/*/*/secrets/).
# Uso:  scripts/create-secrets.sh
set -euo pipefail

cd "$(dirname "$0")/.."
KUBECONFIG="${KUBECONFIG:-$PWD/kubeconfig}"
export KUBECONFIG

KC=(kubectl --kubeconfig "$KUBECONFIG")

apply_env_secret() { # $1=namespace $2=secret-name $3=env-file
  local ns=$1 name=$2 file=$3
  if [ ! -f "$file" ]; then
    echo "skip: $file (ausente)"
    return 0
  fi
  echo "Secret $ns/$name <- $file"
  "${KC[@]}" -n "$ns" create secret generic "$name" \
    --from-env-file="$file" --dry-run=client -o yaml \
    | "${KC[@]}" apply -f -
}

apply_yaml_secret() { # $1=yaml-file
  local file=$1
  if [ ! -f "$file" ]; then
    echo "skip: $file (ausente)"
    return 0
  fi
  echo "Secret <- $file"
  "${KC[@]}" apply -f "$file"
}

# authentik — env do app (chaves AUTHENTIK_*)
apply_env_secret platform authentik-config manifests/argocd/authentik/secrets/authentik.env
# authentik — auth do PostgreSQL (chaves postgres-password / password)
apply_yaml_secret manifests/argocd/authentik/secrets/postgresql-auth.yaml
# kube-prometheus-stack — admin do Grafana (chaves admin-user / admin-password)
apply_yaml_secret manifests/argocd/prometheus-stack/secrets/grafana-admin.yaml
# litellm — env do proxy (OPENAI_API_KEY, LITELLM_SALT_KEY, PROXY_BASE_URL, OIDC)
apply_env_secret platform litellm-env manifests/argocd/litellm/secrets/litellm.env
# litellm — credenciais do YugabyteDB (chaves username / password)
apply_yaml_secret manifests/argocd/litellm/secrets/litellm-db.yaml
# litellm — master key do proxy (chave masterkey)
apply_yaml_secret manifests/argocd/litellm/secrets/litellm-masterkey.yaml

echo "OK: secrets aplicados."
