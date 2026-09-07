#!/bin/bash
# Independent, read-only check of the sanitised image with debugfs (no root, no mount).
set -u
IMG=${1:?image}; FS="$IMG?offset=33554432"
d() { debugfs -R "$1" "$FS" 2>/dev/null; }
echo "== must be absent"
for p in /home/orangepi/.ssh /root/.ssh /home/orangepi/.bash_history /root/.bash_history /home/orangepi/.zsh_history /home/orangepi/.config/google-chrome /home/orangepi/.claude /home/orangepi/.claude.json /home/orangepi/.codex /home/orangepi/.gemini /home/orangepi/.gnupg /home/orangepi/.cache /etc/shadow- /etc/gshadow- /etc/passwd- /etc/group- /var/lib/dbus/machine-id /etc/modprobe.d/zz-egpu-experiment.conf; do
  d "stat $p" | grep -q Inode && echo "  PRESENT: $p" || echo "  ok: $p"
done
echo "== /home/orangepi/.config entries matching chrome/backup"; d "ls -l /home/orangepi/.config" | awk '{print $NF}' | grep -i -E "chrome|backup|crash" || echo "  none"
echo "== /etc/ssh host keys"; d "ls -l /etc/ssh" | awk '{print $NF}' | grep ssh_host || echo "  none"
echo "== machine-id size"; d "stat /etc/machine-id" | grep -o "Size: [0-9]*"
echo "== NetworkManager connections"; d "ls -l /etc/NetworkManager/system-connections" | awk 'NF>2{print $NF}' | grep -v -E "^\.\.?$" || echo "  none"
echo "== shadow (orangepi and root fields 2-3 only)"; d "cat /etc/shadow" | awk -F: '$1=="orangepi"||$1=="root"{print "  "$1": hash="substr($2,1,3)"... lastchg="$3}'
echo "== var/log non-empty files"; d "ls -l /var/log" | awk '$6>0 && $NF!="." && $NF!=".." && $2!~/^4/ {print "  "$NF, $6}' | head
echo "== state"; d "cat /boot/orangepiEnv.txt" | grep user_overlays; d "ls -l /boot/overlay-user" | awk '{print $NF}' | grep dtbo | tr "\n" " "; echo; d "ls -l /usr/local/sbin" | awk '{print $NF}' | grep egpu-pcie | tr "\n" " "; echo
echo "== partition table"; sfdisk -l "$IMG" 2>/dev/null | tail -1; ls -la "$IMG" | awk '{print "size:", $5}'
