module irq_ctrl #(
  parameter int SOURCES = 2
) (
  input logic clk, rst,
  input logic acc, wr,
  input logic [7:0] offset,
  input logic [63:0] wdata,
  input logic [7:0] mask,
  output logic [63:0] rdata,
  output logic ok,
  input logic [SOURCES-1:0] sources,
  output logic meip
);
  logic [SOURCES-1:0] enable;
  always_comb begin
    ok = 1;
    case (offset)
      8'h00: rdata = 64'(sources);
      8'h08: rdata = 64'(enable);
      8'h10: rdata = 64'(sources & enable);
      default: begin ok = 0; rdata = 0; end
    endcase
  end
  assign meip = |(sources & enable);
  always_ff @(posedge clk) begin
    if (rst) enable <= '1;
    else if (acc && wr && offset == 8'h08 && mask[0]) enable <= wdata[SOURCES-1:0];
  end
endmodule
