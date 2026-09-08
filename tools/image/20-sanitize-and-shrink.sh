#!/bin/bash
# Run as root on the RAW IMAGE FILE (never on the SD card):
#   sudo bash sanitize-and-shrink.sh /path/to/orangepi4pro-egpu-v1.2.img
# 1) attaches the ext4 partition (offset 32 MiB) as a loop device
# 2) removes everything SECURITY.md lists, by glob and by content
# 3) refuses to continue if any check fails
# 4) shrinks the filesystem to its minimum + margin, truncates the image, fixes the partition table
set -euo pipefail
IMG=${1:?image path}
OFF=33554432                      # 65536 sectors * 512
MNT=/mnt/egpu-img
LOOP=$(losetup -f --show -o $OFF "$IMG"); trap 'umount $MNT 2>/dev/null || true; losetup -d $LOOP 2>/dev/null || true' EXIT
echo "loop: $LOOP"
e2fsck -fy "$LOOP" >/dev/null || [ $? -le 2 ]
mkdir -p $MNT && mount "$LOOP" $MNT
H=$MNT/home/orangepi; R=$MNT/root
echo "== removing"
rm -rf $H/.config/google-chrome* $H/.config/chromium* $H/.mozilla $H/.cache $R/.cache
find $MNT/home $MNT/root -maxdepth 2 \( -iname '.*claude*' -o -iname '.*gemini*' -o -iname '.*codex*' -o -iname '.*copilot*' -o -iname '.*cursor*' -o -iname '.*openai*' -o -iname '.*anthropic*' \) -exec rm -rf {} +
rm -rf $H/.ssh $R/.ssh $H/.gnupg $R/.gnupg $H/.local/share/keyrings $H/.pki
rm -f  $H/.bash_history $H/.zsh_history $H/.python_history $H/.lesshst $H/.viminfo $H/.wget-hsts $H/.Xauthority $H/.ICEauthority $H/.xsession-errors* $H/.sudo_as_admin_successful
rm -f  $R/.bash_history $R/.zsh_history $R/.python_history $R/.lesshst $R/.viminfo
rm -rf $H/.local/share/Trash $H/.local/share/recently-used.xbel $H/.local/share/zsh $H/.nv $R/.nv
rm -f  $MNT/etc/ssh/ssh_host_*
: > $MNT/etc/machine-id; rm -f $MNT/var/lib/dbus/machine-id
rm -rf $MNT/etc/NetworkManager/system-connections/* $MNT/var/lib/NetworkManager/*
rm -f  $MNT/etc/shadow- $MNT/etc/gshadow- $MNT/etc/passwd- $MNT/etc/group-
rm -rf $MNT/var/lib/AccountsService/users/* $MNT/tmp/* $MNT/var/tmp/* $MNT/var/crash/* $MNT/var/lib/systemd/coredump/*
find $MNT/var/log -type f -exec truncate -s 0 {} +
rm -rf $MNT/var/log/journal/*/
rm -f $MNT/etc/modprobe.d/zz-egpu-experiment.conf
echo "== boot-medium state: root on itself, first-boot menu armed, no per-disk udev rule"
CARDUUID=$(blkid -s UUID -o value "$LOOP"); sed -i "s/^rootdev=.*/rootdev=UUID=$CARDUUID/" $MNT/boot/orangepiEnv.txt
grep rootdev $MNT/boot/orangepiEnv.txt; rm -f $MNT/etc/udev/rules.d/70-egpu-system-disk.rules $MNT/var/lib/egpu/firstboot-done
rm -f $MNT/boot/orangepiEnv.txt.before-install-to-disk $MNT/boot/orangepiEnv.txt.before-gen3-test
echo "== credentials"
HASH=$(awk -F: '$1=="orangepi"{print $2}' $MNT/etc/shadow); LAST=$(awk -F: '$1=="orangepi"{print $3}' $MNT/etc/shadow)
perl -e 'my($p,$h)=@ARGV; exit(crypt($p,$h) eq $h ? 0 : 1)' orangepi "$HASH" && echo "orangepi password = orangepi: matches" || { echo "PASSWORD HASH DOES NOT MATCH 'orangepi'"; exit 1; }
[ "$LAST" != 0 ] || { echo "lastchg=0 would break autologin"; exit 1; }
awk -F: '$1=="root"{print "root hash starts with: " substr($2,1,1)}' $MNT/etc/shadow
echo "== asserting"
FAIL=0
for p in $H/.config/google-chrome $H/.ssh $R/.ssh $H/.bash_history $R/.bash_history $H/.gnupg $MNT/etc/shadow- $MNT/var/lib/dbus/machine-id $H/.claude $H/.claude.json $H/.codex $H/.gemini; do [ -e "$p" ] && { echo "STILL PRESENT: $p"; FAIL=1; }; done
[ -s $MNT/etc/machine-id ] && { echo "machine-id not empty"; FAIL=1; }
ls $MNT/etc/ssh/ssh_host_* 2>/dev/null && { echo "host keys remain"; FAIL=1; }
find $MNT/home $MNT/root -maxdepth 4 -type d \( -iname '*chrome*' -o -iname '*chromium*' -o -iname '*firefox*' \) | grep . && FAIL=1
echo "== content scan (keys/tokens); the kernel sgx test fixture is the only expected hit"
grep -rlIE 'BEGIN (RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY' $MNT/home $MNT/root $MNT/etc 2>/dev/null | grep -v 'selftests/sgx/sign_key.pem' | sed 's/^/  KEY: /' | grep . && FAIL=1
grep -rlIE '(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})' $MNT/home $MNT/root $MNT/etc 2>/dev/null | grep -v -E 'egpu-linux/|egpu-nvidia' | sed 's/^/  TOKEN: /' | grep . && FAIL=1
[ $FAIL -eq 0 ] || { echo "REFUSING: checks failed"; exit 1; }
echo "== state check (must be Gen2 + scripts)"
grep user_overlays $MNT/boot/orangepiEnv.txt; ls $MNT/boot/overlay-user; ls $MNT/usr/local/sbin/egpu-pcie-*
du -sh --exclude=proc $MNT 2>/dev/null | tail -1
sync; umount $MNT
echo "== shrinking"
e2fsck -fy "$LOOP" >/dev/null || [ $? -le 2 ]
resize2fs -M "$LOOP" 2>&1 | tail -1
BS=$(dumpe2fs -h "$LOOP" 2>/dev/null | awk '/^Block size/{print $3}'); BC=$(dumpe2fs -h "$LOOP" 2>/dev/null | awk '/^Block count/{print $3}')
MARGIN=$(( (512*1024*1024) / BS )); resize2fs "$LOOP" $((BC+MARGIN)) 2>&1 | tail -1
BC=$(dumpe2fs -h "$LOOP" 2>/dev/null | awk '/^Block count/{print $3}')
e2fsck -fy "$LOOP" >/dev/null || [ $? -le 2 ]
losetup -d "$LOOP"; trap - EXIT
SECT=$(( BC * BS / 512 )); truncate -s $(( OFF + BC * BS )) "$IMG"
printf '65536,%s,83\n' "$SECT" | sfdisk -q -N 1 "$IMG"
sfdisk -l "$IMG" | tail -1; ls -la "$IMG" | awk '{print $5, $9}'
chown --reference="$(dirname "$IMG")" "$IMG" 2>/dev/null || true
echo "DONE"
