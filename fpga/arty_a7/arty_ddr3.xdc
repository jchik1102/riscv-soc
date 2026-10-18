# Arty A7-100T pins for fpga/arty_a7/arty_ddr3_top.sv, from Digilent's master
# constraints (MIT licence, github.com/Digilent/digilent-xdc,
# Arty-A7-100-Master.xdc). The DDR3 pins and their I/O standards come with the
# MIG IP (fpga/arty_a7/mig_ddr3.prj); the clock-domain-crossing constraints
# are applied in fpga/arty_a7/build_arty.tcl after synthesis, once the MIG's
# clocks exist.
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports CLK100MHZ]
create_clock -name sys_clk_pin -period 10.000 [get_ports CLK100MHZ]
set_property -dict { PACKAGE_PIN C2  IOSTANDARD LVCMOS33 } [get_ports ck_rst]
set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 } [get_ports uart_rxd_out]
set_property -dict { PACKAGE_PIN A9  IOSTANDARD LVCMOS33 } [get_ports uart_txd_in]
set_property -dict { PACKAGE_PIN H5  IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN J5  IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
# The button, UART and LEDs are asynchronous to every clock in the design.
set_false_path -from [get_ports {ck_rst uart_txd_in}]
set_false_path -to [get_ports {uart_rxd_out led[*]}]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
