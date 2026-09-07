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
| Video output (X11) | ✅ | The stable path. Plasma X11 verified: P0, hardware GL, no flip-event bug |
| Dual monitor | ✅ | 5120x1440 across two heads |
| Survives reboot | ✅ | Verified end to end |
| Wayland (GNOME 50) | ⚠️ | Renders on the eGPU, but a `nvidia_drm` flip-event bug wedges it — see below |
| Wayland (Plasma 6) | ⚠️ | Same driver bug applies |
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

Wayland works — GNOME 50 and Plasma 6 both render on the eGPU. Getting there
needed two things that are easy to miss.

**1. The GBM backend is missing from Ubuntu's arm64 packaging.** This was the real
blocker. `libnvidia-gl-580` ships 24 libraries and omits `libnvidia-allocator`,
which is NVIDIA's GBM backend. Without it `libgbm` falls through to Mesa's
`dri_gbm.so`, which has no driver for `10de:2584`:

```
libEGL warning: pci id for fd 15: 10de:2584, driver (null)
libEGL warning: egl: failed to create dri2 screen
```

The library exists in NVIDIA's official aarch64 installer at the matching
version. See **[files/nvidia-extra/README.md](files/nvidia-extra/README.md)** for
the recipe — it is proprietary, so it is not committed here.

> **A wrong turn worth recording.** Before this was found, KWin reported
> `Pageflip timed out! This is a bug in the nvidia-drm kernel driver` — 41 times.
> That was read as a second, deeper, probably unfixable problem. It was not: with
> the GBM backend in place the timeouts went to **zero**. A clear error message
> from good software is still a hypothesis, not a diagnosis.

**2. Compositors must be told which DRM device to use.** The board exposes three:

```
card0  sunxi-drm  SoC display engine
card1  pvrsrvkm   PowerVR GPU -- RENDER ONLY, no KMS
card2  nvidia     the eGPU
```

Left alone, mutter picks the PowerVR and dies with
`DRM_IOCTL_MODE_CREATE_DUMB failed: Function not implemented`. Each compositor
reads a different mechanism, so both are pre-installed:

| Compositor | Mechanism | Shipped as |
|---|---|---|
| mutter / GNOME | udev tags `mutter-device-ignore` / `mutter-device-preferred-primary` | `files/udev/61-egpu-mutter-primary.rules` |
| KWin / Plasma | `KWIN_DRM_DEVICES` | `files/plasma/egpu.sh` |
| wlroots (sway, …) | `WLR_DRM_DEVICES` | not shipped — set it to `/dev/dri/card2` |

Both are applied in the image even when the matching desktop is not installed, so
whichever you add later already finds the ground prepared.

**3. A Wayland greeter cannot get GPU access on this kernel.** GDM 50 runs its
greeter as a **transient user** with a dynamic uid and no supplementary groups,
so group membership cannot help it — and with `CONFIG_TMPFS_POSIX_ACL` absent
from this kernel, `uaccess` cannot either. The greeter dies with:

```
libEGL warning: failed to open /dev/dri/renderD129: Permission denied
Failed to setup: The GPU /dev/dri/card2 chosen as primary is not supported by EGL.
```

`files/udev/62-egpu-drm-access.rules` opens the DRM nodes to `0666`. It is a
trade-off — any local user can then open the GPU — and the correct fix is a
kernel rebuild with `CONFIG_TMPFS_POSIX_ACL=y`. SDDM never hit this because its
greeter is X11 and Xorg runs as root.

Also required, and all handled: `nvidia_drm modeset=1 fbdev=0`, membership in the
**`render`** group for human *and* display-manager users, and `rtkit` so mutter
can prioritise its KMS thread.

### The Wayland ceiling: a flip-event bug in `nvidia_drm`

Wayland renders correctly and looks right, but a session under real use wedges.
This is the deepest root cause found, and it is a **driver bug**, not
configuration:

```
WARNING: CPU: 6 PID: 773 at kernel-open/nvidia-drm/nvidia-drm-crtc.h:335
         __nv_drm_handle_flip_event+0x188/0x194 [nvidia_drm]
 nv_drm_handle_flip_occurred     [nvidia_drm]
 nv_drm_event_callback           [nvidia_drm]
 nvKmsKapiHandleEventQueueChange [nvidia_modeset]
```

The line it fires on, in `nv_drm_crtc_dequeue_flip()`:

```c
if (WARN_ON(nv_flip == NULL) || pending_events) {
```

**The driver receives more page-flip completion events than the flips it
enqueued.** The dequeue finds an empty list. Observed **245 times** in one
session, after which `nvidia-smi` reports `[GPU requires reset]`,
`nvidia-modeset/kthread_q` starts spinning, and the compositor hangs. Recovery
needs a reboot *and* a mains power cycle of the GPU's PSU.

Ruled out: spurious interrupts. MSI is correctly in use (`SUNXI-PCIe-MSI`,
`Enable+`, `NVreg_EnableMSI=1`) with zero unhandled interrupts.

**Leading hypothesis.** On Ampere, display events arrive from the GSP firmware
through a queue in system memory that the GPU writes by DMA. This platform is
**non-coherent**. Without correct cache invalidation on that queue the driver can
read stale entries and process the same event twice — exactly this symptom. And
the gap is verifiable: **none of the five non-coherence patches touch
`nvidia-drm`, `nvidia-modeset` or the `kapi` path.** They cover the RM and the
GSP message queue, which is why compute is rock solid and display is not.

Fixing it means extending cache maintenance into the KMS event path. It is also
worth reporting upstream — it is NVIDIA's own `WARN_ON`, firing on a
non-coherent Arm platform.

**Until then: X11 is the reliable path.** The NVIDIA X11 driver does not go
through `nv_drm_handle_flip_event`.

### Slow shutdown

Tearing down a graphical session can wedge the GPU, and shutdown then crawls:

```
NVRM: Going over RM unhandled interrupt threshold for irq 153
nvidia-modeset: ERROR: GPU:0: Error while waiting for GPU progress: 0x0000c67d
NVRM: krcWatchdog_IMPL: RC watchdog: GPU is probably locked! Notify Timeout Seconds: 7
```

The errors start about twenty seconds before `shutdown.target`, while the display
manager is stopping. The RC watchdog then charges 7 s per occurrence and the
machine can hang after `systemd-shutdown` sends its final `SIGTERM`.

`egpu-display-unload.service` mitigates it by unloading `nvidia_drm` and
`nvidia_modeset` while the GPU still answers. It is ordered `Before=` the display
manager, which means it stops **after** it — the moment we want. `nvidia` itself
is left loaded; it serves compute and takes longer to release.

**Mitigation, not a fix.** If the GPU is already wedged by the time it runs, the
`rmmod` can block too, which is why the unit carries `TimeoutStopSec=25`: the
worst case is the behaviour you already had, never worse. The underlying problem
— display teardown wedging the GPU — is unresolved and is likely the same fault
behind the hard freezes.

### Micro-stutter: RealtimeKit

If the desktop stutters while the GPU is clearly working, check for this:

```
gnome-shell: Failed to make thread 'KMS thread' high priority scheduled:
             Name "org.freedesktop.RealtimeKit1" does not exist
```

The image ships without `rtkit`, so mutter cannot give its KMS thread real-time
priority and page-flip timing gets preempted by ordinary work. `pipewire`
complains about the same absence. Install it and start a fresh session:

```bash
sudo apt install rtkit
sudo systemctl enable --now rtkit-daemon
```

Locking the GPU clocks does **not** substitute for this — the frames were not slow
to render, they were late to be scheduled.

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
