#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: the authors of this repository
#
# Boot chain for the Radxa Cubie A7S (Allwinner A733): U-Boot SPL (DRAM init
# through the vendor blob awbin/a733/ddr.bin) + BL31 (TF-A, built from source)
# + U-Boot -> u-boot-sunxi-with-spl.bin.
#
# Usage: scripts/build.sh <stage>
#   pins            print the pinned inputs
#   fetch           clone radxa-pkg/u-boot-dlan17 at the pinned commit, fetch
#                   the submodules the A7S build uses and apply overlay/ +
#                   patches/ (BL31 from source)
#   apply-overlay   apply the overlay to an already cloned tree (work/u-boot-dlan17)
#   build           build SPL + BL31 + U-Boot -> u-boot-sunxi-with-spl.bin, run
#                   the post-build assertions, write out/bootchain/
#   key             print the identity of this checkout's chain (cache key)
#   all             fetch + build
#
# Needs an aarch64 cross compiler (CROSS_COMPILE, default aarch64-linux-gnu-;
# on an aarch64 host the native gcc), make, swig, flex, bison, xxd,
# dpkg-parsechangelog and the build dependencies in the package's
# debian/control (container/packages.txt lists them all). Nothing in the build
# is tied to the host architecture.
set -euo pipefail

# TF-A make_helpers/toolchain.mk greps the output of `gcc -v` for "gcc
# version", which a localized gcc translates, and the build fails; C is also
# the locale the chain was built and proven with.
export LC_ALL=C

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/work}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out}"
. "${ROOT_DIR}/scripts/lib/series.sh"
. "${ROOT_DIR}/scripts/lib/bootchain-epoch.sh"
. "${ROOT_DIR}/scripts/lib/bootchain-layout.sh"

log() { printf '=== %s\n' "$*"; }
die() { printf '::error:: %s\n' "$*" >&2; exit 1; }

# --- pins ---

# --- boot chain: radxa-pkg/u-boot-dlan17, built by us ---
# Pinned to a COMMIT, not to a branch: exact commits only.
# b1cec0a9 = tag 2026.04-4 (2026-09-15): the chain without boot0. One
# u-boot-sunxi-with-spl.bin; the SPL initialises DRAM through
# awbin/a733/ddr.bin (SUNXI_LIBDRAM). Radxa's U-Boot changes are commits in
# `src` (radxa/u-boot, branch u-boot-dlan17), no quilt series any more.
# docs/boot-chain.md says what each part is and where it comes from.
BOOTCHAIN_URL="https://github.com/radxa-pkg/u-boot-dlan17.git"
BOOTCHAIN_COMMIT="b1cec0a90c795f65b82cee7098489e0bdf550b74"
BOOTCHAIN_BOARD="radxa-cubie-a7s"
# The submodules the A7S build uses, with the commit the package must pin for
# each. `src` is U-Boot. Not fetched: `atf` (overlay/apply.sh puts upstream
# TF-A there and asserts radxa's pin), `allwinner-arisc` and
# `allwinner-dramlib` (only the SCP build uses them; no SCP on this chain),
# `tools` (only the SCP firmware and the boot_package.fex packer of the earlier
# chain used them).
BOOTCHAIN_SUBMODULES="src:9da4b3e82d641296f5b19d5e78eaad0d3cf56eec"
# `src` (radxa/u-boot 9da4b3e82d64) is fetched by hash because a branch tip may be
# rewritten. BOOTCHAIN_MIRROR may name a URL prefix that serves a git bundle per
# submodule listed here, <name>.bundle (scripts/make-mirror.sh writes them);
# the rest come from .gitmodules. The pins decide either way:
# stage_fetch_bootchain checks every fetched submodule against the package
# tree and against BOOTCHAIN_SUBMODULES.
BOOTCHAIN_MIRRORED="src"

stage_pins() {
  log "bootchain: ${BOOTCHAIN_URL} @ ${BOOTCHAIN_COMMIT}"
  log "           submodules fetched: ${BOOTCHAIN_SUBMODULES}"
  log "           from the mirror: ${BOOTCHAIN_MIRRORED} (BOOTCHAIN_MIRROR=${BOOTCHAIN_MIRROR:-<unset: upstream>})"
  # The TF-A pin lives in overlay/apply.sh, which is part of the overlay id.
  log "tf-a     : $(sed -n 's/^ATF_UPSTREAM="\(.*\)"$/\1/p' "${ROOT_DIR}/overlay/apply.sh") @ $(sed -n 's/^ATF_BASE="\([0-9a-f]\{40\}\)".*/\1/p' "${ROOT_DIR}/overlay/apply.sh") + patches/tf-a"
  log "blobs    : $(grep -vE '^[[:space:]]*(#|$)' "${ROOT_DIR}/pins/blobs.sha256" | awk '{printf "%s %s; ", $2, $1}')"
  log "overlay  : $(bootchain_overlay_id)"
}

# Put BOOTCHAIN_MIRROR/<name>.bundle under work/ and print its path. Prints
# nothing when the mirror is unset or the download fails, and the caller then
# uses upstream: a mirror that is down must not fail a build upstream can serve.
bootchain_mirror_bundle() {
  local name="$1" dst="${WORK_DIR}/bootchain-mirror/$1.bundle"
  [ -n "${BOOTCHAIN_MIRROR:-}" ] || return 0
  if [ ! -s "${dst}" ]; then
    mkdir -p "$(dirname "${dst}")"
    rm -f "${dst}.part"
    if ! curl -fsSL --retry 3 --retry-all-errors --retry-delay 5 \
        --connect-timeout 20 --max-time 900 -o "${dst}.part" \
        "${BOOTCHAIN_MIRROR}/${name}.bundle"; then
      printf '::warning:: boot chain: %s.bundle not fetched from %s, using upstream\n' \
        "${name}" "${BOOTCHAIN_MIRROR}" >&2
      rm -f "${dst}.part"
      return 0
    fi
    mv "${dst}.part" "${dst}"
  fi
  printf '%s\n' "${dst}"
}

# Check out every submodule of BOOTCHAIN_SUBMODULES at the commit the package
# tree pins, one by one, and prove it; that pin must also be the one named
# there. A pin that no longer answers is the failure the mirror guards against,
# so the message names the submodule, the pin and the source that was asked.
# Submodule names equal their paths in this package; the name lookup fails
# loud if not. The submodules the build does not use stay empty and are
# listed with their pins.
bootchain_submodules() {
  local link pin path url bundle links want entry depth
  # Read before the loop: a git inside it that asks for credentials (its
  # failed fetch did) would otherwise eat the rest of the list from stdin.
  mapfile -t links < <(git ls-tree HEAD | awk '$2=="commit" {print $3, $4}')
  local -A have=()
  for link in "${links[@]}"; do have["${link#* }"]="${link%% *}"; done
  for entry in ${BOOTCHAIN_SUBMODULES}; do
    [ -n "${have[${entry%%:*}]:-}" ] \
      || die "boot chain: the package has no submodule ${entry%%:*}"
  done
  for link in "${links[@]}"; do
    pin="${link%% *}" path="${link#* }"
    want=""
    for entry in ${BOOTCHAIN_SUBMODULES}; do
      [ "${entry%%:*}" = "${path}" ] && want="${entry#*:}"
    done
    if [ -z "${want}" ]; then
      printf '        %s %s  (not fetched: the A7S build does not use it)\n' "${pin:0:12}" "${path}"
      continue
    fi
    [ "${pin}" = "${want}" ] \
      || die "boot chain: the package pins ${path} at ${pin}, build.sh BOOTCHAIN_SUBMODULES expects ${want} -- re-verify before changing a pin"
    url="$(git config -f .gitmodules "submodule.${path}.url")" \
      || die "boot chain: no .gitmodules entry named ${path}"
    bundle=""
    case " ${BOOTCHAIN_MIRRORED} " in
      *" ${path} "*) bundle="$(bootchain_mirror_bundle "${path}")" ;;
    esac
    [ -z "${bundle}" ] || url="${bundle}"
    git submodule --quiet init -- "${path}" || die "boot chain: git submodule init ${path} failed"
    git config "submodule.${path}.url" "${url}"
    # From upstream only the pinned commit is fetched (--depth 1, by hash):
    # the repository holds many branches. Nothing in the build reads the
    # history (U-Boot's version suffix is the commit hash, as the package sets
    # UBOOTVERSION, which matches no tag). A bundle is read whole.
    depth="--depth=1"; [ -z "${bundle}" ] || depth=""
    # A bundle is a local transport, which git refuses for submodules unless
    # told (CVE-2022-39253). The URL is ours, set on the line above.
    # shellcheck disable=SC2086
    git -c protocol.file.allow=always submodule update --init --quiet ${depth} -- "${path}" \
      || die "boot chain: submodule ${path} pin ${pin} not fetchable from ${url} (git's reason above). If upstream rewrote or garbage-collected it, the pin has to be in BOOTCHAIN_MIRRORED and in a bundle that BOOTCHAIN_MIRROR points to (scripts/make-mirror.sh)."
    [ "$(git -C "${path}" rev-parse HEAD)" = "${pin}" ] \
      || die "boot chain: submodule ${path} is at $(git -C "${path}" rev-parse HEAD), the package pins ${pin}"
    printf '        %s %s  <- %s\n' "${pin:0:12}" "${path}" "${url}"
  done
}

