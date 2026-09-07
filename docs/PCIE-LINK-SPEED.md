# PCIe link speed: is Gen1 x1 the hardware ceiling?

**Short answer: no.** The lane count is hardware (the A733 has exactly one PCIe
lane), but the *speed* is not. The Gen1 overlay in this repo is the only thing
holding the link at 2.5 GT/s. The same SoC, the same controller, the same PHY and
the same M.2 slot have been measured at **Gen3 x1, 8.0 GT/s, 7.876 Gb/s** with an
NVMe SSD. The theoretical gain for the GPU is therefore **4x** (about 2.0 Gb/s
today against about 7.9 Gb/s), never 16x: x4 or x16 are impossible on this board.

This document records the evidence, explains why the first Gen3 attempts probably
failed, and lays out a plan that tests Gen2 and Gen3 **without rebuilding the
kernel** before anything is made permanent.

Everything below was established offline from the v1.1 image (kernel source,
device trees, the A733 user manual, the U-Boot blob in the boot area), from the
vendor driver source, and from the community NVMe work linked in §2.3. Nothing
here has been run on the board yet. §4 is the plan to do exactly that.

---

## 1. What the hardware can do

### 1.1 The A733 manual (v0.92, §18.2–18.3)

- The SoC has **one** PCIe controller, "PCIe3.0 DM", DesignWare-based.
- "Supports Gen1 (2.5Gbps), Gen2 (5Gbps), Gen3 (8Gbps) speed".
- "Link Width: **1 lane**".
- The PHY is `COMB1_PHY_SERDES`, a combo PHY shared with USB3.1, "Supports up to
  1 Lane", "PCIe Gen 1, 2 and 3, up to 8Gbps".
- The controller exposes the standard DesignWare Gen3 equalization machinery
  (register `SII_GEN3_EQ` at user offset 0x1350 reports
  `smlh_ltssm_state_rcvry_eq`, the LTSSM equalization sub-state).

So: **x1 is fixed by silicon. Gen3 is supported by silicon.**

### 1.2 The vendor device tree ships Gen3

`arch/arm64/boot/dts/allwinner/sun60iw2p1.dtsi`, node `pcie@6000000`:

```dts
compatible = "allwinner,sunxi-pcie-v300-rc";
num-lanes = <1>;
max-link-speed = <3>;
phys = <&combo1_pcie>;
```

Allwinner's own default is Gen3. Our overlay `egpu-pcie-gen1.dtbo` does exactly
one thing: it overwrites `max-link-speed` with `1`. That is the whole difference
between the link we run and the link the vendor intends.

### 1.3 The U-Boot in the image also trains at Gen3

The U-Boot control DTB embedded in the boot area of the image (offset
`0x111d7b8`, 42974 bytes) has the same node with `max-link-speed = <3>`,
`num-lanes = <1>`, `status = "okay"`, and the boot command runs
`pci enum; nvme scan`. So **before Linux starts, U-Boot already attempts a Gen3
link training with whatever is in the slot**, then times out or succeeds, and
then Linux resets the endpoint and trains again at whatever the kernel DT says.
Two trainings per boot. Keep that in mind when reading intermittent-enumeration
symptoms (see §3.5).

The U-Boot node also carries a known bug: `pcie3v3_supply = "dc1sw2"`, while the
M.2 slot's 3.3 V is actually `dc1sw1` (see §2.3). Linux is unaffected because its
DT wires `pcie3v3-supply` to the parent rail `dcdc1`, which is always on.

---

## 2. Proof that this slot does Gen3

### 2.1 What we measured ourselves

With the Gen1 overlay, the kernel prints the *measured* link status:

```
pci 0000:01:00.0: 2.000 Gb/s available PCIe bandwidth, limited by 2.5 GT/s PCIe x1 link
```

That line comes from `pcie_print_link_status()` reading `LnkSta`, so Gen1 is real
under our overlay. Nothing in this repo ever measured the link with the overlay
removed — the README says so honestly.

### 2.2 What the driver logs are *not*

The two log lines everyone has been reading are not measurements:

```
sunxi:pcie-rc-6000000.pcie:[ERR]: Speed change timeout
sunxi:pcie-rc-6000000.pcie:[INFO]: PCIe speed of Gen1
```

Look at `bsp/drivers/pcie/pcie-sunxi-rc.c`:

