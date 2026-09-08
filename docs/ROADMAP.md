# Roadmap

Written 2026-09-07, right after the link went from Gen1 to Gen2 and Gen3 hit the
GSP wall. Ordered by gain against risk. Each step says what it proves and how to
back out. Background for every item is in [PCIE-LINK-SPEED.md](PCIE-LINK-SPEED.md).

## Phase 0 — Consolidate Gen2 (low risk)

> **Status 2026-09-08.** Step 1: the v1.2 image was built, sanitised and
> verified, but will not be published — v1.3 will ship once the rebuilt kernel
> is in it. Step 2 **done**: the kernel cross-built with the vendor's Arm GNU
> Toolchain 11.2-2022.02 (RELR off, `mkimage -A arm`, DTB from the same tree)
> boots on both cards. On the Gen2 card: 410/418 MB/s host↔GPU (was 398 with
> the NSI cap), CUDA passes, 200 probes clean, cpufreq 1.8/2.0 GHz, and the
> driver now logs the measured speed with no "Speed change timeout". Three
> test boots failed first because the `uImage` was tagged AArch64; the vendor
> U-Boot is 32-bit and wants `-A arm`. Second finding: the DTB in `/boot`
> (built July) differs in 648 lines from the GitHub tree (April), so a rebuilt
> kernel must ship with its own DTB. Recipe: `tools/kernel/build-kernel.sh`.
> Phase 3 step 3 is staged: the test card carries the U-Boot boot package with
> the `dc1sw1` fix (readback-verified), awaiting a boot test.

1. **Ship a new image from the board's current state.** The published release
   still carries the Gen1 overlay. Same process as before: shrink, sanitise with
   globs (Chrome backup profiles, `shadow-`), split into 2 GB parts, publish as
   v1.2. Update the download section of the README and PROJECT-LOG.
2. **Rebuild the kernel with the driver patch**
   (`files/patches/sunxi-pcie-report-real-link-speed.patch`) and raise the NSI
   bandwidth limit from 400 to 700. Today it caps transfers at exactly 398 MB/s.
   Keep the version string `6.6.98-sun60iw2` so the NVIDIA modules still load.
   Build on a separate SD card, with `/boot` and the module tarball backed up.
   Success: `egpu-pcie-bandwidth` above 400 MB/s, `dmesg` without
   "Speed change timeout".

## Phase 1 — Unlock Gen3 (the big win: another 2x)

> **Status 2026-09-08.** Steps 3 and 4 done, see PCIE-LINK-SPEED.md §5.3. The
> GSP halts on every Gen3 boot (4/4); a GSP booted at Gen2 works but the RM
> pins its maximum to the speed negotiated at init and no open-side knob raises
> it. Gen3 is blocked in the driver, not in the link. Next: step 5 (DMA patch)
> or a newer driver release.

3. **Instrument the GSP boot.** `NVreg_RmMsg` and `NVreg_ResmanDebugLevel` in
   `modprobe.d`, cold boot with the stock DT and the NVIDIA modules blocked, then
   `modprobe nvidia` while capturing `dmesg`. Goal: which RPC or stage the GSP is
   in when `Xid 62` fires — firmware transfer, queue setup, or already inside the
   RM.
4. **Discriminating test: Gen3 after the GSP is up.** Boot at Gen2, driver
   loaded, CUDA working, then `egpu-pcie-retrain 3` with the module guard
   bypassed on purpose and the GPU's PSU within reach. Two outcomes:
   - CUDA keeps working at 8 GT/s: only the GSP *boot* fails at Gen3. Practical
     fix without touching the driver: DT at Gen2 plus a retrain to Gen3 inside
     `egpu-video-apply` after init. Nearly the full gain.
   - It dies with an Xid: DMA at Gen3 is broken in general. Go to step 5.
5. **Non-coherent DMA hypothesis.** Review the barriers and cache maintenance in
   `nvidia-arm-noncoherent-pr972.patch` on the GSP RPC queues, compare with the
   upstream PR discussion, test variants. Driver work, not PCIe work. Only enter
   here if step 4 points at it.
