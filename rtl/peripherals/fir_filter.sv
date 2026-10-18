// Hardware FIR filter on the SoC bus: the same arithmetic as sw/fir.c and
// matlab/fir_model.m. Q15 coefficients and samples, full-precision products
// summed in a 37-bit accumulator, then round half up ((acc + 2^14) >> 15) and
// saturate to 16 bits.
//
// The CPU programs the TAPS coefficients, then writes one sample at a time to
// DATA. Each write shifts the sample into a delay line (zero at reset or after
// CTRL.CLEAR) and starts TAPS/LANES cycles of multiply-accumulate, LANES taps
// per cycle. A DATA read returns the latest output. Accesses that need the
// filter idle (DATA, the coefficients, CTRL) are held off with req_ready low
// while it computes, so "write sample, read output" needs no polling; STATUS,
// INFO, CYCLES and SAMPLES can be read at any time.
//
// Registers (8-byte aligned; writes use the low 16 bits and need byte lanes
// 0 and 1; any other access answers with an error):
//   0x000 CTRL     W  bit 0 CLEAR: zero the delay line, the output and the counters
//   0x008 STATUS   R  bit 0 busy
//   0x010 INFO     R  {version 8, LANES 8, TAPS 16}
//   0x018 CYCLES   R  cycles spent computing since reset or CLEAR
//   0x020 DATA     W  push a sample and start; R  the latest output, sign-extended
//   0x028 SAMPLES  R  outputs computed since reset or CLEAR
//   0x100 + 8k COEFF[k]  RW  coefficient k (k = 0 multiplies the newest sample)
module fir_filter #(
  parameter int TAPS = 16,
  parameter int LANES = 4,
  parameter logic [63:0] BASE = platform_pkg::DSP_BASE
) (
  input logic clk, rst,
  input logic req_valid,
  output logic req_ready,
  input soc_pkg::bus_req_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output soc_pkg::bus_rsp_t rsp
);
  localparam int STEPS = TAPS / LANES;
  localparam int ACC = 32 + $clog2(TAPS) + 1;   // a sum of TAPS 32-bit products, plus a guard bit
  localparam int SW = STEPS > 1 ? $clog2(STEPS) : 1;
  localparam logic [63:0] INFO = {32'b0, 8'd1, 8'(LANES), 16'(TAPS)};
  // synthesis translate_off
  initial if (TAPS < 1 || TAPS > 32 || LANES < 1 || TAPS % LANES != 0)
    $fatal(1, "fir_filter: TAPS must be 1 to 32 and a multiple of LANES");
  // synthesis translate_on

  logic signed [15:0] h [TAPS];
  logic signed [15:0] x [TAPS];      // x[0] is the newest sample
  logic signed [ACC-1:0] acc, acc_next;
  logic signed [15:0] y;
  logic busy;
  logic [SW-1:0] step;
  logic [63:0] cycles, samples;

  localparam logic signed [ACC-1:0] HALF = 1 <<< 14, Y_MAX = 32767, Y_MIN = -32768;
  function automatic logic signed [15:0] round_saturate(input logic signed [ACC-1:0] a);
    logic signed [ACC-1:0] r;
    r = (a + HALF) >>> 15;
    if (r > Y_MAX) return 16'sh7fff;
    if (r < Y_MIN) return 16'sh8000;
    return r[15:0];
  endfunction

  // This cycle's LANES products, taps step*LANES to step*LANES+LANES-1.
  always_comb begin
    acc_next = acc;
    for (int l = 0; l < LANES; l++) begin
      logic signed [31:0] p;
      p = h[step * LANES + l] * x[step * LANES + l];
      acc_next = acc_next + p;
    end
  end

  // ------------------------------------------------------------- bus decode
  typedef enum logic [2:0] {R_CTRL, R_STATUS, R_INFO, R_CYCLES, R_DATA, R_SAMPLES, R_COEFF, R_NONE} kind_t;
  kind_t kind;
  logic [15:0] offset;
  logic [4:0] coeff_index;
  logic bad, hold, accept;
  logic [63:0] rvalue;
  assign offset = 16'(req.addr - BASE);
  assign coeff_index = offset[7:3];
  always_comb begin
    case (offset)
      16'h000: kind = R_CTRL;
      16'h008: kind = R_STATUS;
      16'h010: kind = R_INFO;
      16'h018: kind = R_CYCLES;
      16'h020: kind = R_DATA;
      16'h028: kind = R_SAMPLES;
      default: kind = offset[15:8] == 8'h01 && offset[2:0] == 0 && coeff_index < TAPS ? R_COEFF : R_NONE;
    endcase
    bad = kind == R_NONE;
    if (req.write && (kind == R_STATUS || kind == R_INFO || kind == R_CYCLES || kind == R_SAMPLES)) bad = 1;
    if (!req.write && kind == R_CTRL) bad = 1;
    if (req.write && req.mask[1:0] != 2'b11) bad = 1;
    case (kind)
      R_STATUS: rvalue = {63'b0, busy};
      R_INFO: rvalue = INFO;
      R_CYCLES: rvalue = cycles;
      R_DATA: rvalue = 64'(y);
      R_SAMPLES: rvalue = samples;
      R_COEFF: rvalue = 64'(h[coeff_index]);
      default: rvalue = 0;
    endcase
    hold = busy && !bad && (kind == R_DATA || kind == R_COEFF || kind == R_CTRL);
  end
  assign req_ready = !rst && !rsp_valid && !hold;
  assign accept = req_valid && req_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      rsp_valid <= 0; rsp <= '0;
      busy <= 0; step <= '0; acc <= '0; y <= '0; cycles <= '0; samples <= '0;
      for (int k = 0; k < TAPS; k++) begin h[k] <= '0; x[k] <= '0; end
    end else begin
      if (rsp_valid && rsp_ready) rsp_valid <= 0;
      if (busy) begin
        cycles <= cycles + 1;
        acc <= acc_next;
        if (step == SW'(STEPS - 1)) begin
          busy <= 0;
          y <= round_saturate(acc_next);
          samples <= samples + 1;
        end else step <= step + 1'b1;
      end
      if (accept) begin
        rsp_valid <= 1;
        rsp.error <= bad;
        rsp.rdata <= bad || req.write ? 64'b0 : rvalue;
        if (!bad && req.write) begin
          case (kind)
            R_CTRL: if (req.wdata[0]) begin
              for (int k = 0; k < TAPS; k++) x[k] <= '0;
              y <= '0; cycles <= '0; samples <= '0;
            end
            R_DATA: begin
              x[0] <= req.wdata[15:0];
              for (int k = 1; k < TAPS; k++) x[k] <= x[k-1];
              busy <= 1; step <= '0; acc <= '0;
            end
            R_COEFF: h[coeff_index] <= req.wdata[15:0];
            default: ;
          endcase
        end
      end
    end
  end
endmodule
