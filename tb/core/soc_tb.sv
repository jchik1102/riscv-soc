`timescale 1ns/1ps
module soc_tb #(parameter bit PIPELINE = 0);
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic loader_we = 0;
  logic [12:0] loader_word = 0;
  logic [63:0] loader_data = 0;
  logic trace_valid, halted;
  logic [63:0] trace_pc, trace_result;
  logic [4:0] trace_rd;
  logic uart_tx, uart_rx = 1;
  int count = 0;
  synthesis_top #(.PIPELINE(PIPELINE)) dut(.*);
  initial begin
    repeat (2) @(negedge clk);
    loader_we = 1; loader_data = 64'h0070011300500093;
    @(negedge clk);
    loader_word = 1; loader_data = 64'h00000000002081b3;
    @(negedge clk);
    loader_we = 0; rst = 0;
  end
  always @(negedge clk) if (!rst && trace_valid) begin
    if (trace_pc !== platform_pkg::RESET_PC + count * 4) $fatal(1, "Integrated PC mismatch");
    case (count)
      0: if (trace_rd !== 1 || trace_result !== 5) $fatal(1, "Integrated x1 mismatch");
      1: if (trace_rd !== 2 || trace_result !== 7) $fatal(1, "Integrated x2 mismatch");
      2: if (trace_rd !== 3 || trace_result !== 12) $fatal(1, "Integrated x3 mismatch");
      3: begin
        if (!halted || !dut.trace.trap || dut.trace.cause != 2) $fatal(1, "Missing terminal diagnostic");
        $display("SOC_TEST_PASS: synchronous RAM and synthesis harness execute 5+7=12");
        $finish;
      end
      default: $fatal(1, "Duplicate trace");
    endcase
    count++;
  end
  initial begin #10000; $fatal(1, "SoC watchdog"); end
endmodule
