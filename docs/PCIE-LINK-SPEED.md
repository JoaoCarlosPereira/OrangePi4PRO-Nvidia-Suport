# PCIe link speed: Gen1 x1 was not the ceiling

**Result (2026-09-07): the shipped image now runs the link at Gen2 x1 — 5.0 GT/s,
about 400 MB/s each way, twice what Gen1 gave — validated end to end with the
NVIDIA driver, CUDA and 300 error-free link probes. Gen3 x1 trains perfectly
(8.0 GT/s, equalization complete, zero physical-layer errors, 20 000 clean MMIO
reads) but the GPU's GSP firmware halts during driver init at that speed
(`Xid 62`), three times out of three, so Gen3 is not usable yet.**

The lane count is hardware: the Allwinner A733 has exactly one PCIe lane, so x1
is final and x4/x16 are impossible. The speed was software all along. Two things
kept Gen1 in place, and both were software:

1. The vendor driver's log lines about speed are not measurements (§3.1), so the
   early observation "it tries a speed change, times out, and ends up at Gen1" was
   never evidence of anything.
2. The NVIDIA firmware **copies the root port's advertised maximum into the
   GPU's own `LnkCap`** a couple of seconds after every reset (§3.2). Once the
   root port has said "2.5 GT/s" once, the GPU says it too. That made every
   partial experiment done with the Gen1 overlay look like "the GPU won't go
   faster".

Measured on the board, same riser, same cable, same PSU:

| Boot configuration | Link | `egpu-pcie-bandwidth` host→GPU / GPU→host | CUDA | Driver init |
|---|---|---|---|---|
| `egpu-pcie-gen1` (v1.1 image) | 2.5 GT/s x1 | 199 / 199 MB/s | PASS | clean |
| **`egpu-pcie-gen2` (now)** | 5.0 GT/s x1 | **398 / 398 MB/s** (410 / 418 with the NSI limit at 700) | **PASS** | **clean** |
| stock DT, no overlay | 8.0 GT/s x1 | — | `CUDA_ERROR_UNKNOWN` | `Xid 62`, `NV_ERR_RESET_REQUIRED` |

---

## 1. What the hardware can do

### 1.1 The A733 manual (v0.92, §18.2–18.3)

- One PCIe controller, "PCIe3.0 DM", DesignWare-based.
- "Supports Gen1 (2.5Gbps), Gen2 (5Gbps), Gen3 (8Gbps) speed". "Link Width: **1 lane**".
- PHY `COMB1_PHY_SERDES`, shared with USB3.1: "Supports up to 1 Lane", "PCIe Gen 1,
  2 and 3, up to 8Gbps".

### 1.2 The vendor device tree ships Gen3

`arch/arm64/boot/dts/allwinner/sun60iw2p1.dtsi`, node `pcie@6000000`:

```dts
compatible = "allwinner,sunxi-pcie-v300-rc";
num-lanes = <1>;
max-link-speed = <3>;
```

`egpu-pcie-gen1.dtbo` overwrote exactly one property. `egpu-pcie-gen2.dtbo` now
does the same with `<2>`.

### 1.3 U-Boot trains the link before Linux, at Gen3

The U-Boot control DTB embedded in the image (boot area offset `0x111d7b8`) has
the same node with `max-link-speed = <3>`, `status = "okay"`, and the boot command
runs `pci enum; nvme scan`. **Every boot has two link trainings**: U-Boot at
Gen3, then Linux. Every kernel log shows it:

```
[    1.905] sunxi:pcie-rc-6000000.pcie:[INFO]: pcie is already link up
```

On every boot observed the first Linux probe inherited U-Boot's link. When the
GPU had been power-cycled it was enumerated right there; after a warm reset it
was not, and `egpu-pcie-recover`'s rebind (a fresh `PERST#`) brought it in. The
U-Boot node also names the wrong 3.3 V rail (`pcie3v3_supply = "dc1sw2"`, the
slot is on `dc1sw1` — see §2.3); Linux is unaffected because its DT wires the
supply to the always-on parent rail `dcdc1`.

---

## 2. Proof that this slot does Gen3, and where the GPU stops

### 2.1 Live measurements, 2026-09-07

Runtime retrain from a Gen1 boot, NVIDIA modules unloaded, one `PERST#` via
controller rebind so the GPU forgets the Gen1 host (§3.2), then
`egpu-pcie-retrain`:

