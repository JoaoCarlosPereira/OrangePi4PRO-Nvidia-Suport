# RTX 3050 on Orange Pi 4 Pro

Hardware: MSI RTX 3050 6GB, 10de:2584, Allwinner A733, kernel 6.6.98-sun60iw2.

Validated:
- Gen1 overlay enables enumeration (boot remains intermittent).
- High-memory overlay adds 512 MiB at CPU/PCI 0x440000000, within the A733 v0.92 manual PCIe slave aperture 0x440000000-0x53fffffff.
- Rebinding the empty PCIe controller recovered enumeration after the high-memory boot.
- BAR1 allocated 0x440000000-0x44fffffff; BAR3 0x450000000-0x451ffffff.
- No NVIDIA driver loaded yet; allocation does not prove MMIO/DMA functionality.
- NVIDIA 580.142 open kernel modules patched for non-coherent Arm are installed
  under /lib/modules/6.6.98-sun60iw2/extra.
- nvidia-smi identifies the RTX 3050 and all 6144 MiB of VRAM.
- nvidia_uvm is operational without pageable-memory integration because the
  vendor kernel lacks CONFIG_MMU_NOTIFIER.
- /home/orangepi/egpu-cuda-test.py verifies context creation, VRAM transfers,
  execution of an sm_86 kernel, synchronization, and correct returned data.
- Final reboot tested the automatic PCIe recovery and module loading.

Recovery used while PCI bus contained ONLY the root port and no endpoint drivers:
```
echo 6000000.pcie > /sys/bus/platform/drivers/sunxi-pcie/unbind
echo 6000000.pcie > /sys/bus/platform/drivers/sunxi-pcie/bind
```
Do not run this blindly with an active GPU or other PCI devices.

Installed recovery service: /etc/systemd/system/egpu-pcie-recover.service
Installed recovery command: /usr/local/sbin/egpu-pcie-recover
Module load configuration: /etc/modules-load.d/egpu-nvidia.conf

Patched driver source and local commit history:
/home/orangepi/egpu-nvidia-580.142-full (branch egpu-a733-580.142).

Boot rollback: restore /boot/orangepiEnv.txt.before-egpu-highmem to /boot/orangepiEnv.txt to retain Gen1 only. The before-egpu-gen1 backup restores the original configuration. Reboot after restoring.

Kernel source: /home/orangepi/egpu-linux, upstream orange-pi-6.6-sun60iw2, commit 8a9be72c9006a87f786736b3aa4e2dfd971c1429. Running config: /boot/config-6.6.98-sun60iw2. No installed headers, CONFIG_MODVERSIONS disabled. Running kernel compiled with GCC 11.2.1.


## Video output (2026-09-05) -- WORKING

The RTX 3050 drives the desktop. Xorg runs entirely on the GPU, 2560x1440 @ 144 Hz
over HDMI to a Samsung Odyssey G5, with hardware GL:

```
(==) ServerLayout "egpu-layout"
(II) Loading /usr/lib/aarch64-linux-gnu/nvidia/xorg/nvidia_drv.so
(II) NVIDIA GLX Module  580.142
(II) NVIDIA(0): Setting mode "DFP-2:nvidia-auto-select"
OpenGL renderer string: NVIDIA GeForce RTX 3050/PCIe
OpenGL version string: 4.6.0 NVIDIA 580.142
```
Zero (EE) in the log. Xorg sits in Ssl+ at single-digit CPU and answers xdpyinfo.

### What actually unblocked it

Swapping the monitor to a different physical port on the card. Before that the
panel reported "no signal"; after, it reported a black screen -- i.e. TMDS was
being driven -- and every subsequent test passed. Nothing in software changed
between those two states. Suspect a bad port, a bad cable seat, or a connector
that needs a fresh HPD cycle after the GPU has been power-cycled.

### Hypotheses tested and DISPROVEN along the way

Recording these so they are not re-investigated:

- *Display pushbuffer not readable by the GPU over DMA.* False. Compute channels
  use pushbuffers in system memory too, and CUDA works, so GPU->sysmem DMA is fine.
- *The high PCIe outbound window is unmapped (ATU bug).* False. Proven by mapping
  a spare outbound ATU region (index 4) from CPU 0x460000000 to PCI 0x22000000 and
  reading BAR0 through it: identical values to the direct low-window read.
