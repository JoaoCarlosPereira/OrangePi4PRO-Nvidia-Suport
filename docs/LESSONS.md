# Lessons

Working notes carried between sessions of this project, consolidated on
2026-09-07. Each one cost time to learn. Newer notes first.

## PCIe link speed (2026-09-07)

- **Hardware:** the A733 has one PCIe lane (x1 is final), Gen1–Gen3. The vendor
  DT already asks for `max-link-speed = <3>`; Gen1 was only our overlay. The M.2
  slot does Gen3 with an NVMe drive (Haidegger22/orangepi4pro-nvme-boot-no-sd).
- **Measured:** Gen1 199 MB/s; Gen2 398–418 MB/s, CUDA passes, 300 probes clean;
  Gen3 trains at 8 GT/s with equalization complete and AER at zero, but
  `modprobe nvidia` ends in `Xid 62` (GSP halt) three times out of three, with
  AER still clean — not link corruption.
- **The driver's log lies.** The sunxi driver prints the *target* link speed
  (LnkCtl2), not the negotiated one, and "Speed change timeout" with Gen1 forced
  is an artifact (the bit has nothing to do). Real speed:
  `/sys/bus/pci/devices/0000:01:00.0/current_link_speed` or the kernel's
  "available PCIe bandwidth" line.
- **The GPU mirrors the host.** The GPU firmware copies the root port's `LnkCap`
  into its own about 2 s after every `PERST#`; it survives `rmmod` and warm
  reboots. The root port must advertise the target speed *before* the GPU comes
  out of reset (i.e. in the DT), otherwise `DIRECT_SPEED_CHANGE` clears in 0 ms
  and nothing happens.
- **Idle looks like Gen1.** The NVIDIA driver parks the link at 2.5 GT/s in P8
  and ramps under load. A static read on an idle desktop shows 2.5 GT/s at any
  configured speed.
- **The NSI limiter is the exact ceiling.** The driver sets the PCIe master's
  bandwidth limit to 200/400/700 MB/s per gen; measured throughput lands on it.
- **U-Boot trains first.** The image's U-Boot runs `pci enum` at Gen3 before
  Linux; every kernel log shows "pcie is already link up".
- **How the board was frozen, so nobody repeats it:**
  1. A `watch nvidia-smi` in a terminal reloaded the modules between `rmmod` and
     the controller unbind; unbinding with `nvidia` bound freezes the board.
     Before link experiments: stop the display manager, `install nvidia
     /bin/false` in `modprobe.d`, `fuser -k /dev/nvidia*`, confirm `lsmod` empty.
  2. Two unbind/bind cycles about 12 s apart froze the board with no watchdog
     recovery; only mains power fixed it. One `PERST#` per experiment, then
     wait at least 5 s.
  3. `pkill -f <string>` inside an SSH command whose own command line contains
     the string kills the session itself.
- Tools installed on the board in `/usr/local/sbin`: `egpu-pcie-linkinfo`
  (read-only), `egpu-pcie-retrain <gen> --stress N` (refuses with nvidia
  loaded), `egpu-pcie-bandwidth`.

## Two images, only one publishable (2026-09-05)

- `orangepi4pro-egpu-reduzida.img.xz` is a **private backup**: Chrome cookies
  and passwords, agent sessions, SSH keys, `/etc/shadow`. Never publish.
- `orangepi4pro-egpu-distribuivel.img.xz` is the sanitised one in the release,
  split into `part-0`/`part-1` for GitHub's 2 GB limit.
- What nearly leaked were **backup copies**, not originals: Chrome creates
  `google-chrome-backup-crashrecovery-*` next to the profile (540 MB each, with
  `Cookies` and `Login Data`), and `/etc/shadow-` keeps the previous password
  database. Sanitise with globs, not exact names.
- `chroot` to change a password **fails silently** on a host of a different
  architecture (x86_64 cannot run aarch64 `chpasswd`). Edit `/etc/shadow`
  directly and verify.

## Testing video output on an NVIDIA GPU (2026-09-05)

- **`modetest` is useless against `nvidia-drm`.** No dumb buffers, so
  `modetest -s` prints "setting mode" and exits 0 while "failed to create dumb
  buffer" scrolls past. It sets a mode with nothing to scan out. It also dies
  with the SSH session unless launched via `systemd-run`.
- **Raw BAR1 reads are not a health check.** BAR1 is an MMU-translated window
  into VRAM; unmapped offsets legitimately return zeros.
- **The test that counts:** `nvidia_drm modeset=1 fbdev=1`, write to `/dev/fb0`
  **and read it back**. Colour bars plus a one-pixel marker at a known
  coordinate confirm the mapping address by address on the panel.
- **Testing a high PCIe window:** program a spare outbound ATU region mapping a
  high address onto BAR0's PCI address and compare with the direct BAR0 read
  (`/dev/mem` works, `CONFIG_STRICT_DEVMEM` is off; ATU outbound at
  DBI+0x300000, 0x200 per region).
- **Leftover state:** `fbset -g 1024 768` persists and shows the top-left corner
  of a larger buffer — looks exactly like broken scanout. Run `fbset -i` first.
- **"No signal" and "black screen" are different diagnoses.** No signal = TMDS
  not driven. Black = signal present, content is the problem. Ask which.

## Not breaking the desktop (2026-09-05)

1. **`options nvidia_drm ... fbdev=1`** moves `fbcon` to the NVIDIA framebuffer,
   which comes out of the 3050's HDMI ports. The monitor on the Orange Pi's
   HDMI goes black with only a cursor. Never use `fbdev=1` until the 3050's
   output is proven.
2. **Loading `nvidia_drm` at boot without pinning the Xorg layout** makes X
   attach the GPU as a secondary GPU screen, fall back to `modesetting` on the
   NVIDIA DRM node and hang loading `glamoregl`; lightdm restarts 5x and gives
   up. Antidote: `Option "AutoAddGPU" "off"` in
   `/etc/X11/xorg.conf.d/05-no-autoaddgpu.conf`.
- Safety nets on the board: `egpu-video-check` / `-enable` / `-disable` in
  `/usr/local/sbin`, plus `OnFailure=egpu-video-rollback.service` on lightdm.
- `nvidia_drv.so` is **not** in `/usr/lib/xorg/modules/drivers/` but in
  `/usr/lib/aarch64-linux-gnu/nvidia/xorg/`, the `ModulePath` declared in
  `10-nvidia.conf`.

## Platform facts

- Board: Orange Pi 4 Pro, Allwinner A733, vendor kernel 6.6.98-sun60iw2,
  Ubuntu 26.04 "Orange Pi 1.1.0". GPU: MSI RTX 3050 6GB (`10de:2584`).
- The technical diary lives **on the board**, `/home/orangepi/egpu-progress.md`,
  listing hypotheses already tested and **refuted** — read before touching
  anything. Patched NVIDIA 580.142 source in
  `/home/orangepi/egpu-nvidia-580.142-full` (branch `egpu-a733-580.142`); kernel
  source in `/home/orangepi/egpu-linux` (PCIe driver in `bsp/drivers/pcie/`).
- A warm SoC reset leaves the GPU powered and half-initialised; it then refuses
  to train the link. Only cutting the eGPU PSU's power recovers it.
- For unattended `sudo` over SSH, use a temporary askpass script and
  `SUDO_ASKPASS=... sudo -A`.
