# Where a unit's LUTs and flip-flops sit, by the signal they belong to (spikes §8.18's follow-up, the coordinator 10-21:
# where hart 1's LUTs went). For each <label>=<dcp>, and each unit of core 0 named in UNITS: every LUT, flip-flop and
# LUTRAM cell at or below the unit, grouped by family. A cell inside a submodule instance belongs to that instance
# (its name kept whole, indices included, so per-thread copies stay apart). The unit's own cells are named for the
# signal they drive or hold, with bit indices folded to [], and _i_N, _INST_0, _reg and replication suffixes removed.
# Writes groups_<label>.tsv: unit, family, LUTs, flip-flops, LUTRAM sites. Compare two with cell_groups_diff.py.
# Post-synthesis checkpoints built with -flatten_hierarchy none keep the units apart (h100_hn0, h100_hz0).
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_cell_groups.tcl <label=dcp>...       (about 5 GB)
set UNITS {u_fetch u_rn u_lsu u_csr u_rob}
set CORE "u_soc/g_core\[0\].g_tgc.u_core/"
proc fam {rel} {
  set i [string first / $rel]
  if {$i >= 0} { return "[string range $rel 0 [expr {$i - 1}]]/" }
  set n $rel
  set n [regsub {_INST_0(_i_\d+)?(__\d+)?$} $n {}]
  set n [regsub {(_i_\d+)+(__\d+)?$} $n {}]
  set n [regsub {_rep(lica)?(_\d+)?(__\d+)?$} $n {}]
  set n [regsub {(__\d+)+$} $n {}]
  set n [regsub -all {\[\d+\]} $n {[]}]
  set n [regsub {_reg(\[\])*$} $n {\1}]
  set n [regsub {_reg$} $n {}]
  return $n
}
foreach arg $argv {
  lassign [split $arg =] label dcp
  open_checkpoint $dcp
  set fs [open groups_$label.tsv w]
  foreach u $UNITS {
    set pre "${CORE}${u}/"
    set cnt [dict create]
    foreach {cls filt} {lut {REF_NAME =~ LUT*} ff {REF_NAME =~ FD*} ram {REF_NAME =~ RAMD* || REF_NAME =~ RAMS*}} {
      foreach c [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}* && ($filt)"] {
        set f [fam [string range [get_property NAME $c] [string length $pre] end]]
        dict update cnt $f v { if {![info exists v]} { set v {0 0 0} }; lset v [lsearch {lut ff ram} $cls] [expr {[lindex $v [lsearch {lut ff ram} $cls]] + 1}] }
      }
    }
    dict for {f v} $cnt { puts $fs [join [concat [list $u $f] $v] "\t"] }
    flush $fs
  }
  close $fs
  close_design
}
puts "Q_CELL_GROUPS_DONE"
