#!/bin/bash
# Install the rebuilt U-Boot boot package (files/uboot/boot_package-dc1sw1.fex) on
# the Orange Pi 4 Pro. Run ON THE BOARD as root.
#
#   install-uboot.sh sd     write it into the boot area of the card the system booted from
#   install-uboot.sh spi    write it into the SPI NOR at 0x40000 (needed to boot without a microSD)
#   install-uboot.sh deb    replace the package inside the vendor u-boot .deb directory, so
#                           `orangepi-config -> System -> Install -> boot from SPI` writes this
#                           U-Boot instead of the stock one
#   install-uboot.sh all    all three
#
# boot0 is never touched. Every write is read back and compared. A dump of the
# previous content is kept next to this script's log in /root/egpu-uboot-backup/.
set -euo pipefail
PKG=${PKG:-$(dirname "$(readlink -f "$0")")/../../files/uboot/boot_package-dc1sw1.fex}
[ -f "$PKG" ] || PKG=/usr/local/share/egpu/boot_package-dc1sw1.fex
[ -f "$PKG" ] || { echo "boot package not found"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
SIZE=$(stat -c %s "$PKG"); SUM=$(sha256sum "$PKG" | cut -d' ' -f1)
BK=/root/egpu-uboot-backup; mkdir -p $BK; TS=$(date +%Y%m%d-%H%M%S)
[ "$SIZE" = 1392640 ] || { echo "unexpected package size $SIZE"; exit 1; }

do_sd() {
    ROOTDEV=$(findmnt -n -o SOURCE /); DISK=$(lsblk -n -o PKNAME "$ROOTDEV" | head -1)
    case $DISK in mmcblk*) ;; *) echo "root is on /dev/$DISK, not a microSD/eMMC; skipping sd"; return;; esac
    dd if=/dev/$DISK of=$BK/sd-bootpkg-$TS.bin bs=8k skip=2050 count=170 status=none
    dd if="$PKG" of=/dev/$DISK bs=8k seek=2050 conv=fsync,notrunc status=none; sync
    [ "$(dd if=/dev/$DISK bs=8k skip=2050 count=170 status=none | head -c $SIZE | sha256sum | cut -d' ' -f1)" = "$SUM" ] && echo "sd: written and verified on /dev/$DISK" || { echo "sd: READBACK MISMATCH"; exit 1; }
}
do_spi() {
    [ -e /dev/mtd0 ] || { echo "no /dev/mtd0"; exit 1; }
    command -v flash_erase >/dev/null && command -v mtd_debug >/dev/null || { echo "install mtd-utils first"; exit 1; }
    dd if=/dev/mtd0ro of=$BK/spinor-full-$TS.bin bs=64k status=none
    flash_erase -q /dev/mtd0 0x40000 22
    mtd_debug write /dev/mtd0 0x40000 $SIZE "$PKG" >/dev/null; sync
    [ "$(dd if=/dev/mtd0ro bs=64k skip=4 count=22 status=none | head -c $SIZE | sha256sum | cut -d' ' -f1)" = "$SUM" ] && echo "spi: written and verified at 0x40000 (boot0 untouched)" || { echo "spi: READBACK MISMATCH -- do not power off, rerun"; exit 1; }
}
do_deb() {
    D=$(ls -d /usr/lib/linux-u-boot-*orangepi4pro* 2>/dev/null | head -1); [ -n "$D" ] || { echo "vendor u-boot directory not found"; exit 1; }
    [ -f $D/boot_package.fex.orig ] || cp $D/boot_package.fex $D/boot_package.fex.orig
    cp "$PKG" $D/boot_package.fex && echo "deb: $D/boot_package.fex replaced (original kept as .orig); orangepi-config will now flash the fixed U-Boot"
}
case ${1:-} in sd) do_sd;; spi) do_spi;; deb) do_deb;; all) do_sd; do_spi; do_deb;; *) sed -n 2,14p "$0"; exit 1;; esac
