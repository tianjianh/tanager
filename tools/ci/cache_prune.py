#!/usr/bin/env python3
"""cache-prune: the checking tools' hash-keyed build caches, $TANAGER_BUILD/cycle-identical/build and
boot-lockstep/build, trimmed as each tool trims its own after its builds (cycle_identical.prune_cache): from the most
recently used, builds are kept while they number at most 40 and come to at most 15 GB, and the older ones go, never
one a check holds or is building, nor one used or changed in the last hour. Lock files without a build go after a day.

  python3 tools/ci/cache_prune.py [--dry-run]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cycle_identical as ci  # noqa: E402  (prune_cache, TB)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="say what would go and remove nothing")
    a = ap.parse_args()
    for name in ("cycle-identical", "boot-lockstep"):
        bdir = os.path.join(ci.TB, name, "build")
        if os.path.isdir(bdir):
            print(f"cache-prune: {name}/build: {ci.prune_cache(bdir, dry_run=a.dry_run)}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
