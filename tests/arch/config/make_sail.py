#!/usr/bin/env python3
"""Writes each Tanager ACT4 configuration's sail.json (docs/spec/verification.md §6.1).

Each one starts from the framework's RVA20S64 reference (config/sail/sail-RVA20S64/sail.json in the
pinned riscv-arch-test checkout) and applies the overrides below, so the differences are explicit:
Tanager's memory map (tg_map_pkg), its extensions, and its WARL choices, which must also match Spike
(the lockstep checker) and the core.

  ~/opt/tanager/act-venv/bin/python make_sail.py [--arch-test ~/src/tanager/riscv-arch-test]
"""
import argparse
import copy
import json
import os

import pyjson5

HERE = os.path.dirname(os.path.abspath(__file__))


def region(base, size, kind):
    """A memory region of tg_map_pkg: 'mem' (PMA_MEM), 'rom' (PMA_ROM) or 'io' (PMA_DEVICE)."""
    attrs = {
        "mem_type": "MainMemory" if kind == "mem" else "IOMemory",
        "cacheable": kind != "io",
        "coherent": True,
        "executable": kind != "io",
        "readable": True,
        "writable": kind != "rom",
        "read_idempotent": kind != "io",
        "write_idempotent": kind != "io",
        "misaligned_exceptions": {"load_store": {"Some": "AlignmentException"}, "vector": {"None": None},
                                  "amo": "AlignmentException", "lrsc": "AlignmentException"},
        "atomic_support": "AMOArithmetic" if kind == "mem" else "AMONone",
        "misaligned_atomicity_granule_size_exp": 0,
        "vector_misaligned_atomicity_granule_size_exp": 0,
        "reservability": "RsrvEventual" if kind == "mem" else "RsrvNone",
        "supports_cbo_zero": kind == "mem",
        "supports_pte_read": kind == "mem",
        "supports_pte_write": kind == "mem",
    }
    return {"base": {"len": 64, "value": hex(base)}, "size": {"len": 64, "value": hex(size)},
            "attributes": attrs, "include_in_device_tree": kind == "mem"}


# tg_map_pkg (plan §5.4). RAM size matches tests/arch/config/link.ld.
REGIONS = [
    region(0x02000000, 0x10000, "io"),        # ACLINT
    region(0x0C000000, 0x4000000, "io"),      # PLIC (and the simple interrupt generator)
    region(0x10000000, 0x1000, "io"),         # UART
    region(0x10001000, 0x1000, "io"),         # host control
    region(0x10010000, 0x4000, "io"),         # virtio
    region(0x11000000, 0x10000, "io"),        # debug
    region(0x80000000, 0x10000000, "mem"),    # DRAM (256 MiB used by the tests)
]

ALL_OFF = ["A", "F", "D", "S", "H", "B", "V"]  # extensions with a "supported" flag in "extensions"


