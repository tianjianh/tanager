# G4's reports after routing (sourced by g4_fit.tcl, and by g4_report.tcl on a routed checkpoint):
# the pblocks' utilisation, each block's LUTs per clock region, utilisation and timing reports,
# the chip's and the uncore's worst paths, the crossbar's paths from and to the cores, the uncore's
# failing endpoints by block, and the per-site table. Expects fh (summary.txt, open), t0, cfg,
# core_mhz and mask, and the procs tg_kv and tg_util.
close [open util_pblocks.rpt w]
foreach pb [get_pblocks -quiet] { report_utilization -pblocks $pb -append -file util_pblocks.rpt }
# each block's LUTs per clock region (the cores, the uncore and its blocks)
set rf [open regions.txt w]
foreach pat {u_soc/* u_soc/u_uncore/*} {
  foreach blk [get_cells -quiet -filter {!IS_PRIMITIVE} $pat] {
    set name [get_property NAME $blk]
    current_instance -quiet
    current_instance -quiet $blk
    set cnt [dict create]
    foreach c [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ CLB.LUT.* || PRIMITIVE_TYPE =~ CLB.LUTRAM.*}] {
      set cr [get_property CLOCK_REGION [get_sites -quiet -of_objects $c]]
      if {$cr ne ""} { dict incr cnt $cr }
    }
    current_instance -quiet
    set line [format "%-40s" $name]
    foreach k [lsort [dict keys $cnt]] { append line [format " %s:%d" $k [dict get $cnt $k]] }
    puts $rf $line
  }
}
foreach ref {URAM288 RAMB36E2 RAMB18E2 DSP48E2} {
  set cnt [dict create]
  foreach c [get_cells -quiet -hier -filter "REF_NAME == $ref"] {
    set cr [get_property CLOCK_REGION [get_sites -quiet -of_objects $c]]
    if {$cr ne ""} { dict incr cnt $cr }
  }
  set line [format "%-40s" $ref]
  foreach k [lsort [dict keys $cnt]] { append line [format " %s:%d" $k [dict get $cnt $k]] }
  puts $rf $line
}
close $rf

report_utilization -file util.rpt
report_utilization -hierarchical -hierarchical_depth 5 -hierarchical_min_primitive_count 0 -file util_hier.rpt
# the uncore's and each core's share, from the hierarchical table's columns (instance, module,
# total LUTs, logic LUTs, LUTRAMs, SRLs, FFs, RAMB36, RAMB18, URAM, DSP)
set r [report_utilization -hierarchical -hierarchical_depth 2 -hierarchical_min_primitive_count 0 -return_string]
foreach line [split $r "\n"] {
  set f [lmap x [split $line |] {string trim $x}]
  if {[llength $f] < 12 || ![string is integer -strict [lindex $f 3]]} { continue }
  lassign $f - inst mod total logic lutram srl ff b36 b18 uram dsp
  if {$inst eq "u_uncore"} {
    set k uncore
  } elseif {[string match {g_core?[01]?*u_core} $inst]} {
    set k core[string index $inst 7]
  } else {
    continue
  }
  foreach {c v} [list lut $total lutram $lutram ff $ff ramb36 $b36 ramb18 $b18 uram $uram dsp $dsp] { tg_kv $fh ${k}_$c $v }
}
report_timing_summary -max_paths 10 -file timing_summary.rpt
report_timing -max_paths 20 -nworst 1 -unique_pins -sort_by slack -input_pins -file timing.rpt
report_design_analysis -logic_level_distribution -logic_level_dist_paths 2000 -file levels.rpt
report_clock_utilization -file clock_utilization.rpt

proc tg_path_kv {fh tag p} {
  if {$p eq ""} { tg_kv $fh $tag none; return }
  tg_kv $fh $tag [format "%.3f levels %d logic %.3f net %.3f %s -> %s" [get_property SLACK $p] \
    [get_property LOGIC_LEVELS $p] [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] \
    [get_property NAME [get_property STARTPOINT_PIN $p]] [get_property NAME [get_property ENDPOINT_PIN $p]]]
}
proc tg_xgroup {n} {
  foreach {re k} {{/u_xbar/g_ta_slice\[} a_slice {/u_xbar/g_ta\[} a_arb {/u_xbar/g_id\[} d_slice
                  {/u_xbar/g_ib\[} b_slice {/u_xbar/g_tc\[} c {/u_xbar/g_te\[} e} {
    if {[regexp $re $n]} { return $k }
  }
  return other
}
proc tg_worst {args} {
  if {[catch {get_timing_paths -max_paths 1 -nworst 1 -setup {*}$args} p]} { return "" }
  return $p
}
set p [tg_worst]
tg_kv $fh wns_ns [format %.3f [get_property SLACK $p]]
tg_path_kv $fh worst $p
tg_kv $fh whs_ns [format %.3f [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]]

# ---- the uncore ----
set U u_soc/u_uncore
set useq [get_cells -quiet -hierarchical -filter "NAME =~ ${U}/* && IS_SEQUENTIAL"]
set udsp [get_cells -quiet -hierarchical -filter "NAME =~ ${U}/* && REF_NAME == DSP48E2"]
set uin  [get_pins -quiet -of_objects $udsp -filter {DIRECTION == IN}]
set cseq [get_cells -quiet -hierarchical -filter "NAME =~ u_soc/g_core* && IS_SEQUENTIAL"]
set ps   [get_cells -quiet -hierarchical -filter {REF_NAME == PS8}]
tg_kv $fh uncore_seq_cells [llength $useq]
tg_kv $fh uncore_dsp48 [llength $udsp]
tg_kv $fh uncore_dsp48_seq [llength [filter -quiet $udsp IS_SEQUENTIAL]]
set upaths {}
foreach {tag targs} [list \
    uncore_to       [list -to $useq] \
    uncore_dsp_in   [list -through $uin] \
    uncore_internal [list -from $useq -to $useq] \
    core_to_uncore  [list -from $cseq -to $useq] \
    uncore_to_core  [list -from $useq -to $cseq] \
    ps_to_uncore    [list -from $ps -to $useq] \
    uncore_to_ps    [list -from $useq -to $ps]] {
  set q [tg_worst {*}$targs]
  tg_path_kv $fh $tag $q
  if {$q ne ""} { lappend upaths $q }
}
if {[llength $upaths]} { report_timing -of_objects $upaths -input_pins -file uncore_paths.rpt }

# ---- the crossbar's paths to and from the cores (the SoC track: out-of-context uncore runs do
# not time them). The crossbar's cells by group: A slices, A arbiters (g_ta), C and E slices,
# D and B slices; a DSP-form slice is timed through its DSP's pins.
set xg [dict create]
foreach c [get_cells -quiet -hierarchical -filter "NAME =~ ${U}/u_xbar/* && IS_SEQUENTIAL && REF_NAME != DSP48E2"] {
  dict lappend xg [tg_xgroup [get_property NAME $c]] $c
}
set xd [dict create]
foreach c [get_cells -quiet -hierarchical -filter "NAME =~ ${U}/u_xbar/* && REF_NAME == DSP48E2"] {
  dict lappend xd [tg_xgroup [get_property NAME $c]] $c
}
set xf [open xbar_core.txt w]
puts $xf "# worst setup slack (ns) between the cores and the crossbar's groups at $core_mhz MHz: levels, logic and wire"
set xpaths {}
foreach {tag dir grp} {core_to_a_slice in a_slice core_to_a_arb in a_arb core_to_c_slice in c core_to_e_slice in e
                       core_to_xbar in * d_slice_to_core out d_slice b_slice_to_core out b_slice xbar_to_core out *} {
  set worst ""
  foreach src {seq dsp} {
    set cells {}
    if {$src eq "seq"} { set d $xg } else { set d $xd }
    dict for {k v} $d { if {$grp eq "*" || $k eq $grp} { lappend cells {*}$v } }
    if {![llength $cells]} { continue }
    set cells [get_cells -quiet $cells]
    if {$dir eq "in" && $src eq "seq"} {
      set q [tg_worst -from $cseq -to $cells]
    } elseif {$dir eq "in"} {
      set q [tg_worst -from $cseq -through [get_pins -quiet -of_objects $cells -filter {DIRECTION == IN}]]
    } elseif {$src eq "seq"} {
      set q [tg_worst -from $cells -to $cseq]
    } else {
      set q [tg_worst -through [get_pins -quiet -of_objects $cells -filter {DIRECTION == OUT}] -to $cseq]
    }
    if {$q ne "" && ($worst eq "" || [get_property SLACK $q] < [get_property SLACK $worst])} { set worst $q }
  }
  if {$worst eq ""} { puts $xf [format "%-18s none" $tag]; continue }
  lappend xpaths $worst
  puts $xf [format "%-18s %8.3f  levels %2d  logic %.3f  net %.3f  %s -> %s" $tag [get_property SLACK $worst] \
    [get_property LOGIC_LEVELS $worst] [get_property DATAPATH_LOGIC_DELAY $worst] [get_property DATAPATH_NET_DELAY $worst] \
    [get_property NAME [get_property STARTPOINT_PIN $worst]] [get_property NAME [get_property ENDPOINT_PIN $worst]]]
}
close $xf
if {[llength $xpaths]} { report_timing -of_objects $xpaths -input_pins -file xbar_core_paths.rpt }

# ---- the uncore's failing endpoints by block (two levels under u_uncore), as the SoC track's
# out-of-context runs count them ----
set cnt [dict create]; set wst [dict create]
foreach q [get_timing_paths -quiet -max_paths 5000 -nworst 1 -setup -slack_lesser_than 0 -to $useq] {
  set key [join [lrange [split [get_property NAME [get_property ENDPOINT_PIN $q]] /] 2 3] /]
  dict incr cnt $key
  set sl [get_property SLACK $q]
  if {![dict exists $wst $key] || $sl < [dict get $wst $key]} { dict set wst $key $sl }
}
set rows {}
dict for {k n} $cnt { lappend rows [list $k $n [dict get $wst $k]] }
set ff [open uncore_failing.txt w]
puts $ff "# the uncore's failing endpoints (at most 5,000) by block, with the worst slack (ns)"
foreach r [lsort -real -index 2 $rows] { puts $ff [format "%-64s %6d %8.3f" {*}$r] }
close $ff
report_timing -max_paths 20 -nworst 1 -setup -from $useq -to $useq -input_pins -file uncore_internal.rpt

# ---- per register-slice site (tg_skid) ----
proc tg_ini {i} {
  foreach {base kind} {12 hdma 8 mmio 4 l1i 0 l1d} { if {$i >= $base} { return "$kind[expr {$i - $base}]" } }
}
proc tg_tgt {t} {
  set nb 2
  if {$t < $nb} { return "l2b$t" }
  return [lindex {rom dev err} [expr {$t - $nb}]]
}
set sites [get_cells -quiet -hierarchical -filter \
  "NAME =~ ${U}/* && (ORIG_REF_NAME == tg_skid || REF_NAME =~ tg_skid*)"]
set sf [open sites.txt w]
puts $sf "# UNCORE_DSP 0x$mask at $core_mhz MHz. Slack in ns: into the main data register (in), out of"
puts $sf "# it (out), into the slice's control and skid flops (ctl). form: dsp (tg_dsp_reg2) or fab."
puts $sf [format "%-4s %-10s %-4s %8s %8s %8s %s" bit site form in out ctl "in from (levels), out to (levels)"]
set spaths {}
set rows {}
foreach s $sites {
  set n [get_property NAME $s]
  set rel [string range $n [string length "$U/"] end]
  set bit -; set label "other"
  if {[regexp {u_xbar/g_id\[(\d+)\]} $rel -> i]} {
    set bit $i; set label "D.[tg_ini $i]"
  } elseif {[regexp {u_xbar/g_ta_slice\[(\d+)\]} $rel -> t]} {
    set bit [expr {16 + $t}]; set label "A.[tg_tgt $t]"
  } elseif {[regexp {u_xbar/g_tc\[(\d+)\]} $rel -> b]} {
    set bit [expr {24 + $b}]; set label "C.b$b"
  } elseif {[regexp {u_xbar/g_ib\[(\d+)\]} $rel -> c]} {
    set bit [expr {28 + $c}]; set label "B.c$c"
  } elseif {[regexp {u_xbar/g_te\[(\d+)\]} $rel -> b]} {
    set label "E.b$b"
  } elseif {[regexp {g_mem\[(\d+)\]\.u_slice/u_(ar|aw|w|r|b)$} $rel -> b ch]} {
    set bit [expr {32 + 5 * $b + [lsearch {ar aw w r b} $ch]}]; set label "M$b.[string toupper $ch]"
  } elseif {[regexp {u_l2/g_bank\[(\d+)\]\.u_bank/u_rslice$} $rel -> b]} {
    set bit [expr {42 + $b}]; set label "L2R.b$b"
  } else {
    set label "other:$rel"
  }
  # the slice's cells, found from the instance (its name has brackets, which -filter globs read
  # as character classes)
  current_instance -quiet
  current_instance -quiet $s
  set dsps [get_cells -quiet -hierarchical -filter {REF_NAME == DSP48E2}]
  set seqs [get_cells -quiet -hierarchical -filter {IS_SEQUENTIAL && PRIMITIVE_LEVEL != INTERNAL && REF_NAME != DSP48E2}]
  current_instance -quiet
  set main [filter -quiet $seqs {NAME =~ *main_q_reg*}]
  set ctl  [filter -quiet $seqs {NAME !~ *main_q_reg*}]
  set pin ""; set pout ""; set pctl ""
  if {[llength $dsps]} {
    set form dsp
    set pin  [tg_worst -through [get_pins -quiet -of_objects $dsps -filter {DIRECTION == IN}]]
    set pout [tg_worst -through [get_pins -quiet -of_objects $dsps -filter {DIRECTION == OUT}]]
  } else {
    set form fab
    if {[llength $main]} {
      set pin  [tg_worst -to $main]
      set pout [tg_worst -from $main]
    }
  }
  if {[llength $ctl]} { set pctl [tg_worst -to $ctl] }
  set sl {}
  foreach q [list $pin $pout $pctl] {
    if {$q eq ""} { lappend sl NA } else { lappend sl [format %.3f [get_property SLACK $q]]; lappend spaths $q }
  }
  # where the worst path in comes from and the worst path out goes to, with its logic levels
  set ends ""
  foreach q [list $pin $pout] end {STARTPOINT_PIN ENDPOINT_PIN} {
    if {$q eq ""} { append ends " -"; continue }
    append ends [format " %s(%d)" [get_property NAME [get_property $end $q]] [get_property LOGIC_LEVELS $q]]
  }
  lappend rows [list $bit $label $form {*}$sl $ends]
}
foreach r [lsort -dictionary -index 0 $rows] {
  lassign $r bit label form in out ctl ends
  puts $sf [format "%-4s %-10s %-4s %8s %8s %8s %s" $bit $label $form $in $out $ctl $ends]
}
close $sf
if {[llength $spaths]} { report_timing -of_objects $spaths -input_pins -file sites_paths.rpt }
tg_kv $fh sites [llength $sites]
tg_kv $fh total_s [expr {[clock seconds] - $t0}]
close $fh
