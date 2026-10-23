<!-- SPDX-License-Identifier: GPL-2.0-only -->
# Downloads and their terms

The repository contains no vendor binary. Everything below is fetched at build
time from its public origin and checked against a commit id or sha256 committed
here. **Do not publish a `u-boot-sunxi-with-spl.bin` you built**: it contains the
vendor DRAM blob, which has no redistribution grant. "Unknown" means no licence
text came with the file.

| What | Origin | Pin | Licence | Redistribute? |
|---|---|---|---|---|
| Package tree `u-boot-dlan17` (build glue) | github.com/radxa-pkg/u-boot-dlan17 | commit `b1cec0a90c79` (tag `2026.04-4`), `scripts/build.sh` | GPL-3.0-or-later (its `debian/copyright`) | yes |
| **`awbin/a733/ddr.bin`**, the DRAM initialisation (AArch32), 232 409 bytes | the same package tree | sha256 `d89804f404f2eef6ef5b03d82a310ef0906c4db8ded760be221b131f5c813a05`, `pins/blobs.sha256` | closed vendor code, no licence text | **no** |
| U-Boot source (`src` submodule) | github.com/radxa/u-boot, branch `u-boot-dlan17` | commit `9da4b3e82d64` (by hash only), `scripts/build.sh` | GPL-2.0-or-later | yes |
| TF-A | git.trustedfirmware.org/TF-A/trusted-firmware-a, master | commit `3d425f4f4598`, `overlay/apply.sh` | BSD-3-Clause | yes |
| Debian trixie base image | docker.io/library/debian | index digest in `container/Containerfile` | various, DFSG | yes |
| Builder packages | snapshot.debian.org | timestamp and exact versions in `container/packages.lock` | various, DFSG | yes |

How the blob is handled:

- `scripts/build.sh fetch` clones the package at the pinned commit; the build
  checks `ddr.bin` against `pins/blobs.sha256` before it starts and stops on any
  difference. It also checks that the SPL in the result carries the blob
  unchanged. The blob is never patched or modified here.
- The package's other prebuilt files (`awbin/a733/bl31.bin`) are not used: BL31 is
  built from TF-A source.
- The package's `atf` fork, `allwinner-arisc`, `allwinner-dramlib` and `tools`
  submodules are not fetched.

The U-Boot pin is fetched from upstream by hash (`git fetch --depth 1`): the
commit is fetched by hash because a branch tip may be rewritten, and GitHub
serves a commit that no branch holds only until it collects it. If it ever stops
answering, the build stops with a message naming the pin; `BOOTCHAIN_MIRROR`
(a URL prefix serving a `src.bundle` written by `scripts/make-mirror.sh`) is
the way to supply it from your own copy.

A new download is added here in the same change that adds the fetch.
