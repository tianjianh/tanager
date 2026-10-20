# Fetch's worst paths in routed checkpoints, out-of-context cores or full chips (the coordinator, 10-20: before M7's
# step 5b adds the thread select to F1). Per checkpoint and core, the worst path of each fetch family:
#   icache  from the I$ data RAMs (u_fetch/g_way*, block RAM): F2's cone, by endpoint family
#   tage    from TAGE's table RAMs (u_fetch/g_tage.u_tage/g_tab*): by endpoint family
#   fpc     from fetch's PC register (u_fetch/fpc_q)
#   head    from the instruction queue's head (u_fetch/u_cmp/head_q)
# with its slack, levels, logic and wire, and its chain: each cell on the path (type and name, indices dropped) and
# each hop's fanout and net delay. Every clock's setup uncertainty is taken back first. Writes fetch_paths.txt (the
# summary) and fetch_paths.rpt (the full report of each family's worst path).
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_fetch_paths.tcl <label=routed.dcp>...   (about 5 GB)
proc fam {name pre} {
  set n [string range $name [string length $pre] end]
  set n [regsub {/xpm_memory_base_inst/.*$} $n {/xpm}]
  set n [regsub {/(RAM[A-H](_D1)?|mem_reg_[0-9_]+)(/[A-Z]+)?$} $n {}]
  set n [regsub -all {\[\d+\]} $n {[]}]
  set n [regsub -all {_rep(lica)?(_\d+)?(__\d+)?} $n {}]
  set n [regsub {_reg(\[\])*(/[A-Z0-9]+)?$} $n {}]
  set n [regsub {/[A-Z][A-Z0-9_]*$} $n {}]
  return $n
}
proc cell_of {pin} { return [join [lrange [split $pin /] 0 end-1] /] }
proc chain {p pre} {
  # the report's data path: each cell's type and name, each net's fanout and delay
  set out {}; set inpath 0
  foreach ln [split [report_timing -of_objects $p -return_string] "\n"] {
    if {[string match "*Location*Delay type*" $ln]} { set inpath 1; continue }
    if {!$inpath} { continue }
    if {[string match "*required time*" $ln] || [string match "*(clock * rise edge)*" $ln] && [llength $out] > 2} { break }
    if {[regexp {\s([A-Z0-9_]+)\s+\(Prop_[^)]*\)} $ln -> t]} { lappend out "<$t>"; continue }
    if {[regexp {net \(fo=(\d+), routed\)\s+([0-9.]+)\s+[0-9.]+\s+(\S+)} $ln -> fo d nm]} {
      lappend out [format "%s(fo%s,%.2f)" [fam $nm $pre] $fo $d]
    }
  }
  return [join $out " "]
}
set fs [open fetch_paths.txt w]
set fr [open fetch_paths.rpt w]
foreach arg $argv {
  lassign [split $arg =] label dcp
  open_checkpoint $dcp
  foreach c [get_clocks] { set_clock_uncertainty -setup 0 $c }
  puts $fs "== $label: $dcp (WNS [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]])"
  if {[llength [get_cells -quiet u_fetch]]} { set pres [list ""] } else {
    set pres [list "u_soc/g_core\[0\].g_tgc.u_core/" "u_soc/g_core\[1\].g_tgc.u_core/"]
  }
  foreach pre $pres {
    puts $fs "  -- core [expr {$pre eq {} ? {(out of context)} : $pre}]"
    set srcs [list \
      icache [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_way* && PRIMITIVE_GROUP == BLOCKRAM"] \
      tage   [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_tage.u_tage/g_tab* && PRIMITIVE_GROUP == BLOCKRAM"] \
      fpc    [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/fpc_q_reg* && IS_SEQUENTIAL"] \
      head   [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/u_cmp/head_q_reg* && IS_SEQUENTIAL"]]
    foreach {kind src} $srcs {
      if {![llength $src]} { puts $fs "    $kind: no cells"; continue }
      set ps [get_timing_paths -quiet -setup -from $src -max_paths 3000 -nworst 1 -unique_pins -slack_lesser_than 2.0]
      set w [dict create]; set wp [dict create]; set n [dict create]
      foreach p $ps {
        set e [fam [cell_of [get_property NAME [get_property ENDPOINT_PIN $p]]] $pre]
        dict incr n $e
        set sl [get_property SLACK $p]
        if {![dict exists $w $e] || $sl < [dict get $w $e]} { dict set w $e $sl; dict set wp $e $p }
      }
      set rows {}
      dict for {e sl} $w { lappend rows [list $e $sl] }
      set rows [lsort -real -index 1 $rows]
      puts $fs "    $kind: [llength $ps] endpoints below 2.0 ns in [llength $rows] families"
      set k 0
      foreach r $rows {
        if {[incr k] > 6} { break }
        lassign $r e sl
        set p [dict get $wp $e]
        set lg [get_property DATAPATH_LOGIC_DELAY $p]; set nt [get_property DATAPATH_NET_DELAY $p]
        puts $fs [format "      %7.3f %4d  %-44s %2d levels  logic %.2f net %.2f (%2.0f%% wire)  from %s" $sl [dict get $n $e] $e \
          [get_property LOGIC_LEVELS $p] $lg $nt [expr {100.0 * $nt / ($lg + $nt)}] \
          [fam [cell_of [get_property NAME [get_property STARTPOINT_PIN $p]]] $pre]]
        if {$k <= 3} {
          puts $fs "               chain: [chain $p $pre]"
          puts $fr "######## $label [expr {$pre eq {} ? {core} : $pre}] $kind -> $e"
          puts $fr [report_timing -of_objects $p -return_string]
        }
      }
      flush $fs
    }
  }
  close_design
}
close $fs; close $fr
puts "Q_FETCH_PATHS_DONE"
