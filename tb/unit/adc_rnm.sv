`timescale 1ns/1ps
// Real-number model of a sampling ADC, for the bench that feeds the hardware
// FIR filter (tb/unit/fir_adc_tb.sv). The analog input is a SystemVerilog
// real on a variable port; XSim does not support user-defined nettypes, so
// there is no resolved real net, only one driver per analog node.
//
// On each rising clk edge the model takes the input as it is at that instant
// (an ideal sample-and-hold), applies offset, gain error and Gaussian input
// noise, and quantizes to BITS bits, two's complement, mid-tread (round to the
// nearest code, ties up). Input beyond the range clips to the end codes and
// sets overrange. The code is left-justified into 16 bits, so it is a Q15
// sample for the filter: full scale +-VREF maps to +-1.0.
module adc_rnm #(
  parameter int BITS = 12,
  parameter real VREF = 1.0,
  parameter real OFFSET = 0.0,       // volts, added to the input
  parameter real GAIN = 1.0,         // 1.0 = no gain error
  parameter real NOISE_RMS = 0.0,    // volts rms, input-referred
  parameter int SEED = 1
) (
  input real vin,
  input logic clk,
  output logic signed [15:0] code,
  output logic overrange,
  output real sampled                // the value that was quantized, for checks
);
  localparam real LSB = 2.0 * VREF / (2.0 ** BITS);
  localparam longint MAX_CODE = (64'sd1 <<< (BITS - 1)) - 1;
  localparam longint MIN_CODE = -(64'sd1 <<< (BITS - 1));
  // synthesis translate_off
  initial if (BITS < 2 || BITS > 16) $fatal(1, "adc_rnm: BITS must be 2 to 16");
  // synthesis translate_on
  int seed = SEED;
  initial begin code = 0; overrange = 0; sampled = 0.0; end

  always @(posedge clk) begin
    real v;
    longint q;
    v = (vin + OFFSET) * GAIN;
    // $dist_normal takes integer arguments: draw with a standard deviation of
    // 1e6 and scale back, giving 1e-6 resolution on a unit normal.
    if (NOISE_RMS != 0.0) v = v + NOISE_RMS * real'($dist_normal(seed, 0, 1000000)) / 1.0e6;
    q = longint'($floor(v / LSB + 0.5));
    overrange <= q > MAX_CODE || q < MIN_CODE;
    if (q > MAX_CODE) q = MAX_CODE;
    if (q < MIN_CODE) q = MIN_CODE;
    code <= 16'(q <<< (16 - BITS));
    sampled <= v;
  end
endmodule
