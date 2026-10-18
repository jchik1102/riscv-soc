`timescale 1ns/1ps
// The S6 SoC bench (tb/core/soc_s6_tb.sv) with DDR3 behind the SDRAM region
// instead of the SDR SDRAM: cpu_soc with the pipeline core and both caches ->
// rtl/memory/ddr3_bridge.sv -> the MIG DDR3 controller (simulation build) ->
// Micron's DDR3 model. The transcript has the same format as the S6 bench's,
// so scripts/check_soc_ddr3.py checks it with the same cache-aware model and
// compares its retirements with the SDR run of the same program. The CPU
// starts once the MIG has calibrated; cycles count from then.
module soc_ddr3_tb #(
  parameter int ICACHE_BYTES = 2048,
  parameter int DCACHE_BYTES = 2048
);
  import soc_pkg::*;
  import platform_pkg::*;
  localparam real PERIOD = 20.0;
  logic clk = 0;
  initial begin #3.7; forever #(PERIOD / 2) clk = ~clk; end   // unrelated phase to the MIG clocks

  logic rst = 1;
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

  cpu_soc #(.PIPELINE(1), .UART_DIVISOR(16'd16), .SDRAM(1), .CACHE(1),
            .ICACHE_BYTES(ICACHE_BYTES), .DCACHE_BYTES(DCACHE_BYTES)) dut(.*);

  // ---------------------------------------------------------- DDR3 path
  logic sys_clk = 0, clk_ref = 0, sys_rst_n = 0;
  always #5.0 sys_clk = ~sys_clk;                      // 100 MHz system clock
  always #2.5 clk_ref = ~clk_ref;                      // 200 MHz IDELAY reference
  initial #200 sys_rst_n = 1;
  wire [15:0] dq; wire [1:0] dqs_p, dqs_n, dm;
  wire [13:0] addr; wire [2:0] ba; wire ras_n, cas_n, we_n, reset_n, ck_p, ck_n, cke, cs_n, odt;
  logic ui_clk, ui_rst, calib_done, bridge_rst = 1;
  logic [27:0] app_addr; logic [2:0] app_cmd; logic app_en, app_rdy;
  logic [127:0] app_wdf_data, app_rd_data; logic app_wdf_end, app_wdf_wren, app_wdf_rdy;
  logic [15:0] app_wdf_mask; logic app_rd_data_end, app_rd_data_valid;
  mig_ddr3 mig(
    .ddr3_dq(dq), .ddr3_dqs_n(dqs_n), .ddr3_dqs_p(dqs_p), .ddr3_addr(addr), .ddr3_ba(ba),
    .ddr3_ras_n(ras_n), .ddr3_cas_n(cas_n), .ddr3_we_n(we_n), .ddr3_reset_n(reset_n),
    .ddr3_ck_p(ck_p), .ddr3_ck_n(ck_n), .ddr3_cke(cke), .ddr3_cs_n(cs_n), .ddr3_dm(dm), .ddr3_odt(odt),
    .sys_clk_i(sys_clk), .clk_ref_i(clk_ref),
    .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end),
    .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren), .app_rd_data(app_rd_data), .app_rd_data_end(app_rd_data_end),
    .app_rd_data_valid(app_rd_data_valid), .app_rdy(app_rdy), .app_wdf_rdy(app_wdf_rdy),
    .app_sr_req(1'b0), .app_ref_req(1'b0), .app_zq_req(1'b0), .app_sr_active(), .app_ref_ack(), .app_zq_ack(),
    .ui_clk(ui_clk), .ui_clk_sync_rst(ui_rst), .init_calib_complete(calib_done), .device_temp(),
    .sys_rst(sys_rst_n));
  ddr3_model #(.DEBUG(0)) memory(.rst_n(reset_n), .ck(ck_p), .ck_n(ck_n), .cke(cke), .cs_n(cs_n), .ras_n(ras_n),
    .cas_n(cas_n), .we_n(we_n), .dm_tdqs(dm), .ba(ba), .addr(addr), .dq(dq), .dqs(dqs_p), .dqs_n(dqs_n), .tdqs_n(), .odt(odt));
  ddr3_bridge bridge(.clk(clk), .rst(bridge_rst), .bus_rst(rst),
    .req_valid(sdram_req_valid), .req_ready(sdram_req_ready), .req(sdram_req),
    .rsp_valid(sdram_rsp_valid), .rsp_ready(sdram_rsp_ready), .rsp(sdram_rsp), .init_done(init_done),
    .ui_clk(ui_clk), .ui_rst(ui_rst), .calib_done(calib_done),
    .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
    .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end), .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren),
    .app_wdf_rdy(app_wdf_rdy), .app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid));
  always @(posedge clk) bridge_rst <= ui_rst;           // both sides of the bridge start together

  byte unsigned image [0:RAM_BYTES-1];
  string image_path, trace_path;
  int fd, interrupts = 0, cycles = 0, cache_en = 3;
  int n_fill [2] = '{0, 0}, n_read [2] = '{0, 0}, n_write = 0, n_fence = 0, sdram_wait_cycles = 0;
  int ev [7] = '{0, 0, 0, 0, 0, 0, 0};

  initial begin
    if (!$value$plusargs("IMAGE=%s", image_path)) $fatal(1, "IMAGE required");
    if (!$value$plusargs("TRACE=%s", trace_path)) $fatal(1, "TRACE required");
    if ($value$plusargs("CACHE_EN=%d", cache_en)) begin end
    cache_enable_init = 2'(cache_en);
    foreach (image[i]) image[i] = 0;
    $readmemh(image_path, image);
    fd = $fopen(trace_path, "w");
    $fdisplay(fd, "order,pc,insn,next_pc,rd,rd_data,mem_addr,mem_rmask,mem_wmask,mem_rdata,mem_wdata,trap,cause,intr");
    repeat (2) @(negedge clk);
    for (int w = 0; w < RAM_BYTES/8; w++) begin
      loader_we = 1; loader_word = 13'(w);
      for (int lane = 0; lane < 8; lane++) loader_data[8*lane +: 8] = image[8*w + lane];
      @(negedge clk);
    end
    loader_we = 0;
    wait (init_done);
    @(negedge clk);
    $display("SOC_DDR3 calibration done at %0t ns", $realtime);
    // The MIG's write calibration leaves its training patterns at the bottom of
    // the DDR3. They are not part of what the program wrote, so the model's
    // store is emptied here: the final dump then holds only the program's
    // writes, as the SDR bench's does (that controller writes nothing itself).
    memory.memory_used = 0;
    rst = 0;
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
    if (sdram_req_valid && !sdram_req_ready) sdram_wait_cycles++;
    if (dut.pipeline.ev_i_access) ev[0]++;
    if (dut.pipeline.ev_i_miss) ev[1]++;
    if (dut.pipeline.ev_i_uncached) ev[2]++;
    if (dut.pipeline.ev_d_access) ev[3]++;
    if (dut.pipeline.ev_d_miss) ev[4]++;
    if (dut.pipeline.ev_d_uncached) ev[5]++;
    if (dut.pipeline.ev_d_write) ev[6]++;
    if (cycles > 2000000) $fatal(1, "DDR3 SoC watchdog");
  end

  assert property (@(posedge clk) disable iff (rst) sdram_req_valid && !sdram_req_ready |=> sdram_req_valid && $stable(sdram_req))
    else $fatal(1, "SDRAM-region request changed under backpressure");
  assert property (@(posedge clk) disable iff (rst) sdram_req_valid |-> sdram_req.addr >= SDRAM_BASE && sdram_req.addr - SDRAM_BASE < SDRAM_BYTES)
    else $fatal(1, "A non-SDRAM address reached the SDRAM port");
  assert property (@(posedge clk) disable iff (rst) sdram_req_valid && sdram_req.burst != 0 |->
                   sdram_req.burst == 3 && !sdram_req.write && sdram_req.mask == 8'hff && sdram_req.addr[4:0] == 0)
    else $fatal(1, "Malformed line fill on the SDRAM port");

  byte unsigned final_ram [0:RAM_BYTES-1];
  int mem_fd;
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
      // Every byte written to the DDR3, from the Micron model's store (one
      // 8-beat x 16-bit burst per entry, address {bank, row, column/8}), in the
      // SDR bench's dump format, "bank row column high value" for the byte at
      // offset row<<13 | bank<<11 | column<<1 | high, so the same checker reads it.
      mem_fd = $fopen({trace_path, ".sdram"}, "w");
      for (int e = 0; e < memory.memory_used; e++) begin
        automatic logic [23:0] a = memory.address[e];
        automatic logic [127:0] d = memory.memory[e];
        for (int b = 0; b < 16; b++) begin
          automatic longint unsigned off = ((longint'(a[23:21]) << 24) | (longint'(a[20:7]) << 10) | (longint'(a[6:0]) << 3)) * 2 + b;
          if (!$isunknown(d[8*b +: 8]) && off < SDRAM_BYTES)
            $fdisplay(mem_fd, "%0d %0d %0d %0d %02h", (off >> 11) & 3, off >> 13, (off >> 1) & 1023, off & 1, d[8*b +: 8]);
        end
      end
      $fclose(mem_fd);
      $fclose(fd);
      $display("SOC_DDR3 config icache=%0d dcache=%0d cache_en=%0d", ICACHE_BYTES, DCACHE_BYTES, cache_en);
      $display("SOC_DDR3 memory: d_fill=%0d d_read=%0d d_write=%0d i_fill=%0d i_read=%0d fence_i=%0d wait_cycles=%0d",
               n_fill[0], n_read[0], n_write, n_fill[1], n_read[1], n_fence, sdram_wait_cycles);
      if (ev[1] != n_fill[1] || ev[2] != n_read[1] || ev[4] != n_fill[0] || ev[5] != n_read[0] || ev[6] != n_write)
        $fatal(1, "Cache events differ from the observed memory transactions");
      $display("SOC_DDR3_TEST_PASS cycles=%0d interrupts=%0d", cycles, interrupts);
      $finish;
    end
  end
  initial begin #(80.0e6); $fatal(1, "DDR3 SoC time watchdog"); end
endmodule