- *The ATU upper-limit register at DBI+0x300020 is required for >4 GB windows.*
  False. A/B test: clearing it to 0 does not break the mapping. The driver writing
  only lower_32_bits() of the limit is harmless here.
- *BAR1 is dead.* Inconclusive, and not the problem. Raw reads of BAR1 offset 0
  return zeros because BAR1 is an MMU-translated window into VRAM; nothing is
  mapped there until the driver maps it. Do not use raw BAR1 pokes as a health test.

### How the display path was actually verified

Write to /dev/fb0 and read back. With nvidia_drm modeset=1 fbdev=1 the framebuffer
is 2560x1440, stride 10240, 32 bpp, and CPU writes land in VRAM and read back
intact. Drawing colour bars plus a one-pixel marker at (1280,720) confirmed the
mapping address by address on the physical panel.

Note: modetest is useless against this driver -- nvidia-drm does not implement
dumb buffers, so `modetest -s` reports a successful modeset while
"failed to create dumb buffer: Invalid argument" scrolls past. It sets a mode with
nothing to scan out. Use the fbdev path instead.

Also note: `fbset -g <w> <h> ...` does take effect and persists. A leftover
`fbset -g 1024 768` made the panel show the top-left corner of a 2560x1440 buffer,
which looks exactly like a broken scanout. Check `fbset -i` before concluding
anything about geometry.

### Failure mode to remember

When the NVIDIA X driver aborts mid-session, the Xorg process does NOT exit. It
spins at ~70% CPU in state Rs+ and stops answering, so lightdm stays "active" and
any OnFailure= hook never fires. Stopping lightdm or killing that wedged Xorg
froze the board hard enough to need a reboot. Prefer a sysrq reboot
(`echo s > /proc/sysrq-trigger; echo u > ...; echo b > ...`) over pkill.

### Installed

- /etc/X11/xorg-egpu-nvidia.conf -- ServerLayout "egpu-layout", Driver "nvidia",
  BusID "PCI:1:0:0", ModulePath to the NVIDIA xorg dir. Installed as
  /etc/X11/xorg.conf by egpu-video-enable.
- /etc/X11/xorg.conf.d/05-no-autoaddgpu.conf -- AutoAddGPU/AutoBindGPU off. Without
  it X auto-adds the GPU as a secondary screen, falls back to `modesetting` on the
  NVIDIA DRM node and hangs loading glamoregl.
- egpu-video-check / egpu-video-enable / egpu-video-disable / egpu-compute.
- egpu-video-watchdog.timer, OnBootSec=75 -- verifies the X server answers xdpyinfo
  and reverts to the Orange Pi HDMI if not. Covers the wedged-Xorg case above.
- lightdm OnFailure=egpu-video-rollback.service as a second net.
- egpu-pcie-recover retries unbind/bind up to 5 times; original single-shot version
  at /root/egpu-backup/egpu-pcie-recover.orig.

XFCE stores wallpaper per monitor name. Moving X from the Allwinner output to the
NVIDIA one renames the monitor HDMI-1 -> HDMI-0, so the backdrop keys no longer
match and the desktop goes black. Fix by creating
/backdrop/screen0/monitorHDMI-0/workspace*/last-image in xfce4-desktop.

Hard lesson, unchanged: a warm SoC reset leaves the GPU powered and half-initialised,
and it then refuses to train the PCIe link no matter how many unbind/bind cycles are
issued. Only cutting mains power to the eGPU PSU recovers it.

### Confirmed working configuration

Dual head on the 3050: Screen 0 at 5120x1440, HDMI-0 and HDMI-1 both 2560x1440.
Under load the GPU sits at P0, 2017 MHz core / 7001 MHz memory, ~35 W -- versus
P8 / 210 MHz / 10 W when nothing is being scanned out. That power state is a quick
way to tell whether the display engine is actually running.

XFCE wallpaper keys must exist per monitor name; both monitorHDMI-0 and
monitorHDMI-1 are populated under /backdrop/screen0/ in xfce4-desktop.