- `sunxi_pcie_host_read_speed()` reads `LINK_CONTROL2_LINK_STATUS2` (DBI 0xa0)
  and masks `& 0xf`. Bits 3:0 of that register are **LnkCtl2 Target Link Speed**
  — the value the driver itself just wrote — not the current speed. "PCIe speed
  of GenN" always echoes the request.
- `sunxi_pcie_host_speed_change()` waits for the `DIRECT_SPEED_CHANGE` bit
  (DBI 0x80c bit 17) to self-clear for `LINK_WAIT_MAX_RETRIE` = **20** iterations
  of `usleep_range(100, 1000)`, i.e. **2–20 ms**. On timeout it prints
  "PCIe speed of Gen1" **unconditionally**, without reading anything.
- With the Gen1 overlay the link is already at Gen1 when the driver requests a
  "speed change" to Gen1. There is nothing to change, so the bit may never
  self-clear and the timeout fires on every boot. That is why
  `Speed change timeout` appears on successful boots too: **it is an artifact of
  forcing Gen1, not a fault.**

A Gen3 speed change from Gen1 goes through `Recovery.Equalization` phases 0–3.
The PCIe spec allows each phase up to 24–32 ms. A 2–20 ms wait can time out on a
perfectly healthy Gen3 negotiation, print "Gen1", and the link may still end up
at Gen3 a few milliseconds later — or not. **The original observation "it
attempts a speed change, times out, and often ends up with no endpoint" was
made through this misleading log**, so it does not tell us what speed the link
actually reached or why enumeration failed.

### 2.3 The NVMe community result on the same slot

