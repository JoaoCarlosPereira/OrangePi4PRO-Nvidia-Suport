# v1.3 — PCIe Gen2, rebuilt kernel, link tooling

Built 2026-09-08 from the working board with `tools/image/`, verified per
[SECURITY.md](../SECURITY.md). v1.2 was built but never published; this release
supersedes it.

## What changed since v1.1

- **PCIe link at Gen2 x1 (5.0 GT/s) instead of Gen1.** `user_overlays=egpu-pcie-gen2
  egpu-pcie-highmem`. Host↔GPU copy bandwidth 410/418 MB/s (was 199), CUDA passes,
  `egpu-link-margin` clean, validated on warm and cold boots. Gen3 trains but the
  NVIDIA GSP halts at driver init; see [PCIE-LINK-SPEED.md](PCIE-LINK-SPEED.md).
- **Rebuilt kernel `6.6.98-sun60iw2`** with the PCIe driver fixes in
  `files/patches/`: the log reports the measured link speed, a Gen3 speed change
  gets enough time, and the NSI bandwidth limiter no longer caps transfers at the
  per-gen value. Built with the vendor's Arm GNU Toolchain 11.2-2022.02; the DTB
  comes from the same source tree (see `tools/kernel/build-kernel.sh` for why).
  The NVIDIA 580.142 modules and the PowerVR module are unchanged and load as
  before. The vendor kernel and DTB stay on the card as `uImage.orig` and
  `sun60i-a733-orangepi-4-pro.dtb.orig`.
- **New tools in `/usr/local/sbin`:** `egpu-pcie-linkinfo`, `egpu-pcie-retrain`,
  `egpu-pcie-bandwidth`.
- The Gen1 overlay stays in `/boot/overlay-user/` for anyone who needs to fall back.

## Unchanged from v1.1

`orangepi`/`orangepi` autologin, root locked, SSH host keys regenerated on first
boot, filesystem expands on first boot, first boot is slow and may land on the
wrong output once. The U-Boot in the image's boot area is the vendor's; the
rebuilt U-Boot with the M.2 power-rail fix is documented separately in
[PHASE3-PLAN.md](PHASE3-PLAN.md) and is not part of this image.

## Files

Filled in at publication.
