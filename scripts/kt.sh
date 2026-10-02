#!/bin/bash
# kt.sh — wrapper do ktctl (kt-connect) para o cluster k8s-one.
#
# Fixa os defaults deste ambiente (kubeconfig da SA, imagem do shadow, DNS em
# modo hosts) e repassa o restante dos argumentos para o ktctl. Assim os
# comandos ficam curtos e sem armadilha:
#
#   scripts/kt.sh connect
#   scripts/kt.sh exchange <svc> --expose 8080 -n <ns>
#   scripts/kt.sh mesh <svc> --expose 8080 -n <ns>
#   scripts/kt.sh preview <nome> --expose 8080
#   scripts/kt.sh forward <svc> 6060:8080 -n <ns>
#   scripts/kt.sh clean
#
# Gere o kubeconfig da SA antes, com scripts/kt-connect-kubeconfig.sh.
#
# Variáveis de ambiente:
#   KUBECONFIG        kubeconfig do cluster (default: ./kubeconfig.kt-connect)
#   KT_SHADOW_IMAGE   imagem do shadow (default: registry.cn-hangzhou.aliyuncs.com/...)
#   KT_NAMESPACE      ns do shadow no connect (default: kt-connect)
#   KT_EXCLUDE_IPS    IPs fora do túnel no connect (default: 192.168.32.0/20, a rede docker)
set -euo pipefail

cd "$(dirname "$0")/.."

KUBECONFIG="${KUBECONFIG:-$PWD/kubeconfig.kt-connect}"
KT_SHADOW_IMAGE="${KT_SHADOW_IMAGE:-registry.cn-hangzhou.aliyuncs.com/rdc-incubator/kt-connect-shadow:v0.3.7}"
# Namespace do shadow do `connect`. O ktctl NÃO segue o namespace do contexto do
# kubeconfig (o flag --namespace tem default "default"), então fixamos o nosso.
KT_NAMESPACE="${KT_NAMESPACE:-kt-connect}"
# O ktctl calcula o CIDR dos pods a partir dos IPs reais. Como há pods com
# hostNetwork (cilium, cilium-envoy, cilium-operator, adguard) que reportam o IP
# do nó (192.168.32.2), o range computado vira 192.168.0.0/16 e engole a rede
# docker. Excluímos a rede docker para o connect não sequestrar as rotas dela.
KT_EXCLUDE_IPS="${KT_EXCLUDE_IPS:-192.168.32.0/20}"

if [ "$#" -eq 0 ]; then
  echo "Uso: scripts/kt.sh <connect|exchange|mesh|preview|forward|clean|birdseye|recover> [args...]" >&2
  exit 2
fi

if ! command -v ktctl >/dev/null 2>&1; then
  echo "ERRO: ktctl não encontrado no PATH." >&2
  echo "      Instale o v0.3.7: https://github.com/alibaba/kt-connect/releases/tag/v0.3.7" >&2
  exit 1
fi

if [ ! -f "$KUBECONFIG" ]; then
  echo "ERRO: kubeconfig não encontrado em '$KUBECONFIG'." >&2
  echo "      Gere com: scripts/kt-connect-kubeconfig.sh" >&2
  exit 1
fi

SUBCOMMAND="$1"
shift

# Checa se a flag já foi passada pelo usuário (com ou sem "=valor").
flag_present() { # $1 = flag, rest = args
  local needle="$1"; shift
  local a
  for a in "$@"; do
    case "$a" in
      "$needle"|"$needle"=*) return 0 ;;
    esac
  done
  return 1
}

KT_GLOBALS=()
flag_present --kubeconfig "$@" || flag_present -c "$@" || KT_GLOBALS+=(--kubeconfig "$KUBECONFIG")
flag_present --image "$@"      || flag_present -i "$@" || KT_GLOBALS+=(--image "$KT_SHADOW_IMAGE")

if [ "$SUBCOMMAND" = "connect" ]; then
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ERRO: 'connect' precisa de root (cria o tun e mexe nas rotas). Use sudo." >&2
    exit 1
  fi
  # localDNS reescreve o /etc/resolv.conf; 'hosts' escreve só no /etc/hosts.
  flag_present --dnsMode "$@" || KT_GLOBALS+=(--dnsMode hosts)
  # Shadow no ns kt-connect (o -n do ktctl ignora o contexto do kubeconfig).
  flag_present -n "$@" || flag_present --namespace "$@" || KT_GLOBALS+=(--namespace "$KT_NAMESPACE")
  # Preserva a rede docker (ver KT_EXCLUDE_IPS acima).
  flag_present --excludeIps "$@" || KT_GLOBALS+=(--excludeIps "$KT_EXCLUDE_IPS")
fi

echo ">> ktctl $SUBCOMMAND ${KT_GLOBALS[*]} $*" >&2
exec ktctl "$SUBCOMMAND" "${KT_GLOBALS[@]}" "$@"
