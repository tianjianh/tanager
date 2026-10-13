# Memory-primitive check (plan §8.3). Vivado can silently drop a RAM read port, so every
# synthesis run checks each memory wrapper instance against the primitive counts its
# parameters imply.
#
#   source tools/tcl/tg_prim_check.tcl
#   set bad [tg_prim_check ?-file <report.txt>? ?-expect <list>? ?-fail 0|1?]
#
# Call it after synth_design and again after opt_design. It returns the number of failures
# and prints one line per wrapper instance:
#   PRIM_OK|PRIM_FAIL|PRIM_WARN <instance> <module> <shape> expected <...> found <...>
# plus PRIM_STRAY lines for RAM primitives outside any wrapper (memories must go through
# rtl/common/prim, conventions §4), and a PRIM_SUMMARY line. With -fail 1 (default) a
# failure raises a Tcl error after the report is written, so a batch run stops.
#
# Expected counts come from the instance's port widths (the wrappers keep their hierarchy):
#   tg_ram_lut   WIDTH = |wdata|, NR = |rdata| / WIDTH, AW = |waddr|
#                AW <= 5: RAM32M16 = ceil(NR * ceil(WIDTH/2) / 7)
#                AW >= 6: RAM64M8  = 2^(AW-6) * ceil(NR * WIDTH / 7)
#                Anything else inside the instance (other RAM primitives) is a failure.
#   tg_ram_sdp   Block or UltraRAM through XPM. The family found must be one family, and the
#   tg_ram_tdp   count is compared with the smallest mapping of a 2^AW x WIDTH memory:
#                URAM288 = ceil(WIDTH/72) * ceil(2^AW / 4096) (exact)
#                RAMB36E2/RAMB18E2, in RAMB36 equivalents (a RAMB18 is 0.5): a different
#                count is a warning, no primitive at all is a failure.
# -expect adds exact checks for any cell: a list of {<cell-name-glob> <REF_NAME> <count>},
# where the count is that of REF_NAME cells at or below the matching cells.

proc tg_prim__ceil {a b} { return [expr {($a + $b - 1) / $b}] }

# Number of bits of port <bus> of a hierarchical cell (packed multi-dimensional ports are
# flattened to pins named bus[i][j] or bus[k]).
proc tg_prim__busw {cell bus} {
  set n 0
  foreach p [get_pins -quiet -of_objects $cell] {
    if {[regexp "^${bus}(\\\[.*)?\$" [get_property REF_PIN_NAME $p]]} { incr n }
  }
  return $n
}

# REF_NAME -> count of non-internal primitive cells at or below a hierarchical cell.
proc tg_prim__count {cell} {
  set counts [dict create]
  current_instance -quiet
  current_instance -quiet $cell
  foreach c [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE && PRIMITIVE_LEVEL != INTERNAL}] {
    dict incr counts [get_property REF_NAME $c]
  }
  current_instance -quiet
  return $counts
}

proc tg_prim__ram_refs {} {
  return {RAM32M16 RAM64M8 RAM32M RAM64M RAM32X1D RAM64X1D RAM128X1D RAM256X1D RAM512X1S
          RAM32X1S RAM64X1S RAM128X1S RAM256X1S RAM32X16DR8 RAMB36E2 RAMB18E2 URAM288
          FIFO36E2 FIFO18E2}
}

# Smallest block-RAM mapping of DEPTH x WIDTH, in RAMB36 equivalents. SDP allows the 72-bit
# (RAMB36) and 36-bit (RAMB18) modes at 512 entries; TDP ports are at most 36 / 18 bits.
proc tg_prim__bram_equiv {depth width tdp} {
  set best 1e9
  foreach {prim size} {RAMB36 36864 RAMB18 18432} {
    set w36 [expr {$prim eq "RAMB36" ? 1.0 : 0.5}]
    # (depth, width) aspect ratios with parity, then without
    if {$prim eq "RAMB36"} {
      set aspects {512 72 1024 36 2048 18 4096 9 8192 4 16384 2 32768 1}
    } else {
      set aspects {512 36 1024 18 2048 9 4096 4 8192 2 16384 1}
    }
    foreach {d w} $aspects {
      if {$tdp && $d == 512} { continue }
      set n [expr {[tg_prim__ceil $depth $d] * [tg_prim__ceil $width $w]}]
      set eq [expr {$n * $w36}]
      if {$eq < $best} { set best $eq }
    }
  }
  return $best
}

