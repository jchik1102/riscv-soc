set_location_assignment PIN_C14 -to HEX0[0]
set_location_assignment PIN_E15 -to HEX0[1]
set_location_assignment PIN_C15 -to HEX0[2]
set_location_assignment PIN_C16 -to HEX0[3]
set_location_assignment PIN_E16 -to HEX0[4]
set_location_assignment PIN_D17 -to HEX0[5]
set_location_assignment PIN_C17 -to HEX0[6]
set_location_assignment PIN_D15 -to HEX0[7]
set_location_assignment PIN_C18 -to HEX1[0]
set_location_assignment PIN_D18 -to HEX1[1]
set_location_assignment PIN_E18 -to HEX1[2]
set_location_assignment PIN_B16 -to HEX1[3]
set_location_assignment PIN_A17 -to HEX1[4]
set_location_assignment PIN_A18 -to HEX1[5]
set_location_assignment PIN_B17 -to HEX1[6]
set_location_assignment PIN_A16 -to HEX1[7]
set_location_assignment PIN_B20 -to HEX2[0]
set_location_assignment PIN_A20 -to HEX2[1]
set_location_assignment PIN_B19 -to HEX2[2]
set_location_assignment PIN_A21 -to HEX2[3]
set_location_assignment PIN_B21 -to HEX2[4]
set_location_assignment PIN_C22 -to HEX2[5]
set_location_assignment PIN_B22 -to HEX2[6]
set_location_assignment PIN_A19 -to HEX2[7]
set_location_assignment PIN_F21 -to HEX3[0]
set_location_assignment PIN_E22 -to HEX3[1]
set_location_assignment PIN_E21 -to HEX3[2]
set_location_assignment PIN_C19 -to HEX3[3]
set_location_assignment PIN_C20 -to HEX3[4]
set_location_assignment PIN_D19 -to HEX3[5]
set_location_assignment PIN_E17 -to HEX3[6]
set_location_assignment PIN_D22 -to HEX3[7]
set_location_assignment PIN_F18 -to HEX4[0]
set_location_assignment PIN_E20 -to HEX4[1]
set_location_assignment PIN_E19 -to HEX4[2]
set_location_assignment PIN_J18 -to HEX4[3]
set_location_assignment PIN_H19 -to HEX4[4]
set_location_assignment PIN_F19 -to HEX4[5]
set_location_assignment PIN_F20 -to HEX4[6]
set_location_assignment PIN_F17 -to HEX4[7]
set_location_assignment PIN_J20 -to HEX5[0]
set_location_assignment PIN_K20 -to HEX5[1]
set_location_assignment PIN_L18 -to HEX5[2]
set_location_assignment PIN_N18 -to HEX5[3]
set_location_assignment PIN_M20 -to HEX5[4]
set_location_assignment PIN_N19 -to HEX5[5]
set_location_assignment PIN_N20 -to HEX5[6]
set_location_assignment PIN_L19 -to HEX5[7]
set_location_assignment PIN_B8 -to KEY[0]
set_location_assignment PIN_A7 -to KEY[1]
set_location_assignment PIN_A8 -to LEDR[0]
set_location_assignment PIN_A9 -to LEDR[1]
set_location_assignment PIN_A10 -to LEDR[2]
set_location_assignment PIN_B10 -to LEDR[3]
set_location_assignment PIN_D13 -to LEDR[4]
set_location_assignment PIN_C13 -to LEDR[5]
set_location_assignment PIN_E14 -to LEDR[6]
set_location_assignment PIN_D14 -to LEDR[7]
set_location_assignment PIN_A11 -to LEDR[8]
set_location_assignment PIN_B11 -to LEDR[9]
set_location_assignment PIN_P11 -to MAX10_CLK1_50
set_location_assignment PIN_C10 -to SW[0]
set_location_assignment PIN_C11 -to SW[1]
set_location_assignment PIN_D12 -to SW[2]
set_location_assignment PIN_C12 -to SW[3]
set_location_assignment PIN_A12 -to SW[4]
set_location_assignment PIN_B12 -to SW[5]
set_location_assignment PIN_A13 -to SW[6]
set_location_assignment PIN_A14 -to SW[7]
set_location_assignment PIN_B14 -to SW[8]
set_location_assignment PIN_F15 -to SW[9]
foreach port {MAX10_CLK1_50 SW[*] LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]} {
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to $port
}
set_instance_assignment -name IO_STANDARD "3.3 V SCHMITT TRIGGER" -to KEY[0]
set_instance_assignment -name IO_STANDARD "3.3 V SCHMITT TRIGGER" -to KEY[1]
foreach port {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]} {
    set_instance_assignment -name CURRENT_STRENGTH_NEW 8MA -to $port
}
set dram_pins {
    DRAM_ADDR[0] U17 DRAM_ADDR[1] W19 DRAM_ADDR[2] V18 DRAM_ADDR[3] U18 DRAM_ADDR[4] U19
    DRAM_ADDR[5] T18 DRAM_ADDR[6] T19 DRAM_ADDR[7] R18 DRAM_ADDR[8] P18 DRAM_ADDR[9] P19
    DRAM_ADDR[10] T20 DRAM_ADDR[11] P20 DRAM_ADDR[12] R20 DRAM_BA[0] T21 DRAM_BA[1] T22
    DRAM_CAS_N U21 DRAM_CKE N22 DRAM_CLK L14 DRAM_CS_N U20 DRAM_LDQM V22 DRAM_RAS_N U22
    DRAM_UDQM J21 DRAM_WE_N V20
    DRAM_DQ[0] Y21 DRAM_DQ[1] Y20 DRAM_DQ[2] AA22 DRAM_DQ[3] AA21 DRAM_DQ[4] Y22 DRAM_DQ[5] W22
    DRAM_DQ[6] W20 DRAM_DQ[7] V21 DRAM_DQ[8] P21 DRAM_DQ[9] J22 DRAM_DQ[10] H21 DRAM_DQ[11] H22
    DRAM_DQ[12] G22 DRAM_DQ[13] G20 DRAM_DQ[14] G19 DRAM_DQ[15] F22
}
foreach {port pin} $dram_pins {
    set_location_assignment PIN_$pin -to $port
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to $port
}
foreach port {DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_RAS_N DRAM_WE_N DRAM_CS_N DRAM_LDQM DRAM_UDQM DRAM_DQ[*]} {
    set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to $port
}
set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER ON -to DRAM_DQ[*]
set_instance_assignment -name FAST_INPUT_REGISTER ON -to DRAM_DQ[*]
