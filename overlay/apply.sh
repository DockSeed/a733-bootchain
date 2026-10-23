#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: the authors of this repository
#
# Apply the boot-chain overlay to a cloned radxa-pkg/u-boot-dlan17 tree.
# Called by scripts/build.sh (stage `fetch`) after it has put the package and
# its `src` submodule (U-Boot) in place; it fetches upstream TF-A itself.
#
# The package (b1cec0a9) builds one u-boot-sunxi-with-spl.bin: the U-Boot SPL
# initialises DRAM through the vendor blob awbin/a733/ddr.bin (SUNXI_LIBDRAM)
# and loads a FIT with BL31 and U-Boot. Radxa's U-Boot changes are commits in
# `src`; there is no quilt series.
#
# What this does:
#   1. .github/local/Makefile.local: adds a release-build rule for atf and
#      rewrites the radxa-cubie-a7s_build target to build and use
#      atf/build/sun60i_a733/release/bl31.bin instead of the prebuilt
#      awbin/a733/bl31.bin, without scp.bin. SUNXI_LIBDRAM stays.
#   2. Applies patches/u-boot/series to src/ (git apply), among them the
#      BL31 base back in SRAM at 0x62000 and no SCP image in the FIT.
#   3. Puts upstream TF-A at ATF_BASE into atf/ and applies
#      patches/tf-a/series.
#
# Every assumption about the upstream tree's shape is asserted before editing:
# an upstream edit that touches the same lines fails this script loudly
# instead of silently producing a different machine.
#
# Not re-runnable: step 1 refuses a tree it has already rewritten. The fetch
# stage always starts from a fresh tree.
#
# Usage: overlay/apply.sh <path-to-cloned-u-boot-dlan17-tree>
set -euo pipefail

dir="${1:?usage: apply.sh <cloned-tree>}"
overlay_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# The one series reader of this repo (format and what it refuses: its header).
# It is part of the overlay's identity (bootchain_overlay_id in scripts/build.sh).
series_lib="${overlay_dir}/../scripts/lib/series.sh"
[ -f "${series_lib}" ] \
  || { echo "::error:: ${series_lib} missing -- apply.sh runs from a checkout of this repo"; exit 1; }
# shellcheck source=../scripts/lib/series.sh
. "${series_lib}"

[ -d "${dir}/.git" ] \
  || { echo "::error:: ${dir} is not a git checkout (no .git)"; exit 1; }
[ -f "${dir}/.github/local/Makefile.local" ] \
  || { echo "::error:: ${dir}/.github/local/Makefile.local missing"; exit 1; }
# Radxa moved its quilt patches into `src` (1fa5458, "u-boot: migrate quilt
# patches into source"). A quilt series in debian/patches would be applied by
# nobody.
[ ! -e "${dir}/debian/patches" ] \
  || { echo "::error:: ${dir}/debian/patches exists -- the package layout changed; this overlay does not apply a quilt series. Refusing."; exit 1; }
[ -f "${dir}/src/configs/radxa-cubie-a7s_defconfig" ] \
  || { echo "::error:: src/configs/radxa-cubie-a7s_defconfig missing -- src not fetched?"; exit 1; }

# ---------------------------------------------------------------------------
# 1. .github/local/Makefile.local: source BL31, no SCP.
# ---------------------------------------------------------------------------
python3 - "${dir}/.github/local/Makefile.local" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()

# Sanity: the A5E target proves the source-build pattern works; if it changes
# shape, our mirror of it needs a review.
if "BL31=../atf/build/sun55i_a523/debug/bl31.bin" not in t:
    sys.exit("::error:: A5E source-BL31 line missing from Makefile.local -- the package layout changed. Refusing.")

# (a) Add a release-build pattern rule next to the debug one.
DEBUG_RULE = (
    "atf/build/%/debug/bl31.bin:\n"
    "\t$(MAKE) -j$(shell nproc) -C atf CROSS_COMPILE=$(CROSS_COMPILE) PLAT=$* DEBUG=1\n"
)
RELEASE_RULE = (
    "\n"
    "atf/build/%/release/bl31.bin:\n"
    "\t$(MAKE) -j$(shell nproc) -C atf CROSS_COMPILE=$(CROSS_COMPILE) PLAT=$* DEBUG=0\n"
)
if "atf/build/%/release/bl31.bin:" in t:
    sys.exit("::error:: Makefile.local already has a release atf rule -- tree already overlaid? Start from a fresh clone.")