# Every prebuilt file taken from the package tree must match pins/blobs.sha256
# (paths relative to the tree). A moved or altered blob stops the stage.
bootchain_verify_blobs() {
  local dir="${1:-${WORK_DIR}/u-boot-dlan17}" pins="${ROOT_DIR}/pins/blobs.sha256" n
  [ -s "${pins}" ] || die "pins/blobs.sha256 missing or empty"
  n="$(grep -vcE '^[[:space:]]*(#|$)' "${pins}")"
  ( cd "${dir}" && grep -vE '^[[:space:]]*(#|$)' "${pins}" | sha256sum -c --quiet - ) \
    || die "a prebuilt file in ${dir} does not match pins/blobs.sha256 (listed above)"
  log "prebuilt files verified against pins/blobs.sha256 (${n} file(s))"
}

# Clone the boot-chain package at the pinned commit and prove it is that commit.
# Only the submodules in BOOTCHAIN_SUBMODULES are fetched; bootchain_submodules
# checks and prints each one, with where it came from (the mirror for
# BOOTCHAIN_MIRRORED).
#
# The overlay (overlay/ and patches/) is applied at the end of this stage: it
# rewires the A7S Makefile target to build and consume BL31 from upstream TF-A
# source instead of the awbin/a733/bl31.bin blob, without SCP, and applies the
# U-Boot patches to src/.
stage_fetch_bootchain() {
  mkdir -p "${WORK_DIR}"
  local dir="${WORK_DIR}/u-boot-dlan17"
  if [ ! -d "${dir}/.git" ]; then
    rm -rf "${dir}"
    git clone --quiet "${BOOTCHAIN_URL}" "${dir}" || die "boot chain clone failed"
  fi
  cd "${dir}"
  git fetch --quiet origin || die "boot chain fetch failed"
  git checkout --quiet --detach "${BOOTCHAIN_COMMIT}" \
    || die "boot chain: pinned commit ${BOOTCHAIN_COMMIT} not found"
  # Verify, do not trust: a checkout that silently landed elsewhere would build
  # another chain.
  local got; got="$(git rev-parse HEAD)"
  [ "${got}" = "${BOOTCHAIN_COMMIT}" ] \
    || die "boot chain HEAD is ${got}, expected ${BOOTCHAIN_COMMIT}"
  log "boot chain at ${BOOTCHAIN_COMMIT} (verified)"
  log "submodule pins (verified):"
  bootchain_submodules
  bootchain_verify_blobs "${dir}"
  # The package ships a prebuilt BL31; the overlay stops wiring it in. Printed
  # for awareness: knowing what Radxa shipped helps when diagnosing a regression.
  if [ -f awbin/a733/bl31.bin ]; then
    local bl31_ver
    bl31_ver="$(grep -a -m1 -o 'v2\.[0-9][0-9a-z.()]*:[0-9a-f]*\(-dirty\)\{0,1\}' awbin/a733/bl31.bin 2>/dev/null)" \
      || bl31_ver="<no version string>"
    log "awbin/a733/bl31.bin (prebuilt, UNUSED after overlay): $(stat -c%s awbin/a733/bl31.bin) B, ${bl31_ver}"
  fi
  stage_apply_bootchain_overlay "${dir}"
}

# Identity of the boot-chain overlay as it exists in THIS checkout: one hash over
# every file under overlay/, patches/ and pins/, and the two scripts that decide
# what the chain contains without living in it: scripts/lib/series.sh (which
# patches apply) and scripts/lib/bootchain-epoch.sh (the build time every
# timestamp in the firmware is pinned to). Recomputed, never stored, so editing
# any of them changes it. Paths are hashed relative to the repository root, so
# the identity does not depend on where the repo is checked out, and a rename
# changes it.
#
# It exists so that a chain built before an overlay change cannot be mistaken
# for one built after it: the build stamps it into BOOTCHAIN-ID and
# stage_build_bootchain refuses a tree that carries another one.
bootchain_overlay_id() {
  { ( cd "${ROOT_DIR}" \
        && find overlay patches pins -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) \
    && ( cd "${ROOT_DIR}" && sha256sum scripts/lib/series.sh scripts/lib/bootchain-epoch.sh ); } \
    | sha256sum | cut -d' ' -f1
}

# The key of a boot chain: the pinned upstream commit plus the identity of the
# overlay. Both are known from this checkout alone, with no fetch and no build.
# They are the same two fields the BOOTCHAIN-ID stamp carries.
stage_bootchain_key() {
  printf '%s-%s\n' "$(printf '%s' "${BOOTCHAIN_COMMIT}" | cut -c1-12)" \
                    "$(bootchain_overlay_id | cut -c1-12)"
}

# Apply the boot-chain overlay (BL31 from TF-A source instead of the prebuilt
# awbin/a733/bl31.bin, no SCP, the U-Boot patches in src/). Every assumption
# about Radxa's tree shape is asserted inside apply.sh: an upstream edit that
# touches the same lines fails this stage loudly rather than producing a
# different machine. The tree then carries the overlay id in .bootchain-overlay,
# which the build stage compares with this checkout's.
stage_apply_bootchain_overlay() {
  local dir="${1:-${WORK_DIR}/u-boot-dlan17}"
  [ -x "${ROOT_DIR}/overlay/apply.sh" ] \
    || die "overlay/apply.sh missing or not executable"
  [ -d "${dir}/.git" ] || die "boot chain missing -- run \`build.sh fetch\` first"
  log "applying overlay/ and patches/ (source BL31)"
  "${ROOT_DIR}/overlay/apply.sh" "${dir}" \
    || die "bootchain overlay failed to apply (see messages above)"
  bootchain_overlay_id > "${dir}/.bootchain-overlay"
}

# Build the chain with the package's own make glue (.github/local/Makefile.local,
# target radxa-cubie-a7s): BL31 from source, then U-Boot with the SPL, binman
# packing u-boot-sunxi-with-spl.bin. Then prove the result is what the patches
# say. The package's debuild path (-> .deb) is not used.

# kconfig_value <.config> <SYMBOL> -- the value of CONFIG_<SYMBOL>, "n" when
# it is not set; quotes kept.
kconfig_value() {
  local v
  v="$(sed -n "s/^CONFIG_$2=\(.*\)\$/\1/p" "$1")"
  printf '%s\n' "${v:-n}"
}

