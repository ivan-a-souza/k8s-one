#!/bin/bash
# fix-rbd-stale.sh — one-shot recovery for orphaned rbd-nbd mappings.
#
# Run from the HOST (needs kubectl + a kubeconfig). Finds the Ceph RBD CSI node
# plugin pod and unmaps nbd devices whose volumeHandle has no VolumeAttachment
# in Attached=true state for this node (see scripts/rbd-nbd-reaper.sh for the
# rationale). Use it when a PVC is stuck in ContainerCreating with
# "rbd image ... is still being used" / "cookie mismatch".
#
# Uso:
#   scripts/fix-rbd-stale.sh                 # dry-run (mostra o que faria)
#   scripts/fix-rbd-stale.sh --apply         # desmapeia os órfãos
#   scripts/fix-rbd-stale.sh --apply --all   # desmapeia TODOS (emergência/boot)
#   scripts/fix-rbd-stale.sh --apply --yes   # sem confirmação
set -euo pipefail

cd "$(dirname "$0")/.."
KUBECONFIG="${KUBECONFIG:-$PWD/kubeconfig}"
export KUBECONFIG
NODE="${NODE_NAME:-k8s-one}"
NAMESPACE="${ROOK_NAMESPACE:-rook-ceph}"

DRY_RUN=1
ALL=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --apply)   DRY_RUN=0 ;;
    --all)     ALL=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    *) echo "arg desconhecido: $arg" >&2; exit 2 ;;
  esac
done

kc() { kubectl --kubeconfig="$KUBECONFIG" "$@"; }

PLUGIN=$(kc -n "$NAMESPACE" get pods -o name 2>/dev/null | grep 'rbd.csi.ceph.com-nodeplugin' | head -1 || true)
if [ -z "$PLUGIN" ]; then
  echo "ERRO: CSI rbd nodeplugin não encontrado em $NAMESPACE" >&2
  exit 1
fi
echo "CSI nodeplugin: $PLUGIN"

attached_volumes() {
  local pv_map va_pvs
  pv_map=$(kc get pv -o go-template='{{range .items}}{{if .spec.csi}}{{.metadata.name}} {{.spec.csi.volumeHandle}}{{"\n"}}{{end}}{{end}}' 2>/dev/null) || return 1
  [ -n "$pv_map" ] || return 1
  va_pvs=$(kc get volumeattachments -o go-template='{{range .items}}{{if and (eq .spec.nodeName "'"$NODE"'") .status.attached}}{{.spec.source.persistentVolumeName}}{{"\n"}}{{end}}{{end}}' 2>/dev/null) || return 1
  local pv vh
  while read -r pv; do
    [ -n "$pv" ] || continue
    vh=$(printf '%s\n' "$pv_map" | awk -v p="$pv" '$1==p{print $2}')
    [ -n "$vh" ] && echo "$vh"
  done <<< "$va_pvs"
}

ATTACHED=""
if [ "$ALL" = "0" ]; then
  ATTACHED=$(attached_volumes) || { echo "ERRO: não consegui consultar VAs/PVs" >&2; exit 1; }
fi

# Collect targets: device path + volID
targets=()
for dev in /sys/block/nbd[0-9]*; do
  [ -e "$dev" ] || continue
  backend=$(cat "$dev/backend" 2>/dev/null || true)
  [ -n "$backend" ] || continue
  if [ "$ALL" = "0" ] && printf '%s\n' "$ATTACHED" | grep -qxF "$backend"; then
    continue
  fi
  targets+=("$(basename "$dev") $backend")
done

if [ "${#targets[@]}" -eq 0 ]; then
  echo "Nenhum mapeamento rbd-nbd órfão encontrado."
  exit 0
fi

echo "Mapeamentos a desmapear (${#targets[@]}):"
for t in "${targets[@]}"; do echo "  $t"; done

if [ "$DRY_RUN" = "1" ]; then
  echo
  echo "[dry-run] nada foi alterado. Use --apply para desmapear."
  exit 0
fi

if [ "$ASSUME_YES" != "1" ]; then
  read -r -p "Confirma o unmap desses dispositivos? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "abortado."; exit 0 ;; esac
fi

for t in "${targets[@]}"; do
  dev="/dev/${t%% *}"
  echo "unmap $dev"
  kc -n "$NAMESPACE" exec "$PLUGIN" -c csi-rbdplugin -- rbd-nbd unmap "$dev" || \
    echo "WARN: falha ao desmapear $dev" >&2
done
echo "OK."
