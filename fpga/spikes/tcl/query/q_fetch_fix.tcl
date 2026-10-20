# Sizes the fetch fixes proposed after q_fetch_paths.tcl (the coordinator's fetch timing study, 10-20), per checkpoint
# and core, with every clock's setup uncertainty taken back:
#   f2     every endpoint family of F2's cone (paths from the I$ data or TAGE's table RAMs), the worse source's slack
#   fpc    fpc_q -> fpc_q: the worst path, the worst through the ITLB's PTE output (u_itlb/pte*), and the worst that
#          misses it (through the micro-BTB's outputs u_ubtb/hit*, target*, br_slot*); fpc_q's worst load net
#   head   the instruction queue's head (u_cmp/head_q) to decode's redirect (u_de/dred_*) and rename's uop register
#          (u_rn/rn_uop_q): worst slack each, and the fanout of head_q's nets
#   ras    krt_q's worst path now, and the worst path through the RAS's top outputs (what krt_q would see if it took
#          the stack's top directly)
# Writes fetch_fix.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_fetch_fix.tcl <label=routed.dcp>...   (about 5 GB)
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
proc worst {args} {
  set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 {*}$args]
  if {![llength $p]} { return "none" }
  return [format "%.3f (%d levels, logic %.2f net %.2f)" [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
    [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p]]
}
set fs [open fetch_fix.txt w]
foreach arg $argv {
  lassign [split $arg =] label dcp
  open_checkpoint $dcp
  foreach c [get_clocks] { set_clock_uncertainty -setup 0 $c }
  puts $fs "== $label: $dcp"
  if {[llength [get_cells -quiet u_fetch]]} { set pres [list ""] } else {
    set pres [list "u_soc/g_core\[0\].g_tgc.u_core/" "u_soc/g_core\[1\].g_tgc.u_core/"]
  }
  foreach pre $pres {
    puts $fs "  -- core [expr {$pre eq {} ? {(out of context)} : $pre}]"
    set rams [concat \
      [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_way* && PRIMITIVE_GROUP == BLOCKRAM"] \
      [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_tage.u_tage/g_tab* && PRIMITIVE_GROUP == BLOCKRAM"]]
    set ps [get_timing_paths -quiet -setup -from $rams -max_paths 5000 -nworst 1 -unique_pins -slack_lesser_than 1.5]
    set w [dict create]; set n [dict create]; set lv [dict create]
    foreach p $ps {
      set e [fam [cell_of [get_property NAME [get_property ENDPOINT_PIN $p]]] $pre]
      dict incr n $e
      set sl [get_property SLACK $p]
      if {![dict exists $w $e] || $sl < [dict get $w $e]} { dict set w $e $sl; dict set lv $e [get_property LOGIC_LEVELS $p] }
    }
    set rows {}
    dict for {e sl} $w { lappend rows [list $e $sl] }
    puts $fs "    f2: [llength $ps] endpoints below 1.5 ns in [llength $rows] families"
    foreach r [lsort -real -index 1 $rows] {
      lassign $r e sl
      puts $fs [format "      %7.3f %4d  %2d levels  %s" $sl [dict get $n $e] [dict get $lv $e] $e]
    }
    set fpc [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/fpc_q_reg* && IS_SEQUENTIAL"]
    set pte [get_pins -quiet -of_objects [get_cells -quiet -hierarchical -filter "NAME == ${pre}u_fetch/u_itlb"] \
      -filter {DIRECTION == OUT && REF_PIN_NAME =~ pte*}]
    set ub  [get_pins -quiet -of_objects [get_cells -quiet -hierarchical -filter "NAME == ${pre}u_fetch/u_ubtb"] \
      -filter {DIRECTION == OUT}]
    puts $fs "    fpc: worst [worst -from $fpc -to $fpc]"
    puts $fs "         through the ITLB's PTE ([llength $pte] pins): [worst -from $fpc -through $pte -to $fpc]"
    puts $fs "         through the micro-BTB's outputs ([llength $ub] pins): [worst -from $fpc -through $ub -to $fpc]"
    foreach src {fpc} {
      set nets [get_nets -quiet -of_objects [get_pins -quiet -of_objects $fpc -filter {REF_PIN_NAME == Q}]]
      set big {}
      foreach nt $nets {
        set fo [get_property FLAT_PIN_COUNT $nt]
        set d 0.0
        foreach pp [get_timing_paths -quiet -setup -through $nt -max_paths 1 -nworst 1] { set d [get_property SLACK $pp] }
        lappend big [list [get_property NAME $nt] [expr {$fo - 1}] $d]
      }
      set big [lsort -integer -decreasing -index 1 $big]
      puts $fs "         fpc_q's nets, highest fanout first (name, loads, worst slack through it):"
      foreach b [lrange $big 0 7] { puts $fs [format "           %-50s %4d  %.3f" [fam [lindex $b 0] $pre] [lindex $b 1] [lindex $b 2]] }
    }
    set head [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/u_cmp/head_q_reg* && IS_SEQUENTIAL"]
    set dred [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_de/dred_* && IS_SEQUENTIAL"]
    set rnq  [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_rn/rn_uop_q_reg* && IS_SEQUENTIAL"]
    puts $fs "    head: [llength $head] head registers; to decode's redirect [worst -from $head -to $dred]; to rename's uops [worst -from $head -to $rnq]"
    set hn {}
    foreach nt [get_nets -quiet -of_objects [get_pins -quiet -of_objects $head -filter {REF_PIN_NAME == Q}]] {
      lappend hn [list [get_property NAME $nt] [expr {[get_property FLAT_PIN_COUNT $nt] - 1}]]
    }
    puts $fs "         head_q's nets: [join [lmap h [lsort -integer -decreasing -index 1 $hn] {format {%s:%d} [fam [lindex $h 0] $pre] [lindex $h 1]}] {, }]"
    set krt [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/krt_q_reg* && IS_SEQUENTIAL"]
    set top [get_pins -quiet -of_objects [get_cells -quiet -hierarchical -filter "NAME == ${pre}g_ras.u_ras"] \
      -filter {DIRECTION == OUT && REF_PIN_NAME =~ top*}]
    puts $fs "    ras: krt_q [worst -to $krt]; the RAS top's outputs ([llength $top] pins) to any endpoint [worst -through $top]"
    flush $fs
  }
  close_design
}
close $fs
puts "Q_FETCH_FIX_DONE"
