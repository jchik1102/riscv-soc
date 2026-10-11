module muldiv_unit (
  input logic clk, rst, kill,
  input logic start,
  input core_pkg::md_op_t op,
  input logic word,
  input logic [63:0] a, b,
  output logic busy, done,
  output logic [63:0] result
);
  logic mul_busy, mul_done, div_busy, div_done, accept, selected_div;
  logic [63:0] mul_result, div_result;

  assign busy = mul_busy || div_busy;
  assign accept = start && !busy;
  assign done = mul_done || div_done;
  assign result = selected_div ? div_result : mul_result;

  mul_iter multiplier(.clk(clk), .rst(rst), .kill(kill), .start(accept && !op[2]),
    .op(op), .word(word), .a(a), .b(b), .busy(mul_busy), .done(mul_done), .result(mul_result));
  div_iter divider(.clk(clk), .rst(rst), .kill(kill), .start(accept && op[2]),
    .op(op), .word(word), .a(a), .b(b), .busy(div_busy), .done(div_done), .result(div_result));

  always_ff @(posedge clk) begin
    if (rst) selected_div <= 0;
    else if (accept && !kill) selected_div <= op[2];
  end
endmodule
