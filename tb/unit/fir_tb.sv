`timescale 1ns/1ps
// Unit bench of rtl/peripherals/fir_filter.sv on its bus port.
// +CASES=<file> gives the cases matlab/fir_vectors.m wrote (coefficients,
// inputs and fir_model's outputs); every output must match bit for bit. Each
// case starts with CTRL.CLEAR and reprograms the coefficients. Directed checks
// then cover the register map: read-back, STATUS while busy, accesses held
// while computing, byte-lane masks, error responses (which must not change
// state), response backpressure and the CYCLES and SAMPLES counters.
module fir_tb #(parameter int TAPS = 16, parameter int LANES = 4);
  import soc_pkg::*;
  localparam logic [63:0] BASE = 64'h0000000010020000;
  localparam int STEPS = TAPS / LANES;
  localparam logic [63:0] CTRL = BASE + 'h00, STATUS = BASE + 'h08, INFO = BASE + 'h10, CYCLES = BASE + 'h18,
                          DATA = BASE + 'h20, SAMPLES = BASE + 'h28, COEFF = BASE + 'h100;

  logic clk = 0;
  always #10 clk = ~clk;
  logic rst = 1;
  logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 1;
  bus_req_t req = '0;
  bus_rsp_t rsp;
  fir_filter #(.TAPS(TAPS), .LANES(LANES), .BASE(BASE)) dut(.clk(clk), .rst(rst),
    .req_valid(req_valid), .req_ready(req_ready), .req(req), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp));

  int errors = 0, checks = 0, outputs = 0, max_wait = 0, min_data_wait = 1 << 30;
  task automatic check(input bit condition, input string message);
    checks++;
    if (!condition) begin errors++; $error("FIR_TB %0t: %s", $realtime, message); end
    if (errors > 20) $fatal(1, "FIR_TB: too many errors");
  endtask

  // One bus access. waits counts the cycles req_valid was high before the
  // handshake; rsp_hold keeps rsp_ready low for that many cycles first.
  task automatic access(input bit write, input logic [63:0] addr, input logic [63:0] wdata, input logic [7:0] mask,
                        output logic [63:0] rdata, output bit error, output int waits, input int rsp_hold = 0);
    @(negedge clk);
    req_valid = 1; req.write = write; req.addr = addr; req.wdata = wdata; req.mask = mask;
    #1;   // let req_ready settle for the new request before sampling it
    waits = 0;
    while (!req_ready) begin waits++; @(negedge clk); #1; end
    @(posedge clk);
    @(negedge clk);
    req_valid = 0;
    if (rsp_hold > 0) begin
      rsp_ready = 0;
      repeat (rsp_hold) begin check(rsp_valid, "response dropped under backpressure"); @(negedge clk); end
      rsp_ready = 1;
    end
    check(rsp_valid, "no response the cycle after the handshake");
    rdata = rsp.rdata; error = rsp.error;
    @(posedge clk);
    if (waits > max_wait) max_wait = waits;
  endtask
  task automatic wr(input logic [63:0] addr, input logic [63:0] wdata, input logic [7:0] mask = 8'hff,
                    input bit expect_error = 0);
    logic [63:0] r; bit e; int w;
    access(1, addr, wdata, mask, r, e, w);
    check(e == expect_error, $sformatf("write %h: error=%0d, expected %0d", addr, e, expect_error));
  endtask
  task automatic rd(input logic [63:0] addr, output logic [63:0] value, input bit expect_error = 0);
    bit e; int w;
    access(0, addr, 0, 8'hff, value, e, w);
    check(e == expect_error, $sformatf("read %h: error=%0d, expected %0d", addr, e, expect_error));
  endtask
  task automatic expect_reg(input logic [63:0] addr, input logic [63:0] want, input string name);
    logic [63:0] v;
    rd(addr, v);
    check(v === want, $sformatf("%s = %h, expected %h", name, v, want));
  endtask
  // Push a sample and read the output back, as the firmware driver does.
  task automatic push_pull(input logic signed [15:0] sample, output logic signed [15:0] result);
    logic [63:0] v; bit e; int w;
    wr(DATA, 64'(sample));
    access(0, DATA, 0, 8'hff, v, e, w);
    check(!e, "DATA read error");
    check(v === 64'(signed'(v[15:0])), $sformatf("DATA read %h is not a sign-extended 16-bit value", v));
    if (w < min_data_wait) min_data_wait = w;
    result = v[15:0];
  endtask

  // Behavioural reference for the directed checks (the MATLAB cases cover the arithmetic).
  logic signed [15:0] ref_h [TAPS], ref_x [TAPS];
  function automatic logic signed [15:0] ref_step(input logic signed [15:0] sample);
    longint acc;
    for (int k = TAPS - 1; k > 0; k--) ref_x[k] = ref_x[k-1];
    ref_x[0] = sample;
    acc = 0;
    for (int k = 0; k < TAPS; k++) acc += longint'(ref_h[k]) * longint'(ref_x[k]);
    acc = (acc + (64'sd1 <<< 14)) >>> 15;
    if (acc > 32767) acc = 32767;
    if (acc < -32768) acc = -32768;
    return 16'(acc);
  endfunction
  task automatic load_coeffs(input logic signed [15:0] coeff [TAPS]);
    wr(CTRL, 1);
    for (int k = 0; k < TAPS; k++) begin wr(COEFF + 8*k, 64'(coeff[k])); ref_h[k] = coeff[k]; ref_x[k] = 0; end
  endtask

  string cases_path;
  initial begin
    int fd, rc, ncases, taps, n, x, y;
    logic signed [15:0] coeff [TAPS];
    logic signed [15:0] got;
    logic [63:0] v, saved;
    bit e; int w;
    if (!$value$plusargs("CASES=%s", cases_path)) $fatal(1, "CASES required");
    repeat (3) @(negedge clk);
    rst = 0;
    expect_reg(INFO, {32'b0, 8'd1, 8'(LANES), 16'(TAPS)}, "INFO");
    expect_reg(STATUS, 0, "STATUS after reset");
    expect_reg(SAMPLES, 0, "SAMPLES after reset");

    // ------------------------------------------------------ MATLAB cases
    fd = $fopen(cases_path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", cases_path);
    rc = $fscanf(fd, "%d", ncases);
    for (int c = 0; c < ncases; c++) begin
      rc = $fscanf(fd, "%d %d", taps, n);
      if (taps != TAPS) $fatal(1, "case %0d has %0d taps, bench has %0d", c, taps, TAPS);
      for (int k = 0; k < TAPS; k++) begin rc = $fscanf(fd, "%d", x); coeff[k] = 16'(x); end
      load_coeffs(coeff);
      for (int k = 0; k < TAPS; k++) expect_reg(COEFF + 8*k, 64'(coeff[k]), $sformatf("COEFF[%0d] read-back", k));
      for (int i = 0; i < n; i++) begin
        rc = $fscanf(fd, "%d %d", x, y);
        push_pull(16'(x), got);
        outputs++;
        check(got === 16'(y), $sformatf("case %0d output %0d: got %0d, MATLAB %0d", c, i, got, y));
      end
      expect_reg(SAMPLES, 64'(n), $sformatf("case %0d SAMPLES", c));
      expect_reg(CYCLES, 64'(n * STEPS), $sformatf("case %0d CYCLES", c));
    end
    $fclose(fd);

    // --------------------------------------------------- directed checks
    for (int k = 0; k < TAPS; k++) coeff[k] = 16'(1000 * (k + 1) - 9000);
    load_coeffs(coeff);
    // STATUS is not held: busy reads 1 right after a push (when a push takes more than one cycle).
    wr(DATA, 64'(16'sd12345));
    void'(ref_step(16'sd12345));
    access(0, STATUS, 0, 8'hff, v, e, w);
    check(!e && w <= 1, $sformatf("STATUS read was held: error=%0d waits=%0d", e, w));
    if (STEPS > 1) check(v[0] == 1, "STATUS.busy not set while computing");
    expect_reg(DATA, 64'(ref_step_peek()), "output after STATUS read");
    // A coefficient write while computing is held until the output is done,
    // so the output in flight uses the old coefficients.
    wr(DATA, 64'(-16'sd20000));
    got = ref_step(-16'sd20000);
    access(1, COEFF + 8*3, 64'(16'sd7), 8'hff, v, e, w);
    check(!e && (STEPS == 1 || w > 0), $sformatf("COEFF write while busy: error=%0d waits=%0d", e, w));
    ref_h[3] = 7;
    expect_reg(DATA, 64'(got), "output computed with the old coefficient");
    push_pull(16'sd5, got);
    check(got === ref_step(16'sd5), "output after the held coefficient write");
    // Narrower stores carry the sample in bytes 0 and 1.
    access(1, DATA, 64'h0000_0000_0000_8001, 8'h03, v, e, w);
    check(!e, "16-bit store to DATA");
    expect_reg(DATA, 64'(ref_step(16'sh8001)), "output after a 16-bit store");
    access(1, DATA, 64'h1234_5678_0000_7ff0, 8'h0f, v, e, w);
    check(!e, "32-bit store to DATA");
    expect_reg(DATA, 64'(ref_step(16'sh7ff0)), "output after a 32-bit store (upper bits ignored)");
    // Error responses, none of which may change state.
    rd(SAMPLES, saved);
    wr(DATA + 4, 64'h1, 8'hf0, 1);            // unaligned
    wr(DATA, 64'h1, 8'hfc, 1);                // misses byte lanes 0-1
    wr(DATA, 64'h1, 8'h01, 1);                // only byte 0
    wr(STATUS, 1, 8'hff, 1);                  // read-only registers
    wr(INFO, 1, 8'hff, 1);
    wr(CYCLES, 1, 8'hff, 1);
    wr(SAMPLES, 1, 8'hff, 1);
    rd(CTRL, v, 1);                           // write-only
    rd(BASE + 'h30, v, 1);                    // unmapped
    rd(COEFF + 8*TAPS, v, 1);                 // one past the last coefficient
    rd(COEFF + 4, v, 1);                      // unaligned coefficient
    rd(BASE + 'h1000, v, 1);
    wr(COEFF + 8*TAPS, 64'h1, 8'hff, 1);
    expect_reg(SAMPLES, saved, "SAMPLES after error responses");
    expect_reg(COEFF + 8*3, 64'(16'sd7), "COEFF[3] after error responses");
    push_pull(-16'sd1, got);
    check(got === ref_step(-16'sd1), "output after error responses");
    // Backpressure on the response: the read data must stay put.
    wr(DATA, 64'(16'sd31000));
    got = ref_step(16'sd31000);
    access(0, DATA, 0, 8'hff, v, e, w, 5);
    check(!e && v[15:0] === got, "DATA read under response backpressure");
    // CLEAR zeroes the delay line, output and counters, and keeps the coefficients.
    wr(CTRL, 1);
    for (int k = 0; k < TAPS; k++) ref_x[k] = 0;
    expect_reg(DATA, 0, "DATA after CLEAR");
    expect_reg(SAMPLES, 0, "SAMPLES after CLEAR");
    expect_reg(CYCLES, 0, "CYCLES after CLEAR");
    expect_reg(COEFF, 64'(coeff[0]), "COEFF[0] after CLEAR");
    wr(CTRL, 0);                              // CLEAR bit low: no effect
    push_pull(16'sd100, got);
    check(got === ref_step(16'sd100), "first output after CLEAR");
    expect_reg(SAMPLES, 1, "SAMPLES after CTRL write of 0");

    if (STEPS > 1) check(min_data_wait > 0, "a DATA read right after a push was never held");
    if (errors == 0)
      $display("FIR_TB_PASS taps=%0d lanes=%0d steps=%0d cases=%0d matlab_outputs=%0d checks=%0d max_wait=%0d",
               TAPS, LANES, STEPS, ncases, outputs, checks, max_wait);
    else $fatal(1, "FIR_TB_FAIL errors=%0d", errors);
    $finish;
  end
  function automatic logic signed [15:0] ref_step_peek();
    longint acc = 0;
    for (int k = 0; k < TAPS; k++) acc += longint'(ref_h[k]) * longint'(ref_x[k]);
    acc = (acc + (64'sd1 <<< 14)) >>> 15;
    if (acc > 32767) acc = 32767;
    if (acc < -32768) acc = -32768;
    return 16'(acc);
  endfunction
  initial begin #50000000; $fatal(1, "FIR_TB watchdog"); end
endmodule
