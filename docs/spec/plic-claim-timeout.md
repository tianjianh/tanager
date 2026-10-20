# A claim timeout for the PLIC's level sources (plan)

For the coordinator, before any RTL (soc-2, 10-20). It is a mitigation for SD1's lost interrupt in RISC-V mode, not
the fix.
- **What's wrong:** the board's capture (boot 54's shutdown) shows PLIC source 21 claimed and never completed. SD1's
  line is high, pending is 0, the source is enabled on hart 0's S context at priority 1 with threshold 0, and the
  probe's complete brought the I/O back.
- **Why a mitigation:** the mechanism is still being hunted ([soc.md](soc.md) §8.2, SD1's interrupt under stress).
  This keeps the board from hanging meanwhile. It goes behind a switch, off by default.

## What it does

- **The rule:** a level source that is claimed (the gateway's busy flag) while its line stays high is counted.
  - At `T` it is treated as completed: busy clears, the gateway pends it again the next cycle, and the context
    takes it again.
  - The count stops and clears whenever the line is low or the source isn't claimed. So a handler that has
    cleared its device never times out, however late its complete comes.
- **`T`:** 2^23 core cycles, 84 ms at 100 MHz (parameter `CLAIM_TMO_LOG2`).
  - One shared prescaler of 2^16 cycles, plus 7 bits per source.
  - It is built for the level sources only: the edge sources (the machine-error sources, 16 and up) never time
    out. All 31 sources would be 217 flops; the five PS sources alone, 35.
- **The switch:** `PLIC_CLAIM_TMO`, a `tg_uncore` parameter from `build.tcl` (`TG_PLIC_CLAIM_TMO=1`). Off leaves
  `tg_plic` as it is: no logic, every build identical.
- **Visible, not silent:** a read-only word in the PLIC's unused range at `0x0C1F_F000` gives:
  - `[15:0]` how many timeouts have fired (saturating);
  - `[20:16]` the last source to fire;
  - `[31]` set once any has fired.

  The board's probe reads it, so a run that needed the timeout says so. A write clears it.

## A handler that is merely slow

- **Linux's claim lasts only as long as a hardirq handler.**
  - `plic_handle_irq` claims, runs the handler and completes, with interrupts off on that CPU: microseconds.
  - A threaded handler (`IRQF_ONESHOT`) is masked by priority and completed right after its primary handler, so
    its claim window is short too.
  - A hardirq handler running for 84 ms would already raise RCU stall warnings.
- **If it ever happened:** the timeout pends the source again; the slow handler returns and completes it (busy is
  already clear, so nothing changes); the CPU takes the second delivery once interrupts are back on.
  - If the handler had cleared its device, as every Linux handler does before returning, the line was low and the
    timeout never fired, because the count needs the line high.
  - If the line is still high, the device still wants service, and the second delivery is a real one, as any
    level interrupt would be.
- **So the cost is at most one spurious delivery** to a handler that ran past `T` with its device still asserting.
  Linux counts that and goes on (disabling a line needs 99,900 of 100,000 unhandled).

## What the spec deviation costs

- **The spec:** a gateway forwards no new request for a source until it receives that source's completion. This
  forwards one after `T` with the line high. Linux, OpenSBI and U-Boot never hold a claim that long.
- **Lockstep:** Spike doesn't model the PLIC. A claim read is a device value, which the checker already takes from
  the trace, so a second delivery checks like any other interrupt. In simulation the timeout never fires
  (`T` = 8.4M cycles of a held claim with the line high), so `tb_boot`, the regressions and cycle-identical don't
  change with the switch on, and trivially with it off.
- **The tests:**
  - `tests/unit/periph`: a claimed level source held past a short `T` with its line high pends again and is
    claimed again. The same with its line low never fires. An edge source never fires. The status word counts,
    and a write clears it.
  - The test that fails on the old RTL: the same bench without the switch keeps the source claimed forever, which
    is the board's state.
- **Area:** 35 to 217 flops and their LUTs, in the uncore.

## What it doesn't fix

- **The cause.** Something on the way between the core and the PLIC lost a claim's completion. If it's a read
  value lost in the core's MMIO path, the same fault on another register (an SD status read) would show as an I/O
  error, not a hang. The status word is the guard against hiding it: the hunt goes on with the timeout on, and
  any firing is a data point.
- **An enable or priority lost:** the PLIC can't know Linux's intent. The capture rules this out for the case seen.
