# Out-of-context Vivado implementation (synthesis, placement, routing) of one
# top for a Xilinx part, with reports. Called by scripts/run-vivado.ps1:
#   vivado -mode batch -source vivado-impl.tcl -tclargs \
#     <top> <part> <period_ns> <out_dir> <generics name:value+name:value or none> <xdc or none> <sources...>
# With no XDC, one clock "clk" is created on port clk at <period_ns>. Ports are
# out of context, so only register-to-register paths are timed (the designs
# register their ports, like the Quartus fit wrappers). Prints
# VIVADO_PASS/VIVADO_FAIL with slack, Fmax and resource counts.
lassign $argv top part period out generics xdc
set sources [lrange $argv 6 end]
file mkdir $out
set_part $part
read_verilog -sv $sources
if {$xdc ne "none"} {
  read_xdc -mode out_of_context $xdc
} else {
  set f [open $out/clock.xdc w]
  puts $f "create_clock -name clk -period $period \[get_ports clk\]"
  close $f
  read_xdc -mode out_of_context $out/clock.xdc
}
set g {}
# name:value+name:value, because vivado.bat splits arguments at "=" and ","
if {$generics ne "none"} { foreach kv [split $generics +] { lappend g -generic [string map {: =} $kv] } }
synth_design -top $top -part $part -mode out_of_context {*}$g
opt_design
place_design
phys_opt_design
route_design
report_utilization -file $out/utilization.txt
report_utilization -hierarchical -hierarchical_depth 4 -file $out/utilization_hierarchy.txt
report_timing_summary -max_paths 10 -file $out/timing_summary.txt
report_timing -setup -max_paths 1 -path_type full -file $out/worst_setup_path.txt
report_clock_interaction -file $out/clock_interaction.txt
if {[llength [get_clocks]] > 1} {
  report_cdc -details -file $out/cdc.txt
  report_bus_skew -file $out/bus_skew.txt
}
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -hold -max_paths 1]]
set worst [get_timing_paths -setup -max_paths 1]
set clk_period [get_property PERIOD [get_property ENDPOINT_CLOCK $worst]]
set fmax [format %.2f [expr {1000.0 / ($clk_period - $wns)}]]
# Resource counts from Vivado's own utilization report (counting LUT cells
# would count both halves of a dual-output LUT).
set util [report_utilization -return_string]
proc util_value {util name} {
  set pattern [string map [list NAME $name] {\|\s*NAME\s*\|\s*([0-9.]+)}]
  if {[regexp $pattern $util -> v]} { return $v }
  return NA
}
set luts [util_value $util {Slice LUTs}]
set ffs [util_value $util {Slice Registers}]
set bram [util_value $util {Block RAM Tile}]
set dsp [util_value $util {DSPs}]
set unrouted [llength [get_nets -hier -quiet -filter {ROUTE_STATUS == UNROUTED}]]
set verdict [expr {$wns >= 0 && $whs >= 0 && $unrouted == 0 ? "VIVADO_PASS" : "VIVADO_FAIL"}]
set line "$verdict top=$top part=$part wns_ns=$wns whs_ns=$whs fmax_mhz=$fmax (worst clock period $clk_period ns) slice_luts=$luts slice_registers=$ffs bram_tiles=$bram dsps=$dsp unrouted_nets=$unrouted"
puts $line
set f [open $out/result.txt w]; puts $f $line; close $f
