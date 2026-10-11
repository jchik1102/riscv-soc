`timescale 1ns/1ps
module accel_tb #(
  parameter int N = 4,
  parameter bit PARALLEL = 1,
  parameter int TRANSACTIONS = 20000
);
  import soc_pkg::*;
  localparam logic [63:0] BASE = platform_pkg::ACCELERATOR_BASE;
  localparam int L = PARALLEL ? N : N * N * N;

  logic clk = 0;
  always #10 clk = ~clk;
  logic rst = 1;
  logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0, irq;
  bus_req_t req = '0;
  bus_rsp_t rsp;
  matrix_accel #(.N(N), .PARALLEL(PARALLEL), .BASE(BASE)) dut(.clk(clk), .rst(rst),
    .req_valid(req_valid), .req_ready(req_ready), .req(req), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp), .irq(irq));

  int errors = 0, checks = 0, cycle = 0, fd;
  int hits [string];
  string required [$] = '{"start_ab", "start_abc", "done_with_irq", "done_masked", "w1c_done", "w1c_start_ignored",
    "start_while_busy", "write_a_busy", "write_b_busy", "write_c_busy", "write_d_error", "byte_error", "half_error",
    "unmapped_error", "row_beyond_n_error", "read_d_busy", "read_d_done", "read_info", "read_cycles_busy", "read_ctrl",
    "word_low", "word_high", "dword", "restart_after_done", "w1c_at_completion_edge", "reset_while_busy",
    "rsp_backpressure", "wrap_overflow", "operand_min_squared", "ignored_register_write", "ctrl_upper_write"};
  function automatic void hit(input string name);
    if (hits.exists(name)) hits[name]++; else hits[name] = 1;
  endfunction
  task automatic check(input bit condition, input string message);
    checks++;
    if (!condition) begin errors++; $error("ACCEL_TB %0t cycle %0d: %s", $realtime, cycle, message); end
    if (errors > 20) $fatal(1, "ACCEL_TB: too many errors");
  endtask
  logic [31:0] rng = 32'h1;
  function automatic int unsigned rnd();
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    return rng;
  endfunction
  function automatic int unsigned urange(input int unsigned lo, input int unsigned hi);
    return lo + rnd() % (hi - lo + 1);
  endfunction
  function automatic logic [7:0] operand();
    int unsigned p;
    p = urange(0, 9);
    if (p == 0) return 8'h80;
    if (p == 1) return 8'h7f;
    if (p == 2) return 8'h00;
    if (p == 3) return 8'h01;
    if (p == 4) return 8'hff;
    return 8'(rnd());
  endfunction
  function automatic logic [31:0] c_value();
    int unsigned p;
    p = urange(0, 7);
    if (p == 0) return 32'h7fffffff;
    if (p == 1) return 32'h80000000;
    if (p == 2) return 32'h7fff0000 + 32'(urange(0, 65535));
    if (p == 3) return 32'h80000000 + 32'(urange(0, 65535));
    if (p == 4) return 32'h0;
    return rnd();
  endfunction

  logic [7:0] ma [N][N], mb [N][N];
  logic [31:0] mc [N][N], md [N][N], mres [N][N];
  bit va [N], vb [N], vc [N][N], vd [N][N], vres [N][N];
  bit m_busy = 0, m_done = 0, m_ign = 0, m_ie = 0, m_acc = 0;
  int m_e0 = 0, m_cycles = 0;
  bit res_wrapped;
  function automatic void model_reset();
    for (int i = 0; i < N; i++) begin
      va[i] = 0; vb[i] = 0;
      for (int j = 0; j < N; j++) begin vc[i][j] = 0; vd[i][j] = 0; end
    end
    m_busy = 0; m_done = 0; m_ign = 0; m_ie = 0; m_acc = 0; m_cycles = 0;
  endfunction
  function automatic void compute();
    res_wrapped = 0;
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) begin
        longint sum = 0;
        bit ok = 1;
        for (int k = 0; k < N; k++) begin
          if (!va[i] || !vb[k]) ok = 0;
          sum += longint'($signed(ma[i][k])) * longint'($signed(mb[k][j]));
          if (ma[i][k] == 8'h80 && mb[k][j] == 8'h80) hit("operand_min_squared");
        end
        if (m_acc) begin
          if (!vc[i][j]) ok = 0;
          sum += longint'($signed(mc[i][j]));
        end
        if (sum > 64'sd2147483647 || sum < -64'sd2147483648) res_wrapped = 1;
        mres[i][j] = sum[31:0];
        vres[i][j] = ok;
      end
  endfunction
  function automatic logic [31:0] model_word(input logic [15:0] off, output bit defined, output bit exists);
    int idx;
    logic [63:0] regv;
    defined = 1; exists = 1;
    idx = int'(off[7:2]);
    model_word = 0;
    if (off < 16'h20) begin
      case (off[4:3])
        2'd0: regv = {61'b0, m_acc, m_ie, 1'b0};
        2'd1: regv = {61'b0, m_ign, m_done, m_busy};
        2'd2: regv = {24'b0, 8'd1, 16'(L), 8'(PARALLEL ? N * N : 1), 8'(N)};
        default: regv = 64'(m_cycles);
      endcase
      model_word = off[2] ? regv[63:32] : regv[31:0];
    end else if (off[15:8] == 8'h01 && idx < N) begin
      defined = va[idx];
      for (int k = 0; k < N; k++) model_word[8*k +: 8] = ma[idx][k];
    end else if (off[15:8] == 8'h02 && idx < N) begin
      defined = vb[idx];
      for (int k = 0; k < N; k++) model_word[8*k +: 8] = mb[idx][k];
    end else if (off[15:8] == 8'h03 && idx < N * N) begin
      defined = vc[idx / N][idx % N]; model_word = mc[idx / N][idx % N];
    end else if (off[15:8] == 8'h04 && idx < N * N) begin
      defined = vd[idx / N][idx % N] && !m_busy; model_word = md[idx / N][idx % N];
    end else exists = 0;
  endfunction

  function automatic bus_req_t random_request();
    bus_req_t r;
    int unsigned pick, word, form;
    logic [15:0] off;
    logic [31:0] w0, w1;
    r = '0;
    pick = urange(0, 99);
    form = urange(0, 2);
    w0 = 0; w1 = 0;
    if (pick < 18) begin
      for (int k = 0; k < 4; k++) begin w0[8*k +: 8] = operand(); w1[8*k +: 8] = operand(); end
      word = urange(0, N - 1);
      off = (pick < 9 ? 16'h100 : 16'h200) + 16'(4 * word);
      r.write = 1;
    end else if (pick < 28) begin
      w0 = c_value(); w1 = c_value();
      word = urange(0, N * N - 1);
      off = 16'h300 + 16'(4 * word);
      r.write = 1;
    end else if (pick < 38) begin
      off = 16'h000; r.write = 1; form = 0; if (urange(0, 7) == 0) form = 2;
      w0 = {29'b0, urange(0, 1) != 0, urange(0, 3) != 0, urange(0, 5) != 0};
    end else if (pick < 55) begin
      off = 16'h008; form = urange(0, 2);
    end else if (pick < 72) begin
      word = urange(0, N * N - 1); off = 16'h400 + 16'(4 * word);
    end else if (pick < 78) begin
      word = urange(0, 3);
      if (word == 0) off = 16'h100 + 16'(4 * urange(0, N - 1));
      else if (word == 1) off = 16'h200 + 16'(4 * urange(0, N - 1));
      else if (word == 2) off = 16'h300 + 16'(4 * urange(0, N * N - 1));
      else off = 16'h000;
    end else if (pick < 85) begin
      off = 16'h008; r.write = 1; form = 0; w0 = {29'b0, urange(0, 1) != 0, urange(0, 2) != 0, 1'b1};
    end else if (pick < 89) begin
      off = 16'h018; if (urange(0, 1) != 0) off = 16'h010; form = urange(0, 2);
    end else if (pick < 93) begin
      off = 16'h018; if (urange(0, 1) != 0) off = 16'h010; r.write = 1; w0 = rnd(); w1 = rnd();
      if (urange(0, 2) == 0) begin off = 16'h000; form = 1; w1 = 32'h7; end
    end else begin
      word = urange(0, 5);
      off = 16'h100 + 16'(4 * urange(0, N - 1));
      r.write = urange(0, 1);
      if (word == 0) off = 16'h020 + 16'(8 * urange(0, 27));
      else if (word == 1) off = 16'h500 + 16'(4 * urange(0, 63));
      else if (word == 2) begin off = 16'h200 + 16'(4 * urange(N, 63)); if (urange(0, 1) != 0) off[9:8] = 2'b01; end
      else if (word == 3) begin off = 16'h400 + 16'(4 * urange(0, N * N - 1)); r.write = 1; end
      w0 = rnd(); w1 = rnd();
      if (word >= 4) begin
        r.addr = BASE + {off[15:3], 3'b0};
        if (word == 4) r.mask = 8'h01 << urange(0, 7); else r.mask = 8'h03 << (2 * urange(0, 3));
        r.wdata = {w1, w0};
        return r;
      end
    end
    r.addr = BASE + {48'b0, off[15:3], 3'b0};
    case (form)
      0: begin r.mask = off[2] ? 8'hf0 : 8'h0f; r.wdata = off[2] ? {w0, 32'b0} : {32'b0, w0}; end
      1: begin r.mask = 8'hf0; r.wdata = {w1, w0}; end
      default: begin r.mask = 8'hff; r.wdata = {w1, w0}; end
    endcase
    return r;
  endfunction

  int issued = 0, gap = 0;
  bit outstanding = 0;
  bit exp_error, exp_defined [2];
  logic [63:0] exp_rdata;
  logic [7:0] exp_mask;
  bit exp_write, exp_d_done;
  always @(negedge clk) begin
    rsp_ready <= urange(0, 3) != 0;
    if (rst) begin
      req_valid <= 0;
    end else if (!req_valid && !outstanding && issued < TRANSACTIONS) begin
      if (gap > 0) gap <= gap - 1;
      else begin
        automatic bus_req_t r = random_request();
        if (m_busy && m_e0 + L == cycle + 1 && urange(0, 1) == 0) begin
          r = '0; r.addr = BASE + 8; r.write = 1; r.mask = 8'h0f; r.wdata = 64'h2;
        end else if (m_done && urange(0, 3) == 0) begin
          r = '0; r.addr = BASE; r.write = 1; r.mask = 8'h0f; r.wdata = {61'b0, urange(0, 1) != 0, 1'b1, 1'b1};
        end
        req <= r;
        req_valid <= 1;
      end
    end
  end

  bit last_irq = 0;
  always @(posedge clk) begin
    automatic bit busy_before = m_busy;
    cycle++;
    if (rst) begin
      if (cycle > 1) check(irq === (m_done && m_ie), $sformatf("irq %b at a reset edge, model DONE %0d IE %0d", irq, m_done, m_ie));
      if (m_busy) hit("reset_while_busy");
      model_reset();
      outstanding = 0;
      $fdisplay(fd, "RESET,%0d", cycle);
    end else begin
      check(irq === (m_done && m_ie), $sformatf("irq %b, model DONE %0d IE %0d", irq, m_done, m_ie));
      if (irq !== last_irq) $fdisplay(fd, "I,%0d,%0d", cycle, irq);
      if (rsp_valid && !rsp_ready) hit("rsp_backpressure");
      if (rsp_valid && rsp_ready) begin
        check(outstanding, "response without request");
        $fdisplay(fd, "R,%01h,%016h", rsp.error, rsp.rdata);
        check(rsp.error === exp_error, $sformatf("error flag %b, expected %b (addr %h mask %h write %0d)", rsp.error, exp_error, req.addr, exp_mask, exp_write));
        for (int h = 0; h < 2; h++) if (exp_mask[4*h] && !exp_error && !exp_write && exp_defined[h])
          check(rsp.rdata[32*h +: 32] === exp_rdata[32*h +: 32], $sformatf("read data half %0d %h, expected %h", h, rsp.rdata[32*h +: 32], exp_rdata[32*h +: 32]));
        if (exp_error || exp_write) check(rsp.rdata === 64'b0, "nonzero data with an error/write response");
        for (int h = 0; h < 2; h++) if (!exp_mask[4*h]) check(rsp.rdata[32*h +: 32] === 32'b0, "unselected half not zero");
        if (exp_d_done) hit("read_d_done");
        outstanding = 0;
        if (urange(0, 3) == 0) gap <= urange(1, 5); else gap <= 0;
      end
      if (req_valid && req_ready) begin
        automatic logic [15:0] off = 16'(req.addr - BASE);
        automatic bit bad = 0, defined, exists;
        automatic logic [31:0] value;
        automatic bit wr_ctrl = 0, wr_status = 0;
        $fdisplay(fd, "Q,%0d,%016h,%01h,%02h,%016h", cycle, req.addr, req.write, req.mask, req.wdata);
        issued++;
        exp_mask = req.mask; exp_write = req.write; exp_rdata = 0; exp_d_done = 0;
        exp_defined[0] = 1; exp_defined[1] = 1;
        if (!(req.mask == 8'h0f || req.mask == 8'hf0 || req.mask == 8'hff)) begin
          bad = 1;
          if (req.mask == 8'h03 || req.mask == 8'h0c || req.mask == 8'h30 || req.mask == 8'hc0) hit("half_error"); else hit("byte_error");
        end
        for (int h = 0; h < 2; h++) if (req.mask[4*h] && !bad) begin
          automatic logic [15:0] w = {off[15:3], h[0], 2'b00};
          value = model_word(w, defined, exists);
          if (!exists) begin
            bad = 1;
            if ((w[15:8] == 8'h01 || w[15:8] == 8'h02)) hit("row_beyond_n_error"); else hit("unmapped_error");
          end else if (req.write && w[15:8] == 8'h04) begin bad = 1; hit("write_d_error"); end
          else if (req.write && busy_before && w[15:8] >= 8'h01 && w[15:8] <= 8'h03) begin
            bad = 1;
            if (w[15:8] == 8'h01) hit("write_a_busy"); else if (w[15:8] == 8'h02) hit("write_b_busy"); else hit("write_c_busy");
          end
          exp_rdata[32*h +: 32] = value;
          exp_defined[h] = defined;
          if (!req.write && w[15:8] == 8'h04) begin if (busy_before) hit("read_d_busy"); else if (defined) exp_d_done = 1; end
          if (!req.write && w == 16'h10) hit("read_info");
          if (!req.write && w == 16'h18 && busy_before) hit("read_cycles_busy");
          if (!req.write && w == 16'h00) hit("read_ctrl");
        end
        if (!bad) begin
          if (req.mask == 8'h0f) hit("word_low"); else if (req.mask == 8'hf0) hit("word_high"); else hit("dword");
        end
        exp_error = bad;
        outstanding = 1;
        if (req.write && !bad) begin
          for (int h = 0; h < 2; h++) if (req.mask[4*h]) begin
            automatic logic [15:0] w = {off[15:3], h[0], 2'b00};
            automatic int idx = int'(w[7:2]);
            automatic logic [31:0] data = req.wdata[32*h +: 32];
            if (w[15:8] == 8'h01) begin va[idx] = 1; for (int k = 0; k < N; k++) ma[idx][k] = data[8*k +: 8]; end
            else if (w[15:8] == 8'h02) begin vb[idx] = 1; for (int k = 0; k < N; k++) mb[idx][k] = data[8*k +: 8]; end
            else if (w[15:8] == 8'h03) begin vc[idx / N][idx % N] = 1; mc[idx / N][idx % N] = data; end
            else if (w == 16'h00) wr_ctrl = 1;
            else if (w == 16'h08) wr_status = 1;
            else if (w == 16'h10 || w == 16'h18) hit("ignored_register_write");
            else if (w == 16'h04) hit("ctrl_upper_write");
          end
          if (wr_status) begin
            if (req.wdata[1] && m_done) hit("w1c_done");
            if (req.wdata[1] && busy_before && m_e0 + L == cycle) hit("w1c_at_completion_edge");
            if (req.wdata[2] && m_ign) hit("w1c_start_ignored");
            if (req.wdata[1]) m_done = 0;
            if (req.wdata[2]) m_ign = 0;
          end
          if (wr_ctrl) begin
            m_ie = req.wdata[1]; m_acc = req.wdata[2];
            if (req.wdata[0] && busy_before) begin m_ign = 1; hit("start_while_busy"); end
            else if (req.wdata[0]) begin
              if (m_done) hit("restart_after_done");
              compute();
              if (res_wrapped) hit("wrap_overflow");
              if (m_acc) hit("start_abc"); else hit("start_ab");
              m_busy = 1; m_done = 0; m_e0 = cycle; m_cycles = 0;
              for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) vd[i][j] = 0;
            end
          end
        end
      end
      if (busy_before) begin
        m_cycles++;
        if (cycle == m_e0 + L) begin
          m_busy = 0; m_done = 1;
          for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) begin md[i][j] = mres[i][j]; vd[i][j] = vres[i][j]; end
          if (m_ie) hit("done_with_irq"); else hit("done_masked");
        end
      end
    end
    last_irq = rst ? 0 : irq;
  end
  always @(posedge clk) if (req_valid && req_ready) req_valid <= 0;

  initial begin
    string path;
    if ($value$plusargs("SEED=%d", rng)) rng = rng * 32'h9e3779b1 + 32'h7f4a7c15;
    if (rng == 0) rng = 1;
    if (!$value$plusargs("TRACE=%s", path)) path = "accel_trace.csv";
    fd = $fopen(path, "w");
    $fdisplay(fd, "N,%0d,%0d", N, PARALLEL);
    model_reset();
    repeat (3) @(posedge clk);
    rst <= 0;
    fork
      forever begin
        @(posedge clk);
        if (!rst && urange(0, 2999) < (m_busy ? 15 : 1)) begin
          rst <= 1;
          repeat (urange(1, 3)) @(posedge clk);
          rst <= 0;
        end
      end
    join_none
    wait (issued >= TRANSACTIONS && !outstanding);
    repeat (L + 10) @(posedge clk);
    $fclose(fd);
    foreach (required[i]) if (!hits.exists(required[i])) begin errors++; $error("ACCEL_TB: coverage bin %s not hit", required[i]); end
    $display("ACCEL_TB n=%0d parallel=%0d latency=%0d transactions=%0d checks=%0d", N, PARALLEL, L, issued, checks);
    foreach (hits[name]) $display("ACCEL_TB cover %s %0d", name, hits[name]);
    if (errors) $fatal(1, "ACCEL_TB FAIL: %0d errors", errors);
    $display("ACCEL_TEST_PASS");
    $finish;
  end
  initial begin
    #(20.0 * TRANSACTIONS * 100);
    $fatal(1, "ACCEL_TB watchdog");
  end
endmodule
