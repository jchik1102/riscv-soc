package require ::quartus::sta
set revision [lindex $argv 0]
project_open $revision
create_timing_netlist
read_sdc
update_timing_netlist
set out [open sdram_io_timing.txt w]
foreach_in_collection op [get_available_operating_conditions] {
    set_operating_conditions $op
    update_timing_netlist
    set name [get_operating_conditions_info -display_name $op]
    foreach {label from to} {
        "SDRAM DQ -> capture registers" {DRAM_DQ[*]} {}
        "registers -> SDRAM pins" {} {DRAM_*}
    } {
        foreach kind {setup hold} {
            if {$from ne ""} {
                set paths [get_timing_paths -from [get_ports $from] -$kind -npaths 1]
            } else {
                set paths [get_timing_paths -to [get_ports $to] -$kind -npaths 1]
            }
            foreach_in_collection p $paths {
                puts $out [format "%-28s %-24s %-5s slack %7.3f ns  from %s to %s" $name $label $kind \
                    [get_path_info $p -slack] [get_node_info -name [get_path_info $p -from]] [get_node_info -name [get_path_info $p -to]]]
            }
        }
    }
}
report_ucp -file sdram_unconstrained.txt
close $out
project_close
