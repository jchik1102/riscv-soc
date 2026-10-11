`timescale 1ns/1ps
module assertion_tb;
  bit clk = 0, rst = 1, request = 0, response = 0;
  int observed = 0;
  always #5 clk = ~clk;
  assert property (@(posedge clk) disable iff (rst) request |=> response)
    begin observed++; $display("ASSERTION_OBSERVED_PASS"); end
    else $fatal(1, "EXPECTED_ASSERTION_FAILURE");
  initial begin
    repeat (2) @(negedge clk);
    rst = 0; request = 1;
    @(negedge clk);
    request = 0; response = !$test$plusargs("INJECT_FAILURE");
    repeat (2) @(negedge clk);
    if (observed != 1) $fatal(1, "Assertion did not execute exactly once");
    $display("ASSERTION_TEST_PASS");
    $finish;
  end
  initial begin #1000; $fatal(1, "Watchdog"); end
endmodule
