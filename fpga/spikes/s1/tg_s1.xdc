# Spike S1 PL pins. KV260 fan enable (SOM240_1 C24, package pin A12, active low), driven by
# the PS timer's PWM through EMIO so Linux's pwm-fan driver sets the speed (DR-129).
set_property PACKAGE_PIN A12 [get_ports fan_en_b]
set_property IOSTANDARD LVCMOS33 [get_ports fan_en_b]
set_property SLEW SLOW [get_ports fan_en_b]
set_property DRIVE 4 [get_ports fan_en_b]
