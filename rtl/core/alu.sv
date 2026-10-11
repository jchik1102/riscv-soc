module alu (
  input core_pkg::alu_op_t op,
  input logic word_op,
  input logic [63:0] a, b,
  output logic [63:0] result
);
  import core_pkg::*;
  logic [31:0] word_result;
  always_comb begin
    word_result = 0;
    result = 0;
    if (word_op) begin
      case (op)
        OP_ADD: word_result = a[31:0] + b[31:0];
        OP_SUB: word_result = a[31:0] - b[31:0];
        OP_SLL: word_result = a[31:0] << b[4:0];
        OP_SRL: word_result = a[31:0] >> b[4:0];
        OP_SRA: word_result = $signed(a[31:0]) >>> b[4:0];
        default: word_result = 0;
      endcase
      result = {{32{word_result[31]}}, word_result};
    end else begin
      case (op)
        OP_ADD: result = a + b;
        OP_SUB: result = a - b;
        OP_SLL: result = a << b[5:0];
        OP_SLT: result = {63'b0, $signed(a) < $signed(b)};
        OP_SLTU: result = {63'b0, a < b};
        OP_XOR: result = a ^ b;
        OP_SRL: result = a >> b[5:0];
        OP_SRA: result = $signed(a) >>> b[5:0];
        OP_OR: result = a | b;
        OP_AND: result = a & b;
        default: result = 0;
      endcase
    end
  end
endmodule
