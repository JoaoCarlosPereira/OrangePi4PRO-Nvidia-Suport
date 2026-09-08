#!/bin/bash
# Installs the eGPU support files on an Orange Pi 4 Pro.
#
# Installs boot services, helper commands, Xorg layout, upgrade shielding, the
# PCIe device tree overlays (Gen2 + high-memory aperture) and the rebuilt U-Boot
# package into the card's boot area and the vendor .deb. It does NOT build the
# NVIDIA driver -- see docs/TUTORIAL.md Part 2 for that.
#
# Options (environment variables):
#   EGPU_KERNEL=/path/kernel-6.6.98-sun60iw2-egpu.tar.gz   also install the rebuilt kernel
#                (release asset; tools/kernel/install-kernel.sh, restorable)
#   EGPU_UBOOT_SPI=1   also flash the fixed U-Boot into the SPI NOR (needed to boot
#                      without a microSD; boot0 untouched, readback-verified)
#   EGPU_SKIP_OVERLAYS=1 / EGPU_SKIP_UBOOT=1   leave those parts alone
#   EGPU_FIRSTBOOT=1   arm the first-boot menu (egpu-firstboot.service): on the next boot
#                      tty1 offers to move the system to a connected disk (USB 3 SSD, NVMe)
#                      while this medium keeps /boot. Used when building the image.
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
install -m 755 "$HERE/tools/kernel/install-kernel.sh" /usr/local/sbin/egpu-install-kernel
install -m 755 "$HERE/tools/uboot/install-uboot.sh"   /usr/local/sbin/egpu-install-uboot
install -d /usr/local/share/egpu
install -m 644 "$F/uboot/boot_package-dc1sw1.fex" /usr/local/share/egpu/
say "egpu-install-kernel, egpu-install-uboot, /usr/local/share/egpu/boot_package-dc1sw1.fex"

echo "== PCIe device tree overlays (Gen2 + 512 MiB prefetchable aperture) =="
if [ -z "${EGPU_SKIP_OVERLAYS:-}" ]; then
    command -v dtc >/dev/null || apt-get install -y -q device-tree-compiler >/dev/null
    install -d /boot/overlay-user
    for o in egpu-pcie-gen2 egpu-pcie-highmem egpu-usbc-host egpu-pcie-gen1; do
        dtc -@ -q -I dts -O dtb -o "/boot/overlay-user/$o.dtbo" "$F/overlays/$o.dts"
        say "/boot/overlay-user/$o.dtbo"
    done
    ENV=/boot/orangepiEnv.txt
    [ -f "$ENV.before-egpu" ] || cp "$ENV" "$ENV.before-egpu"
    if grep -q '^user_overlays=' "$ENV"; then
        sed -i 's/^user_overlays=.*/user_overlays=egpu-pcie-gen2 egpu-pcie-highmem egpu-usbc-host/' "$ENV"
    else
        printf '\nuser_overlays=egpu-pcie-gen2 egpu-pcie-highmem\n' >> "$ENV"
    fi
    say "$ENV: user_overlays=egpu-pcie-gen2 egpu-pcie-highmem egpu-usbc-host (backup: $ENV.before-egpu)"
    say "  egpu-usbc-host: USB-C port is a host from the kernel, so a root filesystem on a USB-C SSD is found at boot"
    say "  Gen1 overlay installed too, for fallback; Gen3 halts the NVIDIA GSP -- see docs/PCIE-LINK-SPEED.md"
    say "  power-cycle the GPU's PSU before the next boot: the GPU remembers the host's previous max speed"
else
    say "skipped (EGPU_SKIP_OVERLAYS)"
fi

echo "== U-Boot with the M.2 power-rail fix =="
if [ -z "${EGPU_SKIP_UBOOT:-}" ]; then
    PKG=/usr/local/share/egpu/boot_package-dc1sw1.fex /usr/local/sbin/egpu-install-uboot sd  | sed 's/^/  /'
    PKG=/usr/local/share/egpu/boot_package-dc1sw1.fex /usr/local/sbin/egpu-install-uboot deb | sed 's/^/  /'
    if [ -n "${EGPU_UBOOT_SPI:-}" ]; then
        command -v mtd_debug >/dev/null || apt-get install -y -q mtd-utils >/dev/null
        PKG=/usr/local/share/egpu/boot_package-dc1sw1.fex /usr/local/sbin/egpu-install-uboot spi | sed 's/^/  /'
    else
        say "SPI NOR left alone (set EGPU_UBOOT_SPI=1 to enable booting without a microSD)"
    fi
