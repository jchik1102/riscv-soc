module muldiv_unit (
  input logic clk, rst, kill,
  input logic start,
  input core_pkg::md_op_t op,
  input logic word,
  input logic [63:0] a, b,
  output logic busy, done,
  output logic [63:0] result
);
`ifdef RISCV_FORMAL_ALTOPS
  // riscv-formal's alternative operations: each RV64M operation becomes
  // (a + b) or (a - b) XOR a per-operation constant, answered one cycle after
  // start, so the riscv-formal checks can follow M instructions through the
  // pipeline within a short bound. The real multiplier and divider are
  // checked on their own (formal/muldiv_formal.sv). Normal builds never
  // define RISCV_FORMAL_ALTOPS.
  logic pending;
  logic [63:0] alt;
  function automatic logic [63:0] altops(input core_pkg::md_op_t op, input logic word, input logic [63:0] a, b);
    logic [63:0] r;
    case (op)
      core_pkg::MD_MUL: r = (a + b) ^ 64'h2cdf52a55876063e;
      core_pkg::MD_MULH: r = (a + b) ^ 64'h15d01651f6583fb7;
      core_pkg::MD_MULHSU: r = (a - b) ^ 64'hea3969edecfbe137;
      core_pkg::MD_MULHU: r = (a + b) ^ 64'hd13db50d949ce5e8;
      core_pkg::MD_DIV: r = (a - b) ^ 64'h29bbf66f7f8529ec;
      core_pkg::MD_DIVU: r = (a - b) ^ 64'h8c629acb10e8fd70;
      core_pkg::MD_REM: r = (a - b) ^ 64'hf5b7d8538da68fa5;
      default: r = (a - b) ^ 64'hbc4402413138d0e1;
    endcase
    return word ? {{32{r[31]}}, r[31:0]} : r;
  endfunction
  assign busy = pending;
  assign done = pending;
  assign result = alt;
  always_ff @(posedge clk) begin
    if (rst || kill) pending <= 0;
    else if (start && !pending) begin pending <= 1; alt <= altops(op, word, a, b); end
    else pending <= 0;
  end
`else
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
`endif
endmodule
