#!/usr/bin/env python3
"""Forward references from Verilator's JSON dump (tools/ci/fwdref.sh runs it; from the core track's
fwdref, 2026-10-17; DR-150, docs/spec/verification.md §4.3):
   verilator --json-only --json-only-output T.json --json-only-meta-output M.json <lint args> --top-module <top>
   fwdref.py T.json M.json [path-prefix ...]            (default prefix rtl/)
Lists every reference to a module-level signal or parameter from a line above its declaration in the
same file (Verilator links the later declaration; nothing in simulation shows it). Classes:
  IMPLICIT NET  a whole name in an instance's port connection: Vivado makes a new undriven net. Inside a
                generate block it is the block's own (Synth 8-11241, 8-605, 8-3848: rn_fire, the board's
                two-core hang); at module scope the later declaration then meets it (8-11241, 8-8895:
                de_state, dbg_sel);
  generate      another use inside a generate block (Vivado resolves it upward, Synth 8-6901);
  module scope  another use: Vivado resolves it (Synth 8-6901).
Exit 1 if any IMPLICIT NET, else 0."""
import json, sys
tree = json.load(open(sys.argv[1]))
files = json.load(open(sys.argv[2]))["files"]
prefixes = sys.argv[3:] or ["rtl/"]
def floc(loc):
    f, rest = loc.split(",", 1)
    return f, int(rest.split(":", 1)[0])
var = {}       # addr -> (name, file id, line, at module level)
refs = []      # (name, varp, file id, line, generate path, whole name in a port connection)
def walk(n, gen, top, pin):
    if isinstance(n, list):
        for v in n: walk(v, gen, top, pin)
        return
    if not isinstance(n, dict): return
    t = n.get("type")
    if t == "MODULE": gen, top, pin = (), True, False
    if t == "VAR" and "loc" in n:
        f, l = floc(n["loc"])
        var[n["addr"]] = (n.get("name"), f, l, top and not gen)
    if t == "VARREF" and "loc" in n and n.get("varp", "UNLINKED") != "UNLINKED":
        f, l = floc(n["loc"])
        refs.append((n.get("name"), n["varp"], f, l, gen, pin))
    for k, v in n.items():
        if k in ("type", "name", "addr", "loc"): continue
        if t == "GENBLOCK":
            walk(v, gen + (n.get("name") or "genblk",), top, False)
        elif t in ("FUNC", "TASK"):
            walk(v, gen, False, False)
        elif t == "PIN" and k == "exprp":
            # a whole name (the expression is the VARREF itself) is what Vivado declares implicitly
            whole = isinstance(v, list) and len(v) == 1 and isinstance(v[0], dict) and v[0].get("type") == "VARREF"
            walk(v, gen, top, whole)
        else:
            walk(v, gen, top, False if t not in (None,) and t != "PIN" else pin)
walk(tree, (), True, False)
out = {}
for name, vp, f, l, gen, pin in refs:
    v = var.get(vp)
    if not v: continue
    vname, vf, vl, vtop = v
    if not vtop or vf != f or l >= vl: continue
    fn = files.get(f, {}).get("filename", f)
    if not any(fn.startswith(p) for p in prefixes): continue
    where = ".".join(gen)
    if pin:
        kind = "IMPLICIT NET " + ("in " + where if gen else "at module scope")
    else:
        kind = "generate " + where if gen else "module scope"
    key = (fn, l, name, vl)
    if key not in out or kind.startswith("IMPLICIT"): out[key] = kind
for (fn, l, name, vl), kind in sorted(out.items()):
    print(f"{fn}:{l}: '{name}' used before its declaration at line {vl} ({kind})")
nimp = sum(1 for k in out.values() if k.startswith("IMPLICIT"))
print(f"{len(out)} forward references, {nimp} implicit nets in Vivado")
sys.exit(1 if nimp else 0)
