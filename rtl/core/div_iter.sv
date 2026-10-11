module div_iter (
  input logic clk, rst, kill,
  input logic start,
  input core_pkg::md_op_t op,
  input logic word,
  input logic [63:0] a, b,
  output logic busy, done,
  output logic [63:0] result
);
  import core_pkg::*;
  logic [63:0] divisor, remainder, quotient;
  logic [6:0] remaining;
  logic word_q, want_remainder, negate_quotient, negate_remainder, divide_by_zero;
  logic is_signed;
  logic [63:0] dividend_ext, divisor_ext, dividend_mag, divisor_mag;
  logic [64:0] shifted;
  logic [65:0] trial;
  logic [63:0] quotient_out, remainder_out, selected;

  always_comb begin
    is_signed = op == MD_DIV || op == MD_REM;
    if (word) begin
      dividend_ext = is_signed ? {{32{a[31]}}, a[31:0]} : {32'b0, a[31:0]};
      divisor_ext = is_signed ? {{32{b[31]}}, b[31:0]} : {32'b0, b[31:0]};
    end else begin
      dividend_ext = a;
      divisor_ext = b;
    end
    dividend_mag = is_signed && dividend_ext[63] ? -dividend_ext : dividend_ext;
    divisor_mag = is_signed && divisor_ext[63] ? -divisor_ext : divisor_ext;

    shifted = {remainder, quotient[63]};
    trial = {1'b0, shifted} - {2'b0, divisor};

    quotient_out = divide_by_zero ? '1 : (negate_quotient ? -quotient : quotient);
    remainder_out = negate_remainder ? -remainder : remainder;
    selected = want_remainder ? remainder_out : quotient_out;
  end

  always_ff @(posedge clk) begin
    if (rst || kill) begin
      busy <= 0;
      done <= 0;
      remaining <= 0;
      if (rst) begin
        result <= 0; divisor <= 0; remainder <= 0; quotient <= 0;
        word_q <= 0; want_remainder <= 0; negate_quotient <= 0;
        negate_remainder <= 0; divide_by_zero <= 0;
      end
    end else begin
      done <= 0;
      if (!busy) begin
        if (start) begin
          busy <= 1;
          word_q <= word;
          want_remainder <= op == MD_REM || op == MD_REMU;
          negate_quotient <= is_signed && (dividend_ext[63] ^ divisor_ext[63]);
          negate_remainder <= is_signed && dividend_ext[63];
          divide_by_zero <= divisor_ext == 0;
          divisor <= divisor_mag;
          remainder <= 0;
          quotient <= word ? {dividend_mag[31:0], 32'b0} : dividend_mag;
          remaining <= word ? 7'd32 : 7'd64;
        end
      end else if (remaining != 0) begin
        if (!trial[65]) begin
          remainder <= trial[63:0];
          quotient <= {quotient[62:0], 1'b1};
        end else begin
          remainder <= shifted[63:0];
          quotient <= {quotient[62:0], 1'b0};
        end
        remaining <= remaining - 7'd1;
      end else begin
        result <= word_q ? {{32{selected[31]}}, selected[31:0]} : selected;
        done <= 1;
        busy <= 0;
      end
    end
  end
endmodule
