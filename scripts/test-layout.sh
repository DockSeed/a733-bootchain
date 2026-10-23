#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only OR MIT
# SPDX-FileCopyrightText: the authors of this repository
#
# Does the boot-chain size guard (scripts/lib/bootchain-layout.sh) pass
# what fits and refuse what does not -- no root, no board, no image?
#
# A flasher writes u-boot-sunxi-with-spl.bin at 128 KiB into the gap in front
# of p1 (16 MiB). Nothing there is allocated, and a file past the room
# overwrites the start of the ext4 filesystem while the magic that a flasher
# reads back is still in place. The writers need root, so the guard is a
# function of a file size and the layout constants, and this runs the
# function on sparse files of exactly the sizes that matter, taking the limits
# from the constants themselves so a changed layout moves the cases with it.
#
# Cases:
#   - a 1.5 MiB chain passes; the file of a real chain too, when
#     BOOTCHAIN_DIR names a directory holding u-boot-sunxi-with-spl.bin
#   - a file of exactly the room passes; one KiB and one byte more fail
#   - a missing file and an empty file fail
#   - the limits are the constants, not literals: moved constants move the
#     verdict, and a layout whose offset is not after the MBR and before p1
#     is refused
#   - wiring: build.sh calls the guard in `build` before it copies anything
#     to out/, and defines no layout constant of its own; flash.sh calls it
#     before it writes; spl-swap.sh, which runs on the board and
#     cannot source the library, carries the same offsets
#
# Exit 0 = every case held.
set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=lib/bootchain-layout.sh
. "${HERE}/scripts/lib/bootchain-layout.sh"

# BUILD_SH names the build.sh the wiring cases read; a copy with the guard taken
# out shows that they fail.
BUILD_SH="${BUILD_SH:-${HERE}/scripts/build.sh}"

T=$(mktemp -d) || exit 2
trap 'rm -rf "${T}"' EXIT
n=0 failed=0

# mk <name> <bytes> -- a sparse file of that size
mk() { truncate -s "$2" "${T}/$1"; }

# pass <name> <file>; fail <name> <expected-text> <file>
# Each runs the check in a subshell, so a case may override a constant.
pass() {
  local name="$1" out rc
  n=$((n + 1))
  out="$(bootchain_layout_check "${T}/$2" 2>&1)"; rc=$?
  if [ "${rc}" = 0 ] && [ -z "${out##===*}" ]; then
    echo "ok   ${n}: ${name}"; echo "       ${out}"
  else
    echo "FAIL ${n}: ${name}: rc=${rc}, wanted 0 and a === line"; echo "       ${out}"; failed=$((failed + 1))
  fi
}
fail() {
  local name="$1" want="$2" out rc
  n=$((n + 1))
  out="$(bootchain_layout_check "${T}/$3" 2>&1)"; rc=$?
  if [ "${rc}" = 1 ] && printf '%s\n' "${out}" | grep -qF -- "${want}"; then
    echo "ok   ${n}: ${name}"; printf '%s\n' "${out}" | sed 's/^/       /'
  else
    echo "FAIL ${n}: ${name}: rc=${rc}, wanted 1 and '${want}'"; printf '%s\n' "${out}" | sed 's/^/       /'; failed=$((failed + 1))
  fi
}
check() { # check <name> <command...>
  local name="$1"; shift
  n=$((n + 1))
  if "$@"; then echo "ok   ${n}: ${name}"; else echo "FAIL ${n}: ${name}"; failed=$((failed + 1)); fi
}

room=$(( (P1_START_MIB * 1024 - SPL_OFFSET_KIB) * 1024 ))
echo "layout: u-boot-sunxi-with-spl.bin @${SPL_OFFSET_KIB} KiB (room ${room} B), p1 @${P1_START_MIB} MiB"

mk chain-1m5 1572864
pass "a 1.5 MiB chain" chain-1m5
if [ -n "${BOOTCHAIN_DIR:-}" ]; then
  n=$((n + 1))
  if out="$(bootchain_layout_check "${BOOTCHAIN_DIR}/u-boot-sunxi-with-spl.bin" 2>&1)"; then
    echo "ok   ${n}: real file in ${BOOTCHAIN_DIR}"; echo "       ${out}"
  else
    echo "FAIL ${n}: real file in ${BOOTCHAIN_DIR}"; echo "       ${out}"; failed=$((failed + 1))
  fi
fi

# The file against p1.
mk max "${room}"
mk max-1k $(( room + 1024 ))
mk max-1b $(( room + 1 ))
mk max-minus-1b $(( room - 1 ))
pass "a file of exactly the room (${room} B) passes" max
pass "one byte under the room passes" max-minus-1b
fail "one KiB over the room fails" "first partition" max-1k
fail "one byte over the room fails" "1 B into the first partition" max-1b

