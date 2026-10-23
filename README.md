# a733-bootchain

Boot chain recipe for the **Radxa Cubie A7S** (Allwinner A733, sun60iw2): one
`./build.sh` in a container gives you `u-boot-sunxi-with-spl.bin`, the file that
goes in front of the first partition of the SD card or eMMC.

```
BROM -> U-Boot SPL (vendor DRAM blob ddr.bin) -> BL31 (TF-A, built from source, SRAM 0x62000) -> U-Boot -> kernel
```

**You build it yourself. We ship no binary and no vendor blob**: the DRAM
initialisation code is downloaded at build time from its public origin and
checked against a sha256 committed here (see [The DRAM blob](#the-dram-blob)).
The A733 is the SoC; the Cubie A7S is the board this is built and tested on.
Other A733 boards will need their own defconfig and patches.

## What you get

`out/bootchain/u-boot-sunxi-with-spl.bin` (about 1.2 MiB) and `BOOTCHAIN-ID`
(`upstream`, `submodules`, `overlay`, `source_date_epoch`, `built`,
`offset_kib`, sha256 of the file). The build refuses to
finish unless the result is what the patches say: BL31 version and address,
the Cortex-A76 errata workarounds, the security setup, the FIT contents, the
boot order, the pinned build time in every banner, and that the file fits in
front of the first partition.

- TF-A is upstream master plus 17 patches (`patches/tf-a/`): the A733 platform
  on upstream's Allwinner code and generic GIC driver.
- U-Boot is Radxa's tree (U-Boot v2026.07 plus 73 commits) with 17 patches
  (`patches/u-boot/`). No upstream U-Boot has the A733 yet.
- No boot0, no boot package, no SCP firmware, no ARISC start. `boot_targets` is
  `fel mmc_auto nvme0 usb0 pxe dhcp`.
- U-Boot starts the watchdog on WDT_CPUS and hands it to Linux running. Linux
  needs a device tree that drives WDT_CPUS (or stops the watchdog); otherwise
  the board resets about 16 s after boot. Stopping the watchdog at the U-Boot
  prompt (`wdt dev watchdog@7021000`, `wdt stop`) reaches such a system.

## Requirements

- Linux on x86-64 with `git`, `bash` and **rootless podman or docker**. Nothing
  else on the host, and no root for the build. (aarch64 hosts: the package lock
  resolves, a build there has not been tried yet.)
- About 3 GB free disk (the builder image is 0.8 GB, the sources and build 0.6 GB)
  and a network connection during the build.
- Time: a few minutes. On a busy 8-core machine the first run, builder image
  included, took under 3 minutes.
- A way to write the SD card (root, or a device you may write to).

## Quick start

```sh
git clone https://github.com/DockSeed/a733-bootchain
cd a733-bootchain
./build.sh
```

The result is in `out/bootchain/`. `./build.sh --help` lists the stages and the
few switches. The first run builds the builder image from `container/`: Debian
trixie pinned by digest, every package at the exact version in
`container/packages.lock` from [snapshot.debian.org](https://snapshot.debian.org),
and the image build fails if the installed set differs from the lock. The
sources are pinned by full commit id. Rebuilding gives the same bytes.

## Flash

The file goes to **128 KiB** (sector 256, where the BROM looks for the SPL), the
first partition starts at 16 MiB. Tested on the SD card; Radxa's own setup
script writes eMMC at the same offset, not tried here. Find the target with
`lsblk` first: a wrong device is lost data.

```sh
scripts/flash.sh /dev/sdX            # or an image file; asks you to type the device path
```

It writes only the gap in front of the first partition, reads the bytes back
and compares the sha256. By hand, the same thing:

```sh
sudo dd if=out/bootchain/u-boot-sunxi-with-spl.bin of=/dev/sdX bs=512 seek=256 conv=notrunc,fsync
```

On a running board (as root), `scripts/spl-swap.sh write u-boot-sunxi-with-spl.bin`
replaces the chain on the boot card and reads it back with `O_DIRECT`.
The card needs a partition table with the first partition at 16 MiB or later.

## Status

The chain of this tree was booted on two Cubie A7S boards from the SD card,
cold and after a warm reset (PSCI): the 6 GiB board (LPDDR5 at 2400 MHz) and
the 8 GiB board (2040 MHz). On both: the DRAM blob reports version V0.6036 and
the full size; PB0-PB3 sit at IO disable (`PB_CFG0` `0xffffffff`), the GPIO
withstand-voltage register reads `0x01155550`; `boot_targets` is as built;
`rng` gives different data each time and Linux gets its KASLR seed; Linux boots
(another distribution's image, through UEFI; on the 6 GiB board NVMe is found
at PCIe Gen3); `poweroff` ends at 0.0 W. The PMIC rails the DRAM uses read the
same as with Radxa's boot0 chain.

Measured earlier with the same BL31, on both boards: PSCI `CPU_ON` brings up
all 8 cores, `CPU_SUSPEND` including cluster sleep works on all 8, five rounds
of full load and idle plus 20 rounds of hotplug on cores 1-7 ran without
errors.

Not yet proven for this chain: an 8 h soak, eMMC boot, suspend to RAM (needs
open firmware for the E902 co-processor, and its DRAM half exists only in a
closed library). BL31's CPU_SUSPEND alone ran an 8 h load/idle soak without
errors on the 8 GiB board (see
`patches/tf-a/allwinner-a733-native-psci-cpu-suspend.patch`).

## The DRAM blob

The SPL initialises LPDDR5 through `awbin/a733/ddr.bin`, closed vendor code from
Radxa's `u-boot-dlan17` package. It has no redistribution grant, so this
repository does not contain it and a `u-boot-sunxi-with-spl.bin` you build
contains it: **do not publish your build output**. `build.sh` downloads the
package at a pinned commit, checks the blob's sha256 (`pins/blobs.sha256`)
before building and checks that the SPL carries it unchanged. Details and the
other downloads: [docs/blobs.md](docs/blobs.md).

## More

- [docs/blobs.md](docs/blobs.md): what is downloaded, from where, pin, licence.
- [docs/boot-chain.md](docs/boot-chain.md): what is built, what is a blob, the
  layout of the file, version strings, how this differs from Radxa's chain.
- [docs/tf-a-series.md](docs/tf-a-series.md): where each TF-A patch comes from,
  design decisions, open items, hardware tests.
- `scripts/update-lock.sh [<snapshot>]`: regenerate `container/packages.lock`
  (maintainers; not needed to build).
- `scripts/build.sh`, `scripts/test-layout.sh`: the stages themselves (what runs
  in the container) and the layout self-test; both work directly on a Debian host
  with the packages listed in `container/packages.txt`.

## How this was made

One human and AI coding agents (Claude). The human set the direction, made
every decision and handled the hardware. The patches, scripts and
documentation were written by the agents; every patch of our own carries
`Assisted-by: Claude`. The hardware statements under Status were measured on
the boards.

Earlier versions of this repository described other projects' code, including
Radxa's and Allwinner's, in a tone that was not fair to the people who wrote
it. Those texts were written with AI agents and published without the review
they needed. They have been rewritten, and we apologise to everyone they
concerned. Their work is what made this project possible.

## License

"As upstream", in [REUSE](https://reuse.software) style: every part has the
licence of the project it belongs to. Full texts in `LICENSES/`; the mapping for
files without a header is `REUSE.toml`.

| part | licence |
|---|---|
| `patches/tf-a/` | BSD-3-Clause (TF-A) |
| `patches/u-boot/` | GPL-2.0-or-later (U-Boot) |
| `scripts/`, `overlay/`, `container/` | the SPDX header in each file (`GPL-2.0-only`, some `GPL-2.0-only OR MIT`) |
| README, docs, pins | GPL-2.0-only |

The root `LICENSE` is the GPL-2.0 text, for the parts that are ours; the table
above is what holds per file. The vendor blob is not in this tree and is not
covered by any of these licences.
Patches taken from other authors keep their authors' sign-offs.
