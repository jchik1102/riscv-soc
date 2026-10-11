module mul_iter (
  input logic clk, rst, kill,
  input logic start,
  input core_pkg::md_op_t op,
  input logic word,
  input logic [63:0] a, b,
  output logic busy, done,
  output logic [63:0] result
);
  import core_pkg::*;
  logic [63:0] multiplicand, hi, lo, correction;
  logic [6:0] remaining;
  md_op_t op_q;
  logic word_q;
  logic [64:0] partial;
  logic [63:0] correction_next, finished;
  logic a_signed, b_signed;

  always_comb begin
    a_signed = op == MD_MULH || op == MD_MULHSU;
    b_signed = op == MD_MULH;
    correction_next = (a_signed && a[63] ? b : 64'b0) + (b_signed && b[63] ? a : 64'b0);
    partial = {1'b0, hi} + (lo[0] ? {1'b0, multiplicand} : 65'b0);
    case (op_q)
      MD_MUL: finished = word_q ? {{32{lo[63]}}, lo[63:32]} : lo;
      MD_MULHU: finished = hi;
      default: finished = hi - correction;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst || kill) begin
      busy <= 0;
      done <= 0;
      remaining <= 0;
      if (rst) begin
        result <= 0; hi <= 0; lo <= 0; multiplicand <= 0; correction <= 0;
        op_q <= MD_MUL; word_q <= 0;
      end
    end else begin
      done <= 0;
      if (!busy) begin
        if (start) begin
          busy <= 1;
          op_q <= op;
          word_q <= word;
          hi <= 0;
          multiplicand <= word ? {32'b0, a[31:0]} : a;
          lo <= word ? {32'b0, b[31:0]} : b;
          correction <= correction_next;
          remaining <= word ? 7'd32 : 7'd64;
        end
      end else if (remaining != 0) begin
        hi <= partial[64:1];
        lo <= {partial[0], lo[63:1]};
        remaining <= remaining - 7'd1;
      end else begin
        result <= finished;
        done <= 1;
        busy <= 0;
      end
    end
  end
endmodule
