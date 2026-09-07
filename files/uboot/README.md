# Rebuilt U-Boot boot package

`boot_package-dc1sw1.fex` is the vendor U-Boot (`orangepi-xunlong/u-boot-orangepi`,
branch `v2018.05-sun60iw2`, commit b791be8) rebuilt with two patches and packed
with the vendor tools:

- `pcie3v3_supply = "dc1sw1"` in `arch/arm/dts/board-uboot.dts` — the M.2 slot's
  3.3 V rail. Stock U-Boot switches on `dc1sw2` and never sees an NVMe drive
  ([TblP/orangepi-uboot-fix](https://github.com/TblP/orangepi-uboot-fix)).
- `-Wno-error`, so it builds with a current GCC.
- **USB VBUS for the two Type-A ports**: `CONFIG_USB1_VBUS_PIN="PB7"` with an
  active-low enable (`CONFIG_USB1_VBUS_ACTIVE_LOW`). Stock U-Boot drives
  reference-board pins (`PL5`/`PL6`) high, so the Type-A ports have no power
  during U-Boot and `usb start` never finds a drive. The pin comes from the
  kernel DTS (`usb1-vbus`, `PB7 GPIO_ACTIVE_LOW`). This is the fix that makes
  booting from USB possible on this board.

All three changes are in `u-boot-orangepi4pro.patch`, which `tools/uboot/build-uboot.sh`
applies. The package contains U-Boot itself with its control DTB, `monitor.fex` and `scp.fex`. It
does **not** contain `boot0`; the vendor `boot0` already on your card or SPI NOR
stays in place. Install with `tools/uboot/install-uboot.sh`; rebuild with
`tools/uboot/build-uboot.sh`.

Verified 2026-09-08 on an Orange Pi 4 Pro: boots from the SD boot area, from the
SPI NOR, and — with no microSD present — brings the system up from a USB stick in
a Type-A port (`docs/BOOT-WITHOUT-SD.md`). Note that the public U-Boot tree (March 2026) is older than the
binary Orange Pi ships (July 2026); nothing regressed in our tests, but the July
changes are unknown.
