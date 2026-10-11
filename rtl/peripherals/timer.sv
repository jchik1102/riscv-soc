module timer (
  input logic clk, rst,
  input logic acc, wr,
  input logic [7:0] offset,
  input logic [63:0] wdata,
  input logic [7:0] mask,
  output logic [63:0] rdata,
  output logic ok,
  output logic msip, mtip
);
  logic [63:0] mtime, mtimecmp, lane;
  always_comb begin
    for (int i = 0; i < 8; i++) lane[8*i +: 8] = {8{mask[i]}};
    ok = 1; rdata = 0;
    case (offset)
      8'h00: rdata = {63'b0, msip};
      8'h08: rdata = mtimecmp;
      8'h10: rdata = mtime;
      default: ok = 0;
    endcase
  end
  assign mtip = mtime >= mtimecmp;
  always_ff @(posedge clk) begin
    if (rst) begin
      mtime <= 0; mtimecmp <= '1; msip <= 0;
    end else begin
      mtime <= mtime + 64'd1;
      if (acc && wr) case (offset)
        8'h00: if (mask[0]) msip <= wdata[0];
        8'h08: mtimecmp <= (mtimecmp & ~lane) | (wdata & lane);
        8'h10: mtime <= (mtime & ~lane) | (wdata & lane);
        default: begin end
      endcase
    end
  end
endmodule
