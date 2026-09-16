#!/bin/bash
# fix-nbd-stuck.sh — desconecta dispositivos nbd MORTOS (mapeamentos rbd-nbd
# cujo processo userspace já morreu). Esses mapeamentos podem deixar o
# systemd-udevd/containerd presos em D-state e o container k8s-one imortal
# (ver README > Troubleshooting > "Container/Docker travado").
#
# Rode no HOST, com sudo. NÃO mexe no Docker: apenas desconecta os nbd mortos.
# Depois reinicie o Docker e recrie o cluster.
#
# Uso:
#   sudo scripts/fix-nbd-stuck.sh            # dry-run (lista os nbd mortos)
#   sudo scripts/fix-nbd-stuck.sh --apply    # desconecta
#   sudo scripts/fix-nbd-stuck.sh --apply --yes
set -euo pipefail

APPLY=0
YES=0
for a in "$@"; do
  case "$a" in
    --apply)   APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --yes|-y)  YES=1 ;;
    *) echo "arg desconhecido: $a" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERRO: rode com sudo" >&2; exit 1; }

dead=()
for d in /sys/block/nbd[0-9]*; do
  [ -e "$d" ] || continue
  backend=$(cat "$d/backend" 2>/dev/null || true)
  [ -n "$backend" ] || continue
  pid=$(cat "$d/pid" 2>/dev/null || true)
  # mapeamento vivo = processo dono ainda existe
  if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    continue
  fi
  dead+=("$(basename "$d")")
done

if [ "${#dead[@]}" -eq 0 ]; then
  echo "Nenhum nbd morto encontrado."
  exit 0
fi

echo "nbd mortos (mapeamento sem processo): ${dead[*]}"
if [ "$APPLY" != "1" ]; then
  echo "[dry-run] use --apply para desconectar."
  exit 0
fi
if [ "$YES" != "1" ]; then
  read -r -p "Desconectar ${dead[*]}? [y/N] " a
  case "$a" in y|Y|yes|YES) ;; *) echo "abortado."; exit 0 ;; esac
fi

python3 - "${dead[@]}" <<'PY'
import fcntl, os, sys

NBD_CLEAR_SOCK = 0xab04
NBD_CLEAR_QUE = 0xab05
NBD_DISCONNECT = 0xab08

for name in sys.argv[1:]:
    dev = "/dev/" + name
    try:
        fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK)
    except OSError as e:
        print(dev, "open:", e)
        continue
    for label, req in (("DISCONNECT", NBD_DISCONNECT),
                       ("CLEAR_QUE", NBD_CLEAR_QUE),
                       ("CLEAR_SOCK", NBD_CLEAR_SOCK)):
        try:
            fcntl.ioctl(fd, req, 0)
            print(dev, label, "ok")
        except OSError as e:
            print(dev, label, "err", e)
    os.close(fd)
PY

echo
echo "OK. Agora reinicie o Docker e recrie o cluster:"
echo "  sudo systemctl restart docker && docker compose up -d"
