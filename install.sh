#!/bin/bash
# Installs the eGPU support files on an Orange Pi 4 Pro.
#
# This installs the plumbing only: boot services, helper commands, Xorg layout
# and upgrade shielding. It does NOT build the NVIDIA driver and does NOT touch
# the device tree overlays -- do those first, following docs/TUTORIAL.md.
#
# Safe to re-run.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

HERE=$(cd "$(dirname "$0")" && pwd)
F="$HERE/files"

say() { printf '  %s\n' "$*"; }

echo "== Sanity checks =="
if ! grep -qi "orange" /etc/os-release 2>/dev/null; then
    echo "WARNING: this does not look like an Orange Pi image." >&2
    read -rp "Continue anyway? [y/N] " a
    [ "${a:-n}" = "y" ] || exit 1
fi
KREL=$(uname -r)
if [ ! -f "/lib/modules/$KREL/extra/nvidia.ko" ]; then
    echo "WARNING: no patched nvidia.ko for kernel $KREL." >&2
    echo "         Build the driver first -- see docs/TUTORIAL.md Part 2." >&2
    read -rp "Continue anyway? [y/N] " a
    [ "${a:-n}" = "y" ] || exit 1
fi

echo "== Helper commands -> /usr/local/sbin =="
for s in "$F"/scripts/egpu-*; do
    install -m 755 "$s" /usr/local/sbin/
    say "$(basename "$s")"
done

echo "== Xorg =="
install -d /etc/X11/xorg.conf.d
install -m 644 "$F/xorg/xorg-egpu-nvidia.conf"  /etc/X11/
install -m 644 "$F/xorg/05-no-autoaddgpu.conf"  /etc/X11/xorg.conf.d/
say "/etc/X11/xorg-egpu-nvidia.conf  (canonical layout, never auto-removed)"
say "/etc/X11/xorg.conf.d/05-no-autoaddgpu.conf"

echo "== modprobe =="
install -m 644 "$F/modprobe/egpu-nvidia-display.conf" /etc/modprobe.d/
say "/etc/modprobe.d/egpu-nvidia-display.conf"

# nvidia_drm loads from egpu-video-apply, after PCIe recovery -- never from here.
if [ -f /etc/modules-load.d/egpu-nvidia-display.conf ]; then
    rm -f /etc/modules-load.d/egpu-nvidia-display.conf
    say "removed stale /etc/modules-load.d/egpu-nvidia-display.conf"
fi

echo "== udev (escolha de dispositivo DRM para Wayland) =="
install -m 644 "$F/udev/61-egpu-mutter-primary.rules" /etc/udev/rules.d/
udevadm control --reload-rules >/dev/null 2>&1 || true
say "/etc/udev/rules.d/61-egpu-mutter-primary.rules"

echo "== systemd =="
install -m 644 "$F"/systemd/egpu-*.service "$F"/systemd/egpu-*.timer /etc/systemd/system/
install -m 644 "$F/systemd/regen-ssh-host-keys.service" /etc/systemd/system/
# O drop-in de OnFailure precisa existir para o DM realmente em uso. Um
# drop-in em display-manager.service.d nao e aplicado de forma confiavel,
# porque display-manager.service e um symlink.
for dm in lightdm gdm3 gdm sddm; do
    if [ -f "/lib/systemd/system/$dm.service" ] || [ -f "/usr/lib/systemd/system/$dm.service" ]; then
        install -d "/etc/systemd/system/$dm.service.d"
        install -m 644 "$F/systemd/lightdm.service.d/egpu-rollback.conf" \
                "/etc/systemd/system/$dm.service.d/egpu-rollback.conf"
        say "OnFailure instalado para $dm"
    fi
done
systemctl daemon-reload
for u in egpu-pcie-recover.service egpu-video-apply.service \
         egpu-video-watchdog.timer egpu-health.service \
         regen-ssh-host-keys.service; do
    systemctl enable "$u" >/dev/null 2>&1 && say "enabled $u"
done

echo "== Intent file =="
if [ ! -f /etc/default/egpu-video ]; then
    cat > /etc/default/egpu-video <<'EOF'
