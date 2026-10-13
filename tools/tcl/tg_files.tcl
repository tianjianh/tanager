# Reads Tanager filelists (.f) into Vivado, mirroring Verilator's -F semantics:
# one file per line, `-F other.f` nests (paths relative to the list), `//` and `#` start comments.
#   source tools/tcl/tg_files.tcl
#   tg_read_rtl <repo-root> <cfg>        ;# config package + rtl/rtl.f
#   tg_read_f <list.f>                    ;# any list

proc tg_f_files {f} {
  set dir [file dirname [file normalize $f]]
  set out {}
  set fh [open $f r]
  while {[gets $fh line] >= 0} {
    regsub {//.*$} $line {} line
    regsub {#.*$} $line {} line
    set line [string trim $line]
    if {$line eq ""} { continue }
    if {[regexp {^-F\s+(\S+)} $line -> sub]} {
      set out [concat $out [tg_f_files [file join $dir $sub]]]
    } else {
      lappend out [file join $dir $line]
    }
  }
  close $fh
  return $out
}

proc tg_read_f {f} {
  foreach src [tg_f_files $f] { read_verilog -sv $src }
}

proc tg_read_rtl {root cfg} {
  read_verilog -sv [file join $root rtl common cfg tg_cfg_${cfg}.sv]
  tg_read_f [file join $root rtl rtl.f]
}
