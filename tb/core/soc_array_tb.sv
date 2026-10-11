`timescale 1ns/1ps
module soc_array_tb #(parameter bit PIPELINE = 0);
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
  int stores = 0, loads = 0, retired = 0;
  synthesis_top #(.PIPELINE(PIPELINE)) dut(.*);
  logic [63:0] x10;
  if (PIPELINE) begin : a0_pipeline assign x10 = dut.soc.pipeline.core.rf.regs[10]; end
  else begin : a0_multicycle assign x10 = dut.soc.multicycle.core.rf.regs[10]; end
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
    if (dut.trace.mem_wmask != 0) stores++;
    if (dut.trace.mem_rmask != 0) begin
      if (loads < 16 && (trace_rd != 7 || trace_result !== 64'($signed(loads-8))))
        $fatal(1,"Array signed word load mismatch at %0d",loads);
      if (loads == 16 && (trace_rd != 11 || trace_result !== 64'h00000000fffffff8))
        $fatal(1,"Array LWU result mismatch");
      if (loads == 17 && (trace_rd != 12 || trace_result !== 64'hfffffffffffffff8))
        $fatal(1,"Array LD result mismatch");
      loads++;
    end
    if (!dut.trace.trap) retired++;
    else begin
      if (!halted || dut.trace.cause != 3 || stores != 17 || loads != 18 ||
          x10 !== 64'hfffffffffffffff8)
        $fatal(1,"Array terminal state mismatch: stores=%0d loads=%0d",stores,loads);
      $display("SOC_ARRAY_TEST_PASS: assembly -8..7 sum=-8, LWU/LD, %0d stores %0d loads %0d retired",stores,loads,retired);
      $finish;
    end
  end
  initial begin #1000000; $fatal(1,"Synchronous RAM array watchdog"); end
endmodule