```
[before] LnkSta 2.5 GT/s x1 | EqComplete=0 | LTSSM=0x11 (L0) | AER CESta=00000000
target Gen2 → [after] 5.0 GT/s x1 | AER clean | OK: 5000 BAR0 reads
target Gen3 → speed-change bit cleared after 0.3 ms
             [after] 8.0 GT/s x1 | EqComplete=1 Ph1=1 Ph2=1 Ph3=1 LinkEqReq=0 | AER CESta=00000000
             OK: 20000 BAR0 reads (boot0=0xb77000a1), AER clean
```

Cold boot with the stock DT (no Gen1 overlay), NVIDIA blocked for that boot:

```
[    1.905] sunxi:pcie-rc-6000000.pcie:[INFO]: PCIe speed of Gen3
[    1.922] pci 0000:01:00.0: 7.876 Gb/s available PCIe bandwidth, limited by 8.0 GT/s PCIe x1 link
GPU LnkCap=00454d04 (16 GT/s)   RC LnkCap=00737c13
```

Gen3 equalization completes in well under a millisecond, and the channel —
riser, cable and all — carries 8 GT/s with no `RxErr`, `BadTLP` or `BadDLLP`
under MMIO traffic and under `egpu-link-margin` with the driver loaded. The
"marginal link" hypothesis in the README was formed at Gen1 and does not
transfer to Gen3 as-is.

### 2.2 The Gen3 wall: `Xid 62` at driver init

Loading `nvidia` on an 8 GT/s link, three times (runtime retrain, cold stock-DT
boot, and after a fresh `PERST#`), always ended the same way within two seconds:

```
NVRM: Xid (PCI:0000:01:00): 62, 5236acff c008c040 00000000 202a5b42 2025ef7c ...
NVRM: rpcRmApiAlloc_GSP: GspRmAlloc failed ... status=0x00000062
NVRM: Assertion failed: Reset required [NV_ERR_RESET_REQUIRED]
```

`Xid 62` is "internal micro-controller halt": the GSP, which the open kernel
modules boot on the GPU before anything else works, stops. `nvidia-smi` then
cannot talk to the driver and `cuInit`/`cuCtxCreate` fail. **AER on both link
partners stayed completely clean through the failure** — the counters were
cleared immediately before `modprobe` and read back zero afterwards — so this is
not corrupted TLPs on the wire. After a `PERST#` the same GPU boots the GSP
cleanly at Gen1 or Gen2. The speed is the only variable.

What is different about Gen3 for the GSP boot, in order of likelihood:

1. **DMA timing on a non-coherent Arm.** The GSP firmware and its RPC queues
   move host↔GPU by DMA through the `nvidia-arm-noncoherent-pr972.patch` cache
   maintenance path. A 4x faster link exposes any ordering or flush race that
   Gen1/Gen2 hide. This is the hypothesis to chase first, because it is software.
2. A GPU-side PCIe power/EQ state that the RM programs at Gen3 (it does its own
   speed management: idle at Gen1, ramping under load) interacting with a root
   port that never sees a `RATE_SHADOW`/EQ redo — see §5.3 for the controller's
   Gen3 registers.
3. Payload-level signal integrity that AER cannot see (bit errors inside a TLP
   with a valid LCRC are impossible; errors are either caught or absent — so
   this one is *unlikely*, and it is listed only for completeness).

### 2.3 The NVMe community result on the same slot