if DEBUG_RULE not in t:
    sys.exit("::error:: debug atf pattern rule not at expected form. Refusing.")
t = t.replace(DEBUG_RULE, DEBUG_RULE + RELEASE_RULE, 1)

# (b) The A7S build: depend on + consume the source BL31; no scp.bin, the
#     E902 is never started on this chain. The DRAM blob stays.
OLD = (
    "radxa-cubie-a7s_build: radxa-cubie-a7s_defconfig awbin/a733/scp.bin\n"
    "\t$(UMAKE) SCP=../awbin/a733/scp.bin BL31=../awbin/a733/bl31.bin SUNXI_LIBDRAM=../awbin/a733/ddr.bin\n"
)
NEW = (
    "radxa-cubie-a7s_build: radxa-cubie-a7s_defconfig "
    "atf/build/sun60i_a733/release/bl31.bin\n"
    "\t$(UMAKE) BL31=../atf/build/sun60i_a733/release/bl31.bin SUNXI_LIBDRAM=../awbin/a733/ddr.bin\n"
)
if OLD not in t:
    sys.exit("::error:: radxa-cubie-a7s_build block not at expected form -- the package layout changed. Refusing.")
t = t.replace(OLD, NEW, 1)

p.write_text(t)
PY

echo "  [overlay] Makefile.local: A7S builds + consumes atf/build/sun60i_a733/release/bl31.bin, no SCP, SUNXI_LIBDRAM=awbin/a733/ddr.bin"

# ---------------------------------------------------------------------------
# 2. Our U-Boot patches, applied to src/ in series order.
#
#    `git apply --check` first, so a patch that does not apply to the pinned
#    src (plus the entries before it) stops the script before it writes.
#    Names must stay flat (no `/`).
#
#    What `sunxi-cubie-a7s-watchdog-autostart` is for: the A733 watchdog
#    hardware, the sunxi_wdt driver and a DT node for it all exist; the
#    watchdog is not started (WATCHDOG_AUTOSTART defaults to n on ARCH_SUNXI
#    in drivers/watchdog/Kconfig and the defconfig sets no WDT option).
#    Enabling them lets U-Boot run the 16s watchdog during
#    its own phase, including at the prompt, and hand it to Linux still
#    running: U-Boot has no stop-before-Linux path. Linux has to feed or stop
#    the watchdog (systemd: RuntimeWatchdogSec); see the patch text for what
#    sunxi_wdt does with a watchdog that is already running.
# ---------------------------------------------------------------------------
series_load "${overlay_dir}/../patches/u-boot" \
  || { echo "::error:: patches/u-boot/series is missing, empty or malformed -- overlay is incomplete"; exit 1; }

