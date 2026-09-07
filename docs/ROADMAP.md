# Roadmap

Written 2026-09-07, right after the link went from Gen1 to Gen2 and Gen3 hit the
GSP wall. Ordered by gain against risk. Each step says what it proves and how to
back out. Background for every item is in [PCIE-LINK-SPEED.md](PCIE-LINK-SPEED.md).

## Phase 0 — Consolidate Gen2 (low risk)

> **Status 2026-09-08.** Step 1 done: the v1.2 image is built, sanitised,
> verified and split, ready to publish (`docs/RELEASE-NOTES-v1.2.md`). Step 2:
> the kernel cross-compiles cleanly (same 319 modules and vermagic as the card),
> but three test boots failed — because the `uImage` had been wrapped with
> `mkimage -A arm64`. The A733's vendor U-Boot is 32-bit and its `bootm`
> silently rejects a legacy image tagged AArch64; the vendor wraps the arm64
> `Image` with **`-A arm`**. RELR packing and the toolchain were red herrings,
> although the final build uses the exact Arm GNU Toolchain 11.2-2022.02 with
> RELR off to stay byte-for-byte comparable. A second real finding: the DTB in
> `/boot` (built July) differs in 648 lines from the one compiled from the
> GitHub tree (April): CPU OPP tables, GPU power domain, USB `res_dcap` clocks.
> The public tree is not the tree that built the shipped kernel, so a rebuilt
> kernel must ship with its own DTB (matched pair), which the eGPU overlays
> apply to unchanged.

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
