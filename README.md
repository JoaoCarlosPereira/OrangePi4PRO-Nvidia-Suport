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
| Video output (X11) | ⚠️ | Works, but **the link drops under heavy GPU load** — see below |
| Dual monitor | ⚠️ | 5120x1440 works, same stability caveat |
| Survives reboot | ✅ | Verified end to end |
| Wayland (GNOME) | ⚠️ | Session runs on the eGPU, but **performance is poor** — cause not yet identified |
| Vulkan | ❓ | Untested |

### ⚠️ Stability: the link drops under load

**This is the most important thing to know before relying on this setup.**

A light desktop is stable. Starting a browser, or anything that creates and
destroys GL objects in bulk, can take the PCIe link down. When that happens the
GPU disappears from the bus and **the whole board freezes** — display, SSH, and
all. Only a hard reset recovers it, and the reset then leaves the GPU wedged
until its PSU is power-cycled.

The captured failure chain:

```
NVRM: _issueRpcAndWait: rpcSendMessage failed with status 0x0000000f for fn 10
NVRM: rpcRmApiFree_GSP: GspRmFree failed: ... status=0x0000000f
nvidia-modeset: ERROR: GPU:0: Failed to query display engine channel state
(EE) NVIDIA(0): Failed to allocate push buffer
(EE) NVIDIA(0): Error recovery failed.  *** Aborting ***
nvidia-modeset: ERROR: GPU:0: Error while waiting for GPU progress   ← forever, every 5 s
```

`0x0000000f` is **`NV_ERR_GPU_IS_LOST` — "GPU lost from the bus"**. The GSP RPC did
not fail because of a driver bug; it failed because the device stopped answering.

**It is a physical problem, not a software one.** The root port's AER status shows
receiver errors:

```
DevSta: CorrErr+
CESta:  RxErr+ BadTLP- BadDLLP- Rollover- Timeout-
```

`RxErr` is a physical-layer error — corrupted symbols on the wire. Measured: after
clearing the sticky bits, **three minutes at idle accumulate zero errors**. The
link is electrically clean when quiet and degrades under traffic. That also
explains the `Speed change timeout` on every boot and the intermittent
enumeration: this link is marginal at Gen1 x1 and cannot train higher.

**The variable is the boot, not the workload.** Establishing this took three
wrong turns, recorded here so nobody repeats them.

Observed across four boots, everything else held constant:

| Boot | State | Result |
|---|---|---|
| A | all peripherals attached | froze opening a settings panel, then a browser |
| B | all peripherals attached | froze on a single `nvidia-smi -q -d PERFORMANCE`, at GPU idle, 11 W |
| C | webcam + mic unplugged | same command clean, 40 probes clean, browser worked |
| D | **everything plugged back in** | **200 probes clean** |

Boot C looked like proof that USB power load was the cause. Boot D refutes it —
the peripherals came back and the link stayed clean. What actually separates A/B
from C/D is a **reset in between**.

The most likely explanation is that **PCIe link training quality varies from boot
to boot**. That fits the rest of this board's behaviour: `Speed change timeout` on
every boot, enumeration that sometimes fails entirely, and a link that never gets
past Gen1 x1. Some boots train a marginal link, and those boots freeze under
traffic; others train a clean one and stay up.

Two hypotheses that were tested and are **not** the cause:

- **ASPM.** Already disabled on both ends of the link. Not it.
- **GPU power transients.** Boot B froze at GPU idle, 11 W, P8, with no load step.
  Not it.
- **USB / total board load.** Refuted by boot D.

What remains is signal integrity that is settled at link-training time: the riser,
its connectors, and how the link happens to equalise on a given boot.

### Check each boot before trusting it

This is the practical consequence. `egpu-link-margin` clears the root port's
correctable-error counter, generates GPU traffic, and stops at the **first**
physical-layer error instead of waiting for the freeze:

```bash
sudo egpu-link-margin        # 40 iterations
sudo egpu-link-margin 200    # tighter
```

Run it after booting. A clean result does not guarantee the boot is good, but a
**dirty** result tells you this boot's link is marginal and heavy GPU use will
likely take the machine down — reboot instead of finding out the hard way.

Use the same probe before and after changing a cable or a riser. Just do not draw
a conclusion from a single observation, the way this README did twice: the failure
is probabilistic, and a reboot confounds every A/B test.

Manually, the same idea:

```bash
sudo setpci -s 00:00.0 0x110.L=0xffffffff        # clear
# ... use the desktop ...
sudo lspci -vv -s 00:00.0 | grep CESta            # RxErr- means clean
```

