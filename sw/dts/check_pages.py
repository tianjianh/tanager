#!/usr/bin/env python3
"""Every MMIO range in a Tanager device tree must cover whole 4 KiB pages (soc.md §4, "PMP regions: whole pages").

OpenSBI gives each device it uses (its console, the reset syscons, the ACLINT, the PLIC) a PMP region of that device's
reg range. Until DR-182 a region smaller than 4 KiB, or one not on a 4 KiB boundary, cleared the core's "every 4K page
is PMP-homogeneous" flag (tg_csr pmp_al), so no 4K page cached its PMP result in the TLB: on the board that cost -23.6%
on a store loop and +10% on rdtime (RISC-V mode's memory gap, docs/spec/soc-d4-modes.md). Since DR-182 it costs only its
own page's cached result; the rule stays, as it costs nothing. So this checks every
reg with a size: its base and its size are multiples of 4 KiB. Nodes whose reg has no size (cpus, MDIO PHYs) are skipped.
  check_pages.py <tree.dtb>...        exit status 1 and one line per range at fault
"""
import re
import subprocess
import sys

PAGE = 0x1000


def cells(text):
    return [int(c, 16) if c.startswith("0x") else int(c) for c in text.split()]


def check(dtb):
    dts = subprocess.run(["dtc", "-q", "-I", "dtb", "-O", "dts", dtb], check=True, capture_output=True,
                         text=True).stdout
    bad = []
    stack = []          # per open node: [path, #address-cells, #size-cells] (the cells its children use)
    for line in dts.splitlines():
        s = line.strip()
        m = re.match(r"^([^\s=;{}]+)\s*\{$", s)
        if m:
            name = m.group(1)
            path = "/" if name == "/" else (stack[-1][0].rstrip("/") + "/" + name)
            stack.append([path, 2, 1])          # the spec's defaults until the node says otherwise
            continue
        if s.startswith("};"):
            stack.pop()
            continue
        if not stack:
            continue
        m = re.match(r"^#(address|size)-cells = <(.+)>;$", s)
        if m:
            stack[-1][1 if m.group(1) == "address" else 2] = cells(m.group(2))[0]
            continue
        m = re.match(r"^reg = <(.+)>;$", s)
        if m and len(stack) >= 2:
            ac, sc = stack[-2][1], stack[-2][2]     # the parent's cells describe this node's reg
            if sc == 0:
                continue
            v = cells(m.group(1))
            for k in range(0, len(v) - ac - sc + 1, ac + sc):
                base = 0
                for c in v[k:k + ac]:
                    base = (base << 32) | c
                size = 0
                for c in v[k + ac:k + ac + sc]:
                    size = (size << 32) | c
                if base % PAGE or size % PAGE or size == 0:
                    bad.append(f"{dtb}: {stack[-1][0]}: reg 0x{base:x} size 0x{size:x} is not whole 4 KiB pages")
    return bad


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        return 2
    bad = []
    for f in sys.argv[1:]:
        bad += check(f)
    for b in bad:
        print(b)
    if bad:
        print("check_pages: OpenSBI would make a PMP region smaller than a page, which costs every 4K page its cached "
              "PMP result in the core (-23.6% on a store loop, +10% on rdtime; soc.md §4): give the node its whole page")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
