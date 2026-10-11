`timescale 1ns/1ps
module cache_tb #(
  parameter int BYTES = 2048,
  parameter int TRANSACTIONS = 20000
);
  import soc_pkg::*;
  localparam logic [63:0] BASE = platform_pkg::SDRAM_BASE;
  localparam logic [63:0] SPAN = platform_pkg::SDRAM_BYTES;
  localparam int LINES = BYTES / 32;
  localparam int MAX_WAIT = 200;

  logic clk = 0;
  always #10 clk = ~clk;
  logic rst = 1, enable = 1, invalidate = 0;
  logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0;
  bus_req_t req = '0;
  bus_rsp_t rsp;
  logic mreq_valid, mreq_ready, mrsp_valid = 0, mrsp_ready;
  bus2_req_t mreq;
  bus2_rsp_t mrsp = '0;
  logic ev_access, ev_miss, ev_bypass, ev_write;

  cache #(.BYTES(BYTES), .WRITES(1)) dut(.clk(clk), .rst(rst), .enable(enable), .invalidate(invalidate),
    .req_valid(req_valid), .req_ready(req_ready), .req(req), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp),
    .mreq_valid(mreq_valid), .mreq_ready(mreq_ready), .mreq(mreq), .mrsp_valid(mrsp_valid), .mrsp_ready(mrsp_ready),
    .mrsp(mrsp), .ev_access(ev_access), .ev_miss(ev_miss), .ev_bypass(ev_bypass), .ev_write(ev_write));

  int errors = 0, checks = 0, cycle = 0;
  int hits [string];
  string required [$] = '{"read_hit", "read_miss", "conflict_eviction", "write_hit", "write_miss", "write_error_on_valid_line", "outside_alias_of_valid_line",
    "fill_error", "read_error_bypass", "bypass_disabled", "bypass_outside", "enable_drop_during_fill", "invalidate_during_fill",
    "reset_during_fill", "reset_during_pass", "hit_after_write_hit", "subword_read_hit", "subword_write_hit",
    "cpu_backpressure", "memory_accept_delay", "beat_gap", "every_beat_requested", "far_tag"};
  function automatic void hit(input string name);
    if (hits.exists(name)) hits[name]++; else hits[name] = 1;
  endfunction
  task automatic check(input bit condition, input string message);
    checks++;
    if (!condition) begin errors++; $error("CACHE_TB %0t: %s", $realtime, message); end
    if (errors > 20) $fatal(1, "CACHE_TB: too many errors");
  endtask
  logic [31:0] rng = 32'h1;
  function automatic int unsigned rnd();
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    return rng;
  endfunction
  function automatic int unsigned urange(input int unsigned lo, input int unsigned hi);
    return lo + rnd() % (hi - lo + 1);
  endfunction

  logic [7:0] written [longint unsigned];
  function automatic logic [7:0] mem_byte(input longint unsigned address);
    if (written.exists(address)) return written[address];
    return 8'(address * 13 + 8'h3c ^ (address >> 9));
  endfunction
  function automatic logic [63:0] mem_beat(input longint unsigned address, input logic [7:0] mask);
    logic [63:0] value = 0;
    for (int lane = 0; lane < 8; lane++) if (mask[lane]) value[lane*8 +: 8] = mem_byte(address + lane);
    return value;
  endfunction
  localparam logic [63:0] BAD0 = BASE + 64'h0000_0400, BAD1 = BASE + 64'h0200_1ce0;
  function automatic bit bad_line(input logic [63:0] address);
    return {address[63:5], 5'b0} == BAD0 || {address[63:5], 5'b0} == BAD1;
  endfunction

  bit s_busy = 0, s_ready_rand = 0;
  bus2_req_t s_req;
  int s_beat = 0, s_delay = 0, s_error_beat = -1;
  bit s_write_error = 0;
  typedef struct {bus2_req_t r; bit error; realtime at;} txn_t;
  txn_t log_q [$];
  bit fill_error_seen;
  assign mreq_ready = !rst && !s_busy && s_ready_rand;

  always @(posedge clk) begin
    s_ready_rand <= urange(0, 3) != 0;
    if (mreq_valid && !mreq_ready && !rst) hit("memory_accept_delay");
    if (rst) begin
      s_busy <= 0; mrsp_valid <= 0;
    end else begin
      if (mrsp_valid && s_req.burst != 0) check(mrsp_ready, "burst master not ready for a presented beat");
      if (mrsp_valid && mrsp_ready) begin
        mrsp_valid <= 0;
        if (mrsp.last) s_busy <= 0;
        else begin
          s_beat <= s_beat + 1;
          s_delay <= 0;
          if (urange(0, 2) == 0) s_delay <= urange(1, 3);
        end
      end else if (s_busy && !mrsp_valid) begin
        if (s_delay != 0) begin s_delay <= s_delay - 1; hit("beat_gap"); end
        else begin
          automatic bit err = s_req.write ? s_write_error : (s_req.burst == 0 ? bad_line(s_req.addr) : s_beat == s_error_beat);
          mrsp_valid <= 1;
          mrsp.error <= err;
          mrsp.last <= err || s_beat == int'(s_req.burst);
          mrsp.rdata <= err || s_req.write ? 64'b0 : mem_beat(s_req.addr + 8 * s_beat, s_req.mask);
        end
      end
      if (mreq_valid && mreq_ready) begin
        automatic txn_t t;
        if (mreq.burst != 0)
          check(mreq.burst == 3 && !mreq.write && mreq.mask == 8'hff && mreq.addr[4:0] == 0, "malformed line fill");
        check(mreq.addr[2:0] == 0, "misaligned memory request");
        s_busy <= 1; s_req <= mreq; s_beat <= 0; s_delay <= urange(0, 4);
        s_error_beat <= mreq.burst != 0 && bad_line(mreq.addr) ? int'(mreq.addr[7:6]) : -1;
        s_write_error <= mreq.write && urange(0, 24) == 0;
        t.r = mreq; t.at = $realtime;
        t.error = mreq.write ? 0 : (mreq.burst == 0 ? bad_line(mreq.addr) : bad_line(mreq.addr));
        log_q.push_back(t);
      end
    end
  end
  bit apply_pending = 0;
  bus2_req_t apply_req;
  always @(posedge clk) begin
    if (apply_pending && !s_write_error)
      for (int lane = 0; lane < 8; lane++) if (apply_req.mask[lane]) written[apply_req.addr + lane] = apply_req.wdata[lane*8 +: 8];
    apply_pending <= !rst && mreq_valid && mreq_ready && mreq.write;
    apply_req <= mreq;
  end

  bit m_valid [0:LINES-1];
  logic [63:0] m_tag [0:LINES-1];
  int m_access = 0, m_miss = 0, m_bypass = 0, m_write = 0;
  int d_access = 0, d_miss = 0, d_bypass = 0, d_write = 0;
  function automatic int line_index(input logic [63:0] address);
    return int'((address - BASE) >> 5) % LINES;
  endfunction
  function automatic logic [63:0] line_tag(input logic [63:0] address);
    return (address - BASE) / BYTES;
  endfunction
  function automatic bit in_region(input logic [63:0] address);
    return address >= BASE && address - BASE < SPAN;
  endfunction

  typedef enum {C_IDLE, C_REQ, C_RSP} cstate_t;
  cstate_t cstate = C_IDLE;
  typedef enum {K_HIT, K_MISS, K_PASS} kind_t;
  kind_t kind;
  int issued = 0, gap = 0, wait_count = 0, max_hit = 0, max_miss = 0, accept_cycle = 0;
  realtime accept_time;
  bit fill_seen, pass_seen, fill_killed, kill_now, op_write_hit;
  logic [63:0] expect_data, last_write_hit_addr = '1;
  logic [63:0] recent [$];
  bit held_bypass = 0;

  function automatic bus_req_t random_request();
    bus_req_t r;
    logic [63:0] offset;
    int size = 1 << urange(0, 3);
    int pick = urange(0, 9);
    offset = 0;
    if (pick <= 2) offset = 64'(urange(0, 16383));
    else if (pick <= 4) offset = 64'(urange(0, 1023));
    else if (pick == 5) offset = 64'h0200_0000 + 64'(urange(0, 4095));
    else if (pick == 6) offset = 64'h0300_0000 + 64'(urange(0, 4095));
    else if (pick == 7) begin
      if (recent.size() != 0) offset = recent[urange(0, recent.size() - 1)] - BASE;
    end else if (pick == 8) offset = (BAD0 - BASE) + 64'(urange(0, 31));
    else begin
      offset = 64'(urange(0, 63));
      if (urange(0, 1) != 0) offset = offset + 64'h0000_0400; else offset = offset + 64'h0200_1cc0;
    end
    r.addr = {BASE[63:3] + offset[63:3], 3'b0};
    if (urange(0, 29) == 0) begin
      r.addr = 8 * 64'(urange(0, 127));
      if (urange(0, 3) == 0) r.addr = r.addr + BASE - 64'h1000; else r.addr = r.addr + BASE + SPAN;
    end
    r.write = urange(0, 99) < 40;
    pick = urange(0, 4);
    case (pick)
      0: r.mask = 8'hff;
      1: r.mask = 8'(((1 << size) - 1) << (8'(urange(0, 7)) & ~8'(size - 1)));
      2: r.mask = 8'(urange(0, 255));
      default: begin
        r.mask = 8'(((1 << size) - 1) << (8'(urange(0, 7)) & ~8'(size - 1)));
        if (size == 8) r.mask = 8'hff;
      end
    endcase
    r.wdata = {rnd(), rnd()};
    return r;
  endfunction

  always @(posedge clk) begin
    cycle++;
    rsp_ready <= urange(0, 3) != 0;
    if (rsp_valid && !rsp_ready) hit("cpu_backpressure");
    if (ev_access) d_access++;
    if (ev_miss) d_miss++;
    if (ev_bypass) d_bypass++;
    if (ev_write) d_write++;
    if (ev_miss) check(mreq_valid && mreq_ready && mreq.burst == 3, "miss event without an accepted line fill");
    if (mreq_valid && mreq_ready && mreq.burst == 3) check(ev_miss, "line fill without a miss event");
    kill_now = invalidate || !enable;
    if (rst) begin
      req_valid <= 0;
      held_bypass = 0;
      cstate <= C_IDLE;
      gap <= urange(0, 3);
      for (int i = 0; i < LINES; i++) m_valid[i] = 0;
      log_q.delete();
    end else begin
      case (cstate)
        C_IDLE: begin
          check(!rsp_valid, "response with no outstanding request");
          if (gap != 0) gap <= gap - 1;
          else if (issued < TRANSACTIONS) begin
            req <= random_request();
            req_valid <= 1;
            wait_count <= 0;
            cstate <= C_REQ;
          end
        end
        C_REQ: begin
          check(!rsp_valid, "response before acceptance");
          wait_count <= wait_count + 1;
          check(wait_count < MAX_WAIT, "request not accepted in time");
          if (req_valid && req_ready) begin
            automatic int idx = line_index(req.addr);
            automatic bit cacheable = in_region(req.addr);
            automatic bit model_hit = cacheable && m_valid[idx] && m_tag[idx] == line_tag(req.addr);
            issued++;
            accept_cycle <= cycle;
            accept_time = $realtime;
            fill_seen = 0; pass_seen = 0; fill_killed <= 0;
            expect_data = mem_beat(req.addr, req.mask);
            if (held_bypass || req.write || !enable || !cacheable) begin
              kind = K_PASS;
              if (req.write) m_write++; else m_bypass++;
              if (req.write && enable && cacheable) m_access++;
              op_write_hit = req.write && enable && model_hit;
              if (req.write && model_hit && enable) hit("write_hit");
              else if (req.write) hit("write_miss");
              if (req.write && model_hit && enable && req.mask != 8'hff) hit("subword_write_hit");
              if (!cacheable && m_valid[idx] && m_tag[idx] == line_tag(BASE + (req.addr - BASE) % SPAN)) hit("outside_alias_of_valid_line");
              if (!req.write && cacheable) hit("bypass_disabled");
              else if (!req.write) hit("bypass_outside");
              if (!req.write && bad_line(req.addr)) hit("read_error_bypass");
            end else if (model_hit) begin
              kind = K_HIT; m_access++;
              hit("read_hit");
              if (req.mask != 8'hff) hit("subword_read_hit");
              if ({req.addr[63:5], 5'b0} == {last_write_hit_addr[63:5], 5'b0}) hit("hit_after_write_hit");
              if (req.addr - BASE >= 64'h0200_0000) hit("far_tag");
            end else begin
              kind = K_MISS; m_access++;
              hit("read_miss");
              hit($sformatf("beat%0d", req.addr[4:3]));
              if (m_valid[idx]) hit("conflict_eviction");
              m_valid[idx] = 0;
            end
            if (cacheable && urange(0, 1) != 0) begin
              recent.push_back(req.addr);
              if (recent.size() > 24) void'(recent.pop_front());
            end
            held_bypass = 0;
            req_valid <= 0;
            cstate <= C_RSP;
          end else if (req_valid) held_bypass = held_bypass || req.write || !enable || !in_region(req.addr);
        end
        C_RSP: begin
          wait_count <= wait_count + 1;
          check(wait_count < MAX_WAIT, "response not produced in time");
          while (log_q.size() != 0) begin
            automatic txn_t t = log_q.pop_front();
            if (kind == K_PASS) begin
              check(!pass_seen && t.r.burst == 0 && t.r.addr == req.addr && t.r.write == req.write && t.r.mask == req.mask &&
                    (!req.write || t.r.wdata == req.wdata), "pass-through not forwarded unchanged");
              check(t.at == accept_time, "pass-through not accepted in the CPU acceptance cycle");
              pass_seen = 1;
            end else if (kind == K_MISS) begin
              check(!fill_seen && t.r.burst == 3 && t.r.addr == {req.addr[63:5], 5'b0}, "miss without its line fill");
              fill_seen = 1;
              m_miss++;
            end else check(0, "memory transaction on a hit");
          end
          if (kind == K_MISS && cycle > accept_cycle && kill_now) fill_killed <= 1;
          if (rsp_valid && rsp_ready) begin
            automatic int idx = line_index(req.addr);
            automatic bit want_error = 0;
            if (kind == K_PASS) want_error = req.write ? s_write_error : bad_line(req.addr);
            if (kind == K_MISS) want_error = bad_line(req.addr);
            check(kind != K_PASS || pass_seen, "pass-through response without its transaction");
            check(kind != K_MISS || fill_seen, "miss response without a line fill");
            check(rsp.error == want_error, $sformatf("error flag %0b, expected %0b (%h)", rsp.error, want_error, req.addr));
            if (rsp.error || req.write) check(rsp.rdata == 0, "data on an error or write response");
            else check(rsp.rdata === expect_data, $sformatf("read %h mask %h: %h expected %h", req.addr, req.mask, rsp.rdata, expect_data));
            if (kind == K_MISS && rsp.error) hit("fill_error");
            if (op_write_hit && !rsp.error && !(fill_killed || kill_now)) last_write_hit_addr <= req.addr;
            if (op_write_hit && rsp.error) hit("write_error_on_valid_line");
            if (kind == K_HIT) begin
              if (cycle - accept_cycle > max_hit) max_hit = cycle - accept_cycle;
            end else if (kind == K_MISS && cycle - accept_cycle > max_miss) max_miss = cycle - accept_cycle;
            gap <= 0;
            if (urange(0, 4) == 0) gap <= urange(1, 6);
            cstate <= C_IDLE;
          end
        end
      endcase
      if (mrsp_valid && mrsp_ready && mrsp.last && s_req.burst == 3 && cstate == C_RSP && kind == K_MISS) begin
        automatic int idx = line_index(req.addr);
        if (!mrsp.error && !fill_killed && !kill_now && s_beat == 3) begin
          m_valid[idx] = 1;
          m_tag[idx] = line_tag(req.addr);
          hit("every_beat_requested");
        end
        if ((fill_killed || kill_now) && !invalidate) hit("enable_drop_during_fill");
        if (fill_killed || invalidate) hit("invalidate_during_fill");
      end
      if (invalidate || !enable) for (int i = 0; i < LINES; i++) m_valid[i] = 0;
    end
  end

  initial begin
    if ($value$plusargs("SEED=%d", rng)) rng = rng * 32'h9e3779b1 + 32'h7f4a7c15;
    if (rng == 0) rng = 1;
    repeat (3) @(posedge clk);
    rst <= 0;
    fork
      forever begin
        @(posedge clk);
        invalidate <= urange(0, 2999) == 0;
        if (urange(0, 4999) == 0) enable <= 0;
        else if (!enable && urange(0, 39) == 0) enable <= 1;
        if (!rst && urange(0, 1999) == 0) begin
          if (cstate == C_RSP && kind == K_MISS) hit("reset_during_fill");
          if (cstate == C_RSP && kind == K_PASS) hit("reset_during_pass");
          rst <= 1;
          repeat (urange(1, 3)) @(posedge clk);
          rst <= 0;
        end
      end
    join_none
    wait (issued >= TRANSACTIONS && cstate == C_IDLE);
    repeat (20) @(posedge clk);
    foreach (required[i]) if (!hits.exists(required[i])) begin errors++; $error("CACHE_TB: coverage bin %s not hit", required[i]); end
    for (int b = 0; b < 4; b++) if (!hits.exists($sformatf("beat%0d", b))) begin errors++; $error("CACHE_TB: miss on beat %0d not hit", b); end
    $display("CACHE_TB bytes=%0d transactions=%0d checks=%0d hit_latency<=%0d miss_latency<=%0d", BYTES, issued, checks, max_hit, max_miss);
    $display("CACHE_TB events dut access=%0d miss=%0d bypass=%0d write=%0d model access=%0d miss=%0d bypass=%0d write=%0d",
             d_access, d_miss, d_bypass, d_write, m_access, m_miss, m_bypass, m_write);
    if (d_access != m_access || d_miss != m_miss || d_bypass != m_bypass || d_write != m_write) begin
      errors++; $error("CACHE_TB: event counts differ from the model");
    end
    foreach (hits[name]) $display("CACHE_TB cover %s %0d", name, hits[name]);
    if (errors) $fatal(1, "CACHE_TB FAIL: %0d errors", errors);
    $display("CACHE_TEST_PASS");
    $finish;
  end
  initial begin
    #(20.0 * TRANSACTIONS * 200);
    $fatal(1, "CACHE_TB watchdog");
  end
endmodule
