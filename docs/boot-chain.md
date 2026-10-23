<!-- SPDX-License-Identifier: GPL-2.0-only -->
# Boot chain

`./build.sh` builds two files in `out/bootchain/`:

| File | Goes to |
|---|---|
| `u-boot-sunxi-with-spl.bin` | the card at 128 KiB (the boot ROM loads the SPL from sector 256; the SPL finds BL31 and U-Boot behind itself) |
| `BOOTCHAIN-ID` | a text stamp: package commit, submodule pins, overlay hash, pinned build epoch, build time, offset, sha256 of the file |

The first partition starts at 16 MiB. The offsets live in
`scripts/lib/bootchain-layout.sh`; the build refuses a chain that does not fit,
and `scripts/flash.sh` checks again before it writes.

```
BROM -> U-Boot SPL (SRAM 0x47060, calls the vendor DRAM blob ddr.bin at 0x90000)
     -> BL31 (TF-A, built here, SRAM 0x62000) -> U-Boot (DRAM 0x4a000000) -> kernel
```

## What is built from source, what is a blob

| Part | Source |
|---|---|
| DRAM init | **vendor blob** `awbin/a733/ddr.bin` (232 409 bytes) from Radxa's package tree, built into the SPL unchanged; the SPL copies it to SRAM 0x90000 and calls it |
| U-Boot SPL and U-Boot | Radxa's tree (`radxa/u-boot` `9da4b3e82d64`, U-Boot v2026.07 plus 73 commits for the A733) + 17 patches (`patches/u-boot/`) |
| BL31 | upstream TF-A master `3d425f4f4598` + 17 patches (`patches/tf-a/`; provenance in [tf-a-series.md](tf-a-series.md)) |

No boot0, no `boot_package.fex`, no SCP firmware, no packer: the U-Boot build
itself (binman) writes the one file. The frame is Radxa's package
`radxa-pkg/u-boot-dlan17` at commit `b1cec0a90c79` (tag `2026.04-4`), built with
its own Makefile. `overlay/apply.sh` rewires it: BL31 is built from TF-A instead
of taken from the package's prebuilt `bl31.bin`, no SCP image is built or
loaded, and the patch series are applied. Patches taken from other authors keep
their author and sign-off and name the commit they come from (`Link:`).

Nothing in the DRAM blob is changed or inspected beyond locating it: the DRAM
clock and the rails it touches are known only by readback on the board. The SPL
sets no PMIC rail itself.

## The file

| offset in the file | content | made by |
|---|---|---|
| 0x0 | eGON.BT0 header (0x60 B; `length` at 0x10 = SPL rounded up to 8 KiB, `dram_size` at 0x24 written at run time) | `tools/sunxi_egon.c` |
| 0x60 | SPL code and data; inside its `.rodata` `awbin/a733/ddr.bin`, unchanged (`arch/arm/mach-sunxi/sunxi_libdram.S` `.incbin`) | U-Boot SPL build |
| up to 0x4a000 | 0xff padding (`min-size = <0x4a000>` for the A733 in `arch/arm/dts/sunxi-u-boot.dtsi`) | binman |
| 0x4a000 | FIT: `uboot` (U-Boot at `CONFIG_TEXT_BASE`), `atf` (BL31, load = entry = `CONFIG_SUNXI_BL31_BASE`), `fdt-1`; configuration `firmware = "atf"`, `loadables = "uboot"` | binman |

`scripts/build.sh` reads this back from the built file
(`scripts/lib/sunxi-spl-image.py layout`): the FIT holds exactly these three
images, the DRAM blob sits once inside the SPL, and the FIT is where the SPL
looks for it.

## The SPL

- The BROM loads the eGON image into SRAM at 0x47000; code starts at
  `SPL_TEXT_BASE` 0x47060. `SPL_MAX_SIZE` is 0x49000 in the A7S defconfig, so
  the SPL ends at 0x90060 at most.
- The first code, still in AArch32, is the boot hook in
  `arch/arm/include/asm/arch-sunxi/boot0.h`: it copies the blob from its place
  in the image to `SUNXI_LIBDRAM_BASE` 0x90000, calls it, stores the value it
  returns into `dram_size` of the eGON header in SRAM, then switches to AArch64
  through RVBAR/RMR. `sunxi_dram_init()` (`arch/arm/mach-sunxi/dram_sun60i_a733.c`)
  returns that size in MiB. The SPL itself trains nothing.
- Early stack at `SPL_STACK` 0x5A000 (inside the blob's copy in the image,
  spent by then), BSS in DRAM at 0x4ff80000; after DRAM init the stack moves to
  `SPL_STACK_R_ADDR` 0x4fe00000 with a 0x140000 heap. `gpio_init()` sets the
  console pins and PB0-PB3 to IO disable (patch
  `sunxi-a733-jtag-pins-to-io-disable`). `sunxi_board_init()` writes 0x01155550
  to `GPIO_POW_MODE` (PIO + 0x40) when the SoC version (`0x03000024 & 7`) is 1.
