# GPU rendering and video decode on the eGPU (desktop, players, browsers)

Verified 2026-09-08 on the RTX 3050, driver 580.142, Ubuntu 26.04 arm64, Plasma 6.6 on
X11. Set up by `sudo egpu-setup-video` (`files/scripts/egpu-setup-video`); the loader part
is kept in sync at every boot by `egpu-video-apply` through `egpu-gl-profile`.

## The trap: EGL on X11 was software

The stock Orange Pi image ships its own Mesa build for the PowerVR GPU in `/usr/local/lib`
(`libEGL.so.1`, `libGLESv2.so.2`, `libgbm.so.1`, **not** glvnd) and forces it to the front
of the loader with `/etc/ld.so.conf.d/00-pvr-priority.conf`. Once X runs on the NVIDIA card
that Mesa has no driver for the screen it is asked to render to, so every EGL client on X11
silently gets `softpipe`, pure CPU rendering:

```
$ eglinfo -B -p x11
EGL vendor string: Mesa Project
OpenGL ES profile renderer: softpipe        <- CPU
```

Nothing else looks wrong. `glxinfo` says NVIDIA (GLX is dispatched by the X server, not by
the loader), `nvidia-smi` lists Xorg, KWin and plasmashell as GPU clients, and the video
*decode* even happens on NVDEC. What lands on the CPU is everything that goes through EGL:
Chrome's whole GPU process (ANGLE), GTK4 applications, mpv's `vo=gpu`, VLC's `gl` output,
Firefox when it prefers EGL. That is where the "lag" comes from.

The fix is one loader file that sorts before the vendor's:

```
/etc/ld.so.conf.d/00-egpu-glvnd.conf
    /usr/lib/aarch64-linux-gnu
```

followed by `ldconfig`. glvnd's `libEGL.so.1` then wins, and it dispatches X11 displays to
`libEGL_nvidia.so.0` (the `egl-x11` platform libraries `libnvidia-egl-xcb1`/`-xlib1` are
already installed by the driver packages):

```
$ eglinfo -B -p x11
EGL vendor string: NVIDIA
OpenGL core profile renderer: NVIDIA GeForce RTX 3050/PCIe
```