# Not a file the guard can size.
: > "${T}/empty"
fail "a missing file fails" "not a regular file" absent
fail "an empty file fails" "empty" empty

# The limits are the constants. Each case moves one in a subshell and asks again.
# moved <pass|fail> <name> <file> VAR=VALUE...
moved() {
  local want="$1" name="$2" f="$3" rc a
  shift 3
  n=$((n + 1))
  ( for a in "$@"; do declare -g "${a%%=*}=${a#*=}"; done
    bootchain_layout_check "${T}/${f}" ) >/dev/null 2>&1; rc=$?
  if { [ "${want}" = pass ] && [ "${rc}" = 0 ]; } || { [ "${want}" = fail ] && [ "${rc}" = 1 ]; }; then
    echo "ok   ${n}: ${name}"
  else
    echo "FAIL ${n}: ${name}: rc=${rc}, wanted ${want}"; failed=$((failed + 1))
  fi
}
moved fail "p1 moved to 1 MiB: the 1.5 MiB chain no longer fits" chain-1m5 P1_START_MIB=1
moved pass "p1 moved to 2 MiB: the 1.5 MiB chain still fits" chain-1m5 P1_START_MIB=2
moved fail "offset moved to 512 KiB: the file of exactly the room no longer fits" max SPL_OFFSET_KIB=512
moved fail "offset at p1: refused, offsets out of order" chain-1m5 "SPL_OFFSET_KIB=$(( P1_START_MIB * 1024 ))"
moved fail "offset 0, inside the MBR: refused" chain-1m5 SPL_OFFSET_KIB=0

# Wiring. first_line <file> <function> <pattern> = line (within the file) of
# the first match inside that function, or nothing.
first_line() {
  awk -v fn="$2" -v pat="$3" '
    $0 ~ "^"fn"\\(\\) *\\{" { f = 1; next }
    f && /^}/ { f = 0 }
    f && index($0, pat) && $0 !~ /^[[:space:]]*#/ { print NR; exit }' "$1"
}
guard_before() { # guard_before <function> <first-write-pattern>
  local g w
  g="$(first_line "${BUILD_SH}" "$1" 'bootchain_layout_check "')"; w="$(first_line "${BUILD_SH}" "$1" "$2")"
  [ -n "${g}" ] && [ -n "${w}" ] && [ "${g}" -lt "${w}" ]
}
# The patterns are literal text of build.sh, not expansions.
# shellcheck disable=SC2016
check "build.sh build calls the guard before it copies the chain to out/" \
  guard_before stage_build_bootchain 'cp "${img}"'
no_own_constants() { ! grep -Eq '^[[:space:]]*(SPL_OFFSET_KIB|P1_START_MIB|V1_BOOT0_OFFSET_KIB|V1_BOOTPKG_OFFSET_KIB)=' "${BUILD_SH}" "${HERE}/scripts/flash.sh"; }
check "build.sh and flash.sh define no layout constant (one source: scripts/lib/bootchain-layout.sh)" no_own_constants
flash_guard_before_write() {
  local g w
  g="$(grep -n 'bootchain_layout_check "' "${HERE}/scripts/flash.sh" | head -1 | cut -d: -f1)"
  w="$(grep -n 'of="${target}"' "${HERE}/scripts/flash.sh" | head -1 | cut -d: -f1)"
  [ -n "${g}" ] && [ -n "${w}" ] && [ "${g}" -lt "${w}" ]
}
check "flash.sh calls the guard before it writes" flash_guard_before_write
sw() { sed -n "s/^$1=\([0-9][0-9]*\).*/\1/p" "${HERE}/scripts/$2"; }
check "spl-swap.sh SPL_OFF_KIB ($(sw SPL_OFF_KIB spl-swap.sh)) is SPL_OFFSET_KIB (${SPL_OFFSET_KIB})" \
  test "$(sw SPL_OFF_KIB spl-swap.sh)" = "${SPL_OFFSET_KIB}"
check "spl-swap.sh V1_BOOT0_OFF_KIB ($(sw V1_BOOT0_OFF_KIB spl-swap.sh)) is V1_BOOT0_OFFSET_KIB (${V1_BOOT0_OFFSET_KIB})" \
  test "$(sw V1_BOOT0_OFF_KIB spl-swap.sh)" = "${V1_BOOT0_OFFSET_KIB}"
check "spl-swap.sh V1_PKG_OFF_KIB ($(sw V1_PKG_OFF_KIB spl-swap.sh)) is V1_BOOTPKG_OFFSET_KIB (${V1_BOOTPKG_OFFSET_KIB})" \
  test "$(sw V1_PKG_OFF_KIB spl-swap.sh)" = "${V1_BOOTPKG_OFFSET_KIB}"

echo
if [ "${failed}" = 0 ]; then echo "${n} cases, all held"; else echo "${n} cases, ${failed} FAILED"; fi
[ "${failed}" = 0 ]
