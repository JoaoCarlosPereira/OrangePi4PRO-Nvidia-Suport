# Phase 3 plan: boot media, and what the other Orange Pi 4 Pro projects found

Written 2026-09-07 after surveying the public Orange Pi 4 Pro / Allwinner A733
work on GitHub. Two goals, from the [roadmap](ROADMAP.md): make this image boot
without a microSD card (USB or NVMe), and fold in community findings that
measurably improve the board. A third item emerged from the survey and is
recorded at the end because it changes the Gen3 picture in Phase 1.

## 1. What is out there

| Project | What it is | What we can take |
|---|---|---|
| [TblP/orangepi-uboot-fix](https://github.com/TblP/orangepi-uboot-fix) | The one-line U-Boot fix: `pcie3v3_supply = "dc1sw2"` → `"dc1sw1"`. U-Boot switched on the wrong 3.3 V rail, so the M.2 slot was dead until Linux started. | The patch, verified against AXP8191 register 0x11 at the U-Boot prompt. SPI NOR flashing procedure and its risks. |
| [Haidegger22/orangepi4pro-nvme-boot-no-sd](https://github.com/Haidegger22/orangepi4pro-nvme-boot-no-sd) | Full recipe: orangepi-build for U-Boot `v2018.05-sun60iw2`, `pack_uboot_spinor.sh` for the boot package on an arm64 host, flashing SPI NOR, rootfs UUID pitfalls, measured NVMe at Gen3 (610–640 MB/s). | The build and packaging steps, `bootcmd_nvme`, the checks that the stock DTB is Gen3. |
| [CarterPerez-dev/orangepi-4-pro-nvme-fix](https://github.com/CarterPerez-dev/orangepi-4-pro-nvme-fix) | Phison-based SSDs (Kingston NV3, Samsung PM9B1, Pi NVMe) **drop off the bus** during the sunxi driver's Gen3 speed change; WD SN740/SN770/SN580 survive. Workaround: `max-link-speed = <1>`. RESEARCH.md ties it to the same DesignWare "Speed change timeout / roll back to Gen1" bug class as i.MX6 and RK3399, and notes Radxa's WIP compatibility patches for the same SoC (Cubie A7A, `cubie-image/sun60iw2p1`). | A second, independent case of the vendor speed-change path breaking endpoints. Radxa's patches are a lead for Phase 1. |
| [jonas5/orangepi-4pro-armbian](https://github.com/jonas5/orangepi-4pro-armbian) | **Mainline Linux 7.1.5** on the A733 with a single 55-file patch: DTS, CCU, pinctrl, thermal, AXP8191, GMAC, MMC, display (`sun60i-de/hdmi/tcon`), crypto, and the SerDes/PCIe/USB3 PHYs (`phy-sun60i-*.c`). PCIe Gen3 x1 and NVMe work with the mainline DesignWare controller driver. Vendor U-Boot still required. NPU, ISP, HDMI audio not working. | A working mainline kernel for this board, with PCIe on the mainline `pcie-designware` core instead of the BSP fork. |
| [armbian/build PR #9967](https://github.com/armbian/build/pull/9967) | Community (`.csc`) Armbian board config on the vendor 6.6 kernel and 2018 U-Boot. `armbian-install` handles NVMe boot; QEMU used for the x86-only Allwinner pack tools. Radxa's PowerVR blobs + Mesa-PVR give GPU/VPU acceleration on the A733's own GPU. | A maintained build recipe, and the pointer to PowerVR userspace for the SoC GPU. |
| [JerrettDavis/orangepi4pro-board-support](https://github.com/JerrettDavis/orangepi4pro-board-support) | Config fragments (HID multitouch etc. missing from the vendor 5.15 kernel), TOC1 boot-package inspection/repacking tooling, NVMe-first boot direction. | The TOC1 tooling if we repack the boot area ourselves. |
| [blippu/orangepi4pro](https://github.com/blippu/orangepi4pro) | Vendor kernel rebuilt with TUN, MQUEUE, OverlayFS, UTF-8. | Config options to check in ours (Docker/Tailscale users). |
| [DietPi releases](https://github.com/MichaIng/DietPi/releases) | Ships Orange Pi 4 Pro images on the vendor 6.6 kernel and vendor U-Boot. | Nothing new for PCIe; confirms mainline U-Boot has no A733 support. |

Boot-order facts that constrain everything below: the A733 BROM looks at
microSD, eMMC and SPI NOR only. Neither NVMe nor USB is a BROM boot source. So
"boot from USB/NVMe" always means **U-Boot lives on the SPI NOR** and finds the
rootfs on the other medium. Mainline U-Boot has no A733 port; the vendor
`v2018.05-sun60iw2` tree is the only option.

## 2. Step 9 — Boot without a microSD

### 2.1 What is broken today, precisely

The U-Boot in our image (control DTB at boot-area offset `0x111d7b8`) has
`pcie3v3_supply = "dc1sw2"`. The slot is on `dc1sw1`. For an NVMe drive that
means no power and no link. For **our eGPU** the riser is externally powered, so
the link trains anyway — that is why every kernel log shows "pcie is already
link up" — but the bug is still there for anyone who puts an SSD in the slot.

USB is a separate question. The vendor `distro_bootcmd` lists targets; we know
`bootcmd_nvme` (`pci enum; nvme scan; ...`) is present. Whether `bootcmd_usb`
is present and whether `usb start` works on this U-Boot has **not** been
checked. It is the first thing to test at the U-Boot prompt.

### 2.2 Plan

1. **Serial console first.** Everything in this step is diagnosed at the U-Boot
   prompt; SSH is not available that early. Confirm the UART header works and
   log a full boot (`printenv boot_targets`, `usb start; usb storage`,
   `pci enum; nvme scan`).
2. **Rebuild U-Boot** with orangepi-build (`BOARD=orangepi4pro BRANCH=current
   BUILD_OPT=u-boot`), carrying three patches:
   - TblP's rail fix (`dc1sw1`);
   - Haidegger22's `-Werror` disable for modern GCC;
   - **our own decision on `pci enum`** (roadmap step 7): for the eGPU image,
     either drop it from the boot command or add `reset-gpios` so U-Boot performs
     a proper `PERST#`. Two link trainings per boot are today's source of the
     "already link up" path.
   Check the produced `u-boot-dtb.dts` for the three changes before packing.
3. **Pack and test from SD, not SPI.** Write the new boot package into the SD
   card's boot area (same offsets the image uses) on a *spare* card. Boot it. If
   it fails, the old card still boots. Only then move to SPI.
4. **SPI NOR.** Dump the 16 MiB first (`dd if=/dev/mtd0`), then write the boot
   package at offset `0x40000` following TblP's procedure: full-image write,
   read back, compare hashes, **do not power off until they match**.
5. **Rootfs on USB.** Flash our image to a USB SSD/stick, fix `rootdev=` in
   `/boot/orangepiEnv.txt` and `/etc/fstab` to the new UUID (Haidegger22's
   pitfall), remove the microSD, boot. Success: the kernel log shows the root
   device on `sd*`, `egpu-video-apply` brings the desktop up on the 3050.
6. **Ship it.** The v1.x image keeps booting from SD as today. The SPI/USB path
   becomes a documented option (`docs/BOOT-WITHOUT-SD.md`) plus a small script
   that flashes the boot package with the readback check.

Risks: a bad SPI write is recoverable only by booting from SD and rewriting;
a partial write during power loss can brick boot0 until the SD path is used.
Never do step 4 with the GPU experiments of Phase 1 in the same session.

## 3. Step 10 — Community improvements worth measuring

Rule: reproduce the author's number on our board before and after; keep only
what moves a number we can show; credit the source in the README.

| Candidate | Source | Measure | Expected value |
|---|---|---|---|
| Kernel options TUN, POSIX_MQUEUE, OVERLAY_FS, UTF-8 | blippu | `zcat /proc/config.gz`; Docker/Tailscale start | Convenience; zero risk once we rebuild the kernel anyway (Phase 0) |
| HID multitouch / UHID / UINPUT | JerrettDavis | touchscreen and gamepad detection | Convenience; same rebuild |
| PowerVR blobs + Mesa-PVR for the SoC GPU | Armbian PR comments | `glxinfo` on the Allwinner HDMI | Useful only when the eGPU is off; low priority for this project |
| `armbian-install` style NVMe/USB install flow | Armbian PR | boots without SD | Feeds step 9 |
| Thermal/DVFS tables | jonas5 (mainline thermal driver), Armbian | `sensors`, sustained `stress-ng` clocks | Verify the vendor kernel is not throttling under eGPU load |
| Radxa `sun60iw2p1` PCIe compatibility patches | CarterPerez RESEARCH.md | our Phase 1 Gen3 test | Possibly the fix for the speed-change path itself |

## 4. The mainline track (new, from the survey)

jonas5's work means the A733 runs mainline 7.1.5 with PCIe Gen3 x1 on the
**mainline DesignWare driver**, not the BSP fork whose speed-change sequence
breaks Phison SSDs and (plausibly) the GSP boot of our GPU. That is a
structurally different route to Gen3:

- the mainline `pcie-designware` core does the Gen3 equalization and speed
  change the standard way, with `max-link-speed` honoured by the core;
- mainline arm64 handles non-coherent PCIe DMA through the normal DMA API, so
  the NVIDIA non-coherent patch (PR972) would need re-evaluation rather than
  the vendor-kernel workaround;
- the NVIDIA 580 open modules build against recent kernels, but 7.1 will need
  checking for compat breaks.

Cost: a new kernel, new DTB, new module build, and losing vendor-only pieces
(NPU, ISP, HDMI audio) that this project does not use. Gain: a PCIe stack that
is maintained upstream, and an answer to whether the `Xid 62` at Gen3 is the
BSP driver's fault. **Recommendation:** run it as an experiment on a separate SD
card after Phase 1 step 4, not as a replacement for the shipped image until it
matches everything the vendor kernel does for us.
