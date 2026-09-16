#!/bin/bash
# rbd-nbd-reaper.sh
# Reaps orphaned rbd-nbd mappings on the node.
#
# The ceph-block StorageClass uses mounter=rbd-nbd (krbd cannot reach the mon
# from inside the k8s-one container). rbd-nbd mappings live in the kernel/host
# and can survive pod/plugin restarts; cephcsi's healer then fails with
# "missing stash" / "rbd-nbd: cookie mismatch" / "is still being used", leaving
# PVCs stuck in ContainerCreating.
#
# A mapping is orphaned when its volumeHandle has NO VolumeAttachment in
# Attached=true state for this node — the same signal cephcsi uses to decide
# which volumes must be staged. To avoid acting on a transient API hiccup, a
# mapping must be continuously orphaned for >= RBD_REAPER_GRACE seconds.
#
# Unmap = SIGTERM to the rbd-nbd pid (what `rbd-nbd unmap` does underneath).
set -u

NODE_NAME="${NODE_NAME:-k8s-one}"
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
DRY_RUN="${RBD_REAPER_DRY_RUN:-1}"
GRACE="${RBD_REAPER_GRACE:-300}"
INTERVAL="${RBD_REAPER_INTERVAL:-30}"
LOG="${RBD_REAPER_LOG:-/tmp/rbd-reaper.log}"
STATE="${RBD_REAPER_STATE:-/tmp/rbd-reaper.state}"
ONESHOT=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --apply)        DRY_RUN=0 ;;
    --oneshot)      ONESHOT=1 ;;
    --grace=*)      GRACE="${arg#*=}" ;;
    --interval=*)   INTERVAL="${arg#*=}" ;;
  esac
done

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG"; }
kc() { kubectl --kubeconfig="$KUBECONFIG" "$@"; }

# Print the volumeHandles that must be attached to this node (one per line).
attached_volumes() {
  local pv_map va_pvs
  pv_map=$(kc get pv -o go-template='{{range .items}}{{if .spec.csi}}{{.metadata.name}} {{.spec.csi.volumeHandle}}{{"\n"}}{{end}}{{end}}' 2>/dev/null) || return 1
  [ -n "$pv_map" ] || return 1
  va_pvs=$(kc get volumeattachments -o go-template='{{range .items}}{{if and (eq .spec.nodeName "'"$NODE_NAME"'") .status.attached}}{{.spec.source.persistentVolumeName}}{{"\n"}}{{end}}{{end}}' 2>/dev/null) || return 1

  local pv vh
  while read -r pv; do
    [ -n "$pv" ] || continue
    vh=$(printf '%s\n' "$pv_map" | awk -v p="$pv" '$1==p{print $2}')
    [ -n "$vh" ] && echo "$vh"
  done <<< "$va_pvs"
}

# Resolve the rbd-nbd pid for a volumeHandle.
# NOTE: /sys/block/nbdN/pid holds the pid in the *initial* (outer host) PID
# namespace, which does not exist inside the k8s-one container. We instead find
# the process in our own /proc whose cmdline carries the volumeHandle/cookie.
find_rbd_nbd_pid() {
  local vol="$1" f p
  for f in /proc/[0-9]*/comm; do
    [ "$(cat "$f" 2>/dev/null)" = "rbd-nbd" ] || continue
    p=$(basename "$(dirname "$f")")
    if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$vol"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

reap_cycle() {
  if ! kc get --raw=/readyz >/dev/null 2>&1; then
    log "WARN: API not ready; skipping cycle"
    return 0
  fi

  local attached
  attached=$(attached_volumes) || { log "WARN: could not query VAs/PVs; skipping cycle"; return 0; }

  local now dev backend pid
  now=$(date +%s)
  local -A orphan_now=()
  for dev in /sys/block/nbd[0-9]*; do
    [ -e "$dev" ] || continue
    backend=$(cat "$dev/backend" 2>/dev/null)
    [ -n "$backend" ] || continue
    if printf '%s\n' "$attached" | grep -qxF "$backend"; then
      continue
    fi
    orphan_now["$backend"]="$dev"
  done

  # Load previous orphan state (volID -> first-seen epoch)
  local -A first_seen=()
  if [ -f "$STATE" ]; then
    while read -r v t; do [ -n "${v:-}" ] && first_seen["$v"]="$t"; done < "$STATE"
  fi

  : > "$STATE"
  local fs dur
  for backend in "${!orphan_now[@]}"; do
    dev="${orphan_now[$backend]}"
    fs="${first_seen[$backend]:-$now}"
    echo "$backend $fs" >> "$STATE"
    dur=$(( now - fs ))
    [ "$dur" -lt "$GRACE" ] && continue

    pid=$(find_rbd_nbd_pid "$backend" || true)
    [ -n "$pid" ] || continue

    if [ "$DRY_RUN" = "1" ]; then
      log "DRY-RUN would unmap $(basename "$dev") volID=$backend pid=$pid orphan_for=${dur}s"
    else
      log "unmapping $(basename "$dev") volID=$backend pid=$pid orphan_for=${dur}s"
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
}

log "reaper starting (node=$NODE_NAME dry_run=$DRY_RUN grace=${GRACE}s interval=${INTERVAL}s)"
while true; do
  reap_cycle
  [ "$ONESHOT" = "1" ] && break
  sleep "$INTERVAL"
done
log "reaper exiting"
