# GPU video decode on the eGPU (players and browsers)

Verified 2026-09-08 on the RTX 3050, driver 580.142, Ubuntu 26.04 arm64. Set up by
`sudo egpu-setup-video` (`files/scripts/egpu-setup-video`).

## What works

| Path | How | Codecs |
|---|---|---|
| NVDEC via CUDA | `ffmpeg -hwaccel cuda`, `mpv --hwdec=nvdec` | H.264, HEVC, VP9, AV1 (GA107) |
| VDPAU | `libvdpau_nvidia`, VLC and other VDPAU players | H.264, HEVC, VP9 |
| VA-API | `nvidia-vaapi-driver` (elFarto) built from source, direct backend | H.264, HEVC, VP9, AV1 |
| Google Chrome (official arm64 build) | launcher override with `--enable-features=VaapiVideoDecodeLinuxGL,VaapiIgnoreDriverChecks,VaapiOnNvidiaGPUs --ignore-gpu-blocklist` | via VA-API |
| Firefox (Mozilla linux-aarch64 build in `/opt/firefox`) | `policies.json` enables VA-API and forces hardware decode; `MOZ_DISABLE_RDD_SANDBOX=1` in the environment | via VA-API |

Proof that the decoder engine is used: `nvidia-smi dmon -s u` shows the `dec`
column above zero while a video plays (24 % during a 1080p H.264 decode in the
test).

## Things that bit

- **The apt pin blocks new NVIDIA packages.** `99-egpu-freeze` pins every
  `nvidia-*`/`libnvidia-*` to -1 so upgrades cannot break the module/userspace
  pair. That also blocks *installing* `libnvidia-decode-580`; the script lifts
  the pin for that one `apt-get install libnvidia-decode-580=<exact version>` and
  puts it back, then `apt-mark hold`s the new packages.
- **The Firefox snap cannot use an external VA-API driver** (confinement). Use
  Mozilla's official Linux aarch64 tarball; the script installs it to `/opt/firefox`
  with a desktop entry that carries the environment.
- **Environment must reach the desktop session**, not just shells:
  `/etc/environment` (pam_env) and `/etc/environment.d/90-egpu-vaapi.conf`
  (systemd user sessions) both get `LIBVA_DRIVER_NAME=nvidia`,
  `NVD_BACKEND=direct`, `MOZ_DISABLE_RDD_SANDBOX=1`.
- The decoded frames travel through the same non-coherent DMA path as
  everything else on this board. No artefacts were seen in the tests; if a codec
  shows corruption, try `NVD_BACKEND=egl` first.

## Check it

```bash
LIBVA_DRIVER_NAME=nvidia NVD_BACKEND=direct vainfo --display drm --device /dev/dri/renderD129
ffmpeg -hwaccel cuda -i video.mp4 -f null -          # exit 0 = NVDEC decode works
nvidia-smi dmon -s u                                 # 'dec' > 0 while playing
```

Chrome: `chrome://gpu` → *Video Decode: Hardware accelerated*; `chrome://media-internals`
while playing shows a `VaapiVideoDecoder`. Firefox: `about:support` → Media →
*Hardware video decoding* and, while playing, `about:media`.
