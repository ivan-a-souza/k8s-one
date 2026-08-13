#!/bin/bash
# rbd-device-watch.sh
# Watches for RBD block devices in the kernel and creates their /dev nodes.
# The Ceph CSI krbd mounter uses `--options noudev`, so the kernel does not
# emit uevents and udevd does not create the device nodes. This helper ensures
# /dev/rbdN exists with the correct dev_t so mkfs/mount can proceed.
set -u

while true; do
  for d in /sys/class/block/rbd[0-9]*; do
    [ -e "$d" ] || continue
    n=$(basename "$d")
    [ -e "/dev/$n" ] && continue
    dev=$(cat "$d/dev" 2>/dev/null)
    [ -z "$dev" ] && continue
    maj=${dev%%:*}
    min=${dev##*:}
    mknod "/dev/$n" b "$maj" "$min" 2>/dev/null
    chmod 660 "/dev/$n" 2>/dev/null
    echo "[rbd-watch] created /dev/$n ($dev)" >> /tmp/rbd-watch.log
  done
  sleep 1
done
