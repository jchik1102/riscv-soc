module regfile (
  input logic clk, rst,
  input logic [4:0] rs1, rs2,
  output logic [63:0] rdata1, rdata2,
  input logic we,
  input logic [4:0] rd,
  input logic [63:0] wdata
);
  logic [63:0] regs [1:31];
  assign rdata1 = rs1 == 0 ? 64'b0 : regs[rs1];
  assign rdata2 = rs2 == 0 ? 64'b0 : regs[rs2];
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 1; i < 32; i++) regs[i] <= 0;
    end else if (we && rd != 0) regs[rd] <= wdata;
  end
endmodule
