#!/bin/bash
# Userspace extraction (needs read access to /dev/sdc and /dev/sdc1):
# 32 MiB boot area verbatim, then the ext4 partition as a sparse raw copy of used blocks only.
set -euo pipefail
OUT=/run/media/joao/dados/orangepi-backup/orangepi4pro-egpu-v1.2.img
dd if=/dev/sdc of="$OUT" bs=512 count=65536 status=none
e2image -ra -p -O 33554432 /dev/sdc1 "$OUT" 2>&1 | tail -2
ls -la "$OUT" | awk '{print "apparent:", $5}'; du -h "$OUT" | awk '{print "on disk:", $1}'
echo EXTRACT_DONE
