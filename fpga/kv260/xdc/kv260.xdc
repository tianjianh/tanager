# KV260 pins used by the Tanager board top (docs/spec/soc.md §2.1).
# Fan enable, active low (som240_1_c24 = A12, 3.3 V bank): the PS TTC PWM that Linux's pwm-fan drives (DR-129).
set_property PACKAGE_PIN A12       [get_ports fan_en_b]
set_property IOSTANDARD  LVCMOS33  [get_ports fan_en_b]
set_property SLEW        SLOW      [get_ports fan_en_b]
set_property DRIVE       4         [get_ports fan_en_b]

# RISC-V console on PMOD J2 (kv260_top PMOD_UART, DR-126): the board's CH340 USB UART (COM5 on the
# laptop) has its RX on J2 pin 1 and its TX on J2 pin 2, so the FPGA's TX drives pin 1 and its RX
# samples pin 2. J2 is numbered odd/even (rows 11 9 7 5 3 1 and 12 10 8 6 4 2), so pins 1 and 2 face
# each other; Digilent's numbering would put pin 2 on E10, which is wrong here. Source: the board
# session, confirmed on the board by the user (2026-10-14): pin 1 = H12 (HDA11, som240_1_a17), pin 2
# = B10 (HDA15, som240_1_b20). The Vivado board files (kv260_som, kv260_carrier) list the SOM240 pins
# but carry no PMOD interface, so they cannot settle the mapping.
# txd is high-impedance while PMOD_UART = 0. build.tcl's TG_PMOD_TXD / TG_PMOD_RXD override the pins.
set_property PACKAGE_PIN H12       [get_ports pmod_uart_txd]
set_property PACKAGE_PIN B10       [get_ports pmod_uart_rxd]
set_property IOSTANDARD  LVCMOS33  [get_ports {pmod_uart_txd pmod_uart_rxd}]
set_property PULLUP      true      [get_ports pmod_uart_rxd]
set_property SLEW        SLOW      [get_ports pmod_uart_txd]
set_property DRIVE       4         [get_ports pmod_uart_txd]
