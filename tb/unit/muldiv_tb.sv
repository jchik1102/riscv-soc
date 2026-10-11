`timescale 1ns/1ps
module muldiv_tb;
  import core_pkg::*;
  logic clk = 0, rst = 1, kill = 0, start = 0, word = 0;
  md_op_t op = MD_MUL;
  logic [63:0] a = 0, b = 0;
  logic busy, done;
  logic [63:0] result;
  always #5 clk = ~clk;
  muldiv_unit dut(.*);

  typedef struct { logic [2:0] f3; logic word; logic [63:0] a, b, expected; } vec_t;
  vec_t vectors[$];
  string vector_path;
  int seed = 1;
  int unsigned rng_state = 1;

  function automatic int unsigned rnd();
    rng_state ^= rng_state << 13; rng_state ^= rng_state >> 17; rng_state ^= rng_state << 5;
    return rng_state;
  endfunction
  function automatic int unsigned rnd_range(int unsigned lo, int unsigned hi);
    return lo + rnd() % (hi - lo + 1);
  endfunction

  logic [63:0] drive_expected;
  int drive_latency, drive_class;

  longint cycle = 0;
  bit reset_seen = 0;
  bit pending = 0;
  logic [63:0] pending_expected;
  longint pending_accept, pending_due;
  int pending_class;
  int accepts = 0, dones = 0, canceled = 0, ignored_starts = 0, back_to_back = 0;
  int changed_inputs = 0, cancel_tests = 0, reset_with_start = 0;
  int latency [4] = '{-1, -1, -1, -1};
  int checked [16];

  function automatic int class_of(logic [2:0] f3, logic w);
    return (f3[2] ? 2 : 0) + (w ? 1 : 0);
  endfunction

  always @(posedge clk) begin
    cycle++;
    if (cycle > 3000000) $fatal(1, "Global watchdog expired");
    if (reset_seen && $isunknown({busy, done})) $fatal(1, "Unknown busy/done");
    if (rst) reset_seen = 1;
    if (done && busy) $fatal(1, "done and busy asserted together");
    if (pending && !done && !busy) $fatal(1, "busy dropped before done");
    if (done) begin
      if (!pending) $fatal(1, "done without an outstanding accepted operation (canceled op completed?)");
      if (cycle != pending_due)
        $fatal(1, "Latency mismatch: done sampled %0d cycles after acceptance, expected %0d",
               cycle - pending_accept, pending_due - pending_accept);
      if ($isunknown(result) || result !== pending_expected)
        $fatal(1, "Result mismatch: expected %016h actual %016h", pending_expected, result);
      latency[pending_class] = int'(cycle - pending_accept - 1);
      pending = 0;
      dones++;
    end
    if (pending && cycle >= pending_due) $fatal(1, "Operation watchdog: done missing");
    if (rst || kill) begin
      if (pending) canceled++;
      if (start) reset_with_start++;
      pending = 0;
    end else if (start && !busy) begin
      pending = 1;
      pending_expected = drive_expected;
      pending_accept = cycle;
      pending_due = cycle + drive_latency + 1;
      pending_class = drive_class;
      accepts++;
    end else if (start) ignored_starts++;
  end

  task automatic drive(vec_t v);
    op = md_op_t'(v.f3); word = v.word; a = v.a; b = v.b; start = 1;
    drive_expected = v.expected;
    drive_latency = (v.word ? 32 : 64) + 1;
    drive_class = class_of(v.f3, v.word);
  endtask

  task automatic disturb();
    op = md_op_t'(rnd_range(0, 7)); word = rnd_range(0, 1);
    a = {rnd(), rnd()}; b = {rnd(), rnd()};
    start = rnd_range(0, 2) == 0;
    changed_inputs++;
  endtask

  task automatic run_vector(vec_t v);
    if (done) back_to_back++;
    drive(v);
    @(negedge clk);
    if (!busy) $fatal(1, "Operation was not accepted");
    do begin disturb(); @(negedge clk); end while (!done);
    start = 0;
    checked[{v.f3, v.word}]++;
  endtask

  task automatic cancel_test(vec_t v, int after, bit use_kill);
    if (after == 0) begin
      drive(v);
      if (use_kill) kill = 1; else rst = 1;
      @(negedge clk);
      if (busy) $fatal(1, "start accepted during %s", use_kill ? "kill" : "reset");
    end else begin
      drive(v);
      @(negedge clk);
      repeat (after - 1) begin disturb(); @(negedge clk); end
      disturb();
      if (use_kill) kill = 1; else rst = 1;
      @(negedge clk);
    end
    rst = 0; kill = 0; start = 0;
    repeat (80) begin
      @(negedge clk);
      if (busy || done) $fatal(1, "Canceled operation remained active (after=%0d)", after);
    end
    cancel_tests++;
    run_vector(v);
    @(negedge clk);
  endtask

  initial begin
    int fd, f3, w, count;
    logic [63:0] va, vb, ve;
    vec_t v, sample [4];
    bit found [4];
    if (!$value$plusargs("VECTORS=%s", vector_path)) $fatal(1, "VECTORS required");
    if ($value$plusargs("SEED=%d", seed)) begin end
    rng_state = seed == 0 ? 1 : seed;
    fd = $fopen(vector_path, "r");
    if (fd == 0) $fatal(1, "Cannot open vectors");
    while (!$feof(fd)) begin
      count = $fscanf(fd, "%h %h %h %h %h\n", f3, w, va, vb, ve);
      if (count == 5) begin
        v.f3 = f3; v.word = w; v.a = va; v.b = vb; v.expected = ve;
        vectors.push_back(v);
      end else if (count > 0) $fatal(1, "Malformed vector line");
    end
    $fclose(fd);
    if (vectors.size() == 0) $fatal(1, "No vectors read");

    repeat (3) @(negedge clk);
    rst = 0;
    @(negedge clk);
    if (busy || done) $fatal(1, "Unit active after reset");

    foreach (vectors[i]) begin
      automatic int gap = rnd_range(0, 3) == 0 ? 0 : rnd_range(1, 3);
      if (gap > 0) begin
        start = 0;
        repeat (gap) begin
          a = {rnd(), rnd()}; @(negedge clk);
        end
      end
      run_vector(vectors[i]);
    end
    @(negedge clk);

    foreach (vectors[i]) begin
      automatic int c = class_of(vectors[i].f3, vectors[i].word);
      if (!found[c]) begin found[c] = 1; sample[c] = vectors[i]; end
    end
    for (int c = 0; c < 4; c++) begin
      automatic int iter = c[0] ? 32 : 64;
      automatic int points [7] = '{0, 1, 2, iter / 2, iter, iter + 1, iter + 2};
      if (!found[c]) $fatal(1, "Missing vector class %0d", c);
      foreach (points[p]) begin
        cancel_test(sample[c], points[p], 0);
        cancel_test(sample[c], points[p], 1);
      end
    end

    foreach (checked[k]) begin
      automatic bit legal = k[0] == 0 || k[3:1] inside {0, 4, 5, 6, 7};
      if (legal && checked[k] == 0) $fatal(1, "No checked operation for funct3=%0d word=%0d", k[3:1], k[0]);
    end
    if (accepts != dones + canceled) $fatal(1, "Accepted %0d != completed %0d + canceled %0d", accepts, dones, canceled);
    if (back_to_back == 0 || ignored_starts == 0 || reset_with_start == 0) $fatal(1, "Protocol scenario not exercised");
    $display("MULDIV_LATENCY mul64=%0d mulw=%0d div64=%0d divw=%0d", latency[0], latency[1], latency[2], latency[3]);
    $display("MULDIV_TEST_PASS vectors=%0d accepted=%0d completed=%0d canceled=%0d cancel_tests=%0d ignored_starts=%0d back_to_back=%0d changed_input_cycles=%0d start_during_cancel=%0d",
             vectors.size(), accepts, dones, canceled, cancel_tests, ignored_starts, back_to_back, changed_inputs, reset_with_start);
    $finish;
  end
endmodule
