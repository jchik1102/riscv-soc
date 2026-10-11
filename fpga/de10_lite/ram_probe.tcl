package require ::quartus::project
package require ::quartus::flow
set root [file normalize [file join [file dirname [info script]] ../..]]
file mkdir [file join $root build quartus_ram_probe]
cd [file join $root build quartus_ram_probe]
project_new ram_probe -overwrite
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY onchip_ram
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
foreach source {rtl/soc/platform_pkg.sv rtl/soc/soc_pkg.sv rtl/memory/onchip_ram.sv} {
    set_global_assignment -name SYSTEMVERILOG_FILE [file join $root $source]
}
foreach port {rst req_valid req_ready req.addr[*] req.write req.mask[*] req.wdata[*] rsp_valid rsp_ready rsp.rdata[*] rsp.error loader_we loader_word[*] loader_data[*]} {
    set_instance_assignment -name VIRTUAL_PIN ON -to $port
}
export_assignments
execute_module -tool map
project_close
puts "RAM_PROBE_PASS: isolated default RAM Analysis & Synthesis only"
