// Unit test of the harness's MMIO read check (mmio_read_check_t, tlmodels.h; DR-176; verification.md §2.4): `make -C sim unit`.
// The cases the regressions cannot reach yet: sources per hart (M7 step 5) and SOLO_TID's source 1.
#include <cstdio>
#include "tlmodels.h"
using namespace tg;
static int fails = 0, total = 0;
static void expect(bool ok, const char* what, const std::string& e) {
  printf("%-4s %-58s %s\n", ok ? "ok" : "FAIL", what, e.c_str());
  total++;
  if (!ok) fails++;
}
int main() {
  { mmio_read_check_t c; c.threads = 2;   // one hart, source 0: reads and retirements alternate
    c.read(0, 10, 0x200bff8); expect(c.retire(0, 0x100).empty(), "one hart, source 0, read then retire", "");
    c.read(0, 20, 0x200bff8); c.read(0, 30, 0x2004000);   // the first was squashed and the handler read next
    std::string e = c.retire(0, 0x104); expect(!e.empty(), "squashed read caught at the next retirement", e); }
  { mmio_read_check_t c; c.threads = 2;   // SOLO_TID: hart 0's reads come with source 1
    c.read(1, 10, 0x200bff8); expect(c.retire(0, 0x100).empty(), "SOLO_TID: hart 0 on source 1", "");
    c.read(1, 20, 0x200bff8); expect(c.retire(0, 0x104).empty(), "SOLO_TID: second read", "");
    c.read(1, 30, 0x200bff8); std::string e = c.exit(0); expect(!e.empty(), "SOLO_TID: a read left at exit", e); }
  { mmio_read_check_t c; c.threads = 2;   // two harts, one source: the check stops, never a false stop
    c.read(0, 10, 0x200bff8); expect(c.retire(0, 0x100).empty(), "one source: hart 0", "");
    c.read(0, 20, 0x200bff8); c.read(0, 25, 0x200bff8);
    expect(c.retire(1, 0x200).empty() && !c.on, "one source: hart 1 stops the check", "");
    expect(c.exit(0).empty(), "one source: exit after the stop", ""); }
  { mmio_read_check_t c; c.threads = 2;   // two harts, sources 0 and 1: reads interleave, each matched per hart
    c.read(0, 10, 0x200bff8); c.read(1, 12, 0x2004008);
    expect(c.retire(1, 0x200).empty(), "two sources: hart 1 retires first", "");
    expect(c.retire(0, 0x100).empty(), "two sources: then hart 0", "");
    c.read(1, 20, 0x200bff8); c.read(0, 21, 0x200bff8); c.read(1, 30, 0x200bff8);   // hart 1's first was squashed
    expect(c.retire(0, 0x104).empty(), "two sources: hart 0 unaffected", "");
    std::string e = c.retire(1, 0x204); expect(!e.empty(), "two sources: hart 1's squashed read caught", e);
  }
  { mmio_read_check_t c; c.threads = 2;   // exit: only the exiting hart's reads must have retired
    c.read(0, 10, 0x200bff8); c.read(1, 12, 0x200bff8);
    expect(c.retire(1, 0x200).empty(), "exit: hart 1 retires its read", "");
    expect(c.exit(1).empty(), "exit: hart 1 exits while hart 0's read is out", "");
    std::string e = c.exit(0); expect(!e.empty(), "exit: hart 0's own read still out at its exit", e); }
  { mmio_read_check_t c; c.threads = 2;
    std::string e = c.retire(0, 0x100); expect(!e.empty(), "a load retired with no read at all", e); }
  printf("mmio read check (unit): %d passed, %d failed\n", total - fails, fails);
  return fails != 0;
}