proc tg_prim_check {args} {
  set file ""
  set expect {}
  set fail 1
  foreach {k v} $args {
    switch -- $k {
      -file   { set file $v }
      -expect { set expect $v }
      -fail   { set fail $v }
      default { error "tg_prim_check: unknown option $k" }
    }
  }
  set lines {}
  set nfail 0
  set nwarn 0
  set ninst 0
  set ram_refs [tg_prim__ram_refs]
  set covered [dict create]

  set wrappers [get_cells -quiet -hierarchical -filter {
    !IS_PRIMITIVE && (ORIG_REF_NAME =~ "tg_ram_*" || REF_NAME =~ "tg_ram_*")}]
  foreach cell $wrappers {
    set mod [get_property ORIG_REF_NAME $cell]
    if {$mod eq ""} { set mod [get_property REF_NAME $cell] }
    regsub {__parameterized\d+$} $mod {} mod
    if {$mod ni {tg_ram_lut tg_ram_sdp tg_ram_tdp}} { continue }
    incr ninst
    set found [tg_prim__count $cell]
    set status OK
    set exp [dict create]

    if {$mod eq "tg_ram_lut"} {
      set w  [tg_prim__busw $cell wdata]
      set aw [tg_prim__busw $cell waddr]
      set rw [tg_prim__busw $cell rdata]
      set nr [expr {$w > 0 ? $rw / $w : 0}]
      set shape "2^$aw x $w, $nr read"
      if {$aw <= 5} {
        dict set exp RAM32M16 [tg_prim__ceil [expr {$nr * [tg_prim__ceil $w 2]}] 7]
      } else {
        dict set exp RAM64M8 [expr {(1 << ($aw - 6)) * [tg_prim__ceil [expr {$nr * $w}] 7]}]
      }
      foreach ref $ram_refs {
        set f [expr {[dict exists $found $ref] ? [dict get $found $ref] : 0}]
        set e [expr {[dict exists $exp $ref] ? [dict get $exp $ref] : 0}]
        if {$f != $e} { set status FAIL }
      }
    } else {
      set tdp [expr {$mod eq "tg_ram_tdp"}]
      set w  [tg_prim__busw $cell [expr {$tdp ? "wdata_a" : "wdata"}]]
      set aw [tg_prim__busw $cell [expr {$tdp ? "addr_a" : "waddr"}]]
      set depth [expr {1 << $aw}]
      set shape "2^$aw x $w[expr {$tdp ? ", tdp" : ""}]"
      set nuram [expr {[dict exists $found URAM288] ? [dict get $found URAM288] : 0}]
      set n36 [expr {[dict exists $found RAMB36E2] ? [dict get $found RAMB36E2] : 0}]
      set n18 [expr {[dict exists $found RAMB18E2] ? [dict get $found RAMB18E2] : 0}]
      set nlut 0
      foreach ref $ram_refs {
        if {$ref ni {URAM288 RAMB36E2 RAMB18E2} && [dict exists $found $ref]} {
          incr nlut [dict get $found $ref]
        }
      }
      if {$nuram > 0 && ($n36 + $n18 + $nlut) == 0} {
        set e [expr {[tg_prim__ceil $w 72] * [tg_prim__ceil $depth 4096]}]
        dict set exp URAM288 $e
        if {$nuram != $e} { set status FAIL }
      } elseif {($n36 + $n18) > 0 && ($nuram + $nlut) == 0} {
        set e [tg_prim__bram_equiv $depth $w $tdp]
        dict set exp RAMB36_equiv $e
        set got [expr {$n36 + 0.5 * $n18}]
        if {$got != $e} { set status WARN }
      } elseif {$nlut > 0 && ($nuram + $n36 + $n18) == 0} {
        dict set exp distributed "(PRIM=distributed)"
        set status WARN
      } else {
        dict set exp memory ">0 of one family"
        set status FAIL
      }
    }
    if {$status eq "FAIL"} { incr nfail }
    if {$status eq "WARN"} { incr nwarn }
    set fl {}
    dict for {k v} $found { if {$k in $ram_refs} { lappend fl $k $v } }
    lappend lines [format "PRIM_%s %s %s {%s} expected {%s} found {%s}" \
      $status [get_property NAME $cell] $mod $shape $exp $fl]
    dict set covered [get_property NAME $cell] 1
  }

  # Exact expectations for arbitrary cells.
  foreach e $expect {
    lassign $e pat ref n
    set cells [get_cells -quiet -hierarchical -filter "NAME =~ \"$pat\""]
    set tot 0
    foreach c $cells {
      if {[get_property IS_PRIMITIVE $c]} {
        if {[get_property REF_NAME $c] eq $ref} { incr tot }
      } else {
        set f [tg_prim__count $c]
        if {[dict exists $f $ref]} { incr tot [dict get $f $ref] }
      }
    }
    set st [expr {$tot == $n ? "OK" : "FAIL"}]
    if {$st eq "FAIL"} { incr nfail }
    lappend lines [format "PRIM_%s %s (expect) %s expected %d found %d" $st $pat $ref $n $tot]
  }

  # RAM primitives outside every wrapper (inferred memories).
  set nstray 0
  foreach c [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE && PRIMITIVE_LEVEL != INTERNAL}] {
    set ref [get_property REF_NAME $c]
    if {$ref ni $ram_refs} { continue }
    set name [get_property NAME $c]
    set inside 0
    dict for {w _} $covered {
      if {[string first "$w/" $name] == 0} { set inside 1; break }
    }
    if {!$inside && ![string match "*xpm_*" [get_property PARENT $c]]} {
      incr nstray
      if {$nstray <= 50} { lappend lines "PRIM_STRAY $name $ref" }
    }
  }
  lappend lines [format "PRIM_SUMMARY instances %d fail %d warn %d stray %d" \
    $ninst $nfail $nwarn $nstray]

  foreach l $lines { puts $l }
  if {$file ne ""} {
    set fh [open $file w]
    puts $fh [join $lines "\n"]
    close $fh
  }
  if {$fail && $nfail > 0} {
    error "tg_prim_check: $nfail memory instance(s) do not match their expected primitives"
  }
  return $nfail
}
