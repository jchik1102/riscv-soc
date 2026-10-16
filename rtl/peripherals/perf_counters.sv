module perf_counters (
  input logic clk, rst,
  input logic acc, wr,
  input logic [7:0] offset,
  input logic [63:0] wdata,
  input logic [7:0] mask,
  output logic [63:0] rdata,
  output logic ok,
  input logic ev_retired, ev_mem_wait, ev_arith_wait, ev_fetch_wait, ev_load_use, ev_redirect,
  input logic ev_i_access, ev_i_miss, ev_i_uncached, ev_d_access, ev_d_miss, ev_d_uncached, ev_d_write,
  input logic ev_branch, ev_mispredict
);
  localparam int N = 16;
  logic enable;
  logic [63:0] count [1:N];
  logic [N-1:0] event_bits;
  logic [63:0] lane;
  assign event_bits = {ev_mispredict, ev_branch, ev_d_write, ev_d_uncached, ev_d_miss, ev_d_access, ev_i_uncached, ev_i_miss, ev_i_access,
                       ev_redirect, ev_load_use, ev_fetch_wait, ev_arith_wait, ev_mem_wait, ev_retired, 1'b1};
  always_comb begin
    for (int i = 0; i < 8; i++) lane[8*i +: 8] = {8{mask[i]}};
    ok = offset[2:0] == 0 && offset < 8'h88;
    rdata = offset == 8'h00 ? {63'b0, enable} : (ok ? count[offset[7:3]] : 64'b0);
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      enable <= 1;
      for (int i = 1; i <= N; i++) count[i] <= 0;
    end else begin
      for (int i = 1; i <= N; i++) begin
        if (acc && wr && offset[7:3] == 5'(i) && ok)
          count[i] <= (count[i] & ~lane) | (wdata & lane);
        else if (enable && event_bits[i-1]) count[i] <= count[i] + 64'd1;
      end
      if (acc && wr && offset == 8'h00 && mask[0]) enable <= wdata[0];
    end
  end
endmodule
