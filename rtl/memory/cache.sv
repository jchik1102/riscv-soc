module cache #(
  parameter logic [63:0] BASE = platform_pkg::SDRAM_BASE,
  parameter logic [63:0] SPAN = platform_pkg::SDRAM_BYTES,
  parameter int BYTES = 2048,
  parameter bit WRITES = 1
) (
  input logic clk, rst,
  input logic enable,
  input logic invalidate,
  input logic req_valid,
  output logic req_ready,
  input soc_pkg::bus_req_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output soc_pkg::bus_rsp_t rsp,
  output logic mreq_valid,
  input logic mreq_ready,
  output soc_pkg::bus2_req_t mreq,
  input logic mrsp_valid,
  output logic mrsp_ready,
  input soc_pkg::bus2_rsp_t mrsp,
  output logic ev_access, ev_miss, ev_bypass, ev_write
);
  import soc_pkg::*;
  localparam int LINE_BYTES = 32;
  localparam int LINES = BYTES / LINE_BYTES;
  localparam int INDEX_BITS = $clog2(LINES);
  localparam int WORDS = BYTES / 8;
  localparam int WORD_BITS = $clog2(WORDS);
  localparam int SPAN_BITS = $clog2(SPAN);
  localparam int TAG_BITS = SPAN_BITS - $clog2(BYTES);

  // synthesis translate_off
  initial begin
    if (BYTES != 2048 && BYTES != 4096) $fatal(1, "cache: only 2 KiB and 4 KiB are qualified");
    if (SPAN != (64'd1 << SPAN_BITS) || BASE[SPAN_BITS-1:0] != 0) $fatal(1, "cache: region must be an aligned power of two");
  end
  // synthesis translate_on

  typedef enum logic [2:0] {S_IDLE, S_HIT, S_FILL_REQ, S_FILL, S_RSP, S_PASS} state_t;
  state_t state;

  logic [63:0] offset;
  logic cacheable, hit, bypass, held_bypass, accept, start_ok;
  logic [INDEX_BITS-1:0] index;
  logic [1:0] beat;
  logic [TAG_BITS-1:0] tag;
  logic [LINES-1:0] valid;
  logic [TAG_BITS-1:0] tags [0:LINES-1];
  assign offset = {{(64 - SPAN_BITS){1'b0}}, req.addr[SPAN_BITS-1:0]};
  assign cacheable = req.addr[63:SPAN_BITS] == BASE[63:SPAN_BITS];
  assign index = offset[5 +: INDEX_BITS];
  assign beat = offset[4:3];
  assign tag = offset[SPAN_BITS-1 -: TAG_BITS];
  assign hit = cacheable && valid[index] && tags[index] == tag;
  assign bypass = held_bypass || req.write || !enable || !cacheable;
  assign start_ok = !rst && state == S_IDLE;

  logic [INDEX_BITS-1:0] op_index;
  logic [1:0] op_beat, fill_beat;
  logic [TAG_BITS-1:0] op_tag;
  logic [63:0] op_addr, op_wdata, rsp_data;
  logic [7:0] op_mask;
  logic op_write, op_hit, kill, rsp_error;
  logic [63:0] op_lanes;
  always_comb for (int lane = 0; lane < 8; lane++) op_lanes[8*lane +: 8] = {8{op_mask[lane]}};

  logic [WORD_BITS-1:0] ram_addr;
  logic ram_we;
  logic [7:0] ram_mask;
  logic [63:0] ram_wdata, ram_q;

  always_comb begin
    req_ready = start_ok && (bypass ? mreq_ready : 1'b1);
    accept = req_valid && req_ready;
    rsp_valid = 0;
    rsp.rdata = rsp_data;
    rsp.error = rsp_error;
    case (state)
      S_HIT: begin rsp_valid = 1; rsp.rdata = ram_q & op_lanes; rsp.error = 0; end
      S_RSP: rsp_valid = 1;
      S_PASS: begin rsp_valid = mrsp_valid; rsp.rdata = mrsp.rdata; rsp.error = mrsp.error; end
      default: ;
    endcase
    mreq = to_bus2(req);
    mreq_valid = start_ok && req_valid && bypass;
    if (state == S_FILL_REQ) begin
      mreq = '0;
      mreq.addr = {op_addr[63:5], 5'b0};
      mreq.mask = 8'hff;
      mreq.burst = 2'd3;
      mreq_valid = !rst;
    end
    mrsp_ready = !rst && (state == S_FILL || (state == S_PASS && rsp_ready));
    ram_addr = {op_index, op_beat};
    ram_we = 0;
    ram_mask = 8'hff;
    ram_wdata = mrsp.rdata;
    case (state)
      S_IDLE: ram_addr = {index, beat};
      S_FILL: begin ram_addr = {op_index, fill_beat}; ram_we = mrsp_valid && !mrsp.error; end
      S_PASS: begin
        ram_we = WRITES && op_write && op_hit && !kill && enable && !invalidate &&
                 mrsp_valid && rsp_ready && !mrsp.error;
        ram_mask = op_mask;
        ram_wdata = op_wdata;
      end
      default: ;
    endcase
    if (rst) ram_we = 0;
    ev_access = accept && enable && cacheable && (req.write || !bypass);
    ev_write = accept && req.write;
    ev_bypass = accept && bypass && !req.write;
    ev_miss = state == S_FILL_REQ && mreq_valid && mreq_ready;
  end

  genvar lane;
  generate for (lane = 0; lane < 8; lane = lane + 1) begin : lanes
    logic [7:0] data [0:WORDS-1];
    always_ff @(posedge clk) begin
      if (ram_we && ram_mask[lane]) data[ram_addr] <= ram_wdata[lane*8 +: 8];
      ram_q[lane*8 +: 8] <= data[ram_addr];
    end
  end endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE;
      valid <= '0;
      held_bypass <= 0;
      kill <= 0;
      op_index <= 0; op_beat <= 0; op_tag <= 0; op_addr <= 0; op_wdata <= 0; op_mask <= 0;
      op_write <= 0; op_hit <= 0; fill_beat <= 0; rsp_data <= 0; rsp_error <= 0;
    end else begin
      held_bypass <= state == S_IDLE && req_valid && !req_ready && bypass;
      if (invalidate || !enable) kill <= 1;
      case (state)
        S_IDLE: if (accept) begin
          op_index <= index; op_beat <= beat; op_tag <= tag; op_addr <= req.addr;
          op_wdata <= req.wdata; op_mask <= req.mask; op_write <= req.write;
          op_hit <= hit;
          kill <= 0;
          rsp_error <= 0;
          if (bypass) state <= S_PASS;
          else if (hit) state <= S_HIT;
          else state <= S_FILL_REQ;
        end
        S_HIT: if (rsp_ready) state <= S_IDLE;
        S_FILL_REQ: begin
          valid[op_index] <= 0;
          if (mreq_ready) begin
            state <= S_FILL;
            fill_beat <= 0;
          end
        end
        S_FILL: if (mrsp_valid) begin
          fill_beat <= fill_beat + 2'd1;
          if (fill_beat == op_beat) rsp_data <= mrsp.rdata & op_lanes;
          if (mrsp.error) begin rsp_error <= 1; rsp_data <= 0; end
          if (mrsp.last || mrsp.error) begin
            state <= S_RSP;
            if (!mrsp.error && !rsp_error && fill_beat == 2'd3 && !kill && enable && !invalidate) begin
              valid[op_index] <= 1;
              tags[op_index] <= op_tag;
            end
          end
        end
        S_RSP: if (rsp_ready) state <= S_IDLE;
        S_PASS: if (mrsp_valid && rsp_ready) state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
      if (invalidate || !enable) valid <= '0;
    end
  end
endmodule