[Haidegger22/orangepi4pro-nvme-boot-no-sd](https://github.com/Haidegger22/orangepi4pro-nvme-boot-no-sd),
building on [TblP/orangepi-uboot-fix](https://github.com/TblP/orangepi-uboot-fix),
boots an Orange Pi 4 Pro from a WD SN750 in the M.2 slot, on the same
6.6.98-sun60iw2 kernel, with the **stock** DTB (Gen3). Their measured result:

```
sunxi:pcie-rc-6000000.pcie:[INFO]: PCIe speed of Gen3
pci 0000:01:00.0: 7.876 Gb/s available PCIe bandwidth, limited by 8.0 GT/s PCIe x1 link
cat /sys/bus/pci/devices/0000:01:00.0/current_link_speed   # 8.0 GT/s PCIe
```

Sustained reads of about 610–640 MB/s and writes of about 560 MB/s. They also note
the inverse of our situation: *"if the kernel DTB carries max-link-speed = <1>,
Linux renegotiates the link down to Gen1 (2.0 Gb/s)"*.

Two more things from their U-Boot patch that we reuse:

- The LTSSM state is readable at DBI `0x06000728` (`PCIE_PL_DEBUG0`, bits 5:0).
  `0x00` is Detect.Quiet (no receiver seen), `0x11` is L0.
- Link-up status is at `0x06400e0c` (`SMLH_LINK_UP | RDLH_LINK_UP` = `0x3`).

**Conclusion:** SoC, controller, PHY, slot and kernel all do Gen3 x1 today. What
differs in our setup is what hangs off the slot — a riser and cable to an x16
card — and the endpoint's Gen3 equalization behaviour.

---

## 3. Why Gen3 may fail with the GPU, and what is software

Ordered from "certainly software" to "certainly physical".

### 3.1 The driver gives up too early and lies about the result (software)

Described in §2.2. Fix: wait long enough for equalization (hundreds of ms), and
on timeout **read `LnkSta`** instead of assuming Gen1. Patch:
`files/patches/sunxi-pcie-report-real-link-speed.patch`. Note that
`CONFIG_AW_PCIE_RC=y` is built-in, so this needs a kernel rebuild — see §4.4 for
why that is the *last* step, not the first.

### 3.2 No Gen3 equalization tuning at all (software)

The vendor driver never touches `GEN3_RELATED_OFF` (DBI 0x890) or
`GEN3_EQ_CONTROL_OFF` (DBI 0x8a8). Upstream DesignWare users that train dGPUs
reliably (e.g. `pcie-tegra194.c`) set the preset request vector and feedback mode
explicitly. If the runtime experiment in §4.2 shows Gen3 reaching
`Recovery.Equalization` and falling back, these registers are the knobs:

| Register | Field | Meaning |
|---|---|---|
| 0x8a8 | bits 3:0 `FB_MODE` | 0 = direction change, 1 = figure of merit |
| 0x8a8 | bits 23:8 `PSET_REQ_VEC` | which Tx presets to request from the GPU |
| 0x890 | bit 16 `GEN3_EQ_DISABLE` | skip EQ phases 2/3 entirely (diagnostic only) |
| 0x890 | bits 25:24 `RATE_SHADOW_SEL` | selects which rate 0x8a8 applies to |

All of them are writable from user space through `/dev/mem`
(`CONFIG_STRICT_DEVMEM` is off on this kernel), so they can be tried without a
rebuild.

### 3.3 Gen2 needs no equalization (software test with high odds)

5 GT/s is negotiated exactly like 2.5 GT/s, with no equalization phase. If the
channel is good enough for Gen2, the link should come up at Gen2 with the current
driver by simply requesting it. Gen2 x1 already **doubles** today's bandwidth
(about 4 Gb/s). That is why §4 tests Gen2 first.

### 3.4 The channel is already marginal at Gen1 (physical)

The README's `egpu-link-margin` work is real evidence: `RxErr+` accumulating
under traffic at 2.5 GT/s means corrupted symbols on the wire at the *easiest*
rate. Gen3 at 8 GT/s is roughly four times more demanding of the same trace.
Every centimetre of riser cable, every connector, and any refclk degradation
counts. This is the part no software can fix, and it is also the part the NVMe
users do not have: their SSD sits directly in the slot.

Expect the outcome to be one of: Gen3 clean, Gen3 with `RxErr` and freezes
(unusable), Gen2 clean, or Gen1 only. **Gen2 clean is a very plausible landing
point** with a typical M.2-to-x16 riser; Gen3 may need a better riser.

### 3.5 Two link trainings per boot (software, U-Boot)

U-Boot enumerates PCIe at Gen3 before Linux (§1.3). A GPU that saw a PERST#, a
Gen3 attempt and an abort, and then another PERST# from Linux, may well be the
"half-initialised, refuses to train, only a power cycle helps" state the README
describes. Two cheap experiments: (a) watch the serial console during boot for
U-Boot's `Link up timeout` / `pcie link up success` / `PCIe speed of GenN`, and
(b) remove `pci enum;nvme scan` from the U-Boot boot command, or rebuild U-Boot
with TblP's rail fix, and see whether enumeration becomes deterministic.

---

## 4. Plan

Rules: one variable per boot, run `egpu-link-margin` after every change, X on the
Allwinner HDMI during the experiments (`egpu-video-disable --auto`), and never
retrain while the NVIDIA modules are loaded — a failed retrain drops the GPU off
the bus and `nvidia` will take the box with it.

### 4.1 Phase 0 — measure what we actually have (one boot, no changes)

```bash
sudo egpu-pcie-linkinfo
```

Records, for root port and GPU: `LnkCap` (advertised max), `LnkSta` (current),
`LnkCtl2` (target), `LnkSta2` (equalization phase bits), AER `CESta`, the DWC
Gen3 registers and the LTSSM state. Save the output. This is the baseline every
later run is compared against.

### 4.2 Phase 1 — runtime retrain, no rebuild, no reboot

Boot as today (Gen1, stable enumeration), keep X on the Pi's HDMI, then:

```bash
sudo egpu-pcie-retrain 2      # request 5 GT/s and retrain
sudo egpu-link-margin 200     # is it electrically clean?
```

`egpu-pcie-retrain` widens the root port's advertised speed in the DBI (the same
`dbi_ro_wr_en` trick the vendor driver uses), sets the target speed, pulses
`DIRECT_SPEED_CHANGE` exactly like the driver, waits properly, and prints the
*measured* result plus the equalization bits. If the link comes back at Gen2
with zero `RxErr` after 200 probes, Gen2 is ours.

Then, same boot or next boot:

```bash
sudo egpu-pcie-retrain 3
sudo egpu-link-margin 200
```

Three outcomes and what each means:

| `current_link_speed` | `LnkSta2` | Meaning | Next |
|---|---|---|---|
| 8.0 GT/s, `RxErr-` | `EqComplete+` phases 1–3 `+` | Gen3 works. Riser is fine. | §4.3 with Gen3 |
| 8.0 GT/s but `RxErr+` quickly | EQ complete | Trains but channel too weak | better riser, or settle for Gen2 |
| falls back to 2.5/5 GT/s | any phase `-`, or `LinkEqReq+` | Equalization failed | §3.2 knobs, then riser |
| link down / GPU lost | — | Endpoint could not follow | power-cycle GPU; try §3.2 `GEN3_EQ_DISABLE` once as a diagnostic |

### 4.3 Phase 2 — make the winner persistent (overlay only)

- **Gen2:** install `files/overlays/egpu-pcie-gen2.dts` in place of the Gen1 one
  and set `user_overlays=egpu-pcie-gen2 egpu-pcie-highmem`.
- **Gen3:** simply drop the Gen1 overlay: `user_overlays=egpu-pcie-highmem`.
  The vendor default is already Gen3.

Reboot several times. Enumeration must stay at least as reliable as with Gen1
(`egpu-pcie-recover` logs to the journal how many attempts it needed). If
enumeration gets worse, that is the two-trainings problem of §3.5, not the
speed itself — test it by disabling U-Boot's `pci enum` before concluding.

Do not forget the `egpu-pcie-recover` unbind/bind path: with Gen2/Gen3 in the DT
each rebind will now attempt the faster speed too, and the `Speed change
timeout` log should **disappear** on healthy boots (the bit self-clears when a
real change happens).

### 4.4 Phase 3 — driver patch (kernel rebuild; optional)

`files/patches/sunxi-pcie-report-real-link-speed.patch` makes the driver wait up
to ~500 ms for the speed change and log the *measured* `LnkSta` speed. It is a
quality-of-life fix, not a prerequisite: the overlay alone changes the negotiated
speed. It is last because `CONFIG_AW_PCIE_RC=y` means rebuilding the kernel
image, and this repo pins the kernel because the NVIDIA modules are built for
exactly `6.6.98-sun60iw2`. Rebuilding the same version string keeps the modules
loadable (no `CONFIG_MODVERSIONS`), but back up `/boot` and the modules first —
`egpu-health --repair` restores the modules, nothing restores a kernel.

### 4.5 If Gen3 needs equalization tuning

Order of attempts, each followed by `egpu-pcie-retrain 3` + `egpu-link-margin`:

1. `PSET_REQ_VEC = 0x3ff`, `FB_MODE = 0` (Tegra's Gen3 recipe): request every
   preset, direction-change feedback.
2. `FB_MODE = 1` (figure of merit).
3. `GEN3_EQ_DISABLE` — **diagnostic only**: if the link trains at 8 GT/s with EQ
   skipped and stays clean, the failure was the EQ handshake, not the channel.

`egpu-pcie-linkinfo` prints the current values so every attempt is recorded.

### 4.6 Secondary software ceiling to check once the link is faster

The vendor driver caps the PCIe master port in the NSI bandwidth limiter to 200,
400 or 700 (MB/s) for Gen1/2/3 via `nsi_port_set_abs_bwl()` — only on the success
path, and 700 is below the ~985 MB/s a Gen3 x1 link carries. The limiter is
exposed under `/sys/class/hwmon/*/port_abs_bwl*`. Check it after Gen3 works and
raise or disable it if throughput plateaus around 700 MB/s.

---

## 5. What to expect when it works

| Link | Raw | Payload (~) | NVMe reference on this slot |
|---|---|---|---|
| Gen1 x1 (today) | 2.5 GT/s | 250 MB/s | — |
| Gen2 x1 | 5.0 GT/s | 500 MB/s | — |
| Gen3 x1 | 8.0 GT/s | 985 MB/s | 610–640 MB/s read measured |

For a desktop GPU this is still a narrow pipe — a 3050 in a PC has 16 GB/s — but
scanout is unaffected (framebuffer lives in VRAM), texture uploads and CUDA
host-device copies get 2–4x faster, and, more importantly for this board, PCIe
latency-bound operations (register reads, small DMA) improve because each TLP
spends less time on the wire.

## 6. Files added for this investigation

| File | Purpose |
|---|---|
| `files/scripts/egpu-pcie-linkinfo` | Read-only snapshot of both link partners, EQ bits, DWC Gen3 registers, LTSSM |
| `files/scripts/egpu-pcie-retrain` | Runtime speed change to Gen2/Gen3, refuses to run with NVIDIA loaded |
| `files/overlays/egpu-pcie-gen2.dts` | Persistent Gen2 if that is where the riser tops out |
| `files/patches/sunxi-pcie-report-real-link-speed.patch` | Driver: longer speed-change wait, log measured speed |
