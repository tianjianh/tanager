# KV260 pins used by the Tanager board top (docs/spec/soc.md §2.1).
# Fan enable, active low (som240_1_c24 = A12, 3.3 V bank). Driven low: full speed while loaded.
set_property PACKAGE_PIN A12       [get_ports fan_en_b]
set_property IOSTANDARD  LVCMOS33  [get_ports fan_en_b]
set_property SLEW        SLOW      [get_ports fan_en_b]
set_property DRIVE       4         [get_ports fan_en_b]