def tanager(c, *, user, sup, pmp, zexts, letters="M", mutable="", hpm=False, usable=None, counters=0):
    """Common Tanager settings. `zexts`: the Z* and S* extensions that are supported; `letters`: the
    single-letter extensions among A, B, M, F, D (C follows Zca); `mutable`: the misa bits software may
    clear, as in Spike (its write mask is M, A, B, C, F, D, Q, H, V within the ISA); `usable`: the PMP
    entries that work, the rest of the `pmp` implemented ones reading zero (default: all); `counters`: M9's programmable
    counters from mhpmcounter3 (TG_HPM, sim/profile.mk's HPM=1: 4, with Sscofpmf in `zexts`), or none (they read zero)."""
    b = c["base"]
    # mcountinhibit: CY and IR (and the HPM counters when they exist); bit 1 is read-only zero
    b["mcountinhibit"] = {"supported": True, "writable_bits": {"len": 32, "value": "0xFFFF_FFFD" if hpm else "0x0000_0005"}}
    b["writable_fiom"] = sup
    # M9's counters (mhpmcounter3.., their mhpmevent's event field 8 bits beside Sscofpmf's OF and mode inhibits); without
    # them Spike's mhpmcounters read zero
    hc = ((1 << counters) - 1) << 3
    b["writable_hpm_counters"] = {"len": 32, "value": f"0x{hc >> 16:04X}_{hc & 0xFFFF:04X}" if counters else "0x0"}
    if counters:
        b["hpmevent_width_bits"] = 8
    cen = "0xFFFF_FFFF" if hpm else "0x0000_0007"
    b["scounteren_writable_bits"] = {"len": 32, "value": cen if sup else "0x0"}
    b["mcounteren_writable_bits"] = {"len": 32, "value": cen if user else "0x0"}
    b["hcounteren_writable_bits"] = {"len": 32, "value": "0x0"}
    b["mtvec"] = {"direct": {"supported": True, "base_alignment": 2},
                  "vectored": {"supported": True, "base_alignment": 2}}
    b["mstatus"] = {"fs_legal_states": "ExtContext_FourState" if sup else "ExtContext_Off",
                    "vs_legal_states": "ExtContext_Off"}
    b["privileged_isa_version"] = "Privileged_ISA_1_13"  # Spike's (e.g. medeleg's hardware-error bit)
    if sup:
        # Spike's masks: medeleg causes 1-9, the page faults (12, 13, 15) and hardware error (19, with
        # Zicntr), plus misaligned fetch (0) only without C; mideleg SSIP, STIP, SEIP.
        b["medeleg"]["delegatable_bits"] = {"len": 64, "value": "0x0000_0000_0008_B3FE" if "Zca" in zexts
                                            else "0x0000_0000_0008_B3FF"}
        b["mideleg"]["delegatable_bits"] = {"len": "xlen", "value": "0x2222" if counters else "0x222"}  # LCOFI with them
    m = c["memory"]
    m["physaddr_bits"] = 34
    m["pmp"] = {"grain": 0, "count": pmp, "usable_count": pmp if usable is None else usable, "tor_supported": pmp > 0,
                "na4_supported": pmp > 0, "napot_supported": pmp > 0}
    # Misaligned accesses trap with address-misaligned, AMOs and LR/SC included (Spike without Zicclsm).
    for k in ("load_store", "amo", "lrsc"):
        m["misaligned"]["exceptions"][k] = {"Some": "AlignmentException"}
    # Sail keeps its own boot ROM and device tree at 0x1000 (the reference's first region); the
    # tests never touch Tanager's boot ROM there.
    m["regions"] = [m["regions"][0]] + REGIONS
    p = c["platform"]
    p["clint"]["size"] = 0x10000
    # Without S-mode, Spike and Tanager allow WFI in U-mode (mstatus.TW = 0).
    p["wfi_available_to_user_mode"] = user and not sup
    if "A" in letters:
        # Za64rs: Spike reserves the 64-byte block of the LR's address; stores do not cancel it.
        p["reservation"] = {"reservation_set_size_exp": 6, "require_exact_reservation_addr": False,
                            "invalidate_on_same_hart_store": False}
    e = c["extensions"]
    for k in ALL_OFF:
        e[k]["supported"] = k in letters
    for k in "MABCFD":
        e[k]["mutable_misa"] = k in mutable
    if "F" in letters:
        # Spike dirties mstatus.FS whenever an instruction raises a flag, even one already set.
        e["F"]["fflags_dirty_policy"] = "Fflags_Dirty_Flag"
    e["M"]["supported"] = True
    e["U"]["supported"] = user
    e["S"]["supported"] = sup
    for k, v in e.items():
        if isinstance(v, dict) and k[0] in "ZS" and len(k) > 1 and "supported" in v:
            v["supported"] = k in zexts
    return c


# Zmmul stays off in Sail: Spike's ISA strings have no zmmul, so clearing misa.M makes MUL illegal too.
BASE_Z = ("Zicntr", "Zicsr", "Zifencei")


