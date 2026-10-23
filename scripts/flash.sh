#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: the authors of this repository
#
# Write the boot chain into the gap in front of the first partition of a disk
# or image file: u-boot-sunxi-with-spl.bin at 128 KiB. Nothing else on the
# target changes (conv=notrunc). Works on an SD card, an eMMC seen as a block
# device, or a raw .img. The boot0 + boot package layout is not handled here
# (scripts/spl-swap.sh write-v1 does it on a running board).
#
# Usage: scripts/flash.sh <target> [<chain-dir>]
#   <target>     block device (e.g. /dev/sdX) or image file
#   <chain-dir>  default out/bootchain
#
# Refuses a file that does not fit the layout (scripts/lib/bootchain-layout.sh)
# or has no eGON.BT0 magic, and reads the written bytes back and compares
# their sha256 after the write.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/bootchain-layout.sh"

target="${1:?usage: $0 <block-device|image> [chain-dir]}"
chain="${2:-${ROOT_DIR}/out/bootchain}"
spl="${chain}/u-boot-sunxi-with-spl.bin"

die() { printf '::error:: %s\n' "$*" >&2; exit 1; }

[ -e "${target}" ] || die "${target} does not exist"
bootchain_layout_check "${spl}" || die "the chain does not fit the layout; nothing written"
[ "$(dd if="${spl}" bs=1 skip=4 count=8 status=none)" = "eGON.BT0" ] \
  || die "${spl}: no eGON.BT0 magic at offset 4"
if [ -b "${target}" ]; then
  printf 'About to overwrite the boot gap of %s (%s). Type the device path to go on: ' \
    "${target}" "$(lsblk -dno SIZE,MODEL "${target}" 2>/dev/null | xargs)"
  read -r answer
  [ "${answer}" = "${target}" ] || die "not confirmed"
fi

size="$(stat -c%s "${spl}")"
dd if="${spl}" of="${target}" bs=512 seek=$(( SPL_OFFSET_KIB * 2 )) conv=notrunc,fsync status=none
sync

direct=""; [ -b "${target}" ] && direct="iflag=direct"
# shellcheck disable=SC2086
got="$(dd if="${target}" bs=512 skip=$(( SPL_OFFSET_KIB * 2 )) count=$(( (size + 511) / 512 )) ${direct} status=none \
  | head -c "${size}" | sha256sum | cut -d' ' -f1)"
[ "${got}" = "$(sha256sum "${spl}" | cut -d' ' -f1)" ] \
  || die "readback of ${target} at ${SPL_OFFSET_KIB} KiB does not match ${spl}"
echo "=== boot chain written and read back: u-boot-sunxi-with-spl.bin (${size} B, sha256 ${got}) @${SPL_OFFSET_KIB} KiB"
