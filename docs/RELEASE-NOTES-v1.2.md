# v1.2 — PCIe Gen2, link tooling, sanitised rebuild

Built 2026-09-07 from the working board with `tools/image/`, verified per
[SECURITY.md](../SECURITY.md).

## What changed since v1.1

- **PCIe link at Gen2 x1 (5.0 GT/s) instead of Gen1.** `user_overlays=egpu-pcie-gen2
  egpu-pcie-highmem`. Measured host↔GPU copy bandwidth doubled (199 → 398 MB/s),
  CUDA passes, `egpu-link-margin` clean over 300 probes, validated on warm and cold
  boots. Gen3 trains but the NVIDIA GSP halts at driver init; see
  [PCIE-LINK-SPEED.md](PCIE-LINK-SPEED.md).
- **New tools in `/usr/local/sbin`:** `egpu-pcie-linkinfo` (read-only link/EQ/LTSSM
  snapshot), `egpu-pcie-retrain` (runtime speed change with MMIO stress, refuses to
  run with the NVIDIA modules loaded), `egpu-pcie-bandwidth` (CUDA copy rate).
- The Gen1 overlay stays in `/boot/overlay-user/` for anyone who needs to fall back:
  edit `user_overlays` in `/boot/orangepiEnv.txt` and power-cycle the GPU.
- Kernel and NVIDIA driver unchanged: `6.6.98-sun60iw2`, 580.142 open modules with
  the non-coherent Arm patch.

## Unchanged from v1.1

Everything in the README applies: `orangepi`/`orangepi` autologin, root locked,
SSH host keys regenerated on first boot, filesystem expands to the card on first
boot, first boot is slow and may land on the wrong output once.

## Files

```
orangepi4pro-egpu.img.xz.part-0   2097152000 bytes
orangepi4pro-egpu.img.xz.part-1   1356302640 bytes
orangepi4pro-egpu.img.xz.sha256   ed10b497b1e20f487aa9db2a4ef6b733c95e3ab79ed090ad259e0222554e1ef5
```

```bash
cat orangepi4pro-egpu.img.xz.part-* > orangepi4pro-egpu.img.xz
sha256sum -c orangepi4pro-egpu.img.xz.sha256
xz -dc orangepi4pro-egpu.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
```

Uncompressed: 14601416704 bytes (13.6 GB root partition + 32 MiB boot area).
