#!/bin/bash
# Cross-build the 6.6.98-sun60iw2 kernel for Orange Pi 4 Pro on an x86_64 PC,
# exactly the way the working build was made (2026-09-08). Read the notes first.
#
#   bash build-kernel.sh /path/to/egpu-linux /path/to/config-6.6.98-sun60iw2 /path/to/out
#
# Notes that cost a night to learn:
# * The vendor U-Boot is 32-bit: wrap the arm64 Image with `mkimage -A arm`, NOT -A arm64.
#   A legacy image tagged AArch64 is silently rejected by bootm -- the board just never boots.
# * Use the Arm GNU Toolchain 11.2-2022.02 (the vendor's) and disable CONFIG_RELR so the
#   binary stays comparable with the vendor's. Ubuntu's gcc-11 also works, but auto-enables RELR.
# * The GitHub tree (orange-pi-6.6-sun60iw2 @ 8a9be72c9) is NOT the tree that built the
#   shipped kernel: its DTB differs in 648 lines from /boot's. Always ship the kernel with the
#   DTB built from the same tree (arch/arm64/boot/dts/allwinner/sun60i-a733-orangepi-4-pro.dtb).
# * A tree copied from the board carries aarch64 host binaries (scripts/kconfig/conf):
#   `git clean -xdfq` first; `make mrproper` hung on it.
# * LOCALVERSION=-sun60iw2 gives the exact release string, so the NVIDIA/PowerVR modules in
#   /lib/modules/6.6.98-sun60iw2/extra keep loading (no MODVERSIONS, same vermagic).
set -euo pipefail
SRC=${1:?kernel tree}; CFG=${2:?config}; OUT=${3:?output dir}
TC=${TC:-$HOME/kernel-build/toolchain/gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu/bin}
export PATH=$TC:$PATH
M="make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- LOCALVERSION=-sun60iw2"
cd "$SRC"; git clean -xdfq
cp "$CFG" .config; $M olddefconfig; ./scripts/config --disable RELR; $M olddefconfig
[ "$($M -s kernelrelease)" = 6.6.98-sun60iw2 ] || { echo "release string mismatch"; exit 1; }
$M -j"$(nproc)" Image modules allwinner/sun60i-a733-orangepi-4-pro.dtb
mkdir -p "$OUT/stage"; $M -s INSTALL_MOD_PATH="$OUT/stage" INSTALL_MOD_STRIP=1 modules_install
rm -f "$OUT"/stage/lib/modules/*/build "$OUT"/stage/lib/modules/*/source
tar -C "$OUT/stage" -czf "$OUT/modules.tgz" lib
mkimage -A arm -O linux -T kernel -C none -a 0x41000000 -e 0x41000000 -n "Linux kernel" -d arch/arm64/boot/Image "$OUT/uImage"
cp arch/arm64/boot/dts/allwinner/sun60i-a733-orangepi-4-pro.dtb "$OUT/"
ls -la "$OUT"/uImage "$OUT"/modules.tgz "$OUT"/*.dtb
echo "Install on the card: /boot/uImage, /boot/dtb-6.6.98-sun60iw2/allwinner/<dtb>, and lib/modules/6.6.98-sun60iw2/kernel + modules.order, then depmod -b <mount> 6.6.98-sun60iw2. Keep extra/ untouched."