def tcore(c):
    """tg_tcore: RV64IM, Zicsr, Zicntr, Zifencei; M and U; no PMP, no HPM counters; misa.M writable
    (verification.md §5)."""
    return tanager(c, user=True, sup=False, pmp=0, zexts=BASE_Z, mutable="M")


def core_m2(c):
    """tg_core at M2: RV64IM, M-mode only, 16 PMP entries, misa.M writable (core-pipeline.md §9.1)."""
    return tanager(c, user=False, sup=False, pmp=16, zexts=BASE_Z, mutable="M")


M3_Z = BASE_Z + ("Zaamo", "Zalrsc", "Zca", "Zba", "Zbb", "Zbs", "Zicond", "Zihintpause", "Zihpm", "Zkt",
                 "Ziccamoa", "Ziccif", "Ziccrse", "Sstc", "Svinval", "Sv39", "Svade", "Svbare",
                 "Ssccptr", "Sstvala", "Sstvecd",
                 "Ssstrict")  # Sail allows Ssstrict only with S; without S its defaults trap the same way


def core_m3(c):
    """tg_core at M3 before its F/D integration: the plan's day-one ISA without F and D. RV64IMAC, Zba,
    Zbb, Zbs (B), Zicond, Zihintpause, Zihpm (counters read zero), Zkt; M, S and U with Sv39, Svade,
    Sstc, Svinval; 16 PMP entries. misa M, A, B and C are writable, as in Spike."""
    return tanager(c, user=True, sup=True, pmp=16, zexts=M3_Z, letters="MAB", mutable="MABC", hpm=True)


def core_m3_fd(c, usable=None):
    """tg_core at M3 with F/D (plan §11): the plan's day-one ISA, RV64IMAFDC with Zcd; misa F and D
    are writable too, as in Spike."""
    return tanager(c, user=True, sup=True, pmp=16, zexts=M3_Z + ("Zcd",), letters="MABFD", mutable="MABCFD",
                   hpm=True, usable=usable)


def core_m3_fd_p8(c):
    """The same with DR-167's 8 PMP entries (PMP_ENTRIES=8): the architecture's 16 implemented, 8 to 15
    reading zero, as in Spike with --pmp=8."""
    return core_m3_fd(c, usable=8)


def core_m3_fd_hpm(c, usable=None):
    """The same with M9's performance counters on (TG_HPM, sim/profile.mk's HPM=1; DR-190): mhpmcounter3 to 6 writable
    and counting their mhpmevent's event (8 bits), Sscofpmf's OF and mode inhibits, scountovf and LCOFI (delegatable)."""
    return tanager(c, user=True, sup=True, pmp=16, zexts=M3_Z + ("Zcd", "Sscofpmf"), letters="MABFD", mutable="MABCFD",
                   hpm=True, usable=usable, counters=4)


def core_m3_fd_p8_hpm(c):
    """The counters with DR-167's 8 PMP entries (HPM=1 on the default core)."""
    return core_m3_fd_hpm(c, usable=8)


CONFIGS = {"tcore-rv64im": tcore, "core-m2-rv64im": core_m2, "core-m3-rv64imac": core_m3,
           "core-m3-rv64imafdc": core_m3_fd, "core-m3-rv64imafdc-p8": core_m3_fd_p8,
           "core-m3-rv64imafdc-hpm": core_m3_fd_hpm, "core-m3-rv64imafdc-p8-hpm": core_m3_fd_p8_hpm}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arch-test", default=os.path.expanduser("~/src/tanager/riscv-arch-test"))
    a = ap.parse_args()
    with open(os.path.join(a.arch_test, "config/sail/sail-RVA20S64/sail.json")) as f:
        base = pyjson5.decode(f.read())
    for name, fn in CONFIGS.items():
        c = fn(copy.deepcopy(base))
        out = os.path.join(HERE, name, "sail.json")
        with open(out, "w") as f:
            f.write(f"// Generated by tests/arch/config/make_sail.py from ACT4's sail-RVA20S64 reference; edit the script.\n")
            json.dump(c, f, indent=2)
            f.write("\n")
        print("wrote", out)


if __name__ == "__main__":
    main()
