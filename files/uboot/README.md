# Rebuilt U-Boot boot package

`boot_package-dc1sw1.fex` is the vendor U-Boot (`orangepi-xunlong/u-boot-orangepi`,
branch `v2018.05-sun60iw2`, commit b791be8) rebuilt with two patches and packed
with the vendor tools:

- `pcie3v3_supply = "dc1sw1"` in `arch/arm/dts/board-uboot.dts` — the M.2 slot's
  3.3 V rail. Stock U-Boot switches on `dc1sw2` and never sees an NVMe drive
  ([TblP/orangepi-uboot-fix](https://github.com/TblP/orangepi-uboot-fix)).
- `-Wno-error`, so it builds with a current GCC.

It contains U-Boot itself with its control DTB, `monitor.fex` and `scp.fex`. It
does **not** contain `boot0`; the vendor `boot0` already on your card or SPI NOR
stays in place. Install with `tools/uboot/install-uboot.sh`; rebuild with
`tools/uboot/build-uboot.sh`.

Verified 2026-09-08 on an Orange Pi 4 Pro: boots from the SD boot area and from
the SPI NOR. Note that the public U-Boot tree (March 2026) is older than the
binary Orange Pi ships (July 2026); nothing regressed in our tests, but the July
changes are unknown.
