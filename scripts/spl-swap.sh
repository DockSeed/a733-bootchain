#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only OR MIT
# SPDX-FileCopyrightText: the authors of this repository
#
# spl-swap.sh -- as root on a running board: put a boot chain on the card
# in front of its first partition and read it back.
#
#   spl-swap.sh write <u-boot-sunxi-with-spl.bin> [<device>]
#       the file at 128 KiB (sector 256, where the BROM loads the SPL from).
#   spl-swap.sh write-v1 <boot0_sdcard.bin> <boot_package.fex> [<device>]
#       the boot0 + boot package layout: boot0 at 128 KiB, the boot package at
#       12 MiB. You bring both files yourself; this repository builds neither.
#
# Both modes write the whole boot area, 128 KiB up to 16 MiB, in one go:
# zeros with the chain at its offsets, as the area of an image built with
# that chain looks. So nothing of the other layout stays behind (a tail of
# u-boot-sunxi-with-spl.bin behind boot0, a boot package at 12 MiB), and the
# area compares equal with the image's. The area is written with
# conv=notrunc,fsync and read back with O_DIRECT, around the page cache, so a
# matching sha256 means the card holds the bytes, not the kernel's copy of them.
# The partitions stay as they are. The next cold boot runs what was written.
# There is no backup mode: keep the file you replace.
#
# Why a script: a half-written boot chain does not boot at all, and the only
# way back is then physical (another computer, or the U-Boot prompt on the
# serial console).
#
# <device> defaults to /dev/mmcblk0 (the SD card; the eMMC is another mmcblk).
# The script refuses anything that is not a whole MMC/SD block device, a file
# without its magic, and a file that would reach the first partition (start
# read from sysfs). The offsets are the ones in scripts/lib/bootchain-layout.sh
# (scripts/test-layout.sh checks them).
set -eu
SPL_OFF_KIB=128
V1_BOOT0_OFF_KIB=128
V1_PKG_OFF_KIB=12288
AREA_OFF_KIB=128
AREA_END_KIB=16384

die() { echo "$*" >&2; exit 1; }
usage() { die "usage: $0 write <u-boot-sunxi-with-spl.bin> [device] | write-v1 <boot0_sdcard.bin> <boot_package.fex> [device]"; }

# magic <file> <offset> <length> -- the bytes at that offset
magic() { dd if="$1" bs=1 skip="$2" count="$3" status=none; }

# sha_file <file>; sha_dev <offset-bytes> <length-bytes> -- the second reads
# the device with O_DIRECT in 512 B sectors and cuts the result to the length.
sha_file() { sha256sum "$1" | cut -d' ' -f1; }
sha_dev() {
  dd if="$DEV" bs=512 skip=$(( $1 / 512 )) count=$(( ($2 + 511) / 512 )) iflag=direct status=none \
    | head -c "$2" | sha256sum | cut -d' ' -f1
}

# area_new; place <file> <offset-KiB>; area_put -- build the area in a
# file (zeros), put the chain into it, then write it, read it back, compare.
area_new() {
  AREA="$(mktemp)"
  trap 'rm -f "$AREA"' EXIT
  dd if=/dev/zero of="$AREA" bs=1024 count=$(( AREA_END_KIB - AREA_OFF_KIB )) status=none
}
place() {
  dd if="$1" of="$AREA" bs=1024 seek=$(( $2 - AREA_OFF_KIB )) conv=notrunc status=none
  echo "$(basename "$1"): $(stat -c%s "$1") B at $2 KiB, sha256 $(sha_file "$1")"
}
area_put() {
  len=$(( (AREA_END_KIB - AREA_OFF_KIB) * 1024 ))
  want="$(sha_file "$AREA")"
  old="$(sha_dev $(( AREA_OFF_KIB * 1024 )) "$len")"
  echo "boot area $AREA_OFF_KIB KiB .. $AREA_END_KIB KiB"
  echo "  before: $old"
  echo "  new:    $want"
  if [ "$old" = "$want" ]; then echo "  already on the card"; return 0; fi
  dd if="$AREA" of="$DEV" bs=1024 seek="$AREA_OFF_KIB" conv=notrunc,fsync status=none
  sync
  got="$(sha_dev $(( AREA_OFF_KIB * 1024 )) "$len")"
  echo "  after:  $got"
  [ "$got" = "$want" ] || die "READBACK MISMATCH of the boot area -- do not power-cycle"
}

# fits <file> <offset-KiB> <limit-bytes> <what> -- the file ends before the limit
fits() {
  [ -s "$1" ] || die "$1: missing or empty"
  end=$(( $2 * 1024 + $(stat -c%s "$1") ))
  [ "$end" -le "$3" ] || die "$1 ends at $end B, $4 starts at $3 B"
}

[ $# -ge 1 ] || usage
mode="$1"; shift
case "$mode" in
  write)    [ $# -ge 1 ] && [ $# -le 2 ] || usage; SPL="$1"; DEV="${2:-/dev/mmcblk0}" ;;
  write-v1) [ $# -ge 2 ] && [ $# -le 3 ] || usage; BOOT0="$1"; PKG="$2"; DEV="${3:-/dev/mmcblk0}" ;;
  *) usage ;;
esac

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -b "$DEV" ] || die "$DEV is not a block device"
case "$DEV" in /dev/mmcblk[0-9]) ;; *) die "$DEV: whole MMC/SD device only" ;; esac
b="${DEV##*/}"
[ -r "/sys/block/$b/${b}p1/start" ] \
  || die "$DEV has no first partition in sysfs -- cannot bound the write"
p1=$(( $(cat "/sys/block/$b/${b}p1/start") * 512 ))
[ "$p1" -ge $(( AREA_END_KIB * 1024 )) ] || die "first partition at $(( p1 / 1024 )) KiB, before the end of the boot area ($AREA_END_KIB KiB)"
echo "device $DEV ($(cat "/sys/block/$b/device/name" 2>/dev/null)), first partition at $(( p1 / 1024 )) KiB"

case "$mode" in
  write)
    [ "$(magic "$SPL" 4 8)" = eGON.BT0 ] || die "$SPL: no eGON.BT0 magic at offset 4"
    fits "$SPL" "$SPL_OFF_KIB" $(( AREA_END_KIB * 1024 )) "the end of the boot area"
    area_new; place "$SPL" "$SPL_OFF_KIB"; area_put
    echo "ok: the next cold boot runs this SPL, BL31 and U-Boot"
    ;;
  write-v1)
    [ "$(magic "$BOOT0" 4 8)" = eGON.BT0 ] || die "$BOOT0: no eGON.BT0 magic at offset 4"
    [ "$(magic "$PKG" 0 13)" = sunxi-package ] || die "$PKG: no sunxi-package magic at offset 0"
    fits "$BOOT0" "$V1_BOOT0_OFF_KIB" $(( V1_PKG_OFF_KIB * 1024 )) "the boot package"
    fits "$PKG" "$V1_PKG_OFF_KIB" $(( AREA_END_KIB * 1024 )) "the end of the boot area"
    area_new; place "$BOOT0" "$V1_BOOT0_OFF_KIB"; place "$PKG" "$V1_PKG_OFF_KIB"; area_put
    echo "ok: the next cold boot runs this boot0 + boot package chain"
    ;;
esac
