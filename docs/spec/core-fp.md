# F and D in the core (`EXT_FD`, M3)

Status: core side built behind `EXT_FD` (off by default), not yet wired to the FP back end — core track — 2026-10-14

The FPU track owns the FP back end (docs/spec/fpu.md, "Core integration (P4 back end)"):
- `tg_fp_exec`, port P4 from the issue grant onward, with `tg_fprf` and `tg_fpu` inside it;
- `tg_fcsr`, which holds `frm` and `fflags`.

This page covers the core's side of that contract. With `EXT_FD` off, none of this logic exists and the core behaves as an RV64IMAC core.

## Decode (`tg_decode`)
- **When F/D encodings are legal:**
  - FLW, FLD, FSW and FSD, FMADD/FMSUB/FNMSUB/FNMADD, and OP-FP;
  - only with `misa.F` (and `misa.D` for D) and `mstatus.FS` ≠ Off, as Spike.
- **Rounding mode:** resolved at decode (DYN → `frm`). A reserved mode, or DYN while `frm` ≥ 5, is illegal in an instruction that rounds. Every CSR write ends in a flush, so the `frm` that decode sees is the architectural one.
- **Fields in `dec_t`:**
  - register flags `rs1_fp`, `rs2_fp`, `rd_fp`, plus `rs3`;
  - `fop`, `fmt`, `src_fmt`, `ifmt` and `rm`;
  - `fp_int`: an FP op with an integer result;
  - `fp_div`: the divide/sqrt unit.
- **Class:** `C_FP` for every OP-FP and FMA op. FP loads and stores keep `C_LD` and `C_ST`.
- **`f0`:** a real register, so `rd_en` is never cleared for an FP `rd`.

## Rename (`tg_rename`, `tg_rmap`)
- **FP map:** a second `tg_rmap`. Like the integer map, it is in LUTRAM with live-value tables and versioned recovery (core-pipeline.md §5.2). Each slot reads `rs1`, `rs2`, `rs3` and `rd`.
- **Producer fields:** the FP map's producer field is the wakeup column only. Every FP result has one, and no FP producer is a 1-cycle op, so FP sources never use MX.
- **Physical FP registers:** {bank, index}, in the low bits of `preg_t` fields.
  - **F0:** written by P4's results. Its free list starts with indices 32–63; f0–f31 map to F0 0–31 after reset, written with zero by the reset sequence.
  - **F1:** written by FP loads. Its free list holds 0–63.
- **FP ready table:** one bit per FP physical register. It is set by F0 writes (from P4) and F1 writes (FP loads), and cleared when rename allocates the register.
- **Sources:** `src1` and `src2` come from whichever file their flag names. `src3` is always FP. The intra-group bypass compares the register file as well as the number.
- **Destinations:**
  - an FP result takes F0;
  - an FP load takes F1;
  - an FP op with an integer result takes bank 1, written through the bank-1 slots (below).
- **Wakeup columns (AR-1):**
  - FMA and FMISC ops with an FP result take a wakeup tag;
  - divides, square roots, FP→int ops and FP loads take an LLT. An FP→int op with `rd` = x0 takes none, but still carries an LLT's column, as P4 expects.
  - P4 wakes FMA and FMISC results; the core wakes FP→int results and FP loads.
- **Credits:** FP divides are held to `FDIV_INFLIGHT` and FP→int ops to `FPI_INFLIGHT` in flight. Each count is the sum of two parts:
  - the uops renamed but not yet issued; a flush drops these;
  - those issued but not yet returned (`fdiv_done`, `fpi_pop`). P4 returns every operation it was issued, flushed or not.
  So a flush can never leak a credit.

## Issue (`tg_issue`, `tg_iq`)
- **IQ-FP:** `IQ_FP` rows, in the shared woken vector. Its payload is exactly what P4 reads, with the three source tags early (in flip-flops).
- **`fmisc_block`:** a registered output of P4. While it is high, FMISC rows with an FP result are not selected, because the F0 slot three cycles after an FMA is taken. Each row keeps one bit saying whether it is such an op (`tg_iq` `CBLK`).
- **Integer sources:**
  - IQ-FP's dependencies on 1-cycle integer producers resolve only when the producer's row is freed, 2 cycles after its select, because IQ-FP gets no `mx_issued`.
  - P4 reads the integer source from the register file in its RF stage. The ALU writes the register file at the end of s+3, before any later RF stage, so there is no bypass into P4's integer source.
  - This costs +2 cycles on int→FP moves of in-flight ALU results, about 0.4% of FP sources in the census (area_recovery.md §5.4).

## Execute (`tg_exec`) and the LSU (`tg_lsu`)
- **Shared integer read port:** P4's integer source (FCVT.F.I, FMV.F.X) reads it first. The LSU's store-data capture of integer stores waits that cycle (`sd_busy`).
- **FP→int results:** they leave P4's queue like a finished divide.
  - The head claims a bank-1 write slot 4 cycles ahead, after any MUL in RF and any divide claim that cycle, and blocks A1's select.
  - It wakes its LLT a cycle before the write.
  - It is written in its slot (`fpi_ready`) and completes its ROB entry with its fflags. A flush cancels a pending claim.
- **FP loads:**
  - They write F1 through P4 straight from the load result register (`fld_*`); P4 NaN-boxes FLW.
  - The write is announced at M2 for P4's bypass.
  - The LQ keeps an FP load's F1 index and takes its bytes unextended.
- **FP stores:**
  - Their data comes from the FP file's store-data port (`fsd_*`). FSW stores bits 31:0.
  - Their readiness comes from the FP ready table at dispatch, and from FP register writes snooped afterwards.

## ROB, commit and CSRs (`tg_rob`, `tg_csr`)
- **Flags:** five fflag bits per ROB entry, from P4's F0 completions and from FP→int completions. At commit they go to `tg_fcsr` with "wrote an f register" (`cm_fflags`, `cm_rd_fp`).
- **Commit:** `cm_rd_fp` steers the committed map update and the freed register to the FP map and free lists.
- **Trace:** the commit trace's `rd_fp` names the file; the value is read from the FP file's trace ports.
- **CSRs:**
  - `fflags`, `frm` and `fcsr` are illegal while FS is Off. They are read from `tg_fcsr` and written to it at retirement.
  - FS becomes Dirty on `tg_fcsr`'s pulse (an f register written, flags accumulated) and on fcsr writes.
  - `misa.F` and `misa.D` exist with `EXT_FD`. Software may clear them as in Spike, and D needs F; with F clear, the F/D encodings are illegal.

## Still to do
- `tg_fp_exec` and `tg_fcsr` in `tg_core`:
  - the payload conversion;
  - the F0 writes into the FP ready table, with tags returned 2 cycles after their write;
  - the FP trace reads;
  - the reset sequence's zeros into F0 0–31.
- The simulation's ISA string with F and D, the `rv64uf`/`rv64ud` riscv-tests, ACT4 `core-m3-rv64imafdc`, and random rv64gc in lockstep.