src_dir="${dir}/src"
for name in "${SERIES[@]}"; do
  case "${name}" in
    */*) echo "::error:: patches/u-boot/series: '${name}' has a directory; U-Boot patch names must be flat"; exit 1 ;;
  esac
  p="${overlay_dir}/../patches/u-boot/${name}"
  git -C "${src_dir}" apply --check "${p}" \
    || { echo "::error:: u-boot patch ${name} does not apply cleanly to src at $(git -C "${src_dir}" rev-parse HEAD) + the entries before it"; exit 1; }
  git -C "${src_dir}" apply "${p}"
  echo "  [overlay] u-boot ${name} applied"
done

# ---------------------------------------------------------------------------
# 3. TF-A: upstream master at ATF_BASE plus patches/tf-a/series in atf/.
#
#    The base is upstream TF-A master at a pinned commit, not radxa's pin.
#    radxa's `atf` submodule points at the dlan17 fork, TF-A master of
#    2025-01-09 plus the A523/A733 commits. Its pin is asserted from the
#    package tree (a radxa bump still fails loud and gets a look), but the fork
#    is not fetched: atf/ is filled with the pinned upstream commit, fetched by
#    its hash and verified. The A733 support is patches/tf-a/series, rebased
#    onto that commit.
#
#    A patch that does not apply stops the script. The thing being patched is
#    the firmware that powers CPUs down, and a half-applicable patch there is
#    a board that does not boot.
#
#    The atf build is a dependency of radxa-cubie-a7s_build, so it sees the
#    patched tree.
# ---------------------------------------------------------------------------
ATF_PIN="f4c0b0dba78a2d9916154c130979992caa3f3156"  # radxa's submodule pin: dlan17 fork, A733 v2.12 tip
ATF_UPSTREAM="https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git"
ATF_BASE="3d425f4f459820a44d24b23464dbc09d6baab7bb"  # TF-A master, 2026-10-02 (VERSION 2.15.0)
atf_dir="${dir}/atf"
atf_series="${overlay_dir}/../patches/tf-a/series"

[ -f "${atf_series}" ] \
  || { echo "::error:: ${atf_series} missing"; exit 1; }
have_pin="$(git -C "${dir}" ls-tree HEAD atf | awk '$2 == "commit" {print $3}')"
[ "${have_pin}" = "${ATF_PIN}" ] \
  || { echo "::error:: the package pins atf at '${have_pin}', expected radxa's ${ATF_PIN} -- the pinned package does not match the expected layout; re-verify before changing a pin."; exit 1; }
if [ -e "${atf_dir}/.git" ] || [ -n "$(ls -A "${atf_dir}" 2>/dev/null)" ]; then
  echo "::error:: ${atf_dir} is not empty -- the atf submodule was checked out, or the tree is already overlaid. Start from a fresh clone."; exit 1
fi
mkdir -p "${atf_dir}"
git -C "${atf_dir}" init --quiet
git -C "${atf_dir}" fetch --quiet --no-tags --depth 1 "${ATF_UPSTREAM}" "${ATF_BASE}" \
  || { echo "::error:: cannot fetch ${ATF_BASE} from ${ATF_UPSTREAM}"; exit 1; }
got="$(git -C "${atf_dir}" rev-parse 'FETCH_HEAD^{commit}')"
[ "${got}" = "${ATF_BASE}" ] \
  || { echo "::error:: fetching ${ATF_BASE} gave ${got}"; exit 1; }
git -C "${atf_dir}" checkout --quiet --detach "${ATF_BASE}"
[ "$(git -C "${atf_dir}" rev-parse HEAD)" = "${ATF_BASE}" ] \
  || { echo "::error:: atf checkout of ${ATF_BASE} did not take"; exit 1; }
[ -f "${atf_dir}/plat/allwinner/common/allwinner-common.mk" ] \
  || { echo "::error:: ${ATF_BASE} has no plat/allwinner/common/allwinner-common.mk"; exit 1; }
echo "  [overlay] atf: TF-A master ${ATF_BASE} (package pin ${ATF_PIN} not fetched)"

series_load "${overlay_dir}/../patches/tf-a" \
  || { echo "::error:: patches/tf-a/series is malformed"; exit 1; }

for name in "${SERIES[@]}"; do
  src="${overlay_dir}/../patches/tf-a/${name}"
  git -C "${atf_dir}" apply --check "${src}" \
    || { echo "::error:: atf patch ${name} does not apply cleanly to TF-A ${ATF_BASE} + the entries before it"; exit 1; }
  git -C "${atf_dir}" apply "${src}"
  echo "  [overlay] atf ${name} applied"
done

# ---------------------------------------------------------------------------
# 4. Sanity: print the resulting A7S rule so the build log shows what was built.
# ---------------------------------------------------------------------------
echo
echo "  Resulting radxa-cubie-a7s_build rule:"
awk '/^\.PHONY: radxa-cubie-a7s_build$/,/^$/' "${dir}/.github/local/Makefile.local" \
  | sed 's/^/    /'
echo
echo "  BL31 provenance after overlay (A7S: the SOURCE path, not awbin/):"
grep -E 'BL31=' "${dir}/.github/local/Makefile.local" | sed 's/^/    /'