- Boot source from the eGON header's `boot_media` (written by the BROM): 0x10 =
  card at 128 KiB, 0x12 = eMMC at 128 KiB. The SPL loads the FIT from
  `max(SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR, length / 512)` + 240 + 16 sectors
  (`board_spl_mmc_get_uboot_raw_sector()`). With the upstream default 0x40 that
  is the FIT only while the SPL is larger than 0x48000 B; this chain sets 0x250
  (= 0x4a000 / 512, patch `sunxi-cubie-a7s-u-boot-where-binman-puts-it`), so it
  holds whatever the SPL's size. The SPL then puts each image of the FIT at its
  load address and enters BL31 with U-Boot as the next stage.
- The SPL's UFS and SPI-NOR loaders are configured out: the A7S has neither.

## BL31 placement

| side | value | where |
|---|---|---|
| TF-A | `BL31_BASE` = `SUNXI_SRAM_A2_BASE` 0x50000 + `SUNXI_SRAM_A2_BL31_OFFSET` 0x12000 = **0x62000**, `BL31_LIMIT` 0x70000 | `patches/tf-a/allwinner-a733-add-initial-support.patch`, common `platform_def.h` |
| U-Boot | `CONFIG_SUNXI_BL31_BASE` **0x62000** (FIT `atf` load and entry), `CONFIG_SUNXI_SCP_BASE` 0 | `patches/u-boot/sunxi-a733-bl31-in-sram-without-scp.patch` |

Radxa's prebuilt BL31 (115 677 B) does not fit the SRAM slot, so Radxa's tree
loads it to DRAM. The source BL31 does fit (release build about 37 KiB,
0x62000-0x6b098). The SPL runs from SRAM while it loads BL31 there. That is safe
because 0x62000-0x70000 always lies in the blob's copy inside the SPL image,
which the boot hook has already moved to 0x90000: with `SPL_MAX_SIZE` 0x49000
and a 232 409 B blob, that copy covers 0x57487-0x7fc39 wherever the linker
places it, and the early stack (0x5A000) lies below 0x62000. `scripts/build.sh`
checks this on the linked SPL (`sunxi_libdram_blob_start/_end`), and that the
three addresses (bl31.elf entry, `CONFIG_SUNXI_BL31_BASE`, FIT load and entry)
are one. The kernel needs no reservation for BL31 (it sits in SRAM).

## SCP / ARISC

No SCP image is built or loaded (`SUNXI_SCP_BASE` 0, no `SCP=` in
`Makefile.local`). Radxa's tree has `CMD_SUNXI_BOOT_ARISC` default y on the
A733, and `boot/pxe_utils.c` runs it before each extlinux boot: it reads the
trained DRAM parameters out of the blob at 0x90000 into the kernel's device
tree (96 `dram_paraNN` properties under `/dram`, or "refusing to start ARISC"
without that node) and issues SMC 0x8000ff10 with the DT address. This
BL31 answers that function ID with SMC_UNK
(`services/arm_arch_svc/arm_arch_svc_setup.c`, default case), so the E902
co-processor stays in reset. The patch `sunxi-cubie-a7s-no-arisc-start` turns
the command off, so neither the device-tree edit nor the SMC happens; an EFI
boot never reached that hook anyway.

Reset and power-off do not need the ARISC: BL31 resets through the standalone
watchdog and switches the AXP318W PMIC off over S_TWI0.

## Build time and reproducibility

The U-Boot banners (SPL and U-Boot), TF-A's `Built :` string and the FIT
`timestamp` carry the time of the build unless it is pinned. `scripts/build.sh`
exports `SOURCE_DATE_EPOCH` = the committer date of the pinned package commit
(`scripts/lib/bootchain-epoch.sh` says why that date and what honours the
variable), replacing whatever the environment holds. On the board the banners
read `(Sep 15 2026 - 08:50:12 +0000)` and `Built : 08:50:12, Sep 15 2026`: the
date of the pinned package commit, not the day you built. The real build time is
`built=` in `BOOTCHAIN-ID`; `source_date_epoch=` is the pinned value. Two builds
of unchanged input give the same `u-boot-sunxi-with-spl.bin`; `BOOTCHAIN-ID`
differs only in `built=`. The build reads the epoch back out of the finished
file and fails if a banner, a `Built :` string or the FIT timestamp does not
carry it.

Build on an x86-64 host to get the same bytes as the tested chain; a native
aarch64 compiler gives other bytes (not tried).

## Pins and checks

