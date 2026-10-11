`timescale 1ns/1ps
module board_tb #(parameter bit PIPELINE = 1, parameter IMAGE_FILE = "fir_words.hex",
                  parameter int IMAGE_WORDS = 128, parameter int DEMO = 0);
  logic clk = 0;
  always #10 clk = ~clk;
  logic [1:0] KEY = 2'b11;
  logic [9:0] SW = 0;
  logic [9:0] LEDR;
  logic [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
  logic [12:0] DRAM_ADDR;
  logic [1:0] DRAM_BA;
  logic DRAM_CAS_N, DRAM_RAS_N, DRAM_WE_N, DRAM_CS_N, DRAM_CKE, DRAM_CLK, DRAM_LDQM, DRAM_UDQM;
  wire [15:0] DRAM_DQ;
  logic [63:0] expected;
  longint unsigned cycles_first, cycles_second;
  localparam IMG = DEMO == 5 ? "s8_bench_words.hex" : DEMO == 4 ? "s7_bench_words.hex" : DEMO == 3 ? "s6_bench_words.hex" : DEMO == 2 ? "s5_sdram_words.hex" : DEMO == 1 ? "s4_demo_words.hex" : IMAGE_FILE;
  localparam int WORDS = DEMO == 5 ? 1024 : DEMO == 4 ? 512 : DEMO == 3 ? 256 : DEMO == 2 ? 512 : DEMO == 1 ? 256 : IMAGE_WORDS;
  localparam logic [63:0] S6_CHECK = 64'h1f08e84a;
  localparam logic [63:0] S7_CHECK = 64'h5b465e18;
  localparam logic [63:0] S8_CHECK = 64'h32f682fe;
  localparam logic [63:0] TESTER_BYTES = 64'h2000;
  de10_lite_top #(.PIPELINE(PIPELINE), .IMAGE_FILE(IMG), .IMAGE_WORDS(WORDS),
                  .EXPECTED_CHECKSUM(DEMO == 5 ? S8_CHECK : DEMO == 4 ? S7_CHECK : DEMO == 3 ? S6_CHECK : DEMO == 2 ? 64'h7fc9e2a8 : DEMO == 1 ? 64'd6 : 64'h0fc6e755), .DEMO(DEMO),
                  .TESTER_BYTES(TESTER_BYTES)) dut(.MAX10_CLK1_50(clk), .*);
  sdram_model sdram(.clk(DRAM_CLK), .cke(DRAM_CKE), .cs_n(DRAM_CS_N), .ras_n(DRAM_RAS_N), .cas_n(DRAM_CAS_N),
    .we_n(DRAM_WE_N), .ba(DRAM_BA), .a(DRAM_ADDR), .dqm({DRAM_UDQM, DRAM_LDQM}), .dq(DRAM_DQ));
  function automatic logic [3:0] digit(input logic [7:0] segments);
    for (int v = 0; v < 16; v++) begin
      logic [7:0] pattern;
      case (v)
        0: pattern = 8'hc0; 1: pattern = 8'hf9; 2: pattern = 8'ha4; 3: pattern = 8'hb0;
        4: pattern = 8'h99; 5: pattern = 8'h92; 6: pattern = 8'h82; 7: pattern = 8'hf8;
        8: pattern = 8'h80; 9: pattern = 8'h90; 10: pattern = 8'h88; 11: pattern = 8'h83;
        12: pattern = 8'hc6; 13: pattern = 8'ha1; 14: pattern = 8'h86; default: pattern = 8'h8e;
      endcase
      if (segments == pattern) return 4'(v);
    end
    $fatal(1, "Undecodable seven-segment pattern %h", segments);
  endfunction
  function automatic logic [23:0] shown();
    return {digit(HEX5), digit(HEX4), digit(HEX3), digit(HEX2), digit(HEX1), digit(HEX0)};
  endfunction
  function automatic logic [63:0] report_word(input int i);
    return {dut.soc.ram.lanes[7].data[16'h1000 + i], dut.soc.ram.lanes[6].data[16'h1000 + i],
            dut.soc.ram.lanes[5].data[16'h1000 + i], dut.soc.ram.lanes[4].data[16'h1000 + i],
            dut.soc.ram.lanes[3].data[16'h1000 + i], dut.soc.ram.lanes[2].data[16'h1000 + i],
            dut.soc.ram.lanes[1].data[16'h1000 + i], dut.soc.ram.lanes[0].data[16'h1000 + i]};
  endfunction
  task automatic wait_result(output longint unsigned cycles);
    int guard = 0;
    logic [23:0] view_value;
    while (LEDR[0] !== 1 && LEDR[1] !== 1) begin @(posedge clk); if (++guard > 3000000) $fatal(1, "Board watchdog"); end
    if (LEDR[0] !== 1 || LEDR[1] !== 0)
      $fatal(1, "Board reported FAIL: magic=%h checksum=%h status=%h cause=%0d trap=%0d retired=%0d cycles=%0d", dut.magic,
             dut.checksum, dut.status, dut.final_cause, dut.final_trap, dut.retired, dut.cycles);
    SW[1:0] = 0; repeat (6) @(posedge clk);
    if (shown() !== expected[23:0]) $fatal(1, "HEX checksum %h, expected %h", shown(), expected[23:0]);
    if (DEMO == 5) begin
      SW[1:0] = 1; repeat (6) @(posedge clk);
      view_value = shown();
      if (view_value[23:20] !== 4'h3 || view_value[19:0] == 0) $fatal(1, "HEX phase/ticks %h, expected phase 3 and ticks", view_value);
      if (view_value[19:0] !== 20'(report_word(3))) $fatal(1, "HEX ticks %h, report %h", view_value, report_word(3));
      for (int workload = 0; workload < 2; workload++)
        for (int mode = 0; mode < 2; mode++)
          for (int method = 0; method < 3; method++)
            for (int metric = 0; metric < 8; metric++) begin
              logic [63:0] want;
              SW[1:0] = 2; SW[8] = workload[0]; SW[7] = mode[0]; SW[6:5] = 2'(method); SW[4:2] = 3'(metric);
              repeat (6) @(posedge clk);
              want = report_word(16 + ((workload * 2 + mode) * 4 + method) * 16 + metric);
              if (want == 0 && metric < 2) $fatal(1, "Report metric %0d of window %0d/%0d/%0d is zero", metric, workload, mode, method);
              if (want >= 64'h1000000) $fatal(1, "Report metric exceeds the 24-bit display: %h", want);
              if (shown() !== want[23:0]) $fatal(1, "HEX window %0d/%0d/%0d metric %0d: %h, report %h", workload, mode, method, metric, shown(), want);
            end
      SW[8:2] = 0; SW[1:0] = 3; repeat (6) @(posedge clk);
      if (shown() !== {4'd4, 8'd10, 12'd0}) $fatal(1, "HEX N/cases/mismatches %h", shown());
      cycles = dut.cycles;
      if (LEDR[4] !== 1 || LEDR[6] !== 1 || LEDR[7] !== 1) $fatal(1, "SDRAM, caches or accelerator LED off");
    end else if (DEMO == 4) begin
      SW[1:0] = 1; repeat (6) @(posedge clk);
      view_value = shown();
      if (view_value[23:20] !== 4'h3 || view_value[19:0] == 0) $fatal(1, "HEX phase/ticks %h, expected phase 3 and ticks", view_value);
      for (int mode = 0; mode < 2; mode++)
        for (int metric = 0; metric < 8; metric++) begin
          SW[1:0] = 2; SW[5] = mode[0]; SW[4:2] = 3'(metric); repeat (6) @(posedge clk);
          if (shown() !== dut.s6_cycles[{mode[0], 3'(metric)}] || shown() == 0)
            $fatal(1, "HEX total mode %0d metric %0d: %h", mode, metric, shown());
        end
      SW[5:2] = 0; SW[1:0] = 3; repeat (6) @(posedge clk);
      if (shown() !== {4'd4, 8'd10, 12'd0}) $fatal(1, "HEX N/cases/mismatches %h", shown());
      cycles = dut.cycles;
      if (LEDR[4] !== 1 || LEDR[6] !== 1 || LEDR[7] !== 1) $fatal(1, "SDRAM, caches or accelerator LED off");
    end else if (DEMO == 3) begin
      SW[1:0] = 1; repeat (6) @(posedge clk);
      view_value = shown();
      if (view_value[23:20] !== 4'h5 || view_value[19:0] == 0) $fatal(1, "HEX phase/ticks %h, expected phase 5 and ticks", view_value);
      for (int view = 2; view < 4; view++)
        for (int mode = 0; mode < 4; mode++)
          for (int where = 0; where < 2; where++) begin
            SW[1:0] = 2'(view); SW[3:2] = 2'(mode); SW[4] = where[0]; repeat (6) @(posedge clk);
            if (shown() !== dut.s6_cycles[{2'(mode), where[0], view == 2}] || shown() == 0)
              $fatal(1, "HEX cycles view %0d mode %0d kernel %0d: %h", view, mode, where, shown());
          end
      SW[4:2] = 0;
      cycles = dut.cycles;
      if (LEDR[4] !== 1 || LEDR[6] !== 1) $fatal(1, "SDRAM initialized or caches LED off");
    end else if (DEMO == 2) begin
      SW[1:0] = 1; repeat (6) @(posedge clk);
      if (shown() !== 24'h600000) $fatal(1, "HEX phase/errors %h, expected phase 6 and no errors", shown());
      SW[1:0] = 2; repeat (6) @(posedge clk);
      if (shown() !== 24'h0) $fatal(1, "HEX runs %h: the simulation image has no run counter", shown());
      SW[1:0] = 3; repeat (6) @(posedge clk); cycles = longint'(shown()) << 24;
      if (cycles != (dut.cycles & 64'hffffff000000)) $fatal(1, "Displayed cycles[47:24] differ from counter %0d", dut.cycles);
      cycles = dut.cycles;
      if (LEDR[4] !== 1) $fatal(1, "SDRAM initialized LED off");
    end else begin
      SW[1:0] = 1; repeat (6) @(posedge clk); cycles = shown();
      SW[1:0] = 2; repeat (6) @(posedge clk); cycles |= longint'(shown()) << 24;
      if (cycles != dut.cycles) $fatal(1, "Displayed cycles %0d differ from counter %0d", cycles, dut.cycles);
    end
  endtask
  bit watch_init = 0;
  always @(posedge clk) if (watch_init && DEMO >= 2 && LEDR[4] !== 1) $fatal(1, "KEY0 re-initialized the SDRAM controller");
  initial begin
    if (!$value$plusargs("EXPECTED=%h", expected)) $fatal(1, "EXPECTED required");
    if (DEMO == 1) expected = 6;
    else if (DEMO == 5) begin
      if (!$value$plusargs("S8_EXPECTED=%h", expected)) $fatal(1, "S8_EXPECTED required");
      if (expected != S8_CHECK) $fatal(1, "Bench EXPECTED_CHECKSUM parameter is stale");
    end
    else if (DEMO == 4) begin
      if (!$value$plusargs("S7_EXPECTED=%h", expected)) $fatal(1, "S7_EXPECTED required");
      if (expected != S7_CHECK) $fatal(1, "Bench EXPECTED_CHECKSUM parameter is stale");
    end
    else if (DEMO == 3) begin
      if (!$value$plusargs("S6_EXPECTED=%h", expected)) $fatal(1, "S6_EXPECTED required");
      if (expected != S6_CHECK) $fatal(1, "Bench EXPECTED_CHECKSUM parameter is stale");
    end
    else if (DEMO == 2) begin
      if (!$value$plusargs("S5_EXPECTED=%h", expected)) $fatal(1, "S5_EXPECTED required");
      if (expected != 64'h7fc9e2a8) $fatal(1, "Bench EXPECTED_CHECKSUM parameter is stale");
    end
    else if (expected[23:0] != 24'hc6e755) $fatal(1, "Bench EXPECTED_CHECKSUM parameter is stale");
    wait_result(cycles_first);
    watch_init = 1;
    KEY[0] = 0; repeat (10) @(posedge clk); KEY[0] = 1;
    repeat (10) @(posedge clk);
    if (LEDR[0] !== 0 || LEDR[3] !== 1) $fatal(1, "KEY0 did not restart boot loading");
    wait_result(cycles_second);
    if (DEMO < 2 && cycles_first != cycles_second) $fatal(1, "Run cycle counts differ: %0d vs %0d", cycles_first, cycles_second);
    if (DEMO == 2) begin
      automatic int guard = 0;
      SW[9] = 1;
      KEY[0] = 0; repeat (10) @(posedge clk); KEY[0] = 1;
      repeat (10) @(posedge clk);
      if (LEDR[5] !== 1) $fatal(1, "Tester mode LED off");
      while (LEDR[0] !== 1 && LEDR[1] !== 1) begin @(posedge clk); if (++guard > 3000000) $fatal(1, "Tester watchdog"); end
      if (LEDR[1] !== 0) $fatal(1, "Tester reported errors: %0d first at %h", dut.tester_errors, dut.first_error);
      SW[1:0] = 0; repeat (6) @(posedge clk);
      if (shown() == 0) $fatal(1, "HEX tester loop count zero with pass LED on");
      if (sdram.errors) $fatal(1, "SDRAM model reported %0d protocol/timing errors", sdram.errors);
      $display("BOARD_TB_S5_TESTER: loops=%0d errors=%0d over %0d bytes; model refreshes=%0d", dut.loops, dut.tester_errors,
               TESTER_BYTES, sdram.n_refresh);
    end
    if (sdram.errors) $fatal(1, "SDRAM model reported %0d protocol/timing errors", sdram.errors);
    $display("BOARD_TB_PASS: demo=%0d pipeline=%0d value=%h cycles=%0d retired=%0d (twice, KEY0 rerun)",
             DEMO, PIPELINE, expected[23:0], cycles_first, dut.retired);
    $finish;
  end
endmodule
