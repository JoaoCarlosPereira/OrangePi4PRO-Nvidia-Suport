# Troubleshooting

Read the first section before anything else. It will save you more time than the
rest of this document combined.

---

## "No signal" and "black screen" are different diagnoses

This distinction is the single most useful diagnostic on this platform, and it is
easy to blur when someone asks "is there video?".

| Symptom | Meaning | Where to look |
|---|---|---|
| Monitor says **no signal** | TMDS is not being driven at all | Display engine / SOR / cable / port |
| Monitor shows a **black screen** | There *is* a signal; the content is black | Framebuffer, scanout source, X |

During this project the panel moved from "no signal" to "black screen" after the
monitor was **moved to a different physical port on the card**, with no software
change whatsoever. Everything worked from that point on. If you are stuck at "no
signal", try every port and a different cable before touching software.

---

## Diagnostic ladder

Work down this list. Do not skip levels — each one rules out the ones below it.

### 1. Is the GPU on the bus?

```bash
lspci -nn | grep NVIDIA
```

Nothing? See [Intermittent enumeration](#intermittent-pcie-enumeration).

### 2. Did the big BARs get addresses?

```bash
sudo dmesg | grep -E "BAR (1|3):"
```

`failed to assign` means the high-memory overlay is not active. Check
`user_overlays` in `/boot/orangepiEnv.txt` and that the `.dtbo` files exist in
`/boot/overlay-user/`.

### 3. Does the driver initialise?

```bash
nvidia-smi
```

```
NVRM: GPU 0000:01:00.0: RmInitAdapter failed! (0x62:0x56:2028)
```

means the link came up degraded. Power-cycle the GPU's PSU rather than retrying.

### 4. Does the display engine see the monitor?

```bash
sudo modprobe nvidia_drm modeset=1 fbdev=1
for c in /sys/class/drm/card*-*; do
    printf '%-24s %s\n' "$(basename "$c")" "$(cat "$c/status")"
done
nvidia-smi -q | grep -i "display"
```

`connected` plus `Display Attached : Yes` means DDC/I2C and hot-plug detect work.
Those travel a completely separate path from pixel output, so this passing tells
you nothing about whether video works — only that the cable and port are sound.

### 5. Does the framebuffer reach the panel?

The decisive test. See §4.2 of the [tutorial](TUTORIAL.md). Write colour bars to
`/dev/fb0`, read them back, and look at the monitor.

### 6. Only now, involve X

```bash
grep -E "\(EE\)|ServerLayout|Setting mode" /var/log/Xorg.0.log
```

---

## Tools that lie to you

### `modetest` reports success while doing nothing

`nvidia-drm` does not implement dumb buffers. `modetest -s` prints a perfectly
convincing modeset line and exits 0 — while this scrolls past:

```
failed to create dumb buffer: Invalid argument
```

It set a mode with **no framebuffer attached**. Nothing is scanned out, the panel
stays dark, and you conclude the hardware is broken.

It also dies with your SSH session unless launched through `systemd-run`, so a
test that "held the mode for 90 seconds" may have held it for two.

**Use the fbdev write/read-back test instead.**

### Raw BAR1 reads are not a health check

```bash
# This proves nothing:
sudo dd if=/sys/bus/pci/devices/0000:01:00.0/resource1 bs=4 count=4 | xxd
```

BAR1 on an NVIDIA GPU is an **MMU-translated window into VRAM**. Offsets the
driver has not mapped return zeros, and writes are discarded. That is correct
behaviour, not a dead aperture.

To actually test a PCIe window, alias a **known-readable** target into it: program
a spare outbound ATU region mapping a high CPU address to BAR0's PCI address, then
compare reads through both paths.

### `fbset -g` persists and fakes a broken scanout

If you ever ran `fbset -g 1024 768 ...`, the panel will show the **top-left corner
of a larger buffer** — image crammed into a corner, borders missing on two sides.
This looks exactly like a broken scanout engine.

```bash
fbset -i     # check geometry BEFORE concluding anything
```

---

## Hypotheses that look right and are wrong

Each of these was investigated and **disproven**. They are recorded so nobody
repeats the work.

### ❌ "The display pushbuffer is not readable by the GPU over DMA"

Plausible: the pushbuffer lives in system memory and this platform is
non-coherent.

**Disproven by:** compute channels use pushbuffers in system memory too, and CUDA
works. GPU→sysmem DMA is fine.

### ❌ "The high PCIe outbound window is unmapped (ATU bug)"

The driver writes only `lower_32_bits()` of the ATU limit, which for a window at
`0x440000000` yields a limit *below* the base. It looks like a textbook 64-bit bug.

**Disproven by:** mapping a spare outbound ATU region (index 4) from CPU
`0x460000000` to PCI `0x22000000`, then reading BAR0 through it. Identical values
to the direct low-window read — so the high window works.

### ❌ "The ATU upper-limit register at DBI+0x300020 must be programmed"

**Disproven by A/B test:** clearing it to `0` does not break the mapping. The
register is not consulted the way the theory assumed.

### ❌ "USB peripherals were loading the board's rails"

Removing a webcam and a microphone made a command that had reliably frozen the
board run clean, 40 times in a row. The mechanism was plausible: the A733's PCIe
PHY draws its rails from the AXP8191, and sustained USB current degrades that
input.

**Disproven by:** plugging everything back in and running 200 probe iterations
with zero physical-layer errors. A **reset** had happened between the two states,
and that was the real difference.

**The lesson matters more than the hypothesis.** This failure is probabilistic and
a reboot confounds every comparison. Two separate causal claims were made and
retracted during this investigation, each from a single clean run. Measure with
`egpu-link-margin` across several boots before believing anything.

### ❌ "BAR1 is dead"

**Disproven:** see *Raw BAR1 reads are not a health check* above.

---

## Intermittent PCIe enumeration

The A733 controller sometimes fails to train the link on boot. Symptoms:

```
sunxi:pcie-rc-6000000.pcie:[ERR]: Speed change timeout
sunxi:pcie-rc-6000000.pcie:[INFO]: PCIe speed of Gen1
```

...followed by only the root port on the bus:

```
00:00.0 PCI bridge [0604]: Device [1f6d:abcd] (rev 01)
```

Note that `Speed change timeout` appears on **successful** boots too. It is not a
reliable failure signal — the absence of `01:00.x` is.

### Recovery, in order of escalation

1. **Controller rebind.** `egpu-pcie-recover` does this up to five times at boot.
   Manually:
   ```bash
   echo 6000000.pcie | sudo tee /sys/bus/platform/drivers/sunxi-pcie/unbind
   sleep 2
   echo 6000000.pcie | sudo tee /sys/bus/platform/drivers/sunxi-pcie/bind
   ```
   > Never do this with a live GPU or other PCI devices on the bus.

2. **Cut mains power to the GPU's PSU.** Wait ten seconds, power on, then boot the
   board.

A **warm reset of the SoC** (reset button, `reboot -f` after a hang) leaves the
card powered and half-initialised. It will then refuse to train the link no matter
how many rebinds you issue. Only a real power cycle recovers it. If you have
rebooted three times and the endpoint has not appeared, stop rebooting.

---

## The desktop will not start

### Black screen with a blinking cursor in the corner

**This is usually not a hang.** The text console migrated to the NVIDIA
framebuffer while your monitor is somewhere else — or while that card is not
producing an image. The cursor is a healthy console with nothing written to it.

Before debugging anything: **move the monitor to the other output.** If the
desktop is there, nothing is broken; the console and X are simply on different
heads.

Caused by `nvidia_drm fbdev=1`, which the 580 driver sets by itself. The current
`egpu-video-apply` handles this — it loads the module with `fbdev=0` and only
moves the console to the GPU after confirming a monitor is connected there. If
you are on an older setup, over SSH:

```bash
sudo sh -c 'echo "options nvidia_drm modeset=1 fbdev=0" > /etc/modprobe.d/egpu-nofbdev.conf'
sudo egpu-video-apply
sudo systemctl restart lightdm
```

### lightdm restarts five times and gives up

```
lightdm.service: Main process exited, code=exited, status=1/FAILURE
lightdm.service: Start request repeated too quickly.
```

With the Xorg log ending mid-`glamoregl`. This is the `AutoAddGPU` trap — see §4.1
of the tutorial.

### Xorg is "active" but nothing responds

The nastiest one. The NVIDIA X driver aborted, but the process **did not exit**:

```
$ ps -o stat,pcpu -C Xorg
Rs+  70.0
$ xdpyinfo -display :0
Can't open display :0
```

`systemctl is-active lightdm` still says `active`, so `OnFailure=` hooks never
run. This is why `egpu-video-watchdog.timer` exists — it tests that X actually
answers, not that lightdm claims to be alive.

> **Do not `pkill` the wedged Xorg, and do not `systemctl stop lightdm`.** Both
> froze the board hard enough to require a physical reset — which then wedges the
> GPU (see above). Use sysrq:
> ```bash
> echo s | sudo tee /proc/sysrq-trigger
> echo u | sudo tee /proc/sysrq-trigger
> echo b | sudo tee /proc/sysrq-trigger
> ```

### `Failed to allocate DMA context` / `Failed to allocate push buffer`

```
(EE) NVIDIA(GPU-0): Failed to allocate DMA context
(EE) NVIDIA(0): Failed to allocate push buffer
nvidia-modeset: ERROR: GPU:0: Failed to query display engine channel state
```

Seen while the monitor was on a port that produced no signal. After moving the
monitor to a working port, X started cleanly and these never recurred. The
relationship was never fully established — if you hit this, **check the physical
output first** before assuming a driver problem.

---

## SSH refuses connections but the board pings

```
$ ping 192.168.2.118      # replies
$ ssh orangepi@...        # Connection refused
```

`sshd` is not listening. On this image that should heal itself within a minute —
`egpu-ssh-guard` runs on a timer and forces the port back open. If it does not,
the diagnosis matters.

**First, confirm the board finished booting.** `xrdp` listens on **3389** and is a
good canary. If 3389 answers, the boot completed and only `sshd` is broken.

Then, from the board's own HDMI or over RDP:

```bash
journalctl -t egpu-ssh-guard          # what the guard tried, and why it failed
systemctl status ssh.service          # not ssh.socket -- see below
sudo /usr/local/sbin/egpu-ssh-guard   # run it in the foreground, watch it work
```

### Why this image does not use socket activation

Ubuntu ships `sshd` socket-activated, and that is the trap. If `sshd` fails to
start, `ssh.socket` exhausts its start-rate limit, enters `failed`, and **stops
listening entirely** — the port does not reopen on its own, ever. The usual
trigger is **missing host keys** after cloning or sanitising an image, because
`sshd` refuses to start without them.

Two things about the factory `ssh.service` make it worse, and both are cleared by
`files/systemd/ssh.service.d/egpu-always.conf`:

| Factory setting | What it does to you |
|---|---|
| `ExecStartPre=/usr/sbin/sshd -t` | a typo in `sshd_config` blocks the start outright |
| `RestartPreventExitStatus=255` | 255 is exactly what `sshd` returns for a config error, so systemd stops retrying |

So: a single bad line in a config file is enough to close your only recovery
channel, permanently, with no retry. That is what the hardening exists to
prevent.

### If the guard reports the lifeboat

```
egpu-ssh-guard: bote salva-vidas escutando na 22 (chaves em /run/egpu-ssh -- a impressao digital MUDOU)
```

Your client will refuse to connect with a host-key mismatch warning. That is
expected: the lifeboat generates a throwaway key under `/run` because `/etc` was
not usable. Accept the new key, get in, and fix the real problem — the guard
leaves the broken files next to the originals with a `.quebrado-<timestamp>`
suffix.

---

## The GPU monitor is dark for most of the boot

Not a fault. The NVIDIA modules load late, so nothing can drive the card until
lightdm starts. U-Boot and the kernel console go to the board's own HDMI or the
serial port; Plymouth does not appear on the card at all.

And because the driver is loaded with `fbdev=0`, there is **never** a text console
on the GPU. `fbcon` stays on the SoC display engine, so Ctrl+Alt+F2 appears on
the **Orange Pi HDMI**. If Xorg fails, the GPU monitor simply goes dark and stays
dark — there is nothing else able to drive that output.

Do not chase this as a display bug. Diagnose over SSH, or on the board's HDMI.

### On a first boot, expect minutes — and possibly the wrong output

A freshly flashed card is the slowest case, and the sequence looks like a fault
even when nothing is wrong:

```
dark screen  ->  ~3 min filesystem expansion  ->  board reboots itself
             ->  dark screen again  ->  up to 25 s of PCIe retries
             ->  up to 8 s waiting for hot-plug detect  ->  lightdm
```

If it ends with a desktop on the **Orange Pi HDMI** instead of the card, the
endpoint did not enumerate and the fallback did its job:

```bash
egpu-video-check
journalctl -u egpu-pcie-recover -b     # "endpoint NAO enumerado apos 5 tentativas"
```

The fix is not software. Cut mains power to the GPU's PSU for ~10 s and boot
again — a warm reset leaves the card powered and half-initialised, and it will
refuse to train the link no matter how many times the controller is rebound.

---

## The desktop wedges under use, and `nvidia-smi` says `[GPU requires reset]`

Check `dmesg` for this — it is the deepest fault found on this platform:

```
WARNING: at kernel-open/nvidia-drm/nvidia-drm-crtc.h:335
         __nv_drm_handle_flip_event+0x188/0x194 [nvidia_drm]
```

`nv_drm_crtc_dequeue_flip()` found an empty flip list: the driver got more
page-flip completion events than flips it enqueued. Count them —

```bash
sudo dmesg | grep -c __nv_drm_handle_flip_event
```

245 in one session here. After enough of them the GPU needs a reset, the
compositor hangs, and only a reboot plus a mains power cycle of the GPU's PSU
recovers it.

**It only affects Wayland.** The NVIDIA X11 driver does not use this path, which
is why Plasma X11 stays stable while Wayland does not.

Do not chase these first, they are ruled out:

- **Spurious interrupts.** MSI is correctly in use (`SUNXI-PCIe-MSI`, `Enable+`,
  `NVreg_EnableMSI=1`) with zero unhandled interrupts.
- **Power management.** Locking clocks to P0 changes nothing.
- **Scheduling.** Happens with `rtkit` working and the KMS thread prioritised.

Leading hypothesis and the work it implies: see the Wayland section of the
[README](../README.md).

---

## A Wayland greeter fails: "not supported by EGL"

```
libEGL warning: failed to open /dev/dri/renderD129: Permission denied
Failed to setup: The GPU /dev/dri/card2 chosen as primary is not supported by EGL.
gdm3: Gdm: GdmDisplay: Session never registered, failing
```

GDM 50 runs its greeter as a **transient user** — look for `/run/user/60583/` or
similar in the log, not the `gdm` uid. Transient users get **no supplementary
groups**, so adding `gdm` to `video` and `render` does not help; the greeter is
not running as `gdm`.

And `uaccess` cannot help either, because this kernel lacks
`CONFIG_TMPFS_POSIX_ACL` (see the next section).

Fix: `files/udev/62-egpu-drm-access.rules`, which opens the DRM nodes to `0666`.

```bash
sudo cp files/udev/62-egpu-drm-access.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=drm
sudo systemctl restart display-manager
```

SDDM does not hit this — its greeter is X11 and Xorg runs as root. If you would
rather not open the nodes, that is a valid workaround; the correct fix is a
kernel rebuilt with `CONFIG_TMPFS_POSIX_ACL=y`.

---

## EGL or GBM cannot open the GPU: "Permission denied"

```
libEGL warning: failed to open /dev/dri/card2: Permission denied
(udev-worker): card2: Failed to apply ACL: Operation not supported
```

The vendor kernel is built **without `CONFIG_TMPFS_POSIX_ACL`**:

```bash
grep TMPFS_POSIX_ACL /boot/config-$(uname -r)
# CONFIG_TMPFS_POSIX_ACL is not set
```

`devtmpfs` therefore cannot store POSIX ACLs, and systemd's `uaccess` tagging —
the normal mechanism that grants the logged-in user access to the GPU — fails
silently every boot. Access falls back entirely to group membership.

This is easy to miss because the two nodes have **different groups**:

```
crw-rw---- root video   /dev/dri/card2
crw-rw---- root render  /dev/dri/renderD129
```

Most users are already in `video`, so KMS works and the desktop appears — but
`render` is usually missing, and without the render node EGL and GBM fail. Fix:

```bash
sudo usermod -aG video,render "$USER"
```

Then **log out and back in** — group changes only apply to new sessions.

---

## After an upgrade

```bash
sudo egpu-health
```

```
FALHA: modulo NVIDIA 580.142 nao casa com userspace 580.150
```

Repair:

```bash
sudo egpu-health --repair          # restores modules from /root/egpu-backup
```

If userspace moved forward, either downgrade it to match or rebuild the modules
against the new version. Then re-apply the holds and the pin — see Part 6 of the
tutorial.

If the **kernel** changed, the modules must be rebuilt; there is no shortcut.

---

## Wallpaper is black after moving X to the GPU

Not a fault. XFCE stores wallpapers per monitor name and the name changed. See
§4.4 of the tutorial.

---

## Useful one-liners

```bash
# Full stack verdict
sudo egpu-health

# What did the boot decide, and why?
journalctl -t egpu-video-apply -t egpu-pcie-recover -b

# Is the display engine actually running?
nvidia-smi --query-gpu=power.draw,clocks.gr,pstate --format=csv
#   P8 / 210 MHz / ~12 W  -> idle (normal with a static desktop)
#   P0 / 2017 MHz / ~35 W -> active

# Which driver is X really using?
grep -E "ServerLayout|_drv\.so|\(EE\)" /var/log/Xorg.0.log

# Connector state without starting X
for c in /sys/class/drm/card*-*; do
    printf '%-24s %s\n' "$(basename "$c")" "$(cat "$c/status")"
done
```
