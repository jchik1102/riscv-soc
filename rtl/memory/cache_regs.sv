module cache_regs #(
  parameter bit PRESENT = 1,
  parameter int ICACHE_BYTES = 2048,
  parameter int DCACHE_BYTES = 2048
) (
  input logic clk, rst,
  input logic acc, wr,
  input logic [7:0] offset,
  input logic [63:0] wdata,
  input logic [7:0] mask,
  output logic [63:0] rdata,
  output logic ok,
  input logic [1:0] enable_init,
  output logic icache_enable, dcache_enable
);
  logic [63:0] info;
  assign info = PRESENT ? {23'b0, 1'b1, 8'd32, 16'(DCACHE_BYTES), 16'(ICACHE_BYTES)} : 64'b0;
  assign ok = offset == 8'h00 || offset == 8'h08;
  assign rdata = offset == 8'h00 ? {62'b0, dcache_enable, icache_enable} : (offset == 8'h08 ? info : 64'b0);
  always_ff @(posedge clk) begin
    if (rst) begin
      icache_enable <= PRESENT && enable_init[0];
      dcache_enable <= PRESENT && enable_init[1];
    end else if (acc && wr && offset == 8'h00 && mask[0] && PRESENT) begin
      icache_enable <= wdata[0];
      dcache_enable <= wdata[1];
    end
  end
endmodule
