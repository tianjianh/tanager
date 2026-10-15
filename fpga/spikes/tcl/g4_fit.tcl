# Spike G4 (DR-136, for the SoC track): the v1 full chip in the board's own top, to see which of
# the uncore's register slices close with their main data register in DSP48E2s (tg_dsp_reg2) in
# the real placement. kv260_top as fpga/kv260/tcl/build.tcl builds it: the PS block design, the
# MMCM and both clocks, the PMOD console and the fan rule (DR-129), with real cores. Synthesis
# uses DR-113's settings (-flatten_hierarchy none, AreaOptimized_high), as the v1 budget does;
# without them two smt2 cores and the uncore do not fit the XCK26. Placement and routing use the
# board build's flow (opt, place, phys_opt, route; default directives).
# Run it only through tools/vivado_run.sh (conventions §9), e.g. by fpga/spikes/scripts/run_g4.sh:
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/g4_fit.tcl <repo-root> <cfg> <core_mhz> \
#       <uncore_dsp> [-n_cores N] [-constraints T] [-floorplan F] [-flatten M] [-synth_directive D]
#       [-dcp 0|1] [-synth_dcp D]
#   uncore_dsp   tg_uncore's UNCORE_DSP mask (e.g. 0xDCE03000000): one bit per register-slice site
#   -constraints a Tcl file sourced after synthesis (e.g. fpga/spikes/tcl/g3_false_paths.tcl); it
#                may write constraints.txt
#   -floorplan   a floorplan (fpga/spikes/tcl/fp/g4_*.tcl, with fp_lib.tcl's helpers), sourced after
#                the constraints; floorplan.txt and util_pblocks.rpt record it
#   -dcp 1       keep post_synth.dcp (after synthesis, before any constraint) and routed.dcp
#   -synth_dcp D start from such a post-synthesis checkpoint instead of synthesising (the same
#                design for every floorplan; its uncore_dsp argument must match the checkpoint's)
# Writes to the run directory: summary.txt (key value lines, with the uncore's figures),
# sites.txt (per register-slice site: its UNCORE_DSP bit, form, and the worst slack into and out
# of its main data register and into its control flops), sites_paths.rpt, uncore_paths.rpt,
# xbar_core.txt and xbar_core_paths.rpt (the crossbar's paths from and to the cores, by group),
# uncore_failing.txt (failing endpoints by block), uncore_internal.rpt, util.rpt, util_hier.rpt,
# timing_summary.rpt, timing.rpt, levels.rpt, prim_synth.txt, prim_opt.txt.

lassign $argv root cfg core_mhz uncore_dsp
set n_cores 2
set constraints ""
set flatten none
set synth_dir AreaOptimized_high
set keep_dcp 0
set floorplan ""
set synth_dcp ""
set rest [lrange $argv 4 end]
while {[llength $rest]} {
  set rest [lassign $rest k v]
  switch -- $k {
    -n_cores         { set n_cores $v }
    -constraints     { set constraints $v }
    -flatten         { set flatten $v }
    -synth_directive { set synth_dir $v }
    -dcp             { set keep_dcp $v }
    -floorplan       { set floorplan $v }
    -synth_dcp       { set synth_dcp $v }
    default { error "g4_fit.tcl: unknown option $k" }
  }
}
set mask [format %016llX $uncore_dsp]
set part xck26-sfvc784-2LV-c
# Synthesis forks one helper per thread (about 1-2 GB each): at most TANAGER_SYNTH_THREADS
# (default 2), as in ooc_run.tcl; placement and routing get 8.
set synth_threads [expr {[info exists ::env(TANAGER_SYNTH_THREADS)] ? $::env(TANAGER_SYNTH_THREADS) : 2}]
proc tg_kv {fh k v} { puts $fh [format "%-24s %s" $k $v] }
set t0 [clock seconds]

