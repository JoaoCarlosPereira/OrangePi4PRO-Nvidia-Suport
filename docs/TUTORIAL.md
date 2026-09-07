# Tutorial — RTX 3050 on an Orange Pi 4 Pro, from scratch

Everything from a stock board to a working accelerated desktop. Read the whole
page before starting: some steps are hard to undo and one of them can leave you
without a screen.

## What you need

| | |
|---|---|
| Board | Orange Pi 4 Pro (Allwinner A733) |
| OS | Ubuntu 26.04 "Resolute" / Orange Pi 1.1.0, kernel `6.6.98-sun60iw2` |
| GPU | NVIDIA Ampere. Tested: MSI RTX 3050 6 GB, GA107, `10de:2584` |
| Adapter | PCIe riser from the board's M.2 slot |
| **GPU power** | **A separate ATX PSU. Non-negotiable — the Pi cannot feed a discrete card.** |
| Access | SSH from another machine. You *will* need it. |

> **Set up SSH before you start.** Several steps here can kill the local display.
> Every recovery in this guide assumes you can still reach the board over the
> network.

---

# Part 1 — Get the GPU onto the PCIe bus

Nothing else matters until `lspci` shows the card. Out of the box it will not.

## 1.1 Cap the link at Gen2

The vendor device tree asks for Gen3. The A733 trains Gen3 x1 to the GPU without
a single link error, but the NVIDIA GSP firmware halts during driver init at that
speed (`Xid 62`). Gen2 works end to end and doubles Gen1's bandwidth, so cap the
link there. The details, and what "Speed change timeout" in the log really means,
are in [PCIE-LINK-SPEED.md](PCIE-LINK-SPEED.md).

`egpu-pcie-gen2.dts`:

```dts
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target-path = "/soc@3000000/pcie@6000000";
        __overlay__ {
            max-link-speed = <2>;
        };
    };
};
```

> If you had the older `egpu-pcie-gen1` overlay installed, replace it: never load
> both. And power-cycle the GPU's PSU after changing the speed — the GPU
> remembers the host's previous maximum until it gets a real reset.

## 1.2 Add the high-memory aperture

This is the step people miss, and without it the GPU enumerates but its large
BARs fail to get addresses.

An RTX 3050 asks for a **256 MB BAR1** and a **32 MB BAR3**, both 64-bit
prefetchable. The board's default PCIe memory window is 96 MB at `0x22000000`.
BAR1 does not fit, so the kernel gives up on it:

```
pci 0000:01:00.0: BAR 1: no space for [mem size 0x10000000 64bit pref]
pci 0000:01:00.0: BAR 1: failed to assign [mem size 0x10000000 64bit pref]
```

The A733 manual (v0.92) documents a second, much larger PCIe slave aperture:

```
PCIE_SLAVE    0x440000000---0x53FFFFFFF
```

The overlay reserves the first 512 MB of it for 64-bit prefetchable BARs, while
preserving the vendor's existing config, I/O and non-prefetchable windows.

`egpu-pcie-highmem.dts`:

```dts
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target-path = "/soc@3000000/pcie@6000000";
        __overlay__ {
            #address-cells = <3>;
            #size-cells = <2>;
            // Preserve vendor config, I/O and non-prefetchable windows.
            // A733 manual v0.92: PCIe slave high aperture 0x440000000-0x53fffffff.
            // Reserve its first 512 MiB for 64-bit prefetchable GPU BARs.
            ranges = <0x00000800 0 0x20000000 0 0x20000000 0 0x01000000>,
                     <0x81000000 0 0x21000000 0 0x21000000 0 0x01000000>,
                     <0x82000000 0 0x22000000 0 0x22000000 0 0x06000000>,
                     <0xc3000000 4 0x40000000 4 0x40000000 0 0x20000000>;
        };
    };
};
```

> **This is board-specific.** Those addresses come from the A733 manual. Do not
> copy them onto a different SoC.

## 1.3 Build and install both overlays

```bash
sudo apt install device-tree-compiler

dtc -@ -I dts -O dtb -o egpu-pcie-gen2.dtbo    egpu-pcie-gen2.dts
dtc -@ -I dts -O dtb -o egpu-pcie-highmem.dtbo egpu-pcie-highmem.dts

sudo mkdir -p /boot/overlay-user
sudo cp egpu-pcie-gen2.dtbo egpu-pcie-highmem.dtbo /boot/overlay-user/
```

