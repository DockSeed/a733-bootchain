<!-- SPDX-License-Identifier: GPL-2.0-only -->
# TF-A series: provenance, decisions, open items

The patch messages in `patches/tf-a/` are written for upstream review and carry
no history. What each patch was made from, which choices it rests on and what is
still open lives here.

## Sign-off chain

Our own patches have `From: DockSeed <dockseed@proton.me>`, carry no
`Signed-off-by` and end with `Assisted-by: Claude` (written by an AI coding
agent, directed and checked by a human). A patch of another author keeps
that author's `From:` and `Signed-off-by` as given; where code of that author
sits in one of our patches, it is marked `Co-developed-by:` with that author's
`Signed-off-by`. What we changed in a third-party patch is one line
`[DockSeed: ...]` after the author's sign-off, and a `Link:` points to the fork
commit it comes from. Authors outside this project: Jernej Skrabec and Yixun Lan
(dlan17 TF-A fork).

## Where each patch comes from

| patch | from |
|---|---|
| allow-max-cpus-per-cluster-to-be-overridden | dlan17 fork a6298748c (Jernej Skrabec), unchanged; upstream review 44294, open |
| let-a-platform-use-the-generic-gic-driver | ours, new; uses the generic driver instead of the fork's GIC layer (14b197fee, 57c92e467) |
| cpu-on-off-for-the-new-mpidr-format | fork b5de74a68 (Jernej Skrabec), adapted: selected by `SUNXI_NEW_MPIDR_FMT` instead of replacing `sunxi_cpu_ops.c` for every SoC; AArch64 reset bit from the platform's `CLU0_CPUn_CTRL_REG`, not the A523 address; folds in "reject MPIDRs that name no core" and "bound the PPU waits"; A523 parts dropped |
| cortex-a53-opt-outs-in-the-a53-makefile | ours, new |
| a733-add-initial-support | fork f4c0b0dba (Yixun Lan), adapted to the A733 alone and set per UM V1.00: `CCMU_SEC_SWITCH_REG` at CCU + 0x1F00 (4.1.6.278; 0x0F00 is `SPI0_CLK_REG` on the A733); no `SUNXI_DSP_PRCM_BASE` (the A733 has no DSP PRCM); `sunxi_cpucfg_ncat3.h` reduced to `CLU0_CPUn_CTRL_REG` and `CLU0_RVBARADDRn_L/H` (the fork's ncat2 AA64nAA32 location is reserved on the A733, UM 5.1.6.1); `SUNXI_GICR_BASE` instead of the fork's `SUNXI_GICC_BASE`; CPU files and GIC-600 options in the platform's own `platform.mk` instead of the fork's `allwinner-common-a55.mk`/`-a76.mk`; `SUNXI_PSCI_USE_SCPI := 0` |
| a733-security-setup-from-the-um | ours + the S_TZMA/S_SPC writes of fork 87ecf4ef5 (Jernej Skrabec), now built only where the map defines both blocks |
| system-reset-through-a-standalone-watchdog | fork 13c7a3b55 (Jernej Skrabec), adapted: the define is a boolean tested with `#if`; plus our system reset without preconditions |
| a733-native-psci-cpu-suspend | ours: native PSCI CPU_SUSPEND, on by default, the per-core AArch64 reset bit and the 2 KiB stacks; the GIC steps use the generic driver's `gicv3_cpuif_disable()/_enable()` |
| a733-enable-cpu-back-pll | ours |
| a733-apply-a76-errata | ours (errata 1946160, 2743102, 2356586, CVE-2025-10263); the 2743102 revision check is upstream's own on master |
| a733-apply-a76-erratum-3888013 | ours |
| a733-el2-access-to-the-dsu-cluster-pmu | ours |
| a733-dsu-cluster-power-required | ours; on master the GIC enable runs before `pwr_domain_on_finish`, so the advisory write now follows it (unrelated registers); suspend order unchanged |
| gicv3-let-a-platform-read-a-cores-redistributor-base | ours, new, for the DSU patch below |
| a733-dsu-cluster-off-state | ours; GIC steps keep their order relative to the generic driver; frame addresses now from the driver; RWP waits unbounded like the driver's own (IHI 0069 gives no bound, and on the wake path CNTFRQ_EL0 is not yet programmed for a timeout) |
| a733-runtime-console-at-error-level | ours |
| a733-power-off-through-the-axp318w | ours, new: `sunxi_power_down()` sets AXP318W 0x55 bit 7 over S_TWI0, as Linux's axp20x; S_TWI0 values from the A733 manual (S_PRCM, port L) and the silicon readback of APBS1; pattern of `sun50i_h616/sunxi_power.c` |

## Decisions for the TF-A master base

**Power-down WFI return (CPU_SUSPEND).** TF-A master runs one WFI after the
power-down hook; if it returned, PSCI would call the hook again and panic
without `PABANDON_ACK`. `cortex_a55.S`/`cortex_a76.S` do not acknowledge, and
must not: both TRMs state that with `CPUPWRCTLR_EL1.CORE_PWRDN_EN` set a WFI
masks all interrupts and wake-up events and only a reset ends it (Cortex-A55
TRM 100442_0200_03_en, 2.4.8 "Power down sequence", p. 44-45; Cortex-A76 TRM
100798_0401_01_en, 5.9 "Core powerup and powerdown sequences", p. 44-45). An
abandon handler for these cores would be code for a path the hardware does
not have; upstream's own wording (change 47297): "Older cores will powerdown
and immediately power back up". No A55/A76 pabandon change exists on
review.trustedfirmware.org (searched 2026-10-03; 34244 "Cortex-A55
CPUPWRCTRL_EL1 accessors" is abandoned and adds no abandon support). What
keeps the panic unreachable is that both hooks set the bit and ISB before the
WFI; `build.sh` asserts exactly that on the linked image
(`scripts/lib/aarch64-cpu-ops.py` + disassembly). Silicon check: hardware
test 2 below.

**Link-time optimisation.** The A733 builds with TF-A's default (GCC release:
LTO on). `build.sh` reads linked objects from the link map, and finds the
security-setup stores by anchor (`aarch64-mmio-stores.py --anchor 0x07010290`),
because with LTO `sunxi_security_setup()` is inlined into `bl31_main()`.
Release BL31 37 016 B (`bl31.bin` as built here). EL3 stack, deepest chain
(`gcc -fcallgraph-info=su`, PSCI indirect calls resolved to the platform's PSCI
ops): 928 B from `std_svc_smc_handler` (CPU_SUSPEND, wake path, a print), 736 B
warm boot, 672 B cold boot; without LTO 912 B. 2 KiB per core stays.

**Cortex-A53 opt-outs.** `?=` in `allwinner-common.mk` cannot work: TF-A's
`defaults.mk` and `cpu-ops.mk` set all eight values before the platform
makefile. They now sit in `allwinner-common-a53.mk`; A64, A133, H6, H616 and
R329 build identical `config.h` and identical code.

**GIC-600 frames.** The DSU code uses the frame the generic driver found;
every core checks once that it is `SUNXI_GICR_BASE + core * 128 KiB` (GIC-600
TRM 100336 r1p6 Table 4-1: page 4 + 2 * ITScount + 2 * n from GICD; UM V1.00
GIC window 0x03400000-0x0358FFFF) and panics with an ERROR line if not.

## Open items

- **CPU_BACK_PLL enable.** BL31 enables the PLL because the Linux CPU clock
  driver parks the clusters on it and nothing else enables it. Linux does not
  yet enable its parking source through the clock framework before
  reparenting; until it does, `allwinner-a733-enable-cpu-back-pll` stays.
- **Redistributor frame save/restore** in the DSU patch is platform code and
  covers IGROUPR0, IGRPMODR0, ISENABLER0, ICFGR1, NSACR and IPRIORITYR. Its
  completeness against the GIC-600 TRM (ISPENDR0, ICFGR0, wake state) is not
  shown; the alternative is a generic save/restore in the GICv3 driver.
- **GICV3_IMPL_GIC600_MULTICHIP** was 1 in the fork's makefiles and is 0 now.
  One GIC-600, no multichip data registered: no difference expected. Note only.
- **SYSTEM_OFF without the PMIC.** With
  `allwinner-a733-power-off-through-the-axp318w`
  `sunxi_power_down()` switches the AXP318W off over S_TWI0; `poweroff` ends
  at 0.0 W. What is left: when the device tree U-Boot passes names no
  `x-powers,axp318w`, or S_TWI0 does not come up, `sunxi_power_down()`
  returns, only the cores go off, and on master that ends in
  `panic("Could not power off CPU")` after 32 WFI.

## Hardware tests for this series

Checks on the Cubie A7S. Tests 1 and 3 can be repeated with the chain built
from this repository. Tests 2 and 4 are observations on the hardware that the
decisions named there rest on.

1. **Boot and soak** of the shipping chain: cold boot, `dmesg` without BL31
   ERROR lines, all 8 CPUs online, 10 min load/idle (cpuidle core state in use,
   `/sys/devices/system/cpu/cpu*/cpuidle/state*/usage` growing on every core),
   no `PANIC` on the UART.
2. **Wake pending at the power-down WFI.** The decision "Power-down WFI
   return" above relies on the TRM statement that a power-down WFI ends only
   through reset. The test checks that a Group 0 interrupt pending at the WFI
   of a core-level CPU_SUSPEND (FIQ asserted, ICC_HPPIR0_EL1 = 15) does not
   return into PSCI's abandon path but brings the core back through reset,
   on all eight cores (A55 cpu0-5, A76 cpu6-7).
3. **GIC frame check**: the boot log must not contain `DSU: cpu<n>
   redistributor found at`; all eight CPUs come online (each runs the check
   after CPU_ON).
4. **CNTFRQ_EL0 at the wake.** A bounded RWP wait in the cluster wake path
   takes its deadline from `timeout_init_us()`, which scales by CNTFRQ_EL0.
   The core's power-down resets CNTFRQ_EL0 and the PSCI library programs it
   again only after the platform hook, so a 10 ms deadline there was computed
   from an unprogrammed register and panicked with `GICR_CTLR.RWP still set
   after 10000 us`. That is why the RWP waits in
   `allwinner-a733-dsu-cluster-off-state` are unbounded, like the GIC
   driver's own.
