// Formal check of muldiv_unit (all 13 RV64M operations) against a reference
// written from the RISC-V spec with SystemVerilog arithmetic.
//
// The unit is the real 64-bit RTL. Proving a 64x64 multiplier and divider for
// every input is beyond SAT, so each operand is built from a few free bits:
//   bit 63, bit 31, a fill bit repeated over bits 62..32, a fill bit repeated
//   over bits 30..K, and K free low bits.
// That still includes 0, +-1, small values, INT64_MIN/MAX, INT32_MIN/MAX for the
// W forms, all-ones, and division by zero, but it is a restricted operand space,
// not every 64-bit input. One operation is started after reset and its result
// is compared when done rises. Read with: read_slang -D FORMAL.
`ifdef FORMAL
module muldiv_formal #(parameter int K = 8) (
  input logic clk,
  input logic [2:0] op_in,
  input logic word_in,
  input logic a63, a31, a_hi_fill, a_lo_fill, input logic [K-1:0] a_low,
  input logic b63, b31, b_hi_fill, b_lo_fill, input logic [K-1:0] b_low
);
  import core_pkg::*;
  logic rst, start, busy, done;
  logic [63:0] result;
  md_op_t op;
  logic word;
  logic [63:0] a, b;
  muldiv_unit dut(.clk(clk), .rst(rst), .kill(1'b0), .start(start), .op(op), .word(word),
                  .a(a), .b(b), .busy(busy), .done(done), .result(result));

  function automatic logic [63:0] shape(input logic s63, s31, hf, lf, input logic [K-1:0] low);
    return {s63, {31{hf}}, s31, {(31 - K){lf}}, low};
  endfunction

  // Operands and operation are fixed for the whole run; the single start
  // happens on the first cycle after reset.
  logic [2:0] cyc = 3'd0;
  always_ff @(posedge clk) if (cyc != 3'd7) cyc <= cyc + 3'd1;
  assign rst = cyc == 3'd0;
  assign start = cyc == 3'd1;
  assign op = md_op_t'(op_in);
  assign word = word_in;
  assign a = shape(a63, a31, a_hi_fill, a_lo_fill, a_low);
  assign b = shape(b63, b31, b_hi_fill, b_lo_fill, b_low);
  always_ff @(posedge clk) if (cyc != 3'd0)
    assume ($stable(op_in) && $stable(word_in) && $stable(a63) && $stable(a31) && $stable(a_hi_fill) &&
            $stable(a_lo_fill) && $stable(a_low) && $stable(b63) && $stable(b31) && $stable(b_hi_fill) &&
            $stable(b_lo_fill) && $stable(b_low));
  // Only MUL has a W form among the multiplies (MULW); MULH* have none.
  always_comb assume (!(word_in && (op_in == 3'd1 || op_in == 3'd2 || op_in == 3'd3)));
`ifdef OP
  // One operation per SymbiYosys task keeps each solver query small.
  always_comb assume (op_in == 3'(`OP) && word_in == 1'(`WORD));
`endif

  // ------------------------------------------------- RISC-V reference
  function automatic logic [63:0] sext32(input logic [31:0] x);
    return {{32{x[31]}}, x};
  endfunction
  function automatic logic [63:0] reference(input logic [2:0] f, input logic w, input logic [63:0] x, y);
    logic signed [127:0] ps; logic [127:0] pu, psu;
    logic signed [63:0] sx, sy; logic signed [31:0] sx32, sy32;
    logic [31:0] ux32, uy32;
    sx = x; sy = y; sx32 = x[31:0]; sy32 = y[31:0]; ux32 = x[31:0]; uy32 = y[31:0];
    ps = 128'(signed'(sx)) * 128'(signed'(sy));
    pu = {64'b0, x} * {64'b0, y};
    psu = 128'(signed'(sx)) * $signed({64'b0, y});
    if (!w) case (f)
      3'd0: return pu[63:0];                                   // MUL
      3'd1: return ps[127:64];                                 // MULH
      3'd2: return psu[127:64];                                // MULHSU
      3'd3: return pu[127:64];                                 // MULHU
      3'd4: return y == 0 ? '1 : (x == 64'h8000_0000_0000_0000 && y == '1) ? x : 64'(sx / sy);   // DIV
      3'd5: return y == 0 ? '1 : x / y;                        // DIVU
      3'd6: return y == 0 ? x : (x == 64'h8000_0000_0000_0000 && y == '1) ? 64'd0 : 64'(sx % sy); // REM
      default: return y == 0 ? x : x % y;                      // REMU
    endcase
    else case (f)
      3'd0: return sext32(32'(ux32 * uy32));                   // MULW
      3'd4: return uy32 == 0 ? '1 : (ux32 == 32'h8000_0000 && uy32 == '1) ? sext32(ux32) : sext32(32'(sx32 / sy32)); // DIVW
      3'd5: return uy32 == 0 ? '1 : sext32(ux32 / uy32);       // DIVUW
      3'd6: return uy32 == 0 ? sext32(ux32) : (ux32 == 32'h8000_0000 && uy32 == '1) ? 64'd0 : sext32(32'(sx32 % sy32)); // REMW
      default: return uy32 == 0 ? sext32(ux32) : sext32(ux32 % uy32); // REMUW
    endcase
  endfunction

  logic seen_done = 1'b0;
  always_ff @(posedge clk) if (rst) seen_done <= 1'b0; else if (done) seen_done <= 1'b1;
  always_ff @(posedge clk) if (cyc >= 3'd2) begin
    if (done) ap_result: assert (result == reference(op_in, word_in, a, b));
    if (done) ap_single_done: assert (!seen_done);
    if (cyc >= 3'd2 && !done && !seen_done) ap_busy_until_done: assert (busy);
  end
  always_ff @(posedge clk) if (cyc >= 3'd2) begin
    cp_done_full: cover (done && !word_in);
    cp_done_word: cover (done && word_in);
    cp_div_overflow: cover (done && op_in == 3'd4 && !word_in && a == 64'h8000_0000_0000_0000 && b == '1);
    cp_div_zero: cover (done && op_in == 3'd5 && b == 0);
  end
endmodule
`endif
