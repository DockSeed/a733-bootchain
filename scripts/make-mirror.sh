#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: the authors of this repository
#
# Build the git bundles that BOOTCHAIN_MIRROR (scripts/build.sh) can point to.
# One bundle per name in BOOTCHAIN_MIRRORED, <name>.bundle: the branch the package's .gitmodules names
# for it (every branch when it names none) plus a branch `pin` at the commit the
# package pins, so the pin survives a force-push or a garbage collection
# upstream. One branch, because the repository (`src`) holds many branches;
# only the pinned commit is needed.
#
# Needs a tree from `scripts/build.sh fetch`. Writes out/mirror/*.bundle and
# out/mirror/SHA256SUMS. Hosting them is up to you.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/work}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out}"
BOOTCHAIN_COMMIT="$(sed -n 's/^BOOTCHAIN_COMMIT="\([0-9a-f]*\)"/\1/p' "${ROOT_DIR}/scripts/build.sh")"
BOOTCHAIN_MIRRORED="$(sed -n 's/^BOOTCHAIN_MIRRORED="\(.*\)"/\1/p' "${ROOT_DIR}/scripts/build.sh")"
tree="${WORK_DIR}/u-boot-dlan17"
dst="${OUT_DIR}/mirror"
die() { printf '::error:: %s\n' "$*" >&2; exit 1; }

[ -d "${tree}/.git" ] || die "run scripts/build.sh fetch first"
rm -rf "${dst}"; mkdir -p "${dst}"
echo "bundles for package commit ${BOOTCHAIN_COMMIT:0:12}"
for name in ${BOOTCHAIN_MIRRORED}; do
  pin="$(git -C "${tree}" ls-tree HEAD "${name}" | awk '{print $3}')"
  url="$(git config -f "${tree}/.gitmodules" "submodule.${name}.url")"
  [ -n "${pin}" ] && [ -n "${url}" ] || die "no submodule ${name} in the package"
  branch="$(git config -f "${tree}/.gitmodules" "submodule.${name}.branch" || true)"
  refs="+refs/heads/*:refs/heads/*"
  [ -z "${branch}" ] || refs="+refs/heads/${branch}:refs/heads/${branch}"
  work="$(mktemp -d)"
  git init --quiet --bare "${work}/m.git"
  git -C "${work}/m.git" fetch --quiet --no-tags "${url}" "${refs}" \
    || die "${name}: ${refs} not fetchable from ${url}"
  git -C "${work}/m.git" cat-file -e "${pin}^{commit}" 2>/dev/null \
    || git -C "${work}/m.git" fetch --quiet "${url}" "${pin}" \
    || die "${name}: pin ${pin} not fetchable from ${url}"
  git -C "${work}/m.git" branch -f pin "${pin}"
  git -C "${work}/m.git" symbolic-ref HEAD refs/heads/pin
  git -C "${work}/m.git" bundle create "${dst}/${name}.bundle" --all
  rm -rf "${work}"
  echo "${name}: pin ${pin} <- ${url} (${branch:-all branches})"
done
( cd "${dst}" && sha256sum ./*.bundle | sed 's| \./| |' > SHA256SUMS )
ls -l "${dst}"
