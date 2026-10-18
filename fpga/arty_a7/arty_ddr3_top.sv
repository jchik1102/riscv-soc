// Board top for a Digilent Arty A7-100T (xc7a100tcsg324-1): the pipeline SoC
// with its caches, and DDR3 as the memory behind the SDRAM region in place of
// the DE10-Lite's SDR SDRAM: cpu_soc -> rtl/memory/ddr3_bridge.sv -> the MIG
// DDR3 controller (fpga/arty_a7/gen_mig.tcl) -> the board's MT41K128M16.
//
// One MMCM makes all the clocks from the 100 MHz oscillator: 50 MHz for the
// SoC, 200 MHz for the MIG's IDELAY reference and 100 MHz for the MIG's own
// PLL. Firmware loads from a boot ROM into the on-chip RAM, as on the
// DE10-Lite; the SoC's 64 MiB SDRAM region maps to the first 64 MiB of the
// 256 MiB DDR3. LEDs: 0 calibration done, 1 core halted, 2 the firmware's
// report says pass, 3 it says fail. The UART is the board's USB serial port.
//
// This top has been simulated in pieces and implemented in Vivado; it has not
// been run on a board.
module arty_ddr3_top #(
  parameter IMAGE_FILE = "s5_board_words.hex",
  parameter int IMAGE_WORDS = 512
) (
  input  logic CLK100MHZ,
  input  logic ck_rst,                 // red reset button, active low
  input  logic uart_txd_in,
  output logic uart_rxd_out,
  output logic [3:0] led,
  inout  wire [15:0] ddr3_dq,
  inout  wire [1:0] ddr3_dqs_n, ddr3_dqs_p,
  output logic [13:0] ddr3_addr,
  output logic [2:0] ddr3_ba,
  output logic ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n,
  output logic [0:0] ddr3_ck_p, ddr3_ck_n, ddr3_cke, ddr3_cs_n, ddr3_odt,
  output logic [1:0] ddr3_dm
);
  import soc_pkg::*;
  localparam logic [63:0] REPORT = platform_pkg::RAM_BASE + 64'h8000;
  localparam int RAM_WORDS = int'(platform_pkg::RAM_BYTES / 8);

  // ------------------------------------------------------------- clocks
  logic clk_in, clk_fb, clk_fb_buf, mmcm_locked, clk50_raw, clk200_raw, clk100_raw, clk, clk_ref, clk_mig;
  IBUF clk_ibuf(.I(CLK100MHZ), .O(clk_in));
  MMCME2_BASE #(.CLKIN1_PERIOD(10.0), .CLKFBOUT_MULT_F(10.0), .DIVCLK_DIVIDE(1),
                .CLKOUT0_DIVIDE_F(20.0), .CLKOUT1_DIVIDE(5), .CLKOUT2_DIVIDE(10)) mmcm(
    .CLKIN1(clk_in), .CLKFBIN(clk_fb_buf), .CLKFBOUT(clk_fb), .CLKFBOUTB(),
    .CLKOUT0(clk50_raw), .CLKOUT0B(), .CLKOUT1(clk200_raw), .CLKOUT1B(), .CLKOUT2(clk100_raw), .CLKOUT2B(),
    .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
    .LOCKED(mmcm_locked), .PWRDWN(1'b0), .RST(1'b0));
  BUFG fb_bufg(.I(clk_fb), .O(clk_fb_buf));
  BUFG soc_bufg(.I(clk50_raw), .O(clk));
  BUFG ref_bufg(.I(clk200_raw), .O(clk_ref));
  BUFG mig_bufg(.I(clk100_raw), .O(clk_mig));

  // ------------------------------------------------------------- resets
  // The MIG's reset is the button and the MMCM lock. The bridge's SoC side
  // follows the MIG's user-clock reset (both must start together); the CPU
  // also waits for the boot image to be loaded.
  // Two-flop synchronizers, each fed straight from its source (a gate in front
  // of a synchronizer could glitch). clk only runs once the MMCM has locked.
  (* ASYNC_REG = "TRUE" *) logic [1:0] btn_sync = 0;
  (* ASYNC_REG = "TRUE" *) logic [1:0] ui_rst_sync = 2'b11;
  logic mig_rst_n, ui_clk, ui_rst, calib_done, bridge_rst;
  always_ff @(posedge clk) btn_sync <= {btn_sync[0], ck_rst};
  assign mig_rst_n = mmcm_locked && ck_rst;
  always_ff @(posedge clk) ui_rst_sync <= {ui_rst_sync[0], ui_rst};
  assign bridge_rst = ui_rst_sync[1];
  logic system_rst;
  assign system_rst = bridge_rst || !btn_sync[1];

  logic [13:0] load_index;
  logic [63:0] rom_q;
  logic load_we, load_from_rom, cpu_rst;
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
    load_from_rom <= load_index < IMAGE_WORDS;
  end
  assign cpu_rst = system_rst || load_index <= RAM_WORDS;

  // ---------------------------------------------------------------- SoC
  retire_t trace;
  logic trace_valid, halted;
  logic sdram_req_valid, sdram_req_ready, sdram_rsp_valid, sdram_rsp_ready, init_done;
  bus2_req_t sdram_req;
  bus2_rsp_t sdram_rsp;
  cpu_soc #(.PIPELINE(1), .SDRAM(1), .CACHE(1)) soc(.clk(clk), .rst(cpu_rst),
    .loader_we(load_we), .loader_word(load_word), .loader_data(load_from_rom ? rom_q : 64'b0),
    .trace_valid(trace_valid), .trace(trace), .halted(halted),
    .event_retired(), .event_mem_wait(), .event_arith_wait(), .event_fetch_wait(), .event_load_use(), .event_redirect(),
    .uart_tx(uart_rxd_out), .uart_rx(uart_txd_in), .cache_enable_init(2'b11),
    .sdram_req_valid(sdram_req_valid), .sdram_req_ready(sdram_req_ready), .sdram_req(sdram_req),
    .sdram_rsp_valid(sdram_rsp_valid), .sdram_rsp_ready(sdram_rsp_ready), .sdram_rsp(sdram_rsp));

  // --------------------------------------------------------------- DDR3
  logic [27:0] app_addr;
  logic [2:0] app_cmd;
  logic app_en, app_rdy, app_wdf_end, app_wdf_wren, app_wdf_rdy, app_rd_data_end, app_rd_data_valid;
  logic [127:0] app_wdf_data, app_rd_data;
  logic [15:0] app_wdf_mask;
  ddr3_bridge bridge(.clk(clk), .rst(bridge_rst), .bus_rst(cpu_rst),
    .req_valid(sdram_req_valid), .req_ready(sdram_req_ready), .req(sdram_req),
    .rsp_valid(sdram_rsp_valid), .rsp_ready(sdram_rsp_ready), .rsp(sdram_rsp), .init_done(init_done),
    .ui_clk(ui_clk), .ui_rst(ui_rst), .calib_done(calib_done),
    .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
    .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end), .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren),
    .app_wdf_rdy(app_wdf_rdy), .app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid));
  mig_ddr3 mig(
    .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p), .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba),
    .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n), .ddr3_reset_n(ddr3_reset_n),
    .ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n), .ddr3_cke(ddr3_cke), .ddr3_cs_n(ddr3_cs_n), .ddr3_dm(ddr3_dm),
    .ddr3_odt(ddr3_odt), .sys_clk_i(clk_mig), .clk_ref_i(clk_ref),
    .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end),
    .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren), .app_rd_data(app_rd_data), .app_rd_data_end(app_rd_data_end),
    .app_rd_data_valid(app_rd_data_valid), .app_rdy(app_rdy), .app_wdf_rdy(app_wdf_rdy),
    .app_sr_req(1'b0), .app_ref_req(1'b0), .app_zq_req(1'b0), .app_sr_active(), .app_ref_ack(), .app_zq_ack(),
    .ui_clk(ui_clk), .ui_clk_sync_rst(ui_rst), .init_calib_complete(calib_done), .device_temp(),
    .sys_rst(mig_rst_n));

  // ------------------------------------------------------------- status
  // The firmware's report block (as on the DE10-Lite): status 1 is a pass.
  logic [63:0] status;
  always_ff @(posedge clk) begin
    if (cpu_rst) status <= 0;
    else if (trace_valid && trace.mem_wmask == 8'hff && trace.mem_addr == REPORT + 16) status <= trace.mem_wdata;
  end
  assign led = {status == 2, status == 1, halted, init_done};
endmodule