No software setting fixes signal integrity.

### Wayland

GNOME 50 is **Wayland-only** — upstream removed X11 in GNOME 49, and there is no
`gnome-session-xsession` package. So on this board GNOME means Wayland.

Wayland needs one extra thing that X11 does not: **telling the compositor which
DRM device to use.** The board exposes three:

```
card0  sunxi-drm  SoC display engine
card1  pvrsrvkm   PowerVR GPU -- RENDER ONLY, no KMS
card2  nvidia     the eGPU
```

Left alone, mutter picks the PowerVR and dies:

```
KMS: DRM_IOCTL_MODE_CREATE_DUMB failed: Function not implemented
Failed to lock front buffer on /dev/dri/card1
```

The session comes up black. `files/udev/61-egpu-mutter-primary.rules` fixes it
with the tags mutter itself looks for — `mutter-device-ignore` on the PowerVR and
the SoC engine, `mutter-device-preferred-primary` on the NVIDIA card. After that:

```
Created gbm renderer for '/dev/dri/card2'
GPU /dev/dri/card2 selected primary given udev rule
Added device '/dev/dri/card2' (nvidia-drm) using atomic mode setting.
```

Both heads light up, the compositor uses the real NVIDIA EGL stack
(`libEGL_nvidia`, `libnvidia-eglcore`, `libnvidia-egl-gbm`), and the framebuffers
live in VRAM.

**But it is slow** — visible stutter, especially on cursor movement. That is an
open problem. Ruled out so far, with evidence:

- **Software rendering.** No — the process maps `libEGL_nvidia` and holds
  `/dev/nvidia0`.
- **Missing hardware cursor plane.** No — the device exposes 12 planes: 4 Overlay,
  4 Primary, 4 Cursor, and a cursor plane is bound.
- **Framebuffers in system memory crossing the Gen1 x1 link.** No — VRAM use
  (~82 MiB) matches two 5120x1440 buffers held locally.
- **Two compositors fighting over seat0.** Was a contributor and is fixed, but
  the stutter survives it.

Still unexplained: the GPU never leaves `P8 / 210 MHz` with `utilization 0 %`
while the session stutters, and mutter logs `Failed to initialize accelerated
iGPU/dGPU framebuffer sharing: Not hardware accelerated`. Nobody is busy, so
something is waiting — KMS atomic commit latency over a Gen1 x1 link is the
current suspect, untested.

X11 remains the smooth option. GDM offers both, so the choice is the user's:
pick XFCE (X11) or Ubuntu (GNOME/Wayland) at the login screen.

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

> ### ⚠️ Image v1.0 only — fixed in v1.1
>
> **SSH does not start on first boot.** The sanitisation removed
> `/etc/ssh/ssh_host_*` without arming regeneration, so `sshd` fails and port 22
> stays closed. Everything else boots — `xrdp` on 3389 is reachable.
>
> Recover from a local terminal (or over RDP):
> ```bash
> sudo ssh-keygen -A
> sudo systemctl enable --now ssh
> ```
>
> **The text console also lands on the NVIDIA framebuffer** even though eGPU
> video ships disabled, because the 580 driver defaults to `fbdev=1`. A monitor
> on the GPU then shows only a blinking cursor while the desktop sits on the
> Orange Pi HDMI — indistinguishable from a hang. Fix with:
> ```bash
> echo 'options nvidia_drm modeset=1 fbdev=0' | sudo tee /etc/modprobe.d/egpu-nofbdev.conf
> ```


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
3. **Output selection is automatic.** If a monitor is plugged into the NVIDIA
   card, the desktop and the text console both go there. If not, they stay on the
   Orange Pi HDMI. Nothing to configure.

To re-decide without rebooting — after plugging or unplugging a monitor:

```bash
sudo egpu-video-apply
sudo systemctl restart lightdm
```

Overrides, if you need them:

| Command | Effect |
|---|---|
| `egpu-video-auto` | automatic (default) |
| `egpu-video-enable` | always the NVIDIA card, even with no monitor detected |
| `egpu-video-disable` | always the Orange Pi HDMI |

`egpu-video-enable` exists for KVM switches and monitors that do not assert
hot-plug detect while powered off.

If X fails to come up, a watchdog reverts to the Orange Pi HDMI 75 seconds after
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
| `scripts/` | `egpu-*` helper commands, including `egpu-link-margin` |
| `udev/` | DRM device selection for Wayland compositors |

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