`egpu-gl-profile nvidia|integrada|status` writes or removes that file and also flips
`GSK_RENDERER` (`gl` on the NVIDIA card, back to the vendor's `cairo` on the PowerVR).
`egpu-video-apply` calls it with the same decision it makes for the Xorg layout, so a boot
without the eGPU goes back to the factory order and PowerVR keeps working.

## What runs where now

Measured with autoplaying 1080p test clips (H.264 60 fps, VP9 30 fps), `nvidia-smi dmon -s u`
for the `dec` column and a CPU sampler over the application's processes. The board has 8 cores.

| Component | Path | Evidence |
|---|---|---|
| Xorg, KWin, plasmashell, Qt apps | NVIDIA GLX | listed as `G` clients in `nvidia-smi` |
| GTK4 (zenity, nautilus) | EGL NVIDIA, `GSK_RENDERER=gl` | `GDK_DEBUG=opengl` prints `Vendor: NVIDIA`, `Using OpenGL backend EGL` |
| Firefox 155 (`/opt/firefox`) | WebRender on EGL NVIDIA; VA-API decode, DMA-BUF import, zero copy | `Got VA-API DMABufSurface`, `used copied 0`; `dec` 4–6 %; H.264 60 fps 0.9 core, VP9 0.6 core |
| Google Chrome 152 (arm64) | ANGLE on NVIDIA GL; VA-API decode | `SystemInfo.getInfo`: `gpu_compositing enabled`, `video_decode enabled`, renderer `ANGLE (NVIDIA…)`; `dec` 7–8 %; H.264 60 fps 0.6 core, VP9 0.35 core |
| mpv | `hwdec=nvdec,vaapi`, `vo=gpu` | `Using hardware decoding (nvdec)`; 0.3 core for 1080p60 |
| VLC 3 | `codec=avcodec`, `avcodec-hw=vdpau`, `gl` output on `egl_x11` | `using hw decoder module "vdpau_avcodec"` |
| ffmpeg | `-hwaccel cuda`, `h264_nvenc`/`hevc_nvenc`/`av1_nvenc` | `ffmpeg -hwaccels` lists cuda vdpau vaapi |
| Moonlight (Flatpak) | runtime's glvnd + `org.freedesktop.Platform.VAAPI.nvidia`; env pinned by `flatpak override` | — |

Before the loader fix, Chrome and GTK4 were on `softpipe` and Firefox fell back to GLX with
a CPU copy of every decoded frame.

## Things that bit

- **The apt pin blocks new NVIDIA packages.** `99-egpu-freeze` pins every
  `nvidia-*`/`libnvidia-*` to -1 so upgrades cannot break the module/userspace
  pair. That also blocks *installing* `libnvidia-decode-580`; the script lifts
  the pin for that one `apt-get install libnvidia-decode-580=<exact version>` and
  puts it back, then `apt-mark hold`s the new packages.
- **The Firefox snap cannot use an external VA-API driver** (confinement). Use
  Mozilla's official Linux aarch64 tarball; the script installs it to `/opt/firefox`
  with a desktop entry that carries the environment. Preferences go in
  `/opt/firefox/distribution/policies.json` (`media.ffmpeg.vaapi.enabled`,
  `media.hardware-video-decoding.force-enabled`, `media.rdd-ffmpeg.enabled`,
  `gfx.webrender.all`, `gfx.x11-egl.force-enabled`, `widget.dmabuf.force-enabled`), all with
  `Status: default` so the user can still change them.
- **Firefox opens the profile named in `[Install…]`**, not `[Profile0] Default=1`. When a
  profile is copied in from another machine, point the `Install` section at it too, with
  Firefox closed, or it keeps opening the empty `default-release` profile.
- **Environment must reach the desktop session**, not just shells:
  `/etc/environment` (pam_env) and `/etc/environment.d/90-egpu-vaapi.conf`
  (systemd user sessions) both get `LIBVA_DRIVER_NAME=nvidia`, `NVD_BACKEND=direct`,
  `VDPAU_DRIVER=nvidia`, `MOZ_DISABLE_RDD_SANDBOX=1`, `GSK_RENDERER=gl`.
- **GTK 4.20 renamed the GL renderer.** `GSK_RENDERER=ngl` now warns and the value is `gl`.
- **VLC in the stock image decodes through GStreamer + the Allwinner Cedar engine**
  (`gstdecode` → `omx_vdec_aw`), then copies frames back for display. Hardware, but not the
  GPU and not zero-copy. `codec=avcodec` + `avcodec-hw=vdpau` in `~/.config/vlc/vlcrc` moves
  it to the RTX. The vendor's `vout=x11` (software output) is removed so VLC picks `gl`.
- **GStreamer's `va` plugin registers no elements** with `nvidia-vaapi-driver`; the driver
  does not implement what `gst-va` needs. Nothing installed on the reference board uses
  GStreamer for video, so this is documented, not fixed.
- The decoded frames travel through the same non-coherent DMA path as
  everything else on this board. No artefacts were seen in the tests; if a codec
  shows corruption, try `NVD_BACKEND=egl` first.

## Check it

```bash
eglinfo -B -p x11 | grep -E "vendor|renderer"       # must say NVIDIA; "softpipe" = the trap above
sudo egpu-gl-profile status                          # which libEGL.so.1 the loader resolves first
LIBVA_DRIVER_NAME=nvidia NVD_BACKEND=direct vainfo --display drm --device /dev/dri/renderD129
ffmpeg -hwaccel cuda -i video.mp4 -f null -          # exit 0 = NVDEC decode works
nvidia-smi dmon -s u                                 # 'dec' > 0 while a video plays
nvidia-smi                                           # Xorg, kwin_x11, plasmashell, firefox listed as G clients
```

Chrome: `chrome://gpu` → *Video Decode: Hardware accelerated*, GL renderer `ANGLE (NVIDIA …)`;
`chrome://media-internals` while playing shows a `VaapiVideoDecoder`. Firefox:
`about:support` → Graphics → *Compositing: WebRender*, *Window Protocol: x11*, and Media →
*Hardware video decoding*; while playing, `about:media`. Chrome's sandboxed GPU process does
not appear in `nvidia-smi`'s process list; use the `dec` column instead.
