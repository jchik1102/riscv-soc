module bus_decoder #(
  parameter logic [63:0] RAM_BASE = platform_pkg::RAM_BASE,
  parameter logic [63:0] RAM_BYTES = platform_pkg::RAM_BYTES,
  parameter logic [63:0] MMIO_BASE = platform_pkg::PERIPHERALS_BASE,
  parameter logic [63:0] MMIO_BYTES = platform_pkg::PERIPHERALS_BYTES,
  parameter logic [63:0] SDRAM_BASE = platform_pkg::SDRAM_BASE,
  parameter logic [63:0] SDRAM_BYTES = 64'h0,
  parameter logic [63:0] ACCEL_BASE = platform_pkg::ACCELERATOR_BASE,
  parameter logic [63:0] ACCEL_BYTES = 64'h0
) (
  input logic clk, rst,
  input logic req_valid,
  output logic req_ready,
  input soc_pkg::bus_req_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output soc_pkg::bus_rsp_t rsp,
  output logic ram_req_valid,
  input logic ram_req_ready,
  output soc_pkg::bus_req_t ram_req,
  input logic ram_rsp_valid,
  output logic ram_rsp_ready,
  input soc_pkg::bus_rsp_t ram_rsp,
  output logic mmio_req_valid,
  input logic mmio_req_ready,
  output soc_pkg::bus_req_t mmio_req,
  input logic mmio_rsp_valid,
  output logic mmio_rsp_ready,
  input soc_pkg::bus_rsp_t mmio_rsp,
  output logic sdram_req_valid,
  input logic sdram_req_ready,
  output soc_pkg::bus_req_t sdram_req,
  input logic sdram_rsp_valid,
  output logic sdram_rsp_ready,
  input soc_pkg::bus_rsp_t sdram_rsp,
  output logic accel_req_valid,
  input logic accel_req_ready,
  output soc_pkg::bus_req_t accel_req,
  input logic accel_rsp_valid,
  output logic accel_rsp_ready,
  input soc_pkg::bus_rsp_t accel_rsp
);
  typedef enum logic [2:0] {T_RAM, T_MMIO, T_ERROR, T_SDRAM, T_ACCEL} target_t;
  target_t target, owner;
  logic busy, err_pending;
  always_comb begin
    if (req.addr >= RAM_BASE && req.addr - RAM_BASE < RAM_BYTES) target = T_RAM;
    else if (req.addr >= MMIO_BASE && req.addr - MMIO_BASE < MMIO_BYTES) target = T_MMIO;
    else if (SDRAM_BYTES != 0 && req.addr >= SDRAM_BASE && req.addr - SDRAM_BASE < SDRAM_BYTES) target = T_SDRAM;
    else if (ACCEL_BYTES != 0 && req.addr >= ACCEL_BASE && req.addr - ACCEL_BASE < ACCEL_BYTES) target = T_ACCEL;
    else target = T_ERROR;
    ram_req = req; mmio_req = req; sdram_req = req; accel_req = req;
    ram_req_valid = !busy && req_valid && target == T_RAM;
    mmio_req_valid = !busy && req_valid && target == T_MMIO;
    sdram_req_valid = !busy && req_valid && target == T_SDRAM;
    accel_req_valid = !busy && req_valid && target == T_ACCEL;
    case (target)
      T_RAM: req_ready = !busy && ram_req_ready;
      T_MMIO: req_ready = !busy && mmio_req_ready;
      T_SDRAM: req_ready = !busy && sdram_req_ready;
      T_ACCEL: req_ready = !busy && accel_req_ready;
      default: req_ready = !busy && !rst;
    endcase
    case (owner)
      T_RAM: begin rsp_valid = busy && ram_rsp_valid; rsp = ram_rsp; end
      T_MMIO: begin rsp_valid = busy && mmio_rsp_valid; rsp = mmio_rsp; end
      T_SDRAM: begin rsp_valid = busy && sdram_rsp_valid; rsp = sdram_rsp; end
      T_ACCEL: begin rsp_valid = busy && accel_rsp_valid; rsp = accel_rsp; end
      default: begin rsp_valid = busy && err_pending; rsp = '{rdata: 64'b0, error: 1'b1}; end
    endcase
    ram_rsp_ready = busy && owner == T_RAM && rsp_ready;
    mmio_rsp_ready = busy && owner == T_MMIO && rsp_ready;
    sdram_rsp_ready = busy && owner == T_SDRAM && rsp_ready;
    accel_rsp_ready = busy && owner == T_ACCEL && rsp_ready;
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 0; owner <= T_ERROR; err_pending <= 0;
    end else begin
      if (req_valid && req_ready) begin
        busy <= 1; owner <= target; err_pending <= target == T_ERROR;
      end else if (rsp_valid && rsp_ready) begin
        busy <= 0; err_pending <= 0;
      end
    end
  end
endmodule
