# Booting without a microSD card

The A733's boot ROM only looks at microSD, eMMC and SPI NOR. To run the system
from a USB drive (or an NVMe SSD in the M.2 slot) you keep **U-Boot in the SPI
NOR** and put the root filesystem on the other medium. Two things stood in the
way on the stock image, both fixed here:

0. The vendor U-Boot leaves the two USB Type-A ports **unpowered**: it drives
   reference-board VBUS pins (`PL5`/`PL6`) while this board's Type-A VBUS enable
   is `PB7`, active-low. A stick in a Type-A port has its LED off during U-Boot
   and `usb start` finds nothing. Fixed in `files/uboot/boot_package-dc1sw1.fex`.
1. The vendor U-Boot switches on the wrong 3.3 V rail for the M.2 slot
   (`dc1sw2`, the slot is on `dc1sw1`), so an NVMe drive is invisible to it.
   `files/uboot/boot_package-dc1sw1.fex` is the vendor U-Boot rebuilt with the
   fix (see `files/uboot/README.md`). An externally powered eGPU riser does not
   need the fix; an SSD does.
2. `orangepi-config → System → Install → boot from SPI` flashes the U-Boot from
   the vendor `.deb`, i.e. the buggy one, on top of whatever you put in the SPI.
   `install.sh` (or `egpu-install-uboot deb`) replaces the package inside the
   `.deb` directory, so orangepi-config flashes the fixed one from then on.

## Procedure (USB drive)

On the PC:

```bash
# 1. write the image to the USB drive (16 GB or larger, everything on it is lost)
cat orangepi4pro-egpu.img.xz.part-* | xz -dc | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
# 2. give the root filesystem its own UUID, so it never collides with a microSD
NEW=$(uuidgen); sudo tune2fs -U "$NEW" /dev/sdX1
sudo mount /dev/sdX1 /mnt
sudo sed -i "s/^rootdev=UUID=.*/rootdev=UUID=$NEW/" /mnt/boot/orangepiEnv.txt
sudo sed -i "s/UUID=[0-9a-f-]*\( *\/ \)/UUID=$NEW\1/" /mnt/etc/fstab
sudo umount /mnt
```

On the board, booted from the microSD as usual:

```bash
sudo egpu-install-uboot spi          # fixed U-Boot into the SPI NOR at 0x40000, boot0 untouched
```

Then power off, **remove the microSD**, plug the USB drive into one of the two
**USB 2.0 Type-A** ports (U-Boot only drives the EHCI controller; the USB-C 3.1
port is XHCI and is not available at boot), GPU PSU on, power on. Boot order in
U-Boot is mmc → ufs → nvme → usb. The first boot expands the filesystem to the
drive and reboots once, as on microSD.

The same steps apply to an NVMe SSD, with `nvme0n1p1` in place of `sdX1` and no
USB-port caveat. `orangepi-config` can do the copy for you (System → Install,
target USB or NVMe) once `egpu-install-uboot deb` has been run.

## Status

- Rebuilt U-Boot boots from the SD boot area and from the SPI NOR: verified.
- Boot from USB with no microSD present: **verified 2026-09-08** — SanDisk
  Cruzer Glide 16 GB in a Type-A port, root on `/dev/sda1`, filesystem expanded
  on first boot, PCIe Gen2 and the desktop on the RTX 3050 as on microSD.

Two things that cost a failed attempt each: the stick must be in a **Type-A**
port (the USB-C port is XHCI, invisible to this U-Boot — on this board the
keyboard and mouse usually occupy both Type-A ports, so unplug one), and the
U-Boot must carry the PB7 VBUS fix above. With neither logo nor LED you cannot
tell those apart from a dead SPI; the SPI was fine all along.

## Recovery

If the SPI content is bad, the board still boots from a microSD (the ROM tries
it first). `egpu-install-uboot` keeps a full 16 MiB dump of the SPI NOR in
`/root/egpu-uboot-backup/` before writing; restore with
`mtd_debug write /dev/mtd0 0 16777216 <dump>` after `flash_erase /dev/mtd0 0 0`.

## Fast root filesystem: boot medium + disk

U-Boot reads only microSD and USB 2.0, but Linux drives the USB-C 3.1 port and
NVMe at full speed. `egpu-install-to-disk` splits the two roles:

```
microSD or USB 2.0 stick   /boot (kernel, DTB, overlays, orangepiEnv.txt) + a complete fallback system
disk (USB-C SSD, NVMe)     /   -- GPT, one ext4 partition, the whole disk, exclusively for the system
```

The disk's `/etc/fstab` mounts the boot medium at `/media/bootfs` and bind-mounts
its `/boot` on `/boot`, so kernel updates and `orangepiEnv.txt` edits still land
where U-Boot reads them. The boot medium's `orangepiEnv.txt` gets
`rootdev=UUID=<disk>`; `egpu-install-to-disk --revert` points it back.

```bash
sudo egpu-install-to-disk --list          # candidates (everything but the boot medium)
sudo egpu-install-to-disk /dev/sda        # asks you to type ERASE, copies, reboots
```

The image arms `egpu-firstboot.service`: after the first-boot resize, tty1 shows a
menu for 60 seconds — keep running from the medium (default), install to a listed
disk (erases it), or ask again next boot.
