# NVIDIA GPU support on the Orange Pi 4 Pro

Running an **NVIDIA RTX 3050 as an external GPU on an Orange Pi 4 Pro**
(Allwinner A733, ARM64) — with CUDA *and* working video output.

Both monitors below are driven by the 3050, on a board whose SoC vendor never
intended to talk to a discrete GPU, using a driver NVIDIA has not qualified for
this platform.

```
Screen 0: current 5120 x 1440
HDMI-0 connected 2560x1440+2560+0
HDMI-1 connected 2560x1440+0+0
OpenGL renderer string: NVIDIA GeForce RTX 3050/PCIe
OpenGL version string:  4.6.0 NVIDIA 580.142
```

---

## Status

| Capability | State | Notes |
|---|---|---|
| PCIe enumeration | ✅ | Gen1 x1 — requires a device tree overlay |
| CUDA / compute | ✅ | Validated: context, VRAM transfers, sm_86 kernel |
| `nvidia-smi` | ✅ | Reports the GPU and all 6144 MiB |
| Video output (X11) | ✅ | 2560x1440 @ 144 Hz, hardware GL |
| Dual monitor | ✅ | 5120x1440 across two heads |
| Survives reboot | ✅ | Verified end to end |
| Wayland | ❓ | Untested |
| Vulkan | ❓ | Untested |

### Performance ceiling

The link trains at **2.5 GT/s x1** — about 2 Gb/s, against the 252 Gb/s the card
is capable of:

```
2.000 Gb/s available PCIe bandwidth, limited by 2.5 GT/s PCIe x1 link
(capable of 252.048 Gb/s with 16.0 GT/s PCIe x16 link)
```

This is the A733's PCIe controller, not a configuration mistake. Desktop use and
video playback are fine. Anything that streams large buffers across the bus every
frame will be bottlenecked. Scanout itself is not affected — the display engine
reads the framebuffer from VRAM locally.

---

## Hardware

| | |
|---|---|
| Board | Orange Pi 4 Pro (Allwinner A733) |
| RAM | 12 GB |
| OS | Ubuntu 26.04 "Resolute" / Orange Pi 1.1.0 |
| Kernel | 6.6.98-sun60iw2 (vendor BSP) |
| GPU | MSI GeForce RTX 3050 6 GB (GA107, `10de:2584`) |
| Driver | NVIDIA 580.142 open kernel modules, **patched** |
| GPU power | External ATX PSU |

The GPU needs its own power supply. The Orange Pi cannot feed a discrete card.

---

## Two ways to use this

### 1. Flash the prebuilt image

The fastest path. See [releases](../../releases). The image behaves like any
official Orange Pi image: flash it, boot, and the filesystem expands to fill your
card automatically.

**Requirements:** a card of **17 GB or larger**, and an NVIDIA Ampere GPU on a
powered PCIe riser.

GitHub caps release assets at 2 GB, so the image ships split. Rejoin, verify, and
flash:

```bash
cat orangepi4pro-egpu.img.xz.part-* > orangepi4pro-egpu.img.xz
sha256sum -c orangepi4pro-egpu.img.xz.sha256

xz -dc orangepi4pro-egpu.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
sync
```

Replace `/dev/sdX` with your card — **check it twice with `lsblk`**, `dd` will
happily overwrite the wrong disk. Balena Etcher also works and takes the `.img.xz`
directly.

**First boot:**

1. The root filesystem expands to fill the card (this can add up to a minute).
2. You will be asked to set a new password and create your user.
3. Video output through the GPU starts **disabled**, because the image has to boot
   on machines that have no GPU attached. Turn it on once you are logged in:

```bash
sudo egpu-video-check     # confirm the GPU and its connectors are seen
sudo egpu-video-enable    # switch X to the NVIDIA card
sudo systemctl restart lightdm
```

If X fails to come up, a watchdog reverts to the Allwinner HDMI 75 seconds after
boot — you will not be locked out.

> **What the image contains:** the patched NVIDIA 580.142 modules, the driver and
> kernel source trees used to build them, the device tree overlays, and all the
> `egpu-*` tooling. No personal data — see [SECURITY.md](SECURITY.md).

### 2. Build it yourself

Follow **[docs/TUTORIAL.md](docs/TUTORIAL.md)**. It covers the device tree
overlays, the driver patches, building the modules, and the Xorg configuration,
in the order they need to happen.

---

## Why this needs patches at all

NVIDIA's driver assumes a coherent, PCIe-conformant host. The A733 is neither in
the ways that matter:

- **No IOMMU** for the PCIe device — the GPU DMAs to physical addresses directly.
- **`dma-coherent` is absent** from the device tree node. I/O is non-coherent, so
  DMA buffers need explicit cache maintenance that the stock driver never performs.
- **The chipset is unknown to the driver.** `NVRM: Chipset not recognized (vendor
  ID 0x1f6d, device ID 0xabcd)`, followed by *"The NVIDIA GPU driver for AArch64
  has not been qualified on this platform"*.

The patch series that makes compute work is
[Mario Bălănică's non-coherent Arm work](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/972)
(PR #972 against `open-gpu-kernel-modules`). Full credit for the hard part of this
belongs there. This repository is about getting that driver to also drive displays
on this specific board, and about the surrounding plumbing that keeps it stable.

---

## What is in `files/`

| Path | Purpose |
|---|---|
| `overlays/` | Device tree overlays for PCIe Gen1 and the high-memory aperture |
| `xorg/` | Xorg layout that pins X to the NVIDIA card |
| `modprobe/` | Module options |
| `systemd/` | Boot-time services: PCIe recovery, conditional apply, watchdog |
| `scripts/` | `egpu-*` helper commands |

Every one of these is explained in the tutorial. Do not copy them blindly — the
PCIe addresses come from the A733 manual and are board-specific.

---

## Troubleshooting

If something does not work, read **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**
before anything else. It documents the real failure modes, how to tell them apart,
and — just as usefully — **four hypotheses that look right and are wrong**. Each
one cost hours before being disproven.

The single most valuable thing in that document: *"no signal"* and *"black screen"*
are completely different diagnoses. Do not conflate them.

---

## Known limitations

- **PCIe enumeration is intermittent.** Some boots the endpoint simply does not
  appear. A retry service handles most cases; occasionally the GPU's PSU has to be
  power-cycled at the mains.
- **A warm reset of the SoC wedges the GPU.** It stays powered and half-initialised
  and then refuses to train the link, no matter how many controller rebinds you
  issue. Only cutting power to the card recovers it.
- **No Plymouth splash.** Module loading was deliberately moved late in boot, so
  there is no NVIDIA framebuffer when Plymouth starts. Explained in the tutorial.
- **Kernel and driver are version-pinned.** The modules are built for exactly
  6.6.98-sun60iw2 and 580.142. Upgrading either breaks the pair.

---

## Credits

- **Mario Bălănică** — the non-coherent Arm DMA patches, without which none of
  this works.
- NVIDIA — `open-gpu-kernel-modules`.
- The Armbian project — `orangepi-resize-filesystem` and the surrounding image
  tooling.

## License

Documentation and scripts here: MIT. The NVIDIA driver source and its patches keep
their own licenses.