Every input is fetched from its public origin by commit id or sha256: the
package, the one submodule the build uses (`src`, U-Boot) and TF-A
(`ATF_BASE` in `overlay/apply.sh`). The DRAM blob is checked against
`pins/blobs.sha256` before the build, and the build checks that the SPL carries
it unchanged, once.

The build then checks the result, not just the exit code: the BL31 inside the
FIT is the source-built one, from the pinned TF-A commit, linked at the address
U-Boot loads it to and placed where loading it cannot overwrite the running SPL;
the FIT holds U-Boot, BL31 and the device tree and nothing else; the SPL looks
for the FIT where binman put it; U-Boot's configuration is what the patches
decide (watchdog, boot counter, PSCI reset, RNG, NVMe, no ARISC start); the boot
order is card or eMMC, then NVMe; every build time in the file is the pinned
epoch; and the `bl31.elf` links what the patches promise -- native CPU_SUSPEND,
the CPU_BACK_PLL enable, no SCPI path, the Cortex-A76 errata and CVE
workarounds, the security-register writes, a power-down hook that cannot return,
the EL3 stack size.

The 3888013 workaround costs the A76 about half its uncached read bandwidth and
comes from its own patch (`allwinner-a733-apply-a76-erratum-3888013`), which
sets `ERRATA_A76_3888013 := 1`. A build without that patch fails, unless
`A733_BUILD_WITHOUT_ERRATUM_3888013=1` is set in the environment of
`scripts/build.sh`; it then warns that this is not the shipping chain. The root
`build.sh` passes only `BOOTCHAIN_MIRROR` into the container, so set the
variable inside it (`./build.sh shell`, then run `scripts/build.sh` there).

## Version strings on the UART

A boot prints three version lines with `-dirty` in them. That names the way the
tree is put together, not an unknown tree:

- `SPL-2.0 - preboot ... {853efe0f-dirty}`, before the DRAM lines: the vendor
  DRAM blob (`ddr.bin`), built by Radxa from their own tree. It is not built
  here, and blobs are not patched.
- `U-Boot SPL 2026.04-4-boot-dlan17-g9da4b3e82d64-dirty` and the U-Boot banner:
  the pinned radxa/u-boot commit `9da4b3e8` plus `patches/u-boot/series`.
  `overlay/apply.sh` applies the series with `git apply` and commits nothing,
  so U-Boot's `setlocalversion` adds `-dirty`.
- `BL31: v2.15.0(release):3d425f4-dirty`: TF-A master `3d425f4` plus
  `patches/tf-a/series`, applied the same way (`git describe --dirty`).

What the chain holds is fixed by the pins and the two series. `BOOTCHAIN-ID`
records the chain: `upstream` (package commit), `submodules` (pinned commits),
`overlay` (hash of `overlay/`, `patches/`, `pins/` and two scripts),
`source_date_epoch`, `built` (real build time), `offset_kib` and the sha256 of
the file (`sha256_<name>`).

## What is different from Radxa's chain

Radxa's package (`2026.04-4`, the frame of this build) builds the same kind of
file. Where this recipe differs from it:

| Radxa's package | this recipe |
|---|---|
| BL31 from the prebuilt `awbin/a733/bl31.bin` (TF-A v2.5, debug), loaded to DRAM | BL31 built from upstream TF-A master plus the patches, in SRAM at 0x62000 |
| SCP image (`scp.bin`) built and loaded to DRAM | no SCP image, `SUNXI_SCP_BASE` 0 |
| ARISC start command runs before each extlinux boot | turned off |
| the watchdog is not started by U-Boot | the watchdog starts in U-Boot and is handed to Linux running (patch `sunxi-cubie-a7s-watchdog-autostart`) |

What this chain no longer contains compared with the boot0-based layout (boot0
at 128 KiB, `boot_package.fex` at 12 MiB, packed by Allwinner's `dragonsecboot`
tool, which needs an x86-64 host): boot0 and its pin/rail setup (now: the SPL and
the DRAM blob), `header-info.bin`, the packer, the SPL running from DRAM.
`scripts/spl-swap.sh write-v1` can still write that layout to a card if you
bring both files.

## Known limits

- **The U-Boot commit is reachable only by hash.** `radxa/u-boot`
  `9da4b3e82d64` is fetched by hash because a branch tip may be rewritten; GitHub
  serves a commit that no branch holds only until it garbage-collects it. If it
  disappears, the fetch fails naming it. A clone of it hosted elsewhere works:
  `BOOTCHAIN_MIRROR` (see [blobs.md](blobs.md)).
- **Built and tested on an x86-64 builder.** Nothing in the chain is tied to the
  host architecture; a build on an aarch64 host has not been tried, and its
  native compiler would give other bytes.
- **Other A733 boards** need their own defconfig and patches.
