#!/bin/bash
# Rebuild and pack the vendor U-Boot for Orange Pi 4 Pro on an x86_64 PC (Ubuntu/Debian).
# Produces boot_package.fex. Needs: gcc-arm-linux-gnueabi, git, busybox, python3, and a
# checkout of orangepi-xunlong/orangepi-build for the x86 pack tools and the boot0/monitor/scp blobs.
set -euo pipefail
W=${1:-$HOME/uboot-build}; mkdir -p "$W"; cd "$W"
[ -d u-boot-orangepi ] || git clone --depth 1 --branch v2018.05-sun60iw2 https://github.com/orangepi-xunlong/u-boot-orangepi.git
[ -d orangepi-build ] || git clone --depth 1 https://github.com/orangepi-xunlong/orangepi-build.git
cd u-boot-orangepi
# -Wno-error (modern GCC), pcie3v3_supply=dc1sw1 (M.2 rail), USB1 VBUS on PB7 active-low (Type-A ports)
git checkout -q -- . && patch -p1 < "$(dirname "$(readlink -f "$0")")/../../files/uboot/u-boot-orangepi4pro.patch"
make sun60iw2p1_t736_defconfig CROSS_COMPILE=arm-linux-gnueabi- >/dev/null
make -j"$(nproc)" CROSS_COMPILE=arm-linux-gnueabi- >/dev/null 2>&1 || true   # the final `cp` to / fails harmlessly
[ -f u-boot.bin ] && [ -f dts/dt.dtb ] || { echo "u-boot build failed"; exit 1; }
grep -q 'pcie3v3_supply = "dc1sw1"' u-boot-dtb.dts || { echo "rail fix missing from control DTB"; exit 1; }
# pack: the control DTB is the one U-Boot built (dts/dt.dtb), NOT orangepi-build's u-boot-current.dts
P="$W/pack"; B="$W/orangepi-build/external/packages/pack-uboot"; rm -rf "$P"; mkdir -p "$P"; cd "$P"
cp -r $B/sun60iw2/bin/* .; cp sys_config/sys_config.fex sys_config.fex; cp "$W/u-boot-orangepi/u-boot.bin" u-boot.fex; cp "$W/u-boot-orangepi/dts/dt.dtb" sunxi.fex
busybox unix2dos sys_config.fex; $B/tools/script sys_config.fex >/dev/null
$B/tools/update_dtb sunxi.fex 4096 >/dev/null; $B/tools/update_uboot -no_merge u-boot.fex sys_config.bin >/dev/null
busybox unix2dos boot_package.cfg; $B/tools/dragonsecboot -pack boot_package.cfg >/dev/null
ls -la boot_package.fex; sha256sum boot_package.fex
echo "SD boot area: dd if=boot_package.fex of=/dev/mmcblkX bs=8k seek=2050 ; SPI NOR: flash_erase /dev/mtd0 0x40000 22 && mtd_debug write /dev/mtd0 0x40000 $(stat -c %s boot_package.fex) boot_package.fex"
