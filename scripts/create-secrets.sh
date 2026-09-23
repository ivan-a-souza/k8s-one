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

apply_yaml_secret_in_ns() { # $1=namespace $2=yaml-file (mesmo conteúdo, outro namespace)
  local ns=$1 file=$2
  if [ ! -f "$file" ]; then
    echo "skip: $file (ausente)"
    return 0
  fi
  echo "Secret $ns <- $file"
  # O `namespace:` do manifesto VENCE o -n do kubectl, então ele é reescrito
  # aqui. É o que permite o mesmo arquivo ser a fonte única de uma credencial
  # que precisa existir em dois namespaces (o banco vive em `data`, os
  # consumidores em `platform`) sem virar duas cópias que divergem.
  sed -E "s|^  namespace: .*|  namespace: $ns|" "$file" | "${KC[@]}" apply -f -
}

# authentik — env do app (chaves AUTHENTIK_*)
apply_env_secret platform authentik-config manifests/argocd/authentik/secrets/authentik.env
# authentik — auth do PostgreSQL (chaves postgres-password / password)
apply_yaml_secret manifests/argocd/authentik/secrets/postgresql-auth.yaml
# kube-prometheus-stack — admin do Grafana (chaves admin-user / admin-password)
apply_yaml_secret manifests/argocd/prometheus-stack/secrets/grafana-admin.yaml
# litellm — env do proxy (OPENAI_API_KEY, LITELLM_SALT_KEY, PROXY_BASE_URL, OIDC)
apply_env_secret platform litellm-env manifests/argocd/litellm/secrets/litellm.env
# litellm — credenciais do PostgreSQL (chaves username / password)
apply_yaml_secret manifests/argocd/litellm/secrets/litellm-db.yaml
# litellm/mesma credencial no ns data: é o script de init do PostgreSQL que cria
# a role com essa senha, e o banco vive em `data` enquanto o proxy vive em
# `platform`. Secret é namespaced, então o MESMO arquivo é aplicado duas vezes —
# uma fonte de verdade só, nunca editar a senha em um lugar e não no outro.
apply_yaml_secret_in_ns data manifests/argocd/litellm/secrets/litellm-db.yaml
# authentik — as mesmas credenciais do banco, agora também no ns data (o
# Secret `authentik-postgresql-auth` continua sendo o que o chart do authentik
# lê via existingSecret; a cópia em `data` é o que o init do PostgreSQL lê).
apply_yaml_secret_in_ns data manifests/argocd/authentik/secrets/postgresql-auth.yaml
# postgres — senha do SUPERUSUÁRIO da instância (chave postgres-password).
# Usada só no POSTGRES_PASSWORD do initdb e em manutenção; nenhuma aplicação a
# recebe.
apply_yaml_secret manifests/argocd/postgres/secrets/postgres-superuser.yaml
# litellm — master key do proxy (chave masterkey)
apply_yaml_secret manifests/argocd/litellm/secrets/litellm-masterkey.yaml
# headlamp — env OIDC da UI (chaves HEADLAMP_CONFIG_OIDC_*)
apply_env_secret ops headlamp-oidc manifests/ops/headlamp/secrets/headlamp-oidc.env
# oauth2-proxy — auth proxy na frente do Headlamp (client + cookie secret)
apply_env_secret ops oauth2-proxy manifests/ops/headlamp/secrets/oauth2-proxy.env

echo "OK: secrets aplicados."
apply_env_secret vaultwarden vaultwarden-env manifests/argocd/vaultwarden/secrets/vaultwarden.env
