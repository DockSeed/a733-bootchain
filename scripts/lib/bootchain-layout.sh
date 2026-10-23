# SPDX-License-Identifier: GPL-2.0-only OR MIT
# SPDX-FileCopyrightText: the authors of this repository
# shellcheck shell=bash
#
# Where the boot chain sits on the card, and the check that it fits. Sourced,
# never run: scripts/build.sh (`build`), scripts/flash.sh and
# scripts/test-layout.sh read the constants from here, so there is one copy
# of them.
#
# Layout of the gap in front of the first partition (offsets in KiB):
#
#   0        MBR (sector 0)
#   128      u-boot-sunxi-with-spl.bin  (the BROM loads the SPL from sector
#            256; the SPL finds the FIT behind itself, BL31 and U-Boot in it)
#   16384    first partition            (the ext4 root)
#
# This is where Radxa's setup/u-boot_setup-allwinner.sh writes the file on
# anything but UFS (the A7S has no UFS).
#
# Nothing is allocated here: the offsets are fixed, so the room the file has
# is the distance to the first partition. `dd conv=notrunc` writes past it
# without a word, and the eGON magic read back after the write is still there
# when the tail of the file has overwritten the start of the filesystem -- so
# the fit is checked from the size, before anything is written. U-Boot grows
# with every driver it gains.
#
# The boot0 + boot package layout (boot0_sdcard.bin at 128 KiB, boot_package.fex
# at 12 MiB) is written by scripts/spl-swap.sh `write-v1`, which runs on the
# board and cannot source this file; it carries its own copy of the offsets,
# and scripts/test-layout.sh fails when they differ from the ones below.
SPL_OFFSET_KIB=128
P1_START_MIB=16
V1_BOOT0_OFFSET_KIB=128
V1_BOOTPKG_OFFSET_KIB=12288   # 12 MiB

# bootchain_layout_check <u-boot-sunxi-with-spl.bin>
#     The file, at SPL_OFFSET_KIB, must end before the first partition.
#     Compared in bytes, because dd writes exactly the bytes the file has.
#     A problem is reported as an `::error::` line on stderr (the same form
#     series_load uses), and the return is 1; the caller adds the `die`. On
#     success one `===` line states the room that is left. Refuses a layout
#     whose offset is not after the MBR and before the first partition, and an
#     empty or missing file.
bootchain_layout_check() {
  local f="${1:?bootchain_layout_check: u-boot-sunxi-with-spl.bin}"
  local off=$(( SPL_OFFSET_KIB * 1024 ))
  local p1_off=$(( P1_START_MIB * 1024 * 1024 ))
  local size over

  # The MBR is sector 0 (512 B); the SPL may not start inside it.
  if [ "${off}" -lt 512 ] || [ "${off}" -ge "${p1_off}" ]; then
    echo "::error:: layout constants out of order: u-boot-sunxi-with-spl.bin @${SPL_OFFSET_KIB} KiB, first partition @$(( P1_START_MIB * 1024 )) KiB (${P1_START_MIB} MiB)" >&2
    return 1
  fi
  if [ ! -f "${f}" ]; then
    echo "::error:: ${f}: not a regular file" >&2
    return 1
  elif [ ! -s "${f}" ]; then
    echo "::error:: ${f}: empty" >&2
    return 1
  fi
  size="$(wc -c < "${f}")"
  if [ $(( off + size )) -gt "${p1_off}" ]; then
    over=$(( off + size - p1_off ))
    echo "::error:: ${f##*/} is ${size} B at ${SPL_OFFSET_KIB} KiB and ends at $(( (off + size + 1023) / 1024 )) KiB, ${over} B into the first partition at $(( P1_START_MIB * 1024 )) KiB (${P1_START_MIB} MiB; room: $(( (p1_off - off) / 1024 )) KiB)" >&2
    return 1
  fi
  printf '=== boot chain fits the image layout: u-boot-sunxi-with-spl.bin %s B at %s KiB, ends at %s KiB, %s KiB of %s KiB left before the first partition\n' \
    "${size}" "${SPL_OFFSET_KIB}" "$(( (off + size + 1023) / 1024 ))" \
    "$(( (p1_off - off - size) / 1024 ))" "$(( (p1_off - off) / 1024 ))"
}