6. **Controller equalization presets** (`0x8a8`, `0x890`) are the last resort.
   Equalization completed cleanly in every test, so they are not the current
   cause.

## Phase 2 — Deterministic boot, and telling people

7. **U-Boot without PCIe.** Rebuild with orangepi-build, applying TblP's
   `dc1sw1` rail fix and removing `pci enum` from the boot command (or disabling
   the `pcie` node in U-Boot's DT — we do not boot from NVMe). Removes the second
   link training per boot, the "already link up" path, and most likely the hang
   after a warm reset. Test from SD before writing to SPI NOR; keep a backup of
   the SPI contents.
8. **Take the findings upstream.** Open an issue or PR on the orangepi-xunlong
   kernel with the driver patch — it fixes a real bug in the log and the
   timeout. Tell the authors of the NVMe-boot repository about the LnkCap
   mirroring, which affects any GPU in that slot.

## Phase 3 — Boot media and community fixes

> **Status 2026-09-08.** Step 9 is two-thirds done. The vendor U-Boot
> (`v2018.05-sun60iw2` @ b791be8) rebuilt with `-Wno-error` and the `dc1sw1`
> rail fix boots the test card from the SD boot area (`bs=8k seek=2050`), and
> the same `boot_package.fex` (1392640 bytes) is now in the **SPI NOR at
> 0x40000**, readback-verified, with the vendor `boot0` at offset 0 untouched
> and a full 16 MiB dump kept in `orangepi-backup/testcard-backup/spinor.bin`.
> Booting from the SPI U-Boot with no microSD present is **verified** with a USB
> stick in a Type-A port; it took a second U-Boot fix (Type-A VBUS enable on
> PB7, active-low — stock U-Boot leaves the ports unpowered). Step 9 done.
> Beyond it: `egpu-install-to-disk` and the first-boot dialog move the root
> filesystem to a fast disk while the medium keeps `/boot`; verified with a
> USB-C SSD (182 MB/s writes) after adding the `egpu-usbc-host` overlay — the
> vendor DT only makes the USB-C port a host from userspace, 11 s into boot. Caveat: the public U-Boot tree is from
> March 2026 while the vendor binary on the cards is from July; nothing broke
> on SD boot, but the July fixes are unknown.

Detailed plan, with the survey of existing projects: [PHASE3-PLAN.md](PHASE3-PLAN.md).

9. **Boot from USB or NVMe without a microSD.** The image's U-Boot cannot bring
   the M.2 slot up on its own: `board-uboot.dts` names the wrong 3.3 V rail
   (`dc1sw2`, the slot is on `dc1sw1`), so `pci enum` finds nothing and the
   NVMe/USB boot targets never get a chance. TblP's one-line patch and
   Haidegger22's build recipe (orangepi-build, `pack_uboot_spinor.sh`) fix it.
   Fold the rail fix into our image's boot area, or into the SPI NOR, and verify
   `bootcmd_usb`/`bootcmd_nvme` actually run from a USB stick with our rootfs.
   Same rebuild carries the `pci enum` decision of step 7. Test from SD first;
   keep a dump of the SPI NOR before writing it.
10. **Survey the other Orange Pi 4 Pro projects on GitHub** and pull in what is
    measurable: thermal and DVFS tables, mainline-kernel progress for the A733,
    U-Boot fixes, PowerVR/`pvrsrvkm` updates, display and audio quirks. For
    each candidate: reproduce the author's measurement on our board before and
    after, keep only what improves a number we can show, and credit the source
    in the README. Candidates and results go into a `docs/COMMUNITY.md`.

## Rules for every experiment

- One `PERST#` per experiment, five seconds of quiet afterwards, GPU PSU within
  reach.
- Before touching the link: stop the display manager, block `modprobe nvidia`,
  kill any `nvidia-smi` loop, confirm `lsmod | grep -c '^nvidia'` prints 0.
- Measure with `egpu-pcie-bandwidth` and `egpu-link-margin`, never with a static
  read of `current_link_speed` — the NVIDIA driver parks an idle link at Gen1.