# Which output drives the desktop.
#   auto = use the NVIDIA card when a monitor is plugged into it,
#          otherwise the Orange Pi HDMI            <- recommended
#   yes  = always the NVIDIA card, even with no monitor detected on it
#   no   = always the Orange Pi HDMI
# Change with: egpu-video-auto / egpu-video-enable / egpu-video-disable
EGPU_VIDEO=auto
EOF
    say "/etc/default/egpu-video  (EGPU_VIDEO=auto)"
else
    say "/etc/default/egpu-video already exists, left alone"
fi

echo "== Upgrade shielding =="
install -m 644 "$F/apt/99-egpu-freeze" /etc/apt/preferences.d/
install -m 644 "$F/apt/99-egpu-guard"  /etc/apt/apt.conf.d/
say "apt pin + post-dpkg guard installed"

PKGS=$(dpkg-query -W -f='${Package}\n' 2>/dev/null \
       | grep -E '^(libnvidia-|nvidia-|xserver-xorg-video-nvidia)' || true)
KERN=$(dpkg-query -W -f='${Package}\n' 2>/dev/null \
       | grep -E '^linux-(image|dtb)' || true)
if [ -n "$PKGS$KERN" ]; then
    # shellcheck disable=SC2086
    apt-mark hold $PKGS $KERN >/dev/null 2>&1 && say "apt-mark hold applied"
fi

echo "== GPU device access =="
# O kernel vendor e compilado sem CONFIG_TMPFS_POSIX_ACL, entao devtmpfs nao
# guarda ACLs e o mecanismo uaccess do systemd falha:
#   (udev-worker): card2: Failed to apply ACL: Operation not supported
# Sem ACL, o acesso a GPU depende inteiramente de grupo. E facil passar
# desapercebido porque card2 e root:video (o usuario normalmente esta em
# video) mas renderD* e root:render -- e sem o render node o EGL/GBM falha.
# Usuarios humanos...
for u in $(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd); do
    usermod -aG video,render "$u" 2>/dev/null && say "$u -> video, render"
done
# ...e os usuarios de sistema dos display managers. Um greeter Wayland roda
# como usuario nao-root e precisa abrir a GPU. Isto ficou de fora da primeira
# versao deste script, que so olhava uid >= 1000.
for u in gdm sddm lightdm; do
    id "$u" >/dev/null 2>&1 && usermod -aG video,render "$u" 2>/dev/null \
        && say "$u -> video, render (usuario de display manager)"
done
say "(mudanca de grupo vale a partir do proximo login)"

echo "== Acesso DRM sem ACL nem grupo =="
install -m 644 "$F/udev/62-egpu-drm-access.rules" /etc/udev/rules.d/
udevadm control --reload-rules >/dev/null 2>&1 || true
udevadm trigger --subsystem-match=drm >/dev/null 2>&1 || true
say "/etc/udev/rules.d/62-egpu-drm-access.rules"
say "  necessario porque o greeter do GDM roda como usuario TRANSITORIO,"
say "  sem grupos suplementares -- e sem CONFIG_TMPFS_POSIX_ACL o uaccess"
say "  tambem nao funciona. Ver comentarios na regra."

echo "== Module backup =="
mkdir -p /root/egpu-backup
if [ -f "/lib/modules/$KREL/extra/nvidia.ko" ]; then
    ( cd "/lib/modules/$KREL" && \
      tar czf "/root/egpu-backup/nvidia-modules-$KREL.tar.gz" extra/nvidia*.ko )
    say "/root/egpu-backup/nvidia-modules-$KREL.tar.gz"
else
    say "skipped (no modules to back up yet)"
fi

echo
echo "Done. Output selection is automatic from now on:"
echo "  monitor plugged into the NVIDIA card -> desktop and console go there"
echo "  no monitor on the NVIDIA card        -> Orange Pi HDMI"
echo
echo "  sudo egpu-video-apply        # re-decide now, without rebooting"
echo "  sudo systemctl restart lightdm"
echo
echo "  sudo egpu-video-check        # what does the GPU see?"
echo "  sudo egpu-health             # verify the whole stack"
echo
echo "Overrides: egpu-video-enable (always NVIDIA), egpu-video-disable (always"
echo "Orange Pi HDMI), egpu-video-auto (back to automatic)."
echo
echo "Keep an SSH session open the first time. If X fails, the watchdog reverts"
echo "to the Orange Pi HDMI 75 s after boot."
