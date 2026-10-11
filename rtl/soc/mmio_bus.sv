module mmio_bus #(
  parameter logic [63:0] BASE = platform_pkg::PERIPHERALS_BASE
) (
  input logic clk, rst,
  input logic req_valid,
  output logic req_ready,
  input soc_pkg::bus_req_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output soc_pkg::bus_rsp_t rsp,
  output logic [4:0] dev_sel,
  output logic dev_acc, dev_wr,
  output logic [7:0] dev_offset,
  output logic [63:0] dev_wdata,
  output logic [7:0] dev_mask,
  input logic [63:0] uart_rdata, timer_rdata, counter_rdata, cache_rdata, intc_rdata,
  input logic [4:0] dev_ok
);
  logic [63:0] offset, lane_mask, selected;
  logic hit;
  assign offset = req.addr - BASE;
  always_comb begin
    dev_sel = 0;
    if (offset[63:12] == 0) dev_sel = 5'b00001;
    else if (offset[63:12] == 1) dev_sel = 5'b00010;
    else if (offset[63:12] == 2) dev_sel = 5'b00100;
    else if (offset[63:12] == 3) dev_sel = 5'b01000;
    else if (offset[63:12] == 4) dev_sel = 5'b10000;
    if (offset[11:8] != 0 || req.addr[2:0] != 0) dev_sel = 0;
    hit = (dev_sel & dev_ok) != 0;
    for (int i = 0; i < 8; i++) lane_mask[8*i +: 8] = {8{req.mask[i]}};
    selected = dev_sel[0] ? uart_rdata : dev_sel[1] ? timer_rdata : dev_sel[2] ? counter_rdata :
               dev_sel[3] ? cache_rdata : intc_rdata;
  end
  assign req_ready = !rst && !rsp_valid;
  assign dev_acc = req_valid && req_ready && hit;
  assign dev_wr = req.write;
  assign dev_offset = offset[7:0];
  assign dev_wdata = req.wdata;
  assign dev_mask = req.mask;
  always_ff @(posedge clk) begin
    if (rst) begin
      rsp_valid <= 0; rsp <= '0;
    end else begin
      if (rsp_valid && rsp_ready) rsp_valid <= 0;
      if (req_valid && req_ready) begin
        rsp_valid <= 1;
        rsp.error <= !hit;
        rsp.rdata <= hit && !req.write ? selected & lane_mask : 64'b0;
      end
    end
  end
endmodule
