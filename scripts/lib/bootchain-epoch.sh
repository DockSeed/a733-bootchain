# SPDX-License-Identifier: GPL-2.0-only OR MIT
# SPDX-FileCopyrightText: the authors of this repository
# shellcheck shell=bash
#
# The time every timestamp in the boot chain is built with. Sourced, never run;
# scripts/build.sh (stage `build`) exports the result as SOURCE_DATE_EPOCH.
#
# Why it exists: u-boot-sunxi-with-spl.bin carries the time it was built: the
# U-Boot banners of the SPL and of U-Boot (`... (Sep 15 2026 - 08:50:12 +0000)`),
# TF-A's `Built :` string, the FIT `timestamp` property. Built twice with one
# SOURCE_DATE_EPOCH the chain is byte-identical, so the clock is the only input
# left, and without pinning it no rebuild can be compared byte for byte with an
# earlier chain.
#
# What honours the variable (read in the pinned trees):
#   U-Boot banner   src/Makefile `filechk_timestamp.h`: `date -u -d @$epoch`,
#                   U_BOOT_DATE / U_BOOT_TIME / U_BOOT_TZ (always +0000)
#   FIT timestamp   src/tools/image-host.c and fit_image.c, through
#                   `imagetool_get_source_date`; src/Makefile `fit-dtb.blob`
#                   (touch -d @$epoch)
#   TF-A `Built :`  atf/Makefile `BUILD_MESSAGE_TIMESTAMP ?= __TIME__", "__DATE__`;
#                   GCC takes __TIME__/__DATE__ from SOURCE_DATE_EPOCH (GCC >= 7,
#                   UTC)
# The other word that changes with the banners is derived, not a clock: the
# eGON.BT0 check_sum of the SPL, a sum over content the SPL banner is part of.
# stage_build_bootchain reads the result back out of
# u-boot-sunxi-with-spl.bin, so a tool that stops honouring the
# variable fails the stage instead of shipping a chain that cannot be reproduced.
#
# The epoch is the committer date of the pinned package commit.
#   - It is a function of BOOTCHAIN_COMMIT alone, so it is the same in every
#     clone and on every machine. The other inputs of the chain are pinned by
#     that commit (the submodule pins) or by overlay/ and patches/ (the TF-A
#     base commit, the patches): an unchanged chain gets an unchanged epoch and
#     a moved pin moves the epoch.
#   - The banner therefore says when the pinned package was committed, not when
#     the chain was built. What says which chain it is: BOOTCHAIN-ID (upstream,
#     overlay hash, `source_date_epoch`) and `built=`, the real build time, which
#     lives in that stamp and not in the firmware.
#
# This file is part of the chain's identity: `bootchain_overlay_id`
# (scripts/build.sh) hashes it with the overlay, so editing the derivation
# changes the identity stamped into BOOTCHAIN-ID.
#
# API
#   bootchain_source_date_epoch <package-clone-dir>
#       prints the epoch (seconds) on stdout; returns 1 when the pinned commit is
#       not in the clone or its date is not a number. Needs BOOTCHAIN_COMMIT.
bootchain_source_date_epoch() {
  local dir="$1" ct
  ct="$(git -C "${dir}" log -1 --format=%ct "${BOOTCHAIN_COMMIT}" 2>/dev/null)" || return 1
  case "${ct}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "${ct}"
}
