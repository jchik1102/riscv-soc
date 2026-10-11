module sdram_ctrl #(
  parameter logic [63:0] BASE = platform_pkg::SDRAM_BASE,
  parameter logic [63:0] BYTES = platform_pkg::SDRAM_BYTES,
  parameter int CLK_PERIOD_PS = 20000,
  parameter int T_POWERUP_PS = 200_000_000,
  parameter int T_RP_PS = 18000,
  parameter int T_RCD_PS = 18000,
  parameter int T_RC_PS = 60000,
  parameter int T_RAS_PS = 42000,
  parameter int T_MRD_PS = 14000,
  parameter int T_DPL_PS = 14000,
  parameter int T_DAL_PS = 30000,
  parameter int T_REFI_PS = 7_000_000,
  parameter int INIT_REFRESHES = 8,
  parameter int CAS_LATENCY = 2,
  parameter int READ_LATENCY = CAS_LATENCY + 1
) (
  input logic clk, rst, bus_rst,
  input logic req_valid,
  output logic req_ready,
  input soc_pkg::bus2_req_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output soc_pkg::bus2_rsp_t rsp,
  output logic init_done,
  output logic sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n,
  output logic [1:0] sdram_ba,
  output logic [12:0] sdram_a,
  output logic [1:0] sdram_dqm,
  output logic [15:0] sdram_dq_o,
  output logic sdram_dq_oe,
  input logic [15:0] sdram_dq_i,
  input logic [1:0] extra_wait,
  input logic extra_capture
);
  function automatic int cycles(input int ps, input int minimum);
    int count;
    count = (ps + CLK_PERIOD_PS - 1) / CLK_PERIOD_PS;
    return count < minimum ? minimum : count;
  endfunction
  localparam int C_POWERUP = cycles(T_POWERUP_PS, 1);
  localparam int C_RP = cycles(T_RP_PS, 1);
  localparam int C_RCD = cycles(T_RCD_PS, 1);
  localparam int C_RC = cycles(T_RC_PS, 1);
  localparam int C_RAS = cycles(T_RAS_PS, 1);
  localparam int C_MRD = cycles(T_MRD_PS, 2);
  localparam int C_DPL = cycles(T_DPL_PS, 2);
  localparam int C_DAL = cycles(T_DAL_PS, 1) > C_DPL + C_RP ? cycles(T_DAL_PS, 1) : C_DPL + C_RP;
  localparam int C_REFI = T_REFI_PS / CLK_PERIOD_PS;
  localparam int BURST = 4;
  localparam int C_RD_RECOVER = C_RP > READ_LATENCY + 1 ? C_RP - READ_LATENCY - 1 : 0;
  localparam logic [12:0] MODE = {3'b000, 1'b0, 2'b00, 3'(CAS_LATENCY), 1'b0, 3'b010};
  localparam logic [3:0] CMD_INHIBIT = 4'b1111, CMD_NOP = 4'b0111, CMD_ACTIVE = 4'b0011,
                         CMD_READ = 4'b0101, CMD_WRITE = 4'b0100, CMD_PRECHARGE = 4'b0010,
                         CMD_REFRESH = 4'b0001, CMD_MODE = 4'b0000;

  // synthesis translate_off
  initial begin
    if (BYTES != 64'h4000000) $fatal(1, "sdram_ctrl: geometry is fixed at 64 MiB");
    if (BASE[25:0] != 0) $fatal(1, "sdram_ctrl: BASE must be aligned to the region size");
    if (C_POWERUP >= 65536 || C_REFI >= 65536 || C_REFI < 64) $fatal(1, "sdram_ctrl: counter range");
    if (CAS_LATENCY < 2 || CAS_LATENCY > 3 || READ_LATENCY < CAS_LATENCY + 1 || READ_LATENCY > 11)
      $fatal(1, "sdram_ctrl: unsupported latency");
    if (C_RCD + BURST < C_RAS) $fatal(1, "sdram_ctrl: tRAS not met by the access sequence");
    if (C_RCD + BURST - 1 + C_DAL < C_RC || C_RCD + READ_LATENCY + BURST + 1 < C_RC)
      $fatal(1, "sdram_ctrl: tRC not met by the access sequence");
  end
  // synthesis translate_on

  typedef enum logic [2:0] {S_POWERUP, S_INIT_REF, S_INIT_MODE, S_IDLE, S_COLUMN, S_WRITE, S_READ} state_t;
  state_t state;
  logic [15:0] wait_count;
  logic [15:0] refresh_count;
  logic refresh_due;
  logic [3:0] init_refreshes;
  logic [5:0] read_count;
  logic [1:0] reads_more;
  logic [1:0] beat;
  logic [1:0] word;
  logic [15:0] dq_q;
  logic [63:0] read_data;
  logic [3:0] cmd;
  logic pending, drop;
  logic op_write;
  logic [7:0] op_mask;
  logic [63:0] op_wdata;
  logic [25:0] op_offset;
  logic [1:0] op_len;
  logic accept, valid_address, legal_burst;
  logic [5:0] word_index;
  logic [63:0] offset;
  logic [63:0] lane_mask;
  logic [3:0] capture;
  assign capture = 4'(READ_LATENCY) + 4'(extra_capture);

  assign {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} = cmd;
  assign offset = {38'b0, req.addr[25:0]};
  assign valid_address = req.addr[63:26] == BASE[63:26] && req.addr[2:0] == 0;
  assign legal_burst = req.burst == 0 || (!req.write && req.mask == 8'hff && req.burst != 2'd2 &&
                                        (req.addr[4:3] & req.burst) == 2'b00);
  assign word_index = read_count - 6'(capture);
  assign req_ready = !rst && !bus_rst && init_done && !pending && !rsp_valid;
  assign accept = req_valid && req_ready;
  always_comb for (int lane = 0; lane < 8; lane++) lane_mask[lane*8 +: 8] = {8{op_mask[lane]}};

  always_ff @(posedge clk) dq_q <= sdram_dq_i;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_POWERUP;
      wait_count <= 16'(C_POWERUP - 1);
      cmd <= CMD_INHIBIT;
      sdram_cke <= 1;
      sdram_dqm <= 2'b11;
      sdram_dq_oe <= 0;
      sdram_ba <= 0;
      sdram_a <= 0;
      init_done <= 0;
      refresh_count <= 0;
      refresh_due <= 0;
      init_refreshes <= 0;
      pending <= 0;
      drop <= 0;
      op_len <= 0;
      rsp_valid <= 0;
      rsp <= '0;
    end else begin
      cmd <= CMD_NOP;
      sdram_dq_oe <= 0;
      sdram_dqm <= init_done ? 2'b00 : 2'b11;
      if (init_done) begin
        if (refresh_count == 0) begin
          refresh_count <= 16'(C_REFI - 1);
          refresh_due <= 1;
        end else refresh_count <= refresh_count - 16'd1;
      end
      if (rsp_valid && rsp_ready) rsp_valid <= 0;
      if (!pending) begin
        op_write <= req.write;
        op_mask <= req.mask;
        op_wdata <= req.wdata;
        op_offset <= offset[25:0];
        op_len <= req.burst;
      end
      if (accept) begin
        if (valid_address && legal_burst) begin
          pending <= 1;
          drop <= 0;
        end else begin
          rsp_valid <= 1;
          rsp <= '{rdata: 64'b0, error: 1'b1, last: 1'b1};
        end
      end
      if (bus_rst) begin
        rsp_valid <= 0;
        if (pending) drop <= 1;
      end
      if (wait_count != 0) wait_count <= wait_count - 16'd1;
      else case (state)
        S_POWERUP: begin
          cmd <= CMD_PRECHARGE;
          sdram_a <= 13'b0_0100_0000_0000;
          wait_count <= 16'(C_RP - 1) + 16'(extra_wait);
          init_refreshes <= 4'(INIT_REFRESHES);
          state <= S_INIT_REF;
        end
        S_INIT_REF: begin
          cmd <= CMD_REFRESH;
          wait_count <= 16'(C_RC - 1) + 16'(extra_wait);
          init_refreshes <= init_refreshes - 4'd1;
          if (init_refreshes == 1) state <= S_INIT_MODE;
        end
        S_INIT_MODE: begin
          cmd <= CMD_MODE;
          sdram_ba <= 0;
          sdram_a <= MODE;
          wait_count <= 16'(C_MRD - 1) + 16'(extra_wait);
          init_done <= 1;
          refresh_count <= 16'(C_REFI - 1);
          state <= S_IDLE;
        end
        S_IDLE: begin
          if (refresh_due) begin
            cmd <= CMD_REFRESH;
            refresh_due <= 0;
            wait_count <= 16'(C_RC - 1) + 16'(extra_wait);
          end else if (pending) begin
            cmd <= CMD_ACTIVE;
            sdram_ba <= op_offset[12:11];
            sdram_a <= op_offset[25:13];
            wait_count <= 16'(C_RCD - 1) + 16'(extra_wait);
            state <= S_COLUMN;
          end
        end
        S_COLUMN: begin
          sdram_ba <= op_offset[12:11];
          if (op_write) begin
            cmd <= CMD_WRITE;
            sdram_a <= {2'b00, 1'b1, op_offset[10:1]};
            sdram_dq_o <= op_wdata[15:0];
            sdram_dqm <= ~op_mask[1:0];
            sdram_dq_oe <= 1;
            word <= 1;
            state <= S_WRITE;
          end else begin
            cmd <= CMD_READ;
            sdram_a <= {2'b00, op_len == 2'd0, op_offset[10:1]};
            read_count <= 0;
            reads_more <= 0;
            beat <= 0;
            state <= S_READ;
          end
        end
        S_WRITE: begin
          sdram_dq_o <= op_wdata[word*16 +: 16];
          sdram_dqm <= ~op_mask[word*2 +: 2];
          sdram_dq_oe <= 1;
          word <= word + 2'd1;
          if (word == 3) begin
            wait_count <= 16'(C_DAL - 1) + 16'(extra_wait);
            state <= S_IDLE;
            pending <= 0;
            if (!drop && !bus_rst) begin
              rsp_valid <= 1;
              rsp <= '{rdata: 64'b0, error: 1'b0, last: 1'b1};
            end
          end
        end
        S_READ: begin
          read_count <= read_count + 6'd1;
          if (reads_more != op_len && read_count[1:0] == 2'd3) begin
            cmd <= CMD_READ;
            sdram_ba <= op_offset[12:11];
            sdram_a <= {2'b00, reads_more + 2'd1 == op_len, op_offset[10:5], op_offset[4:3] + reads_more + 2'd1, 2'b00};
            reads_more <= reads_more + 2'd1;
          end
          if (read_count >= 6'(capture)) read_data[word_index[1:0] * 16 +: 16] <= dq_q;
          if (read_count >= 6'(capture) && word_index[1:0] == 2'd3) begin
            beat <= beat + 2'd1;
            if (beat == op_len) begin
              wait_count <= 16'(C_RD_RECOVER) + 16'(extra_wait);
              state <= S_IDLE;
              pending <= 0;
            end
            if (!drop && !bus_rst) begin
              rsp_valid <= 1;
              rsp.rdata <= {dq_q, read_data[47:0]} & lane_mask;
              rsp.error <= 0;
              rsp.last <= beat == op_len;
            end
          end
        end
        default: state <= S_POWERUP;
      endcase
    end
  end

  // synthesis translate_off
  always @(posedge clk) if (!rst && init_done && refresh_count == 0 && refresh_due)
    $error("sdram_ctrl: refresh overrun");
  always @(posedge clk) if (!rst && !bus_rst && rsp_valid && !rsp_ready && op_len != 0 && pending)
    $error("sdram_ctrl: burst beat not accepted by the burst master");
  // synthesis translate_on
endmodule
