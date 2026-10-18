`timescale 1ns/1ps
// The pipeline SoC with the hardware FIR filter, running sw/fir_hw.c: the
// S3 FIR data set filtered in software and on the filter. The firmware
// checks its two outputs against the reference checksum and each other and
// reports the cycles of each. This bench also watches the filter's bus port
// and checks every DATA read against the MATLAB outputs for the same data
// (+CASES=tests/fir/fir_soc.txt), so the hardware path is checked against
// MATLAB inside the SoC, not only against the firmware's own software filter.
module soc_fir_hw_tb #(parameter int LANES = 4);
  import platform_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic loader_we = 0;
  logic [12:0] loader_word = 0;
  logic [63:0] loader_data = 0;
  logic trace_valid, halted;
  logic [63:0] trace_pc, trace_result;
  logic [4:0] trace_rd;
  logic uart_tx, uart_rx = 1;
  byte unsigned image [0:RAM_BYTES-1];
  string image_path, cases_path;
  logic [63:0] expected;
  logic [63:0] field [8];
  longint unsigned cycles = 0, retired = 0;
  localparam logic [63:0] REPORT = RAM_BASE + 64'h8000;
  localparam logic [63:0] MAGIC = 64'h4649524857313600;
  synthesis_top #(.PIPELINE(1), .FIR_LANES(LANES)) dut(.*);

  int n_expected = 0, data_reads = 0, mismatches = 0;
  int matlab_y [1024];
  initial begin
    int fd, rc, ncases, taps, n, x, y, h;
    if (!$value$plusargs("IMAGE=%s", image_path)) $fatal(1, "IMAGE required");
    if (!$value$plusargs("EXPECTED=%h", expected)) $fatal(1, "EXPECTED required");
    if (!$value$plusargs("CASES=%s", cases_path)) $fatal(1, "CASES required");
    fd = $fopen(cases_path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", cases_path);
    rc = $fscanf(fd, "%d", ncases);
    rc = $fscanf(fd, "%d %d", taps, n);
    for (int k = 0; k < taps; k++) rc = $fscanf(fd, "%d", h);
    for (int i = 0; i < n; i++) begin rc = $fscanf(fd, "%d %d", x, y); matlab_y[i] = y; end
    $fclose(fd);
    n_expected = n;
    foreach (field[i]) field[i] = 0;
    foreach (image[i]) image[i] = 0;
    $readmemh(image_path, image);
    repeat (2) @(negedge clk);
    for (int word_index = 0; word_index < RAM_BYTES/8; word_index++) begin
      loader_we = 1; loader_word = 13'(word_index);
      for (int lane = 0; lane < 8; lane++) loader_data[8*lane +: 8] = image[8*word_index+lane];
      @(negedge clk);
    end
    loader_we = 0; rst = 0;
  end
  always @(posedge clk) if (!rst && !halted) cycles++;

  // Filter port monitor: a DATA read handshake, then its response.
  localparam logic [63:0] DATA = DSP_BASE + 64'h20;
  bit data_read_pending = 0;
  always @(posedge clk) if (!rst) begin
    if (dut.soc.pipeline.dsp.filter.rsp_valid && dut.soc.pipeline.dsp.filter.rsp_ready && data_read_pending) begin
      data_read_pending = 0;
      if (data_reads < n_expected && $signed(dut.soc.pipeline.dsp.filter.rsp.rdata[15:0]) != matlab_y[data_reads]) begin
        mismatches++;
        $error("DATA read %0d: filter %0d, MATLAB %0d", data_reads, $signed(dut.soc.pipeline.dsp.filter.rsp.rdata[15:0]), matlab_y[data_reads]);
      end
      data_reads++;
    end
    if (dut.soc.pipeline.dsp.filter.req_valid && dut.soc.pipeline.dsp.filter.req_ready &&
        !dut.soc.pipeline.dsp.filter.req.write && dut.soc.pipeline.dsp.filter.req.addr == DATA)
      data_read_pending = 1;
  end

  always @(negedge clk) if (!rst && trace_valid) begin
    if (dut.trace.mem_wmask == 8'hff && dut.trace.mem_addr >= REPORT && dut.trace.mem_addr < REPORT + 64)
      field[(dut.trace.mem_addr - REPORT) / 8] = dut.trace.mem_wdata;
    if (!dut.trace.trap) retired++;
    else begin
      // field: 0 magic, 1 checksum_hw, 2 status, 3 checksum_sw, 4 cycles_sw, 5 cycles_hw, 6 mismatches, 7 filter_cycles
      if (dut.trace.cause != 3 || field[0] !== MAGIC || field[2] !== 1 || field[1] !== expected || field[3] !== expected || field[6] !== 0)
        $fatal(1, "FIR result mismatch: cause=%0d magic=%h status=%0d hw=%h sw=%h expected=%h mismatches=%0d",
               dut.trace.cause, field[0], field[2], field[1], field[3], expected, field[6]);
      if (data_reads != n_expected || mismatches != 0)
        $fatal(1, "filter DATA reads: %0d of %0d, %0d differ from MATLAB", data_reads, n_expected, mismatches);
      @(negedge clk);
      if (!halted) $fatal(1, "Core did not halt after EBREAK");
      $display("SOC_FIR_HW_TEST_PASS: lanes=%0d checksum=%h sw_cycles=%0d hw_cycles=%0d speedup=%.1f filter_busy_cycles=%0d matlab_matched=%0d total_cycles=%0d retired=%0d",
               LANES, field[1], field[4], field[5], real'(field[4]) / real'(field[5]), field[7], data_reads, cycles, retired);
      $finish;
    end
  end
  initial begin #20000000; $fatal(1, "FIR watchdog"); end
endmodule