else
    say "skipped (EGPU_SKIP_UBOOT)"
fi

echo "== Kernel =="
if [ -n "${EGPU_KERNEL:-}" ]; then
    /usr/local/sbin/egpu-install-kernel "$EGPU_KERNEL" | sed 's/^/  /'
else
    say "vendor kernel kept. To install the rebuilt one (measured link speed in the log, NSI cap lifted):"
    say "  download kernel-6.6.98-sun60iw2-egpu.tar.gz from the release, then"
    say "  sudo EGPU_KERNEL=/path/to/it $0   (or: sudo egpu-install-kernel /path/to/it)"
fi

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

echo "== SSH a qualquer custo =="
# O sshd e o unico canal de recuperacao deste board, porque o que quebra nele e
# o video. A ativacao por socket do Ubuntu tem um modo de falha que ja nos
# mordeu: se o sshd nao sobe (chaves ausentes num cartao clonado, sshd_config
# quebrado), o ssh.socket estoura o limite de tentativas, entra em failed e
# PARA DE ESCUTAR -- e a porta 22 nao volta sem acesso fisico.
#
# Troca por um daemon persistente com Restart=always e sem limite, mais um
# guard por timer que verifica a porta a cada minuto e escala ate conseguir.
install -d /etc/systemd/system/ssh.service.d
install -m 644 "$F/systemd/ssh.service.d/egpu-always.conf" /etc/systemd/system/ssh.service.d/
say "/etc/systemd/system/ssh.service.d/egpu-always.conf"

# O [Install] da unidade de fabrica tem RequiredBy=ssh.service, entao existe um
# symlink em ssh.service.requires/ que faz o servico EXIGIR o socket -- e parar
# o socket levaria o servico junto. Remove primeiro.
rm -f /etc/systemd/system/ssh.service.requires/ssh.socket
rmdir /etc/systemd/system/ssh.service.requires 2>/dev/null || true
install -m 644 "$F/systemd/egpu-ssh-guard.service" "$F/systemd/egpu-ssh-guard.timer" \
        /etc/systemd/system/
systemctl daemon-reload
systemctl enable ssh.service >/dev/null 2>&1 && say "ssh.service habilitado"
systemctl disable ssh.socket >/dev/null 2>&1 && say "ssh.socket desabilitado"
systemctl enable egpu-ssh-guard.timer >/dev/null 2>&1 && say "egpu-ssh-guard.timer habilitado"
# KillMode=process mantem as sessoes abertas, entao a troca nao corta quem esta
# conectado agora. Mesmo assim: o intervalo entre parar o socket e subir o
# servico e o unico momento em que a porta 22 fica fechada.
if [ -z "${EGPU_SKIP_SSH_SWITCH:-}" ]; then
    systemctl stop ssh.socket 2>/dev/null; systemctl start ssh.service 2>/dev/null
    if /usr/local/sbin/egpu-ssh-guard >/dev/null 2>&1; then
        say "porta 22 respondendo pelo ssh.service"
    else
        say "AVISO: a porta 22 nao respondeu -- rode: sudo egpu-ssh-guard"
    fi
else
    say "troca adiada (EGPU_SKIP_SSH_SWITCH) -- vale no proximo boot"
fi

echo "== System on a fast disk (egpu-install-to-disk / first-boot menu) =="
install -m 644 "$F/xdg/egpu-install-to-disk.desktop" /usr/share/applications/
say "application menu: System -> 'System disk (eGPU image)'"
if [ -n "${EGPU_FIRSTBOOT:-}" ]; then
    rm -f /var/lib/egpu/firstboot-done
    install -d /etc/xdg/autostart; install -m 644 "$F/xdg/egpu-firstboot.desktop" /etc/xdg/autostart/
    systemctl enable egpu-firstboot.service >/dev/null 2>&1 && say "egpu-firstboot armed: menu on tty1 and in the desktop session at the next boot"
else
    say "menu not armed (EGPU_FIRSTBOOT=1 to arm). Any time: sudo egpu-install-to-disk --list"
fi

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
echo "  sudo egpu-ssh-guard          # force port 22 back up"
echo
echo "Overrides: egpu-video-enable (always NVIDIA), egpu-video-disable (always"
echo "Orange Pi HDMI), egpu-video-auto (back to automatic)."
echo
echo "Keep an SSH session open the first time. If X fails, the watchdog reverts"
echo "to the Orange Pi HDMI 75 s after boot."
