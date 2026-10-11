module onchip_ram #(
  parameter logic [63:0] BASE = platform_pkg::RAM_BASE,
  parameter int BYTES = int'(platform_pkg::RAM_BYTES)
) (
  input logic clk, rst,
  input logic req_valid,
  output logic req_ready,
  input soc_pkg::bus_req_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output soc_pkg::bus_rsp_t rsp,
  input logic loader_we,
  input logic [$clog2(BYTES/8)-1:0] loader_word,
  input logic [63:0] loader_data
);
  localparam int WORD_BITS = $clog2(BYTES/8);
  logic [63:0] read_data;
  logic [7:0] read_mask;
  logic accepted, valid_address;
  logic [WORD_BITS-1:0] word_address, port_address, held_word;
  logic write_enable;
  logic [63:0] write_data;
  logic [7:0] write_mask;
  assign accepted = req_valid && req_ready;
  assign valid_address = req.addr >= BASE && req.addr <= BASE + BYTES - 8 && req.addr[2:0] == 0;
  assign word_address = WORD_BITS'((req.addr - BASE) >> 3);
  assign port_address = rst ? loader_word : (rsp_valid ? held_word : word_address);
  assign write_enable = rst ? loader_we : accepted && valid_address && req.write;
  assign write_data = rst ? loader_data : req.wdata;
  assign write_mask = rst ? 8'hff : req.mask;
  assign req_ready = !rst && !rsp_valid;
  genvar lane;
  generate for (lane = 0; lane < 8; lane = lane + 1) begin : lanes
    logic [7:0] data [0:BYTES/8-1];
    always_ff @(posedge clk) begin
      if (write_enable && write_mask[lane])
        data[port_address] <= write_data[lane*8 +: 8];
      read_data[lane*8 +: 8] <= data[port_address];
    end
    assign rsp.rdata[lane*8 +: 8] = read_mask[lane] ? read_data[lane*8 +: 8] : 8'b0;
  end endgenerate
  always_ff @(posedge clk) begin
    if (rst) begin
      rsp_valid <= 0;
      rsp.error <= 0;
      read_mask <= 0;
      held_word <= 0;
    end else begin
      if (rsp_valid && rsp_ready) rsp_valid <= 0;
      if (accepted) begin
        held_word <= word_address;
        rsp_valid <= 1;
        rsp.error <= !valid_address;
        read_mask <= valid_address && !req.write ? req.mask : 8'b0;
      end
    end
  end
endmodule
