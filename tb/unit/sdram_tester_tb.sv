`timescale 1ns/1ps
module sdram_tester_tb;
  import soc_pkg::*;
  localparam real PERIOD = 20.0, LEAD_NS = 1.0;
  localparam logic [63:0] BASE = platform_pkg::SDRAM_BASE;
  localparam logic [63:0] BYTES = 64'h2000;
  logic clk = 0, sdram_clk = 0, sdram_clk_run = 0;
  always #(PERIOD / 2) clk = ~clk;
  always @(clk) sdram_clk <= #(PERIOD - LEAD_NS) clk & sdram_clk_run;
  logic rst = 1;
  logic req_valid, req_ready, rsp_valid, rsp_ready, init_done, verifying;
  bus_req_t req;
  bus_rsp_t rsp;
  logic [15:0] loops;
  logic [31:0] errors;
  logic [63:0] first_error, address;
  logic [1:0] pass;
  logic cke, cs_n, ras_n, cas_n, we_n, dq_oe;
  logic [1:0] ba, dqm;
  logic [12:0] a;
  logic [15:0] dq_o, stuck = 0;
  wire [15:0] dq;
  assign dq = dq_oe ? dq_o : 16'bz;

  sdram_tester #(.BYTES(BYTES)) tester(.clk(clk), .rst(rst || !init_done), .req_valid(req_valid), .req_ready(req_ready),
    .req(req), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp), .loops(loops), .errors(errors),
    .first_error(first_error), .pass(pass), .verifying(verifying), .address(address),
    .first_rdata(), .first_expected());
  bus2_rsp_t rsp2;
  assign rsp = to_bus1(rsp2);
  sdram_ctrl ctrl(.clk(clk), .rst(rst), .bus_rst(1'b0), .req_valid(req_valid), .req_ready(req_ready), .req(to_bus2(req)),
    .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp2), .init_done(init_done),
    .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n),
    .sdram_ba(ba), .sdram_a(a), .sdram_dqm(dqm), .sdram_dq_o(dq_o), .sdram_dq_oe(dq_oe), .sdram_dq_i(dq & ~stuck), .extra_wait(2'b00), .extra_capture(1'b0));
  sdram_model model(.clk(sdram_clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .a(a), .dqm(dqm), .dq(dq));

  function automatic logic [63:0] xorshift(input logic [63:0] x);
    x = x ^ (x << 13); x = x ^ (x >> 7); return x ^ (x << 17);
  endfunction
  task automatic check_contents();
    logic [63:0] state = 64'h9e3779b97f4a7c15, value, wdata;
    int bad = 0;
    for (longint beat = 0; beat < BYTES / 8; beat++) begin
      logic [7:0] mask = 8'(1 << beat[2:0]) | 8'(1 << beat[5:3]);
      state = xorshift(state);
      wdata = {state[55:0], state[63:56]} ^ 64'ha5a5_5a5a_c3c3_3c3c;
      for (int lane = 0; lane < 8; lane++) begin
        longint unsigned offset = beat * 8 + lane;
        logic [7:0] want = mask[lane] ? wdata[lane*8 +: 8] : state[lane*8 +: 8];
        logic [7:0] got = model.peek(offset[12:11], offset[25:13], offset[10:1], offset[0]);
        if (got !== want) bad++;
      end
    end
    if (bad) $fatal(1, "SDRAM_TESTER_TB: %0d region bytes differ from the expected pass-3 contents", bad);
  endtask

  initial begin
    repeat (3) @(posedge clk);
    sdram_clk_run = 1;
    repeat (3) @(posedge clk);
    rst <= 0;
    wait (loops == 1);
    @(posedge clk);
    check_contents();
    wait (loops == 2);
    @(posedge clk);
    check_contents();
    if (errors != 0 || model.errors != 0) $fatal(1, "SDRAM_TESTER_TB: clean loops reported %0d errors (model %0d)", errors, model.errors);
    $display("SDRAM_TESTER_TB clean: loops=%0d errors=0 model writes=%0d reads=%0d", loops, model.n_write, model.n_read);
    stuck = 16'h0020;
    wait (loops == 3);
    if (errors == 0) $fatal(1, "SDRAM_TESTER_TB: stuck-at DQ bit not detected");
    if (first_error < BASE || first_error >= BASE + BYTES || first_error[2:0] != 0)
      $fatal(1, "SDRAM_TESTER_TB: first error address %h outside the region", first_error);
    $display("SDRAM_TESTER_TB injected stuck-at-0 DQ5: errors=%0d first_error=%h", errors, first_error);
    $display("SDRAM_TESTER_TEST_PASS");
    $finish;
  end
  initial begin
    #(PERIOD * 3000000);
    $fatal(1, "SDRAM_TESTER_TB watchdog");
  end
endmodule
