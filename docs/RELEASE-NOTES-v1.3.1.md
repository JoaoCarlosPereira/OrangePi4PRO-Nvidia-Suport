# v1.3.1 — tooling: rebuilt U-Boot, boot without microSD, system on a fast disk

No new image: flash **v1.3** and run `sudo ./install.sh` from this tag to get
everything below. The v1.3 image assets stay as they are.

## What is new since v1.3

- **U-Boot rebuilt with two board fixes** (`files/uboot/boot_package-dc1sw1.fex`,
  source patch `u-boot-orangepi4pro.patch`, recipe `tools/uboot/build-uboot.sh`):
  the M.2 slot's 3.3 V rail (`dc1sw1`) so NVMe drives are visible to U-Boot, and
  the Type-A ports' VBUS enable (`PB7`, active-low) so USB sticks are powered at
  boot. `install.sh` writes it into the card's boot area and into the vendor
  `.deb` that `orangepi-config` uses; `egpu-install-uboot spi` (or
  `EGPU_UBOOT_SPI=1`) puts it in the SPI NOR.
- **Boot without a microSD**: SPI U-Boot + the system on a USB stick in a
  Type-A port. Verified. [docs/BOOT-WITHOUT-SD.md](BOOT-WITHOUT-SD.md).
- **System on a fast disk while the boot medium keeps `/boot`**:
  `egpu-install-to-disk` (GPT, one ext4 partition, rsync, bind-mounted `/boot`,
  `--revert`), a first-boot menu (tty and desktop dialog with a progress bar),
  and an application-menu entry (System → "System disk"). Verified with a USB-C
  SSD: 182 MB/s writes, PCIe Gen2 and the desktop unchanged, drives shown as
  internal.
- **`egpu-usbc-host` overlay**: the USB-C port is a host from the kernel; the
  vendor DT only switched it 11 s into boot from userspace, which made a root
  filesystem on USB-C impossible.
- **Rebuilt kernel installer** (`egpu-install-kernel`, checksummed, `--restore`)
  for the `kernel-6.6.98-sun60iw2-egpu.tar.gz` asset of v1.3.
- **Phase 1 findings** on Gen3 (the GSP halts on every Gen3 boot; Gen2 is the
  practical ceiling with 580.142) and the survey of other A733 projects in
  `docs/PHASE3-PLAN.md`.

## Files

`boot_package-dc1sw1.fex` (1392640 bytes) is attached for convenience; it is the
same file as in the repository.
