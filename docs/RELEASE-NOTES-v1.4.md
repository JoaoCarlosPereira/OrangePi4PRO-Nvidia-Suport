# v1.4 — everything built in: Gen2, rebuilt kernel and U-Boot, first-boot disk menu

Built 2026-09-08 from the working board with `tools/image/`, verified per
[SECURITY.md](../SECURITY.md). Supersedes v1.3; `install.sh` is no longer needed
after flashing this image.

## What the image carries

- **PCIe Gen2 x1** to the GPU (`egpu-pcie-gen2` + `egpu-pcie-highmem` overlays),
  410/418 MB/s host↔GPU, CUDA verified. Gen3 trains but halts the NVIDIA GSP —
  [PCIE-LINK-SPEED.md](PCIE-LINK-SPEED.md).
- **Rebuilt kernel `6.6.98-sun60iw2`** with the PCIe driver fixes (measured speed
  in the log, proper speed-change wait, NSI cap lifted), built with the vendor's
  toolchain and paired with its own DTB. Vendor kernel and DTB kept as `*.orig`.
- **Rebuilt U-Boot in the boot area** (M.2 rail `dc1sw1`, Type-A VBUS on PB7) and
  in the vendor `.deb` used by `orangepi-config`. Same package is
  `files/uboot/boot_package-dc1sw1.fex`; `egpu-install-uboot spi` puts it in the
  SPI NOR for booting without a microSD.
- **USB-C port in host mode from the kernel** (`egpu-usbc-host` overlay), so a
  root filesystem on a USB-C SSD is found at boot.
- **First-boot menu** (tty1 and desktop dialog): keep running from the card, or
  move the system to a connected disk — USB-C SSD or NVMe — while the card keeps
  `/boot`. Also in the application menu (System → "System disk") with a revert
  option. [BOOT-WITHOUT-SD.md](BOOT-WITHOUT-SD.md).
- All `egpu-*` tools, watchdogs, SSH hardening and upgrade shielding of v1.1–v1.3.

## Unchanged

`orangepi`/`orangepi` autologin, root locked, SSH host keys regenerated on first
boot, filesystem expands on first boot, first boot is slow and may land on the
wrong output once. Card of 16 GB or larger.

## Files

Filled in at publication.
