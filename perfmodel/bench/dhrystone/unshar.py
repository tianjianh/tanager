"""Extracts Dhrystone 2.1 from netlib's shell archive without executing it.

The archive stores each file as:  sed >NAME <<'//GO.SYSIN DD NAME' 's/^-//'  followed by lines that
start with '-', ending at the line //GO.SYSIN DD NAME.
"""
import re
import sys
from pathlib import Path


def unshar(archive: Path, out_dir: Path, wanted: set[str]) -> list[str]:
    out_dir.mkdir(parents=True, exist_ok=True)
    lines = archive.read_text(encoding="latin-1").splitlines()
    start = re.compile(r"^sed >(\S+) <<'(//GO\.SYSIN DD \S+)' 's/\^-//'$")
    written = []
    i = 0
    while i < len(lines):
        m = start.match(lines[i])
        i += 1
        if not m:
            continue
        name, end = m.group(1), m.group(2)
        body = []
        while i < len(lines) and lines[i] != end:
            body.append(lines[i][1:] if lines[i].startswith("-") else lines[i])
            i += 1
        i += 1
        if name in wanted:
            (out_dir / name).write_text("\n".join(body) + "\n", encoding="latin-1")
            written.append(name)
    return written


if __name__ == "__main__":
    files = unshar(Path(sys.argv[1]), Path(sys.argv[2]), {"dhry.h", "dhry_1.c", "dhry_2.c"})
    print("extracted:", " ".join(sorted(files)))
    if len(files) != 3:
        sys.exit(1)
