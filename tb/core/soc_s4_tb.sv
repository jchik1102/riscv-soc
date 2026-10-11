`timescale 1ns/1ps
module soc_s4_tb;
  import soc_pkg::*;
  import platform_pkg::*;
  localparam int BIT = 16;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic loader_we = 0;
  logic [12:0] loader_word = 0;
  logic [63:0] loader_data = 0;
  logic trace_valid, halted, uart_tx, uart_rx = 1;
  retire_t trace;
  logic event_retired, event_mem_wait, event_arith_wait, event_fetch_wait, event_load_use, event_redirect;
  byte unsigned image [0:RAM_BYTES-1];
  byte unsigned final_ram [0:RAM_BYTES-1];
  string image_path, trace_path, rx_text = "", expect_text = "", tx_text = "";
  int fd, mem_fd, frame_errors = 0, interrupts = 0, cycles = 0;
  cpu_soc #(.PIPELINE(1), .UART_DIVISOR(16'(BIT))) dut(.*, .cache_enable_init(2'b00), .sdram_req_valid(), .sdram_req_ready(1'b0), .sdram_req(),
    .sdram_rsp_valid(1'b0), .sdram_rsp_ready(), .sdram_rsp('0));

  initial begin
    if (!$value$plusargs("IMAGE=%s", image_path)) $fatal(1, "IMAGE required");
    if (!$value$plusargs("TRACE=%s", trace_path)) $fatal(1, "TRACE required");
    if ($value$plusargs("RX_TEXT=%s", rx_text)) begin end
    if ($value$plusargs("EXPECT_TEXT=%s", expect_text)) begin end
    foreach (image[i]) image[i] = 0;
    $readmemh(image_path, image);
    fd = $fopen(trace_path, "w");
    $fdisplay(fd, "order,pc,insn,next_pc,rd,rd_data,mem_addr,mem_rmask,mem_wmask,mem_rdata,mem_wdata,trap,cause,intr");
    repeat (2) @(negedge clk);
    for (int w = 0; w < RAM_BYTES/8; w++) begin
      loader_we = 1; loader_word = 13'(w);
      for (int lane = 0; lane < 8; lane++) loader_data[8*lane +: 8] = image[8*w + lane];
      @(negedge clk);
    end
    loader_we = 0; rst = 0;
  end

  initial begin
    wait (!rst);
    repeat (4000) @(posedge clk);
    for (int i = 0; i < rx_text.len(); i++) begin
      byte unsigned c = rx_text[i];
      uart_rx = 0; repeat (BIT) @(posedge clk);
      for (int b = 0; b < 8; b++) begin uart_rx = c[b]; repeat (BIT) @(posedge clk); end
      uart_rx = 1; repeat (BIT * 2) @(posedge clk);
    end
  end
  initial begin
    wait (!rst);
    forever begin
      byte unsigned c;
      @(negedge uart_tx);
      repeat (BIT / 2) @(posedge clk);
      if (uart_tx !== 0) $fatal(1, "UART monitor: start bit not held");
      for (int b = 0; b < 8; b++) begin repeat (BIT) @(posedge clk); c[b] = uart_tx; end
      repeat (BIT) @(posedge clk);
      if (uart_tx !== 1) begin frame_errors++; $fatal(1, "UART monitor: missing stop bit"); end
      tx_text = {tx_text, string'(c)};
    end
  end

  always @(posedge clk) if (!rst) begin
    cycles++;
    if (dut.pipeline.core.irsp_valid && dut.pipeline.core.irsp_ready)
      $fdisplay(fd, "IR,%01h,%016h", dut.pipeline.core.irsp.error, dut.pipeline.core.irsp.rdata);
    if (dut.pipeline.core.ireq_valid && dut.pipeline.core.ireq_ready)
      $fdisplay(fd, "IQ,%016h,%01h,%02h,%016h", dut.pipeline.core.ireq.addr, dut.pipeline.core.ireq.write,
                dut.pipeline.core.ireq.mask, dut.pipeline.core.ireq.wdata);
    if (dut.pipeline.core.drsp_valid && dut.pipeline.core.drsp_ready)
      $fdisplay(fd, "R,%01h,%016h", dut.pipeline.core.drsp.error, dut.pipeline.core.drsp.rdata);
    if (dut.pipeline.core.dreq_valid && dut.pipeline.core.dreq_ready)
      $fdisplay(fd, "Q,%016h,%01h,%02h,%016h", dut.pipeline.core.dreq.addr, dut.pipeline.core.dreq.write,
                dut.pipeline.core.dreq.mask, dut.pipeline.core.dreq.wdata);
    if (cycles > 3000000) $fatal(1, "S4 SoC watchdog");
  end

  genvar lane;
  generate for (lane = 0; lane < 8; lane++) begin : dump
    task automatic copy_lane();
      for (int w = 0; w < RAM_BYTES/8; w++) final_ram[8*w + lane] = dut.ram.lanes[lane].data[w];
    endtask
  end endgenerate

  always @(negedge clk) if (!rst && trace_valid) begin
    $fdisplay(fd, "%0d,%016h,%08h,%016h,%0d,%016h,%016h,%02h,%02h,%016h,%016h,%0d,%0d,%0d",
      trace.order, trace.pc, trace.insn, trace.next_pc, trace.rd, trace.rd_data, trace.mem_addr,
      trace.mem_rmask, trace.mem_wmask, trace.mem_rdata, trace.mem_wdata, trace.trap, trace.cause, trace.intr);
    if (trace.intr) interrupts++;
    if (halted) begin
      automatic logic [5:0] final_cause = trace.cause;
      repeat (BIT * 12) @(negedge clk);
      dump[0].copy_lane(); dump[1].copy_lane(); dump[2].copy_lane(); dump[3].copy_lane();
      dump[4].copy_lane(); dump[5].copy_lane(); dump[6].copy_lane(); dump[7].copy_lane();
      mem_fd = $fopen({trace_path, ".mem"}, "w");
      foreach (final_ram[i]) $fdisplay(mem_fd, "%02h", final_ram[i]);
      $fclose(mem_fd);
      $fclose(fd);
      if (final_cause != 3) $fatal(1, "Terminal diagnostic cause %0d (expected EBREAK)", final_cause);
      if (expect_text != "" && tx_text != expect_text) $fatal(1, "UART text mismatch: %s", tx_text);
      mem_fd = $fopen({trace_path, ".uart"}, "w");
      $fwrite(mem_fd, "%s", tx_text);
      $fclose(mem_fd);
      $display("SOC_S4_TEST_PASS cycles=%0d interrupts=%0d uart_chars=%0d", cycles, interrupts, tx_text.len());
      $finish;
    end
  end
endmodule
