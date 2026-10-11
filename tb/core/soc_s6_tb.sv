`timescale 1ns/1ps
module soc_s6_tb #(
  parameter int ICACHE_BYTES = 2048,
  parameter int DCACHE_BYTES = 2048
);
  import soc_pkg::*;
  import platform_pkg::*;
  localparam real PERIOD = 20.0, LEAD_NS = 1.0;
  logic clk = 0, sdram_clk = 0, sdram_clk_run = 0;
  always #(PERIOD / 2) clk = ~clk;
  always @(clk) sdram_clk <= #(PERIOD - LEAD_NS) clk & sdram_clk_run;

  logic rst = 1, ctrl_rst = 1;
  logic loader_we = 0;
  logic [12:0] loader_word = 0;
  logic [63:0] loader_data = 0;
  logic trace_valid, halted, uart_tx, uart_rx = 1;
  retire_t trace;
  logic event_retired, event_mem_wait, event_arith_wait, event_fetch_wait, event_load_use, event_redirect;
  logic sdram_req_valid, sdram_req_ready, sdram_rsp_valid, sdram_rsp_ready, init_done;
  logic [1:0] cache_enable_init = 2'b11;
  bus2_req_t sdram_req;
  bus2_rsp_t sdram_rsp;
  logic cke, cs_n, ras_n, cas_n, we_n, dq_oe;
  logic [1:0] ba, dqm;
  logic [12:0] a;
  logic [15:0] dq_o;
  wire [15:0] dq;
  assign dq = dq_oe ? dq_o : 16'bz;

  cpu_soc #(.PIPELINE(1), .UART_DIVISOR(16'd16), .SDRAM(1), .CACHE(1),
            .ICACHE_BYTES(ICACHE_BYTES), .DCACHE_BYTES(DCACHE_BYTES)) dut(.*);
  sdram_ctrl sdram(.clk(clk), .rst(ctrl_rst), .bus_rst(rst),
    .req_valid(sdram_req_valid), .req_ready(sdram_req_ready), .req(sdram_req),
    .rsp_valid(sdram_rsp_valid), .rsp_ready(sdram_rsp_ready), .rsp(sdram_rsp), .init_done(init_done),
    .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n),
    .sdram_ba(ba), .sdram_a(a), .sdram_dqm(dqm), .sdram_dq_o(dq_o), .sdram_dq_oe(dq_oe), .sdram_dq_i(dq), .extra_wait(2'b00), .extra_capture(1'b0));
  sdram_model model(.clk(sdram_clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .a(a), .dqm(dqm), .dq(dq));

  byte unsigned image [0:RAM_BYTES-1];
  byte unsigned final_ram [0:RAM_BYTES-1];
  string image_path, trace_path;
  int fd, mem_fd, interrupts = 0, cycles = 0, reset_at = -1, reset_fill = 0, cache_en = 3;
  int n_fill [2] = '{0, 0}, n_read [2] = '{0, 0}, n_write = 0, n_fence = 0, fill_cycles = 0, sdram_wait_cycles = 0;
  int ev [7] = '{0, 0, 0, 0, 0, 0, 0};
  bit reset_done = 0;

  initial begin
    if (!$value$plusargs("IMAGE=%s", image_path)) $fatal(1, "IMAGE required");
    if (!$value$plusargs("TRACE=%s", trace_path)) $fatal(1, "TRACE required");
    if ($value$plusargs("RESET_AT=%d", reset_at)) begin end
    if ($value$plusargs("RESET_FILL=%d", reset_fill)) begin end
    if ($value$plusargs("CACHE_EN=%d", cache_en)) begin end
    cache_enable_init = 2'(cache_en);
    foreach (image[i]) image[i] = 0;
    $readmemh(image_path, image);
    fd = $fopen(trace_path, "w");
    $fdisplay(fd, "order,pc,insn,next_pc,rd,rd_data,mem_addr,mem_rmask,mem_wmask,mem_rdata,mem_wdata,trap,cause,intr");
    repeat (2) @(negedge clk);
    sdram_clk_run = 1;
    ctrl_rst = 0;
    for (int w = 0; w < RAM_BYTES/8; w++) begin
      loader_we = 1; loader_word = 13'(w);
      for (int lane = 0; lane < 8; lane++) loader_data[8*lane +: 8] = image[8*w + lane];
      @(negedge clk);
    end
    loader_we = 0; rst = 0;
  end

  logic ir, iq, r, q, sq_d, sq_i, fi;
  assign ir = dut.pipeline.core.irsp_valid && dut.pipeline.core.irsp_ready;
  assign iq = dut.pipeline.core.ireq_valid && dut.pipeline.core.ireq_ready;
  assign r = dut.pipeline.core.drsp_valid && dut.pipeline.core.drsp_ready;
  assign q = dut.pipeline.core.dreq_valid && dut.pipeline.core.dreq_ready;
  assign sq_d = dut.pipeline.caches.sdram_arbiter.m0_req_valid && dut.pipeline.caches.sdram_arbiter.m0_req_ready;
  assign sq_i = dut.pipeline.caches.sdram_arbiter.m1_req_valid && dut.pipeline.caches.sdram_arbiter.m1_req_ready;
  assign fi = dut.pipeline.core.icache_inv;

  always @(posedge clk) if (!rst) begin
    cycles++;
    if (ir || iq || r || q || sq_d || sq_i || fi) $fdisplay(fd, "T,%0d", cycles);
    if (ir) $fdisplay(fd, "IR,%01h,%016h", dut.pipeline.core.irsp.error, dut.pipeline.core.irsp.rdata);
    if (iq) $fdisplay(fd, "IQ,%016h,%01h,%02h,%016h", dut.pipeline.core.ireq.addr, dut.pipeline.core.ireq.write,
                      dut.pipeline.core.ireq.mask, dut.pipeline.core.ireq.wdata);
    if (r) $fdisplay(fd, "R,%01h,%016h", dut.pipeline.core.drsp.error, dut.pipeline.core.drsp.rdata);
    if (q) $fdisplay(fd, "Q,%016h,%01h,%02h,%016h", dut.pipeline.core.dreq.addr, dut.pipeline.core.dreq.write,
                     dut.pipeline.core.dreq.mask, dut.pipeline.core.dreq.wdata);
    if (sq_d) $fdisplay(fd, "SQ,D,%016h,%01h,%02h,%016h,%01h", dut.pipeline.caches.dc_mreq.addr, dut.pipeline.caches.dc_mreq.write,
                        dut.pipeline.caches.dc_mreq.mask, dut.pipeline.caches.dc_mreq.wdata, dut.pipeline.caches.dc_mreq.burst);
    if (sq_i) $fdisplay(fd, "SQ,I,%016h,%01h,%02h,%016h,%01h", dut.pipeline.caches.ic_mreq.addr, dut.pipeline.caches.ic_mreq.write,
                        dut.pipeline.caches.ic_mreq.mask, dut.pipeline.caches.ic_mreq.wdata, dut.pipeline.caches.ic_mreq.burst);
    if (fi) begin $fdisplay(fd, "FI"); n_fence++; end
    if (sq_d) begin if (dut.pipeline.caches.dc_mreq.burst == 3) n_fill[0]++; else if (dut.pipeline.caches.dc_mreq.write) n_write++; else n_read[0]++; end
    if (sq_i) begin if (dut.pipeline.caches.ic_mreq.burst == 3) n_fill[1]++; else n_read[1]++; end
    if (sdram_req_valid && sdram_req.burst != 0) fill_cycles++;
    if (sdram_req_valid && !sdram_req_ready) sdram_wait_cycles++;
    if (dut.pipeline.ev_i_access) ev[0]++;
    if (dut.pipeline.ev_i_miss) ev[1]++;
    if (dut.pipeline.ev_i_uncached) ev[2]++;
    if (dut.pipeline.ev_d_access) ev[3]++;
    if (dut.pipeline.ev_d_miss) ev[4]++;
    if (dut.pipeline.ev_d_uncached) ev[5]++;
    if (dut.pipeline.ev_d_write) ev[6]++;
    if (cycles > 8000000) $fatal(1, "S6 SoC watchdog");
    if (!reset_done && reset_at >= 0 && cycles >= reset_at && sdram.pending &&
        (!reset_fill || (sdram.op_len == 3 && dut.pipeline.caches.sdram_arbiter.owner))) begin
      rst <= 1;
      reset_done = 1;
      $fdisplay(fd, "RESET");
      $display("SOC_S6 CPU reset at cycle %0d (SDRAM state %0d, write %0b, burst %0d)", cycles, sdram.state, sdram.op_write, sdram.op_len);
    end
  end
  int reset_hold = 0;
  always @(posedge clk) if (rst && reset_done) begin
    reset_hold++;
    if (reset_hold == 3) rst <= 0;
  end

  assert property (@(posedge clk) disable iff (rst) sdram_req_valid && !sdram_req_ready |=> sdram_req_valid && $stable(sdram_req))
    else $fatal(1, "SDRAM request changed under backpressure");
  assert property (@(posedge clk) rst |-> !sdram_req_valid && !sdram_rsp_ready)
    else $fatal(1, "SDRAM port active in reset");
  assert property (@(posedge clk) disable iff (rst) sdram_req_valid |-> sdram_req.addr >= SDRAM_BASE && sdram_req.addr - SDRAM_BASE < SDRAM_BYTES)
    else $fatal(1, "A non-SDRAM address reached the SDRAM port");
  assert property (@(posedge clk) disable iff (rst) sdram_req_valid && sdram_req.burst != 0 |->
                   sdram_req.burst == 3 && !sdram_req.write && sdram_req.mask == 8'hff && sdram_req.addr[4:0] == 0)
    else $fatal(1, "Malformed line fill on the SDRAM port");

  genvar lane;
  generate for (lane = 0; lane < 8; lane++) begin : dump
    task automatic copy_lane();
      for (int w = 0; w < RAM_BYTES/8; w++) final_ram[8*w + lane] = dut.ram.lanes[lane].data[w];
    endtask
  end endgenerate

  always @(negedge clk) if (!rst && trace_valid) begin
    $fdisplay(fd, "%0d,%016h,%08h,%016h,%0d,%016h,%016h,%02h,%02h,%016h,%016h,%0d,%0d,%0d",
      trace.order, trace.pc, trace.insn, trace.next_pc, trace.rd, trace.rd_data, trace.mem_addr,
      trace.mem_rmask, trace.mem_wmask, trace.mem_rdata, trace.mem_wdata, trace.trap, trace.cause, trace.intr);
    if (trace.intr) interrupts++;
    if (halted) begin
      repeat (40) @(negedge clk);
      dump[0].copy_lane(); dump[1].copy_lane(); dump[2].copy_lane(); dump[3].copy_lane();
      dump[4].copy_lane(); dump[5].copy_lane(); dump[6].copy_lane(); dump[7].copy_lane();
      mem_fd = $fopen({trace_path, ".mem"}, "w");
      foreach (final_ram[i]) $fdisplay(mem_fd, "%02h", final_ram[i]);
      $fclose(mem_fd);
      model.dump({trace_path, ".sdram"});
      $fclose(fd);
      if (reset_at >= 0 && !reset_done) $fatal(1, "Requested CPU reset during an SDRAM access was not exercised");
      if (model.errors) $fatal(1, "SDRAM model reported %0d protocol/timing errors", model.errors);
      $display("SOC_S6 config icache=%0d dcache=%0d cache_en=%0d", ICACHE_BYTES, DCACHE_BYTES, cache_en);
      $display("SOC_S6 memory: d_fill=%0d d_read=%0d d_write=%0d i_fill=%0d i_read=%0d fence_i=%0d fill_request_cycles=%0d wait_cycles=%0d",
               n_fill[0], n_read[0], n_write, n_fill[1], n_read[1], n_fence, fill_cycles, sdram_wait_cycles);
      $display("SOC_S6 events: i_access=%0d i_miss=%0d i_uncached=%0d d_access=%0d d_miss=%0d d_uncached=%0d d_write=%0d",
               ev[0], ev[1], ev[2], ev[3], ev[4], ev[5], ev[6]);
      $display("SOC_S6 sdram commands: active=%0d read=%0d write=%0d refresh=%0d max_refresh_gap=%0.1f ns",
               model.n_active, model.n_read, model.n_write, model.n_refresh, model.max_refresh_gap);
      if (reset_at < 0 && (ev[1] != n_fill[1] || ev[2] != n_read[1] || ev[4] != n_fill[0] || ev[5] != n_read[0] || ev[6] != n_write))
        $fatal(1, "Cache events differ from the observed SDRAM transactions");
      $display("SOC_S6_TEST_PASS cycles=%0d interrupts=%0d", cycles, interrupts);
      $finish;
    end
  end
endmodule
