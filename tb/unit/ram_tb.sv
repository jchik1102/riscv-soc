`timescale 1ns/1ps
module ram_tb;
  import soc_pkg::*;
  import platform_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0;
  bus_req_t req = '0;
  bus_rsp_t rsp;
  logic loader_we = 0;
  logic [12:0] loader_word = 0;
  logic [63:0] loader_data = 0;
  onchip_ram dut(.*);
  int checks = 0;
  int accepted_requests = 0;
  always @(posedge clk) if (req_valid && req_ready) accepted_requests++;

  task automatic access(input bit write, input logic [63:0] addr,
      input logic [7:0] mask, input logic [63:0] data,
      input bit expected_error, input logic [63:0] expected_data);
    @(negedge clk);
    req_valid = 1; req = '{addr:addr, write:write, mask:mask, wdata:data};
    do @(posedge clk); while (!req_ready);
    @(negedge clk); req_valid = 0; req = '0;
    repeat (4) begin
      @(negedge clk);
      if (!rsp_valid || rsp.error !== expected_error || rsp.rdata !== expected_data)
        $fatal(1, "RAM mismatch addr=%h error=%b data=%h expected=%h", addr, rsp.error, rsp.rdata, expected_data);
      checks++;
    end
    rsp_ready = 1;
    @(negedge clk); rsp_ready = 0;
    if (rsp_valid) $fatal(1, "Duplicate RAM response");
  endtask

  initial begin
    repeat (2) @(negedge clk);
    loader_we = 1; loader_word = 0; loader_data = 64'h8877665544332211;
    @(negedge clk);
    loader_word = 8191; loader_data = 64'h0123456789abcdef;
    @(negedge clk); loader_we = 0; rst = 0;
    access(0, RAM_BASE, 8'hff, 0, 0, 64'h8877665544332211);
    access(0, RAM_BASE, 8'h0f, 0, 0, 64'h0000000044332211);
    access(0, RAM_BASE, 8'hf0, 0, 0, 64'h8877665500000000);
    access(1, RAM_BASE, 8'h55, 64'hffeeddccbbaa0099, 0, 0);
    access(0, RAM_BASE, 8'hff, 0, 0, 64'h88ee66cc44aa2299);
    for (int lane = 0; lane < 8; lane++) begin
      access(1, RAM_BASE, 8'b1 << lane, 64'h0101010101010101 << lane, 0, 0);
    end
    access(0, RAM_BASE, 8'hff, 0, 0, 64'h8040201008040201);
    access(0, RAM_BASE + RAM_BYTES - 8, 8'hff, 0, 0, 64'h0123456789abcdef);
    access(1, RAM_BASE, 0, ~64'b0, 0, 0);
    access(0, RAM_BASE, 8'hff, 0, 0, 64'h8040201008040201);
    access(0, RAM_BASE - 8, 8'hff, 0, 1, 0);
    access(0, RAM_BASE + RAM_BYTES, 8'hff, 0, 1, 0);
    access(0, RAM_BASE + 64'h100000000, 8'hff, 0, 1, 0);
    access(1, RAM_BASE + 1, 8'hff, ~64'b0, 1, 0);
    access(0, RAM_BASE, 8'hff, 0, 0, 64'h8040201008040201);
    @(negedge clk); req_valid = 1; req.addr = RAM_BASE; req.mask = 8'hff;
    @(negedge clk); req_valid = 0; rst = 1;
    @(negedge clk);
    if (rsp_valid || req_ready) $fatal(1, "RAM reset did not cancel response");
    rst = 0;
    access(0, RAM_BASE, 8'hff, 0, 0, 64'h8040201008040201);
    @(negedge clk);
    req_valid = 1;
    req = '{addr:RAM_BASE, write:1'b1, mask:8'h80, wdata:64'hab00000000000000};
    do @(posedge clk); while (!req_ready);
    @(negedge clk); req_valid = 0; rst = 1;
    @(negedge clk);
    if (rsp_valid || req_ready) $fatal(1,"Write response not canceled by reset");
    rst = 0;
    access(0, RAM_BASE, 8'hff, 0, 0, 64'hab40201008040201);
    $display("RAM_TEST_PASS checks=%0d accepted_requests=%0d", checks, accepted_requests);
    $finish;
  end
  initial begin #20000; $fatal(1, "RAM watchdog"); end
endmodule
