#!/usr/bin/env python3
"""cache-prune: the checking tools' hash-keyed build caches, $TANAGER_BUILD/cycle-identical/build and
boot-lockstep/build, trimmed as each tool trims its own after its builds (cycle_identical.prune_cache): from the most
recently used, builds are kept while they number at most 40 and come to at most 15 GB, and the older ones go, never
one a check holds or is building, nor one used or changed in the last hour. Lock files without a build go after a day.
boot-lockstep's finished builds that still hold their sources lose them first, as its own trim does.

  python3 tools/ci/cache_prune.py [--dry-run]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cycle_identical as ci  # noqa: E402  (prune_cache, TB)
import boot_lockstep as bl  # noqa: E402  (drop_sources)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="say what would go and remove nothing")
    a = ap.parse_args()
    for name in ("cycle-identical", "boot-lockstep"):
        bdir = os.path.join(ci.TB, name, "build")
        if not os.path.isdir(bdir):
            continue
        if name == "boot-lockstep":
            n, size = bl.drop_sources(bdir, dry_run=a.dry_run)
            print(f"cache-prune: {name}/build: {'would drop' if a.dry_run else 'dropped'} the sources of {n} finished "
                  f"build(s) ({size / 2**30:.2f} GB)", flush=True)
        print(f"cache-prune: {name}/build: {ci.prune_cache(bdir, dry_run=a.dry_run)}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
