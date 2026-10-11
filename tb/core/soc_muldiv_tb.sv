`timescale 1ns/1ps
module soc_muldiv_tb #(parameter bit PIPELINE = 0);
  import platform_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic loader_we = 0;
  logic [12:0] loader_word = 0;
  logic [63:0] loader_data = 0;
  logic trace_valid, halted;
  logic [63:0] trace_pc, trace_result;
  logic [4:0] trace_rd;
  logic uart_tx, uart_rx = 1;
  byte unsigned image [0:RAM_BYTES-1];
  string image_path;
  int results = 0, retired = 0, m_retired = 0;
  logic [63:0] expected [15] = '{64'hfffffffffffffff2, 64'h4000000000000000, 64'hffffffffffffffff,
    64'hfffffffffffffffe, 64'h8000000000000000, 64'h7ffffffffffffffc, 64'hffffffffffffffff,
    64'h0000000000000001, 64'hffffffffffffffff, 64'hffffffffffffff97, 64'hfffffffffffffffd,
    64'h000000007ffffffc, 64'h000000000000000f, 64'h0000000000000001, 64'h00000000221465f0};
  synthesis_top #(.PIPELINE(PIPELINE)) dut(.*);
  initial begin
    if (!$value$plusargs("IMAGE=%s", image_path)) $fatal(1,"IMAGE required");
    foreach (image[i]) image[i] = 0;
    $readmemh(image_path,image);
    repeat (2) @(negedge clk);
    for (int word_index=0; word_index<RAM_BYTES/8; word_index++) begin
      loader_we = 1; loader_word = 13'(word_index);
      for (int lane=0; lane<8; lane++) loader_data[8*lane +: 8] = image[8*word_index+lane];
      @(negedge clk);
    end
    loader_we = 0; rst = 0;
  end
  always @(negedge clk) if (!rst && trace_valid) begin
    if (dut.trace.mem_wmask == 8'hff && dut.trace.insn[19:15] == 5'd8) begin
      if (results >= 15 || dut.trace.mem_wdata !== expected[results])
        $fatal(1,"M result %0d mismatch: %016h", results, dut.trace.mem_wdata);
      results++;
    end
    if ((dut.trace.insn[6:0] == 7'h33 || dut.trace.insn[6:0] == 7'h3b) && dut.trace.insn[31:25] == 7'h01) m_retired++;
    if (!dut.trace.trap) retired++;
    else begin
      if (!halted || dut.trace.cause != 3 || results != 15)
        $fatal(1,"Terminal state mismatch: cause=%0d results=%0d", dut.trace.cause, results);
      $display("SOC_MULDIV_TEST_PASS: GCC RV64IM firmware, %0d checked results, %0d M retired, %0d retired",
               results, m_retired, retired);
      $finish;
    end
  end
  initial begin #3000000; $fatal(1,"Synchronous RAM M firmware watchdog"); end
endmodule