Back up `/boot/orangepiEnv.txt` before editing it, then add:

```
user_overlays=egpu-pcie-gen2 egpu-pcie-highmem
```

Reboot. **Power the GPU's PSU on before the board boots.**

## 1.4 Verify

```bash
lspci -nn
```

You want two functions — the GPU and its HDMI audio device:

```
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA107 [GeForce RTX 3050 6GB] [10de:2584]
01:00.1 Audio device [0403]: NVIDIA Corporation GA107 High Definition Audio Controller [10de:2291]
```

Then confirm the BARs actually landed in the high aperture:

```bash
sudo dmesg | grep "BAR .*assigned"
```

```
pci 0000:01:00.0: BAR 1: assigned [mem 0x440000000-0x44fffffff 64bit pref]
pci 0000:01:00.0: BAR 3: assigned [mem 0x450000000-0x451ffffff 64bit pref]
```

If you see `failed to assign` instead, the high-memory overlay is not active.

## 1.5 Handle intermittent enumeration

Even with the overlays, **some boots produce no endpoint at all**. The controller
can be unbound and rebound to retry, which recovers most cases.

`files/scripts/egpu-pcie-recover` does this up to five times and exits as soon as
an endpoint appears. It never touches the controller if one is already present —
which matters, because rebinding a live bus with an active GPU is destructive.

Install it plus `files/systemd/egpu-pcie-recover.service`, then:

```bash
sudo systemctl enable egpu-pcie-recover.service
```

> **When retries do not help.** If the endpoint stays missing across several
> boots, the GPU is wedged. This happens after a warm reset of the SoC: the card
> stays powered and half-initialised and will not train the link again. **Cut
> mains power to the GPU's PSU, wait ten seconds, power it back on, then boot the
> board.** No amount of rebinding substitutes for this.

---

# Part 2 — The NVIDIA driver

## 2.1 Why the stock driver is not enough

Three things about this platform break NVIDIA's assumptions:

| Assumption | Reality on the A733 |
|---|---|
| PCIe device sits behind an IOMMU | No IOMMU group at all — the GPU DMAs to physical addresses |
| I/O is cache-coherent | `dma-coherent` is absent from the device tree node |
| The chipset is known | `NVRM: Chipset not recognized (vendor ID 0x1f6d, device ID 0xabcd)` |

The driver also states plainly: *"The NVIDIA GPU driver for AArch64 has not been
qualified on this platform."* It loads anyway.

The non-coherence is the fatal one. Without cache maintenance on DMA mappings the
GPU reads stale data.

## 2.2 Get the source and the patches

```bash
git clone https://github.com/NVIDIA/open-gpu-kernel-modules.git
cd open-gpu-kernel-modules
git checkout 580.142
```

