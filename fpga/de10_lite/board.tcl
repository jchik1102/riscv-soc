package require ::quartus::project
package require ::quartus::flow
set root [file normalize [file join [file dirname [info script]] ../..]]
lassign $argv stage pipeline image words expected demo tester_bytes
if {$demo eq ""} { set demo 0 }
set name de10_lite_${stage}_p${pipeline}
set out [file join $root build quartus_board_${stage}_p${pipeline}]
file mkdir $out
cd $out
project_new $name -overwrite
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY de10_lite_top
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"
set_global_assignment -name STRATIX_DEVICE_IO_STANDARD "3.3-V LVTTL"
foreach source {rtl/soc/platform_pkg.sv rtl/soc/soc_pkg.sv rtl/core/core_pkg.sv rtl/core/decoder.sv rtl/core/alu.sv
                rtl/core/load_store.sv rtl/core/regfile.sv rtl/core/mul_iter.sv rtl/core/div_iter.sv rtl/core/muldiv_unit.sv rtl/core/csr_file.sv
                rtl/core/core_multicycle.sv rtl/core/core_pipeline.sv rtl/soc/bus_arbiter.sv rtl/soc/bus_decoder.sv rtl/soc/mmio_bus.sv rtl/peripherals/uart.sv rtl/peripherals/timer.sv rtl/peripherals/perf_counters.sv rtl/peripherals/irq_ctrl.sv rtl/peripherals/matrix_accel.sv rtl/memory/cache.sv rtl/memory/cache_regs.sv rtl/soc/burst_arbiter.sv rtl/memory/onchip_ram.sv
                rtl/memory/sdram_ctrl.sv rtl/memory/sdram_tester.sv fpga/de10_lite/sdram_pll.sv
                rtl/soc/cpu_soc.sv rtl/memory/boot_rom.sv fpga/de10_lite/de10_lite_top.sv} {
    set_global_assignment -name SYSTEMVERILOG_FILE [file join $root $source]
}
set_global_assignment -name SDC_FILE [file join $root fpga/de10_lite/de10_lite.sdc]
set_parameter -name PIPELINE $pipeline
set_parameter -name IMAGE_FILE "\"[file normalize $image]\""
set_parameter -name IMAGE_WORDS $words
set_parameter -name EXPECTED_CHECKSUM $expected
set_parameter -name DEMO $demo
if {$tester_bytes ne ""} { set_parameter -name TESTER_BYTES $tester_bytes }
source [file join $root fpga/de10_lite/de10_lite_pins.tcl]
export_assignments
execute_flow -compile
project_close
puts "BOARD_BUILD_DONE: $name (inspect fit, timing and assembler reports before any claim)"
