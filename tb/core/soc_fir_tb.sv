`timescale 1ns/1ps
module soc_fir_tb #(parameter bit PIPELINE = 0);
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
  logic [63:0] expected, checksum = 0, status = 0, magic = 0;
  longint unsigned cycles = 0, retired = 0, m_retired = 0, loads = 0, stores = 0;
  localparam logic [63:0] REPORT = RAM_BASE + 64'h8000;
  synthesis_top #(.PIPELINE(PIPELINE)) dut(.*);
  initial begin
    if (!$value$plusargs("IMAGE=%s", image_path)) $fatal(1, "IMAGE required");
    if (!$value$plusargs("EXPECTED=%h", expected)) $fatal(1, "EXPECTED required");
    foreach (image[i]) image[i] = 0;
    $readmemh(image_path, image);
    repeat (2) @(negedge clk);
    for (int word_index = 0; word_index < RAM_BYTES/8; word_index++) begin
      loader_we = 1; loader_word = 13'(word_index);
      for (int lane = 0; lane < 8; lane++) loader_data[8*lane +: 8] = image[8*word_index+lane];
      @(negedge clk);
    end
    loader_we = 0; rst = 0;
  end
  always @(posedge clk) if (!rst && !halted) cycles++;
  always @(negedge clk) if (!rst && trace_valid) begin
    if (dut.trace.mem_wmask == 8'hff && dut.trace.mem_addr == REPORT + 8) checksum = dut.trace.mem_wdata;
    if (dut.trace.mem_wmask == 8'hff && dut.trace.mem_addr == REPORT + 16) status = dut.trace.mem_wdata;
    if (dut.trace.mem_wmask == 8'hff && dut.trace.mem_addr == REPORT) magic = dut.trace.mem_wdata;
    if (dut.trace.mem_wmask != 0) stores++;
    if (dut.trace.mem_rmask != 0) loads++;
    if ((dut.trace.insn[6:0] == 7'h33 || dut.trace.insn[6:0] == 7'h3b) && dut.trace.insn[31:25] == 7'h01) m_retired++;
    if (!dut.trace.trap) retired++;
    else begin
      if (dut.trace.cause != 3 || checksum !== expected || status !== 1 || magic !== 64'h4649523151313500)
        $fatal(1, "FIR result mismatch: cause=%0d checksum=%h expected=%h status=%0d", dut.trace.cause, checksum, expected, status);
      @(negedge clk);
      if (!halted) $fatal(1, "Core did not halt after EBREAK");
      $display("SOC_FIR_TEST_PASS: pipeline=%0d checksum=%h cycles=%0d retired=%0d m=%0d loads=%0d stores=%0d",
               PIPELINE, checksum, cycles, retired, m_retired, loads, stores);
      $finish;
    end
  end
  initial begin #20000000; $fatal(1, "FIR watchdog"); end
endmodule