source [file join $root tools tcl tg_kv260_fan.tcl]
source [file join $root tools tcl tg_prim_check.tcl]
if {$synth_dcp ne ""} {
  set_param general.maxThreads 8
  open_checkpoint $synth_dcp
} else {
  create_project -in_memory -part $part
  set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
  set_param general.maxThreads $synth_threads

  # ---- the board top's sources, as build.tcl reads them ----
  source [file join $root fpga kv260 tcl ps_bd.tcl]
  tg_make_ps_bd [file normalize ./bd] $core_mhz
  read_verilog $::tg_ps_wrapper
  source [file join $root tools tcl tg_files.tcl]
  tg_read_rtl $root $cfg
  tg_read_f [file join $root fpga kv260 kv260.f]
  read_xdc [file join $root fpga kv260 xdc kv260.xdc]
  read_xdc [file join $root fpga kv260 xdc timing.xdc]

  synth_design -top kv260_top -part $part \
    -generic CORE_MHZ=$core_mhz -generic N_CORES=$n_cores -generic CORE_KIND=\"core\" \
    -generic PMOD_UART=1 -generic FAN_WAVE=$::tg_kv260_fan_bit -generic FAN_INVERT=$::tg_kv260_fan_invert \
    -generic "UNCORE_DSP=64'h$mask" \
    -flatten_hierarchy $flatten -directive $synth_dir
  set_param general.maxThreads 8
  if {$keep_dcp} { write_checkpoint -force post_synth.dcp }
}
# as build.tcl: the console pins and the fan are asynchronous to the PL clocks
set_false_path -from [get_ports pmod_uart_rxd]
set_false_path -to [get_ports pmod_uart_txd]
set_false_path -to [get_ports fan_en_b]
if {$constraints ne ""} { source [file join $root $constraints] }
close [open floorplan.txt w]
if {$floorplan ne ""} {
  source [file join $root fpga spikes tcl fp_lib.tcl]
  source [file join $root $floorplan]
}

set fh [open summary.txt w]
tg_kv $fh top kv260_top
tg_kv $fh cfg $cfg
tg_kv $fh n_cores $n_cores
tg_kv $fh core_mhz $core_mhz
tg_kv $fh uncore_dsp 0x$mask
tg_kv $fh synth [expr {$synth_dcp ne "" ? "from $synth_dcp" : "-flatten_hierarchy $flatten -directive $synth_dir"}]
tg_kv $fh floorplan [expr {$floorplan ne "" ? $floorplan : "none"}]
tg_kv $fh pblocks [llength [get_pblocks -quiet]]
report_utilization -file util_synth.rpt
tg_kv $fh prim_fail_synth [tg_prim_check -file prim_synth.txt -fail 0]
tg_kv $fh synth_s [expr {[clock seconds] - $t0}]

# Utilisation figures as report_utilization counts them (CLB LUTs = logic + memory).
proc tg_util {fh tag} {
  set r [report_utilization -return_string]
  foreach {key label} {
    lut_total {CLB LUTs}  lut_logic {LUT as Logic}  lut_mem {LUT as Memory}
    ff {CLB Registers}  bram_tile {Block RAM Tile}  uram {URAM}  dsp {DSPs}
  } {
    set v NA
    if {[regexp "\\|\\s*${label}\\*?\\s*\\|\\s*(\[0-9.\]+)" $r -> n]} { set v $n }
    tg_kv $fh ${tag}_$key $v
  }
}
tg_util $fh synth

# ---- implementation, as build.tcl ----
set t1 [clock seconds]
opt_design
tg_kv $fh prim_fail_opt [tg_prim_check -file prim_opt.txt -fail 0]
place_design
tg_kv $fh place_s [expr {[clock seconds] - $t1}]
phys_opt_design
set t2 [clock seconds]
route_design
tg_kv $fh route_s [expr {[clock seconds] - $t2}]
tg_kv $fh impl_s [expr {[clock seconds] - $t0}]
tg_util $fh impl
# the routed design first, so a failing report does not cost the implementation
if {$keep_dcp} { write_checkpoint -force routed.dcp }
close [open util_pblocks.rpt w]
foreach pb [get_pblocks -quiet] { report_utilization -pblocks $pb -append -file util_pblocks.rpt }
# each block's LUTs per clock region (the cores, the uncore's blocks, the PS wrapper)
set rf [open regions.txt w]
foreach blk [concat [get_cells -quiet -filter {!IS_PRIMITIVE} u_soc/*] [get_cells -quiet -filter {!IS_PRIMITIVE} u_soc/u_uncore/*]] {
  current_instance -quiet
  current_instance -quiet $blk
  set cnt [dict create]
  foreach c [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ CLB.LUT.* || PRIMITIVE_TYPE =~ CLB.LUTRAM.*}] {
    set cr [get_property CLOCK_REGION [get_sites -quiet -of_objects $c]]
    if {$cr ne ""} { dict incr cnt $cr }
  }
  current_instance -quiet
  set line [format "%-40s" [get_property NAME $blk]]
  foreach k [lsort [dict keys $cnt]] { append line [format " %s:%d" $k [dict get $cnt $k]] }
  puts $rf $line
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
puts "G4_FIT_DONE $cfg $core_mhz 0x$mask"