stage_build_bootchain() {
  local dir="${WORK_DIR}/u-boot-dlan17"
  [ -d "${dir}/.git" ] || die "boot chain missing -- run \`build.sh fetch\` first"
  # Refuse a tree that does not carry THIS checkout's overlay: a tree without
  # it brings back the prebuilt BL31 blob, a tree with another one is another
  # chain.
  [ "$(cat "${dir}/.bootchain-overlay" 2>/dev/null)" = "$(bootchain_overlay_id)" ] \
    || die "${dir} does not carry this checkout's overlay -- remove ${dir} and run \`build.sh fetch\` again"
  # Pin every build time in the firmware to the pinned package commit's date
  # (why that date: scripts/lib/bootchain-epoch.sh). An epoch already in
  # the environment is replaced, not trusted: a shell that exports one would
  # make two builds of the same input differ.
  local epoch
  epoch="$(bootchain_source_date_epoch "${dir}")" \
    || die "boot chain: cannot read the committer date of ${BOOTCHAIN_COMMIT} in ${dir}"
  if [ -n "${SOURCE_DATE_EPOCH:-}" ] && [ "${SOURCE_DATE_EPOCH}" != "${epoch}" ]; then
    log "ambient SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} replaced by the pinned ${epoch}"
  fi
  export SOURCE_DATE_EPOCH="${epoch}"
  log "boot chain SOURCE_DATE_EPOCH=${epoch} ($(date -u -d "@${epoch}" '+%Y-%m-%d %H:%M:%S') UTC), committer date of ${BOOTCHAIN_COMMIT}"
  bootchain_verify_blobs "${dir}"
  cd "${dir}"
  # Check the toolchains up front rather than dying halfway through a build.
  # CROSS_COMPILE as the package's Makefile.extra takes it (default
  # aarch64-linux-gnu-); on an aarch64 host without that name, the native gcc.
  local tc="${CROSS_COMPILE-aarch64-linux-gnu-}"
  if ! command -v "${tc}gcc" >/dev/null && [ "$(uname -m)" = aarch64 ] && command -v gcc >/dev/null; then
    tc=""
  fi
  command -v "${tc}gcc" >/dev/null \
    || die "${tc}gcc missing: an aarch64 cross compiler (CROSS_COMPILE, default aarch64-linux-gnu-) or, on an aarch64 host, gcc"
  export CROSS_COMPILE="${tc}"
  # The rest of what this stage needs, checked here for the reason the comment
  # above gives. The authority for the list is the package's own debian/control
  # Build-Depends; container/packages.txt carries them for the container.
  #
  # Fedora names, where they differ from the Debian ones:
  #   python3-devel · swig · ncurses-devel · gnutls-devel · dpkg-dev
  #   python3-setuptools · python3-pyelftools · openssl-devel-engine
  #
  # U-Boot's lib/rsa/rsa-sign.c includes <openssl/engine.h>; where the ENGINE
  # API is a separate package (openssl-devel-engine), install it.
  #
  # dpkg-parsechangelog: the package's Makefile.extra derives UBOOTVERSION
  # from debian/changelog with it.
  for t in make swig flex bison xxd dpkg-parsechangelog; do
    command -v "$t" >/dev/null || die "${t} missing -- see the dependency comment above"
  done
  # Headers are probed by compiling, not inferred from package names: only a
  # compile knows whether the header is actually reachable on this host.
  for h in Python.h openssl/engine.h gnutls/gnutls.h; do
    _inc=""
    [ "$h" = "Python.h" ] && _inc="$(python3-config --includes 2>/dev/null || true)"
    # shellcheck disable=SC2086
    echo "#include <$h>" | cc ${_inc} -fsyntax-only -x c - 2>/dev/null \
      || die "header <$h> not found -- see the dependency comment above"
  done
  make "${BOOTCHAIN_BOARD}" || die "boot chain build failed"
  # Existence and size alone do not prove the image carries the source BL31: a
  # Makefile target that uses the awbin blob would still build the source
  # bl31.bin as a side effect.
  # So also assert the Makefile line itself, and that the version string in the
  # image is the upstream TF-A build (source), not v2.5 (blob).
  grep -qxF $'\t$(UMAKE) BL31=../atf/build/sun60i_a733/release/bl31.bin SUNXI_LIBDRAM=../awbin/a733/ddr.bin' \
    "${dir}/.github/local/Makefile.local" \
    || die "Makefile.local no longer builds the A7S with the source BL31 and ddr.bin alone -- overlay regression?"
  local cfg_u="${dir}/src/.config"
  [ -s "${cfg_u}" ] || die "no ${cfg_u} after the build"
  # The source BL31 got built and has the size we expect. A regression that
  # silently fell back to the awbin blob would otherwise ship a 115 677 B BL31
  # with no signal. SRAM A2 BL31 slot is 0x62000..0x70000 = 57 344 B; the
  # release build (LTO) is about 37 KiB.
  local src_bl31="${dir}/atf/build/sun60i_a733/release/bl31.bin"
  [ -s "${src_bl31}" ] \
    || die "source BL31 not built at ${src_bl31} -- Makefile.local overlay didn't take?"
  local src_bl31_size; src_bl31_size="$(stat -c%s "${src_bl31}")"
  [ "${src_bl31_size}" -gt 4096 ] && [ "${src_bl31_size}" -lt 57344 ] \
    || die "source BL31 is ${src_bl31_size} B -- outside the expected range (4 KiB floor, 56 KiB SRAM A2 ceiling); will not boot"
  local src_bl31_ver
  src_bl31_ver="$(grep -a -m1 -o 'v[0-9]\.[0-9]\+\.[0-9]\+\((release)\|(debug)\):[0-9a-f]\+' "${src_bl31}" 2>/dev/null | tr -d '\0')" \
    || src_bl31_ver="<no TF-A version string>"
  log "source BL31 verified: ${src_bl31_size} B, ${src_bl31_ver}"
  local img="${dir}/out/${BOOTCHAIN_BOARD}/u-boot-sunxi-with-spl.bin"
  [ -s "${img}" ] || die "boot chain build produced no ${img}"
  local spltool="${ROOT_DIR}/scripts/lib/sunxi-spl-image.py"
  # The image carries the same BL31 version (not the awbin blob's v2.5). The
  # full TF-A X.Y.Z(release|debug):hash format: the image also carries U-Boot
  # strings like "v2.0Network" that a looser pattern would match first.
  local img_bl31_ver
  img_bl31_ver="$(grep -a -m1 -o 'v[0-9]\.[0-9]\+\.[0-9]\+\((release)\|(debug)\):[0-9a-f]\+' "${img}" 2>/dev/null | tr -d '\0')" \
    || img_bl31_ver="<no TF-A version string>"
  [ "${img_bl31_ver}" = "${src_bl31_ver}" ] \
    || die "u-boot-sunxi-with-spl.bin BL31 version (${img_bl31_ver}) != source BL31 version (${src_bl31_ver}) -- wrong BL31 shipped"
  log "u-boot-sunxi-with-spl.bin BL31 version matches source: ${img_bl31_ver}"
  # The FIT: U-Boot, BL31 and the device tree, nothing else; BL31 is the
  # firmware the SPL enters. sunxi-u-boot.dtsi adds an image "scp" whenever
  # SUNXI_SCP_BASE is set; setting it for the A733 would bring the firmware
  # back without a sign.
  local lay
  lay="$(python3 "${spltool}" layout "${img}")" || die "cannot read the layout of ${img} (reason above)"
  sed 's/^/        /' <<<"${lay}"
  local images
  images="$(sed -n 's/^image \([^ ]*\) .*/\1/p' <<<"${lay}" | sort | tr '\n' ' ')"
  [ "${images}" = "atf fdt-1 uboot " ] \
    || die "the FIT carries the images '${images}', expected 'atf fdt-1 uboot ' -- an SCP image or another one is back"
  ! grep -aqF 'SCP firmware' "${img}" \
    || die "u-boot-sunxi-with-spl.bin carries an 'SCP firmware' image"
  grep -qx 'config config-1 default=1 firmware=atf loadables=uboot fdt=fdt-1' <<<"${lay}" \
    || die "the FIT's default configuration is not firmware=atf loadables=uboot fdt=fdt-1: $(grep '^config ' <<<"${lay}" | tr '\n' ';')"
  log "FIT: U-Boot, BL31 and the device tree, BL31 entered first, no SCP image"
  # BL31 placement, both sides. TF-A links BL31 at BL31_BASE
  # (SUNXI_SRAM_A2_BASE + SUNXI_SRAM_A2_BL31_OFFSET in
  # `allwinner-a733-add-initial-support`); U-Boot loads it at
  # CONFIG_SUNXI_BL31_BASE (`sunxi-a733-bl31-in-sram-without-scp`), the load
  # and entry address of the FIT image "atf". All three must be one address.
  local bl31_elf_entry bl31_cfg fit_atf_load fit_atf_entry
  bl31_elf_entry="$("${tc}readelf" -h "${dir}/atf/build/sun60i_a733/release/bl31/bl31.elf" | sed -n 's/^ *Entry point address: *\(0x[0-9a-f]*\)$/\1/p')"
  bl31_cfg="$(kconfig_value "${cfg_u}" SUNXI_BL31_BASE)"
  fit_atf_load="$(sed -n 's/^image atf .* load=\(0x[0-9a-f]*\) .*/\1/p' <<<"${lay}")"
  fit_atf_entry="$(sed -n 's/^image atf .* entry=\(0x[0-9a-f]*\) .*/\1/p' <<<"${lay}")"
  log "BL31 address: TF-A bl31.elf entry ${bl31_elf_entry}, U-Boot CONFIG_SUNXI_BL31_BASE ${bl31_cfg}, FIT atf load ${fit_atf_load} entry ${fit_atf_entry}"
  [ -n "${bl31_elf_entry}" ] && [ $(( bl31_elf_entry )) = $(( bl31_cfg )) ] \
    && [ $(( fit_atf_load )) = $(( bl31_cfg )) ] && [ $(( fit_atf_entry )) = $(( bl31_cfg )) ] \
    || die "BL31 is linked at ${bl31_elf_entry:-?} but U-Boot loads it at ${bl31_cfg} (FIT load ${fit_atf_load:-?}, entry ${fit_atf_entry:-?})"
  [ "$(kconfig_value "${cfg_u}" SUNXI_SCP_BASE)" = 0x0 ] \
    || die "CONFIG_SUNXI_SCP_BASE is $(kconfig_value "${cfg_u}" SUNXI_SCP_BASE), not 0x0"
  # Loading BL31 must not overwrite the SPL that does the loading. The SPL
  # runs from SRAM; the only part of it no longer in use when the FIT is
  # loaded is the copy of the DRAM blob inside the image (the boot hook has
  # moved it to SUNXI_LIBDRAM_BASE) and the early stack below SPL_STACK, which
  # the SPL leaves for DRAM before it loads anything. The bytes BL31 occupies
  # while the SPL still runs, [BL31_BASE, BL31_BASE + size of bl31.bin), must
  # lie inside the blob's copy and above SPL_STACK (below it sit gd and the
  # early malloc arena, still in use).
  local spl_elf="${dir}/src/spl/u-boot-spl" spl_syms blob_lo blob_hi spl_stack
  spl_syms="$("${tc}nm" "${spl_elf}")" || die "nm failed on ${spl_elf}"
  blob_lo="0x$(sed -n 's/^\([0-9a-f]*\) . sunxi_libdram_blob_start$/\1/p' <<<"${spl_syms}")"
  blob_hi="0x$(sed -n 's/^\([0-9a-f]*\) . sunxi_libdram_blob_end$/\1/p' <<<"${spl_syms}")"
  spl_stack="$(kconfig_value "${cfg_u}" SPL_STACK)"
  [ "${blob_lo}" != 0x ] && [ "${blob_hi}" != 0x ] || die "no sunxi_libdram_blob_start/_end in ${spl_elf}"
  log "SPL: text $(kconfig_value "${cfg_u}" SPL_TEXT_BASE), DRAM blob copy ${blob_lo}-${blob_hi}, SPL_STACK ${spl_stack}, SUNXI_LIBDRAM_BASE $(kconfig_value "${cfg_u}" SUNXI_LIBDRAM_BASE); BL31 written to ${bl31_cfg}-$(printf '%#x' $(( bl31_cfg + src_bl31_size )))"
  [ $(( bl31_cfg )) -ge $(( blob_lo )) ] && [ $(( bl31_cfg + src_bl31_size )) -le $(( blob_hi )) ] \
    && [ $(( bl31_cfg )) -ge $(( spl_stack )) ] \
    || die "BL31 at ${bl31_cfg} (+${src_bl31_size} B) is not inside the SPL's spent DRAM blob copy ${blob_lo}-${blob_hi} above SPL_STACK ${spl_stack} -- loading it would overwrite the running SPL"
  log "BL31 placement: the SPL loads it over its own spent DRAM blob copy, nothing in use"
  # The SPL finds the FIT at max(SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR, eGON
  # length / 512) sectors after its own start (board_spl_mmc_get_uboot_raw_sector);
  # binman put it at fit_offset. Both must be the same
  # (`sunxi-cubie-a7s-u-boot-where-binman-puts-it`).
  local spl_len fit_off raw seek
  spl_len="$(sed -n 's/^spl_length=//p' <<<"${lay}")"
  fit_off="$(sed -n 's/^fit_offset=//p' <<<"${lay}")"
  raw="$(kconfig_value "${cfg_u}" SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR)"
  seek=$(( raw * 512 )); [ $(( spl_len )) -le "${seek}" ] || seek=$(( spl_len ))
  [ "${seek}" = $(( fit_off )) ] \
    || die "the SPL (eGON length ${spl_len}, SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR ${raw}) looks for the FIT at $(printf '%#x' "${seek}"), binman put it at ${fit_off}"
  log "SPL ${spl_len} B (eGON length), looks for the FIT at $(printf '%#x' "${seek}") = where binman put it"
  # The DRAM blob inside the SPL is the pinned awbin/a733/ddr.bin, unchanged
  # and once.
  local blob_at
  blob_at="$(python3 "${spltool}" find "${img}" "${dir}/awbin/a733/ddr.bin" | tr '\n' ' ')"
  [ "$(wc -w <<<"${blob_at}")" = 1 ] && [ $(( ${blob_at% } )) -lt $(( spl_len )) ] \
    || die "awbin/a733/ddr.bin is in u-boot-sunxi-with-spl.bin at '${blob_at}', expected once inside the SPL"
  log "the SPL carries awbin/a733/ddr.bin unchanged at offset ${blob_at% }"
  # The RNG for EFI_RNG_PROTOCOL: U-Boot has to carry the driver, or Linux
  # boots without a KASLR seed again and nothing here would say so.
  grep -aqF 'sun60i-ce-rng' "${img}" \
    || die "u-boot-sunxi-with-spl.bin has no sun60i-ce-rng driver -- RNG_SUN60I_CE off?"
  log "U-Boot carries the crypto engine RNG (EFI_RNG_PROTOCOL)"
  # No ARISC start (`sunxi-cubie-a7s-no-arisc-start`): the command would edit
  # the kernel's device tree and make an SMC this BL31 does not implement.
  [ "$(kconfig_value "${cfg_u}" CMD_SUNXI_BOOT_ARISC)" = n ] && ! grep -aqF 'sunxi_boot_arisc' "${img}" \
    || die "U-Boot carries sunxi_boot_arisc (CONFIG_CMD_SUNXI_BOOT_ARISC=$(kconfig_value "${cfg_u}" CMD_SUNXI_BOOT_ARISC))"
  log "no sunxi_boot_arisc in U-Boot"
  # The resolved configuration of what the patches decide, as the build used
  # it: printed, and every value asserted.
  local kv k want got bad=""
  for kv in SYSRESET_PSCI=y WATCHDOG_AUTOSTART=y WDT_SUNXI=y CMD_WDT=y BOOTCOUNT_LIMIT=y BOOTCOUNT_BOOTLIMIT=3 \
            SYS_BOOTCOUNT_ADDR=0x0709011C DM_RNG=y RNG_SUN60I_CE=y PCI=y PCIE_SUNXI=y NVME_PCI=y CMD_NVME=y CMD_PCI=y \
            AHCI=n SCSI=n UFS=n SPL_UFS_SUPPORT=n SPL_SPI_SUNXI=n SPI_FLASH=n MTD=n CMD_SUNXI_BOOT_ARISC=n \
            SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=0x250 SUNXI_BL31_BASE=0x00062000 SUNXI_SCP_BASE=0x0; do
    k="${kv%%=*}" want="${kv#*=}" got="$(kconfig_value "${cfg_u}" "${k}")"
    printf '        CONFIG_%s=%s\n' "${k}" "${got}"
    case "${want}" in
      0x*) [ "${got#0x}" != "${got}" ] && [ $(( got )) = $(( want )) ] ;;
      *) [ "${got}" = "${want}" ] ;;
    esac || bad="${bad} CONFIG_${k}=${got}(want ${want})"
  done
  [ -z "${bad}" ] || die "U-Boot's resolved configuration differs from what patches/u-boot decide:${bad}"
  log "U-Boot configuration: as patches/u-boot decide"
  # The memory map as this build has it (printed only; docs/boot-chain.md).
  log "memory map: $(for k in SUNXI_SRAM_ADDRESS SPL_TEXT_BASE SPL_MAX_SIZE SPL_STACK SUNXI_LIBDRAM_BASE SPL_LOAD_FIT_ADDRESS SPL_STACK_R_ADDR SPL_BSS_START_ADDR TEXT_BASE SYS_MALLOC_F_LEN; do printf '%s=%s ' "${k}" "$(kconfig_value "${cfg_u}" "${k}")"; done)"
  # The boot order: card or eMMC first (mmc_auto), then the drive (nvme0), so
  # a stale system on the drive never outranks a freshly written card; no
  # scsi0 (the A733 has no SATA). nvme0's boot runs `pci enum` before
  # `nvme scan`, so the scan finds the drive.
  local targets nvme_boot nvme_init pci_enum bootcmd
  targets="$(python3 "${spltool}" env "${img}" boot_targets)" || die "no boot_targets in U-Boot's default environment"
  nvme_boot="$(python3 "${spltool}" env "${img}" nvme_boot)" || die "no nvme_boot in U-Boot's default environment"
  nvme_init="$(python3 "${spltool}" env "${img}" nvme_init)" || die "no nvme_init in U-Boot's default environment"
  pci_enum="$(python3 "${spltool}" env "${img}" boot_pci_enum)" || die "no boot_pci_enum in U-Boot's default environment"
  bootcmd="$(python3 "${spltool}" env "${img}" bootcmd)" || die "no bootcmd in U-Boot's default environment"
  log "boot_targets=${targets}"
  log "bootcmd=${bootcmd}; boot_pci_enum=${pci_enum}; nvme_boot=${nvme_boot%%if *}...; nvme_init=${nvme_init}"
  case " ${targets} " in
    *" mmc_auto nvme0 "*|*" mmc_auto "*" nvme0 "*) ;;
    *) die "boot_targets '${targets}' does not list nvme0 after mmc_auto" ;;
  esac
  case " ${targets} " in *" scsi0 "*) die "boot_targets '${targets}' lists scsi0" ;; esac
  [ "${pci_enum}" = "pci enum" ] && [ "${nvme_boot#run boot_pci_enum; run nvme_init; }" != "${nvme_boot}" ] \
    && [ "${nvme_init#*nvme scan}" != "${nvme_init}" ] \
    || die "nvme0 does not boot through 'pci enum' + 'nvme scan' (nvme_boot=${nvme_boot}, nvme_init=${nvme_init}, boot_pci_enum=${pci_enum})"
  log "boot order: nvme0 after mmc_auto, no scsi0; nvme0 runs pci enum + nvme scan"
  # Boot-disk safe mode (`sunxi-cubie-a7s-boot-disk-safe-mode`): altbootcmd
  # runs the normal scan with a boot_extlinux that prefers
  # extlinux-fallback.conf, so the safe mode comes from the disk of the normal
  # boot. Compared whole: a changed quote or an added setenv of boot_targets or
  # boot_syslinux_conf boots another disk or nothing.
  local altboot altboot_want
  altboot_want="setenv boot_extlinux 'if test -e \${devtype} \${devnum}:\${distro_bootpart} \${prefix}extlinux/extlinux-fallback.conf; then echo Safe mode: \${devtype} \${devnum}:\${distro_bootpart} \${prefix}extlinux/extlinux-fallback.conf; sysboot \${devtype} \${devnum}:\${distro_bootpart} any \${scriptaddr} \${prefix}extlinux/extlinux-fallback.conf; fi; sysboot \${devtype} \${devnum}:\${distro_bootpart} any \${scriptaddr} \${prefix}\${boot_syslinux_conf}'; run distro_bootcmd; env default -f boot_extlinux"
  altboot="$(python3 "${spltool}" env "${img}" altbootcmd)" || die "no altbootcmd in U-Boot's default environment"
  [ "${altboot}" = "${altboot_want}" ] \
    || die "altbootcmd is not the boot-disk safe mode: ${altboot}"
  log "safe mode: altbootcmd boots extlinux-fallback.conf from the disk of the normal boot"
  # The epoch has to be IN the file, not merely exported. Every U-Boot banner
  # (SPL and U-Boot), every TF-A `Built :` string and the FIT root `timestamp`
  # must read the pinned epoch, and each kind must be found at least once, so
  # a changed banner format fails here and does not pass as "nothing to check".
  python3 "${spltool}" epoch "${img}" "${SOURCE_DATE_EPOCH}" \
    || die "u-boot-sunxi-with-spl.bin does not carry the pinned SOURCE_DATE_EPOCH everywhere (see above): its build time is not reproducible"
  log "u-boot-sunxi-with-spl.bin carries the pinned SOURCE_DATE_EPOCH ${SOURCE_DATE_EPOCH} in every banner and FIT timestamp"
  # Which objects BL31 links, read from the link map of this bl31.elf: the
  # linker lists every input file as a LOAD line. A search of the build
  # directory cannot tell an input of this link from an object an earlier build
  # left there, and with link-time optimisation (the GCC release default) the C
  # functions of these files are inlined and leave no symbol to look for.
  #
  # Native PSCI CPU_SUSPEND, asserted against platform.mk in both directions:
  # size cannot tell an armed build from a built-out one (the added text fits
  # inside existing page padding), the version banner names TF-A, not our flags.
  # allwinner-common.mk adds sunxi_cpu_suspend.c only under
  # SUNXI_PSCI_NATIVE_SUSPEND=1, so the object is linked iff the feature is in.
  local bl31_map="${dir}/atf/build/sun60i_a733/release/bl31/bl31.map" bl31_objs
  bl31_objs="$(sed -n 's|^LOAD .*/\([^/]*\.o\)$|\1|p' "${bl31_map}" | sort -u)"
  [ -n "${bl31_objs}" ] \
    || die "no LOAD lines in ${bl31_map} -- cannot tell which objects BL31 links"
  local susp_want susp_obj=""
  susp_want="$(sed -n 's/^[[:space:]]*SUNXI_PSCI_NATIVE_SUSPEND[[:space:]]*:\{0,1\}=[[:space:]]*\([01]\).*/\1/p' \
    "${dir}/atf/plat/allwinner/sun60i_a733/platform.mk" | tail -1)"
  [ -n "${susp_want}" ] \
    || die "cannot read SUNXI_PSCI_NATIVE_SUSPEND from the A733 platform.mk -- overlay changed shape?"
  ! grep -qx 'sunxi_cpu_suspend.o' <<<"${bl31_objs}" || susp_obj=sunxi_cpu_suspend.o
  if [ "${susp_want}" = 1 ]; then
    [ -n "${susp_obj}" ] \
      || die "platform.mk arms SUNXI_PSCI_NATIVE_SUSPEND=1 but bl31.elf does not link sunxi_cpu_suspend.o -- the feature silently did not compile in"
    # The per-core reset check (AA64nAA32 + RVBAR read back) prints its mask in
    # the arming summary; without it a core 0 that resets into the BROM would be
    # armed again.
    grep -aqF 'reset to BL31 0x' "${src_bl31}" \
      || die "native suspend armed but bl31.bin has no 'reset to BL31' summary -- atf patch allwinner-a733-native-psci-cpu-suspend did not take"
    log "deep idle: ARMED (platform.mk=1, sunxi_cpu_suspend.o linked)"
  else
    [ -z "${susp_obj}" ] \
      || die "platform.mk sets SUNXI_PSCI_NATIVE_SUSPEND=0 but bl31.elf links ${susp_obj} -- the build-out did not take"
    log "deep idle: built out (platform.mk=0, sunxi_cpu_suspend.o not linked)"
  fi
  # CPU_BACK_PLL enable: the kernel parks the CPU clusters on this PLL during a
  # relock and falls back to the 26 MHz DCXO when it is off, so a chain that
  # silently lost the enable still boots and only runs slower. The object in the
  # link map proves it is linked, the log string that the packed BL31 is that
  # build.
  grep -qx 'sunxi_cpu_back_pll.o' <<<"${bl31_objs}" \
    || die "bl31.elf does not link sunxi_cpu_back_pll.o -- atf patch allwinner-a733-enable-cpu-back-pll did not take"
  grep -aqF 'BL31: CPU_BACK_PLL' "${img}" \
    || die "u-boot-sunxi-with-spl.bin carries no 'BL31: CPU_BACK_PLL' string -- the BL31 in its FIT lacks the back-PLL enable"
  log "CPU_BACK_PLL enable: in BL31 and in u-boot-sunxi-with-spl.bin"
  # SCPI PSCI path built out: mainline's or1k/A31-msgbox SCPI code must not reach
  # an A733 BL31, where its SCP release would write an undocumented CPUIDLE
  # register.
  local scpi_obj
  scpi_obj="$(grep -x -m1 -e 'sunxi_scpi_pm.o' -e 'sunxi_msgbox.o' -e 'css_scpi.o' <<<"${bl31_objs}" || true)"
  [ -z "${scpi_obj}" ] \
    || die "bl31.elf links ${scpi_obj} -- atf patch allwinner-a733-add-initial-support (SUNXI_PSCI_USE_SCPI := 0) did not take (SCPI path built in)"
  log "SCPI PSCI path: built out"
  # Cortex-A76 errata 1946160 and 2743102. A flag that silently stopped taking
  # would change nothing a boot can see, so assert the linked BL31. The errata
  # framework inlines reset-time workarounds into cortex_a76_reset_func and
  # leaves only an erratum_cortex_a76_<id>_skip_reset label, which it emits for a
  # chosen erratum only; runtime workarounds keep their own
  # erratum_cortex_a76_<id>_wa function. 1946160 is a reset workaround, 2743102 a
  # runtime one, and cortex_a76_core_pwr_dwn must read the revision itself --
  # without that the 2743102 check takes x10 as found.
  # Tool output goes into a variable first: `nm f | grep -q x` fails under
  # pipefail exactly when x is found early and grep closes the pipe (SIGPIPE).
  local bl31_elf="${dir}/atf/build/sun60i_a733/release/bl31/bl31.elf" syms pwrdn
  syms="$("${tc}nm" "${bl31_elf}")" || die "nm failed on ${bl31_elf}"
  grep -q " erratum_cortex_a76_1946160_skip_reset$" <<<"${syms}" \
    || die "bl31.elf has no erratum_cortex_a76_1946160_skip_reset -- ERRATA_A76_1946160 did not take"
  grep -q " erratum_cortex_a76_2743102_wa$" <<<"${syms}" \
    || die "bl31.elf has no erratum_cortex_a76_2743102_wa -- ERRATA_A76_2743102 did not take"
  pwrdn="$("${tc}objdump" -d "${bl31_elf}" | sed -n '/<cortex_a76_core_pwr_dwn>:/,/ret/p')" \
    || die "objdump failed on ${bl31_elf}"
  grep -q '<cpu_get_rev_var>' <<<"${pwrdn}" \
    || die "cortex_a76_core_pwr_dwn does not call cpu_get_rev_var -- the 2743102 revision check is gone from the TF-A base"
  log "Cortex-A76 errata 1946160 + 2743102: in BL31, 2743102 with its own revision check"
  # The power-down WFI of CPU_SUSPEND. TF-A master executes one WFI after the
  # CPU's power-down hook; should that WFI return, PSCI calls the hook again and
  # panics unless the hook acknowledges a powerdown abandon. Cortex-A55 and
  # Cortex-A76 cannot abandon: once CPUPWRCTLR_EL1.CORE_PWRDN_EN is 1, a WFI
  # masks every interrupt and wake-up event and only a reset ends it (Cortex-A55
  # TRM 100442_0200_03_en 2.4.8; Cortex-A76 TRM 100798_0401_01_en 5.9). That
  # keeps the panic unreachable exactly as long as the hook PSCI calls on each
  # core sets CORE_PWRDN_EN and synchronises it before the WFI. So assert it in
  # the linked image: the cpu_ops entry of each MIDR has its core's hook in both
  # power-down slots (scripts/lib/aarch64-cpu-ops.py), and the hook sets bit 0 of
  # CPUPWRCTLR_EL1 (S3_0_C15_C2_7) by mrs/orr #0x1/msr -- no toggle, no other
  # write of the register -- and issues an ISB after it, before it returns.
  local ops core midr hook
  ops="$(python3 "${ROOT_DIR}/scripts/lib/aarch64-cpu-ops.py" "${tc}" "${bl31_elf}")" \
    || die "cannot read the cpu_ops table of ${bl31_elf} (reason above)"
  for core in cortex_a55:0x410fd050 cortex_a76:0x410fd0b0; do
    midr="${core#*:}"; core="${core%%:*}"
    grep -qx "${midr} ${core}_core_pwr_dwn ${core}_core_pwr_dwn" <<<"${ops}" \
      || die "the cpu_ops of MIDR ${midr} do not point both power-down slots at ${core}_core_pwr_dwn; cpu_ops: $(tr '\n' ';' <<<"${ops}")"
    hook="$("${tc}objdump" -d "${bl31_elf}" | sed -n "/<${core}_core_pwr_dwn>:/,/\tret/p")" \
      || die "objdump failed on ${bl31_elf}"
    awk '
      { l[NR] = $0 }
      /msr[ \t]+s3_0_c15_c2_7,/ { w++ }
      END {
        for (i = 2; i < NR; i++)
          if (l[i-1] ~ /mrs[ \t]+x[0-9]+, s3_0_c15_c2_7$/ && l[i] ~ /orr[ \t]+x[0-9]+, x[0-9]+, #0x1$/ && l[i+1] ~ /msr[ \t]+s3_0_c15_c2_7, x[0-9]+$/) {
            for (j = i + 2; j < NR; j++) if (l[j] ~ /\tisb/) isb = 1
            exit !(isb && w == 1 && l[NR] ~ /\tret/)
          }
        exit 1 }' <<<"${hook}" \
      || die "${core}_core_pwr_dwn does not set CPUPWRCTLR_EL1.CORE_PWRDN_EN (mrs/orr #0x1/msr s3_0_c15_c2_7, then isb, then ret, no other write) -- a power-down WFI could return into PSCI's abandon path, which panics on this core"
  done
  log "Cortex-A55 / Cortex-A76 power-down: cpu_ops of both MIDRs carry the core hook, which sets CORE_PWRDN_EN and ISBs before the WFI (TRM: no WFI return)"
  # Upstream's allwinner-common.mk turns the CPU CVE workarounds off for every
  # Allwinner SoC, which does not hold for the Cortex-A76 cores; allwinner-cortex-a53-opt-outs-in-the-a53-makefile moves
  # them to allwinner-common-a53.mk, which the A733 does not include. If that
  # patch ever stops taking, nothing a boot shows would change -- the BL31 would
  # simply lose Spectre-BHB and SSB. So assert the CVE-2022-23960 vector table,
  # the eight settings as the build used them (config.h holds every define the
  # build passed: the TF-A defaults, none of the A53 values), the end of
  # cortex_a76_reset_func (point VBAR_EL3 at the CVE-2022-23960 vectors), and the
  # version banner: the pinned TF-A master (overlay/apply.sh ATF_BASE), so a
  # chain on another base cannot pass as this one.
  local rst
  grep -q " cortex_a76_wa_cve_vbar$" <<<"${syms}" \
    || die "bl31.elf has no cortex_a76_wa_cve_vbar -- the A76 CVE workarounds are off (atf patch allwinner-cortex-a53-opt-outs-in-the-a53-makefile did not take)"
  local cfg="${dir}/atf/build/sun60i_a733/release/config.h" d
  for d in ENABLE_SPE_FOR_NS:2 ENABLE_SVE_FOR_NS:2 ENABLE_FEAT_MPAM:2 WORKAROUND_CVE_2017_5715:1 \
           WORKAROUND_CVE_2018_3639:1 WORKAROUND_CVE_2022_23960:1 WORKAROUND_CVE_2024_7881:1 WORKAROUND_CVE_2024_5660:1; do
    grep -qx "#define ${d%%:*} ${d#*:}" "${cfg}" \
      || die "the A733 BL31 was built with $(grep -m1 "^#define ${d%%:*} " "${cfg}" || echo "no ${d%%:*}"), not ${d#*:} -- the Cortex-A53 opt-outs reached the A733 (atf patch allwinner-cortex-a53-opt-outs-in-the-a53-makefile)"
  done
  rst="$("${tc}objdump" -d "${bl31_elf}" | sed -n '/<cortex_a76_reset_func>:/,/ret/p')"
  grep -q 'msr[[:space:]]*vbar_el3,' <<<"${rst}" \
    || die "cortex_a76_reset_func does not install the CVE-2022-23960 vectors (no msr vbar_el3)"
  local tfa_base tfa_hash
  tfa_base="$(sed -n 's/^ATF_BASE="\([0-9a-f]\{40\}\)".*/\1/p' "${ROOT_DIR}/overlay/apply.sh")"
  [ -n "${tfa_base}" ] || die "cannot read ATF_BASE from overlay/apply.sh"
  tfa_hash="${src_bl31_ver#v2.15.0(release):}"
  [ "${tfa_hash}" != "${src_bl31_ver}" ] && [ "${#tfa_hash}" -ge 7 ] && [ "${tfa_base#"${tfa_hash}"}" != "${tfa_base}" ] \
    || die "bl31.bin is not built from TF-A master ${tfa_base} (banner: ${src_bl31_ver}) -- the move in overlay/apply.sh did not take"
  log "TF-A base master ${tfa_base} (v2.15.0); A76 reset installs the CVE-2022-23960 vectors"
  # Cortex-A76 errata 2356586 and 3888013, reset-time bits in CPUACTLR2_EL1
  # (S3_0_C15_C1_1) -- bit 0 and bit 22 (0x400000) -- asserted against
  # platform.mk in both directions. Both are required: 3888013 costs the A76
  # about half its Non-cacheable read bandwidth, and the workaround is enabled.
  # It has its own enabling patch; a build without it must set
  # A733_BUILD_WITHOUT_ERRATUM_3888013=1 and then warns that the workaround is
  # missing. Without the variable a missing 3888013 fails the build like a
  # missing 2356586.
  local a76mk="${dir}/atf/plat/allwinner/sun60i_a733/platform.mk" e want bit
  for e in 2356586:0x1 3888013:0x400000; do
    bit="${e#*:}"; e="${e%%:*}"
    want="$(sed -n "s/^[[:space:]]*ERRATA_A76_${e}[[:space:]]*:\{0,1\}=[[:space:]]*\([01]\).*/\1/p" "${a76mk}" | tail -1)"
    if [ "${want}" = 1 ]; then
      grep -q " erratum_cortex_a76_${e}_skip_reset$" <<<"${syms}" \
        || die "platform.mk sets ERRATA_A76_${e} but bl31.elf has no erratum_cortex_a76_${e}_skip_reset"
      # The exact read-modify-write, three consecutive instructions, so an
      # unrelated orr of the same immediate elsewhere in the function cannot pass.
      awk -v b="#${bit}" '
        { l[NR] = $0 }
        END { for (i = 2; i < NR; i++)
                if (l[i-1] ~ /mrs[ \t]+x[0-9]+, s3_0_c15_c1_1$/ && index(l[i], "orr") && substr(l[i], length(l[i]) - length(b) + 1) == b && l[i+1] ~ /msr[ \t]+s3_0_c15_c1_1, x[0-9]+$/) exit 0
              exit 1 }' <<<"${rst}" \
        || die "cortex_a76_reset_func has no mrs/orr ${bit}/msr on CPUACTLR2_EL1 (s3_0_c15_c1_1) for erratum ${e}"
      log "Cortex-A76 erratum ${e}: in the A76 reset, sets ${bit} in CPUACTLR2_EL1"
    else
      ! grep -q " erratum_cortex_a76_${e}_skip_reset$" <<<"${syms}" \
        || die "platform.mk does not set ERRATA_A76_${e} but bl31.elf has erratum_cortex_a76_${e}_skip_reset"
      if [ "${e}" = 3888013 ] && [ "${A733_BUILD_WITHOUT_ERRATUM_3888013:-0}" = 1 ]; then
        echo "::warning:: this boot chain is built WITHOUT the Cortex-A76 erratum 3888013 workaround, on purpose (A733_BUILD_WITHOUT_ERRATUM_3888013=1)."
      elif [ "${e}" = 3888013 ]; then
        die "platform.mk does not set ERRATA_A76_3888013 -- atf patch allwinner-a733-apply-a76-erratum-3888013 did not take. A build without it must set A733_BUILD_WITHOUT_ERRATUM_3888013=1"
      else
        die "platform.mk does not set ERRATA_A76_${e} -- atf patch allwinner-a733-apply-a76-errata did not take"
      fi
    fi
  done
  # CVE-2025-10263 (Cortex-A76 erratum 4193800): after an Inner/Outer Shareable
  # TLBI + DSB, the code must issue one more TLBI + DSB. TF-A puts that into the
  # xlat library only, which the A733 builds without PLAT_XLAT_TABLES_DYNAMIC,
  # so the linked BL31 has no broadcast TLBI at all. What must hold is the
  # property: every broadcast TLBI in bl31.elf sits in the workaround itself or
  # in xlat_arch_tlbi_va, whose sync function then has to call it. A broadcast
  # TLBI anywhere else fails the build, so a patch that adds one has to answer
  # for the erratum.
  local cve_want tlbi_fns f
  cve_want="$(sed -n 's/^[[:space:]]*WORKAROUND_CVE_2025_10263[[:space:]]*:\{0,1\}=[[:space:]]*\([01]\).*/\1/p' "${a76mk}" | tail -1)"
  [ "${cve_want}" = 1 ] \
    || die "platform.mk does not set WORKAROUND_CVE_2025_10263 -- atf patch allwinner-a733-apply-a76-errata did not take"
  tlbi_fns="$("${tc}objdump" -d "${bl31_elf}" \
    | awk '/^[0-9a-f]+ <.*>:$/ {f = $2} /\ttlbi\t[a-z0-9]*(is|os)([,[:space:]]|$)/ {print f}' | sort -u)"
  for f in ${tlbi_fns}; do
    case "${f}" in
      "<apply_cve_2025_10263_wa>:") ;;
      "<xlat_arch_tlbi_va>:")
        "${tc}objdump" -d "${bl31_elf}" | sed -n '/<xlat_arch_tlbi_va_sync>:/,/ret/p' \
          | grep -q '<apply_cve_2025_10263_wa>' \
          || die "xlat_arch_tlbi_va issues a broadcast TLBI but xlat_arch_tlbi_va_sync does not call apply_cve_2025_10263_wa (CVE-2025-10263)" ;;
      *) die "${f%:} issues a broadcast TLBI outside the CVE-2025-10263 workaround path -- add the second TLBI + DSB (Cortex-A76 erratum 4193800)" ;;
    esac
  done
  log "CVE-2025-10263: on in platform.mk; broadcast TLBI in: ${tlbi_fns:-none}"
  # The security setup in sunxi_security_setup() (tf-a patches
  # allwinner-a733-security-setup-from-the-um and
  # allwinner-a733-add-initial-support): PRCM_SEC_SWITCH_REG (0x07010290) gets
  # 0x7 set read-modify-write (SUNXI_R_PRCM_SEC_SWITCH_NS in platform.mk, UM
  # V1.00 4.2.5.26); nothing is written to S_PRCM + 0x8 (no register, UM
  # 4.2.4); and the CCU security switch
  # goes to CCU + 0x1F00 = 0x02003F00 (UM 4.1.6.278), not to CCU + 0x0F00 =
  # 0x02002F00, which is SPI0_CLK_REG (4.1.6.160). None of it changes anything a
  # boot shows, so check the linked code itself: scripts/lib/aarch64-mmio-stores.py
  # --anchor finds, in the disassembly of all of our bl31.elf, the one
  # straight-line region that stores to PRCM_SEC_SWITCH_REG and lists every store
  # it makes, address and value followed through the disassembly (`[A]|0x7` = the
  # word at A with 0x7 set, i.e. mmio_setbits_32). The region, not the symbol:
  # with link-time optimisation sunxi_security_setup() is inlined into
  # bl31_main(). It fails if no region or more than one stores there and on any
  # store it cannot resolve, so an unexpected compiler output fails here instead
  # of passing as "no such store". The S_TZMA and S_SPC writes (as in the dlan17
  # TF-A fork this is derived from) are asserted as well, so dropping them has to
  # be a decision.
  local sec_ns sec_st a
  sec_ns="$(sed -n 's/^[[:space:]]*SUNXI_R_PRCM_SEC_SWITCH_NS[[:space:]]*:\{0,1\}=[[:space:]]*\(0x[0-9a-fA-F]*\).*/\1/p' "${a76mk}" | tail -1)"
  [ "${sec_ns}" = 0x7 ] \
    || die "the A733 platform.mk sets SUNXI_R_PRCM_SEC_SWITCH_NS to '${sec_ns}', not 0x7 -- atf patch allwinner-a733-security-setup-from-the-um did not take"
  sec_st="$("${tc}objdump" -d "${bl31_elf}" | python3 "${ROOT_DIR}/scripts/lib/aarch64-mmio-stores.py" --anchor 0x07010290)" \
    || die "cannot list the stores of the code that writes PRCM_SEC_SWITCH_REG in bl31.elf (reason above) -- extend scripts/lib/aarch64-mmio-stores.py or check the code by hand"
  [ "$(grep -c '^0x7010290 ' <<<"${sec_st}" || true)" = 1 ] && grep -qx '0x7010290 \[0x7010290\]|0x7' <<<"${sec_st}" \
    || die "sunxi_security_setup does not set 0x7 in PRCM_SEC_SWITCH_REG (0x07010290) by one read-modify-write; its stores: $(tr '\n' ' ' <<<"${sec_st}")"
  ! grep -q '^0x7010008 ' <<<"${sec_st}" \
    || die "sunxi_security_setup writes S_PRCM + 0x8 (0x07010008), which is no register (UM 4.2.4)"
  grep -qx '0x2003f00 0x7' <<<"${sec_st}" \
    || die "sunxi_security_setup does not write 0x7 to CCMU_SEC_SWITCH_REG (0x02003F00) -- the CCU offset of atf patch allwinner-a733-add-initial-support did not take"
  ! grep -q '^0x2002f00 ' <<<"${sec_st}" \
    || die "sunxi_security_setup writes CCU + 0x0F00 (0x02002F00), SPI0_CLK_REG on the A733 (UM 4.1.6.160)"
  for a in 0x7003000:0x0 0x7003004:0x0 0x7003008:0x0 0x7002004:0xffffffff 0x7002014:0xffffffff 0x7002024:0xffffffff; do
    grep -qx "${a%%:*} ${a#*:}" <<<"${sec_st}" \
      || die "sunxi_security_setup no longer writes ${a#*:} to ${a%%:*} (S_TZMA / S_SPC) -- they stay"
  done
  log "security setup: PRCM_SEC_SWITCH_REG |= 0x7, no S_PRCM + 0x8, CCMU_SEC_SWITCH_REG at 0x02003F00 (not SPI0_CLK_REG), S_TZMA / S_SPC set (bl31.elf)"
  # EL3 stacks: contiguous, eight of them; an undersized one overflows silently
  # into the next core's. Check the linked size against the declared one:
  # SUNXI_PLAT_STACK_SIZE per core, 0 = the common default, 0x1000 shared by
  # eight cores.
  local mkf="${dir}/atf/plat/allwinner/sun60i_a733/platform.mk"
  local stk map stk_lo stk_hi stk_want
  stk="$(sed -n 's/^[[:space:]]*SUNXI_PLAT_STACK_SIZE[[:space:]]*:\{0,1\}=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${mkf}" | tail -1)"
  [ -n "${stk}" ] \
    || die "cannot read SUNXI_PLAT_STACK_SIZE from the A733 platform.mk -- overlay changed shape?"
  map="${dir}/atf/build/sun60i_a733/release/bl31/bl31.map"
  stk_lo="$(sed -n 's/^[[:space:]]*0x\([0-9a-f]*\)[[:space:]]*__STACKS_START__ = \..*/\1/p' "${map}" | head -1)"
  stk_hi="$(sed -n 's/^[[:space:]]*0x\([0-9a-f]*\)[[:space:]]*__STACKS_END__ = \..*/\1/p' "${map}" | head -1)"
  [ -n "${stk_lo}" ] && [ -n "${stk_hi}" ] || die "no __STACKS_START__/__STACKS_END__ in ${map}"
  stk_want=$(( stk == 0 ? 0x1000 : stk * 8 ))
  [ $(( 0x${stk_hi} - 0x${stk_lo} )) = "${stk_want}" ] \
    || die "BL31 EL3 stacks are $(( 0x${stk_hi} - 0x${stk_lo} )) B, platform.mk SUNXI_PLAT_STACK_SIZE=${stk} wants ${stk_want} B"
  log "BL31 EL3 stacks: $(( stk_want / 8 )) B per core, 0x${stk_lo}-0x${stk_hi}"
  # Refuse a chain that cannot be placed in front of the first partition: here,
  # at build time, and before the copy, so nothing that does not fit reaches
  # out/bootchain.
  bootchain_layout_check "${img}" \
    || die "the boot chain does not fit the image layout (offsets: scripts/lib/bootchain-layout.sh) -- nothing copied to out/bootchain"
  rm -rf "${OUT_DIR}/bootchain"
  mkdir -p "${OUT_DIR}/bootchain"
  cp "${img}" "${OUT_DIR}/bootchain/"
  # Stamp what this chain is, so it can be told from another one. Content-addressed
  # rather than a timestamp: a git checkout rewrites mtimes.
  {
    echo "upstream=${BOOTCHAIN_COMMIT}"
    echo "submodules=${BOOTCHAIN_SUBMODULES}"
    echo "overlay=$(bootchain_overlay_id)"
    # The build time inside the firmware, pinned to the package commit.
    echo "source_date_epoch=${SOURCE_DATE_EPOCH}"
    # The real time of this build. Only here: the firmware does not carry it,
    # so this is the one artefact of a rebuild that differs.
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "offset_kib=${SPL_OFFSET_KIB}"
    ( cd "${OUT_DIR}/bootchain" && sha256sum u-boot-sunxi-with-spl.bin | sed 's/^\([0-9a-f]*\)  \(.*\)$/sha256_\2=\1/' )
  } > "${OUT_DIR}/bootchain/BOOTCHAIN-ID"
  log "boot chain built -> ${OUT_DIR}/bootchain"
  log "boot chain identity:"
  sed 's/^/        /' "${OUT_DIR}/bootchain/BOOTCHAIN-ID"
  ls -l "${OUT_DIR}/bootchain"
}

main() {
  case "${1:-}" in
    pins)          stage_pins ;;
    fetch)         stage_fetch_bootchain ;;
    apply-overlay) stage_apply_bootchain_overlay ;;
    key)           stage_bootchain_key ;;
    build)         stage_build_bootchain ;;
    all)           stage_fetch_bootchain; stage_build_bootchain ;;
    *) sed -n '/^# Usage/,/^# Needs/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
}

main "$@"
