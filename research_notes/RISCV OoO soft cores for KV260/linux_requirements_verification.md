# Linux on a clean-room RV64 OoO dual-core (KV260): ISA/platform requirements, pitfalls, and the RTL-to-Linux verification/debug toolchain other projects used

Research date: 2026-10-12. All Linux-kernel and OpenSBI sources are the `master` branches as fetched on that date. The kernel docs site showed 7.3.0-rc7. Spec versions and dates are recorded inline. No source code is reproduced here. Mechanisms are described in prose.

Method note: the shared web-search budget for this turn ran out mid-research. After that, evidence came only from fetching known primary URLs (spec pages, kernel/OpenSBI source and docs, project READMEs, papers). Items that could not be verified are listed under each section's Gaps.

---

## Q1. What is the minimum ISA and platform for Linux kernel + Buildroot (RV64IMA(C)+Zicsr+Zifencei, M/S/U, Sv39, interrupts/delegation, PMP for OpenSBI, timer, PLIC/AIA, SBI extensions, OpenSBI generic+FDT, U-Boot vs direct boot)?

### Takeaway
A kernel + Buildroot bring-up needs the following:
- RV64IMA + Zicsr + Zifencei, with M/S/U modes.
- Sv39 with correct `satp` WARL behavior.
- An ACLINT/CLINT-style machine timer plus M-mode software-interrupt (IPI) block.
- A PLIC (or AIA APLIC/IMSIC) and a UART.
- An FDT that OpenSBI's `generic` platform can parse.
- SBI firmware providing TIME/IPI/RFENCE plus HSM for SMP.

C, F/D and even PMP are technically optional for this phase: kernel `FPU=n` with a Buildroot `lp64` userland works. But C/F/D are mandatory for any distro, and a PMP of 16 CSRs with at least 4–8 usable entries and grain ≤ 4 KiB is the practical floor if you want OpenSBI to protect itself. U-Boot is not needed for phase 1. Boot ROM → OpenSBI `fw_jump`/`fw_payload` → `Image` + DTB (+ initramfs) is what NaxRiscv and LiteX-VexRiscv use.

### Cited Findings

