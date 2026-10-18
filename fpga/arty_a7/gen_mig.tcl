# Generate the Vivado MIG (7-series) DDR3 controller for the Arty A7-100T from
# fpga/arty_a7/mig_ddr3.prj: Digilent's MIG settings for the board (MIT
# licence, github.com/Digilent/vivado-boards, arty-a7-100/E.0/1.1/mig.prj),
# with the AXI port changed to MIG's native interface, the system clock taken
# from an internal clock ("No Buffer", as the reference clock already was) so
# one MMCM in fpga/arty_a7/arty_ddr3_top.sv can make all the clocks from the
# board's 100 MHz oscillator, and the module renamed.
# MT41K128M16 DDR3L, 16 bits, 325 MHz (DDR3-650) with a 4:1 PHY, so the user
# interface clock is 81.25 MHz and the native data path is 128 bits.
#   vivado -mode batch -source fpga/arty_a7/gen_mig.tcl
# Writes the IP, its user design and its example design (with Micron's DDR3
# simulation model) under build/mig/.
set root [file normalize [file join [file dirname [info script]] ../..]]
set out [file join $root build mig]
file delete -force $out
file mkdir $out/ip
create_project -force mig_ip $out/project -part xc7a100tcsg324-1
create_ip -name mig_7series -vendor xilinx.com -library ip -module_name mig_ddr3 -dir $out/ip
set ipdir [file join $out ip mig_ddr3]
file copy -force [file join $root fpga/arty_a7/mig_ddr3.prj] [file join $ipdir mig_ddr3.prj]
set_property CONFIG.XML_INPUT_FILE mig_ddr3.prj [get_ips mig_ddr3]
generate_target all [get_ips mig_ddr3]
open_example_project -force -dir $out/example [get_ips mig_ddr3]
puts "MIG_GENERATED $ipdir"