[Haidegger22/orangepi4pro-nvme-boot-no-sd](https://github.com/Haidegger22/orangepi4pro-nvme-boot-no-sd),
building on [TblP/orangepi-uboot-fix](https://github.com/TblP/orangepi-uboot-fix),
boots from a WD SN750 in the M.2 slot with the stock DTB: `PCIe speed of Gen3`,
`7.876 Gb/s available`, 610–640 MB/s sustained reads. An NVMe controller has no
GSP to boot, which is consistent with §2.2. Two register addresses from TblP's
U-Boot patch are used by `egpu-pcie-linkinfo`: LTSSM state at DBI `0x06000728`
(`PCIE_PL_DEBUG0[5:0]`, `0x11` = L0) and link-up at `0x06400e0c`.

---

## 3. The two software mechanisms that hid all this

### 3.1 The driver reports the request, not the result

`bsp/drivers/pcie/pcie-sunxi-rc.c`:

- `sunxi_pcie_host_read_speed()` reads `LINK_CONTROL2_LINK_STATUS2` (DBI 0xa0)
  `& 0xf` — **LnkCtl2 Target Link Speed**, what the driver just wrote.
  "PCIe speed of GenN" always echoes the request.
- `sunxi_pcie_host_wait_for_speed_change()` gives `DIRECT_SPEED_CHANGE`
  (DBI 0x80c bit 17) 20 × `usleep_range(100, 1000)` = **2–20 ms**, and on timeout
  prints "PCIe speed of Gen1" **unconditionally**.
- With the Gen1 overlay the link was already at Gen1 when Gen1 was requested; the
  bit had nothing to do and never self-cleared, so `Speed change timeout` fired on
  **every** boot. With the stock DT the same code path logs
  `PCIe speed of Gen3` with no timeout — the bit clears in 0.3 ms.

`files/patches/sunxi-pcie-report-real-link-speed.patch` fixes both (wait up to
~500 ms, always log `LnkSta.CurrentLinkSpeed`). It needs a kernel rebuild
(`CONFIG_AW_PCIE_RC=y`), so it is a quality-of-life fix, not a prerequisite.

### 3.2 The GPU mirrors the root port's `LnkCap`

Polling the GPU's PCIe capability after a `PERST#`, no driver loaded, root port
advertising 2.5 GT/s:

```
 +1s  GPU LnkCap=00453d04 LnkCtl2=0004   <- hardware default, 16 GT/s
 +3s  GPU LnkCap=00453d01 LnkCtl2=0000   <- clamped to the host's 2.5 GT/s
 +6s  GPU LnkCap=00453d01 LnkCtl2=0000
```

The GPU's boot firmware reads the upstream port's maximum and lowers its own
advertised maximum to match; the kernel driver does the same at init
(`pcie.link.gen.hostmax` in `nvidia-smi` is that value). Consequences:

- A DesignWare root port only starts a speed change if the partner advertised
  a higher rate in the last training. With the GPU clamped to Gen1,
  `DIRECT_SPEED_CHANGE` self-clears in 0 ms and nothing happens.
- The clamp **survives `rmmod`, survives a warm reboot, and is re-applied ~2 s
  after every `PERST#`** from whatever the root port advertises at that moment.
- So the root port must advertise the target speed *before* the GPU comes out
  of reset. That is what the device tree does, and why a cold power-up after
  changing the overlay is the clean test.

This also reframes the README's "warm reset wedges the GPU": part of what a warm
reset leaves behind is a GPU that has memorised a Gen1 host.

---

## 4. How the board was frozen twice, so nobody repeats it

### 4.1 Rebinding the controller with the NVIDIA driver bound

Between `rmmod nvidia` and the rebind, a `watch -n 1 nvidia-smi` left in a
terminal reloaded the modules — `nvidia-smi` calls `nvidia-modprobe`, so **any
nvidia-smi anywhere reloads the driver within a second of it being removed**.
The rebind then removed a PCI device with `nvidia` bound to it and the board
locked up; the hardware watchdog rebooted it a minute later.

Guard used afterwards, recommended for any link experiment:

```bash
sudo systemctl stop display-manager
printf 'install nvidia /bin/false\ninstall nvidia_drm /bin/false\ninstall nvidia_modeset /bin/false\ninstall nvidia_uvm /bin/false\n' \
  | sudo tee /etc/modprobe.d/zz-egpu-experiment.conf
sudo fuser -k /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm
sudo rmmod nvidia_drm nvidia_modeset nvidia_uvm nvidia
lsmod | grep -c '^nvidia'          # must print 0
sudo rm /etc/modprobe.d/zz-egpu-experiment.conf   # when done
```

`egpu-pcie-retrain` refuses to run while any `nvidia*` module is loaded.

### 4.2 Two `PERST#` cycles a few seconds apart

With nothing bound, one unbind/bind cycle worked five times in a row across the
session. A second cycle issued ~12 s after the first hung the board hard and the
watchdog did **not** bring it back — most likely U-Boot's `pci enum` (§1.3)
stalling on a GPU left mid-devinit. Recovery needed mains power off on the GPU
PSU and the board, GPU PSU on first.

Rule: **one `PERST#` per experiment, then leave the GPU alone for at least
five seconds.** If a second reset is needed, cut the GPU's power instead.

---

## 5. Remaining work

### 5.1 Gen2 is the default, validated warm and cold

`/boot/orangepiEnv.txt` carries `user_overlays=egpu-pcie-gen2 egpu-pcie-highmem`
and `/boot/overlay-user/egpu-pcie-gen2.dtbo`. Validated on a warm reboot and on
a cold power-up (GPU PSU off and on): kernel `4.000 Gb/s available PCIe
bandwidth, limited by 5.0 GT/s PCIe x1 link`, GPU enumerated on the first probe,
desktop on the GPU, no `Xid`, CUDA passes, 398 MB/s each way, 300 probes clean.
On the cold start U-Boot trains Gen3 first and Linux downshifts to Gen2 in
`setup_rc`; the root port's sticky `RxErr+` seen right after boot comes from that
transition and does not recur once cleared. The previous configuration is in
`/boot/orangepiEnv.txt.before-gen3-test` (Gen1) if it ever needs to come back.

Idle behaviour is normal and not a regression: the NVIDIA driver parks the link
at 2.5 GT/s in P8 and ramps it under load, so `current_link_speed` reads
2.5 GT/s on an idle desktop. Measure with `egpu-pcie-bandwidth`, not with a
static read.

### 5.2 The NSI bandwidth limiter costs a few percent

The vendor driver sets the PCIe master's NSI bandwidth limit from the *requested*
gen: 200, 400 or 700 (MB/s). `egpu-pcie-bandwidth` returns 398 MB/s on a Gen2
boot (limit 400) and 410–418 MB/s on the same Gen2 link when the limit was left
at 700 by a Gen3 boot. Gen1's 199 MB/s was likewise pinned at its 200 limit. The
driver patch is the place to lift it (set 700 for every gen, or skip the call);
until the kernel is rebuilt this is the ceiling and it is close enough.

### 5.3 Getting to Gen3: what to try, in order

1. **Instrument the GSP boot.** `NVreg_RmMsg=`/`NVreg_ResmanDebugLevel` in
   `/etc/modprobe.d`, then load at Gen3 and capture the last RPC before `Xid 62`.
   If the halt is in firmware transfer or queue setup, hypothesis 1 of §2.2
   (non-coherent DMA race) is confirmed and the fix is in
   `nvidia-arm-noncoherent-pr972.patch`, not in the PCIe stack.
2. **Load at Gen2, then retrain to Gen3 with the driver running.** The RM
   handles speed changes itself (it already drops to Gen1 at idle). If the GSP is
   fine once booted and only the *boot* at Gen3 fails, `egpu-pcie-retrain 3`
   after a successful Gen2 init isolates that — but it must be done with a way to
   power-cycle the GPU at hand, and the script's `nvidia*` guard has to be
   bypassed deliberately for that one test.
3. **Controller-side Gen3 knobs**, all writable through `/dev/mem`, as read on
   the live board:

   ```
   0x890 GEN3_RELATED_OFF = 0x00002001  (RXEQ_RGRDLESS_RXTS=1, ZRXDC_NONCOMPL=1, EQ enabled)
   0x8a8 GEN3_EQ_CONTROL  = 0x04059f60  (FB_MODE=0 direction change, PSET_REQ_VEC=0x059f)
   ```

   Equalization completed with these defaults, so they are not the cause of the
   `Xid`, but `PSET_REQ_VEC=0x3ff` / `FB_MODE=1` are the standard things to
   vary if a Gen3 boot ever fails EQ.
4. **U-Boot**: rebuild without `pci enum` (or with TblP's rail fix and a
   `reset-gpios`) so the GPU sees one clean training per boot. This is the fix
   for the "first probe does not enumerate after a warm reset" symptom, and it
   removes one variable from any Gen3 work.

---

## 6. Files added for this investigation

| File | Purpose |
|---|---|
| `files/overlays/egpu-pcie-gen2.dts` | The new default: `max-link-speed = <2>` |
| `files/scripts/egpu-pcie-linkinfo` | Read-only snapshot: both partners' LnkCap/LnkSta/LnkSta2, AER, DWC Gen3 registers, LTSSM |
| `files/scripts/egpu-pcie-retrain` | Runtime speed change to Gen1/2/3 with MMIO stress; refuses to run with NVIDIA loaded |
| `files/scripts/egpu-pcie-bandwidth` | CUDA driver-API host↔GPU copy bandwidth, pinned memory, integrity check |
| `files/patches/sunxi-pcie-report-real-link-speed.patch` | Driver: ~500 ms speed-change wait, log the measured speed, NSI bandwidth cap lifted to 700 for every gen |
| `tools/kernel/build-kernel.sh` | The exact cross-build recipe that produced a booting kernel (toolchain, RELR, `mkimage -A arm`, matched DTB) |
