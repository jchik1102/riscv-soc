`timescale 1ns/1ps
module board_netlist_tb;
  logic clk = 0;
  always #10 clk = ~clk;
  logic [1:0] KEY = 2'b11;
  logic [9:0] SW = 10'b10_0000_0000;
  logic [9:0] LEDR;
  logic [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
  logic [12:0] DRAM_ADDR;
  logic [1:0] DRAM_BA;
  logic DRAM_CAS_N, DRAM_RAS_N, DRAM_WE_N, DRAM_CS_N, DRAM_CKE, DRAM_CLK, DRAM_LDQM, DRAM_UDQM;
  wire [15:0] DRAM_DQ;
  logic model_clk = 0;
  de10_lite_top dut(.MAX10_CLK1_50(clk), .*);
  always @(DRAM_CLK) model_clk <= #(3.0 - 1.0) DRAM_CLK;
  sdram_model sdram(.clk(model_clk), .cke(DRAM_CKE), .cs_n(DRAM_CS_N), .ras_n(DRAM_RAS_N), .cas_n(DRAM_CAS_N),
    .we_n(DRAM_WE_N), .ba(DRAM_BA), .a(DRAM_ADDR), .dqm({DRAM_UDQM, DRAM_LDQM}), .dq(DRAM_DQ));
  function automatic logic [3:0] digit(input logic [7:0] segments);
    case (segments)
      8'hc0: return 0; 8'hf9: return 1; 8'ha4: return 2; 8'hb0: return 3; 8'h99: return 4; 8'h92: return 5;
      8'h82: return 6; 8'hf8: return 7; 8'h80: return 8; 8'h90: return 9; 8'h88: return 10; 8'h83: return 11;
      8'hc6: return 12; 8'ha1: return 13; 8'h86: return 14; default: return 15;
    endcase
  endfunction
  function automatic logic [23:0] shown();
    return {digit(HEX5), digit(HEX4), digit(HEX3), digit(HEX2), digit(HEX1), digit(HEX0)};
  endfunction
  initial begin
    int guard = 0;
    while (LEDR[0] !== 1 && LEDR[1] !== 1) begin @(posedge clk); if (++guard > 1500000) $fatal(1, "NETLIST_TB watchdog, LEDR=%b", LEDR); end
    repeat (20) @(posedge clk);
    SW[1:0] = 2'd1; repeat (10) @(posedge clk);
    $display("NETLIST_TB LEDR=%b errors(HEX)=%h model_errors=%0d writes=%0d reads=%0d refresh=%0d", LEDR, shown(),
             sdram.errors, sdram.n_write, sdram.n_read, sdram.n_refresh);
    if (LEDR[1] === 1) begin
      SW[8] = 1;
      for (int i = 0; i < 4; i++) begin SW[1:0] = 2'(i); repeat (10) @(posedge clk); $display("NETLIST_TB diag SW=%0d HEX=%h", i, shown()); end
      $fatal(1, "NETLIST_TB: tester reported errors in the synthesized netlist");
    end
    if (sdram.errors) $fatal(1, "NETLIST_TB: SDRAM model errors");
    $display("NETLIST_TEST_PASS");
    $finish;
  end
endmodule
