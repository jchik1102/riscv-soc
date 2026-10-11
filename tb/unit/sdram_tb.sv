`timescale 1ns/1ps
module sdram_tb #(
  parameter int CLK_PS = 20000,
  parameter int READ_LATENCY = 3,
  parameter int TRANSACTIONS = 6000
);
  import soc_pkg::*;
  localparam real PERIOD = CLK_PS / 1000.0;
  localparam real LEAD_NS = 1.0;
  localparam logic [63:0] BASE = platform_pkg::SDRAM_BASE;
  localparam logic [63:0] BYTES = platform_pkg::SDRAM_BYTES;
  localparam int MAX_ACCEPT = 40, MAX_RESPONSE = 40;

  logic clk = 0, sdram_clk = 0, sdram_clk_run = 0;
  always #(PERIOD / 2) clk = ~clk;
  always @(clk) sdram_clk <= #(PERIOD - LEAD_NS) clk & sdram_clk_run;

  logic rst = 1, bus_rst = 0;
  logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0, init_done;
  bus2_req_t req = '0;
  bus2_rsp_t rsp;
  logic cke, cs_n, ras_n, cas_n, we_n, dq_oe;
  logic [1:0] ba, dqm;
  logic [12:0] a;
  logic [15:0] dq_o;
  wire [15:0] dq;
  assign dq = dq_oe ? dq_o : 16'bz;

  sdram_ctrl #(.CLK_PERIOD_PS(CLK_PS), .READ_LATENCY(READ_LATENCY)) dut(.clk(clk), .rst(rst), .bus_rst(bus_rst),
    .req_valid(req_valid), .req_ready(req_ready), .req(req), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp),
    .init_done(init_done), .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n),
    .sdram_we_n(we_n), .sdram_ba(ba), .sdram_a(a), .sdram_dqm(dqm), .sdram_dq_o(dq_o), .sdram_dq_oe(dq_oe),
    .sdram_dq_i(dq), .extra_wait(2'b00), .extra_capture(1'b0));
  sdram_model model(.clk(sdram_clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .a(a), .dqm(dqm), .dq(dq));

  logic [7:0] shadow [longint unsigned];
  int errors = 0, checks = 0, known_lanes = 0, unknown_lanes = 0;
  int hits [string];
  string required [$] = '{"read_full", "write_full", "read_partial", "write_partial", "write_zero_mask",
    "write_lane0", "write_lane1", "write_lane2", "write_lane3", "write_lane4", "write_lane5", "write_lane6", "write_lane7",
    "error_misaligned", "error_below", "error_above", "first_beat", "last_beat", "bank_boundary", "row_boundary",
    "refresh_preempts_request", "accept_during_refresh", "backpressure", "busrst_waiting", "busrst_column",
    "busrst_write_data", "busrst_read_data", "busrst_response_pending", "busrst_idle", "controller_reset",
    "read_after_write_hit", "burst_2", "burst_4", "burst_error_write", "burst_error_len3", "burst_error_misaligned",
    "burst_error_mask", "busrst_burst", "burst_row_boundary"};
  function automatic void hit(input string name);
    if (hits.exists(name)) hits[name]++; else hits[name] = 1;
  endfunction
  task automatic check(input bit condition, input string message);
    checks++;
    if (!condition) begin errors++; $error("SDRAM_TB %0t: %s", $realtime, message); end
    if (errors > 20) $fatal(1, "SDRAM_TB: too many errors");
  endtask

  typedef struct packed {logic write; logic [63:0] addr; logic [7:0] mask; logic [63:0] wdata; logic [1:0] burst;} op_t;
  op_t queue [$];
  longint unsigned recent [$];
  int seed = 1, issued = 0, cycle = 0, max_accept = 0, max_response = 0;
  bit random_phase = 0, stop = 0;

  logic [31:0] rng = 32'h1;
  function automatic int unsigned rnd();
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    return rng;
  endfunction
  function automatic int unsigned urange(input int unsigned lo, input int unsigned hi = 0);
    if (hi < lo) begin int unsigned t = lo; lo = hi; hi = t; end
    return lo + rnd() % (hi - lo + 1);
  endfunction
  function automatic logic [7:0] random_mask();
    case (urange(9))
      0, 1, 2, 3: return 8'hff;
      4: return 8'(1 << urange(7));
      5: return 8'(3 << (2 * urange(3)));
      6: return urange(1) ? 8'h0f : 8'hf0;
      7: return urange(30) == 0 ? 8'h00 : 8'(urange(255));
      default: return 8'(urange(255));
    endcase
  endfunction
  function automatic longint unsigned random_offset();
    case (urange(9))
      0, 1, 2: return recent.size() ? recent[urange(recent.size() - 1)] : 0;
      3: return (longint'(urange(32767)) * 2048 + (urange(1) ? 0 : 2040)) % BYTES;
      4: return (longint'(urange(8191)) * 8192 + (urange(1) ? 0 : 8184)) % BYTES;
      5: return urange(1) ? 0 : BYTES - 8;
      6: return longint'(urange(511)) * 8;
      default: return (longint'(rnd()) * 8) % BYTES;
    endcase
  endfunction
  function automatic op_t random_op();
    op_t op;
    longint unsigned offset = random_offset();
    op.write = urange(99) < 50;
    if (!op.write && recent.size() && urange(9) < 6) offset = recent[urange(recent.size() - 1)];
    op.mask = random_mask();
    op.wdata = {rnd(), rnd()};
    op.addr = BASE + offset;
    op.burst = 0;
    if (!op.write && urange(99) < 25) begin
      op.burst = urange(1) ? 2'd3 : 2'd1;
      op.mask = 8'hff;
      if (urange(7) == 0) offset = (longint'(urange(8191)) * 8192 + 8160) % BYTES;
      op.addr = BASE + (offset & ~(longint'(op.burst) * 8));
      case (urange(39))
        0: op.write = 1;
        1: op.burst = 2'd2;
        2: op.addr = op.addr + 8 * 64'(urange(1, 3) & op.burst);
        3: op.mask = 8'h7f;
        default: ;
      endcase
    end
    case (urange(199))
      0: op.addr = BASE + offset + 64'(urange(1, 7));
      1: op.addr = BASE - 8 * 64'(urange(1, 4));
      2: op.addr = BASE + BYTES + 8 * 64'(urange(0, 3));
      default: ;
    endcase
    return op;
  endfunction
  initial begin
    static longint unsigned spots [] = '{0, 8, 2040, 2048, 8184, 8192, 16376, 16384, 32760, 32768,
                                   BYTES/2 - 8, BYTES/2, BYTES - 16, BYTES - 8};
    for (int lane = 0; lane < 8; lane++) queue.push_back('{1, BASE + 64'h100, 8'(1 << lane), {8{8'(8'h10 + lane)}}, 2'd0});
    queue.push_back('{0, BASE + 64'h100, 8'hff, 64'b0, 2'd0});
    for (int i = 0; i < 4; i++) queue.push_back('{1, BASE + 64'h108, 8'(3 << (2 * i)), 64'h1122334455667788 + i, 2'd0});
    queue.push_back('{0, BASE + 64'h108, 8'hff, 64'b0, 2'd0});
    queue.push_back('{1, BASE + 64'h110, 8'h0f, 64'hdeadbeef_cafef00d, 2'd0});
    queue.push_back('{1, BASE + 64'h110, 8'hf0, 64'h01234567_89abcdef, 2'd0});
    queue.push_back('{0, BASE + 64'h110, 8'h0f, 64'b0, 2'd0});
    queue.push_back('{0, BASE + 64'h110, 8'hf0, 64'b0, 2'd0});
    foreach (spots[i]) queue.push_back('{1, BASE + spots[i], 8'hff, {32'(i), 32'(spots[i])} ^ 64'ha5a5_0000_5a5a_ffff, 2'd0});
    foreach (spots[i]) queue.push_back('{0, BASE + spots[i], 8'hff, 64'b0, 2'd0});
    for (int r = 0; r < 4; r++) queue.push_back('{1, BASE + 64'(r) * 8192 + 64'h40, 8'hff, 64'(r) * 64'h0101010101010101, 2'd0});
    for (int k = 0; k < 4; k++) queue.push_back('{1, BASE + 64'(k) * 2048 + 64'h48, 8'hff, ~(64'(k) * 64'h0101010101010101), 2'd0});
    for (int r = 0; r < 4; r++) queue.push_back('{0, BASE + 64'(r) * 8192 + 64'h40, 8'hff, 64'b0, 2'd0});
    for (int k = 0; k < 4; k++) queue.push_back('{0, BASE + 64'(k) * 2048 + 64'h48, 8'hff, 64'b0, 2'd0});
    queue.push_back('{1, BASE + 64'h100, 8'h00, 64'hffff_ffff_ffff_ffff, 2'd0});
    queue.push_back('{0, BASE + 64'h100, 8'hff, 64'b0, 2'd0});
    queue.push_back('{0, BASE + 64'h101, 8'hff, 64'b0, 2'd0});
    queue.push_back('{0, BASE - 8, 8'hff, 64'b0, 2'd0});
    queue.push_back('{1, BASE + BYTES, 8'hff, 64'b0, 2'd0});
  end

  typedef enum {D_IDLE, D_REQ, D_RSP} drive_t;
  drive_t dstate = D_IDLE;
  int gap = 0, wait_cycles = 0, present_cycle = 0, accept_cycle = 0, refresh_cycle = -100;
  bit expect_error, response_seen;
  logic [7:0] expect_mask;
  logic [63:0] expect_data, known;
  logic [1:0] expect_len, beat_seen;

  function automatic void on_accept();
    longint unsigned offset = req.addr - BASE;
    bit in_region = req.addr >= BASE && offset < BYTES;
    bit bad_burst = req.burst != 0 && (req.write || req.burst == 2 || req.mask != 8'hff || (req.addr[4:3] & req.burst) != 0);
    if (cycle - present_cycle > max_accept) max_accept = cycle - present_cycle;
    expect_error = !in_region || req.addr[2:0] != 0 || bad_burst;
    expect_mask = req.mask;
    expect_len = expect_error ? 2'd0 : req.burst;
    beat_seen = 0;
    expect_data = 0; known = 0;
    if (bad_burst && in_region && req.addr[2:0] == 0) begin
      if (req.write) hit("burst_error_write");
      else if (req.burst == 2) hit("burst_error_len3");
      else if (req.mask != 8'hff) hit("burst_error_mask");
      else hit("burst_error_misaligned");
    end else if (expect_error) begin
      if (req.addr[2:0] != 0 && in_region) hit("error_misaligned");
      else if (req.addr < BASE) hit("error_below");
      else hit("error_above");
    end else begin
      if (offset == 0) hit("first_beat");
      if (offset == BYTES - 8) hit("last_beat");
      if (offset % 2048 == 0 || offset % 2048 == 2040) hit("bank_boundary");
      if (offset % 8192 == 0 || offset % 8192 == 8184) hit("row_boundary");
      if (req.write) begin
        if (req.mask == 8'hff) hit("write_full");
        else if (req.mask == 0) hit("write_zero_mask");
        else hit("write_partial");
        for (int lane = 0; lane < 8; lane++) if (req.mask[lane]) begin
          shadow[offset + lane] = req.wdata[lane*8 +: 8];
          hit($sformatf("write_lane%0d", lane));
        end
        if (req.mask != 0) begin
          recent.push_back(offset);
          if (recent.size() > 64) void'(recent.pop_front());
        end
      end else begin
        if (req.burst == 3) hit("burst_4");
        else if (req.burst == 1) hit("burst_2");
        else if (req.mask == 8'hff) hit("read_full");
        else hit("read_partial");
        if (req.burst == 3 && offset % 8192 == 8160) hit("burst_row_boundary");
        expect_beat(0);
      end
    end
  endfunction
  function automatic void expect_beat(input int k);
    longint unsigned offset = req.addr - BASE + 8 * k;
    expect_data = 0; known = 0;
    for (int lane = 0; lane < 8; lane++) if (req.mask[lane] && shadow.exists(offset + lane)) begin
      expect_data[lane*8 +: 8] = shadow[offset + lane];
      known[lane*8 +: 8] = 8'hff;
    end
    if (known != 0) hit("read_after_write_hit");
  endfunction
  function automatic bus2_req_t next_request();
    op_t op;
    if (queue.size() != 0) op = queue.pop_front();
    else op = random_op();
    return '{addr: op.addr, write: op.write, mask: op.mask, wdata: op.wdata, burst: op.burst};
  endfunction
  task automatic on_response();
    check(rsp.error == expect_error, $sformatf("error flag %0b for %h", rsp.error, req.addr));
    check(rsp.last == (beat_seen == expect_len), $sformatf("last flag %0b on beat %0d of %0d", rsp.last, beat_seen, expect_len + 1));
    if (expect_error || req.write) check(rsp.rdata == 0, "nonzero data on an error or write response");
    if (!expect_error && req.write) begin
      longint unsigned offset = req.addr - BASE;
      for (int lane = 0; lane < 8; lane++) if (expect_mask[lane])
        check(model.written(offset[12:11], offset[25:13], 10'(offset[10:1] + lane / 2), lane % 2) &&
              model.peek(offset[12:11], offset[25:13], 10'(offset[10:1] + lane / 2), lane % 2) === req.wdata[lane*8 +: 8],
              $sformatf("write %h lane %0d not at its documented bank/row/column", req.addr, lane));
    end
    else for (int lane = 0; lane < 8; lane++) begin
      if (!expect_mask[lane]) check(rsp.rdata[lane*8 +: 8] === 8'h00, $sformatf("unselected lane %0d not zero", lane));
      else if (known[lane*8]) begin
        known_lanes++;
        check(rsp.rdata[lane*8 +: 8] === expect_data[lane*8 +: 8],
              $sformatf("read %h lane %0d: %h expected %h", req.addr, lane, rsp.rdata[lane*8 +: 8], expect_data[lane*8 +: 8]));
      end else begin
        unknown_lanes++;
        check(!$isunknown(rsp.rdata[lane*8 +: 8]), "unknown read data (capture outside the valid window)");
      end
    end
  endtask

  always @(posedge clk) begin
    cycle++;
    rsp_ready <= (dstate == D_RSP || dstate == D_REQ) && req.burst != 0 ? 1'b1 : urange(3) != 0;
    if (rsp_valid && !rsp_ready) hit("backpressure");
    if (rst || bus_rst) begin
      req_valid <= 0;
      dstate <= D_IDLE;
      gap <= urange(3);
    end else case (dstate)
      D_IDLE: begin
        if (rsp_valid) check(0, "response with no outstanding request");
        if (gap != 0) gap <= gap - 1;
        else if (!stop) begin
          req <= next_request();
          req_valid <= 1;
          present_cycle <= cycle;
          dstate <= D_REQ;
        end
      end
      D_REQ: begin
        if (rsp_valid) check(0, "response before acceptance");
        if (!init_done) present_cycle <= cycle;
        else check(cycle - present_cycle <= MAX_ACCEPT, "request not accepted in time");
        if (req_valid && req_ready) begin
          on_accept();
          if (cycle - refresh_cycle <= 2) hit("accept_during_refresh");
          issued++;
          accept_cycle <= cycle;
          response_seen <= 0;
          req_valid <= 0;
          dstate <= D_RSP;
        end
      end
      D_RSP: begin
        if (!response_seen) check(cycle - accept_cycle <= MAX_RESPONSE, "response not produced in time");
        if (rsp_valid && !response_seen) begin
          response_seen <= 1;
          if (cycle - accept_cycle > max_response) max_response = cycle - accept_cycle;
        end
        if (rsp_valid && rsp_ready) begin
          on_response();
          if (rsp.last || rsp.error) begin
            gap <= urange(5) == 0 ? urange(20) : 0;
            dstate <= D_IDLE;
          end else begin
            beat_seen <= beat_seen + 2'd1;
            expect_beat(int'(beat_seen) + 1);
            accept_cycle <= cycle;
            response_seen <= 0;
          end
        end
      end
    endcase
  end

  always @(dq_oe, model.drive_enable) if (dq_oe && model.drive_enable != 0) check(0, "DQ bus contention");
  always @(posedge clk) if (!rst && init_done) begin
    if ({cs_n, ras_n, cas_n, we_n} == 4'b0001) refresh_cycle <= cycle;
    if (int'(dut.state) == 3 && dut.wait_count == 0 && dut.refresh_due && dut.pending) hit("refresh_preempts_request");
  end

  task automatic pulse_bus_reset();
    if (rsp_valid && !rsp_ready) hit("busrst_response_pending");
    else if (!dut.pending && dstate != D_RSP) hit("busrst_idle");
    else case (int'(dut.state))
      3: if (dut.pending) hit("busrst_waiting");
      4: hit("busrst_column");
      5: hit("busrst_write_data");
      6: begin hit("busrst_read_data"); if (dut.op_len != 0) hit("busrst_burst"); end
      default: ;
    endcase
    bus_rst <= 1;
    repeat (urange(1, 4)) @(posedge clk);
    bus_rst <= 0;
  endtask

  initial begin
    if ($value$plusargs("SEED=%d", seed)) begin end
    rng = seed == 0 ? 32'h1 : 32'(seed) * 32'h9e3779b1 + 32'h7f4a7c15;
    repeat (3) @(posedge clk);
    sdram_clk_run = 1;
    repeat (3) @(posedge clk);
    rst <= 0;
    begin
      automatic realtime t0 = $realtime;
      wait (init_done);
      check($realtime - t0 >= 200000.0 - PERIOD, "initialization shorter than the 200 us power-up wait");
    end
    fork
      forever begin
        @(posedge clk);
        if (!rst && !stop && urange(399) == 0) pulse_bus_reset();
        if (!rst && !stop && dstate == D_RSP && urange(99) == 0) pulse_bus_reset();
      end
    join_none
    wait (issued >= TRANSACTIONS / 2);
    @(posedge clk);
    rst <= 1; bus_rst <= 1;
    repeat (4) @(posedge clk);
    model.power_cycle();
    shadow.delete(); recent.delete();
    hit("controller_reset");
    rst <= 0; bus_rst <= 0;
    wait (init_done);
    wait (issued >= TRANSACTIONS);
    stop = 1;
    wait (dstate == D_IDLE);
    repeat (200) @(posedge clk);
    foreach (required[i]) if (!hits.exists(required[i])) begin
      errors++; $error("SDRAM_TB: coverage bin %s not hit", required[i]);
    end
    if (model.n_refresh < 10 || model.n_bank_change == 0 || model.n_row_change == 0 || model.n_row_same == 0) begin
      errors++; $error("SDRAM_TB: model command coverage too small");
    end
    $display("SDRAM_TB clk=%0d ps seed=%0d transactions=%0d checks=%0d known_lanes=%0d unknown_lanes=%0d",
             CLK_PS, seed, issued, checks, known_lanes, unknown_lanes);
    $display("SDRAM_TB latency: accept<=%0d response<=%0d cycles; refresh gap max %0.1f ns",
             max_accept, max_response, model.max_refresh_gap);
    $display("SDRAM_TB model commands: active=%0d read=%0d write=%0d refresh=%0d mode=%0d auto_precharge=%0d bank_change=%0d row_change=%0d row_same=%0d",
             model.n_active, model.n_read, model.n_write, model.n_refresh, model.n_mode, model.n_auto_precharge,
             model.n_bank_change, model.n_row_change, model.n_row_same);
    foreach (hits[name]) $display("SDRAM_TB cover %s %0d", name, hits[name]);
    if (errors || model.errors) $fatal(1, "SDRAM_TB FAIL: %0d bench errors, %0d model errors", errors, model.errors);
    $display("SDRAM_TEST_PASS");
    $finish;
  end
  initial begin
    #(PERIOD * 4000000);
    $fatal(1, "SDRAM_TB watchdog");
  end
endmodule
