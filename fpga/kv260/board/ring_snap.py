"""Snapshot the commit-trace ring from DDR (read only) and write its records oldest first.

Usage: sudo python3 ring_snap.py RING_PA LOG2 WRITTEN OUT
RING_PA and LOG2 from `tanager-host trace status`; WRITTEN is its "written" count at about the
same moment (the newest record is WRITTEN-1, at slot (WRITTEN-1) mod 2^LOG2). The ring keeps
changing while the cores run, so the oldest slots may already hold newer records.
"""
import mmap
import os
import sys

pa, log2, written, out = int(sys.argv[1], 0), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
n = 1 << log2
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(fd, n * 64, mmap.MAP_SHARED, mmap.PROT_READ, offset=pa)
data = bytes(m[:n * 64])
m.close()
os.close(fd)
start = written % n          # the oldest record's slot
with open(out, "wb") as f:
    f.write(data[start * 64:] + data[:start * 64])
print(f"{n} records from {pa:#x}, oldest first from slot {start}, to {out}")
