create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]
derive_pll_clocks
derive_clock_uncertainty
set_false_path -from [get_ports {KEY[*] SW[*]}]
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]

set sdram_pll_out [get_pins -compatibility_mode -nowarn {*pll1|clk[1]}]
if {[get_collection_size $sdram_pll_out] > 0} {
    create_generated_clock -name sdram_clk_pin -source $sdram_pll_out [get_ports DRAM_CLK]
    set sys_clk [get_clocks {*pll1|clk[0]}]
    set board_min 0.0
    set board_max 1.0
    set sdram_inputs [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_RAS_N DRAM_WE_N DRAM_CS_N DRAM_CKE DRAM_LDQM DRAM_UDQM DRAM_DQ[*]}]
    set_output_delay -clock sdram_clk_pin -max [expr {1.8 + $board_max}] $sdram_inputs
    set_output_delay -clock sdram_clk_pin -min [expr {$board_min - 0.8}] $sdram_inputs
    set_input_delay -clock sdram_clk_pin -max [expr {6.0 + $board_max}] [get_ports {DRAM_DQ[*]}]
    set_input_delay -clock sdram_clk_pin -min [expr {2.5 + $board_min}] [get_ports {DRAM_DQ[*]}]
    set_multicycle_path -setup -from [get_clocks sdram_clk_pin] -to $sys_clk 2
}
