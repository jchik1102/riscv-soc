module sdram_tester #(
  parameter logic [63:0] BASE = platform_pkg::SDRAM_BASE,
  parameter logic [63:0] BYTES = platform_pkg::SDRAM_BYTES
) (
  input logic clk, rst,
  output logic req_valid,
  input logic req_ready,
  output soc_pkg::bus_req_t req,
  input logic rsp_valid,
  output logic rsp_ready,
  input soc_pkg::bus_rsp_t rsp,
  output logic [15:0] loops,
  output logic [31:0] errors,
  output logic [63:0] first_error,
  output logic [1:0] pass,
  output logic verifying,
  output logic [63:0] address,
  output logic [63:0] first_rdata,
  output logic [63:0] first_expected
);
  localparam logic [63:0] SEED = 64'h9e3779b97f4a7c15;
  logic [63:0] state;
  logic waiting;
  logic [63:0] beat;
  logic [63:0] random, pattern, wdata;
  logic [7:0] mask;
  logic [63:0] lanes, expected;

  function automatic logic [63:0] xorshift(input logic [63:0] x);
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    return x ^ (x << 17);
  endfunction
  always_comb begin
    random = xorshift(state);
    case (pass)
      2'd0: pattern = address;
      2'd1: pattern = ~address;
      default: pattern = random;
    endcase
    mask = pass == 2'd3 ? 8'(1 << beat[2:0]) | 8'(1 << beat[5:3]) : 8'hff;
    wdata = pass == 2'd3 ? {random[55:0], random[63:56]} ^ 64'ha5a5_5a5a_c3c3_3c3c : pattern;
    for (int lane = 0; lane < 8; lane++) lanes[lane*8 +: 8] = {8{mask[lane]}};
    expected = pass == 2'd3 ? (pattern & ~lanes) | (wdata & lanes) : pattern;
    req.addr = address;
    req.write = !verifying;
    req.mask = verifying ? 8'hff : mask;
    req.wdata = verifying ? 64'b0 : wdata;
  end
  assign req_valid = !rst && !waiting;
  assign rsp_ready = !rst && waiting;

  always_ff @(posedge clk) begin
    if (rst) begin
      waiting <= 0;
      beat <= 0;
      address <= BASE;
      pass <= 0;
      verifying <= 0;
      state <= SEED;
      loops <= 0;
      errors <= 0;
      first_error <= 0;
      first_rdata <= 0;
      first_expected <= 0;
    end else begin
      if (req_valid && req_ready) waiting <= 1;
      if (rsp_valid && rsp_ready) begin
        waiting <= 0;
        if (verifying && (rsp.error || rsp.rdata != expected)) begin
          if (errors == 0) begin
            first_error <= address;
            first_rdata <= rsp.rdata;
            first_expected <= expected;
          end
          if (errors != '1) errors <= errors + 32'd1;
        end
        if (pass >= 2'd2) state <= random;
        if (beat == BYTES / 8 - 1) begin
          beat <= 0;
          address <= BASE;
          state <= SEED;
          verifying <= !verifying;
          if (verifying) begin
            pass <= pass + 2'd1;
            if (pass == 2'd3) loops <= loops + 16'd1;
          end
        end else begin
          beat <= beat + 64'd1;
          address <= address + 64'd8;
        end
      end
    end
  end
endmodule
