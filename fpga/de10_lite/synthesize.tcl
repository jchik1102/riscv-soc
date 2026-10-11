package require ::quartus::project
package require ::quartus::flow
set root [file normalize [file join [file dirname [info script]] ../..]]
set stage [expr {[llength $argv] > 0 ? [lindex $argv 0] : "s2"}]
set pipeline [expr {[llength $argv] > 1 ? [lindex $argv 1] : 0}]
set accel_n [expr {[llength $argv] > 2 ? [lindex $argv 2] : 0}]
set out [file join $root build quartus_$stage]
file mkdir $out
cd $out
project_new $stage -overwrite
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY synthesis_top
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
foreach source {rtl/soc/platform_pkg.sv rtl/soc/soc_pkg.sv rtl/core/core_pkg.sv rtl/core/decoder.sv rtl/core/alu.sv rtl/core/load_store.sv rtl/core/regfile.sv rtl/core/mul_iter.sv rtl/core/div_iter.sv rtl/core/muldiv_unit.sv rtl/core/csr_file.sv rtl/core/core_multicycle.sv rtl/core/core_pipeline.sv rtl/soc/bus_arbiter.sv rtl/soc/bus_decoder.sv rtl/soc/mmio_bus.sv rtl/peripherals/uart.sv rtl/peripherals/timer.sv rtl/peripherals/perf_counters.sv rtl/peripherals/irq_ctrl.sv rtl/peripherals/matrix_accel.sv rtl/memory/cache.sv rtl/memory/cache_regs.sv rtl/soc/burst_arbiter.sv rtl/memory/onchip_ram.sv rtl/soc/cpu_soc.sv fpga/de10_lite/synthesis_top.sv} {
    set_global_assignment -name SYSTEMVERILOG_FILE [file join $root $source]
}
set_parameter -name PIPELINE $pipeline
set_parameter -name ACCEL_N $accel_n
set_global_assignment -name SDC_FILE [file join $root fpga/de10_lite/synthesis.sdc]
foreach port {rst loader_we loader_word[*] loader_data[*] trace_valid halted trace_pc[*] trace_result[*] trace_rd[*] uart_tx uart_rx} {
    set_instance_assignment -name VIRTUAL_PIN ON -to $port
}
export_assignments
execute_module -tool map
project_close
puts "SYNTHESIS_PASS: Analysis & Synthesis only; placement/timing/board not tested"