Apply [PR #972](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/972) by
Mario Bălănică — five commits, included here as
`nvidia-arm-noncoherent-pr972.patch`:

```bash
git checkout -b egpu-a733-580.142
git am ../nvidia-arm-noncoherent-pr972.patch
```

What each commit does:

| Commit | Effect |
|---|---|
| Query OS for chipset I/O cache coherency | Stops assuming coherence; asks the kernel |
| Disable WC iomaps by default for unknown Arm chipsets | Write-combining MMIO is unsafe here |
| Never skip cache flushing on `dma_map_*()` calls | The core fix |
| Rework DMA cache maintenance helper | Cleanup of the above |
| Fix cached DMA allocations on non-coherent hardware | Allocation path |

A sixth, board-specific commit is needed on this kernel: the vendor BSP is built
without `CONFIG_MMU_NOTIFIER`, which `nvidia-uvm` requires. Guard it in
`kernel-open/nvidia-uvm/uvm_linux.h`. Without this, UVM fails to build.

## 2.3 Prepare the kernel tree

The Orange Pi image ships **no kernel headers package**, so you must build against
a matching source tree.

```bash
git clone https://github.com/orangepi-xunlong/linux-orangepi.git egpu-linux
cd egpu-linux
git checkout orange-pi-6.6-sun60iw2   # tested at commit 8a9be72c9006
cp /boot/config-6.6.98-sun60iw2 .config
make olddefconfig
make modules_prepare
```

Two details that will bite you:

- **`CONFIG_MODVERSIONS` must stay disabled**, matching the running kernel.
- **The running kernel was built with GCC 11.2.1.** Building modules with a
  different major GCC produces modules that load but misbehave. Install `gcc-11`
  and point the build at it.

## 2.4 Build and install

```bash
cd ../open-gpu-kernel-modules
make modules -j$(nproc) \
     SYSSRC=/home/orangepi/egpu-linux \
     CC=gcc-11 HOSTCC=gcc-11
sudo make modules_install SYSSRC=/home/orangepi/egpu-linux
sudo depmod -a
```

Modules land in `/lib/modules/6.6.98-sun60iw2/extra/`:
`nvidia.ko`, `nvidia-modeset.ko`, `nvidia-drm.ko`, `nvidia-uvm.ko`.

> These files belong to **no package**. `dpkg -S` will not find them, and nothing
> rebuilds them automatically. Back them up — see Part 6.

## 2.5 Install matching userspace

The kernel modules and the userspace libraries must be the **same version**.

```bash
sudo apt install nvidia-utils-580 libnvidia-gl-580 libnvidia-compute-580 \
                 xserver-xorg-video-nvidia-580
```

Confirm:

```bash
nvidia-smi
```

```
GPU 0: NVIDIA GeForce RTX 3050 (UUID: GPU-...)
```

---

# Part 3 — Validate compute before touching video

Do not skip this. If CUDA does not work, video will not either, and you will be
debugging two problems at once.

```bash
sudo modprobe nvidia
sudo modprobe nvidia_uvm
nvidia-smi
```

`files/scripts/egpu-compute` wraps exactly this — and deliberately does **not**
load `nvidia_modeset` or `nvidia_drm`, so you can use CUDA without any risk to
your display.

A real test should create a context, transfer to VRAM, run an `sm_86` kernel,
synchronise, and check the returned data.

Note: `nvidia_uvm` works without pageable-memory integration, because the vendor
kernel lacks `CONFIG_MMU_NOTIFIER`.

---

# Part 4 — Video output

This is where a mistake costs you your screen. **Have SSH open.**

## 4.1 Two traps that produce an unrecoverable black screen

**Trap 1 — `AutoAddGPU`.** If `nvidia_drm` is loaded and X is left to its own
devices, X adds the GPU as a *secondary* GPU screen, picks the `modesetting`
driver for it, and hangs loading `glamoregl`:

```
(II) Applying OutputClass "nvidia" options to /dev/dri/card2
(II) Loading /usr/lib/xorg/modules/libglamoregl.so
   ← log ends here, X wedged
```

lightdm then restarts five times and gives up. Prevent it with
`files/xorg/05-no-autoaddgpu.conf`:

```
Section "ServerFlags"
    Option "AutoAddGPU"  "off"
    Option "AutoBindGPU" "off"
EndSection
```

**Trap 2 — `nvidia_drm fbdev=1` before video works.** The 580 driver enables
fbdev on its own. `fb0` becomes `nvidia-drmdrmfb` and the text console migrates to
the NVIDIA card. If that card is not yet producing an image, **the console
disappears from the working output too** — a black screen with a blinking cursor
and no way in except SSH.

Until you have confirmed video, force it off:

```
options nvidia_drm modeset=1 fbdev=0
```

Once video works, `fbdev=1` is desirable: you get the boot console on the GPU.

## 4.2 Prove the display path before involving X

Load the display modules and check the connectors:

```bash
sudo modprobe nvidia_drm modeset=1 fbdev=1
for c in /sys/class/drm/card*-*; do
    printf '%-24s %s\n' "$(basename "$c")" "$(cat "$c/status")"
done
```

A connected monitor on the GPU should read `connected`, and `nvidia-smi -q` should
say `Display Attached : Yes`.

Then write to the framebuffer **and read it back**:

```bash
sudo python3 - <<'PY'
import mmap, os, struct
W, H = 2560, 1440          # match /sys/class/graphics/fb0/virtual_size
f = os.open("/dev/fb0", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(f, W*H*4, mmap.MAP_SHARED)
pat = [0xDEADBEEF, 0x12345678]
for i, v in enumerate(pat):
    m[i*4:i*4+4] = struct.pack("<I", v)
m.flush()
back = [struct.unpack("<I", m[i*4:i*4+4])[0] for i in range(2)]
print("write/readback OK:", back == pat)
# solid colour bars, visible on the panel
row = b"".join(struct.pack("<I", 0x00FF0000 if x < W//3
                           else 0x0000FF00 if x < 2*W//3
                           else 0x000000FF) for x in range(W))
for y in range(H):
    m[y*W*4:(y+1)*W*4] = row
m.flush()
PY
```

If the bars appear on the monitor, the whole display path works and X is the only
thing left.

> **Do not use `modetest` here.** `nvidia-drm` does not implement dumb buffers, so
> `modetest -s` reports a successful modeset while `failed to create dumb buffer:
> Invalid argument` scrolls past. It sets a mode with nothing to scan out, and you
> will conclude the hardware is broken when it is not.

## 4.3 Pin X to the GPU

`files/xorg/xorg-egpu-nvidia.conf`:

```
Section "Files"
    ModulePath "/usr/lib/aarch64-linux-gnu/nvidia/xorg"
    ModulePath "/usr/lib/xorg/modules"
EndSection

Section "ServerLayout"
    Identifier "egpu-layout"
    Screen 0 "egpu-screen"
    Option "AutoAddGPU" "off"
EndSection

Section "Device"
    Identifier "egpu-device"
    Driver     "nvidia"
    BusID      "PCI:1:0:0"
    Option     "AllowEmptyInitialConfiguration" "true"
EndSection

Section "Screen"
    Identifier "egpu-screen"
    Device     "egpu-device"
EndSection
```

The `ModulePath` matters: `nvidia_drv.so` is **not** in
`/usr/lib/xorg/modules/drivers/`. It lives in
`/usr/lib/aarch64-linux-gnu/nvidia/xorg/`. Looking in the usual place and finding
only `modesetting_drv.so` leads to the wrong conclusion that the driver is missing.

Install it as `/etc/X11/xorg.conf`, restart lightdm, and check:

```bash
grep -E "ServerLayout|nvidia_drv|Setting mode|\(EE\)" /var/log/Xorg.0.log
```

```
(==) ServerLayout "egpu-layout"
(II) Loading /usr/lib/aarch64-linux-gnu/nvidia/xorg/nvidia_drv.so
(II) NVIDIA GLX Module  580.142
(II) NVIDIA(0): Setting mode "DFP-2:nvidia-auto-select"
```

Zero `(EE)` lines, and `glxinfo -B` should report
`NVIDIA GeForce RTX 3050/PCIe` with `OpenGL 4.6.0`.

## 4.4 XFCE wallpaper goes black

Expected, not a fault. XFCE stores the wallpaper **per monitor name**. Moving X
from the Allwinner output to the NVIDIA one renames the monitor (`HDMI-1` →
`HDMI-0`), so the existing backdrop keys no longer match.

```bash
IMG=$(xfconf-query -c xfce4-desktop -p /backdrop/monitorVirtual-1/workspace0/last-image)
for WS in 0 1 2 3; do
  xfconf-query -c xfce4-desktop -n -t string \
    -p /backdrop/screen0/monitorHDMI-0/workspace$WS/last-image  -s "$IMG"
  xfconf-query -c xfce4-desktop -n -t int \
    -p /backdrop/screen0/monitorHDMI-0/workspace$WS/image-style -s 5
done
xfdesktop --quit; xfdesktop &
```

Repeat for `monitorHDMI-1` if you run two screens.

---

# Part 5 — Make it survive reboots

A naive setup writes `/etc/X11/xorg.conf` once and hopes. On this board that
fails, because PCIe enumeration is intermittent: on a bad boot X cannot find the
GPU, fails, and you are left with nothing.

The design here separates **intent** from **live configuration**:

| File | Role |
|---|---|
| `/etc/X11/xorg-egpu-nvidia.conf` | Canonical layout. **Never removed.** |
| `/etc/default/egpu-video` | Intent: `EGPU_VIDEO=auto\|yes\|no` |
| `/etc/X11/xorg.conf` | Live config, recreated each boot **only if the GPU is usable** |

`egpu-video-apply.service` runs after PCIe recovery and before the display
manager. In the default `auto` mode it decides which output to use:

1. Is the endpoint on the bus, do the modules load, does `nvidia-smi` answer, did
   a KMS node appear? If any of that fails → Orange Pi HDMI.
2. **Is a monitor actually plugged into the NVIDIA card?** It polls the card's DRM
   connectors for up to 8 s, because hot-plug detect can lag the initial modeset.
   Connected → NVIDIA. Nothing connected → Orange Pi HDMI.

The decision covers the **text console too**, not just X. The module is first
loaded with `fbdev=0`, and only reloaded with `fbdev=1` once a monitor is
confirmed on the GPU. This ordering matters: the 580 driver enables fbdev on its
own, and a console sitting on an output with no monitor is indistinguishable from
a hung board. Getting this backwards is what made a perfectly healthy boot look
dead during development.

`EGPU_VIDEO=yes` forces the NVIDIA card even with nothing detected — for KVM
switches and monitors that do not assert HPD while powered off. `no` pins the
Orange Pi HDMI. `egpu-video-auto` returns to automatic.

Module loading lives in that service rather than `/etc/modules-load.d/`, so
`nvidia_drm` is never loaded before PCIe recovery has had its chance.

## 5.1 The failure mode the obvious safety net misses

When the NVIDIA X driver aborts mid-session, **the Xorg process does not exit**.
It spins at ~70% CPU in state `Rs+` and stops answering. lightdm still reports
`active`, so any `OnFailure=` hook never fires.

Two nets are therefore needed:

- `lightdm.service.d/egpu-rollback.conf` adds `OnFailure=egpu-video-rollback.service`
  — catches a clean X failure.
- `egpu-video-watchdog.timer` fires 75 s after boot and verifies X actually
  answers `xdpyinfo` — catches the wedged case.

### 5.3 Do not strand yourself without SSH

Whatever you do to this system, **keep `sshd` working**. It is the only recovery
channel when the display is wrong, and the display is wrong often on this board.

Two independent mistakes will take it away from you, and both happened here:

**Missing host keys.** If you ever remove `/etc/ssh/ssh_host_*` — cloning a card,
sanitising an image — `sshd` refuses to start, so port 22 silently never opens.
The distro's own `sshd-keygen.service` does not save you: it carries
`ConditionFirstBoot=yes`, so it only ever tries once, and a negated condition is
not a failure, so systemd never retries. Install
`files/systemd/regen-ssh-host-keys.service`, which runs on *any* boot where the
keys are missing:

```ini
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
Before=ssh.service ssh.socket sshd.service
ExecStart=/usr/bin/ssh-keygen -A
```

**Socket activation giving up.** Ubuntu's socket-activated `sshd` stops listening
for good once `ssh.socket` exhausts its start-rate limit — which is what happens
when `sshd` keeps failing. Replace it with a persistent daemon:

```bash
# a) break the Requires= that would drag the socket back in
sudo rm -f /etc/systemd/system/ssh.service.requires/ssh.socket

# b) Restart=always, no start limit, and remove the two factory settings that
#    turn a bad config into "no SSH at all"
sudo install -d /etc/systemd/system/ssh.service.d
sudo install -m 644 files/systemd/ssh.service.d/egpu-always.conf \
        /etc/systemd/system/ssh.service.d/

# c) swap socket for service. KillMode=process keeps your current session alive.
sudo systemctl daemon-reload
sudo systemctl enable ssh.service
sudo systemctl disable ssh.socket
sudo systemctl stop ssh.socket; sudo systemctl start ssh.service
```

Then add the watchdog, which is the part that actually saves you at 3 a.m.:

```bash
sudo install -m 755 files/scripts/egpu-ssh-guard /usr/local/sbin/
sudo install -m 644 files/systemd/egpu-ssh-guard.{service,timer} \
        /etc/systemd/system/
sudo systemctl enable --now egpu-ssh-guard.timer
```

Every 60 s it checks for a listener on port 22 — read straight out of
`/proc/net/tcp`, so it does not depend on `ss`, `netstat` or `lsof` being
installed or working — and escalates until something answers: host keys,
config validation, a minimal known-good `sshd_config`, `reset-failed`, and
finally a lifeboat `sshd` with keys under `/run` for the case where `/` is
read-only.

`egpu-health` checks for missing host keys too, and the apt hook calls
`egpu-ssh-guard --reassert` after every dpkg run, because an `openssh-server`
upgrade re-enables `ssh.socket` behind your back.

> **Never `pkill` a wedged Xorg on this board.** Stopping lightdm or killing that
> process froze the machine hard enough to need a physical reset. If you must
> reboot from a wedged state, use sysrq:
> ```bash
> echo s | sudo tee /proc/sysrq-trigger   # sync
> echo u | sudo tee /proc/sysrq-trigger   # remount read-only
> echo b | sudo tee /proc/sysrq-trigger   # reboot
> ```

## 5.2 The Plymouth trade-off

Moving module loading late means there is no NVIDIA framebuffer when Plymouth
starts, so **the boot splash no longer appears**. This is deliberate. Loading the
modules early brings back the splash and reintroduces the ordering hazard.

---

# Part 6 — Protect it from upgrades

The patched modules belong to no package and there is no DKMS entry. Nothing
rebuilds them — and nothing protects them either. An `apt upgrade` that moves
userspace to 580.150 breaks the pair instantly.

```bash
# 1. Hold
sudo apt-mark hold $(dpkg-query -W -f='${Package}\n' \
    | grep -E '^(libnvidia-|nvidia-|xserver-xorg-video-nvidia)') \
    linux-image-current-sun60iw2 linux-dtb-current-sun60iw2
```

```
# 2. Pin — survives someone running apt-mark unhold
# /etc/apt/preferences.d/99-egpu-freeze
Package: nvidia-* libnvidia-* xserver-xorg-video-nvidia-*
Pin: release *
Pin-Priority: -1

Package: linux-image-current-sun60iw2 linux-dtb-current-sun60iw2
Pin: release *
Pin-Priority: -1
```

Verify the pin actually bites — `Candidate: (none)` is what you want:

```bash
apt policy nvidia-utils-580
```

```
nvidia-utils-580:
  Installed: 580.142-0ubuntu3
  Candidate: (none)
 *** 580.142-0ubuntu3 -1
```

**3. Back the modules up**, since they cannot be reinstalled from a repository:

```bash
sudo mkdir -p /root/egpu-backup
sudo tar czf /root/egpu-backup/nvidia-modules-$(uname -r).tar.gz \
     -C /lib/modules/$(uname -r) extra/nvidia.ko extra/nvidia-modeset.ko \
     extra/nvidia-drm.ko extra/nvidia-uvm.ko
```

**4. Verify continuously.** `files/scripts/egpu-health` checks that the modules
exist for the running kernel, that module and userspace versions match, that the
holds and pin are still in place, and that the canonical Xorg config is present.
`egpu-health --repair` restores the modules from the backup.

Wire it into apt so every `dpkg` run is followed by a check —
`/etc/apt/apt.conf.d/99-egpu-guard`:

```
DPkg::Post-Invoke {
    "if [ -x /usr/local/sbin/egpu-health ]; then /usr/local/sbin/egpu-health --repair || echo '*** eGPU stack affected. Run: sudo egpu-health ***'; fi";
};
```

A kernel upgrade remains fatal regardless: the modules are built for exactly
`6.6.98-sun60iw2` and there is no backup for any other release. If the kernel must
move, rebuild from source **first**.

---

# Verifying the whole thing

```bash
sudo egpu-health
xrandr --query | grep -E "^Screen| connected"
glxinfo -B | grep -E "OpenGL renderer|OpenGL version"
journalctl -t egpu-video-apply -b
```

A healthy boot logs:

```
egpu-pcie-recover: endpoint ja presente no boot, nada a fazer
egpu-video-apply:  eGPU pronta -- X vai subir na RTX 3050
```

## A note on GPU power state

Idle, the card sits at `P8 / 210 MHz / ~12 W`; under load it climbs to
`P0 / 2017 MHz / ~35 W`. `P8` with a static desktop is normal and **not** a sign
that the display engine is inactive — but a card stuck at `P8` while you expect
heavy output is a useful hint that scanout is not really running.

---

Stuck? [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md) covers the failure modes in
detail, including several hypotheses that look correct and are not.