**Versions and dates (as of 2026-10-12)**
- The RISC-V ratified-spec library lists:
  - Unprivileged and Privileged ISA manuals at release **v20260120** (Jan 2026).
  - **RVA23 Profile v1.0** (Oct 2024) and RVB23 v1.0 (Oct 2024).
  - "RISC-V Profiles" (RVA20/RVA22) v1.0 (Apr 2023).
  - **SBI v3.0** (Jul 2025) and **BRS v1.0** (Aug 2025).
  - **Debug v1.0** (Feb 2025).
  - **AIA v1.0** (Jun 2023) and **PLIC v1.0.0** (Feb 2023).
  - E-Trace v2.0 (Jun 2025), N-Trace v1.0 (Nov 2024), HART Trace Interface v1.0 (Sep 2026).
  - Server Platform v1.0 (May 2026).
  - ACLINT does not appear in the list.
  - Source: [RISC-V Ratified Specifications Library](https://docs.riscv.org/reference/home/index.html)
- In the v20260120 manual, the Machine-Level and Supervisor-Level ISA chapters are labelled **Version 1.13** — [Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html); [Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
- The ISA-manual GitHub repo keeps publishing rolling snapshots, the latest tagged 8 Oct 2026. Their listed changes are text clarifications, e.g. Smcntrpmf wording and an Sv57 naming fix — [riscv-isa-manual releases](https://github.com/riscv/riscv-isa-manual/releases)
- The RVA20/RVA22 profile source file says **version 1.1, dated 2 April 2023, Ratified**. The library lists "v1.0 April 2023", a minor discrepancy. The same file is internally inconsistent about whether Ssu64xl is mandatory — [profiles.adoc](https://raw.githubusercontent.com/riscv/riscv-profiles/main/src/profiles.adoc)
- SBI v3.0 is dated 2025-07-16 and Ratified. It adds MPXY, DBTR, FWFT and SSE, plus clarifications to set_timer and the IPI/RFENCE error codes — [SBI v3.0 change log](https://docs.riscv.org/reference/sbi/v3.0/changelog.html)

**Kernel entry contract** (Documentation/arch/riscv/boot.rst, by Alexandre Ghiti, dated 2023-05-23)
- Register and MMU state at entry:
  - a0 must hold the current hart's ID.
  - a1 must hold the physical address of the devicetree.
  - satp must be 0, i.e. the MMU disabled.
  - Source: [Linux boot requirements](https://docs.kernel.org/arch/riscv/boot.html)
- The kernel must sit on a PMD boundary: **2 MB-aligned on RV64**. The EFI stub relocates it otherwise — [boot](https://docs.kernel.org/arch/riscv/boot.html). Early setup treats a non-PMD-aligned physical load address as a fatal bug and rounds the DRAM start down to a PMD boundary — [arch/riscv/mm/init.c](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/mm/init.c)
- The kernel must not map resident firmware memory or PMP-protected memory in its direct map. Firmware must describe those regions in DT (/reserved-memory) or in the UEFI memory map — [boot](https://docs.kernel.org/arch/riscv/boot.html)
- SMP has two methods:
  - "Spinwait": all harts enter and one wins a lottery. It is a legacy path for M-mode kernels or firmware without SBI HSM.
  - "Ordered booting": firmware releases one hart, which starts the others via SBI HSM. This is preferred and is what supports CPU hotplug and kexec.
  - Source: [boot](https://docs.kernel.org/arch/riscv/boot.html)
- Kconfig help adds that spinwait cannot support hotplug or sparse hart IDs, and needs NR_CPUS larger than the first hart's physical ID — [arch/riscv/Kconfig](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/Kconfig)
- Under UEFI, new firmware must implement RISCV_EFI_BOOT_PROTOCOL to pass the boot hartid. The kernel uses only the EFI memory map — [boot](https://docs.kernel.org/arch/riscv/boot.html)

**Kernel ISA assumptions**
- The user-visible base behavior is rv64ima, as defined by user ISA 2.2 and privileged 1.10. The only listed exception is that userspace cannot execute fence.i directly — [hwprobe docs](https://docs.kernel.org/arch/riscv/hwprobe.html)
- **A is required.** No Kconfig option makes A optional or builds with only Zalrsc/Zaamo; atomic RMW support is selected unconditionally — [Kconfig](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/Kconfig)
  - Zabha and Zacas are optional and runtime-patched.
  - Queued spinlocks are gated behind NONPORTABLE. Their help says the forward-progress guarantee comes from CAS with Zabha, or LR/SC with Ziccrse.
- **FPU is optional.** The `FPU` option defaults to y. When disabled, neither kernel nor userspace may use FP, and the userspace ABI flags switch to `-mabi=lp64`. Vector support depends on FPU — [Kconfig](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/Kconfig)
- **C is optional, but on by default.** `RISCV_ISA_C` defaults to y, and its help warns the kernel will not run on cores without compressed instructions — [Kconfig](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/Kconfig)
- **Misaligned accesses.**
  - The default scalar policy, `RISCV_PROBE_UNALIGNED_ACCESS`, probes speed at boot and emulates when traps occur.
  - `RISCV_SBI_FWFT_DELEGATE_MISALIGNED` (NONPORTABLE, off by default) asks firmware to delegate misaligned traps. Its help warns of oopses and KVM-guest crashes on some platforms.
  - Source: [Kconfig](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/Kconfig)
- NR_CPUS ranges 2–512 (default 256) for 64-bit SBI kernels. Binutils ≥ 2.36 needs Zicsr/Zifencei spelled explicitly — [Kconfig](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/Kconfig)
- ISA discovery from DT ([cpufeature.c](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/kernel/cpufeature.c)):
  - The kernel prefers per-hart `riscv,isa-extensions` and falls back to the `riscv,isa` string.
  - On DT systems it sets Zicsr, Zifencei, Zicntr and Zihpm unconditionally.
  - The global ISA is the intersection over all harts.
  - **F is masked out when D is absent.**
  - Zicbom, Zicboz and Zicbop each require a known power-of-two block size.

**Devicetree content Linux and OpenSBI expect**
- RISC-V `cpu` node binding ([cpus.yaml](https://raw.githubusercontent.com/torvalds/linux/master/Documentation/devicetree/bindings/riscv/cpus.yaml)):
  - Each cpu node must contain an `interrupt-controller` child (`riscv,cpu-intc`).
  - It must have either `riscv,isa` or the pair `riscv,isa-base` + `riscv,isa-extensions`.
  - `mmu-type` (`riscv,sv39`/`sv48`/`sv57`/`none`) names the largest supported mode.
  - Optional `riscv,cbom-block-size`, `riscv,cbop-block-size` and `riscv,cboz-block-size` give the CBO sizes.
  - `timebase-frequency` must sit in `/cpus`, not in the cpu node.
- OpenSBI's **generic** platform is entirely FDT-driven ([OpenSBI generic platform](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/docs/platform/generic.md)):
  - Compatible strings must match drivers in `lib/utils`.
  - `/chosen/stdout-path` is needed when there are several consoles.
  - Multi-hart platforms need an IPI device node, and a timer node is required.
  - It builds with `PLATFORM=generic`. Reference users are QEMU virt, Spike, SiFive FU540 and Ariane (CVA6).

**SBI calls the kernel makes** ([arch/riscv/kernel/sbi.c](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/kernel/sbi.c))
- The kernel probes TIME, IPI and RFENCE (spec > 0.1), SRST (≥ 0.3, for reboot/poweroff), DBCN (≥ 2.0, debug console) and FWFT (≥ 3.0).
- If TIME/IPI/RFENCE are missing, it falls back to legacy v0.1 calls **only if `CONFIG_RISCV_SBI_V01` is built in**. Otherwise the stubs just warn.
- **The remote-fence stub returns success without doing anything.**
- HSM is used for ordered SMP boot — [boot](https://docs.kernel.org/arch/riscv/boot.html)

**BRS v1.0 (Boot and Runtime Services, ratified 29 Aug 2025), the platform contract that UEFI/ACPI distro boot targets**
- SBI requirements ([BRS index](https://docs.riscv.org/reference/brs/v1.0/index.html); [BRS SBI chapter](https://docs.riscv.org/reference/brs/v1.0/sbi.html)):
  - SBI ≥ v2.0 is mandatory, and so is **HSM**.
  - **TIME** is required unless Sstc is present.
  - **IPI** and **RFNC** are required unless an IMSIC is present.
  - **PMU** is required unless Sscsrind+Ssccfg are present.
  - DBCN is required if the ACPI SPCR table uses interface type 0x15.
- Rule HR_010 requires application harts to comply with **RVA20S64**. It notes OSes may impose more. BRS-I covers UEFI, ACPI and SMBIOS — [BRS hart chapter](https://docs.riscv.org/reference/brs/v1.0/hart.html)

**OpenSBI hardware requirements and feature probing**
- OpenSBI's stated platform requirements ([OpenSBI platform requirements](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/docs/platform_requirements.md)):
  - All harts need at least rv64ima_zicsr (or rv64im_zalrsc_zicsr).
  - At least one hart needs S-mode.
  - mtvec must support **Direct** mode.
  - F, D and H are optional and detected at runtime.
  - **PMP is optional**, but without it OpenSBI cannot protect M-mode firmware.
  - The **time CSR is optional**, but then a 64-bit MMIO counter must exist so it can be emulated.
  - Multi-hart systems need hardware to inject M-mode software interrupts.
- OpenSBI also probes features at boot ([lib/sbi/sbi_hart.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_hart.c)):
  - It infers the privileged-spec level by probing mcounteren, mcountinhibit and menvcfg (1.10/1.11/1.12).
  - On ≥ 1.11 it writes mcountinhibit so only cycle, time and instret run until S-mode asks for more.
  - It detects Sstc only on ≥ 1.12, by reading stimecmp, then sets menvcfg.STCE.
  - On ≥ 1.12 it sets the menvcfg enables for Zicboz, Zicbom, Svpbmt (RV64), Sstc and Smcdeleg.
  - It enables hardware A/D updating only when Svadu is present and Svade is not.
  - With Smepmp, the previous boot stage must leave mseccfg.MML clear.

**How OpenSBI consumes PMP entries**
- Detection works as follows ([sbi_hart.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_hart.c)):
  - It counts PMP entries by checking that pmpaddr0..63 are writable, stopping at the first failure.
  - It derives granularity and implemented address bits by writing all-ones to pmpaddr0.
  - If the probe traps, OpenSBI treats the hart as having no PMP.
- Root-domain contents ([lib/sbi/sbi_domain.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_domain.c)):
  - The firmware image is either one M-only RWX region, or split into text (RX) and data (RW) regions.
  - A final region spans the whole address space with S/U RWX.
  - Regions are rounded up to naturally aligned powers of two, and the root domain holds at most 32 regions.
  - Regions overlap with "smallest region wins" semantics — [OpenSBI domain docs](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/docs/domain_support.md)
- The **ACLINT MTIMER driver adds its mtime/mtimecmp MMIO as M-mode-only root-domain region(s)**: one region if the two are contiguous, two otherwise — [aclint_mtimer.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/utils/timer/aclint_mtimer.c)
- Programming behavior ([lib/sbi/sbi_hart_pmp.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_hart_pmp.c)):
  - Each region uses one PMP entry.
  - Running out prints "error: insufficient PMP entries" and the configuration fails.
  - A region smaller than the PMP grain, or beyond the implemented address bits, is skipped with a "Can not configure pmp for domain…" message.
  - The Smepmp path reserves entry 0.
  - With zero PMP entries, no protection is installed.
  - A single global sfence.vma (plus hfence.gvma with H) follows PMP programming.
- Spec rules for PMP ([Machine-Level ISA, PMP section](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)):
  - Implementations have **0, 16 or 64** PMP entries.
  - The grain is 2^(G+2) bytes, identical for all entries. NA4 is not selectable when G ≥ 1.
  - **If at least one entry is implemented, an S/U access that matches no entry fails.**
  - Implicit page-table-walk accesses are checked as S-mode.
  - After changing PMP CSRs, M-mode must execute SFENCE.VMA with rs1=x0 and rs2=x0.

**Timer and interrupt controllers**
- Timer rules in the spec ([Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)):
  - The `time` CSR is a read-only shadow of memory-mapped mtime.
  - mtime is 64-bit and increments at a constant frequency.
  - MTIP is pending while mtime ≥ mtimecmp (unsigned compare).
  - On RV64, naturally aligned 64-bit accesses to these registers are atomic.
- The Linux timer driver ([timer-riscv.c](https://raw.githubusercontent.com/torvalds/linux/master/drivers/clocksource/timer-riscv.c)):
  - With **Sstc** it writes stimecmp directly. Otherwise it makes an SBI set_timer call.
  - Sstc raises the clock-event rating from 100 to 450.
  - The clocksource is marked usable from the vDSO (arch timer), so user-space time reads can avoid a syscall.
- Mainline interrupt-controller support includes RISCV_INTC (per-hart local controller), SIFIVE_PLIC, RISCV_APLIC (+ MSI mode), RISCV_IMSIC, ACLINT_SSWI (S-mode IPI) and an RPMI system-MSI controller — [drivers/irqchip/Kconfig](https://raw.githubusercontent.com/torvalds/linux/master/drivers/irqchip/Kconfig)

**Boot flows that worked for other projects (U-Boot vs direct)**
- OpenSBI firmware types ([OpenSBI firmware docs](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/docs/firmware/fw.md); [fw_dynamic](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/docs/firmware/fw_dynamic.md)):
  - **fw_dynamic** receives next-stage info at runtime through a struct whose address is in a2.
  - **fw_jump** jumps to a fixed, compile-time next-stage address.
  - **fw_payload** embeds the next stage, and can embed an FDT via FW_FDT_PATH.
  - The previous stage passes hartid in a0 and the FDT in a1, **8-byte aligned**.
  - FW_TEXT_START defaults to 0, so it must be set to the platform's load address.
- NaxRiscv's Verilator Linux run loads `fw_jump.bin`, `linux.dtb`, `Image` and `rootfs.cpio` directly into memory. No U-Boot is involved — [NaxRiscv simulator README](https://raw.githubusercontent.com/SpinalHDL/NaxRiscv/main/src/test/cpp/naxriscv/README.md)
- Linux-on-LiteX-VexRiscv works the same way ([linux-on-litex-vexriscv](https://github.com/litex-hub/linux-on-litex-vexriscv)):
  - The LiteX BIOS loads images over serial (`boot.json`), TFTP or SD.
  - OpenSBI is built as `fw_jump` for `PLATFORM=litex/vexriscv`.
  - The DTB must match the bitstream's CSR map and memory size.
  - U-Boot is not used. Minimum RAM is 32 MB, or 8 MB with an SD or NFS rootfs.

**Buildroot**
- Buildroot exposes per-extension toggles (I/M/A/F/D/C/V plus an extra-extensions string) and the ABIs lp64, lp64f and lp64d ([Buildroot arch/Config.in.riscv](https://raw.githubusercontent.com/buildroot/buildroot/master/arch/Config.in.riscv)):
  - **lp64 has no FPU dependency.**
  - lp64d requires D, which requires F.
  - V requires GCC ≥ 12.

### Inferences

**Synthesized requirements checklist.** These are my inferences from the cited findings. M = mandatory, R = strongly recommended, O = optional, — = not required.

| Item | Phase 1: kernel + Buildroot | Phase 2: Debian/Fedora/Arch (RV64GC, RVA20) | Phase 3: Ubuntu ≥ 25.10 (RVA23) | Basis |
|---|---|---|---|---|
| RV64I + M + A, Zicsr, Zifencei, little-endian | M | M | M | hwprobe base IMA; Kconfig has no non-A option; RVA20S64 |
| C (compressed) | O (kernel needs `RISCV_ISA_C=n` and a no-C userland) | M | M (+ Zcb, Zcmop) | Kconfig; RVA20U64/RVA23U64 |
| F + D (lp64d), mstatus.FS state tracking | O (`FPU=n`, Buildroot lp64) | M | M (+ Zfa, Zfhmin) | Kconfig; Buildroot; RVA20U64; F alone is useless (masked without D) |
| M/S/U modes, medeleg/mideleg, mtvec Direct mode | M | M | M + H (Sha) | OpenSBI requirements; RVA23S64 |
| Sv39 + hardware page-table walker, correct `satp` WARL (unsupported-mode writes ignored) | M | M | M (+ Svnapot) | RVA20S64; kernel satp probing (Q4) |
| ASIDs | O (0 bits legal), R: more than 2× hart count | R | R | context.c threshold (Q4) |
| A/D: either Svade (fault) or Svadu (HW update), consistently advertised | M (one of them) | M (Svade per RVA20S64, or Svadu) | M | profiles; cpufeature/OpenSBI Svade-vs-Svadu logic |
| PMP | O (OpenSBI still boots), R: 16 CSRs, ≥ 4–8 writable entries, grain ≤ 4 KiB | R | R | OpenSBI pmp code; spec 0/16/64 rule |
| `time` CSR in hardware (shadowing mtime) | R (else trap-emulated by OpenSBI) | R | M (Zicntr) | OpenSBI requirements; vDSO uses arch timer |
| cycle/instret (Zicntr), mcounteren/scounteren, mcountinhibit | M (Zicntr assumed on DT systems) | M | M (+ Zihpm, Sscofpmf) | cpufeature; RVA20U64 |
| menvcfg/senvcfg (priv 1.12 CSRs) | R | R | M | OpenSBI gates Sstc/CBO/Svpbmt enables on ≥ 1.12 |
| ACLINT MTIMER (mtime/mtimecmp) + MSWI (M-soft IPI) or SiFive CLINT | M | M | M (Sstc additionally mandatory) | OpenSBI generic platform: timer and IPI nodes |
| Sstc | R | R | M | timer-riscv.c; RVA23S64 |
| PLIC with an S-mode context per hart (or APLIC/IMSIC) | M (practically, for UART/NIC/SD IRQs) | M | M | irqchip support; PLIC v1.0.0 |
| UART that OpenSBI and Linux both drive (e.g. ns16550a) + `stdout-path` | M | M | M | OpenSBI generic |
| SBI firmware (OpenSBI generic) with TIME, IPI, RFENCE, HSM; SRST/DBCN nice-to-have | M | M (BRS: SBI ≥ 2.0, HSM) | M | sbi.c; BRS |
| Coherent L1D between the 2 harts; LR/SC eventual success (Ziccrse); AMOs on main memory (Ziccamoa) | M (SMP) | M | M | RVA20U64; Kconfig spinlock note |
| Misaligned scalar loads/stores: trap + emulate acceptable, hardware better | O | M (Zicclsm semantics; may be emulated) | M | profiles; uabi |
| U-Boot / UEFI | — (boot ROM → OpenSBI → Image) | R (to boot distro kernels from storage via U-Boot distro boot or EFI) | R | NaxRiscv/LiteX flows; BRS |

**PMP sizing.**
- With OpenSBI's default root domain, one firmware region (or two when split RX/RW), one all-memory S/U region and one or two ACLINT-MTIMER M-only regions already use 3–5 entries. The ACLINT MSWI driver probably adds another (not verified), and Smepmp reserves one more.
- So a PMP with 8 functional entries is a practical floor, and 16 is comfortable. Fewer gives a hard boot failure ("insufficient PMP entries").
- Because the spec only allows 0, 16 or 64 entries, implementing 16 PMP CSRs where only the first N are functional is the natural low-cost option. OpenSBI's writability probe counts functional entries. That the spare entries may be read-only zero is per my reading of the spec; I did not re-check that text this session.

**Must-implement CSR plumbing:** implement menvcfg (priv-1.12 level). Without it OpenSBI will not detect Sstc and will not set the Svpbmt or CBO enable bits, even if the hardware supports them.

**Timer:** implement the `time` CSR in hardware as a shadow of the ACLINT mtime. If it is absent, every `rdtime`, including vDSO `clock_gettime` in user space, traps to OpenSBI for emulation.

**SBI firmware risks:**
- A kernel built without `RISCV_SBI_V01` running on firmware that lacks RFENCE gets remote TLB/i-cache shootdowns that silently do nothing. Use a current OpenSBI (SBI 3.0) and check the boot log lines "SBI TIME/IPI/RFENCE extension detected".
- Prefer ordered booting via HSM over spinwait.

**Phase-1 boot recipe that others proved:**
1. A reset vector in a small boot ROM puts a0 = mhartid and a1 = the DTB address (8-byte aligned).
2. It jumps to OpenSBI `fw_jump`/`fw_payload`, linked at the DRAM base.
3. OpenSBI jumps to a 2 MB-aligned `Image` with an initramfs.

On KV260 the Zynq PS could preload these images into DDR before releasing the soft core's reset. That is my inference; KV260 specifics are outside this note's scope.

### Gaps
- No OpenSBI document states a minimum PMP entry count. The 4–8 floor above is inferred from the source.
- I did not verify whether the ACLINT MSWI and PLIC drivers also add M-only PMP regions.
- I did not fetch the ACLINT spec text. It is absent from the ratified-spec library list.
- The exact DT properties that OpenSBI's PLIC/ACLINT drivers require were not extracted.
- I did not verify which SBI extensions OpenSBI's generic platform enables by default, beyond what the kernel probes.
- The web-search budget ran out before these could be searched.

---

## Q2. What do distros require (Debian, Fedora, Ubuntu RVA20/RVA22/RVA23, Alpine), and can a no-FPU core run any mainstream distro?

### Takeaway
Every mainstream binary distro needs at least RV64GC with the lp64d ABI. That is effectively RVA20U64: F, D and C are mandatory. Ubuntu raised its floor to full RVA23 starting with 25.10, which means V and the hypervisor extension (H) too; Ubuntu 24.04 LTS remains the RVA20 option. Debian 13, Fedora and Arch remain RV64GC/RVA20 as of the sources found. A core without an FPU cannot run any of these binaries. It is limited to Buildroot/Yocto-style lp64 builds.

### Cited Findings
- **RVA20U64** ([RISC-V Profiles v1.1](https://raw.githubusercontent.com/riscv/riscv-profiles/main/src/profiles.adoc)):
  - Mandatory: RV64I with fence.tso, M, A, F, D, C, Zicsr, Zicntr, Ziccif, Ziccrse, Ziccamoa, Za128rs and Zicclsm.
  - Zicclsm means misaligned loads/stores to cacheable, coherent main memory must work, but possibly via traps that "might execute extremely slowly".
- **RVA20S64** adds Zifencei, Ss1p11, Svbare, Sv39, Svade, Ssccptr, Sstvecd and Sstvala — [profiles](https://raw.githubusercontent.com/riscv/riscv-profiles/main/src/profiles.adoc)
- **RVA22** ([profiles](https://raw.githubusercontent.com/riscv/riscv-profiles/main/src/profiles.adoc)):
  - RVA22U64 adds Za64rs (replacing Za128rs), B (Zba/Zbb/Zbs), Zihpm, Zihintpause, Zic64b, Zicbom, Zicbop, Zicboz, Zfhmin and Zkt.
  - RVA22S64 adds Ss1p12, Sscounterenw, Svpbmt and Svinval.
  - Options include V, Zfh, Zkn, Zks, Sv48, Sv57, Svnapot, Sstc, Sscofpmf, Zkr and Sha.
- **RVA23** ([RVA23 profile source](https://raw.githubusercontent.com/riscv/riscv-profiles/main/src/rva23-profile.adoc)):
  - RVA23U64 adds **V**, Zvfhmin, Zvbb, Zvkt, Zihintntl, **Zicond**, Zimop, Zcmop, **Zcb**, **Zfa**, **Zawrs** and Supm to the RVA22U64 set.
  - RVA23S64 is based on privileged 1.13 (Ss1p13). It adds **Svnapot, Sstc, Sscofpmf**, Ssnpm, Ssu64xl and **Sha**: H + Ssstateen + Shcounterenw + Shvstvala + Shtvala + Shvstvecd + Shvsatpa + Shgatpa.
  - Optional S-level: Sv48, Sv57, Zkr, **Svadu**, Sdtrig, Ssstrict, **Svvptc**, Sspm.
  - "Development" options, signalled as future mandates: Zabha, Zacas, Ziccamoc, Zvbc, Zama16b.
- **Debian** ([Debian wiki RISC-V](https://wiki.debian.org/RISC-V), last modified 2026-10-07):
  - riscv64 targets an **RV64GC** hardware baseline with the **lp64d** ABI.
  - It became an official architecture in unstable on 2023-07-23, and a release architecture for trixie on 2025-05-18.
- Debian 13 "trixie" is the **first release to officially support riscv64** — [Debian 13 release notes](https://www.debian.org/releases/trixie/release-notes/whats-new.en.html). It was planned for release on 9 Aug 2025 — [Phoronix](https://www.phoronix.com/news/Debian-13-RISC-V-Ready) — and the release was reported on 11 Aug 2025 — [BetaNews](https://betanews.com/2025/08/11/debian-13-trixie-released-with-five-years-of-support-and-new-architecture-options/)
- **Ubuntu**:
  - In June 2025, Canonical planned to require **RVA23 (RVA23U64)** for 25.10. ubuntu-release-upgrader was to block upgrades past 24.04 on hardware without RVA23U64. Releases 22.04–25.04 had targeted RVA20 — [Phoronix (plan)](https://www.phoronix.com/news/Ubuntu-25.10-To-Require-RVA23); [OMG! Ubuntu](https://www.omgubuntu.co.uk/2025/06/ubuntu-riscv-rva23-support)
  - Ubuntu toolchains moved to RVA23 defaults (GCC 15.2, LLVM 20) — [Phoronix (progress)](https://www.phoronix.com/news/RISC-V-RVA23-Progress-Ubuntu)
  - Canonical's retrospective (dated 27 Feb 2026) confirms that RVA23 became the minimum starting with 25.10. RVA20 users get up to 15 years on 24.04 LTS with Ubuntu Pro. 26.04 LTS is planned as the unified RVA23 long-term baseline — [Canonical blog](https://ubuntu.com/blog/canonical-and-ubuntu-risc-v-a-2025-retro-and-looking-forward-to-2026)
  - RVA23 notably mandates both vector and hypervisor support, which leaves most existing boards on 24.04/25.04 — [Phoronix (plan)](https://www.phoronix.com/news/Ubuntu-25.10-To-Require-RVA23)
- **Fedora**:
  - A FOSDEM 2026 Fedora-on-RISC-V talk lists the current baseline as **RV64GC**. It says Fedora is waiting for a reference platform and is tracking the ISA-profile question in a planning issue — [FOSDEM 2026 slides](https://fosdem.org/2026/events/attachments/SQGLW7-fedora-on-riscv/slides/266759/fedora-ri_x3tr93d.pdf)
  - An informal Hacker News comment from someone identifying as a Fedora RISC-V worker says Fedora cannot build for both RV64GC and RVA23. Low reliability — [HN thread mirror](https://hn.nuxt.dev/item/46588159)
- **Alpine**: riscv64 has been supported since Alpine 3.20, its first stable release with riscv64 — [LF RISE wiki](https://lf-rise.atlassian.net/wiki/spaces/HOME/pages/185237505/Alpine). The Alpine wiki "Riscv64 Redo" page returned HTTP 403, so the baseline was not confirmed.
- **Arch Linux RISC-V** (community port): RV64GC baseline, lp64d ABI — [Arch Linux RISC-V](https://riscv.mirror.pkgbuild.com/)
- **No-FPU paths:**
  - The kernel can be built with `FPU=n`, which gives lp64 soft-float userspace flags — [Kconfig](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/Kconfig)
  - Buildroot supports lp64 without F/D — [Buildroot](https://raw.githubusercontent.com/buildroot/buildroot/master/arch/Config.in.riscv)
  - The kernel drops F if D is absent — [cpufeature.c](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/kernel/cpufeature.c)
  - The legacy Berkeley Boot Loader (riscv-pk) machine-mode code contains FP emulation sources (`fp_emulation.c`, `fp_ldst.c`) alongside misaligned and mul/div emulation — [riscv-pk machine/](https://github.com/riscv-software-src/riscv-pk/tree/master/machine)
  - OpenSBI's requirements list F/D only as optional, runtime-detected features. FP emulation is not mentioned — [OpenSBI platform requirements](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/docs/platform_requirements.md)

### Inferences
- **Phase 2 target = RVA20 (RV64GC + RVA20S64 semantics).** That one target covers Debian 13, Fedora, Arch, probably Alpine, and Ubuntu 24.04 LTS.
  - The extra hardware beyond phase 1 is F+D (IEEE-754 with FS tracking) and C.
  - Also needed are user-visible properties: misaligned support (trap+emulate is legal), LR/SC eventual success, AMOs on main memory, and instruction-fetch atomicity (Ziccif).
- **Ubuntu ≥ 25.10 = RVA23, which brings V and H.** That is a large step for a 2-wide soft core: vector unit, hypervisor two-stage translation, Sstc, Sscofpmf, Svnapot, Zicond, Zfa and more.
  - Treat it as a later milestone. Plan for 24.04 LTS (RVA20) as the Ubuntu target in the meantime.
  - Fedora's move is undecided; it says it is blocked on hardware and build infrastructure.
- **A no-FPU core cannot run any mainstream distro.** All of them ship lp64d binaries.
  - M-mode trap-and-emulate of F/D (as riscv-pk once did) would make the kernel believe an FPU exists and save/restore FP state with trapping instructions. It is technically possible but impractically slow.
  - OpenSBI does not provide it, so you would need custom firmware.
  - A core targeting Debian-class distros therefore needs a real F/D FPU. If phase-1 schedule pressure forces a no-FPU core, ship Buildroot lp64 first.
- **Pick 64-byte cache lines and ≤ 64-byte reservation sets** to satisfy Zic64b and Za64rs (RVA22 and later) from the start. RVA20 allows 128-byte reservation sets (Za128rs).

### Gaps
- No official Fedora decision on RVA23 or RVA22 was found.
- Alpine's riscv64 `-march` baseline was not confirmed (wiki 403, search budget exhausted).
- openSUSE was not checked.
- Whether Ubuntu's 25.10+ kernels themselves require S-mode RVA23 features (H, Sstc) at boot was not verified. The cited requirement is stated for RVA23U64 userspace.
- Debian installer requirements on boot firmware (UEFI vs U-Boot extlinux) and minimum RAM were not verified.

---

## Q3. Which extensions are worth adding to a modest OoO core for performance and compatibility, and what do they cost and buy (Zba/Zbb/Zbs, Zicond, Sstc, Svpbmt, Svinval, Svnapot, Zicbom/Zicboz/Zicbop, Zicntr/Zihpm, Sscofpmf, Zihintpause, Zkt, Zfa)?

### Takeaway
The cheap, high-value set is:
- Zba/Zbb/Zbs and Zicond (small ALU additions that compilers and the kernel use).
- Sstc (removes an M-mode round trip per timer event).
- Zicntr/Zihpm + Sscofpmf (needed for `perf record` sampling).
- Zihintpause and Zicbop (hints).
- Svinval (can reuse SFENCE machinery).
- Zkt (just "don't build an early-out multiplier").

Svpbmt, Zicbom and Zicboz are moderate cost. They matter for non-coherent DMA and fast page zeroing. Svnapot, Svadu and Zfa are second-tier. Every one of these appears in RVA22 or RVA23, so each is also a step toward Ubuntu ≥ 25.10 compatibility.

### Cited Findings
- **How the kernel uses each extension** ([Kconfig](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/Kconfig)). Most are runtime-patched via alternatives, so one kernel image runs with or without them.
  - Zba: address generation.
  - Zbb: popcount, sign-extend and rotate; it also gates the efficient-ffs assumption.
  - Zbc: CRC acceleration.
  - **Zicbom: cache-block management for non-coherent DMA**; it selects `RISCV_DMA_NONCOHERENT`.
  - **Zicboz: `cbo.zero` for faster memory zeroing.**
  - Zicbop: prefetch.
  - **Svnapot: NAPOT contiguous PTEs for larger pages**; it can cost memory with HUGETLBFS.
  - **Svpbmt: page-based memory types.**
  - **Zawrs: more efficient polling loops.**
  - Zabha/Zacas: atomics and the queued-spinlock forward-progress guarantee.
  - Supm: user pointer masking.
- The kernel's recognized-extension table also includes zicond, zihintpause, zihintntl, zimop, zfa, sstc, sscofpmf, svinval, svvptc, svadu, svade, smaia/ssaia, smcdeleg/ssccfg, zkt and others — [cpufeature.c](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/kernel/cpufeature.c)
- hwprobe exports these to user space, including Zba/Zbb/Zbs, Zicboz/Zicbom/Zicbop (with block sizes), Zicond, Zihintpause, Zfa, Zawrs, Zacas, Zkt and Zicclsm, plus a misaligned-performance class (UNKNOWN/EMULATED/SLOW/FAST/UNSUPPORTED). So glibc/ifunc-style code can exploit them — [hwprobe docs](https://docs.kernel.org/arch/riscv/hwprobe.html)
- **Sstc**:
  - With Sstc, Linux programs stimecmp directly and logs "Timer interrupt in S-mode is available via sstc extension". Without it, every timer reprogram is an SBI call — [timer-riscv.c](https://raw.githubusercontent.com/torvalds/linux/master/drivers/clocksource/timer-riscv.c)
  - OpenSBI enables it through menvcfg.STCE — [sbi_hart.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_hart.c)
  - BRS waives the SBI TIME requirement when Sstc exists — [BRS SBI](https://docs.riscv.org/reference/brs/v1.0/sbi.html)
  - It is mandatory in RVA23S64 — [RVA23](https://raw.githubusercontent.com/riscv/riscv-profiles/main/src/rva23-profile.adoc)
- **Sscofpmf** ([riscv_pmu_sbi.c](https://raw.githubusercontent.com/torvalds/linux/master/drivers/perf/riscv_pmu_sbi.c)):
  - The Linux SBI-PMU driver needs Sscofpmf overflow interrupts for sampling.
  - Without Sscofpmf (or a T-Head/Andes vendor equivalent), it logs "Perf sampling/filtering is not supported as sscof extension is not available" and offers counting only.
  - User counter access is governed by the `perf_user_access` sysctl. The default 1 enables only counters backing mmap'd perf events, and otherwise just `time`. 0 disables access, and 2 is the legacy all-of-cycle/time/instret mode.
- OpenSBI's PMU support needs a DT `riscv,pmu` node with event-to-counter mappings. Without the mapping, the SBI PMU extension is not enabled — [OpenSBI PMU docs](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/docs/pmu_support.md). OpenSBI detects writable mhpmcounters and their width at boot — [sbi_hart.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_hart.c)
- **Svinval** ([Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)):
  - SINVAL.VMA invalidates the same entries as SFENCE.VMA with the same operands.
  - SFENCE.W.INVAL and SFENCE.INVAL.IR provide the ordering before and after.
  - The in-order triple behaves like one SFENCE.VMA, which lets software batch many invalidations between two fences.
- **Svvptc**: stores that flip a PTE from invalid to valid become visible to that hart's later implicit accesses within a bounded time. The OS can then skip the SFENCE.VMA after making a PTE valid, at the cost of an occasional extra page fault — [Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
- **Svadu**: hardware A/D updating, enabled by menvcfg.ADUE. With it disabled, Svade (page faults) applies — [Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
  - Linux disables Svadu if the DT also lists Svade — [cpufeature.c](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/kernel/cpufeature.c)
  - OpenSBI turns on hardware A/D only when Svade is absent — [sbi_hart.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_hart.c)
- **Svpbmt** ([Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)):
  - Leaf-PTE bits 62–61 select PMA, NC (non-cacheable, idempotent, weakly ordered) or IO (non-cacheable, non-idempotent, strongly ordered). Value 3 is reserved and faults.
  - Non-leaf PTEs must keep these bits zero.
  - Mixed-attribute aliases need fences plus cache flushes to stay coherent.
- **Zkt** ([Scalar Cryptography chapter](https://docs.riscv.org/reference/isa/v20260120/unpriv/scalar-crypto.html)):
  - Zkt adds no instructions. It guarantees data-independent latency for a listed set: basic integer ALU ops and slt*, **mul/mulh*/mulw**, and the corresponding compressed forms. Zcb's c.mul etc. and all K-crypto instructions are also covered.
  - **Division/remainder**, loads/stores, branches, FP and CSR ops are excluded.
  - It is mandatory in RVA22U64 and RVA23U64 — [profiles](https://raw.githubusercontent.com/riscv/riscv-profiles/main/src/profiles.adoc); [RVA23](https://raw.githubusercontent.com/riscv/riscv-profiles/main/src/rva23-profile.adoc)
- **Where each extension sits in the profiles** ([profiles](https://raw.githubusercontent.com/riscv/riscv-profiles/main/src/profiles.adoc); [RVA23](https://raw.githubusercontent.com/riscv/riscv-profiles/main/src/rva23-profile.adoc)):
  - Mandatory in RVA22: B (Zba/Zbb/Zbs), Zicbom/Zicbop/Zicboz, Zihintpause, Zihpm, Zkt, Svpbmt, Svinval and Sscounterenw.
  - Mandatory in RVA23: Zicond, Zfa, Zawrs, Zcb, Svnapot, Sstc and Sscofpmf.
  - Optional in RVA23: Svadu and Svvptc.
- **Misaligned accesses**:
  - The kernel's user ABI promises that misaligned scalar accesses work in user space, though "may perform poorly". Misaligned vector accesses are supported only with Zicclsm — [uabi](https://docs.kernel.org/arch/riscv/uabi.html)
  - The default kernel config probes at boot and emulates on trap — [Kconfig](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/Kconfig)

### Inferences
The cost estimates below come from general RISC-V and microarchitecture knowledge, not from the sources above. Benefit claims are tied to the cited kernel and profile usage.

- **Tier A — add from day one (low cost):**
  - **Zba/Zbb/Zbs.** Zba is shift-and-add plus unsigned-word ops. Zbb is count leading/trailing zeros, popcount, min/max, rotates, byte-reverse/OR-combine, and sign/zero-extend. Zbs is single-bit ops. These fit in an extra ALU sub-block; clz/ctz/cpop is the largest piece.
  - **Zicond.** Two conditional-zero ALU ops. They remove hard-to-predict branches, which suits a modest branch predictor.
  - **Zkt.** A design constraint only: a fixed-latency multiplier, while the divider may early-out.
  - **Zihintpause and Zicbop.** Hint encodings that may execute as no-ops at first. Zicbop can later feed the L1 prefetcher.
  - **Svinval.** Decode the three instructions and map them onto existing SFENCE.VMA flush logic. The spec's equivalence makes a minimal implementation trivial.
  - **Sstc.** One stimecmp CSR plus a 64-bit comparator per hart, gated by menvcfg.STCE. It saves an ecall-to-M-mode-and-back per timer event, which also helps any future virtualization or SMT work.
  - **Zicntr + Zihpm + Sscofpmf.** Overflow bits, the scountovf view and the local counter-overflow interrupt. This is the only route to `perf record` sampling, which is valuable for tuning the OoO core under Linux to beat NaxRiscv IPC.
- **Tier B — add during phase 2 (moderate cost):**
  - **Svpbmt.** The LSU must honor per-page NC/IO attributes. You already need an uncached path for MMIO.
  - **Zicbom.** Clean/flush/invalidate a cache block in L1D and any L2. The kernel needs it for non-coherent DMA. On KV260 that matters if PS-side DMA masters (Ethernet/USB/SD via the PS) are not hardware-coherent with the soft core's caches; this platform assumption needs checking by whoever covers the KV260 interconnect.
  - **Zicboz.** Zero a whole 64-byte line without fetching it, which speeds kernel page clearing.
  - **Svnapot.** 64 KiB NAPOT matching in the TLBs, for better TLB reach.
  - **Svadu.** An atomic page-table-walker update of PTEs. It is moderate complexity in an OoO core because the D-bit update must be non-speculative (Q4). It removes the A/D page-fault storms that Svade causes.
  - **Zfa** (once the FPU exists).
  - **Zawrs, Zacas, Zabha.**
- **Tier C — only for an RVA23/Ubuntu ≥ 25.10 milestone:** V (+ Zvfhmin/Zvbb/Zvkt) and H (Sha) dominate the cost. Ssnpm/Supm pointer masking and Zimop/Zcmop are cheap by comparison.
- **TLB policy is free:** never cache invalid PTEs. That makes the core Svvptc-compatible and avoids a class of spurious-fault behaviors; see Q4.

### Gaps
- No quantitative source was found for the speedup or code-size benefit of Zba/Zbb/Zbs or Zicond on Linux workloads (e.g. SPEC instruction-count reductions). The search budget ran out.
- Area/timing cost figures for these extensions in FPGA soft cores were not found.
- The kernel's exact use sites for Zihintpause (cpu_relax), Svinval (TLB flush batching) and Svvptc were not verified beyond their presence in the extension table.
- Whether Zawrs instructions may legally act as plain no-ops was not verified.

---

## Q4. Which privileged-spec pitfalls trip up new cores (misaligned access, A/D bits, mtval, WFI, FS/XS dirty tracking, counter enables, interrupt priorities, PMP granularity, satp/ASID, SFENCE.VMA, physical address width, reset vector/boot ROM and DTB placement)?

### Takeaway
The commonest Linux-breaking pitfalls are:
- `satp` not ignoring writes of unsupported modes. Linux probes Sv57→Sv48→Sv39 by write-then-read.
- Wrong trap-value (mtval/stval) and delegation interactions.
- WFI not waking on locally enabled interrupts while globally disabled.
- PMP no-match semantics and granularity mismatches with OpenSBI.
- Missing SFENCE.VMA/fence.i ordering in an OoO memory system.
- A/D-bit handling.
- Subtle CSR-field WARL errors.

XiangShan's DiffTest work catalogued at least 120 static machine-mode CSR rules, plus a set of real bugs that are an excellent checklist.

### Cited Findings
- **satp and Sv-mode probing:**
  - Writing satp with an unsupported MODE has **no effect at all**: the whole write is ignored — [Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
  - Linux picks its paging mode by temporarily identity-mapping itself, writing satp with Sv57 and reading it back. If the read-back differs, it retries with Sv48, then falls back to Sv39. The mode is also capped by the `no4lvl`/`no5lvl` command-line options and DT `mmu-type` — [arch/riscv/mm/init.c](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/mm/init.c)
  - Instruction-fetch, load and store addresses under Sv39 must have bits 63–39 equal to bit 38, or a page fault occurs. A superpage whose low PPN fields are non-zero ("misaligned superpage") must raise a page fault — [Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
- **ASIDs**:
  - ASID width may be zero. Software discovers it by writing ones to the ASID field and reading back. ASIDMAX is 16 for Sv39/48/57 — [Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
  - Linux probes ASID bits the same way at boot ([arch/riscv/mm/context.c](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/mm/context.c)):
    - It enables its ASID allocator **only if the number of ASIDs exceeds twice the number of possible CPUs**.
    - Otherwise every context switch writes satp without an ASID and **flushes the whole local TLB**.
    - ASID rollover bumps a generation counter and makes every CPU flush lazily on its next switch.
- **SFENCE.VMA and speculative walks** ([Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)):
  - The rs1/rs2 = x0 form orders all page-table accesses for all address spaces. Non-zero rs2 does not order global mappings, and an invalid VA in rs1 makes the instruction a no-op without trapping.
  - **The spec permits caching PTEs whose V bit is clear**, while warning that eager caching of invalid PTEs hurts performance.
  - Writing satp does not by itself order earlier page-table stores.
  - Address translation may run speculatively at any time, but speculative walks must not set D bits or raise exceptions.
  - A PTE access that violates PMA or PMP raises an access fault.
- **A/D bits** ([Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)):
  - Under Svade, an access with A=0, or a store with D=0, raises a page fault.
  - With hardware updating, the PTE update must be atomic with respect to other accesses to that PTE.
  - **D-bit updates must be exact (non-speculative).** A-bit updates may be speculative.
- **mtval/stval:**
  - On illegal instruction, mtval holds the faulting instruction bits, truncated to the shortest of the instruction, ILEN or MXLEN, or else zero.
  - Instruction, load and store faults record the faulting virtual address.
  - A misaligned access records the VA of the portion that faulted.
  - Other traps write zero.
  - Source: [Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)
  - stval follows the same pattern. EBREAK writes either zero or the PC — [Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
  - RVA20S64 and later mandate Sstvala, which constrains these choices — [profiles](https://raw.githubusercontent.com/riscv/riscv-profiles/main/src/profiles.adoc)
- **WFI** ([Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)):
  - A hart stalled in WFI **must resume when any locally enabled interrupt is pending, regardless of the global MIE/SIE bits or mideleg**.
  - WFI may legally be a NOP, so software must loop.
  - With TW=1, WFI in lower modes traps if it does not complete within an implementation-bounded time.
- **FS/VS/XS/SD** ([Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)):
  - With F implemented, FS cannot be read-only zero.
  - FS=Off makes FP instructions illegal.
  - Dirty tracking may be imprecise (conservative), and whether a write of an unchanged value sets Dirty is implementation-defined.
  - SD summarizes Dirty status across FS, VS and XS.
- **Counter enables:**
  - When a mcounteren bit is clear, S/U-mode reads of that counter are illegal. U-mode needs both the mcounteren and scounteren bits set — [Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html); [Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
  - mtime cannot be inhibited by mcountinhibit, and a missing mcountinhibit behaves as all-zero — [Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)
  - OpenSBI inhibits HPM counters until S-mode starts them — [sbi_hart.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_hart.c)
- **Interrupt priority**: MEI > MSI > MTI > SEI > SSI > STI > LCOFI, and interrupts to M-mode outrank all lower-privilege interrupts — [Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)
- **PMP** rules are listed in Q1, from [Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html):
  - Allowed counts are 0/16/64. Grain is 2^(G+2) and NA4 is unavailable when G ≥ 1.
  - When any entry exists, an S/U access with no matching entry fails.
  - Page walks are checked as S-mode, and SFENCE.VMA is required after PMP writes.
  - OpenSBI skips any region smaller than the grain, and fails outright if it runs out of entries — [sbi_hart_pmp.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_hart_pmp.c)
- **Misaligned accesses** ([Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)):
  - Hardware may handle them or trap. An access-fault exception is allowed instead of address-misaligned, and is required for non-idempotent regions.
  - A misaligned access is atomic only within one misaligned-atomicity granule.
  - **Misaligned LR/SC always raise an exception.**
  - A misaligned store may partially complete before a later part fails PMP.
- **Reset** ([Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)):
  - M-mode is entered at reset, with mstatus.MIE = MPRV = 0.
  - The PC goes to an implementation-defined reset vector, whose location the platform spec gives.
  - misa resets to the maximal supported set. PMP A/L fields reset to 0.
  - The v1.13 text sets mstatus.MDT=1 at reset. MDT belongs to the double-trap extension, so this matters only if that extension is implemented.
  - mtvec BASE must be 4-byte aligned. Vectored mode may need stricter alignment.
- **PMAs** ([Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)):
  - Cacheability is a platform property set by M-mode.
  - Speculative or redundant accesses to non-idempotent regions are forbidden.
  - Unix-like OSes generally need page tables in cacheable main memory.
  - RsrvEventual (LR/SC eventual success) is recommended for main memory.
- **Physical address width**:
  - satp.PPN write masks differ with implemented PA width. XiangShan's DiffTest treats this as a static, configurable difference between DUT and reference — [Xu et al., JCST 2023](https://jcst.ict.ac.cn/article/doi/10.1007/s11390-023-3285-8)
  - OpenSBI measures implemented PMP address bits — [sbi_hart.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_hart.c)
  - Linux drops RAM that falls beyond its linear-map size, with a warning — [init.c](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/mm/init.c)
- **DTB, kernel and firmware placement**:
  - The DTB pointer in a1 must be 8-byte aligned — [OpenSBI fw docs](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/docs/firmware/fw.md)
  - The kernel must be 2 MB-aligned and must not map firmware/PMP memory — [boot](https://docs.kernel.org/arch/riscv/boot.html)
  - mtvec must support Direct mode for OpenSBI — [OpenSBI requirements](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/docs/platform_requirements.md)
- **Bugs that real cores shipped** (NutShell, an in-order Linux-capable RV64 core; bugs found by XFUZZ/DiffTest): ([Xu et al., JCST 2023](https://jcst.ict.ac.cn/article/doi/10.1007/s11390-023-3285-8))
  - 32-bit AMOs not sign-extending.
  - Reserved or non-writable mstatus fields writable.
  - The VA not zero-extended to 64 bits with translation off.
  - mtval/stval updated without regard to delegation.
  - mstatus.MPRV not cleared on MRET/SRET to a lower mode.
  - MPP accepting an illegal (H) value.
  - Illegal jump targets causing loads/stores to execute.
  - **Misaligned LR/SC not raising misaligned exceptions.**
  - Non-existent pmpcfg1/pmpcfg3 accessible on RV64.
  - CSRRC/CSRRCI with x0/zero-immediate causing write side effects.
  - SC wrongly setting reservations.
  - **mstatus.TVM not trapping S-mode VM operations.**
  - **Misaligned-PPN superpages not faulting.**
- **OoO-specific nondeterminism that Linux exposes** ([Xu et al., JCST 2023](https://jcst.ict.ac.cn/article/doi/10.1007/s11390-023-3285-8)):
  - The Linux kernel does not fence after allocating a new page.
  - A store updating a PTE may still sit in the store queue or buffer when the TLB walker reads memory. The OoO core then takes a page fault that an in-order ISS would not take.
  - XiangShan handles this with a diff-rule that lets the reference model take the same fault when the DUT reports it.
  - XiangShan also takes interrupts at the oldest interrupt-safe instruction. An ISS responds at the next instruction, so naive co-simulation reports false mismatches.

### Inferences
**Top pitfalls to design against** for this OoO dual-core:
1. satp must ignore unsupported MODE writes entirely, or Linux may select Sv48/57 and crash.
2. Provide ASIDs. With 2 harts, more than 4 ASIDs — at least 3 bits — are needed for Linux to use them, and 16 bits are cheap in the CSR. Make sure the TLBs honor the G bit and ASID-specific SFENCE.VMA.
3. Do not cache invalid PTEs in TLBs or page-walk caches. That avoids spurious repeated faults when Linux skips fences after making PTEs valid. Treat any residual store-buffer/PTW race as legal behavior that verification must tolerate.
4. A/D: start with Svade semantics (fault when A/D must be set) and advertise only `svade`. Add Svadu later with a non-speculative, atomic D-bit update in the walker.
5. WFI must wake on (mip & mie) ≠ 0, ignoring global enables. This is critical for the idle loop and for IPIs between the two harts.
6. Get mtval right on illegal-instruction traps. Either write the instruction bits — OpenSBI emulation runs faster — or zero.
7. Ensure delegated traps write stval, not mtval (the NutShell bug).
8. FS must turn Dirty on any FP register write. Being conservative is legal; missing it corrupts FP context across context switches.
9. Implement mcounteren/scounteren/mcountinhibit fully, and a hardware `time` CSR.
10. Use a PMP grain ≤ 4 KiB, 16 PMP CSRs with at least 8 writable, and correct no-match semantics.
11. fence.i must invalidate or flush the I-cache and the fetch pipeline. With SMP, the kernel relies on SBI remote fence.i (RFENCE) and IPIs.
12. Treat any non-idempotent IO region as never-speculative in the LSU.
13. Keep page-table walks coherent with the L1D (store-to-PTW visibility), or else rely on SFENCE.VMA draining.

### Gaps
- The Svade/Svadu and Sstvala definition text, and the misaligned-atomicity-granule (Zama16b) details, were only partially extracted. The machine and supervisor chapters were long, and only the relevant portions were read.
- No published per-core list of OoO Linux-bring-up bugs was found for BOOM, CVA6 or NaxRiscv, comparable to NutShell's list.

---

## Q5. What verification methodology took open-source cores from RTL to booting Linux (riscv-tests, riscv-arch-test, Sail/Spike, lockstep co-simulation, random generators, TestFloat, formal, litmus tests), and what lessons did BOOM, XiangShan, CVA6, NaxRiscv and Rocket learn?

### Takeaway
Every successful Linux-capable open core relied on **commit-level lockstep co-simulation against an ISA reference model**, combined with directed suites, random and fuzz tests, and Linux itself as the ultimate test. The reference models were:
- XiangShan: DiffTest with NEMU (or Spike).
- NaxRiscv/VexiiRiscv: Spike via RVLS.
- BOOM: Dromajo, and Cospike in FireSim.
- CVA6/Ibex: Spike.

The main lesson from XiangShan is that an OoO multicore needs explicit "diff-rules" for legal nondeterminism: interrupt timing, speculative page walks, weak memory, MMIO, and LR/SC. Arch-compatibility tests, now the ACT4 framework with Sail, are necessary but explicitly not sufficient.

### Cited Findings
- **riscv-tests** has four environments ([riscv-tests](https://github.com/riscv-software-src/riscv-tests)):
  - `p`: no VM, core 0 only.
  - `pm`: no VM, all cores.
  - `pt`: no VM, timer interrupt every 100 cycles.
  - `v`: virtual memory enabled.
  - Porting means providing the environment header, timeouts, and comparison of signatures against a golden model.
- **riscv-arch-test (ACT)** ([riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test)):
  - It now uses the **ACT4 framework, a Makefile/Python tool that replaces the deprecated RISCOF**.
  - Expected results come from the **Sail reference model, compatible with Sail v0.15**, and are compiled into self-checking ELFs.
  - Tests are selected from the DUT's UDB configuration file.
  - It includes privileged tests and interrupt macros, but some privileged extensions are excluded by default.
  - The README states explicitly that these are **not verification tests** and that more verification must be run.
  - Older RISC-V compatibility pages still describe RISCOF + Sail — [RVI compatibility testing page](https://riscv.atlassian.net/wiki/spaces/HOME/pages/16154825/RISC-V-Compatible+Testing+Details+for+ISA+Profiles+and+Extensions)
- **Sail RISC-V model** ([sail-riscv](https://github.com/riscv/sail-riscv)):
  - Adopted by RISC-V International; JSON-configured; simulator binary `sail_riscv_sim`.
  - It covers RV64IMAFDC, Sv32/39/48/57, Svnapot/Svpbmt/Svinval, H, V, B, Zicond, Sstc, PMP and more.
  - Its platform support is enough to **boot Linux, FreeBSD and seL4**.
  - It supports the TestRIG protocols, producing RVFI-format traces, and has been cross-tested against Spike.
- **Spike lockstep (NaxRiscv/VexiiRiscv):**
  - NaxRiscv's Verilator testbench compiles Spike as a shared object and runs it in lockstep to ensure the DUT does not diverge — [NaxRiscv simulation docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/simulation/index.html)
  - Its full regression (`make test-all`) takes **about 30 minutes, including FreeRTOS and Linux**. Verilator is pinned to 4.228 — [NaxRiscv simulator README](https://raw.githubusercontent.com/SpinalHDL/NaxRiscv/main/src/test/cpp/naxriscv/README.md)
- **RVLS** ([RVLS](https://github.com/SpinalHDL/rvls)) is SpinalHDL's Spike-based lockstep checker:
  - It consumes commit, register-file, load, store, trap, interrupt-pin and MMIO events.
  - It checks **multi-core** NaxRiscv (write-back L1D, MESI over TileLink) by keeping a per-CPU "memory view" that models when loads read and when stores become globally visible.
  - It assumes software uses fence.i for I-cache coherence and sfence for TLBs.
- VexiiRiscv is an in-order single/dual-issue core ([VexiiRiscv](https://github.com/SpinalHDL/VexiiRiscv)):
  - It uses lockstep simulation via RVLS + Spike and pipeline visualization via Konata.
  - It "can run linux / buildroot / Debian" and reports up to 5.24 CoreMark/MHz and 2.50 DMIPS/MHz.
- NaxRiscv README ([NaxRiscv](https://github.com/SpinalHDL/NaxRiscv)):
  - RV32/RV64 IMAFDCSU; out-of-order with register renaming; example config 2 decode / 3 execution units / 2 retire.
  - Hardware-refilled Sv32/Sv39 MMU.
  - "Linux / Buildroot works on hardware"; the README shows a Linux 5.10.1 boot log.
  - High-perf config: **2.93 DMIPS/MHz, 5.02 CoreMark/MHz**, 155 MHz on Artix-7.
  - Implements RISC-V External Debug Support **0.13.2** (JTAG/OpenOCD/GDB).
- **XiangShan: DiffTest + NEMU, LightSSS, XFUZZ** ([Xu et al., "Functional Verification for Agile Processor Development: A Case for Workflow Integration", JCST 38(4), July 2023](https://jcst.ict.ac.cn/article/doi/10.1007/s11390-023-3285-8)):
  - DiffTest uses "information probes" in the RTL to stream architectural events: commits, traps, CSR state, int/FP register state, write-backs, store/load/atomic events, sbuffer, refill, LR/SC.
  - It compares them per instruction against a reference model.
  - "Diff-rules" make legal nondeterminism tolerable:
    - At least **120 static rules** for machine-mode CSRs. These are implementation-defined WARL masks, e.g. satp.PPN width.
    - Dynamic rules cover asynchronous interrupts (the DUT tells the reference when to take them), speculative translation (a DUT page fault is a hint to the reference), weak memory and hardware timing.
  - For multicore, a "Global Memory" model records stores entering the memory system. Each single-core reference is checked against it and updated when they legally disagree under RVWMO.
  - XFUZZ (coverage-guided fuzzing) found **33 NutShell bugs** that real workloads and AFL++ missed.
  - A dual-core XiangShan **L2-cache bug surfaced only after more than 168 hours of Redis simulation (about 3 billion cycles)**. It was diagnosed using the ChiselDB transaction database plus LightSSS waveforms.
- The MICRO 2022 paper "Towards Developing High Performance RISC-V Processors Using Agile Methodology" describes the same toolset (design, functional verification, debugging, performance). It was an IEEE Micro Top Pick — [XiangShan publications](https://xiangshan-doc-old.readthedocs.io/tutorials/publications/)
- XiangShan's current README:
  - Runs `--diff` against a NEMU interpreter shared object.
  - Adds `xspdb`, a Python debugger with commit-PC watchpoints.
  - Builds the Verilator emu with `EMU_THREADS`.
  - Recommends the `kunminghu-v2` branch for downstream work.
  - Source: [XiangShan README (kunminghu-v3)](https://cdn.jsdelivr.net/gh/openxiangshan/xiangshan@kunminghu-v3/README.md)
- NEMU is described as XiangShan's **golden model** in reference mode ([NEMU](https://github.com/OpenXiangShan/NEMU)):
  - ISA rv64gcbhk currently, with vector "in the near future". The xs defconfig enables RVH and RVV.
  - In standalone mode it produces SimPoint BBVs and checkpoints.
- **BOOM/Chipyard/FireSim:**
  - Dromajo is Esperanto's RV64GC emulator "designed for RTL co-simulation" ([Dromajo](https://github.com/chipsalliance/dromajo)):
    - It is based on TinyEMU and models ISA 2.3 / priv 1.11.
    - It offers a cosim library/API, and checkpoint save/load for HW/SW co-simulation.
  - Chipyard documents Dromajo co-simulation for BOOM using trace-IO config fragments — [Chipyard 1.5.0 Debugging BOOM](https://chipyard.readthedocs.io/en/1.5.0/Advanced-Concepts/Debugging-BOOM.html)
  - FireSim's Dromajo bridge checks BOOM functionally at FPGA speed. It is **"highly experimental" and single-core only** — [FireSim Dromajo docs](https://firesim.readthedocs.io/en/latest/Advanced-Usage/Debugging-and-Profiling-on-FPGA/Dromajo.html)
  - FireSim also integrated a Spike-based "Cospike" bridge — [FireSim cospike-integration merge (mirror)](https://cdn05042023.gitlink.org.cn/replica/firesim/commit/dee9a783338e506275d06b5a21e365e0d652567d). FireSim documentation seen in search snippets says it supports only single-core BOOM with commit width 1 or 2; that page was not fetched.
- **Rocket-era riscv-torture** ([riscv-torture](https://github.com/ucb-bar/riscv-torture)):
  - It generates random interleavings of hand-written sequences.
  - It dumps a register "signature" at test end, diffs Spike against RTL, and auto-minimizes failing tests.
  - Its README dates from 2012 and lists FP/vector/loop support as TODO.
- **CVA6 and core-v-verif:**
  - CVA6's `verif/` holds a riscv-dv-based simulation environment and riscv-tests p/v test lists ([CVA6 verif README](https://github.com/openhwgroup/cva6/blob/master/verif/README.md)):
    - Default `DV_SIMULATORS=veri-testharness,spike`.
    - Default target `cv64a6_imafdc_sv39`.
    - UVM environment `uvmt_cva6`. The verification plan and coverage flow are VCS-only.
  - OpenHW's core-v-verif covers CV32E40P/X/S and CVA6 — [core-v-verif](https://github.com/openhwgroup/core-v-verif)
- **Ibex (lowRISC)** ([Ibex verification docs](https://ibex-core.readthedocs.io/en/latest/03_reference/verification.html)):
  - UVM testbench with riscv-dv, plus random interrupt and debug agents.
  - Compares register write-back traces against Spike (built with commit log and misaligned support).
  - Its status is V2S: over 90% code/functional coverage with over 90% regression pass rate.
  - It notes OVPsim was dropped because it does not support Ibex's co-simulation approach.
- **riscv-dv** ([riscv-dv](https://github.com/chipsalliance/riscv-dv)):
  - SV/UVM generator, now under CHIPS Alliance, covering RV32/64IMAFDC in M/S/U.
  - Features include page-table randomization and exceptions, an MMU stress suite, privileged CSR tests, trap/interrupt handling, and a randomized debug ROM.
  - Co-simulation ISSs: Spike, riscv-ovpsim, Whisper and Sail.
  - It **requires a SystemVerilog/UVM-1.2 simulator** (VCS, Xcelium, Questa or Riviera-PRO). A `pygen` directory exists.
- **FORCE-RISCV** ([FORCE-RISCV](https://github.com/openhwgroup/force-riscv)):
  - Python-templated instruction-sequence generator for RV64G/RV32G + V 1.0, with full M/S/U switching.
  - Supports Sv48/Sv39/Sv32 paging with page-size options, non-trivial exception handlers, and multi-thread generation.
  - Uses the Spike-based Handcar ISS. Its user manual is a work in progress.
- **riscv-formal** ([riscv-formal](https://github.com/YosysHQ/riscv-formal)):
  - SymbiYosys-based; the core must expose the RVFI interface.
  - It focuses on formal models of all RV32I/RV64I instructions; checks for memory buses, CSRs and the B extension were added under Sandia funding.
  - It describes itself as work in progress. Example cores include PicoRV32 and NERV.
- **Memory-model litmus testing** ([litmus-tests-riscv](https://github.com/litmus-tests/litmus-tests-riscv)):
  - The RISC-V Memory Model Task Group's litmus suite was generated with diy plus hand-written tests.
  - It runs on herd (axiomatic) and rmem (operational "Flat"); the two models differ on 7 LR/SC tests.
  - It runs on hardware via the `litmus` tool. "Negative differences" mean the hardware showed RVWMO-forbidden behavior.
  - Full hardware runs take **days to weeks**.
- **FPU** ([TestFloat](http://www.jhauser.us/arithmetic/TestFloat.html)):
  - Berkeley TestFloat **Release 3e (Jan 2018)** compares an FP implementation against SoftFloat.
  - It covers all IEEE-754-1985 operations except decimal conversions, in half/single/double/extended/quad, all rounding modes, plus FMA and unsigned conversions.
  - It is weaker on hard division/square-root rounding cases and SRT-specific bugs.

### Inferences
**Recommended stack** (inference from what demonstrably worked):
1. **Directed:** riscv-tests (p/pm/pt/v) on every commit. ACT4 arch tests with Sail 0.15 for compatibility evidence, not as verification.
2. **Commit-level lockstep co-simulation** is the core of the strategy.
   - Expose an RVFI-like retire port carrying up to the retire width per cycle (≥ 2). Include rd/rs values, PC, instruction, trap/interrupt cause, mtval, CSR writes, memory address/data, MMIO flag, SC result, and store-commit events for global memory.
   - Use Spike as the reference: it is current on extensions, used by NaxRiscv, VexiiRiscv, Ibex, CVA6 and FireSim, and RVLS shows the multicore memory-view pattern. Alternatively use NEMU via DiffTest; it is fast and already has OoO diff-rules.
   - Dromajo's modelled spec level (priv 1.11, RV64GC) is behind RVA22/23 extensions.
   - Implement XiangShan-style diff-rules from day one:
     - The DUT tells the reference when to take an interrupt.
     - DUT page faults are accepted as hints.
     - MMIO read values are copied from the DUT.
     - SC failures follow the DUT.
     - Multicore uses a global-memory oracle.
     - WARL masks are configured statically.
3. **Random and fuzz tests:**
   - riscv-dv needs a commercial SV simulator. If the flow is open-source and Verilator-only, prefer FORCE-RISCV (Python + Handcar) or a coverage-guided fuzzer in the XFUZZ style.
   - riscv-torture-style signature tests are a cheap supplement.
   - Weight generation towards privileged/MMU corners. The NutShell bug list in Q4 is a good seed list.
4. **FPU:** run TestFloat on the FPU in isolation, at unit level, before system integration. Add directed div/sqrt hard-rounding tests.
5. **Formal:** use riscv-formal (via RVFI) for decode, ALU and CSR instruction-semantics checks. Use SymbiYosys block-level proofs for OoO structures such as free list, ROB commit, LSQ ordering and TLB invalidation. Full-core OoO+MMU formal is not something these tools claim to do.
6. **Memory model:** run a subset of litmus-tests-riscv in RTL simulation of the dual-core under the lockstep checker. Run the full suite on the FPGA under Linux (days to weeks) and watch for "negative differences".
7. **System:** Linux + Buildroot boot in simulation as a regression; NaxRiscv's full regression including Linux is about 30 minutes. Then long-running FPGA workloads, since XiangShan's worst bug needed about 3 billion cycles.

### Gaps
- No primary source was retrieved confirming CVA6's exact Spike "tandem" (RVFI step-and-compare) mechanism or Linux-boot regression.
- Esperanto/BOOM published lessons on Dromajo cosim were not found.
- Rocket's current verification flow beyond riscv-tests/torture was not retrieved.
- Coverage numbers for NaxRiscv were not found.
- The ACT4 test-coverage details for Sv39/PMP/interrupts were not enumerated.
- The web-search budget ran out before searching for formal verification of Ibex against Sail and for XiangShan litmus results.

---

## Q6. How fast is RTL simulation, how long does Linux take to boot in it, what checkpoint/restore techniques exist, and what FPGA-side debug works (Vivado ILA, commit-trace buffers, RISC-V Debug 0.13/1.0 via BSCANE2 + OpenOCD)?

### Takeaway
Verilator runs single-issue cores at tens to hundreds of kHz, but OoO cores at only about 1–10 kHz. XiangShan (6-issue) runs at about 0.9 kHz single-thread, or 3.3 kHz with 8 threads. Even with LightSSS-style fork snapshots and ISS checkpoints, Linux boots in RTL take minutes to hours, and long workloads take days. GSIM claims about 7× over Verilator on XiangShan. Teams therefore pair fast-ISS checkpoints with RTL restore and move long runs to FPGA (FireSim-style).

On FPGA, a RISC-V Debug 0.13.2/1.0 module tunnelled through a Xilinx BSCANE2 USER chain with OpenOCD `riscv use_bscan_tunnel` works. On Zynq UltraScale+ (KV260) there are three known traps:
- The PS TAP/ARM DAP shares the chain and adds a 1-bit delay.
- The USER opcodes differ from 7-series.
- Vivado's ILA/VIO already occupies USER1.

### Cited Findings
- **Verilator speeds** (booting Linux, Intel i9-9900K, single-threaded Verilator): ([GSIM, arXiv 2508.02236](https://arxiv.org/html/2508.02236v1))
  - stuCore (in-order) about 900 kHz.
  - Rocket about 30 kHz.
  - **BOOM (3-issue OoO) about 9 kHz.**
  - **XiangShan (6-issue OoO) about 0.9 kHz.**
- **GSIM** ([GSIM](https://arxiv.org/html/2508.02236v1)):
  - It reports **7.34× over Verilator for XiangShan Linux boot** and 19.94× for Rocket CoreMark.
  - It averages 3.72× over 1-thread Verilator, and about 1.18× over 8-thread Verilator, for XiangShan SPEC2006.
  - Emission/compile time for XiangShan was 374.6 s with Verilator and 389.1 s with GSIM.
  - Besides Verilator, only GSIM simulated XiangShan; ESSENT and Arcilator failed on some designs.
  - These are the authors' own claims, with no independent reproduction found.
- **XiangShan/NutShell in Verilator** ([JCST 2023](https://jcst.ict.ac.cn/article/doi/10.1007/s11390-023-3285-8)):
  - NutShell: **843.7 kHz** single-thread (58.8k lines of generated C++); CoreMark in 10 s; Linux boot in 5 minutes.
  - XiangShan: **3.3 kHz with 8 threads** (15.2M lines of C++); CoreMark in 8 minutes; Linux boot in 18 minutes.
  - **Turning on waveforms drops XiangShan simulation to about 8.5% of normal speed.**
- NEMU's README says XiangShan Verilator runs of checkpoints take "from hours to days", against 6 minutes to 1 hour on XS-GEM5 — [NEMU](https://github.com/OpenXiangShan/NEMU)
- **Checkpoint/restore:**
  - **NEMU flow** ([NEMU](https://github.com/OpenXiangShan/NEMU)):
    - Boot Linux in NEMU for SimPoint profiling (BBVs), cluster them, then boot again to produce checkpoints.
    - Checkpoints are restored in M-mode by the "GCPT restorer" and run with `emu -i checkpoint.gz`.
    - Do not take checkpoints in M-mode.
  - **Dromajo** can generate checkpoints after N instructions or cycles and resume them for HW/SW co-simulation — [Dromajo](https://github.com/chipsalliance/dromajo)
- **LightSSS** ([JCST 2023](https://jcst.ict.ac.cn/article/doi/10.1007/s11390-023-3285-8)):
  - The simulator periodically calls `fork()`. Copy-on-write makes each child an incremental snapshot, and at most 2 are kept.
  - On a mismatch, the second-to-last snapshot re-runs with waveforms on.
  - Overhead is **under 1%** even at a 1-second interval, against 10–20% for the earlier LiveSim.
  - In the L2-bug case, re-simulating the last 30.8k cycles with waveforms took 3 minutes. The paper contrasts this with an extra 16 hours using LiveSim, or 168 hours re-running from scratch.
- **NaxRiscv simulation aids** ([NaxRiscv simulator README](https://raw.githubusercontent.com/SpinalHDL/NaxRiscv/main/src/test/cpp/naxriscv/README.md)):
  - Bounded FST traces with start/stop times, and "sporadic" periodic trace slices.
  - gem5/Konata pipeline traces and stats windows.
  - A `--sim-master`/`--sim-slave` pair, where a delayed second simulation records traces when the master crashes. This is similar in spirit to LightSSS.
  - Periodic speed printing.
- **FPGA-accelerated simulation**:
  - FireSim claims cycle-exact simulation at **"10s to 100s of MHz"** for Rocket/BOOM/Chipyard SoCs, fast enough to interact with Linux — [FireSim](https://github.com/firesim/firesim)
  - Its Dromajo bridge streams BOOM commits to a host-side Dromajo for checking. It is experimental and single-core only — [FireSim Dromajo docs](https://firesim.readthedocs.io/en/latest/Advanced-Usage/Debugging-and-Profiling-on-FPGA/Dromajo.html)
- **RISC-V Debug spec:**
  - **v1.0 was ratified 2025-02-21.** It is almost entirely forward- and backward-compatible with v0.13; the incompatible changes are listed in its introduction — [Debug spec v1.0](https://docs.riscv.org/reference/debug/v1.0/index.html); [introduction](https://docs.riscv.org/reference/debug/v1.0/introduction.html)
  - QEMU documents Debug 1.0 support starting with QEMU 11.2, via the `sdtrig` flag — [QEMU RISC-V debug](https://www.qemu.org/docs/master/specs/riscv-debug.html)
- **OpenOCD** ([OpenOCD manual](https://openocd.org/doc/html/Architecture-and-Core-Commands.html)):
  - Its RISC-V target "primarily supports" Debug **0.13**, plus legacy 0.11. The manual does not mention 1.0.
  - `riscv use_bscan_tunnel width [type]` enables a BSCAN tunnel to the Debug Module. Width is the DM transport TAP's IR width; type 0 is NESTED_TAP (default) and 1 is DATA_REGISTER.
  - The tunnel scans USER4 into the Xilinx TAP, then encapsulates DR scans. The protocol is described as SiFive-specific and poorly documented.
  - `riscv set_bscan_tunnel_ir` targets non-Xilinx devices. `riscv set_ir` exists because BSCANE2 permits only limited IR values.
- **VexRiscv BSCANE2 example** ([VexRiscv BSCANE2 doc commit (mirror)](https://software.mcgoron.com/Hardware/VexRiscv/commit/52a2e889d054f0bb9d7047af74c4ce6f58a48cae)):
  - Hardware side: a BSCANE2 with USER4, tunnelling without its own TAP, and debug/JTAG clock domains reset separately from the CPU.
  - OpenOCD side: the stock Xilinx 7-series config, a RISC-V target on the FPGA TAP, then `riscv use_bscan_tunnel 6 1`.
- **Zynq UltraScale+ specifics** (Rocket on an Edgeboard ZU device, debugged through BSCAN): ([jsteward blog](https://jsteward.moe/risc-v-hardware-design-part-b-edgeboard-series.html))
  - **USER4** was used because the default USER1 is taken by on-board tools: **ILA, JTAG-to-AXI master, VIO**.
  - **UltraScale+ USER opcodes are 0x920–0x923, not 0x20–0x23**, so OpenOCD had to be patched.
  - The PL TAP (IR 6) and PS TAP (IR 6) are chained, for a combined IR of 12.
  - An **ARM DAP adds a 1-bit shift**. This caused a 1-TCK input delay, fixed in the Chisel tunnel translator, and a 1-TCK output delay, fixed in OpenOCD.
  - The Xilinx `hw_server` had to be stopped to avoid USB conflicts.
  - The motivation was that every boot-ROM change otherwise meant up to an hour of re-synthesis.
- Linux-on-LiteX-VexRiscv's JTAG helper **rejects Zynq/ZynqMP devices with "delayed BSCAN TDI"** — [linux-on-litex-vexriscv](https://github.com/litex-hub/linux-on-litex-vexriscv)
- NaxRiscv implements Debug 0.13.2 over JTAG with OpenOCD/GDB — [NaxRiscv](https://github.com/SpinalHDL/NaxRiscv)
- **Trace standards** (for later commit-trace hardware): E-Trace v2.0 (Jun 2025), N-Trace v1.0 (Nov 2024), Trace Connectors/Control v1.0 (Nov 2024), HART Trace Interface v1.0 (Sep 2026) — [RISC-V Ratified Specifications Library](https://docs.riscv.org/reference/home/index.html)

### Inferences
- **Budget for slow Linux simulation.**
  - At about 3–10 kHz, which is plausible for a 2-wide OoO dual-core under multithreaded Verilator, 100 M cycles take about 3–9 hours, and 1 B cycles take about 1–4 days.
  - So use these practices:
    - A tiny "sim-Linux" config: minimal drivers, tiny initramfs, `lpj=` preset, no SMP-calibration delays, low HZ.
    - LightSSS-style fork snapshots, since the cost is under 1%.
    - Bounded or sporadic waveform windows only, because waveforms cost about 12×.
    - ISS-generated checkpoints restored into RTL for anything past early boot.
  - The JCST numbers are internally hard to reconcile. 18 min at 3.3 kHz is only about 3.6 M cycles, while 5 min at 843.7 kHz is about 253 M cycles. That suggests different Linux workloads or images, so treat "Linux boot in N minutes" claims as workload-specific.
- **A fast, equivalent alternative to cycle simulation is FPGA-in-the-loop co-simulation.** Stream the retire trace (FireSim Dromajo/Cospike pattern) from the KV260 PL to the A53 PS running Spike or an RVLS-like checker. This is a natural fit for the Zynq PS and is my inference. Back it with an on-chip ring buffer holding the last N retired instructions, readable over AXI from the PS or via ILA, for post-mortem when a hang occurs.
- **KV260 debug plan:**
  - Implement a Debug-0.13.2-compatible DM. It is the version OpenOCD primarily supports, and v1.0 is nearly identical, so it is upgradable.
  - Put the DTM behind BSCANE2 USER4 (USER1 is left to ILA/VIO).
  - Budget engineering time for the ZynqMP PS-TAP/DAP chain quirks: the extra 1-bit delay and the UltraScale+ USER opcodes, possibly patching OpenOCD or the tunnel translator as the Edgeboard author did.
  - Alternatively, route a separate PL JTAG over PMOD/GPIO pins. The Edgeboard author avoided that only because of cabling.
- **Pin the tool versions** (NaxRiscv pins Verilator 4.228). Expect Verilator emission times of minutes for large OoO designs; XiangShan's was 375 s.

### Gaps
- No published Verilator Linux-boot wall-clock times were found for BOOM, CVA6 or NaxRiscv. GSIM gives speeds but not durations, and NaxRiscv gives only the 30-minute full-regression figure.
- No multi-threaded Verilator scaling data for BOOM-class designs was retrieved. GSIM only plots normalized "2T" results.
- The current Vivado ILA capture-depth and resource guidance for UltraScale+ (AMD UG908/UG936) was not fetched.
- Whether upstream OpenOCD now handles the ZynqMP DAP 1-bit delay without patches was not verified.
- Whether any open core already implements E-Trace/N-Trace encoders suitable for FPGA was not checked; the search budget had run out.
