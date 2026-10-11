module de10_lite_top #(
  parameter bit PIPELINE = 1,
  parameter IMAGE_FILE = "fir_words.hex",
  parameter int IMAGE_WORDS = 128,
  parameter logic [63:0] EXPECTED_CHECKSUM = 64'h0,
  parameter int DEMO = 0,
  parameter logic [63:0] TESTER_BYTES = platform_pkg::SDRAM_BYTES,
  parameter SDRAM_PHASE_PS = "-3000"
) (
  input logic MAX10_CLK1_50,
  input logic [1:0] KEY,
  input logic [9:0] SW,
  output logic [9:0] LEDR,
  output logic [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
  output logic [12:0] DRAM_ADDR,
  output logic [1:0] DRAM_BA,
  output logic DRAM_CAS_N, DRAM_RAS_N, DRAM_WE_N, DRAM_CS_N, DRAM_CKE, DRAM_CLK, DRAM_LDQM, DRAM_UDQM,
  inout wire [15:0] DRAM_DQ
);
  import soc_pkg::*;
  localparam logic [63:0] REPORT = platform_pkg::RAM_BASE + 64'h8000;
  localparam int RAM_WORDS = int'(platform_pkg::RAM_BYTES / 8);
  localparam bit S5 = DEMO >= 2;
  localparam bit S6 = DEMO >= 3;
  localparam bit S7 = DEMO >= 4;
  localparam bit S8 = DEMO == 5;
  logic clk, pll_locked;

  generate if (S5) begin : pll_clock
    sdram_pll #(.SDRAM_PHASE_PS(SDRAM_PHASE_PS)) pll(.inclk(MAX10_CLK1_50), .c0(clk), .c1(DRAM_CLK), .locked(pll_locked));
  end else begin : direct_clock
    assign clk = MAX10_CLK1_50;
    assign DRAM_CLK = 1'b0;
    assign pll_locked = 1'b1;
  end endgenerate

  logic [1:0] key_meta, key_sync;
  logic [9:0] sw_meta, sw_sync;
  logic [1:0] lock_sync = 0;
  logic [7:0] por_count = 0;
  logic system_rst, power_rst, sdram_rst;
  always_ff @(posedge clk) begin
    key_meta <= KEY; key_sync <= key_meta;
    sw_meta <= SW; sw_sync <= sw_meta;
    lock_sync <= {lock_sync[0], pll_locked};
    if (!lock_sync[1]) por_count <= 0;
    else if (por_count != 8'hff) por_count <= por_count + 8'd1;
  end
  assign power_rst = por_count != 8'hff;
  assign sdram_rst = power_rst || (S5 && !key_sync[1]);
  assign system_rst = sdram_rst || !key_sync[0];

  logic [13:0] load_index;
  logic [63:0] rom_q;
  logic loading, load_we, cpu_rst, tester_mode;
  logic [12:0] load_word;
  boot_rom #(.WORDS(IMAGE_WORDS), .INIT_FILE(IMAGE_FILE)) image_rom(.clk(clk),
    .addr(load_index[$clog2(IMAGE_WORDS)-1:0]), .q(rom_q));
  always_ff @(posedge clk) begin
    if (system_rst) begin
      load_index <= 0; load_we <= 0; load_word <= 0;
    end else begin
      load_we <= load_index < RAM_WORDS;
      load_word <= load_index[12:0];
      if (load_index <= RAM_WORDS) load_index <= load_index + 14'd1;
    end
  end
  assign loading = system_rst || load_index <= RAM_WORDS;
  logic load_from_rom;
  always_ff @(posedge clk) load_from_rom <= load_index < IMAGE_WORDS;
  always_ff @(posedge clk) if (system_rst) tester_mode <= S5 && sw_sync[9];
  assign cpu_rst = loading || tester_mode;

  retire_t trace;
  logic trace_valid, halted;
  logic event_retired, event_mem_wait, event_arith_wait, event_fetch_wait, event_load_use, event_redirect;
  logic cpu_sdram_req_valid, cpu_sdram_req_ready, cpu_sdram_rsp_valid, cpu_sdram_rsp_ready;
  bus2_req_t cpu_sdram_req;
  bus2_rsp_t cpu_sdram_rsp;
  cpu_soc #(.PIPELINE(PIPELINE), .SDRAM(S5), .CACHE(S6),
            .ACCEL_N(S7 ? int'(platform_pkg::ACCEL_N) : 0), .ACCEL_PARALLEL(platform_pkg::ACCEL_PARALLEL != 0)) soc(.clk(clk), .rst(cpu_rst),
    .loader_we(load_we), .loader_word(load_word), .loader_data(load_from_rom ? rom_q : 64'b0),
    .trace_valid(trace_valid), .trace(trace), .halted(halted),
    .event_retired(event_retired), .event_mem_wait(event_mem_wait), .event_arith_wait(event_arith_wait),
    .event_fetch_wait(event_fetch_wait), .event_load_use(event_load_use), .event_redirect(event_redirect),
    .uart_tx(), .uart_rx(1'b1),
    .cache_enable_init(S6 ? 2'b11 : 2'b00),
    .sdram_req_valid(cpu_sdram_req_valid), .sdram_req_ready(cpu_sdram_req_ready), .sdram_req(cpu_sdram_req),
    .sdram_rsp_valid(cpu_sdram_rsp_valid), .sdram_rsp_ready(cpu_sdram_rsp_ready), .sdram_rsp(cpu_sdram_rsp));

  logic init_done, sdram_dq_oe;
  logic [15:0] sdram_dq_o;
  logic [15:0] loops;
  logic [31:0] tester_errors;
  logic [63:0] first_error, tester_address, first_rdata, first_expected;
  logic [1:0] tester_pass;
  logic tester_verify;
  generate if (S5) begin : sdram
    logic req_valid, req_ready, rsp_valid, rsp_ready, t_req_valid, t_rsp_ready;
    bus_req_t t_req;
    bus2_req_t req;
    bus2_rsp_t rsp;
    sdram_tester #(.BYTES(TESTER_BYTES)) tester(.clk(clk), .rst(system_rst || !tester_mode),
      .req_valid(t_req_valid), .req_ready(req_ready && tester_mode), .req(t_req),
      .rsp_valid(rsp_valid && tester_mode), .rsp_ready(t_rsp_ready), .rsp(to_bus1(rsp)),
      .loops(loops), .errors(tester_errors), .first_error(first_error), .first_rdata(first_rdata),
      .first_expected(first_expected), .pass(tester_pass),
      .verifying(tester_verify), .address(tester_address));
    assign req_valid = tester_mode ? t_req_valid : cpu_sdram_req_valid;
    assign req = tester_mode ? to_bus2(t_req) : cpu_sdram_req;
    assign rsp_ready = tester_mode ? t_rsp_ready : cpu_sdram_rsp_ready;
    assign cpu_sdram_req_ready = req_ready && !tester_mode;
    assign cpu_sdram_rsp_valid = rsp_valid && !tester_mode;
    assign cpu_sdram_rsp = rsp;
    sdram_ctrl ctrl(.clk(clk), .rst(sdram_rst), .bus_rst(tester_mode ? system_rst : cpu_rst),
      .req_valid(req_valid), .req_ready(req_ready), .req(req), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
      .rsp(rsp), .init_done(init_done),
      .sdram_cke(DRAM_CKE), .sdram_cs_n(DRAM_CS_N), .sdram_ras_n(DRAM_RAS_N), .sdram_cas_n(DRAM_CAS_N),
      .sdram_we_n(DRAM_WE_N), .sdram_ba(DRAM_BA), .sdram_a(DRAM_ADDR), .sdram_dqm({DRAM_UDQM, DRAM_LDQM}),
      .sdram_dq_o(sdram_dq_o), .sdram_dq_oe(sdram_dq_oe), .sdram_dq_i(DRAM_DQ),
      .extra_wait(S7 ? 2'b00 : sw_sync[7:6]), .extra_capture(S7 ? 1'b0 : sw_sync[5]));
  end else begin : no_sdram
    assign cpu_sdram_req_ready = 0;
    assign cpu_sdram_rsp_valid = 0;
    assign cpu_sdram_rsp = '0;
    assign {DRAM_CKE, DRAM_CS_N, DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N} = 5'b01111;
    assign DRAM_BA = 0;
    assign DRAM_ADDR = 0;
    assign {DRAM_UDQM, DRAM_LDQM} = 2'b11;
    assign sdram_dq_o = 0;
    assign sdram_dq_oe = 0;
    assign init_done = 0;
    assign loops = 0;
    assign tester_errors = 0;
    assign first_error = 0;
    assign first_rdata = 0;
    assign first_expected = 0;
    assign tester_address = 0;
    assign tester_pass = 0;
    assign tester_verify = 0;
  end endgenerate
  assign DRAM_DQ = sdram_dq_oe ? sdram_dq_o : 16'bz;

  logic [63:0] magic, checksum, status, cycles, retired, errors_phase, runs;
  logic [11:0] s7_mismatches;
  logic [3:0] s7_n;
  logic [7:0] s7_cases;
  logic [23:0] s6_cycles [0:15];
  logic [5:0] final_cause;
  logic final_trap;
  always_ff @(posedge clk) begin
    if (cpu_rst) begin
      magic <= 0; checksum <= 0; status <= 0; cycles <= 0; retired <= 0; final_cause <= 0; final_trap <= 0;
      errors_phase <= 0; runs <= 0; s7_mismatches <= 0; s7_n <= 0; s7_cases <= 0;
      for (int i = 0; i < 16; i++) s6_cycles[i] <= 0;
    end else begin
      if (!halted) cycles <= cycles + 64'd1;
      if (event_retired) retired <= retired + 64'd1;
      if (trace_valid && trace.mem_wmask == 8'hff && !trace.trap) begin
        if (trace.mem_addr == REPORT) magic <= trace.mem_wdata;
        if (trace.mem_addr == REPORT + 8) checksum <= trace.mem_wdata;
        if (trace.mem_addr == REPORT + 16) status <= trace.mem_wdata;
        if (!S6 && trace.mem_addr == REPORT + 24) errors_phase[19:0] <= trace.mem_wdata[19:0];
        if (!S6 && trace.mem_addr == REPORT + 56) errors_phase[23:20] <= trace.mem_wdata[3:0];
        if (!S6 && trace.mem_addr == REPORT + 64) runs <= trace.mem_wdata;
        if (S6 && trace.mem_addr == REPORT + 24) errors_phase[19:0] <= trace.mem_wdata[19:0];
        if (S6 && trace.mem_addr == REPORT + 48) errors_phase[23:20] <= trace.mem_wdata[3:0];
        if (S6 && !S8 && trace.mem_addr >= REPORT + 64 && trace.mem_addr < REPORT + 192)
          s6_cycles[4'(trace.mem_addr[7:3] - 5'd8)] <= trace.mem_wdata[23:0];
        if (S7 && trace.mem_addr == REPORT + 32) s7_mismatches <= trace.mem_wdata[11:0];
        if (S7 && trace.mem_addr == REPORT + 40) s7_n <= trace.mem_wdata[3:0];
        if (S7 && trace.mem_addr == REPORT + 56) s7_cases <= trace.mem_wdata[7:0];
      end
      if (trace_valid && trace.trap && halted) begin final_trap <= 1; final_cause <= trace.cause; end
    end
  end
  logic [23:0] s8_metric;
  generate if (S8) begin : s8_metrics
    logic [23:0] metrics [0:255];
    logic we;
    logic [7:0] waddr, raddr;
    logic [63:0] offset;
    assign offset = trace.mem_addr - (REPORT + 64'd128);
    assign we = !cpu_rst && trace_valid && trace.mem_wmask == 8'hff && !trace.trap && offset < 64'd2048;
    assign waddr = offset[10:3];
    assign raddr = {sw_sync[8], sw_sync[7], sw_sync[6:5], 1'b0, sw_sync[4:2]};
    always_ff @(posedge clk) begin
      if (we) metrics[waddr] <= trace.mem_wdata[23:0];
      s8_metric <= metrics[raddr];
    end
  end else begin : no_s8_metrics
    assign s8_metric = 0;
  end endgenerate
  logic pass, fail;
  localparam logic [63:0] MAGIC = DEMO == 5 ? 64'h533844454d4f0000 : DEMO == 4 ? 64'h5337414343454c00 : DEMO == 3 ? 64'h5336434143484500 : DEMO == 2 ? 64'h5335534452414d00 :
                                  DEMO == 1 ? 64'h5334444f4e450000 : 64'h4649523151313500;
  localparam logic [63:0] CHECK_MASK = DEMO >= 2 ? 64'h7fffffff : 64'hffffffffffffffff;
  logic cpu_pass;
  assign cpu_pass = halted && final_trap && final_cause == 6'd3 && magic == MAGIC &&
                    status == 64'd1 && (checksum & CHECK_MASK) == EXPECTED_CHECKSUM;
  assign pass = tester_mode ? loops != 0 && tester_errors == 0 : cpu_pass;
  assign fail = tester_mode ? tester_errors != 0 : final_trap && !cpu_pass;

  logic [25:0] heartbeat;
  always_ff @(posedge clk) heartbeat <= heartbeat + 26'd1;

  logic [23:0] shown;
  logic [63:0] tester_offset;
  assign tester_offset = tester_address - platform_pkg::SDRAM_BASE;
  always_comb begin
    if (tester_mode && sw_sync[8]) case (sw_sync[1:0])
      2'd0: shown = first_rdata[23:0];
      2'd1: shown = first_rdata[47:24];
      2'd2: shown = {8'b0, first_rdata[63:48]};
      default: shown = first_expected[23:0];
    endcase
    else if (tester_mode) case (sw_sync[1:0])
      2'd0: shown = {8'b0, loops};
      2'd1: shown = tester_errors[23:0];
      2'd2: shown = first_error[23:0];
      default: shown = {tester_pass, tester_verify, 3'b0, tester_offset[25:8]};
    endcase
    else if (S8) case (sw_sync[1:0])
      2'd0: shown = checksum[23:0];
      2'd1: shown = errors_phase[23:0];
      2'd2: shown = s8_metric;
      default: shown = {s7_n, s7_cases, s7_mismatches};
    endcase
    else if (S7) case (sw_sync[1:0])
      2'd0: shown = checksum[23:0];
      2'd1: shown = errors_phase[23:0];
      2'd2: shown = s6_cycles[{sw_sync[5], sw_sync[4:2]}];
      default: shown = {s7_n, s7_cases, s7_mismatches};
    endcase
    else if (S6) case (sw_sync[1:0])
      2'd0: shown = checksum[23:0];
      2'd1: shown = errors_phase[23:0];
      2'd2: shown = s6_cycles[{sw_sync[3:2], sw_sync[4], 1'b1}];
      default: shown = s6_cycles[{sw_sync[3:2], sw_sync[4], 1'b0}];
    endcase
    else if (S5) case (sw_sync[1:0])
      2'd0: shown = checksum[23:0];
      2'd1: shown = errors_phase[23:0];
      2'd2: shown = runs[23:0];
      default: shown = cycles[47:24];
    endcase
    else case (sw_sync[1:0])
      2'd0: shown = checksum[23:0];
      2'd1: shown = cycles[23:0];
      2'd2: shown = cycles[47:24];
      default: shown = retired[23:0];
    endcase
  end
  function automatic logic [7:0] seg(input logic [3:0] v);
    case (v)
      4'h0: seg = 8'hc0; 4'h1: seg = 8'hf9; 4'h2: seg = 8'ha4; 4'h3: seg = 8'hb0;
      4'h4: seg = 8'h99; 4'h5: seg = 8'h92; 4'h6: seg = 8'h82; 4'h7: seg = 8'hf8;
      4'h8: seg = 8'h80; 4'h9: seg = 8'h90; 4'ha: seg = 8'h88; 4'hb: seg = 8'h83;
      4'hc: seg = 8'hc6; 4'hd: seg = 8'ha1; 4'he: seg = 8'h86; default: seg = 8'h8e;
    endcase
  endfunction
  always_ff @(posedge clk) begin
    HEX0 <= seg(shown[3:0]); HEX1 <= seg(shown[7:4]); HEX2 <= seg(shown[11:8]);
    HEX3 <= seg(shown[15:12]); HEX4 <= seg(shown[19:16]); HEX5 <= seg(shown[23:20]);
    LEDR <= {heartbeat[25], PIPELINE, S7, S6, tester_mode, init_done, loading && !tester_mode,
             tester_mode ? !system_rst : !halted && !loading, fail, pass};
  end
endmodule
