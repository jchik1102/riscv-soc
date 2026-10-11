`timescale 1ns/1ps
module sdram_pll #(
  parameter SDRAM_PHASE_PS = "-3000",
  parameter real LEAD_NS = 1.0
) (
  input logic inclk,
  output logic c0 = 0, c1,
  output logic locked = 0
);
  always @(inclk) c0 <= #(LEAD_NS) inclk;
  assign c1 = inclk & locked;
  initial begin
    repeat (10) @(posedge inclk);
    locked = 1;
  end
endmodule
