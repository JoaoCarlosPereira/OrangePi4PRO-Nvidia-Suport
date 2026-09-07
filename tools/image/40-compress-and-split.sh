#!/bin/bash
# xz the sanitised image; publish under the generic names the README's download
# instructions use (orangepi4pro-egpu.img.xz.part-*, orangepi4pro-egpu.img.xz.sha256).
set -euo pipefail
cd /run/media/joao/dados/orangepi-backup
IMG=orangepi4pro-egpu-v1.2.img; REL=release-v1.2; GEN=orangepi4pro-egpu.img.xz
xz -T4 -9 -k -f "$IMG"
sha256sum "$IMG.xz" > "$IMG.xz.sha256"
mkdir -p $REL; rm -f $REL/*
split -b 2000M -d -a 1 "$IMG.xz" "$REL/$GEN.part-"
sed "s| .*| $GEN|" "$IMG.xz.sha256" > "$REL/$GEN.sha256"
( cd $REL && sha256sum "$GEN.part-"* > "$GEN.parts.sha256" )
ls -la "$IMG.xz" $REL/ | awk 'NF>=9{print $5, $9}'; cat "$REL/$GEN.sha256"
echo COMPRESS_DONE
