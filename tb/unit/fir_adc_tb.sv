`timescale 1ns/1ps
// Mixed-signal bench: a real-valued analog source drives the ADC model
// (tb/unit/adc_rnm.sv), and every ADC code goes through the hardware FIR
// filter (rtl/peripherals/fir_filter.sv) on its bus port, the way firmware
// would feed it: write the sample, read the output, before the next sample.
//
// TEST=0: one tone at 0.9 of full scale, ideal 12-bit ADC (no noise, offset
//         or gain error). The bench checks the sample-and-hold timing and that
//         every code is within half an LSB of the sampled voltage.
// TEST=1: two tones, one in the pass band and one in the stop band of the
//         low-pass filter, 12-bit ADC with input noise, offset and gain error.
// Both use coherent sampling: N = 1024 samples at fs = 1 MHz, tones on prime
// FFT bins. The bench writes +OUT=<csv> (n, vin, code, y) for
// matlab/adc_fir_check.m, which checks the filter output bit for bit against
// fir_model and measures SNR, tone levels and the filter's attenuation.
module fir_adc_tb #(parameter int TEST = 0, parameter int LANES = 4);
  import soc_pkg::*;
  localparam logic [63:0] BASE = 64'h0000000010020000;
  localparam logic [63:0] CTRL = BASE + 'h00, DATA = BASE + 'h20, COEFF = BASE + 'h100;
  localparam int TAPS = 16, N = 1024, BITS = 12;
  localparam real VREF = 1.0;
  localparam real TS_NS = 1000.0;                       // fs = 1 MHz
  localparam real PI = 3.14159265358979323846;
  localparam int BIN1 = 31, BIN2 = 409;                  // 30.3 kHz and 399.4 kHz
  localparam real AMP1 = TEST == 0 ? 0.9 : 0.45, AMP2 = TEST == 0 ? 0.0 : 0.45;
  localparam real NOISE = TEST == 0 ? 0.0 : 100.0e-6;    // about 0.2 LSB rms
  localparam real OFFSET = TEST == 0 ? 0.0 : 1.5e-3;     // about 3 LSB
  localparam real GAIN = TEST == 0 ? 1.0 : 0.995;
  localparam real LSB = 2.0 * VREF / (2.0 ** BITS);

  logic clk = 0;
  always #10 clk = ~clk;                                 // bus clock, 50 MHz
  logic rst = 1;
  logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 1;
  bus_req_t req = '0;
  bus_rsp_t rsp;
  fir_filter #(.TAPS(TAPS), .LANES(LANES), .BASE(BASE)) dut(.clk(clk), .rst(rst),
    .req_valid(req_valid), .req_ready(req_ready), .req(req), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp));

  // Analog source, recomputed every 1 ns. The ADC clock edges fall half a
  // nanosecond after each update, so sample n sees exactly vin(n * Ts).
  real vin = 0.0;
  function automatic real source(input real t_ns);
    real t = t_ns / TS_NS;                               // in sample periods
    return AMP1 * $sin(2.0 * PI * BIN1 * t / N) + AMP2 * $sin(2.0 * PI * BIN2 * t / N);
  endfunction
  initial forever begin vin = source($realtime); #1; end
  logic adc_clk = 0;
  initial begin #0.5; forever begin adc_clk = 1; #(TS_NS / 2); adc_clk = 0; #(TS_NS / 2); end end
  logic signed [15:0] code;
  logic overrange;
  real sampled;
  adc_rnm #(.BITS(BITS), .VREF(VREF), .OFFSET(OFFSET), .GAIN(GAIN), .NOISE_RMS(NOISE), .SEED(7)) adc(
    .vin(vin), .clk(adc_clk), .code(code), .overrange(overrange), .sampled(sampled));

  function automatic real rabs(input real a);
    return a < 0.0 ? -a : a;
  endfunction
  int errors = 0, checks = 0;
  task automatic check(input bit condition, input string message);
    checks++;
    if (!condition) begin errors++; $error("FIR_ADC_TB %0t: %s", $realtime, message); end
    if (errors > 20) $fatal(1, "FIR_ADC_TB: too many errors");
  endtask
  task automatic access(input bit write, input logic [63:0] addr, input logic [63:0] wdata, output logic [63:0] rdata);
    @(negedge clk);
    req_valid = 1; req.write = write; req.addr = addr; req.wdata = wdata; req.mask = 8'hff;
    #1;
    while (!req_ready) begin @(negedge clk); #1; end
    @(posedge clk);
    @(negedge clk);
    req_valid = 0;
    check(rsp_valid && !rsp.error, $sformatf("access to %h failed", addr));
    rdata = rsp.rdata;
    @(posedge clk);
  endtask

  string coeff_path, out_path;
  initial begin
    int fd, out, rc, value;
    logic [63:0] v;
    automatic real t_sample, exact, max_q_err = 0.0, max_sh_err = 0.0, latency, max_latency = 0.0;
    automatic int clipped = 0;
    if (!$value$plusargs("COEFFS=%s", coeff_path)) $fatal(1, "COEFFS required");
    if (!$value$plusargs("OUT=%s", out_path)) $fatal(1, "OUT required");
    repeat (3) @(negedge clk);
    rst = 0;
    access(1, CTRL, 1, v);
    fd = $fopen(coeff_path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", coeff_path);
    for (int k = 0; k < TAPS; k++) begin rc = $fscanf(fd, "%d", value); access(1, COEFF + 8*k, 64'(value), v); end
    $fclose(fd);
    out = $fopen(out_path, "w");
    $fdisplay(out, "n,vin,code,y");
    for (int n = 0; n < N; n++) begin
      @(posedge adc_clk);
      #1;                                                // the ADC's nonblocking outputs have landed
      t_sample = $realtime - 1.0;
      exact = source(t_sample - 0.5);
      if (TEST == 0) begin
        if (rabs(sampled - exact) > max_sh_err) max_sh_err = rabs(sampled - exact);
        if (!overrange && rabs(real'(code >>> (16 - BITS)) * LSB - sampled) > max_q_err)
          max_q_err = rabs(real'(code >>> (16 - BITS)) * LSB - sampled);
      end
      if (overrange) clipped++;
      access(1, DATA, 64'(code), v);
      access(0, DATA, 0, v);
      latency = $realtime - t_sample;
      if (latency > max_latency) max_latency = latency;
      check(latency < TS_NS, $sformatf("sample %0d took %0.1f ns, longer than the sample period", n, latency));
      $fdisplay(out, "%0d,%.9f,%0d,%0d", n, exact, code, $signed(v[15:0]));
    end
    $fclose(out);
    if (TEST == 0) begin
      check(max_sh_err < 1.0e-9, $sformatf("sample-and-hold error %g V", max_sh_err));
      check(max_q_err <= LSB / 2.0 + 1.0e-12, $sformatf("quantization error %g V, more than half an LSB (%g V)", max_q_err, LSB / 2.0));
    end
    check(clipped == 0, $sformatf("%0d samples clipped", clipped));
    if (errors == 0)
      $display("FIR_ADC_TB_PASS test=%0d samples=%0d bits=%0d max_quant_err_lsb=%.3f max_sh_err_v=%g max_sample_to_output_ns=%.1f checks=%0d",
               TEST, N, BITS, max_q_err / LSB, max_sh_err, max_latency, checks);
    else $fatal(1, "FIR_ADC_TB_FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #(TS_NS * (N + 20)); $fatal(1, "FIR_ADC_TB watchdog"); end
endmodule
