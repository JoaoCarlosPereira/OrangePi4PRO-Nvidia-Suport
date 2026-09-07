#!/bin/bash
# Install the rebuilt 6.6.98-sun60iw2 kernel on the Orange Pi 4 Pro. Run ON THE BOARD as root.
#
#   install-kernel.sh /path/to/kernel-6.6.98-sun60iw2-egpu.tar.gz   install (originals kept as *.orig)
#   install-kernel.sh --restore                                     put the vendor kernel, DTB and modules back
#
# The tarball is a release asset of this repository. It carries uImage (already wrapped
# with `mkimage -A arm`, which this 32-bit U-Boot requires), the DTB built from the same
# source tree (the two must go together), and the in-tree modules. The NVIDIA and PowerVR
# modules in /lib/modules/<ver>/extra are not touched: same version string, same vermagic.
set -euo pipefail
KV=6.6.98-sun60iw2; D=/boot/dtb-$KV/allwinner; DTB=sun60i-a733-orangepi-4-pro.dtb
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
[ "$(uname -r)" = "$KV" ] || { echo "running kernel is $(uname -r), this package is for $KV"; exit 1; }
if [ "${1:-}" = "--restore" ]; then
    [ -f /boot/uImage.orig ] || { echo "no /boot/uImage.orig to restore"; exit 1; }
    cp /boot/uImage.orig /boot/uImage; cp $D/$DTB.orig $D/$DTB
    tar -C /lib/modules -xzf /root/modules-$KV.orig.tgz; depmod -a $KV; sync
    echo "vendor kernel, DTB and modules restored; reboot"; exit 0
fi
TAR=${1:?tarball}; T=$(mktemp -d); tar -C "$T" -xzf "$TAR"; S=$(ls -d "$T"/kernel-*)
( cd "$S" && sha256sum -c --quiet SHA256SUMS ) || { echo "checksum mismatch inside tarball"; exit 1; }
[ -f /boot/uImage.orig ] || cp /boot/uImage /boot/uImage.orig
[ -f $D/$DTB.orig ] || cp $D/$DTB $D/$DTB.orig
[ -f /root/modules-$KV.orig.tgz ] || tar -C /lib/modules -czf /root/modules-$KV.orig.tgz $KV
mkdir -p "$T/m" && tar -C "$T/m" -xzf "$S/modules.tgz"
rm -rf /lib/modules/$KV/kernel; cp -a "$T/m/lib/modules/$KV/kernel" /lib/modules/$KV/; cp -a "$T/m/lib/modules/$KV/modules.order" /lib/modules/$KV/
depmod -a $KV
cp "$S/uImage" /boot/uImage; cp "$S/$DTB" $D/$DTB; sync; rm -rf "$T"
echo "installed: $(stat -c %s /boot/uImage)-byte uImage, DTB $(stat -c %s $D/$DTB) bytes, extra modules: $(ls /lib/modules/$KV/extra | tr '\n' ' ')"
echo "reboot to use it; '$0 --restore' undoes it"
