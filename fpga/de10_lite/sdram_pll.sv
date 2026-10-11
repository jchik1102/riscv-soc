module sdram_pll #(
  parameter SDRAM_PHASE_PS = "-3000"
) (
  input logic inclk,
  output logic c0, c1,
  output logic locked
);
  wire [4:0] clocks;
  altpll #(
    .bandwidth_type("AUTO"),
    .clk0_divide_by(1), .clk0_duty_cycle(50), .clk0_multiply_by(1), .clk0_phase_shift("0"),
    .clk1_divide_by(1), .clk1_duty_cycle(50), .clk1_multiply_by(1), .clk1_phase_shift(SDRAM_PHASE_PS),
    .compensate_clock("CLK0"),
    .inclk0_input_frequency(20000),
    .intended_device_family("MAX 10"),
    .lpm_type("altpll"),
    .operation_mode("NORMAL"),
    .pll_type("AUTO"),
    .port_activeclock("PORT_UNUSED"), .port_areset("PORT_UNUSED"), .port_clkbad0("PORT_UNUSED"),
    .port_clkbad1("PORT_UNUSED"), .port_clkloss("PORT_UNUSED"), .port_clkswitch("PORT_UNUSED"),
    .port_configupdate("PORT_UNUSED"), .port_fbin("PORT_UNUSED"), .port_inclk0("PORT_USED"),
    .port_inclk1("PORT_UNUSED"), .port_locked("PORT_USED"), .port_pfdena("PORT_UNUSED"),
    .port_phasecounterselect("PORT_UNUSED"), .port_phasedone("PORT_UNUSED"), .port_phasestep("PORT_UNUSED"),
    .port_phaseupdown("PORT_UNUSED"), .port_pllena("PORT_UNUSED"), .port_scanaclr("PORT_UNUSED"),
    .port_scanclk("PORT_UNUSED"), .port_scanclkena("PORT_UNUSED"), .port_scandata("PORT_UNUSED"),
    .port_scandataout("PORT_UNUSED"), .port_scandone("PORT_UNUSED"), .port_scanread("PORT_UNUSED"),
    .port_scanwrite("PORT_UNUSED"),
    .port_clk0("PORT_USED"), .port_clk1("PORT_USED"), .port_clk2("PORT_UNUSED"), .port_clk3("PORT_UNUSED"),
    .port_clk4("PORT_UNUSED"),
    .self_reset_on_loss_lock("OFF"),
    .width_clock(5)
  ) altpll_component (
    .inclk({1'b0, inclk}),
    .clk(clocks),
    .locked(locked),
    .areset(1'b0),
    .clkswitch(1'b0),
    .configupdate(1'b0),
    .pfdena(1'b1),
    .phasecounterselect(4'b0000),
    .phasestep(1'b0),
    .phaseupdown(1'b0),
    .scanclk(1'b0),
    .scanclkena(1'b1),
    .scandata(1'b0)
  );
  assign c0 = clocks[0];
  assign c1 = clocks[1];
endmodule
