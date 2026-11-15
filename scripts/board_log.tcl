# Reads a running DE10-Lite demo image through its JTAG readout (the in-system
# source/probe in fpga/de10_lite/de10_lite_top.sv) and prints everything the HEX
# displays can show, plus the full counters. Run by scripts/board_log.ps1 with
# quartus_stp -t; the output is saved under results/board/.
#
#   quartus_stp -t board_log.tcl <demo 0..5> [timeout seconds]
#
# Probe layout (240 bits): [23:0] displayed value, [24] pass, [25] fail,
# [26] halted, [27] loading, [28] tester mode, [29] SDRAM ready, [30] final trap,
# [36:31] final cause, [39:37] demo, [40] pipeline, [44:41] layout version,
# [111:48] checksum, [175:112] cycles, [239:176] retired instructions.
# Source (11 bits): [10] use virtual switches, [9:0] virtual SW9..SW0.

lassign $argv want_demo timeout
if {$want_demo eq ""} { puts "usage: board_log.tcl <demo 0..5> \[timeout seconds\]"; exit 2 }
if {$timeout eq ""} { set timeout 120 }

proc field {value low width} { expr {($value >> $low) & ((1 << $width) - 1)} }

proc read_probe {} {
    # Two equal consecutive reads: the probe is sampled by the JTAG clock, so a
    # value that is still changing must not be recorded.
    for {set attempt 0} {$attempt < 50} {incr attempt} {
        set a [read_probe_data -instance_index 0 -value_in_hex]
        set b [read_probe_data -instance_index 0 -value_in_hex]
        if {$a eq $b} { return [expr "0x$a"] }
    }
    error "Probe value never stable"
}

proc view {switches} {
    # Select a display view with the virtual switches and return the 24-bit value.
    write_source_data -instance_index 0 -value_in_hex -value [format %03X [expr {0x400 | $switches}]]
    after 20
    return [field [read_probe] 0 24]
}

set hardware [lindex [get_hardware_names] 0]
if {$hardware eq ""} { puts "BOARD_LOG_FAIL: no JTAG cable found"; exit 1 }
set device [lindex [get_device_names -hardware_name $hardware] 0]
puts "cable: $hardware"
puts "device: $device"
start_insystem_source_probe -hardware_name $hardware -device_name $device

set status 1
if {[catch {
    write_source_data -instance_index 0 -value_in_hex -value 000
    set deadline [expr {[clock seconds] + $timeout}]
    while 1 {
        # While the program runs the cycle counter moves, so two reads differ:
        # that means "still running", not an error. Only a pair of equal reads
        # with pass or fail set ends the wait.
        set a [read_probe_data -instance_index 0 -value_in_hex]
        set b [read_probe_data -instance_index 0 -value_in_hex]
        set p [expr "0x$b"]
        if {$a eq $b && ([field $p 24 1] || [field $p 25 1])} break
        if {[clock seconds] >= $deadline} { error "demo did not finish within $timeout s (halted=[field $p 26 1] loading=[field $p 27 1] stable=[expr {$a eq $b}])" }
        after 200
    }
    after 300
    set p [read_probe]
    set demo [field $p 37 3]
    puts [format "layout_version: %d" [field $p 41 4]]
    puts [format "demo: %d  pipeline: %d" $demo [field $p 40 1]]
    puts [format "pass: %d  fail: %d  halted: %d  loading: %d  tester_mode: %d  sdram_ready: %d" \
        [field $p 24 1] [field $p 25 1] [field $p 26 1] [field $p 27 1] [field $p 28 1] [field $p 29 1]]
    puts [format "final_trap: %d  final_cause: %d" [field $p 30 1] [field $p 31 6]]
    puts [format "checksum: 0x%016x" [field $p 48 64]]
    puts [format "cycles: %d" [field $p 112 64]]
    puts [format "retired: %d" [field $p 176 64]]
    if {$demo != $want_demo} { error "image is demo $demo, expected demo $want_demo" }
    if {[field $p 41 4] != 1} { error "unknown probe layout version" }

    puts [format "view checksum (SW1 SW0 = 00): %06x" [view 0]]
    if {$demo <= 1} {
        puts [format "view cycles\[23:0\] (01): %06x" [view 1]]
        puts [format "view cycles\[47:24\] (10): %06x" [view 2]]
        puts [format "view retired\[23:0\] (11): %06x" [view 3]]
    } elseif {$demo == 2} {
        puts [format "view phase/errors (01): %06x" [view 1]]
        puts [format "view runs (10): %06x" [view 2]]
        puts [format "view cycles\[47:24\] (11): %06x" [view 3]]
    } elseif {$demo == 3} {
        puts [format "view phase/timer ticks (01): %06x" [view 1]]
        foreach v {2 3} {
            for {set mode 0} {$mode < 4} {incr mode} {
                for {set where 0} {$where < 2} {incr where} {
                    set sw [expr {$v | ($mode << 2) | ($where << 4)}]
                    puts [format "s6 cycles view=%d mode(SW3 SW2)=%d kernel(SW4)=%d: %d" $v $mode $where [view $sw]]
                }
            }
        }
    } elseif {$demo == 4} {
        puts [format "view phase/timer ticks (01): %06x" [view 1]]
        for {set mode 0} {$mode < 2} {incr mode} {
            for {set metric 0} {$metric < 8} {incr metric} {
                set sw [expr {2 | ($metric << 2) | ($mode << 5)}]
                puts [format "s7 total mode(SW5)=%d metric(SW4..SW2)=%d: %d" $mode $metric [view $sw]]
            }
        }
        set v [view 3]
        puts [format "s7 N=%d cases=%d mismatches=%d" [field $v 20 4] [field $v 12 8] [field $v 0 12]]
    } else {
        puts [format "view phase/timer ticks (01): %06x" [view 1]]
        for {set workload 0} {$workload < 2} {incr workload} {
            for {set mode 0} {$mode < 2} {incr mode} {
                for {set method 0} {$method < 3} {incr method} {
                    for {set metric 0} {$metric < 8} {incr metric} {
                        set sw [expr {2 | ($metric << 2) | ($method << 5) | ($mode << 7) | ($workload << 8)}]
                        puts [format "s8 workload(SW8)=%d mode(SW7)=%d method(SW6 SW5)=%d metric(SW4..SW2)=%d: %d" \
                            $workload $mode $method $metric [view $sw]]
                    }
                }
            }
        }
        set v [view 3]
        puts [format "s8 N=%d cases=%d mismatches=%d" [field $v 20 4] [field $v 12 8] [field $v 0 12]]
    }
    set p [read_probe]
    if {[field $p 24 1] == 1 && [field $p 25 1] == 0} {
        puts "BOARD_LOG_PASS: demo $demo passed its own checks on the board (pass LED on, fail LED off)"
        set status 0
    } else {
        puts "BOARD_LOG_FAIL: demo $demo reports pass=[field $p 24 1] fail=[field $p 25 1]"
    }
} message]} {
    puts "BOARD_LOG_FAIL: $message"
}
catch { write_source_data -instance_index 0 -value_in_hex -value 000 }
end_insystem_source_probe
exit $status