Still untested as of this writing: a full reboot. The config is persistent
(/etc/X11/xorg.conf, /etc/modules-load.d/egpu-nvidia-display.conf), but if the PCIe
link fails to train on a given boot the rollback moves the desktop to the Allwinner
HDMI, which now has no monitor attached.

## Persistence and upgrade shielding (2026-09-05)

### Boot-time decision, self-healing

The live /etc/X11/xorg.conf is no longer the source of truth. The canonical file is
/etc/X11/xorg-egpu-nvidia.conf and it is never removed. Intent lives in
/etc/default/egpu-video (EGPU_VIDEO=yes|no).

egpu-video-apply.service runs After=egpu-pcie-recover.service and
Before=display-manager.service. Each boot it checks intent, PCIe enumeration,
modprobe of nvidia/nvidia_modeset/nvidia_drm, that nvidia-smi answers, and that a
KMS node appeared under the device. Only then does it install the canonical file as
/etc/X11/xorg.conf. Otherwise it removes the live file and the desktop comes up on
the Allwinner HDMI for that boot only.

This closes the hole in the earlier design, where the watchdog deleted
/etc/X11/xorg.conf permanently and a single bad boot meant re-running
egpu-video-enable by hand.

Module loading moved out of /etc/modules-load.d and into egpu-video-apply, so
nvidia_drm is never loaded before egpu-pcie-recover has had its chance to bring the
endpoint back.

egpu-video-disable now has two modes: bare invocation sets EGPU_VIDEO=no
(permanent opt-out), --auto only drops the live config so the next boot restores it.

### Upgrade shielding

The patched .ko files belong to no package (dpkg -S finds nothing) and there is no
DKMS entry, so nothing rebuilds them automatically -- but nothing protects them either.

- apt-mark hold on all nvidia-*/libnvidia-*/xserver-xorg-video-nvidia-* plus
  linux-image-current-sun60iw2 and linux-dtb-current-sun60iw2.
- /etc/apt/preferences.d/99-egpu-freeze pins those same packages to -1, which makes
  apt report `Candidate: (none)`. This still holds if someone runs apt-mark unhold.
  To upgrade deliberately: delete that file AND unhold.
- /root/egpu-backup/nvidia-modules-<kver>.tar.gz has the four built modules;
  egpu-restore-modules puts them back and runs depmod.
  /root/egpu-backup/egpu-config.tar.gz has every config file and script.
- egpu-health verifies: modules present for the running kernel, module version
  matches the userspace package version, holds still set, pin file present, canonical
  xorg config present. `egpu-health --repair` restores modules from the backup.
- /etc/apt/apt.conf.d/99-egpu-guard runs egpu-health --repair after every dpkg
  operation. It warns loudly rather than blocking.
- egpu-health.service logs the verdict to the journal at each boot.

A kernel upgrade would still be fatal: the modules are built for 6.6.98-sun60iw2 and
there is no backup for any other release. That is why the kernel packages are pinned
too. If the kernel ever must move, rebuild from ~/egpu-nvidia-580.142-full first.

### Reboot verified (2026-09-05)

A full reboot was tested end to end and the whole chain ran unattended:

```
egpu-pcie-recover: endpoint ja presente no boot, nada a fazer
egpu-video-apply:  eGPU pronta -- X vai subir na RTX 3050
(==) ServerLayout "egpu-layout"
(II) NVIDIA(0): Setting mode "DFP-2:nvidia-auto-select,DFP-3:nvidia-auto-select"
```

Screen 0 came up at 5120x1440 across both heads, zero (EE) in the Xorg log, xfce
session running, whole boot about 70 seconds. The PCIe endpoint enumerated on the
first try, so the retry path in egpu-pcie-recover was not exercised by this test.

Known cosmetic side effect: the Plymouth splash no longer appears. Module loading
was deliberately moved out of /etc/modules-load.d into egpu-video-apply so that
nvidia_drm is never loaded before egpu-pcie-recover has run. Plymouth starts much
earlier than that, so there is no NVIDIA framebuffer for it to draw on. Reverting
this would mean loading the modules early again, which reintroduces the ordering
hazard. Left as is on purpose.

Idle GPU sits at P8 / 210 MHz / ~12 W with a static desktop and climbs to
P0 / 2017 MHz / ~35 W under activity. P8 at idle is not a fault indicator.
