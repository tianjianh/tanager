# KV260 fan control for every board bitstream (DR-129): the fan enable (SOM240_1 C24, package
# pin A12, active low) follows the PS triple-timer-counter's PWM through EMIO, as in Kria's
# default design, so Linux's pwm-fan driver sets the speed instead of the fan running at
# full speed. Shared by fpga/spikes/s1 and fpga/kv260; both source this file.
#
#   source tools/tcl/tg_kv260_fan.tcl
#   set wave [tg_kv260_fan_ps $ps]   ;# $ps: the zynq_ultra_ps_e block-design cell
#   # then drive the A12 port from bit $tg_kv260_fan_bit of $wave, inverted when
#   # $tg_kv260_fan_invert is 1
#
# The facts (timer, waveform channel, polarity) come from the board's running image. Until
# the board session confirms them, they are the placeholders below: timer 0, channel 2,
# not inverted.
set tg_kv260_fan_ttc    0
set tg_kv260_fan_bit    2
set tg_kv260_fan_invert 0

# Enables the timer's waveform outputs on EMIO in the PS configuration and returns the
# block-design pin emio_ttc<n>_wave_o (3 bits, one per channel).
proc tg_kv260_fan_ps {ps} {
  set t $::tg_kv260_fan_ttc
  set_property -dict [list \
    CONFIG.PSU__TTC${t}__PERIPHERAL__ENABLE {1} \
    CONFIG.PSU__TTC${t}__WAVEOUT__ENABLE {1} \
    CONFIG.PSU__TTC${t}__WAVEOUT__IO {EMIO} \
  ] $ps
  set pin [get_bd_pins -quiet $ps/emio_ttc${t}_wave_o]
  if {[llength $pin] != 1} {
    error "tg_kv260_fan_ps: $ps has no pin emio_ttc${t}_wave_o after enabling TTC$t's waveform on EMIO"
  }
  return $pin
}
