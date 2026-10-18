# Quartus fit of rtl/peripherals/fir_filter.sv alone on the DE10-Lite's MAX 10
# at 50 MHz: synthesis, placement, routing and timing analysis, with every
# port except clk as a virtual pin (the filter is a bus peripheral, so its
# ports would be internal wires in the SoC).
#   quartus_sh -t fpga/fir/fir_fit.tcl <lanes>
# Writes build/quartus_fir_l<lanes>/; scripts/run_fir_synth.ps1 reads the reports.
package require ::quartus::project
package require ::quartus::flow
set root [file normalize [file join [file dirname [info script]] ../..]]
set lanes [lindex $argv 0]
set out [file join $root build quartus_fir_l$lanes]
file mkdir $out
cd $out
project_new fir_l$lanes -overwrite
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY fir_filter
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
foreach source {rtl/soc/platform_pkg.sv rtl/soc/soc_pkg.sv rtl/peripherals/fir_filter.sv} {
    set_global_assignment -name SYSTEMVERILOG_FILE [file join $root $source]
}
set_parameter -name LANES $lanes
set f [open fir.sdc w]
puts $f "create_clock -name clk -period 20.000 \[get_ports clk\]\nderive_clock_uncertainty"
close $f
set_global_assignment -name SDC_FILE fir.sdc
foreach port {rst req* rsp*} {
    set_instance_assignment -name VIRTUAL_PIN ON -to $port
}
export_assignments
execute_module -tool map
execute_module -tool fit
execute_module -tool sta
project_close
puts "FIR_FIT_DONE lanes=$lanes"
