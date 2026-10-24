# Unit specifications

Every RTL unit has a spec here before its RTL is written (plan §2.3, conventions §7). The specs are the clean-room record: they say what the unit does, how, and where each idea came from.

- **Cross-track contracts:** [interfaces.md](interfaces.md).
- **Coding, build and collaboration rules:** [conventions.md](conventions.md).
- **The area measures and how to turn them off on a bigger chip:** [area_switches.md](area_switches.md).
- **Every firmware setting below Debian (OpenSBI, U-Boot, the device trees, the kernel command line, the KV260's boot chain):** [firmware_switches.md](firmware_switches.md).

## Template

```markdown
# <unit name> (`tg_<module>`)

Status: draft | reviewed | implemented — owner track — date

## Purpose
One paragraph: what the unit does and where it sits (plan section references).

## Interface
Ports and structs (point to the package types); handshake and timing (which outputs are
registered, latency from each input).

## Behaviour
State, algorithms, corner cases, ordering rules. Diagrams welcome.

## Parameters
Which tg_pkg parameters size it; what must hold for the 2-wide, 3-wide and SMT2 builds.

## Timing and area
Target levels of logic in the critical path at 200 MHz; LUT/FF/BRAM/DSP estimate against
the plan §8.2 budget; the fallback if timing fails.

## Verification
Unit test plan (directed and random), assertions, formal properties, what lockstep covers.

## Provenance
Every borrowed idea: paper, public specification or documentation, with a citation.
No other core's RTL was read for this unit.
```
