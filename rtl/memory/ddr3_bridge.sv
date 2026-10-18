// Bridge from the SoC's SDRAM-region bus (soc_pkg::bus2_req_t, the bus the
// caches refill on) to the native user interface of a Xilinx 7-series MIG
// DDR3 controller, so DDR3 can stand in for the DE10-Lite's SDR SDRAM. The
// requests and responses are the ones rtl/memory/sdram_ctrl.sv takes and
// gives: one 64-bit beat, read or write with byte mask, or an aligned 2- or
// 4-beat read burst; out-of-region, unaligned or illegal bursts answer with
// one error beat. One request is in flight at a time.
//
// The SoC side runs on clk; the MIG side on the MIG's ui_clk. Requests cross
// in one async FIFO and read data back in another (rtl/memory/async_fifo.sv).
// MIG's native port is 128 bits wide for a 16-bit DDR3 at 4:1, one BL8 burst
// per command: a single beat reads or writes half of one burst, a 2-beat burst
// is one whole read, a 4-beat line two reads. app_addr counts 16-bit words.
//
// bus_rst resets the SoC side's view of the bus without the controller (the
// CPU's reset): a request already in flight completes on the DDR3 side and its
// responses are dropped. Both sides' rst and ui_rst must be asserted together
// at power-up, as the async FIFOs require.
module ddr3_bridge #(
  parameter logic [63:0] BASE = platform_pkg::SDRAM_BASE,
  parameter logic [63:0] BYTES = platform_pkg::SDRAM_BYTES,
  parameter int APP_ADDR_WIDTH = 28
) (
  input  logic clk, rst, bus_rst,
  input  logic req_valid,
  output logic req_ready,
  input  soc_pkg::bus2_req_t req,
  output logic rsp_valid,
  input  logic rsp_ready,
  output soc_pkg::bus2_rsp_t rsp,
  output logic init_done,
  // MIG native interface, ui_clk domain
  input  logic ui_clk, ui_rst, calib_done,
  output logic [APP_ADDR_WIDTH-1:0] app_addr,
  output logic [2:0] app_cmd,
  output logic app_en,
  input  logic app_rdy,
  output logic [127:0] app_wdf_data,
  output logic app_wdf_end,
  output logic [15:0] app_wdf_mask,
  output logic app_wdf_wren,
  input  logic app_wdf_rdy,
  input  logic [127:0] app_rd_data,
  input  logic app_rd_data_valid
);
  import soc_pkg::*;
  localparam int OFFSET_BITS = $clog2(BYTES);
  localparam logic [2:0] CMD_WRITE = 3'b000, CMD_READ = 3'b001;
  // synthesis translate_off
  initial if (BYTES != (64'd1 << OFFSET_BITS) || BASE[OFFSET_BITS-1:0] != 0 || OFFSET_BITS - 1 > APP_ADDR_WIDTH)
    $fatal(1, "ddr3_bridge: BYTES must be a power of two, BASE aligned to it, and the region must fit app_addr");
  // synthesis translate_on

  // A request across the clock domains, and a burst of read data back.
  typedef struct packed {
    logic write;
    logic [OFFSET_BITS-1:0] offset;
    logic [63:0] wdata;
    logic [7:0] mask;
    logic [1:0] burst;
  } cmd_t;
  typedef struct packed {
    logic last;          // the request's final entry
    logic two;           // both halves, low then high; otherwise one half
    logic high;          // the half, when only one
    logic [127:0] data;
  } rd_t;

  // ------------------------------------------------------------ SoC side
  cmd_t cmd_in;
  rd_t rd_out;
  logic cmd_valid, cmd_ready, rd_valid, rd_ready;
  logic pending, drop, err_valid, half_done;
  logic [7:0] op_mask;                 // the request's byte lanes; a single-beat read returns only those
  logic [63:0] lanes;
  (* ASYNC_REG = "TRUE" *) logic calib_meta, calib_q;
  logic valid_address, legal_burst, accept;
  assign valid_address = req.addr[63:OFFSET_BITS] == BASE[63:OFFSET_BITS] && req.addr[2:0] == 0;
  assign legal_burst = req.burst == 0 || (!req.write && req.mask == 8'hff && req.burst != 2'd2 &&
                                        (req.addr[4:3] & req.burst) == 2'b00);
  assign init_done = calib_q;
  assign req_ready = !rst && !bus_rst && init_done && !pending && !err_valid && cmd_ready;
  assign accept = req_valid && req_ready;
  assign cmd_in = '{write: req.write, offset: req.addr[OFFSET_BITS-1:0], wdata: req.wdata, mask: req.mask, burst: req.burst};
  assign cmd_valid = accept && valid_address && legal_burst;

  // Each read entry gives one or two beats; half_done marks the low half sent.
  // As from sdram_ctrl, a single-beat read has zeros in the lanes it did not ask for.
  always_comb for (int b = 0; b < 8; b++) lanes[8*b +: 8] = {8{op_mask[b]}};
  always_comb begin
    rsp = '0;
    rsp_valid = 0;
    rd_ready = 0;
    if (err_valid) begin
      rsp_valid = 1;
      rsp.error = 1;
      rsp.last = 1;
    end else if (rd_valid) begin
      rsp_valid = !drop;
      rsp.rdata = rd_out.two ? (half_done ? rd_out.data[127:64] : rd_out.data[63:0])
                             : (rd_out.high ? rd_out.data[127:64] : rd_out.data[63:0]) & lanes;
      rsp.last = rd_out.last && (!rd_out.two || half_done);
      rd_ready = (drop || rsp_ready) && (!rd_out.two || half_done);
    end
  end

  always_ff @(posedge clk) begin
    calib_meta <= calib_done;
    calib_q <= calib_meta;
    if (rst) begin
      pending <= 0; drop <= 0; err_valid <= 0; half_done <= 0; op_mask <= '0;
      calib_meta <= 0; calib_q <= 0;
    end else begin
      if (err_valid && rsp_ready) err_valid <= 0;
      if (accept && !(valid_address && legal_burst)) err_valid <= 1;
      if (accept && valid_address && legal_burst) begin pending <= 1; drop <= 0; op_mask <= req.mask; end
      if (rd_valid && rd_out.two && !half_done && (drop || rsp_ready)) half_done <= 1;
      if (rd_valid && rd_ready) begin
        half_done <= 0;
        if (rd_out.last) begin pending <= 0; drop <= 0; end
      end
      if (bus_rst) begin
        err_valid <= 0;
        if (pending) drop <= 1;
      end
    end
  end

  // ----------------------------------------------------------- clock crossing
  cmd_t cmd_out;
  rd_t rd_in;
  logic cmd_out_valid, cmd_out_ready, rd_in_valid, rd_in_ready;
  async_fifo #(.WIDTH($bits(cmd_t)), .ADDR(2)) cmd_fifo(
    .s_clk(clk), .s_rst(rst), .s_data(cmd_in), .s_valid(cmd_valid), .s_ready(cmd_ready),
    .m_clk(ui_clk), .m_rst(ui_rst), .m_data(cmd_out), .m_valid(cmd_out_valid), .m_ready(cmd_out_ready));
  async_fifo #(.WIDTH($bits(rd_t)), .ADDR(2)) rd_fifo(
    .s_clk(ui_clk), .s_rst(ui_rst), .s_data(rd_in), .s_valid(rd_in_valid), .s_ready(rd_in_ready),
    .m_clk(clk), .m_rst(rst), .m_data(rd_out), .m_valid(rd_valid), .m_ready(rd_ready));

  // -------------------------------------------------------------- MIG side
  typedef enum logic [1:0] {M_IDLE, M_WRITE, M_READ} mstate_t;
  mstate_t mstate;
  cmd_t op;
  logic cmd_sent, data_sent, write_ack;
  logic [1:0] cmds_left, beats_left;   // read commands still to issue, read bursts still to come
  logic [APP_ADDR_WIDTH-1:0] next_addr;

  // The 16-byte burst holding the request: app_addr in 16-bit words, low 3 bits zero.
  function automatic logic [APP_ADDR_WIDTH-1:0] burst_addr(input logic [OFFSET_BITS-1:0] offset);
    return APP_ADDR_WIDTH'({offset[OFFSET_BITS-1:4], 3'b000});
  endfunction

  assign cmd_out_ready = mstate == M_IDLE && !write_ack;
  always_comb begin
    app_en = 0;
    app_cmd = CMD_READ;
    app_addr = next_addr;
    app_wdf_wren = 0;
    app_wdf_end = 0;
    app_wdf_data = {op.wdata, op.wdata};
    // app_wdf_mask: 1 = byte not written. The write lands in one half of the burst.
    app_wdf_mask = op.offset[3] ? {~op.mask, 8'hff} : {8'hff, ~op.mask};
    if (mstate == M_WRITE) begin
      app_en = !cmd_sent;
      app_cmd = CMD_WRITE;
      app_wdf_wren = !data_sent;
      app_wdf_end = !data_sent;
    end else if (mstate == M_READ) begin
      app_en = cmds_left != 0;
    end
    rd_in = '{last: 1'b1, two: 1'b0, high: 1'b0, data: 128'b0};
    rd_in_valid = 0;
    if (write_ack) rd_in_valid = 1;                       // the write's response
    else if (mstate == M_READ && app_rd_data_valid) begin
      rd_in.data = app_rd_data;
      rd_in.two = op.burst != 0;
      rd_in.high = op.offset[3];
      rd_in.last = beats_left == 1;
      rd_in_valid = 1;
    end
  end

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      mstate <= M_IDLE; op <= '0; cmd_sent <= 0; data_sent <= 0; write_ack <= 0;
      cmds_left <= 0; beats_left <= 0; next_addr <= '0;
    end else begin
      if (write_ack && rd_in_ready) write_ack <= 0;
      case (mstate)
        M_IDLE: if (cmd_out_valid && cmd_out_ready) begin
          op <= cmd_out;
          next_addr <= burst_addr(cmd_out.offset);
          cmd_sent <= 0; data_sent <= 0;
          if (cmd_out.write) mstate <= M_WRITE;
          else begin
            cmds_left <= cmd_out.burst == 2'd3 ? 2'd2 : 2'd1;
            beats_left <= cmd_out.burst == 2'd3 ? 2'd2 : 2'd1;
            mstate <= M_READ;
          end
        end
        M_WRITE: begin
          if (app_en && app_rdy) cmd_sent <= 1;
          if (app_wdf_wren && app_wdf_rdy) data_sent <= 1;
          if ((cmd_sent || app_rdy) && (data_sent || app_wdf_rdy)) begin
            mstate <= M_IDLE;
            write_ack <= 1;
          end
        end
        M_READ: begin
          if (app_en && app_rdy) begin
            cmds_left <= cmds_left - 1'b1;
            next_addr <= next_addr + APP_ADDR_WIDTH'(8);
          end
          // MIG has no back-pressure on read data; rd_fifo has room, since only
          // this request's (at most two) entries can be in it.
          if (app_rd_data_valid) begin
            beats_left <= beats_left - 1'b1;
            if (beats_left == 1) mstate <= M_IDLE;
          end
        end
        default: mstate <= M_IDLE;
      endcase
    end
  end
endmodule
