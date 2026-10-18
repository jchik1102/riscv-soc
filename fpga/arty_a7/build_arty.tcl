# Vivado implementation of fpga/arty_a7/arty_ddr3_top.sv for the Arty A7-100T
# (xc7a100tcsg324-1): the MIG IP from fpga/arty_a7/gen_mig.tcl (build/mig/),
# the SoC with caches and the DDR3 bridge, the pins in arty_ddr3.xdc, then
# synthesis, placement, routing, reports and a bitstream. The bitstream has not
# been loaded on a board.
#   vivado -mode batch -source fpga/arty_a7/build_arty.tcl -tclargs <image_words.hex>
# Writes build/vivado/arty_ddr3/ and prints ARTY_PASS or ARTY_FAIL.
set root [file normalize [file join [file dirname [info script]] ../..]]
set image [file normalize [lindex $argv 0]]
set out [file join $root build vivado arty_ddr3]
file mkdir $out
set part xc7a100tcsg324-1
set_part $part
read_ip [file join $root build mig ip mig_ddr3 mig_ddr3.xci]
generate_target all [get_ips mig_ddr3]
synth_ip [get_ips mig_ddr3]
set sources {rtl/soc/platform_pkg.sv rtl/soc/soc_pkg.sv rtl/core/core_pkg.sv rtl/core/decoder.sv rtl/core/alu.sv
  rtl/core/load_store.sv rtl/core/regfile.sv rtl/core/mul_iter.sv rtl/core/div_iter.sv rtl/core/muldiv_unit.sv
  rtl/core/csr_file.sv rtl/core/core_multicycle.sv rtl/core/core_pipeline.sv rtl/soc/bus_arbiter.sv rtl/soc/bus_decoder.sv
  rtl/soc/mmio_bus.sv rtl/peripherals/uart.sv rtl/peripherals/timer.sv rtl/peripherals/perf_counters.sv
  rtl/peripherals/irq_ctrl.sv rtl/peripherals/matrix_accel.sv rtl/peripherals/fir_filter.sv rtl/memory/cache.sv
  rtl/memory/cache_regs.sv rtl/soc/burst_arbiter.sv rtl/memory/onchip_ram.sv rtl/memory/boot_rom.sv
  rtl/memory/async_fifo.sv rtl/memory/ddr3_bridge.sv rtl/soc/cpu_soc.sv fpga/arty_a7/arty_ddr3_top.sv}
foreach s $sources { read_verilog -sv [file join $root $s] }
read_xdc [file join $root fpga/arty_a7/arty_ddr3.xdc]
set f [open $image r]; set words [llength [split [string trim [read $f]] "\n"]]; close $f
synth_design -top arty_ddr3_top -part $part -generic IMAGE_FILE=$image -generic IMAGE_WORDS=$words

# Clock-domain crossings between the SoC clock (MMCM output 0) and the MIG's
# user clock: only the bridge's async FIFOs and two synchronizers cross. As in
# the network engine's two-clock top, bound them instead of cutting them:
# data paths under the faster clock's period, and Gray-pointer bit skew too.
set clk_soc [get_clocks -of_objects [get_pins mmcm/CLKOUT0]]
set clk_ui [get_clocks -of_objects [get_nets ui_clk]]
set ui_period [get_property PERIOD $clk_ui]
set_max_delay -datapath_only -from $clk_soc -to $clk_ui $ui_period
set_max_delay -datapath_only -from $clk_ui -to $clk_soc $ui_period
foreach fifo {cmd_fifo rd_fifo} {
  set_bus_skew -from [get_cells bridge/$fifo/w_gray_reg*] -to [get_cells bridge/$fifo/w_sync1_reg*] $ui_period
  set_bus_skew -from [get_cells bridge/$fifo/r_gray_reg*] -to [get_cells bridge/$fifo/r_sync1_reg*] $ui_period
}

opt_design
place_design
phys_opt_design
route_design
report_utilization -file $out/utilization.txt
report_utilization -hierarchical -hierarchical_depth 3 -file $out/utilization_hierarchy.txt
report_timing_summary -max_paths 10 -file $out/timing_summary.txt
report_timing -setup -max_paths 1 -path_type full -file $out/worst_setup_path.txt
report_clock_interaction -file $out/clock_interaction.txt
report_cdc -details -file $out/cdc.txt
report_bus_skew -file $out/bus_skew.txt
report_drc -file $out/drc.txt
write_bitstream -force $out/arty_ddr3_top.bit
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -hold -max_paths 1]]
set util [report_utilization -return_string]
proc util_value {util name} {
  set pattern [string map [list NAME $name] {\|\s*NAME\s*\|\s*([0-9.]+)}]
  if {[regexp $pattern $util -> v]} { return $v }
  return NA
}
set unrouted [llength [get_nets -hier -quiet -filter {ROUTE_STATUS == UNROUTED}]]
set verdict [expr {$wns >= 0 && $whs >= 0 && $unrouted == 0 ? "ARTY_PASS" : "ARTY_FAIL"}]
set line "$verdict top=arty_ddr3_top part=$part wns_ns=$wns whs_ns=$whs slice_luts=[util_value $util {Slice LUTs}] slice_registers=[util_value $util {Slice Registers}] bram_tiles=[util_value $util {Block RAM Tile}] dsps=[util_value $util {DSPs}] unrouted_nets=$unrouted image_words=$words"
puts $line
set f [open $out/result.txt w]; puts $f $line; close $f
